// moonbit-music —— 公共数据类型
// 本文件已冻结（除标注 TODO 的部分）。承载音频样本、格式描述与顶层音频对象。

///|
/// 交织 PCM 样本缓冲。
///
/// 样本一律解成 `Int`，取值范围 `[-2^(bits-1), 2^(bits-1)-1]`。
/// 交织顺序按帧排列，即立体声为 `[L0, R0, L1, R1, ...]`。
pub(all) struct PcmBuffer {
  mut samples : Array[Int]
  sample_rate : Int
  channels : Int
}

///|
/// 创建空缓冲。
pub fn PcmBuffer::new(sample_rate : Int, channels : Int) -> PcmBuffer {
  { samples: [], sample_rate, channels }
}

///|
/// 追加单个样本。
pub fn PcmBuffer::push(self : PcmBuffer, sample : Int) -> Unit {
  self.samples.push(sample)
}

///|
/// 批量追加样本。
///
/// 命名为 `append_all` 而非 `extend`：`extend` 是 MoonBit 保留字。
pub fn PcmBuffer::append_all(self : PcmBuffer, samples : ArrayView[Int]) -> Unit {
  for s in samples {
    self.samples.push(s)
  }
}

///|
/// 已完成帧数（样本数 / 声道数）。
pub fn PcmBuffer::frame_count(self : PcmBuffer) -> Int {
  if self.channels <= 0 {
    0
  } else {
    self.samples.length() / self.channels
  }
}

///|
/// 按有符号小端字节序导出；`bits` 只支持 8 / 16 / 24 / 32。
pub fn PcmBuffer::to_bytes_le(self : PcmBuffer, bits : Int) -> Bytes {
  let out = Buffer()
  for s in self.samples {
    if bits == 8 {
      out.write_byte(s.to_byte())
    } else if bits == 16 {
      out.write_byte((s & 0xFF).to_byte())
      out.write_byte(((s >> 8) & 0xFF).to_byte())
    } else if bits == 24 {
      out.write_byte((s & 0xFF).to_byte())
      out.write_byte(((s >> 8) & 0xFF).to_byte())
      out.write_byte(((s >> 16) & 0xFF).to_byte())
    } else if bits == 32 {
      out.write_byte((s & 0xFF).to_byte())
      out.write_byte(((s >> 8) & 0xFF).to_byte())
      out.write_byte(((s >> 16) & 0xFF).to_byte())
      out.write_byte(((s >> 24) & 0xFF).to_byte())
    } else {
      abort("PcmBuffer::to_bytes_le: unsupported bits=\{bits}")
    }
  }
  out.to_bytes()
}

///|
/// 空缓冲（0 声道、0 采样率）。用于表示解析失败的占位值。
pub fn PcmBuffer::empty() -> PcmBuffer {
  { samples: [], sample_rate: 0, channels: 0 }
}

///|
/// 总样本数（含所有声道）。
pub fn PcmBuffer::len(self : PcmBuffer) -> Int {
  self.samples.length()
}

///|
/// 采样率（Hz）。
pub fn PcmBuffer::sample_rate(self : PcmBuffer) -> Int {
  self.sample_rate
}

///|
/// 声道数。
pub fn PcmBuffer::channels(self : PcmBuffer) -> Int {
  self.channels
}

///|
/// 按帧+声道下标访问样本。越界时行为同 `Array[]`。
pub fn PcmBuffer::get(self : PcmBuffer, frame : Int, ch : Int) -> Int {
  self.samples[frame * self.channels + ch]
}

///|
/// 按帧+声道下标写入样本。
pub fn PcmBuffer::set(self : PcmBuffer, frame : Int, ch : Int, value : Int) -> Unit {
  self.samples[frame * self.channels + ch] = value
}

///|
/// 按只读视图方式查看内部样本数组，避免拷贝。
pub fn PcmBuffer::as_view(self : PcmBuffer) -> ArrayView[Int] {
  self.samples.view()
}

///|
/// 音频流格式描述。
pub(all) struct AudioFormat {
  sample_rate : Int
  channels : Int
  bits_per_sample : Int
} derive(Eq, @debug.Debug)

///|
/// 完整解码结果：格式 + 交织样本 + 标签。
pub(all) struct Audio {
  format : AudioFormat
  samples : Array[Int]
  tags : Array[(String, String)]
} derive(@debug.Debug)

///|
/// 时长（秒）。
pub fn Audio::duration_seconds(self : Audio) -> Double {
  if self.format.sample_rate <= 0 || self.format.channels <= 0 {
    return 0.0
  }
  let frames = self.samples.length() / self.format.channels
  frames.to_double() / self.format.sample_rate.to_double()
}

///|
/// 帧数。
pub fn Audio::frame_count(self : Audio) -> Int {
  if self.format.channels <= 0 {
    0
  } else {
    self.samples.length() / self.format.channels
  }
}

///|
/// 按魔数猜测容器/编码格式。不解析元数据，只看前若干字节。
///
/// 实现 `Eq` / `Debug`：调用方与测试需要用 `assert_eq` 直接比较格式判定结果，
/// 只靠 `Show` 转字符串比较既啰嗦又容易掩盖问题。
pub(all) enum AudioFormatHint {
  Wav
  Flac
  Ogg
  Mp3
  Unknown
} derive(Eq, @debug.Debug)

///|
/// 让 `AudioFormatHint` 可直接用于字符串插值与打印。
pub impl Show for AudioFormatHint with fn to_string(self : AudioFormatHint) -> String {
  match self {
    AudioFormatHint::Wav => "Wav"
    AudioFormatHint::Flac => "Flac"
    AudioFormatHint::Ogg => "Ogg"
    AudioFormatHint::Mp3 => "Mp3"
    AudioFormatHint::Unknown => "Unknown"
  }
}

///|
/// 让 `AudioFormat` 可直接用于字符串插值。
pub impl Show for AudioFormat with fn to_string(self : AudioFormat) -> String {
  "\{self.sample_rate}Hz/\{self.channels}ch/\{self.bits_per_sample}bit"
}

///|
/// 格式自动识别。识别不出返回 `Unknown`，不抛错。
pub fn detect_format(data : Bytes) -> AudioFormatHint {
  if data.length() >= 4 && data[0] == b'R' && data[1] == b'I' && data[2] == b'F' && data[3] == b'F' {
    return AudioFormatHint::Wav
  }
  if data.length() >= 4 && data[0] == b'f' && data[1] == b'L' && data[2] == b'a' && data[3] == b'C' {
    return AudioFormatHint::Flac
  }
  if data.length() >= 4 && data[0] == b'O' && data[1] == b'g' && data[2] == b'g' && data[3] == b'S' {
    return AudioFormatHint::Ogg
  }
  if data.length() >= 3 && data[0] == b'I' && data[1] == b'D' && data[2] == b'3' {
    return AudioFormatHint::Mp3
  }
  if data.length() >= 2 && data[0] == b'\xFF' && (data[1].to_int() & 0xE0) == 0xE0 {
    return AudioFormatHint::Mp3
  }
  AudioFormatHint::Unknown
}

///|
/// 流式解码器句柄。
///
/// 由各格式的工厂函数构造，`next()` 每次产出一个块（通常是一个 FLAC 帧
/// 或一个 MP3 帧组）。`None` 表示流结束。构造只解析头部，不做全量解码。
pub(all) struct Decoder {
  priv state : DecoderState
}

///|
/// 内部状态。各解码器自行扩展此枚举的对应分支。
priv enum DecoderState {
  FlacDecoder(Int)
  OggDecoder(Int)
  Mp3Decoder(Int)
  WavDecoder(Int)
  Finished
}

///|
/// 从 WAV 字节构造解码器。
pub fn Decoder::from_wav(data : Bytes) -> Decoder raise AudioError {
  ignore(data)
  raise AudioError::Unsupported("Decoder::from_wav 尚未接入实现")
}

///|
/// 从 FLAC 字节构造解码器。
pub fn Decoder::from_flac(data : Bytes) -> Decoder raise AudioError {
  ignore(data)
  raise AudioError::Unsupported("Decoder::from_flac 尚未接入实现")
}

///|
/// 从 Ogg 字节构造解码器。
pub fn Decoder::from_ogg(data : Bytes) -> Decoder raise AudioError {
  ignore(data)
  raise AudioError::Unsupported("Decoder::from_ogg 尚未接入实现")
}

///|
/// 从 MP3 字节构造解码器。
pub fn Decoder::from_mp3(data : Bytes) -> Decoder raise AudioError {
  ignore(data)
  raise AudioError::Unsupported("Decoder::from_mp3 尚未接入实现")
}

///|
/// 取下一块。流结束返回 `None`。
pub fn Decoder::next(self : Decoder) -> PcmBuffer? raise AudioError {
  ignore(self)
  raise AudioError::Unsupported("Decoder::next 尚未接入实现")
}

///|
/// 流格式信息。
pub fn Decoder::format(self : Decoder) -> AudioFormat raise AudioError {
  ignore(self)
  raise AudioError::Unsupported("Decoder::format 尚未接入实现")
}
