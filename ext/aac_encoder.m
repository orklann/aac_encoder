#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#pragma mark - PCMToAACEncoder

@interface PCMToAACEncoder : NSObject {
    ExtAudioFileRef _audioFile;
    AudioStreamBasicDescription _pcmFormat;
    AudioStreamBasicDescription _aacFormat;
    BOOL _finished;

    // Keeps incomplete PCM frames between write calls.
    NSMutableData *_pendingPCM;
}

- (instancetype)initWithOutputPath:(NSString *)outputPath
			      sampleRate:(float)sampleRate
			      bitRate:(float)bitRate
                              error:(NSError **)error;

- (BOOL)writePCMData:(NSData *)data
               error:(NSError **)error;

- (BOOL)finish:(NSError **)error;

@end

#pragma mark - Implementation

static NSString * const PCMToAACErrorDomain =
    @"PCMToAACErrorDomain";

static NSError *MakeError(OSStatus status, NSString *message)
{
    return [NSError errorWithDomain:PCMToAACErrorDomain
                               code:status
                           userInfo:@{
        NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"%@ (OSStatus=%d)",
                                       message,
                                       (int)status]
    }];
}

@implementation PCMToAACEncoder

- (instancetype)initWithOutputPath:(NSString *)outputPath
			      sampleRate:(float)sampleRate
			      bitRate:(float)bitRate
                              error:(NSError **)error
{
    self = [super init];

    if (!self) {
        return nil;
    }

    _audioFile = NULL;
    _finished = NO;
    _pendingPCM = [NSMutableData data];

    //
    // Input PCM format:
    //
    // 48,000 Hz
    // 2 channels
    // signed 16-bit
    // interleaved
    // native endian (little endian on Intel/Apple Silicon Mac)
    //

    memset(&_pcmFormat, 0, sizeof(_pcmFormat));

    _pcmFormat.mSampleRate = sampleRate;
    _pcmFormat.mFormatID = kAudioFormatLinearPCM;

    _pcmFormat.mFormatFlags =
        kAudioFormatFlagIsSignedInteger |
        kAudioFormatFlagIsPacked |
        kAudioFormatFlagsNativeEndian;

    _pcmFormat.mChannelsPerFrame = 2;
    _pcmFormat.mBitsPerChannel = 16;

    _pcmFormat.mFramesPerPacket = 1;

    // 2 channels * 2 bytes
    _pcmFormat.mBytesPerFrame = 4;
    _pcmFormat.mBytesPerPacket = 4;

    //
    // Output AAC format.
    //

    memset(&_aacFormat, 0, sizeof(_aacFormat));

    _aacFormat.mSampleRate = sampleRate;
    _aacFormat.mFormatID = kAudioFormatMPEG4AAC;
    _aacFormat.mChannelsPerFrame = 2;

    UInt32 formatSize = sizeof(_aacFormat);

    OSStatus status = AudioFormatGetProperty(
        kAudioFormatProperty_FormatInfo,
        0,
        NULL,
        &formatSize,
        &_aacFormat
    );

    if (status != noErr) {
        if (error) {
            *error = MakeError(
                status,
                @"Unable to get AAC format information"
            );
        }

        return nil;
    }

    //
    // Create M4A container.
    //

    NSURL *url = [NSURL fileURLWithPath:outputPath];

    status = ExtAudioFileCreateWithURL(
        (__bridge CFURLRef)url,
        kAudioFileM4AType,
        &_aacFormat,
        NULL,
        kAudioFileFlags_EraseFile,
        &_audioFile
    );

    if (status != noErr) {
        if (error) {
            *error = MakeError(
                status,
                @"Unable to create M4A file"
            );
        }

        return nil;
    }

    //
    // Tell ExtAudioFile that we will provide PCM.
    //

    status = ExtAudioFileSetProperty(
        _audioFile,
        kExtAudioFileProperty_ClientDataFormat,
        sizeof(_pcmFormat),
        &_pcmFormat
    );

    if (status != noErr) {
        if (error) {
            *error = MakeError(
                status,
                @"Unable to set PCM client format"
            );
        }

        ExtAudioFileDispose(_audioFile);
        _audioFile = NULL;

        return nil;
    }

    //
    // Set AAC bitrate to 128 kbps.
    //

    AudioConverterRef converter = NULL;
    UInt32 converterSize = sizeof(converter);

    status = ExtAudioFileGetProperty(
        _audioFile,
        kExtAudioFileProperty_AudioConverter,
        &converterSize,
        &converter
    );

    if (status == noErr && converter != NULL) {
        UInt32 bitrate = bitRate;

        AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            sizeof(bitrate),
            &bitrate
        );
    }

    return self;
}

- (BOOL)writePCMData:(NSData *)data
               error:(NSError **)error
{
    @autoreleasepool {
        if (_finished) {
            if (error) {
                *error = [NSError errorWithDomain:PCMToAACErrorDomain
                                             code:-1
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Encoder has already been finished"
                }];
            }

            return NO;
        }

        if (!_audioFile) {
            if (error) {
                *error = [NSError errorWithDomain:PCMToAACErrorDomain
                                             code:-2
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"Audio file is not open"
                }];
            }

            return NO;
        }

        if (data.length == 0) {
            return YES;
        }

        //
        // Each stereo 16-bit PCM frame is 4 bytes:
        //
        //   L: 2 bytes
        //   R: 2 bytes
        //
        // stdout reads aren't guaranteed to be frame-aligned,
        // so combine with any bytes left over from the previous call.
        //

        [_pendingPCM appendData:data];

        NSUInteger frameSize = 4;

        NSUInteger completeBytes =
            (_pendingPCM.length / frameSize) * frameSize;

        if (completeBytes == 0) {
            return YES;
        }

        UInt32 frameCount =
            (UInt32)(completeBytes / frameSize);

        AudioBufferList bufferList;

        memset(&bufferList, 0, sizeof(bufferList));

        bufferList.mNumberBuffers = 1;

        bufferList.mBuffers[0].mNumberChannels = 2;
        bufferList.mBuffers[0].mDataByteSize =
            (UInt32)completeBytes;

        bufferList.mBuffers[0].mData =
            (void *)_pendingPCM.bytes;

        OSStatus status = ExtAudioFileWrite(
            _audioFile,
            frameCount,
            &bufferList
        );

        if (status != noErr) {
            if (error) {
                *error = MakeError(
                    status,
                    @"Failed to encode PCM data"
                );
            }

            return NO;
        }

        //
        // Remove the bytes that were successfully encoded.
        //
        // Keep 0-3 bytes for the next write.
        //

        NSUInteger remainingBytes =
            _pendingPCM.length - completeBytes;

        if (remainingBytes > 0) {
            NSData *remaining =
                [_pendingPCM subdataWithRange:
                    NSMakeRange(completeBytes, remainingBytes)];

            [_pendingPCM setData:remaining];
        } else {
            [_pendingPCM setLength:0];
        }
    }
    return YES;
}

- (BOOL)finish:(NSError **)error
{
    if (_finished) {
        return YES;
    }

    _finished = YES;

    //
    // A valid 16-bit stereo PCM stream must end on a
    // 4-byte frame boundary.
    //

    if (_pendingPCM.length != 0) {
        if (error) {
            *error = [NSError errorWithDomain:PCMToAACErrorDomain
                                         code:-3
                                     userInfo:@{
                NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:
                        @"PCM stream ended with %lu incomplete bytes",
                        (unsigned long)_pendingPCM.length]
            }];
        }

        if (_audioFile) {
            ExtAudioFileDispose(_audioFile);
            _audioFile = NULL;
        }

        return NO;
    }

    //
    // Dispose finalizes the M4A/AAC file.
    //

    if (_audioFile) {
        OSStatus status =
            ExtAudioFileDispose(_audioFile);

        _audioFile = NULL;

        if (status != noErr) {
            if (error) {
                *error = MakeError(
                    status,
                    @"Failed to finalize AAC file"
                );
            }

            return NO;
        }
    }

    return YES;
}

- (void)dealloc
{
    if (_audioFile) {
        ExtAudioFileDispose(_audioFile);
        _audioFile = NULL;
    }
    [super dealloc];
}

@end

PCMToAACEncoder *encoder;

void aac_encoder_start(const char* out, 
        float sample_rate,
        float bitrate) {
    NSError *error = nil;
    NSString *outputPath =
                [NSString stringWithUTF8String:out];
    encoder = [[PCMToAACEncoder alloc]
                    initWithOutputPath:outputPath
                    sampleRate: sample_rate
                    bitRate: bitrate
                    error:&error];
}

void aac_encoder_write(unsigned char* buffer, unsigned int length) {
    NSError *error = nil;
    NSData *data = [NSData dataWithBytes:buffer length:length];
    if (![encoder writePCMData:data error:&error]) {
        fprintf(stderr,
            "Encoding error: %s\n",
            error.localizedDescription.UTF8String);
    }
}

void aac_encoder_finish(void) {
    NSError *error = nil;
   if (![encoder finish:&error]) {
        fprintf(stderr,
            "Failed to finalize AAC file: %s\n",
            error.localizedDescription.UTF8String);
    }
    [encoder release];
}
