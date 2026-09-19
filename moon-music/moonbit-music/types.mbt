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
/// 按大小写不敏感的键名查找标签。未找到返回 `None`。
///
/// 键名匹配规则：去掉前后空白、ASCII 大小写不敏感。匹配顺序按标签
/// 数组原有顺序，返回第一个命中的值。
pub fn Audio::get_tag(self : Audio, key : String) -> String? {
  let lower = key.trim().to_lowercase()
  for (k, v) in self.tags {
    if k.trim().to_lowercase() == lower {
      return Some(v)
    }
  }
  None
}

///|
/// 获取标题标签（兼容常见的几种键名）。
pub fn Audio::title(self : Audio) -> String? {
  self.get_tag("TIT2") ?? self.get_tag("title") ?? self.get_tag("Title")
}

///|
/// 获取艺术家标签。
pub fn Audio::artist(self : Audio) -> String? {
  self.get_tag("TPE1") ?? self.get_tag("artist") ?? self.get_tag("Artist")
}

///|
/// 获取专辑标签。
pub fn Audio::album(self : Audio) -> String? {
  self.get_tag("TALB") ?? self.get_tag("album") ?? self.get_tag("Album")
}

///|
/// 把秒数格式化为 `HH:MM:SS.xxx` 或 `MM:SS.xxx`，小时省略（不足 1 小时）。
///
/// 负时长视为 0。毫秒三位，不做四舍五入（直接截断到毫秒）。
pub fn format_duration(total_seconds : Double) -> String {
  let total = if total_seconds < 0.0 { 0.0 } else { total_seconds }
  let ms = ((total - Double::floor(total)) * 1000.0).to_int()
  let mut secs = Double::floor(total).to_int()
  let hours = secs / 3600
  secs = secs - hours * 3600
  let minutes = secs / 60
  secs = secs - minutes * 60
  let pad2 = fn (n : Int) -> String {
    if n < 10 { "0\{n}" } else { "\{n}" }
  }
  let pad3 = fn (n : Int) -> String {
    if n < 10 { "00\{n}" } else if n < 100 { "0\{n}" } else { "\{n}" }
  }
  if hours > 0 {
    "\{hours}:\{pad2(minutes)}:\{pad2(secs)}.\{pad3(ms)}"
  } else {
    "\{pad2(minutes)}:\{pad2(secs)}.\{pad3(ms)}"
  }
}

///|
/// 返回格式化的时长字符串（HH:MM:SS.xxx 或 MM:SS.xxx）。
pub fn Audio::duration_string(self : Audio) -> String {
  format_duration(self.duration_seconds())
}

///|
/// 把标签导出为「key=value」的多行字符串，每帧一行，用于调试输出。
pub fn Audio::tags_to_string(self : Audio) -> String {
  if self.tags.length() == 0 {
    return "(无标签)"
  }
  let buf = Buffer()
  let mut first = true
  for (k, v) in self.tags {
    if first {
      first = false
    } else {
      buf.write_string("\n")
    }
    buf.write_string(k)
    buf.write_string("=")
    buf.write_string(v)
  }
  buf.to_string()
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
/// 常见采样率白名单（8k ~ 192k）。用于 `is_standard` 验证。
const STANDARD_SAMPLE_RATES : Array[Int] = [
  8000, 11025, 16000, 22050, 24000, 32000,
  44100, 48000, 88200, 96000, 176400, 192000,
]

///|
/// 验证格式参数在物理合理范围内（不做白名单检查）。
pub fn AudioFormat::is_valid(self : AudioFormat) -> Bool {
  self.sample_rate > 0 &&
  self.channels > 0 && self.channels <= 256 &&
  self.bits_per_sample > 0 && self.bits_per_sample <= 64
}

///|
/// 验证是否为「标准」PCM 配置：采样率 ∈ 常见白名单、声道 1/2、位深 8/16/24/32。
pub fn AudioFormat::is_standard(self : AudioFormat) -> Bool {
  if !self.is_valid() {
    return false
  }
  let rate_ok = STANDARD_SAMPLE_RATES.exists(fn (r) { r == self.sample_rate })
  let ch_ok = self.channels == 1 || self.channels == 2
  let bits_ok =
    self.bits_per_sample == 8 ||
    self.bits_per_sample == 16 ||
    self.bits_per_sample == 24 ||
    self.bits_per_sample == 32
  rate_ok && ch_ok && bits_ok
}

///|
/// 每帧字节数（仅对整数 PCM 有意义；float/压缩格式调用方自行判断）。
pub fn AudioFormat::frame_bytes(self : AudioFormat) -> Int {
  (self.bits_per_sample / 8) * self.channels
}

///|
/// 每帧（N 声道 × 1 采样点）的时长（秒）。
pub fn AudioFormat::frame_duration_seconds(self : AudioFormat) -> Double {
  if self.sample_rate <= 0 {
    0.0
  } else {
    1.0 / self.sample_rate.to_double()
  }
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
