// moonbit-music —— MP3（MPEG-1 / MPEG-2 / MPEG-2.5 Layer III）
//
// ⚠️ 覆盖范围（诚实声明，逐条对应实现与测试）
//
//   ✅ 帧同步头解析：11 位同步字、version、layer、protection、bitrate、
//      sampling rate、padding、private、channel mode、mode extension、
//      copyright、original、emphasis；保留值全部报错。
//   ✅ 帧长公式与每帧样本数（MPEG1 = 144*bps/sr + pad，1152 样本；
//      MPEG2/2.5 = 72*bps/sr + pad，576 样本）。
//   ✅ ID3v2 开头跳过（自带最小实现，不依赖 id3.mbt）、ID3v1 尾部识别。
//   ✅ 帧遍历：字节对齐扫描 + 连续两个合法帧头确认 + 中途重同步。
//   ✅ side info 全字段解析（MPEG1 17/32 字节，MPEG2/2.5 9/17 字节）。
//   ✅ Huffman 区域划分与 table_select 选择规则（非窗口切换 granule）。
//   ⚠️ scalefactor band 表：只内置 44100 Hz 的长块 / 短块两张表。
//   ⚠️ Huffman 表：只内置表 1（4 个码字），且该表数据未经外部参考比对。
//   ❌ scalefactor 解码、requantization、stereo processing、alias reduction、
//      IMDCT、频率反转、多相合成滤波器组 —— 一律 raise Unsupported。
//
// 结论：本文件的 `decode_mp3` **不会**返回真实音频。它做完整结构性校验后
// 明确抛 `Unsupported`，绝不输出未经校验的样本。

// ============================================================
// 常量表
// ============================================================

///|
/// MPEG-1 Layer III 比特率表（kbps），下标即 4 位 bitrate index。
///
/// index 0 = free（本实现不支持），index 15 = bad（非法值）。
let mp3_bitrate_mpeg1_l3 : Array[Int] = [
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
]

///|
/// MPEG-2 / MPEG-2.5 Layer III 比特率表（kbps），下标即 4 位 bitrate index。
let mp3_bitrate_mpeg2_l3 : Array[Int] = [
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0,
]

///|
/// MPEG-1 采样率表（Hz），下标即 2 位 sampling rate index；index 3 为保留值，置 0。
let mp3_sample_rates_mpeg1 : Array[Int] = [44100, 48000, 32000, 0]

///|
/// MPEG-2 采样率表（Hz），等于 MPEG-1 的一半。index 3 为保留值，置 0。
let mp3_sample_rates_mpeg2 : Array[Int] = [22050, 24000, 16000, 0]

///|
/// MPEG-2.5 采样率表（Hz），等于 MPEG-1 的四分之一。index 3 为保留值，置 0。
let mp3_sample_rates_mpeg25 : Array[Int] = [11025, 12000, 8000, 0]

///|
/// 44.1kHz 长块的 scalefactor band 边界（23 项 / 22 个 band，末项 576）。
///
/// 相邻两项之差即该 band 的系数宽度。只有 44100 Hz 内置；其余采样率的表
/// 未被本实现验证，故意不写入。
///
/// ⚠️ 与 Huffman 表同样的问题：本仓库里没有参考数据，测试只能验证它
/// 单调递增、首项 0、末项 576（宽度和为 576），**无法**证明它和标准逐项一致。
let mp3_sfb_long_44100 : Array[Int] = [
  0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134, 162, 196, 238, 288,
  342, 418, 576,
]

///|
/// 44.1kHz 短块的 scalefactor band 边界（14 项 / 13 个 band，末项 192）。
///
/// 短块每个 granule 只有 192 个系数（3 个窗口 × 64）。
let mp3_sfb_short_44100 : Array[Int] = [
  0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192,
]

// ============================================================
// MSB-first 位读取器
// ============================================================

///|
/// MSB-first 位读取器（与 FLAC 相同，与 Vorbis 相反）。
///
/// 内部只记录**绝对**位偏移，字节内从最高位开始消费。一次最多读 24 位，
/// 避免 `Int` 左移溢出。越界读抛 `Truncated`，不 panic。
pub struct Mp3BitReader {
  priv data : Bytes
  priv mut bit_offset : Int
}

///|
/// 从 `bit_offset` 位处开始读 `data`。
pub fn Mp3BitReader::new(data : Bytes, bit_offset : Int) -> Mp3BitReader {
  { data, bit_offset, }
}

///|
/// 当前绝对位偏移。
pub fn Mp3BitReader::bit_offset(self : Mp3BitReader) -> Int {
  self.bit_offset
}

///|
/// 剩余可读位数（负数表示起点已越界）。
pub fn Mp3BitReader::bits_left(self : Mp3BitReader) -> Int {
  self.data.length() * 8 - self.bit_offset
}

///|
/// 读 `n` 位（`0 <= n <= 24`），MSB-first，返回无符号值。
pub fn Mp3BitReader::read_bits(
  self : Mp3BitReader,
  n : Int,
) -> Int raise AudioError {
  if n < 0 || n > 24 {
    raise AudioError::Unsupported(
      "Mp3BitReader::read_bits: 只支持 0..24 位，收到 \{n}",
    )
  }
  if self.bits_left() < n {
    raise AudioError::Truncated(
      offset=self.bit_offset / 8,
      needed=n,
      available=self.bits_left(),
    )
  }
  let mut value = 0
  let mut i = 0
  while i < n {
    let byte = self.data[self.bit_offset / 8].to_int()
    // 逻辑右移：bit_offset 恒非负，普通 `>>` 即可。
    let bit = (byte >> (7 - self.bit_offset % 8)) & 1
    value = (value << 1) | bit
    self.bit_offset = self.bit_offset + 1
    i = i + 1
  }
  value
}

///|
/// 跳过 `n` 位，不返回值。
pub fn Mp3BitReader::skip_bits(
  self : Mp3BitReader,
  n : Int,
) -> Unit raise AudioError {
  if n < 0 {
    raise AudioError::Unsupported(
      "Mp3BitReader::skip_bits: 位数不能为负，收到 \{n}",
    )
  }
  if self.bits_left() < n {
    raise AudioError::Truncated(
      offset=self.bit_offset / 8,
      needed=n,
      available=self.bits_left(),
    )
  }
  self.bit_offset = self.bit_offset + n
}

// ============================================================
// 公开数据类型
// ============================================================

///|
/// MPEG 音频版本。
pub(all) enum Mp3Version {
  Mpeg1
  Mpeg2
  Mpeg25
} derive(Eq, @debug.Debug)

///|
/// 声道模式（帧头 2 位 channel mode）。
pub(all) enum Mp3ChannelMode {
  Stereo
  JointStereo
  DualChannel
  Mono
} derive(Eq, @debug.Debug)

///|
/// 帧头解析结果。`version` 保留值、`layer` 非 III、非法比特率等都在解析阶段
/// 已经报错，因此本结构里的值都是可用的。
pub(all) struct Mp3FrameHeader {
  /// MPEG 版本。
  version : Mp3Version
  /// protection bit 为 0（帧头后跟 16 位 CRC）时为 true。
  has_crc : Bool
  /// 比特率，单位 kbps（查表得到）。
  bitrate_kbps : Int
  /// 采样率，单位 Hz。
  sample_rate : Int
  /// padding bit，取值 0 或 1，直接加进帧长。
  padding : Int
  /// private bit，原样保留。
  private_bit : Int
  /// 声道模式。
  channel_mode : Mp3ChannelMode
  /// mode extension 的 2 位原始值（含义依赖声道模式）。
  mode_extension : Int
  /// copyright bit。
  copyright : Bool
  /// original bit。
  original : Bool
  /// emphasis 的 2 位原始值（保留值 `10` 已在解析阶段报错）。
  emphasis : Int
  /// 本帧总字节数（含 4 字节帧头）：MPEG1 为 `144*bitrate/sample_rate + padding`，
  /// MPEG2/2.5 为 `72*bitrate/sample_rate + padding`。
  frame_size : Int
  /// 每帧样本数：MPEG1 = 1152，MPEG2/2.5 = 576。
  samples_per_frame : Int
  /// 声道数：Mono 为 1，其余为 2。
  channels : Int
} derive(Eq, @debug.Debug)

///|
/// 一个 granule 中的一个声道的 side info。
///
/// 字段取值严格来自位流；未传输的字段按规范补零并在注释中标明。
pub(all) struct Mp3GranuleChannel {
  /// part2_3_length，12 位：main data 中属于本 granule 声道的比特数。
  part2_3_length : Int
  /// big_values，9 位：Huffman 编码的大值对数量（覆盖系数 `0 .. 2*big_values-1`）。
  big_values : Int
  /// global_gain，8 位。
  global_gain : Int
  /// scalefac_compress，MPEG1 为 4 位，MPEG2/2.5 为 9 位。
  scalefac_compress : Int
  /// window_switching_flag，1 位。
  window_switching_flag : Int
  /// block_type，2 位；未切换窗口时为 0。
  block_type : Int
  /// mixed_block_flag，1 位；未切换窗口时为 0。
  mixed_block_flag : Int
  /// table_select，长度恒为 3。
  /// 非窗口切换时三个都从位流读出；窗口切换时只传输 [0] 和 [1]，
  /// [2] 恒为 0 且不使用（该情况下 region 2 为空）。
  table_select : Array[Int]
  /// subblock_gain，长度恒为 3；未切换窗口时为全 0。
  subblock_gain : Array[Int]
  /// region0_count，4 位；窗口切换时未传输，为 0。
  region0_count : Int
  /// region1_count，3 位；窗口切换时未传输，为 0。
  region1_count : Int
  /// preflag，1 位；MPEG2/2.5 没有该字段，为 0。
  preflag : Int
  /// scalefac_scale，1 位。
  scalefac_scale : Int
  /// count1table_select，1 位。
  count1table_select : Int
} derive(@debug.Debug)

///|
/// 一帧的 side info。
pub(all) struct Mp3SideInfo {
  /// 来自帧头的 MPEG 版本。
  version : Mp3Version
  /// 声道数。
  channels : Int
  /// main_data_begin：MPEG1 为 9 位，MPEG2/2.5 为 8 位。
  /// 表示本帧 main data 在比特池中要向前回退的字节数。
  main_data_begin : Int
  /// private_bits：单声道 MPEG1 为 5 位 / MPEG2 为 1 位；立体声为 3 位 / 2 位。
  private_bits : Int
  /// scfsi，每个声道一个 4 位掩码；MPEG2/2.5 没有该字段，数组为空。
  scfsi : Array[Int]
  /// granule 列表：MPEG1 有 2 个 granule，MPEG2/2.5 只有 1 个。
  /// `granules[g][c]` 是 granule `g` 的声道 `c`。
  granules : Array[Array[Mp3GranuleChannel]]
} derive(@debug.Debug)

///|
/// 一项 Huffman 码字：`hlen` 位的 `hcod` 对应值对 `(x, y)`。
pub(all) struct Mp3HuffmanEntry {
  hlen : Int
  hcod : Int
  x : Int
  y : Int
} derive(Eq, @debug.Debug)

// ============================================================
// ID3 处理（最小实现，不依赖 id3.mbt）
// ============================================================

///|
/// 文件开头 ID3v2 标签占用的字节数；没有标签返回 0。
///
/// 只做最小实现：`"ID3"` + 2 字节版本 + 1 字节 flags + 4 字节 syncsafe size，
/// 跳过 `10 + size`（若 flags 的 footer 位 `0x10` 置位，再额外跳 10 字节）。
/// 不解析任何 frame，也不处理 unsynchronisation。
/// 若标签声称的长度超出文件，返回文件长度（截断保护）。
pub fn mp3_skip_id3v2(data : Bytes) -> Int {
  if data.length() < 10 {
    return 0
  }
  if data[0] != b'I' || data[1] != b'D' || data[2] != b'3' {
    return 0
  }
  let flags = data[5].to_int()
  // syncsafe：每字节只用低 7 位
  let size = ((data[6].to_int() & 0x7F) << 21) |
    ((data[7].to_int() & 0x7F) << 14) |
    ((data[8].to_int() & 0x7F) << 7) |
    (data[9].to_int() & 0x7F)
  let footer = if (flags & 0x10) != 0 { 10 } else { 0 }
  let total = 10 + size + footer
  if total > data.length() {
    data.length()
  } else {
    total
  }
}

///|
/// 文件末尾 ID3v1 标签（最后 128 字节以 `"TAG"` 开头）的起始偏移；没有则返回 -1。
pub fn mp3_id3v1_offset(data : Bytes) -> Int {
  if data.length() < 128 {
    return -1
  }
  let off = data.length() - 128
  if data[off] == b'T' && data[off + 1] == b'A' && data[off + 2] == b'G' {
    off
  } else {
    -1
  }
}

///|
/// 真正属于 MPEG 音频数据的字节区间 `[start, end)`：排除开头的 ID3v2 与末尾的 ID3v1。
fn mp3_audio_range(data : Bytes) -> (Int, Int) {
  let start = mp3_skip_id3v2(data)
  let id3v1 = mp3_id3v1_offset(data)
  let end = if id3v1 > start && id3v1 <= data.length() {
    id3v1
  } else {
    data.length()
  }
  (start, end)
}

// ============================================================
// 帧头解析
// ============================================================

///|
/// 解析 `offset` 处的 4 字节 MP3 帧同步头。
///
/// 只接受 **Layer III**：
/// - 同步字不匹配 / version 保留值 `01` / layer 保留值 `00` / bitrate index `1111`
///   / sampling rate index `11` / emphasis 保留值 `10` → `InvalidMagic`
/// - 非 Layer III（Layer I / II）与 free bitrate（bitrate index `0000`）→ `Unsupported`
/// - `offset` 处不足 4 字节 → `Truncated`
pub fn mp3_parse_frame_header(
  data : Bytes,
  offset : Int,
) -> Mp3FrameHeader raise AudioError {
  if offset < 0 || offset + 4 > data.length() {
    let avail = if offset >= data.length() { 0 } else { data.length() - offset }
    raise AudioError::Truncated(offset~, needed=4, available=avail)
  }
  let b0 = data[offset].to_int()
  let b1 = data[offset + 1].to_int()
  let b2 = data[offset + 2].to_int()
  let b3 = data[offset + 3].to_int()
  // 前 11 位必须全为 1
  if b0 != 0xFF || (b1 & 0xE0) != 0xE0 {
    raise AudioError::InvalidMagic(
      "MP3 帧同步字不匹配（前 11 位须全为 1），offset=\{offset}",
    )
  }
  // 2 位 version
  let version = match (b1 >> 3) & 0x03 {
    0 => Mp3Version::Mpeg25
    2 => Mp3Version::Mpeg2
    3 => Mp3Version::Mpeg1
    _ =>
      raise AudioError::InvalidMagic(
        "MP3 version 字段为保留值 01，offset=\{offset}",
      )
  }
  // 2 位 layer
  let layer_bits = (b1 >> 1) & 0x03
  if layer_bits == 0 {
    raise AudioError::InvalidMagic(
      "MP3 layer 字段为保留值 00，offset=\{offset}",
    )
  }
  if layer_bits != 1 {
    let name = if layer_bits == 3 { "I" } else { "II" }
    raise AudioError::Unsupported(
      "MP3 只实现 Layer III，本帧是 Layer \{name}，offset=\{offset}",
    )
  }
  // 1 位 protection：0 表示后面跟 16 位 CRC
  let has_crc = (b1 & 0x01) == 0
  // 4 位 bitrate index
  let bitrate_index = (b2 >> 4) & 0x0F
  if bitrate_index == 0 {
    raise AudioError::Unsupported(
      "MP3 free bitrate（bitrate index 0000）不支持，offset=\{offset}",
    )
  }
  if bitrate_index == 15 {
    raise AudioError::InvalidMagic(
      "MP3 bitrate index 1111 为非法值，offset=\{offset}",
    )
  }
  let bitrate_kbps = match version {
    Mp3Version::Mpeg1 => mp3_bitrate_mpeg1_l3[bitrate_index]
    _ => mp3_bitrate_mpeg2_l3[bitrate_index]
  }
  // 2 位 sampling rate index
  let sample_rate_index = (b2 >> 2) & 0x03
  if sample_rate_index == 3 {
    raise AudioError::InvalidMagic(
      "MP3 sampling rate index 11 为保留值，offset=\{offset}",
    )
  }
  let sample_rate = match version {
    Mp3Version::Mpeg1 => mp3_sample_rates_mpeg1[sample_rate_index]
    Mp3Version::Mpeg2 => mp3_sample_rates_mpeg2[sample_rate_index]
    Mp3Version::Mpeg25 => mp3_sample_rates_mpeg25[sample_rate_index]
  }
  let padding = (b2 >> 1) & 0x01
  let private_bit = b2 & 0x01
  // 2 位 channel mode
  let mode_bits = (b3 >> 6) & 0x03
  let channel_mode = match mode_bits {
    0 => Mp3ChannelMode::Stereo
    1 => Mp3ChannelMode::JointStereo
    2 => Mp3ChannelMode::DualChannel
    _ => Mp3ChannelMode::Mono
  }
  let mode_extension = (b3 >> 4) & 0x03
  let copyright = ((b3 >> 3) & 0x01) == 1
  let original = ((b3 >> 2) & 0x01) == 1
  let emphasis = b3 & 0x03
  if emphasis == 2 {
    raise AudioError::InvalidMagic(
      "MP3 emphasis 字段为保留值 10，offset=\{offset}",
    )
  }
  let channels = if channel_mode == Mp3ChannelMode::Mono { 1 } else { 2 }
  let samples_per_frame = match version {
    Mp3Version::Mpeg1 => 1152
    _ => 576
  }
  // Layer III 帧长：MPEG1 用 144，MPEG2/2.5 用 72
  let coefficient = match version {
    Mp3Version::Mpeg1 => 144
    _ => 72
  }
  let frame_size = coefficient * (bitrate_kbps * 1000) / sample_rate + padding
  {
    version,
    has_crc,
    bitrate_kbps,
    sample_rate,
    padding,
    private_bit,
    channel_mode,
    mode_extension,
    copyright,
    original,
    emphasis,
    frame_size,
    samples_per_frame,
    channels,
  }
}

///|
/// side info 的字节数：MPEG1 单声道 17 / 立体声 32；MPEG2/2.5 单声道 9 / 立体声 17。
pub fn mp3_side_info_size(header : Mp3FrameHeader) -> Int {
  match header.version {
    Mp3Version::Mpeg1 => if header.channels == 1 { 17 } else { 32 }
    _ => if header.channels == 1 { 9 } else { 17 }
  }
}

///|
/// side info 在本帧内的字节偏移（帧头 4 字节 + 可能的 2 字节 CRC）。
pub fn mp3_side_info_offset(header : Mp3FrameHeader, frame_offset : Int) -> Int {
  frame_offset + 4 + (if header.has_crc { 2 } else { 0 })
}

///|
/// main data 在本帧内的字节偏移（帧头 + CRC + side info）。
///
/// 注意：这只是本帧 main data 的起点；实际使用还要按 `main_data_begin`
/// 向前回退到比特池里（见 `Mp3SideInfo.main_data_begin`）。
pub fn mp3_main_data_offset(header : Mp3FrameHeader, frame_offset : Int) -> Int {
  mp3_side_info_offset(header, frame_offset) + mp3_side_info_size(header)
}

// ============================================================
// 帧扫描 / 重同步
// ============================================================

///|
/// 尝试解析帧头，失败返回 `None`（不抛错）。供扫描使用。
fn mp3_try_header(data : Bytes, offset : Int) -> Mp3FrameHeader? {
  Some(mp3_parse_frame_header(data, offset)) catch {
    _ => None
  }
}

///|
/// 两个帧头是否属于同一条流（版本与采样率必须一致）。
/// 用于「连续两帧确认」，挡住恰好相隔一个 frame_size 的假同步。
fn mp3_header_matches(a : Mp3FrameHeader, b : Mp3FrameHeader) -> Bool {
  a.version == b.version && a.sample_rate == b.sample_rate
}

///|
/// 若 `offset` 处存在**被下一帧确认**的合法帧头，返回它；否则返回 `None`。
///
/// 这是本实现防误同步的核心策略：单独一个合法帧头不算数，必须在其
/// `frame_size` 之后紧跟另一个合法且版本/采样率一致的帧头。
fn mp3_confirmed_sync(data : Bytes, offset : Int, end : Int) -> Mp3FrameHeader? {
  match mp3_try_header(data, offset) {
    None => None
    Some(h) => {
      let next = offset + h.frame_size
      if next + 4 > end {
        None
      } else {
        match mp3_try_header(data, next) {
          Some(h2) => if mp3_header_matches(h, h2) { Some(h) } else { None }
          None => None
        }
      }
    }
  }
}

///|
/// 在 `[from, end)` 内逐字节搜索第一个被确认的同步头，返回其偏移。
fn mp3_find_sync(data : Bytes, from : Int, end : Int) -> Int? {
  let mut p = from
  while p + 4 <= end {
    if mp3_confirmed_sync(data, p, end) is Some(_) {
      return Some(p)
    }
    p = p + 1
  }
  None
}

///|
/// 第一条被确认的帧的字节偏移（自动跳过开头 ID3v2）。
///
/// 策略：**字节对齐扫描 + 连续 2 个合法帧头确认**。因此本实现要求文件里
/// 至少有 2 个连续帧；只有 1 帧的文件会被判为同步失败。
pub fn mp3_first_frame_offset(data : Bytes) -> Int raise AudioError {
  if data.length() < 4 {
    raise AudioError::Truncated(offset=0, needed=4, available=data.length())
  }
  let (start, end) = mp3_audio_range(data)
  match mp3_find_sync(data, start, end) {
    Some(p) => p
    None =>
      raise AudioError::InvalidMagic(
        "MP3: 在 [\{start}, \{end}) 内找不到连续两个合法帧头，同步失败",
      )
  }
}

///|
/// 扫描全部帧，返回每帧的字节偏移。
///
/// 已锁定之后按 `frame_size` 推进；一旦某处的帧头不合法，或者帧尾超出音频区
/// （可能是末尾残片，也可能是垃圾里的假同步），就**重新做字节对齐搜索**
/// （同样要求连续两帧确认），而不是直接结束——真实文件里帧间可能有填充或垃圾。
/// 只有再也找不到被确认的同步头时才停止。
pub fn mp3_scan_frames(data : Bytes) -> Array[Int] raise AudioError {
  let first = mp3_first_frame_offset(data)
  let (_, end) = mp3_audio_range(data)
  let frames : Array[Int] = []
  let mut pos = first
  while pos + 4 <= end {
    let header = mp3_try_header(data, pos)
    if header is Some(h) && pos + h.frame_size <= end {
      frames.push(pos)
      pos = pos + h.frame_size
    } else {
      match mp3_find_sync(data, pos + 1, end) {
        Some(p) => pos = p
        None => break
      }
    }
  }
  frames
}

// ============================================================
// side info 解析
// ============================================================

///|
/// 读一个 granule 声道的 59 位（MPEG1）或 63 位（MPEG2/2.5）字段。
fn mp3_read_granule_channel(
  reader : Mp3BitReader,
  version : Mp3Version,
) -> Mp3GranuleChannel raise AudioError {
  let mpeg1 = version == Mp3Version::Mpeg1
  let part2_3_length = reader.read_bits(12)
  let big_values = reader.read_bits(9)
  let global_gain = reader.read_bits(8)
  // MPEG1 为 4 位，MPEG2/2.5 为 9 位
  let scalefac_compress = if mpeg1 {
    reader.read_bits(4)
  } else {
    reader.read_bits(9)
  }
  let window_switching_flag = reader.read_bits(1)
  let table_select : Array[Int] = [0, 0, 0]
  let subblock_gain : Array[Int] = [0, 0, 0]
  let mut block_type = 0
  let mut mixed_block_flag = 0
  let mut region0_count = 0
  let mut region1_count = 0
  if window_switching_flag == 1 {
    block_type = reader.read_bits(2)
    mixed_block_flag = reader.read_bits(1)
    table_select[0] = reader.read_bits(5)
    table_select[1] = reader.read_bits(5)
    // table_select[2] 在窗口切换时不传输，保持 0 且不使用
    subblock_gain[0] = reader.read_bits(3)
    subblock_gain[1] = reader.read_bits(3)
    subblock_gain[2] = reader.read_bits(3)
  } else {
    table_select[0] = reader.read_bits(5)
    table_select[1] = reader.read_bits(5)
    table_select[2] = reader.read_bits(5)
    region0_count = reader.read_bits(4)
    region1_count = reader.read_bits(3)
  }
  // MPEG2/2.5 没有 preflag 字段
  let preflag = if mpeg1 { reader.read_bits(1) } else { 0 }
  let scalefac_scale = reader.read_bits(1)
  let count1table_select = reader.read_bits(1)
  {
    part2_3_length,
    big_values,
    global_gain,
    scalefac_compress,
    window_switching_flag,
    block_type,
    mixed_block_flag,
    table_select,
    subblock_gain,
    region0_count,
    region1_count,
    preflag,
    scalefac_scale,
    count1table_select,
  }
}

///|
/// 解析 `frame_offset` 处那一帧的 side info。
///
/// 字段顺序严格按 ISO/IEC 11172-3（MPEG1）：9 位 main_data_begin、
/// 5/3 位 private_bits、每声道 4 位 scfsi、2 个 granule × 声道的 59 位；
/// MPEG2/2.5：8 位 main_data_begin、1/2 位 private_bits、无 scfsi、
/// 1 个 granule × 声道的 63 位。总位数恰好等于 `mp3_side_info_size`：17/32/9/17 字节。
pub fn mp3_parse_side_info(
  data : Bytes,
  header : Mp3FrameHeader,
  frame_offset : Int,
) -> Mp3SideInfo raise AudioError {
  let start = mp3_side_info_offset(header, frame_offset)
  let size = mp3_side_info_size(header)
  if start < 0 || start + size > data.length() {
    let avail = if start >= data.length() { 0 } else { data.length() - start }
    raise AudioError::Truncated(offset=start, needed=size, available=avail)
  }
  let mpeg1 = header.version == Mp3Version::Mpeg1
  let channels = header.channels
  let reader = Mp3BitReader::new(data, start * 8)
  let main_data_begin = if mpeg1 {
    reader.read_bits(9)
  } else {
    reader.read_bits(8)
  }
  let private_bits = if channels == 1 {
    if mpeg1 {
      reader.read_bits(5)
    } else {
      reader.read_bits(1)
    }
  } else if mpeg1 {
    reader.read_bits(3)
  } else {
    reader.read_bits(2)
  }
  let scfsi : Array[Int] = []
  if mpeg1 {
    let mut c = 0
    while c < channels {
      scfsi.push(reader.read_bits(4))
      c = c + 1
    }
  }
  let granule_count = if mpeg1 { 2 } else { 1 }
  let granules : Array[Array[Mp3GranuleChannel]] = []
  let mut g = 0
  while g < granule_count {
    let per_channel : Array[Mp3GranuleChannel] = []
    let mut c = 0
    while c < channels {
      per_channel.push(mp3_read_granule_channel(reader, header.version))
      c = c + 1
    }
    granules.push(per_channel)
    g = g + 1
  }
  {
    version: header.version,
    channels,
    main_data_begin,
    private_bits,
    scfsi,
    granules,
  }
}

// ============================================================
// scalefactor band 表 / Huffman 区域划分
// ============================================================

///|
/// 长块 scalefactor band 边界表。
///
/// ⚠️ 只内置 44100 Hz。其余 8 种采样率（48000/32000/24000/22050/16000/
/// 12000/11025/8000，含 MPEG2/2.5 各自的表）没有经过验证的表数据，
/// 因此一律抛 `Unsupported`，不猜。
pub fn mp3_sfb_long(sample_rate : Int) -> Array[Int] raise AudioError {
  if sample_rate == 44100 {
    mp3_sfb_long_44100
  } else {
    raise AudioError::Unsupported(
      "mp3_sfb_long: 只内置了 44100 Hz 的 scalefactor band 表，收到 \{sample_rate} Hz",
    )
  }
}

///|
/// 短块 scalefactor band 边界表。
///
/// ⚠️ 同样只内置 44100 Hz，其余采样率抛 `Unsupported`。
pub fn mp3_sfb_short(sample_rate : Int) -> Array[Int] raise AudioError {
  if sample_rate == 44100 {
    mp3_sfb_short_44100
  } else {
    raise AudioError::Unsupported(
      "mp3_sfb_short: 只内置了 44100 Hz 的 scalefactor band 表，收到 \{sample_rate} Hz",
    )
  }
}

///|
/// 计算一个 granule 声道的两个 Huffman 区域分界（以系数下标计）：
/// `(region1_start, region2_start)`。
///
/// 规则（仅非窗口切换 granule）：
/// `region1_start = 2 * sfb_long[region0_count + 1]`，
/// `region2_start = 2 * sfb_long[region0_count + region1_count + 2]`。
///
/// ⚠️ 窗口切换（短块）granule 的区域划分本实现没有把握，抛 `Unsupported`，
/// 不写没验证过的常量。
pub fn mp3_huffman_regions(
  granule_channel : Mp3GranuleChannel,
  sample_rate : Int,
) -> (Int, Int) raise AudioError {
  if granule_channel.window_switching_flag != 0 {
    raise AudioError::Unsupported(
      "mp3_huffman_regions: 窗口切换（短块）granule 的区域划分未经验证，未实现",
    )
  }
  let sfb = mp3_sfb_long(sample_rate)
  let i1 = granule_channel.region0_count + 1
  let i2 = granule_channel.region0_count + granule_channel.region1_count + 2
  if i1 >= sfb.length() || i2 >= sfb.length() {
    raise AudioError::InvalidMagic(
      "mp3_huffman_regions: region0_count=\{granule_channel.region0_count} region1_count=\{granule_channel.region1_count} 越界（sfb 表只有 \{sfb.length()} 项）",
    )
  }
  (2 * sfb[i1], 2 * sfb[i2])
}

///|
/// 按系数下标选 Huffman 表号（`table_select[0..2]`）。
pub fn mp3_huffman_table_select(
  granule_channel : Mp3GranuleChannel,
  coefficient : Int,
  region1_start : Int,
  region2_start : Int,
) -> Int {
  if coefficient < region1_start {
    granule_channel.table_select[0]
  } else if coefficient < region2_start {
    granule_channel.table_select[1]
  } else {
    granule_channel.table_select[2]
  }
}

// ============================================================
// Huffman 表
// ============================================================

///|
/// ISO/IEC 11172-3 Table 3-B.7 中的 Huffman code table 1（4 个码字）。
///
/// ⚠️ **未经外部参考实现比对**。本仓库里没有任何真实 MP3 数据，这张表是
/// 按规范手写的。测试只能验证「它是完备前缀码、且解码器与它自洽」，
/// 无法验证它与标准逐位一致。因此它**不参与** `decode_mp3`。
let mp3_huffman_table_1 : Array[Mp3HuffmanEntry] = [
  { hlen: 1, hcod: 0b1, x: 0, y: 0, },
  { hlen: 3, hcod: 0b001, x: 0, y: 1, },
  { hlen: 2, hcod: 0b01, x: 1, y: 0, },
  { hlen: 3, hcod: 0b000, x: 1, y: 1, },
]

///|
/// 取 Huffman 表。目前**只内置表 1**。
///
/// MP3 一共 32 张 Huffman 表（表 0 表示「该区域无数据」），最大的表有 256 个
/// 码字。这些表数据无法在本仓库内验证，因此全部抛 `Unsupported`，
/// 而不是凭记忆写进去。
pub fn mp3_huffman_table(
  index : Int,
) -> Array[Mp3HuffmanEntry] raise AudioError {
  if index == 1 {
    mp3_huffman_table_1
  } else {
    raise AudioError::Unsupported(
      "mp3_huffman_table: 只内置了 Huffman 表 1，请求的是表 \{index}（其余 31 张表的数据未经验证，故意不内置）",
    )
  }
}

///|
/// 从位流中解出一个 `(x, y)` 值对，`reader` 的位置随之前进。
///
/// 逐位累积码字，直到与表中某项 `(hlen, hcod)` 完全匹配。
/// 码字超过表内最长码长仍无匹配则抛 `InvalidMagic`。
pub fn mp3_huffman_decode_pair(
  reader : Mp3BitReader,
  table_index : Int,
) -> (Int, Int) raise AudioError {
  let table = mp3_huffman_table(table_index)
  let mut max_len = 0
  for entry in table {
    if entry.hlen > max_len {
      max_len = entry.hlen
    }
  }
  if max_len == 0 {
    raise AudioError::InvalidMagic(
      "mp3_huffman_decode_pair: Huffman 表 \{table_index} 是空表",
    )
  }
  let mut code = 0
  let mut length = 0
  while length < max_len {
    code = (code << 1) | reader.read_bits(1)
    length = length + 1
    for entry in table {
      if entry.hlen == length && entry.hcod == code {
        return (entry.x, entry.y)
      }
    }
  }
  raise AudioError::InvalidMagic(
    "mp3_huffman_decode_pair: Huffman 表 \{table_index} 中没有匹配的码字（读了 \{length} 位）",
  )
}

// ============================================================
// 未实现的解码链
// ============================================================

///|
/// 把 MP3 解码为交织 16 位 PCM。
///
/// ⚠️ **本实现不能返回真实音频**。样本级解码链（scalefactor 解码、
/// 32 张 Huffman 表、count1 区域、requantization、stereo processing、
/// alias reduction、IMDCT、频率反转、多相合成滤波器组）未实现，
/// 因此本函数在完成结构性校验之后一律抛 `Unsupported`。
///
/// 之所以先做完整结构性校验：这样畸形输入仍然会得到准确的
/// `InvalidMagic` / `Truncated` / `Unsupported(保留值)`，而不是笼统的
/// "未实现"。宁可报得准，也不输出错误的样本。
pub fn decode_mp3(data : Bytes) -> Audio raise AudioError {
  let info = mp3_info(data)
  let frames = mp3_scan_frames(data)
  let offset = mp3_first_frame_offset(data)
  let header = mp3_parse_frame_header(data, offset)
  let side_info = mp3_parse_side_info(data, header, offset)
  ignore(info)
  ignore(frames.length())
  ignore(side_info.main_data_begin)
  raise AudioError::Unsupported(
    "MP3 样本级解码未实现。已完成：帧头解析、帧遍历与重同步、side info 解析、Huffman 区域划分。缺失：scalefactor 解码、Huffman 表 0/2..31 与 count1 区域、requantization、stereo processing（mid/side 与 intensity）、alias reduction、IMDCT、频率反转、多相合成滤波器组",
  )
}

///|
/// 不解码，只取格式信息（取第一条被确认的帧）。
///
/// MP3 解码输出固定为 16 位有符号 PCM；声道数由帧头的 channel mode 决定
/// （Mono → 1，其余 → 2）。
pub fn mp3_info(data : Bytes) -> AudioFormat raise AudioError {
  let offset = mp3_first_frame_offset(data)
  let header = mp3_parse_frame_header(data, offset)
  {
    sample_rate: header.sample_rate,
    channels: header.channels,
    bits_per_sample: 16,
  }
}

///|
/// 逐帧解码器。
///
/// ⚠️ **本实现无法返回可用的 `Decoder`**，直接抛 `Unsupported`：
/// `types.mbt` 中 `Decoder.state` 是 `priv`、`DecoderState::Mp3Decoder(Int)`
/// 只携带一个 `Int` 占位，装不下 `Bytes` 与游标；并且 `Decoder::next` /
/// `Decoder::format` 是冻结的占位实现（恒抛 `Unsupported`），本文件无权改。
/// 返回一个 `next()` 永远失败的句柄只会误导调用方，所以这里明确报不支持。
pub fn mp3_decoder(data : Bytes) -> Decoder raise AudioError {
  ignore(data)
  raise AudioError::Unsupported(
    "mp3_decoder 待接入：types.mbt 的 DecoderState::Mp3Decoder(Int) 只有一个 Int 占位，无法保存字节流与帧游标；且 Decoder::next/format 为冻结的占位实现",
  )
}
