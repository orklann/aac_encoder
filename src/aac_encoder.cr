@[Link(ldflags: "-framework AudioToolbox -framework AVFoundation -framework Foundation #{__DIR__}/../ext/aac_encoder.m")]
lib Native
  fun aac_encoder_start(out : LibC::Char*, sample_rate : Float32, bitrate : Float32)
  fun aac_encoder_write(buffer : UInt8*, length : UInt32)
  fun aac_encoder_finish
end

class AACEncoder
  def initialize(output_path : String, sample_rate : Float32 = 48000.0_f32, bitrate : Float32 = 128000.0_f32)
    Native.aac_encoder_start(output_path, sample_rate, bitrate)
  end

  # Writes raw PCM bytes to the encoder.
  def write(bytes : Bytes) : Nil
    Native.aac_encoder_write(bytes.to_unsafe, bytes.size.to_u32)
  end

  # Finalizes encoding and flushes/closes the output file.
  def finish : Nil
    Native.aac_encoder_finish
  end
end
