@[Link(ldflags: "-framework AudioToolbox -framework AVFoundation -framework Foundation #{__DIR__}/../ext/aac_encoder.m")]
lib Native
  fun aac_encoder_create(out : LibC::Char*, sample_rate : Float32, bitrate : Float32) : Void*
  fun aac_encoder_write(handle : Void*, buffer : UInt8*, length : UInt32)
  fun aac_encoder_finish(handle : Void*)
end

class AACEncoder
  @handle : Void*

  def initialize(output_path : String, sample_rate : Float32 = 48000.0_f32, bitrate : Float32 = 128000.0_f32)
  @handle = Native.aac_encoder_create(output_path, sample_rate, bitrate)
  end

  # Writes raw PCM bytes to the encoder.
  def write(bytes : Bytes) : Nil
    return if @handle.null?
    Native.aac_encoder_write(@handle, bytes.to_unsafe, bytes.size.to_u32)
  end

  # Finalizes encoding and flushes/closes the output file.
  def finish : Nil
    return if @handle.null?
    handle = @handle
    @handle = Pointer(Void).null
    Native.aac_encoder_finish(handle)
  end
end
