#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#pragma mark - PCMToAACEncoder Interface

@interface PCMToAACEncoder : NSObject {
    ExtAudioFileRef _audioFile;
    AudioStreamBasicDescription _pcmFormat;
    AudioStreamBasicDescription _aacFormat;
    BOOL _finished;
    NSMutableData *_pendingPCM;
}

- (instancetype)initWithOutputPath:(NSString *)outputPath
                        sampleRate:(float)sampleRate
                           bitRate:(float)bitRate
                             error:(NSError **)error;

- (BOOL)writePCMData:(NSData *)data error:(NSError **)error;
- (BOOL)finish:(NSError **)error;

@end

#pragma mark - Implementation

static NSString * const PCMToAACErrorDomain = @"PCMToAACErrorDomain";

static NSError *MakeError(OSStatus status, NSString *message) {
    return [NSError errorWithDomain:PCMToAACErrorDomain
                               code:status
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ (OSStatus=%d)", message, (int)status]
    }];
}

@implementation PCMToAACEncoder

- (instancetype)initWithOutputPath:(NSString *)outputPath
                        sampleRate:(float)sampleRate
                           bitRate:(float)bitRate
                             error:(NSError **)error
{
    self = [super init];
    if (!self) return nil;

    _audioFile = NULL;
    _finished = NO;
    
    // FIX 1: Retain mutable data under manual reference counting
    _pendingPCM = [[NSMutableData alloc] init];

    // Input PCM format
    memset(&_pcmFormat, 0, sizeof(_pcmFormat));
    _pcmFormat.mSampleRate = sampleRate;
    _pcmFormat.mFormatID = kAudioFormatLinearPCM;
    _pcmFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    _pcmFormat.mChannelsPerFrame = 2;
    _pcmFormat.mBitsPerChannel = 16;
    _pcmFormat.mFramesPerPacket = 1;
    _pcmFormat.mBytesPerFrame = 4;
    _pcmFormat.mBytesPerPacket = 4;

    // Output AAC format
    memset(&_aacFormat, 0, sizeof(_aacFormat));
    _aacFormat.mSampleRate = sampleRate;
    _aacFormat.mFormatID = kAudioFormatMPEG4AAC;
    _aacFormat.mChannelsPerFrame = 2;

    UInt32 formatSize = sizeof(_aacFormat);
    OSStatus status = AudioFormatGetProperty(
        kAudioFormatProperty_FormatInfo,
        0, NULL, &formatSize, &_aacFormat
    );

    if (status != noErr) {
        if (error) *error = MakeError(status, @"Unable to get AAC format information");
        [_pendingPCM release];
        return nil;
    }

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
        if (error) *error = MakeError(status, @"Unable to create M4A file");
        [_pendingPCM release];
        return nil;
    }

    status = ExtAudioFileSetProperty(
        _audioFile,
        kExtAudioFileProperty_ClientDataFormat,
        sizeof(_pcmFormat),
        &_pcmFormat
    );

    if (status != noErr) {
        if (error) *error = MakeError(status, @"Unable to set PCM client format");
        ExtAudioFileDispose(_audioFile);
        _audioFile = NULL;
        [_pendingPCM release];
        return nil;
    }

    AudioConverterRef converter = NULL;
    UInt32 converterSize = sizeof(converter);
    status = ExtAudioFileGetProperty(
        _audioFile,
        kExtAudioFileProperty_AudioConverter,
        &converterSize,
        &converter
    );

    if (status == noErr && converter != NULL) {
        UInt32 bitrate = (UInt32)bitRate;
        AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            sizeof(bitrate),
            &bitrate
        );
    }

    return self;
}

- (BOOL)writePCMData:(NSData *)data error:(NSError **)error {
    @autoreleasepool {
        if (_finished) {
            if (error) {
                *error = [NSError errorWithDomain:PCMToAACErrorDomain
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Encoder has already been finished"}];
            }
            return NO;
        }

        if (!_audioFile) {
            if (error) {
                *error = [NSError errorWithDomain:PCMToAACErrorDomain
                                             code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"Audio file is not open"}];
            }
            return NO;
        }

        if (data.length == 0) return YES;

        [_pendingPCM appendData:data];

        NSUInteger frameSize = 4;
        NSUInteger completeBytes = (_pendingPCM.length / frameSize) * frameSize;

        if (completeBytes == 0) return YES;

        UInt32 frameCount = (UInt32)(completeBytes / frameSize);

        AudioBufferList bufferList;
        memset(&bufferList, 0, sizeof(bufferList));
        bufferList.mNumberBuffers = 1;
        bufferList.mBuffers[0].mNumberChannels = 2;
        bufferList.mBuffers[0].mDataByteSize = (UInt32)completeBytes;
        bufferList.mBuffers[0].mData = (void *)_pendingPCM.bytes;

        OSStatus status = ExtAudioFileWrite(_audioFile, frameCount, &bufferList);

        if (status != noErr) {
            if (error) *error = MakeError(status, @"Failed to encode PCM data");
            return NO;
        }

        NSUInteger remainingBytes = _pendingPCM.length - completeBytes;
        if (remainingBytes > 0) {
            NSData *remaining = [_pendingPCM subdataWithRange:NSMakeRange(completeBytes, remainingBytes)];
            [_pendingPCM setData:remaining];
        } else {
            [_pendingPCM setLength:0];
        }
    }
    return YES;
}

- (BOOL)finish:(NSError **)error {
    if (_finished) return YES;
    _finished = YES;

    if (_pendingPCM.length != 0) {
        if (error) {
            *error = [NSError errorWithDomain:PCMToAACErrorDomain
                                         code:-3
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"PCM stream ended with %lu incomplete bytes", (unsigned long)_pendingPCM.length]
            }];
        }
        if (_audioFile) {
            ExtAudioFileDispose(_audioFile);
            _audioFile = NULL;
        }
        return NO;
    }

    if (_audioFile) {
        OSStatus status = ExtAudioFileDispose(_audioFile);
        _audioFile = NULL;

        if (status != noErr) {
            if (error) *error = MakeError(status, @"Failed to finalize AAC file");
            return NO;
        }
    }

    return YES;
}

- (void)dealloc {
    if (_audioFile) {
        ExtAudioFileDispose(_audioFile);
        _audioFile = NULL;
    }
    // FIX 2: Properly release pending PCM data
    [_pendingPCM release];
    _pendingPCM = nil;
    
    [super dealloc];
}

@end

#pragma mark - Safe C Interface (Pass Opaque Handles)

// FIX 3: Instead of a global `encoder` variable, pass handles to Crystal to avoid cross-thread races.

void* aac_encoder_create(const char* out, float sample_rate, float bitrate) {
    NSError *error = nil;
    NSString *outputPath = [NSString stringWithUTF8String:out];
    PCMToAACEncoder *enc = [[PCMToAACEncoder alloc] initWithOutputPath:outputPath
                                                            sampleRate:sample_rate
                                                               bitRate:bitrate
                                                                 error:&error];
    if (error) {
        fprintf(stderr, "Initialization error: %s\n", error.localizedDescription.UTF8String);
    }
    return (void*)enc;
}

void aac_encoder_write(void* handle, unsigned char* buffer, unsigned int length) {
    if (!handle) return;
    @autoreleasepool {
        PCMToAACEncoder *enc = (PCMToAACEncoder*)handle;
        NSError *error = nil;
        NSData *data = [NSData dataWithBytesNoCopy:buffer length:length freeWhenDone:NO];
        if (![enc writePCMData:data error:&error]) {
            fprintf(stderr, "Encoding error: %s\n", error.localizedDescription.UTF8String);
        }
    }
}

void aac_encoder_finish(void* handle) {
    if (!handle) return;
    PCMToAACEncoder *enc = (PCMToAACEncoder*)handle;
    NSError *error = nil;
    if (![enc finish:&error]) {
        fprintf(stderr, "Failed to finalize AAC file: %s\n", error.localizedDescription.UTF8String);
    }
    [enc release];
}
