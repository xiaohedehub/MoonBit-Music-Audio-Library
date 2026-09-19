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
///
/// 只检查"数学上可能存在"的下限/上限，不检查硬件或常见格式：
/// 192.5 kHz、3 声道、20 bit 这样的配置都会通过 `is_valid`。
/// 需要"主流声卡可直接播放"的配置判断时改用 `is_standard`。
///
/// @return true 当且仅当 sample_rate > 0、0 < channels <= 256、0 < bits_per_sample <= 64
/// @see AudioFormat::is_standard
pub fn AudioFormat::is_valid(self : AudioFormat) -> Bool {
  self.sample_rate > 0 &&
  self.channels > 0 && self.channels <= 256 &&
  self.bits_per_sample > 0 && self.bits_per_sample <= 64
}

///|
/// 验证是否为「标准」PCM 配置：采样率 ∈ 常见白名单、声道 1/2、位深 8/16/24/32。
///
/// 先调用 `is_valid` 做快路径兜底；三个子条件用 && 短路，先失败的那个不执行。
///
/// 采样率白名单 = [8k, 11.025k, 16k, 22.05k, 24k, 32k, 44.1k, 48k, 88.2k, 96k, 176.4k, 192k]
/// 声道 = 1 (mono) / 2 (stereo, 交织 L R L R ...)
/// 位深 = 8 (unsigned, WAV 特有) / 16 / 24 / 32
///
/// @example
/// ```text
/// is_standard(44100, 2, 16) = true     // CDDA 品质，主流
/// is_standard(48000, 2, 24) = true     // 电影同期
/// is_standard(44100, 6, 16) = false    // 5.1 多声道
/// is_standard(22050, 1, 12) = false    // 非 2 次幂位深
/// ```
/// @return 属于上述标准配置集合返回 true
/// @see AudioFormat::is_valid
/// @see STANDARD_SAMPLE_RATES
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
///
/// `bits_per_sample / 8` 使用整数除法，**向下截断**。
/// 对非 8 对齐的位深（如 12-bit、20-bit）调用方需自己处理尾部
/// 打包位（通常在 WAV/FALC 里都是 8 的倍数，不会踩到此坑）。
///
/// @example
/// ```text
/// frame_bytes(44100, 2, 16) = 2 * 2 = 4
/// frame_bytes(48000, 1, 24) = 1 * 3 = 3
/// frame_bytes(8000,  1, 8)  = 1 * 1 = 1
/// ```
/// @return `floor(bits_per_sample / 8) * channels`
/// @see AudioFormat::frame_duration_seconds
pub fn AudioFormat::frame_bytes(self : AudioFormat) -> Int {
  (self.bits_per_sample / 8) * self.channels
}

///|
/// 每帧（N 声道 × 1 采样点）的时长（秒）。
///
/// `sample_rate <= 0` 返回 0.0，避免除以零和 `Duration::infinity` 之类的语义混乱。
/// 结果是精确有理数 `1 / sample_rate` 的 `Double` 近似；对 44100 Hz 误差
/// 约 2e-17 秒，完全可以忽略（1 亿帧累计误差 < 2 ns）。
///
/// @example
/// ```text
/// frame_duration_seconds(44100 Hz) ≈ 2.267_573_696_145_124_7e-5 s
/// frame_duration_seconds(48000 Hz) = 2.083_333_333_333_333_3e-5 s
/// frame_duration_seconds(0 Hz)     = 0.0 (防御性)
/// ```
/// @return `1.0 / sample_rate` 或防御性的 0.0
/// @see AudioFormat::frame_bytes
/// @see Audio::duration_seconds
pub fn AudioFormat::frame_duration_seconds(self : AudioFormat) -> Double {
  if self.sample_rate <= 0 {
    0.0
  } else {
    1.0 / self.sample_rate.to_double()
  }
}

///|
/// 格式自动识别。识别不出返回 `Unknown`，不抛错。
///
/// 检测策略（按优先级降序，命中即短路返回）：
/// 1. **WAV**：前 4 字节 `"RIFF"` 且 8..12 字节为 `"WAVE"` —— 比只看 RIFF 更严格，
///    可以排除 AVI、ANI、RM 等同样以 RIFF 开头的非音频容器。
/// 2. **FLAC**：前 4 字节 `"fLaC"` —— FLAC 规范的 magic word，字节级确定无歧义。
/// 3. **Ogg**：前 4 字节 `"OggS"` —— Ogg 物理页头首字段，所有 Ogg 容器共享。
/// 4. **MP3 (帧同步)**：首字节 0xFF && `(b1 & 0xE0) == 0xE0` (11 位同步字) 且
///    layer != 00 && version != 01。覆盖 MPEG-1/2/2.5 的 Layer I/II/III。
/// 5. **MP3 (ID3 前置标签)**：前 3 字节 `"ID3"` —— 带前置标签的裸 MP3 流
///    （90% 的商业 MP3 都是这种形态）。
/// 6. **都不命中** → `Unknown`。
///
/// 复杂度：O(1)，最多只读前 12 字节。输入长度不足 12 字节时自动降级到对应分支的
/// 下限检查（比如 n=3 时只走 ID3 和 Unknown 两条路），不会越界。
///
/// @param data 内存中完整或部分音频字节流；可以是文件前 N 字节（通常读 12 字节即够）
/// @return AudioFormatHint 枚举（Wav / Flac / Ogg / Mp3 / Unknown）
/// @see AudioFormatHint::extension
/// @see format_from_extension
pub fn detect_format(data : Bytes) -> AudioFormatHint {
  let n = data.length()
  if n >= 12 &&
     data[0] == b'R' && data[1] == b'I' && data[2] == b'F' && data[3] == b'F' &&
     data[8] == b'W' && data[9] == b'A' && data[10] == b'V' && data[11] == b'E' {
    return AudioFormatHint::Wav
  }
  if n >= 4 && data[0] == b'f' && data[1] == b'L' && data[2] == b'a' && data[3] == b'C' {
    return AudioFormatHint::Flac
  }
  if n >= 4 && data[0] == b'O' && data[1] == b'g' && data[2] == b'g' && data[3] == b'S' {
    return AudioFormatHint::Ogg
  }
  if n >= 2 {
    let b0 = data[0].to_int()
    let b1 = data[1].to_int()
    if b0 == 0xFF {
      // MPEG1/2/2.5 Layer III: 同步字 11 位全 1，layer != 00，version != 01
      let sync_ok = (b1 & 0xE0) == 0xE0
      let layer_ok = (b1 & 0x06) != 0x00
      let version_ok = (b1 & 0x18) != 0x08
      if sync_ok && layer_ok && version_ok {
        return AudioFormatHint::Mp3
      }
    }
  }
  if n >= 3 && data[0] == b'I' && data[1] == b'D' && data[2] == b'3' {
    return AudioFormatHint::Mp3
  }
  AudioFormatHint::Unknown
}

///|
/// 返回 `AudioFormatHint` 对应的典型文件扩展名（小写，不带点）。
///
/// 扩展名是**约定俗成**的"推荐使用"值，不是格式唯一标识：
///   - Ogg Vorbis 也可能叫 `.oga`；
///   - MP3 也可能是 `.mpga` / `.mpeg`；
///   - `Unknown` 统一用 `.bin`，避免乱起名字误导调用方。
/// 需要反向查找（扩展名 → 格式）用 `format_from_extension`。
///
/// @example
/// ```text
/// Wav.extension()     = "wav"
/// Flac.extension()    = "flac"
/// Ogg.extension()     = "ogg"    (Opus-in-Ogg 默认也用 .ogg，除非调用方自行替换)
/// Mp3.extension()     = "mp3"
/// Unknown.extension() = "bin"
/// ```
/// @return 小写、不含前导点的文件扩展名
/// @see format_from_extension
/// @see AudioFormatHint::display_name
pub fn AudioFormatHint::extension(self : AudioFormatHint) -> String {
  match self {
    AudioFormatHint::Wav => "wav"
    AudioFormatHint::Flac => "flac"
    AudioFormatHint::Ogg => "ogg"
    AudioFormatHint::Mp3 => "mp3"
    AudioFormatHint::Unknown => "bin"
  }
}

///|
/// 返回 `AudioFormatHint` 对应的人类可读名称（中文）。
///
/// 文本面向最终用户显示，包含"格式是什么 + 常见用途"两部分信息，
/// 直接出现在 CLI 输出或错误对话框里不需要二次加工。
///
/// @example
/// ```text
/// Wav.display_name() = "WAV (RIFF/WAVE 无损 PCM)"
/// Flac.display_name() = "FLAC (无损压缩)"
/// Ogg.display_name()  = "Ogg (容器，通常为 Vorbis/Opus)"
/// Mp3.display_name()  = "MP3 (MPEG Audio Layer III)"
/// Unknown.display_name() = "未知格式"
/// ```
/// @return 中文格式说明字符串，可直接打印
/// @see AudioFormatHint::extension
pub fn AudioFormatHint::display_name(self : AudioFormatHint) -> String {
  match self {
    AudioFormatHint::Wav => "WAV (RIFF/WAVE 无损 PCM)"
    AudioFormatHint::Flac => "FLAC (无损压缩)"
    AudioFormatHint::Ogg => "Ogg (容器，通常为 Vorbis/Opus)"
    AudioFormatHint::Mp3 => "MP3 (MPEG Audio Layer III)"
    AudioFormatHint::Unknown => "未知格式"
  }
}

///|
/// 从文件扩展名推断格式。扩展名不区分大小写，可带或不带前导点。
///
/// 识别表：
///   WAV  ← wav / wave
///   FLAC ← flac
///   Ogg  ← ogg / oga / opus
///   MP3  ← mp3 / mpeg / mpg
///   其他  → Unknown
///
/// 设计取舍：故意只列**最常见**的别名，不把所有 IANA 注册名都放进来；
/// 罕见扩展名（如 `.mp2` / `.m2a`）走 Unknown，由调用方二次判定，避免误伤。
/// 输入会被 `trim()` + `.` 去前缀 + 小写标准化，调用方不必做预处理。
///
/// @example
/// ```text
/// format_from_extension("WAV")         = Wav
/// format_from_extension(".mp3")        = Mp3
/// format_from_extension("  .Flac ")    = Flac   (trim + 去点 + 小写)
/// format_from_extension("opus")        = Ogg    (Opus-in-Ogg 容器归 Ogg 类)
/// format_from_extension("xyz")         = Unknown
/// format_from_extension("")            = Unknown
/// ```
/// @param ext 原始扩展名（可能带点、大写、前后空格）
/// @return AudioFormatHint 枚举；无法识别时恒为 `Unknown`，从不抛错
/// @see detect_format
/// @see AudioFormatHint::extension
pub fn format_from_extension(ext : String) -> AudioFormatHint {
  let trimmed = ext.trim().to_lowercase()
  let stripped = if trimmed.starts_with(".") { trimmed.substring(1, trimmed.length()) } else { trimmed }
  match stripped {
    "wav" | "wave" => AudioFormatHint::Wav
    "flac" => AudioFormatHint::Flac
    "ogg" | "oga" | "opus" => AudioFormatHint::Ogg
    "mp3" | "mpeg" | "mpg" => AudioFormatHint::Mp3
    _ => AudioFormatHint::Unknown
  }
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
