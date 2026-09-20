// moonbit-music —— Vorbis I 解码器（接口契约 H 段）。
//
// ## 位读取方向：LSB-first（已按规范确认）
//
// Vorbis I 规范 §2.1.4 "coding bits into byte sequences"：
//   "the encoder begins by placing the LSb of the integer to be written into the least
//    significant unused bit position of the destination byte ... When all bits of the
//    destination byte have been filled, encoding continues by zeroing all bits of the next
//    byte and writing the next bit into the bit position 0 of that byte."
// 即：先写整数的低位，字节内从 bit0 往上填，填满再换下一个字节。这与 FLAC 的 MSB-first 相反。
// 本文件因此实现 LSB-first 读取器；`parse_vorbis_ident` 的两个测试用例
// （blocksize 字节 0x86 通过 / 0x68 报错、framing 字节 0x01 通过）能区分两种方向。
//
// ## 范围
//
// 本文件只用 `moonbitlang/core`（实际只用到 builtin 与 debug），不引用包内其他文件。
// 文件内私有符号统一带 `vorbis_` 前缀或用 `Vorbis*` 类型名。
//
// 已实现并测试：identification header、comment header、codebook（长度表 / 规范 Huffman 码字
// 分配 / VQ lookup / Vorbis 自定义浮点）、setup header 的完整结构校验。
// 未实现：音频包解码与合成（floor 曲线、residue、声道耦合、IMDCT、overlap-add）——
// `decode_vorbis` 在校验完 setup header 之后明确抛 `Unsupported`，不返回任何未经验证的音频。

// ---------------------------------------------------------------------------
// 资源上限（畸形输入防护）
// ---------------------------------------------------------------------------

///| 单个 codebook 的 entries 上限。字段本身是 24 位，这里再收紧一档。
const VORBIS_MAX_CODEBOOK_ENTRIES : Int = 4194304

///| 单个 codebook 的 VQ lookup 值个数上限。
const VORBIS_MAX_LOOKUP_VALUES : Int = 4194304

///| floor1 的 x 列表长度上限（规范规定最多 65 个元素）。
const VORBIS_MAX_FLOOR1_X : Int = 65

// ---------------------------------------------------------------------------
// LSB-first 位读取器
// ---------------------------------------------------------------------------

///|
/// LSB-first 位读取器。
///
/// 游标 = (`byte_pos`, `bit_pos`)，`bit_pos` ∈ [0, 7] 表示当前字节内已消费的位数。
/// 读取顺序是「字节 0 的 bit0、bit1 … bit7、字节 1 的 bit0 …」，第 i 个读到的位
/// 落在结果整数的第 i 位（低位在前）。因此 `read_bits(32)` 在字节对齐位置等价于
/// 读取一个 32 位小端无符号整数，`read_bits(8)` 等价于读一个字节。
///
/// 任何越界读取都抛 `AudioError::Truncated`，不做回绕、不 panic。
priv struct VorbisBitReader {
  data : Bytes
  mut byte_pos : Int
  mut bit_pos : Int
}

///|
/// 从 `data` 构造读取器，游标在 bit 0。
fn VorbisBitReader::new(data : Bytes) -> VorbisBitReader {
  VorbisBitReader::{ data, byte_pos: 0, bit_pos: 0 }
}

///|
/// 已消费的位数。
fn VorbisBitReader::bit_offset(self : VorbisBitReader) -> Int {
  self.byte_pos * 8 + self.bit_pos
}

///|
/// 剩余可读位数（可能为 0，不会为负）。
fn VorbisBitReader::bits_left(self : VorbisBitReader) -> Int {
  let total = self.data.length() * 8
  let used = self.bit_offset()
  if used >= total { 0 } else { total - used }
}

///|
/// 读 `n` 位（0 ≤ n ≤ 32），LSB-first。
///
/// `n == 0` 返回 0 且不移动游标（规范 §2.1.9）。`n == 32` 时结果是完整的 32 位位模式，
/// 最高位为 1 时按二进制补码是负数——需要「有符号 32 位」语义请用 `read_i32`。
fn VorbisBitReader::read_bits(self : VorbisBitReader, n : Int) -> Int raise AudioError {
  if n < 0 || n > 32 {
    raise AudioError::Unsupported("vorbis: 位读取宽度 \{n} 超出 0..32")
  }
  if n == 0 {
    return 0
  }
  let avail = self.bits_left()
  if avail < n {
    raise AudioError::Truncated(offset=self.byte_pos, needed=n, available=avail)
  }
  let mut result = 0
  let mut got = 0
  while got < n {
    let cur = self.data[self.byte_pos].to_int()
    let room = 8 - self.bit_pos
    let take = if n - got < room { n - got } else { room }
    let chunk = (cur >> self.bit_pos) & ((1 << take) - 1)
    result = result | (chunk << got)
    got = got + take
    self.bit_pos = self.bit_pos + take
    if self.bit_pos == 8 {
      self.bit_pos = 0
      self.byte_pos = self.byte_pos + 1
    }
  }
  result
}

///|
/// 读 32 位并解释为**有符号** 32 位整数（二进制补码），用于 bitrate 字段。
///
/// 不依赖宿主 `Int` 的宽度：先在 `Int64` 上取低 32 位，再按补码还原符号。
fn VorbisBitReader::read_i32(self : VorbisBitReader) -> Int raise AudioError {
  let raw = self.read_bits(32)
  let lo = raw.to_int64() & 4294967295L
  if lo >= 2147483648L {
    (lo - 4294967296L).to_int()
  } else {
    lo.to_int()
  }
}

///|
/// 读 1 位布尔标志。
fn VorbisBitReader::read_flag(self : VorbisBitReader) -> Bool raise AudioError {
  self.read_bits(1) == 1
}

///|
/// 跳过 `n` 位。
fn VorbisBitReader::skip_bits(self : VorbisBitReader, n : Int) -> Unit raise AudioError {
  let mut left = n
  while left > 0 {
    let step = if left > 32 { 32 } else { left }
    ignore(self.read_bits(step))
    left = left - step
  }
}

///|
/// 跳到下一个字节边界（已经对齐时不做任何事）。
fn VorbisBitReader::byte_align(self : VorbisBitReader) -> Unit raise AudioError {
  if self.bit_pos != 0 {
    ignore(self.read_bits(8 - self.bit_pos))
  }
}

///|
/// 跳过 `n` 个字节，要求当前位置已对齐。越界抛 `Truncated`。
fn VorbisBitReader::skip_bytes(self : VorbisBitReader, n : Int) -> Unit raise AudioError {
  if self.bit_pos != 0 {
    raise AudioError::Unsupported("vorbis: 内部错误——在非字节对齐位置跳字节")
  }
  let avail = self.bits_left() / 8
  if n > avail {
    raise AudioError::Truncated(offset=self.byte_pos, needed=n, available=avail)
  }
  self.byte_pos = self.byte_pos + n
}

///|
/// 读 n 个完整字节，要求当前位游标已经在字节边界。
///
/// 返回新分配的 `Bytes`，长度恰好为 n；越界抛 `Truncated`。
fn VorbisBitReader::read_bytes(self : VorbisBitReader, n : Int) -> Bytes raise AudioError {
  if self.bit_pos != 0 {
    raise AudioError::Unsupported("vorbis: read_bytes 需要在字节边界调用")
  }
  let avail = self.bits_left() / 8
  if n > avail {
    raise AudioError::Truncated(offset=self.byte_pos, needed=n, available=avail)
  }
  let out = Buffer()
  for i in 0..<n {
    out.write_byte(self.data[self.byte_pos + i])
  }
  self.byte_pos = self.byte_pos + n
  out.to_bytes()
}

///|
/// 把位游标复位到给定的字节+位偏移。用于「先试读，失败后回退」场景。
///
/// 越界抛 `Truncated`；但越界不会把游标放在非法状态，而是保持原值不变。
fn VorbisBitReader::seek(self : VorbisBitReader, byte : Int, bit : Int) -> Unit raise AudioError {
  if bit < 0 || bit > 7 {
    raise AudioError::Unsupported("vorbis: seek bit 必须属于 0..7，实际 \{bit}")
  }
  let total_bits = self.data.length() * 8
  let target = byte * 8 + bit
  if target > total_bits {
    raise AudioError::Truncated(offset=byte, needed=bit, available=total_bits - byte * 8)
  }
  self.byte_pos = byte
  self.bit_pos = bit
}

///|
/// 把当前 (byte, bit) 位置快照返回；与 `seek` 配合可实现事务式试读。
fn VorbisBitReader::snapshot(self : VorbisBitReader) -> (Int, Int) {
  (self.byte_pos, self.bit_pos)
}

///|
/// 读取一个无符号变长整数（Vorbis-style LEB128 风格：最多 32 位，7 位/字节，LSB 在先）。
///
/// 连续位模式：每字节低位在前，最高位是「后续还有字节」标志。读到有字节的最高位
/// 为 0 时结束。累计超过 32 位或读完整个数据流都没遇到终止字节时抛
/// `AudioError::LimitExceeded` / `Truncated`。
fn VorbisBitReader::read_uleb128(self : VorbisBitReader) -> Int raise AudioError {
  let mut result : Int64 = 0L
  let mut shift = 0
  loop {
    let byte = self.read_bits(8)
    let val = byte & 0x7F
    result = result | (val.to_int64() << shift)
    shift = shift + 7
    if (byte & 0x80) == 0 {
      break
    }
    if shift > 35 {
      raise AudioError::LimitExceeded("vorbis: uleb128 超过 32 位范围")
    }
  }
  if result > 2147483647L || result < -2147483648L {
    raise AudioError::LimitExceeded("vorbis: uleb128 溢出 Int32 范围")
  }
  result.to_int()
}

// ---------------------------------------------------------------------------
// 通用小工具
// ---------------------------------------------------------------------------

///|
/// 规范 §9.2.1 `ilog`：最高置位的位置（1..n）；`x <= 0` 返回 0。
fn vorbis_ilog(x : Int) -> Int {
  let mut v = x
  let mut r = 0
  while v > 0 {
    r = r + 1
    v = v >> 1
  }
  r
}

///|
/// 校验 7 字节 header 前缀：`[packet_type]` + "vorbis"。
///
/// 长度不足 7 抛 `Truncated`，前缀不匹配抛 `InvalidMagic`。
fn vorbis_check_prefix(data : Bytes, packet_type : Int, what : String) -> Unit raise AudioError {
  if data.length() < 7 {
    raise AudioError::Truncated(offset=0, needed=7, available=data.length())
  }
  let ok = data[0].to_int() == packet_type &&
    data[1] == b'v' &&
    data[2] == b'o' &&
    data[3] == b'r' &&
    data[4] == b'b' &&
    data[5] == b'i' &&
    data[6] == b's'
  if !ok {
    raise AudioError::InvalidMagic(
      "vorbis: \{what} header 魔数不匹配（首字节应是 \{packet_type}，后随 vorbis）",
    )
  }
}

///|
/// Vorbis 自定义 32 位浮点解包（规范 §9.2.2）：
/// ```
/// mantissa = x & 0x1fffff           (21 位)
/// sign     = x & 0x80000000         (1 位)
/// exponent = (x & 0x7fe00000) >> 21 (10 位)
/// 若 sign 非零则 mantissa 取负
/// 返回 mantissa * 2^(exponent - 788)
/// ```
/// 注意：不是「1 位符号 + 6 位指数 + 尾数」；指数是 10 位、尾数是 21 位，总共 32 位定长。
fn vorbis_float32_unpack(x : Int) -> Double {
  let v = x.to_int64() & 4294967295L
  let mantissa = (v & 2097151L).to_int()
  let negative = (v & 2147483648L) != 0L
  let exponent = ((v >> 21) & 1023L).to_int()
  let m = if negative { -mantissa } else { mantissa }
  vorbis_ldexp(m.to_double(), exponent - 788)
}

///|
/// `value * 2^exp`，用循环实现以避免依赖 `@math`（本包 moon.pkg 没有 import core/math）。
fn vorbis_ldexp(value : Double, exp : Int) -> Double {
  let mut r = value
  let mut e = exp
  while e > 0 {
    r = r * 2.0
    e = e - 1
  }
  while e < 0 {
    r = r / 2.0
    e = e + 1
  }
  r
}

///|
/// `base ^ exp <= limit` 是否成立（`Int64` 上运算，超限立即返回 false）。
fn vorbis_pow_within(base : Int, exp : Int, limit : Int64) -> Bool {
  let mut p : Int64 = 1
  for i = 0; i < exp; i = i + 1 {
    p = p * base.to_int64()
    if p > limit {
      return false
    }
  }
  true
}

///|
/// 规范 §9.2.3 `lookup1_values(entries, dimensions)`：
/// 满足 `r ^ dimensions <= entries` 的最大整数 `r`。
fn vorbis_lookup1_values(entries : Int, dimensions : Int) -> Int raise AudioError {
  if dimensions < 1 {
    raise AudioError::InvalidMagic("vorbis: lookup type 1 的 codebook 要求 dimensions >= 1")
  }
  let limit = entries.to_int64()
  let mut r = 1
  while vorbis_pow_within(r + 1, dimensions, limit) {
    r = r + 1
  }
  r
}

///|
/// 十六进制小写形式（24 位），仅用于错误信息。
fn vorbis_hex(v : Int) -> String {
  let digits = "0123456789abcdef"
  let mut out = ""
  let mut shift = 20
  while shift >= 0 {
    let d = (v >> shift) & 15
    out = out + digits[d:d + 1].to_owned()
    shift = shift - 4
  }
  out
}

///|
/// 把整数数组格式化成 `[1,2]` 形式，仅用于错误信息。
fn vorbis_int_list(values : Array[Int]) -> String {
  let mut out = "["
  for i = 0; i < values.length(); i = i + 1 {
    if i > 0 {
      out = out + ","
    }
    out = out + values[i].to_string()
  }
  out + "]"
}

///|
/// 把布尔数组格式化成 `[1,0]` 形式，仅用于错误信息。
fn vorbis_bool_list(values : Array[Bool]) -> String {
  let mut out = "["
  for i = 0; i < values.length(); i = i + 1 {
    if i > 0 {
      out = out + ","
    }
    out = out + (if values[i] { "1" } else { "0" })
  }
  out + "]"
}

// ---------------------------------------------------------------------------
// identification header
// ---------------------------------------------------------------------------

///|
/// Vorbis 流的基本信息。
///
/// `comments` 不由 identification header 提供（那里没有标签）：
/// `parse_vorbis_ident` 返回空数组，标签请用 `parse_vorbis_comment` 取。
pub(all) struct VorbisInfo {
  channels : Int
  sample_rate : Int
  bitrate_max : Int
  bitrate_nominal : Int
  bitrate_min : Int
  comments : Array[(String, String)]
} derive(Eq, @debug.Debug)

///|
/// blocksize 指数 → 实际块大小。Vorbis I 只允许 64..8192，即指数 6..13。
fn vorbis_blocksize(exp : Int) -> Int raise AudioError {
  if exp < 6 || exp > 13 {
    raise AudioError::Unsupported(
      "vorbis: blocksize 指数 \{exp}（= \{1 << exp}）超出 Vorbis I 允许的 64..8192",
    )
  }
  1 << exp
}

///|
/// 解析 identification header（含 `"\x01vorbis"` 前缀的完整 packet）。
///
/// 字段顺序：vorbis_version(32)、audio_channels(8)、audio_sample_rate(32)、
/// bitrate_maximum/nominal/minimum(各 32 位**有符号**)、blocksize_0/1(各 4 位，取 2 的幂)、
/// framing_flag(1 位，必须为 1)。
///
/// 错误映射：
/// - 前缀不对 → `InvalidMagic`；数据不足 → `Truncated`
/// - vorbis_version != 0 → `Unsupported`
/// - blocksize 指数不在 6..13（即不是 64..8192 的 2 的幂）→ `Unsupported`
/// - channels 或 sample_rate 非正、blocksize_0 > blocksize_1、framing_flag != 1 → `InvalidMagic`
pub fn parse_vorbis_ident(data : Bytes) -> VorbisInfo raise AudioError {
  vorbis_check_prefix(data, 1, "identification")
  let br = VorbisBitReader::new(data)
  br.skip_bits(56)
  let version = br.read_i32()
  if version != 0 {
    raise AudioError::Unsupported("vorbis: vorbis_version=\{version}，Vorbis I 要求为 0")
  }
  let channels = br.read_bits(8)
  let sample_rate = br.read_i32()
  let bitrate_max = br.read_i32()
  let bitrate_nominal = br.read_i32()
  let bitrate_min = br.read_i32()
  let blocksize_0_exp = br.read_bits(4)
  let blocksize_1_exp = br.read_bits(4)
  let framing = br.read_bits(1)
  if channels <= 0 {
    raise AudioError::InvalidMagic("vorbis: audio_channels 必须大于 0（读到 \{channels}）")
  }
  if sample_rate <= 0 {
    raise AudioError::InvalidMagic("vorbis: audio_sample_rate 必须大于 0（读到 \{sample_rate}）")
  }
  let blocksize_0 = vorbis_blocksize(blocksize_0_exp)
  let blocksize_1 = vorbis_blocksize(blocksize_1_exp)
  if blocksize_0 > blocksize_1 {
    raise AudioError::InvalidMagic(
      "vorbis: blocksize_0=\{blocksize_0} 大于 blocksize_1=\{blocksize_1}",
    )
  }
  if framing != 1 {
    raise AudioError::InvalidMagic("vorbis: identification header 的 framing_flag 未置位")
  }
  {
    channels,
    sample_rate,
    bitrate_max,
    bitrate_nominal,
    bitrate_min,
    comments: [],
  }
}

// ---------------------------------------------------------------------------
// comment header
// ---------------------------------------------------------------------------

///|
/// 解析 comment header（含 `"\x03vorbis"` 前缀），返回 `(vendor, comments)`。
///
/// 每条 comment 形如 `"KEY=VALUE"`，在**第一个** `=` 处按字节切分（不涉及字符串偏移语义）。
/// 没有 `=` 的条目整个作为 key、value 为空串；重复 key 原样保留、顺序不变。
/// vendor 与 value 按 UTF-8 直接转成 `String`（不校验、不替换，坏字节不会 panic）。
///
/// 规范要求结尾有一个必须为 1 的 framing bit：还有剩余位时读取并校验，
/// 若 packet 恰好在此结束（没有 framing bit）则容忍（少数工具产出的 packet 会省掉它）。
pub fn parse_vorbis_comment(data : Bytes) -> (String, Array[(String, String)]) raise AudioError {
  vorbis_check_prefix(data, 3, "comment")
  let br = VorbisBitReader::new(data)
  br.skip_bits(56)
  let vendor_len = vorbis_read_length(br, "vendor_length")
  let vendor = vorbis_read_utf8(data, br, vendor_len)
  let count = vorbis_read_length(br, "user_comment_list_length")
  let available_bytes = br.bits_left() / 8
  if count.to_int64() * 4L > available_bytes.to_int64() {
    raise AudioError::Truncated(offset=br.byte_pos, needed=count * 4, available=available_bytes)
  }
  let comments : Array[(String, String)] = []
  for i = 0; i < count; i = i + 1 {
    let len = vorbis_read_length(br, "comment length")
    br.byte_align()
    let start = br.byte_pos
    br.skip_bytes(len)
    comments.push(vorbis_split_comment(data, start, len))
  }
  if br.bits_left() > 0 && !br.read_flag() {
    raise AudioError::InvalidMagic("vorbis: comment header 的 framing bit 未置位")
  }
  (vendor, comments)
}

///|
/// 读一个 32 位长度字段。最高位为 1 视为非法（不可能是合法长度）→ `LimitExceeded`。
fn vorbis_read_length(br : VorbisBitReader, what : String) -> Int raise AudioError {
  let raw = br.read_i32()
  if raw < 0 {
    raise AudioError::LimitExceeded("vorbis: comment header 的 \{what}=\{raw} 非法（超过 2^31）")
  }
  raw
}

///|
/// 把 `data[start .. start+len)` 按 UTF-8 解码成 `String`。
///
/// 这里用 `@utf8.decode_lossy`，**不要**用 `Bytes::to_unchecked_string`：
/// 后者把字节当成 UTF-16 码元两两合并（实测 `b"ABC"` 会解成 2 个字符），
/// 会把 comment 文本全部弄乱。`decode_lossy` 对非法字节用替换字符，不抛错、不 panic。
/// `ignore_bom=false`：Vorbis comment 内容按 8 bit clean 原样保留，不吞 BOM。
fn vorbis_bytes_to_string(data : Bytes, start : Int, len : Int) -> String {
  @utf8.decode_lossy(data[start:start + len], ignore_bom=false)
}

///|
/// 读 `len` 个字节并转成 `String`（要求当前位置字节对齐）。
fn vorbis_read_utf8(data : Bytes, br : VorbisBitReader, len : Int) -> String raise AudioError {
  br.byte_align()
  let start = br.byte_pos
  br.skip_bytes(len)
  vorbis_bytes_to_string(data, start, len)
}

///|
/// 把 `data[start .. start+len)` 按第一个 `=` 切成 `(KEY, VALUE)`。
fn vorbis_split_comment(data : Bytes, start : Int, len : Int) -> (String, String) {
  let mut eq = -1
  let mut i = 0
  while i < len {
    if data[start + i] == b'=' {
      eq = i
      i = len
    } else {
      i = i + 1
    }
  }
  if eq < 0 {
    (vorbis_bytes_to_string(data, start, len), "")
  } else {
    (
      vorbis_bytes_to_string(data, start, eq),
      vorbis_bytes_to_string(data, start + eq + 1, len - eq - 1),
    )
  }
}

// ---------------------------------------------------------------------------
// codebook
// ---------------------------------------------------------------------------

///|
/// 解析完成的 codebook（内部表示）。
priv struct VorbisCodebook {
  dimensions : Int
  entries : Int
  ordered : Bool
  sparse : Bool
  lengths : Array[Int]
  codewords : Array[Int]
  lookup_type : Int
  minimum_value : Double
  delta_value : Double
  value_bits : Int
  sequence_p : Bool
  multiplicands : Array[Int]
}

///|
/// 单个 codebook 的可读描述。
///
/// 这是契约 H 段之外的**自检 / 调试接口**：`decode_vorbis` 内部走同一套解析逻辑，
/// 这里把它暴露出来，便于对 codebook 层做黑盒测试与故障排查。
/// `lengths[i] == 0` 表示该 entry 未使用；`codewords[i] == -1` 表示没有分配码字。
pub(all) struct VorbisCodebookInfo {
  dimensions : Int
  entries : Int
  ordered : Bool
  sparse : Bool
  lengths : Array[Int]
  codewords : Array[Int]
  lookup_type : Int
  minimum_value : Double
  delta_value : Double
  value_bits : Int
  sequence_p : Bool
  multiplicands : Array[Int]
} derive(@debug.Debug)

///|
/// 只解析 setup header 的 codebook 段（输入含 `"\x05vorbis"` 前缀），返回每个 codebook 的描述。
///
/// 供自检使用；正常解码请用 `decode_vorbis`。
pub fn parse_vorbis_setup_codebooks(setup : Bytes) -> Array[VorbisCodebookInfo] raise AudioError {
  vorbis_check_prefix(setup, 5, "setup")
  let br = VorbisBitReader::new(setup)
  br.skip_bits(56)
  let count = br.read_bits(8) + 1
  let books : Array[VorbisCodebookInfo] = []
  for i = 0; i < count; i = i + 1 {
    books.push(vorbis_parse_codebook(br).to_info())
  }
  books
}

///|
/// 内部表示 → 可读描述。
fn VorbisCodebook::to_info(self : VorbisCodebook) -> VorbisCodebookInfo {
  {
    dimensions: self.dimensions,
    entries: self.entries,
    ordered: self.ordered,
    sparse: self.sparse,
    lengths: self.lengths,
    codewords: self.codewords,
    lookup_type: self.lookup_type,
    minimum_value: self.minimum_value,
    delta_value: self.delta_value,
    value_bits: self.value_bits,
    sequence_p: self.sequence_p,
    multiplicands: self.multiplicands,
  }
}

///|
/// 解析一个 codebook（规范 §3.2.1）。
///
/// 顺序：24 位 sync `0x564342` → dimensions(16) → entries(24) → ordered(1) →
/// 长度表（ordered：初始长度 5 位 +1，然后每轮读 ilog(剩余 entry) 位作为个数；
/// 非 ordered：sparse(1)，随后每个 entry 读 present(1)（仅 sparse）与 5 位长度 +1）→
/// lookup_type(4) → 若 lookup 非 0：minimum_value(32)、delta_value(32) 两个 Vorbis 浮点、
/// value_bits(4)+1、sequence_p(1)，再读 lookup 值表。
///
/// 同时做规范要求的 Huffman 树合法性校验：过指定（码字溢出）与欠指定（Kraft 和不足）
/// 都抛 `InvalidMagic`；单 entry codebook 按 errata 20150226 特例容忍（但要求长度为 1）。
fn vorbis_parse_codebook(br : VorbisBitReader) -> VorbisCodebook raise AudioError {
  let sync = br.read_bits(24)
  if sync != 0x564342 {
    raise AudioError::InvalidMagic(
      "vorbis: codebook 同步字应为 0x564342，读到 0x\{vorbis_hex(sync)}",
    )
  }
  let dimensions = br.read_bits(16)
  let entries = br.read_bits(24)
  if entries <= 0 {
    raise AudioError::InvalidMagic("vorbis: codebook entries 为 0")
  }
  if entries > VORBIS_MAX_CODEBOOK_ENTRIES {
    raise AudioError::LimitExceeded(
      "vorbis: codebook entries=\{entries} 超过上限 \{VORBIS_MAX_CODEBOOK_ENTRIES}",
    )
  }
  let ordered = br.read_flag()
  let lengths = Array::make(entries, 0)
  let mut sparse = false
  if ordered {
    let mut current_entry = 0
    let mut current_length = br.read_bits(5) + 1
    while current_entry < entries {
      if current_length > 32 {
        raise AudioError::InvalidMagic("vorbis: ordered codebook 的码字长度超过 32")
      }
      let number = br.read_bits(vorbis_ilog(entries - current_entry))
      if current_entry + number > entries {
        raise AudioError::InvalidMagic("vorbis: ordered codebook 长度表写越界")
      }
      for i = current_entry; i < current_entry + number; i = i + 1 {
        lengths[i] = current_length
      }
      current_entry = current_entry + number
      current_length = current_length + 1
    }
  } else {
    sparse = br.read_flag()
    for i = 0; i < entries; i = i + 1 {
      if sparse {
        if br.read_flag() {
          lengths[i] = br.read_bits(5) + 1
        } else {
          lengths[i] = 0
        }
      } else {
        lengths[i] = br.read_bits(5) + 1
      }
    }
  }
  let codewords = vorbis_assign_codewords(lengths)
  let lookup_type = br.read_bits(4)
  if lookup_type > 2 {
    raise AudioError::Unsupported("vorbis: codebook lookup_type=\{lookup_type} 为保留值（>2）")
  }
  let mut minimum_value = 0.0
  let mut delta_value = 0.0
  let mut value_bits = 0
  let mut sequence_p = false
  let multiplicands : Array[Int] = []
  if lookup_type != 0 {
    minimum_value = vorbis_float32_unpack(br.read_i32())
    delta_value = vorbis_float32_unpack(br.read_i32())
    value_bits = br.read_bits(4) + 1
    sequence_p = br.read_flag()
    let lookup_values = if lookup_type == 1 {
      vorbis_lookup1_values(entries, dimensions)
    } else {
      let product = entries.to_int64() * dimensions.to_int64()
      if product > VORBIS_MAX_LOOKUP_VALUES.to_int64() {
        raise AudioError::LimitExceeded(
          "vorbis: lookup type 2 的值表大小 \{product} 超过上限 \{VORBIS_MAX_LOOKUP_VALUES}",
        )
      }
      product.to_int()
    }
    if lookup_values > VORBIS_MAX_LOOKUP_VALUES {
      raise AudioError::LimitExceeded(
        "vorbis: lookup 值表大小 \{lookup_values} 超过上限 \{VORBIS_MAX_LOOKUP_VALUES}",
      )
    }
    for i = 0; i < lookup_values; i = i + 1 {
      multiplicands.push(br.read_bits(value_bits))
    }
  }
  {
    dimensions,
    entries,
    ordered,
    sparse,
    lengths,
    codewords,
    lookup_type,
    minimum_value,
    delta_value,
    value_bits,
    sequence_p,
    multiplicands,
  }
}

///|
/// 规范 Huffman 码字分配（等价于 libvorbis `_make_words`）：按 entry 顺序，
/// 每个使用中的 entry 取「该长度下数值最小、且不与此前分配的码字互为前缀」的码字。
///
/// 规范 §3.2.1 给出的例子（长度 [2,4,4,4,4,2,3,3]）对应码字
/// 00、0100、0101、0110、0111、10、110、111——注意 entry5 是 10 而不是 01，
/// 因为以 01 为前缀的 0100..0111 已被占用。该例子的断言见 `vorbis_test.mbt`。
///
/// 返回与 `lengths` 等长的码字数组（未使用的 entry 为 -1）。校验：
/// - 码字溢出（过指定）→ `InvalidMagic`
/// - 使用中的 entry 数为 0 → `InvalidMagic`
/// - Kraft 和 != 1（欠指定），单 entry 特例除外 → `InvalidMagic`
fn vorbis_assign_codewords(lengths : Array[Int]) -> Array[Int] raise AudioError {
  let n = lengths.length()
  let codewords = Array::make(n, -1)
  let marker = Array::make(33, 0)
  let mut used = 0
  for i = 0; i < n; i = i + 1 {
    let len = lengths[i]
    if len > 0 {
      if len > 32 {
        raise AudioError::Unsupported("vorbis: codebook 码字长度 \{len} 超过 32")
      }
      let entry = marker[len]
      if len < 32 && (entry >> len) != 0 {
        raise AudioError::InvalidMagic("vorbis: Huffman 树过指定（码字溢出）")
      }
      codewords[i] = entry
      used = used + 1
      // 把本节点占用的路径向上标记，必要时进位到更短的层级
      let mut j = len
      while j > 0 {
        if (marker[j] & 1) == 1 {
          if j == 1 {
            marker[1] = marker[1] + 1
          } else {
            marker[j] = marker[j - 1] << 1
          }
          j = 0
        } else {
          marker[j] = marker[j] + 1
          j = j - 1
        }
      }
      // 剪枝：把所有挂在刚被占用节点下面的长码字标记重新挂到新节点上
      let mut k = len + 1
      let mut cur = entry
      while k <= 32 {
        if (marker[k] >> 1) == cur {
          cur = marker[k]
          marker[k] = marker[k - 1] << 1
          k = k + 1
        } else {
          k = 33
        }
      }
    }
  }
  if used == 0 {
    raise AudioError::InvalidMagic("vorbis: codebook 没有任何可用 entry")
  }
  if used == 1 {
    // errata 20150226：单 entry codebook 允许存在，但码字长度必须是 1
    for i = 0; i < n; i = i + 1 {
      if lengths[i] > 0 && lengths[i] != 1 {
        raise AudioError::InvalidMagic(
          "vorbis: 单 entry codebook 的码字长度必须是 1，读到 \{lengths[i]}",
        )
      }
    }
  } else {
    // Kraft 和：sum(2^(32-len)) 必须恰好等于 2^32，否则树不完整
    let mut kraft : Int64 = 0
    for i = 0; i < n; i = i + 1 {
      if lengths[i] > 0 {
        kraft = kraft + (1L << (32 - lengths[i]))
      }
    }
    if kraft != 4294967296L {
      raise AudioError::InvalidMagic("vorbis: Huffman 树欠指定（Kraft 和不等于 1）")
    }
  }
  codewords
}

// ---------------------------------------------------------------------------
// setup header 校验
// ---------------------------------------------------------------------------
//
// 注意：这里只做**结构与范围校验**（同时把游标推进到正确位置），不保留解析结果。
// 原因是音频包解码尚未实现，保留 floor/residue/mapping/mode 的完整配置会成为无人读取的
// 死状态。等音频路径接入时，把 vorbis_validate_* 换成 vorbis_parse_*（返回配置结构）即可。

///|
/// setup header 校验结果的摘要——`decode_vorbis` 用它构造错误信息，也便于排查问题。
priv struct VorbisSetupSummary {
  codebook_count : Int
  floor_types : Array[Int]
  residue_types : Array[Int]
  mapping_count : Int
  mode_count : Int
  mode_blockflags : Array[Bool]
}

///|
/// 校验 setup header 的全部结构：codebooks → time domain transforms（占位，必须为 0）
/// → floors → residues → mappings → modes → framing bit。
///
/// `channels` 来自 identification header（mapping 的耦合与 mux 解析需要它）。
/// 任何结构非法都抛出对应错误，绝不静默跳过。
fn vorbis_parse_setup(setup : Bytes, channels : Int) -> VorbisSetupSummary raise AudioError {
  vorbis_check_prefix(setup, 5, "setup")
  if channels <= 0 {
    raise AudioError::InvalidMagic("vorbis: audio_channels 必须大于 0（读到 \{channels}）")
  }
  let br = VorbisBitReader::new(setup)
  br.skip_bits(56)
  // codebooks
  let codebook_count = br.read_bits(8) + 1
  let codebooks : Array[VorbisCodebook] = []
  for i = 0; i < codebook_count; i = i + 1 {
    codebooks.push(vorbis_parse_codebook(br))
  }
  // time domain transforms（Vorbis I 占位，必须为 0）
  let time_count = br.read_bits(6) + 1
  for i = 0; i < time_count; i = i + 1 {
    let t = br.read_bits(16)
    if t != 0 {
      raise AudioError::InvalidMagic("vorbis: time domain transform 类型 \{t} 非 0（Vorbis I 占位）")
    }
  }
  // floors
  let floor_count = br.read_bits(6) + 1
  let floor_types : Array[Int] = []
  for i = 0; i < floor_count; i = i + 1 {
    let floor_type = br.read_bits(16)
    if floor_type == 0 {
      vorbis_validate_floor0(br, codebook_count)
    } else if floor_type == 1 {
      vorbis_validate_floor1(br, codebook_count)
    } else {
      raise AudioError::Unsupported("vorbis: floor 类型 \{floor_type} 不存在（Vorbis I 只有 0/1）")
    }
    floor_types.push(floor_type)
  }
  // residues
  let residue_count = br.read_bits(6) + 1
  let residue_types : Array[Int] = []
  for i = 0; i < residue_count; i = i + 1 {
    let residue_type = br.read_bits(16)
    if residue_type > 2 {
      raise AudioError::Unsupported(
        "vorbis: residue 类型 \{residue_type} 不存在（Vorbis I 只有 0/1/2）",
      )
    }
    vorbis_validate_residue(br, codebooks)
    residue_types.push(residue_type)
  }
  // mappings
  let mapping_count = br.read_bits(6) + 1
  for i = 0; i < mapping_count; i = i + 1 {
    vorbis_validate_mapping(br, channels, floor_count, residue_count)
  }
  // modes
  let mode_count = br.read_bits(6) + 1
  let mode_blockflags : Array[Bool] = []
  for i = 0; i < mode_count; i = i + 1 {
    let blockflag = br.read_flag()
    let windowtype = br.read_bits(16)
    let transformtype = br.read_bits(16)
    let mapping = br.read_bits(8)
    if windowtype != 0 {
      raise AudioError::InvalidMagic("vorbis: mode windowtype=\{windowtype} 非 0")
    }
    if transformtype != 0 {
      raise AudioError::InvalidMagic("vorbis: mode transformtype=\{transformtype} 非 0")
    }
    if mapping >= mapping_count {
      raise AudioError::InvalidMagic(
        "vorbis: mode 引用了不存在的 mapping \{mapping}（共 \{mapping_count} 个）",
      )
    }
    mode_blockflags.push(blockflag)
  }
  let framing = br.read_bits(1)
  if framing != 1 {
    raise AudioError::InvalidMagic("vorbis: setup header 的 framing bit 未置位")
  }
  { codebook_count, floor_types, residue_types, mapping_count, mode_count, mode_blockflags }
}

///|
/// floor 0 header decode 的校验（规范 §6.2.1）：
/// order(8)、rate(16)、bark_map_size(16)、amplitude_bits(6)、amplitude_offset(8)、
/// number_of_books(4)+1，随后每本书 8 位的 book_list（必须落在已配置的 codebook 内）。
fn vorbis_validate_floor0(br : VorbisBitReader, codebook_count : Int) -> Unit raise AudioError {
  ignore(br.read_bits(8)) // floor0_order
  ignore(br.read_bits(16)) // floor0_rate
  ignore(br.read_bits(16)) // floor0_bark_map_size
  ignore(br.read_bits(6)) // floor0_amplitude_bits
  ignore(br.read_bits(8)) // floor0_amplitude_offset
  let book_count = br.read_bits(4) + 1
  for i = 0; i < book_count; i = i + 1 {
    let b = br.read_bits(8)
    if b >= codebook_count {
      raise AudioError::InvalidMagic(
        "vorbis: floor0 book_list[\{i}]=\{b} 超出 codebook 数量 \{codebook_count}",
      )
    }
  }
}

///|
/// floor 1 header decode 的校验（规范 §7.2.2）：
/// partitions(5)、每个 partition 的 class(4)、每个 class 的 dimensions(3)+1、
/// subclasses(2)、masterbook(8，仅 subclasses != 0)、subclass books(各 8 位)，
/// 然后 multiplier(2)+1、rangebits(4) 与 partition 展开出的 x 列表。
///
/// 校验：masterbook / subclass book 必须落在已配置的 codebook 内、
/// x 列表最多 65 个元素且互不相同。
fn vorbis_validate_floor1(br : VorbisBitReader, codebook_count : Int) -> Unit raise AudioError {
  let partitions = br.read_bits(5)
  let partition_class_list = Array::make(partitions, 0)
  let mut maximum_class = -1
  for i = 0; i < partitions; i = i + 1 {
    let c = br.read_bits(4)
    partition_class_list[i] = c
    if c > maximum_class {
      maximum_class = c
    }
  }
  let class_count = maximum_class + 1
  let class_dimensions = Array::make(class_count, 0)
  for i = 0; i < class_count; i = i + 1 {
    class_dimensions[i] = br.read_bits(3) + 1
    let subclasses = br.read_bits(2)
    if subclasses != 0 {
      let master = br.read_bits(8)
      if master >= codebook_count {
        raise AudioError::InvalidMagic(
          "vorbis: floor1 masterbook=\{master} 超出 codebook 数量 \{codebook_count}",
        )
      }
    }
    for j = 0; j < (1 << subclasses); j = j + 1 {
      let raw = br.read_bits(8)
      // 规范：读 8 位后减一；0 减一后为 -1，表示该子类不使用 codebook
      if raw != 0 && raw - 1 >= codebook_count {
        raise AudioError::InvalidMagic(
          "vorbis: floor1 subclass book=\{raw - 1} 超出 codebook 数量 \{codebook_count}",
        )
      }
    }
  }
  ignore(br.read_bits(2)) // floor1_multiplier（值本身不影响结构校验）
  let rangebits = br.read_bits(4)
  let x_list : Array[Int] = [0, 1 << rangebits]
  for i = 0; i < partitions; i = i + 1 {
    let dim = class_dimensions[partition_class_list[i]]
    for j = 0; j < dim; j = j + 1 {
      if x_list.length() >= VORBIS_MAX_FLOOR1_X {
        raise AudioError::InvalidMagic("vorbis: floor1 x 列表超过 \{VORBIS_MAX_FLOOR1_X} 个元素")
      }
      x_list.push(br.read_bits(rangebits))
    }
  }
  for i = 0; i < x_list.length(); i = i + 1 {
    for j = i + 1; j < x_list.length(); j = j + 1 {
      if x_list[i] == x_list[j] {
        raise AudioError::InvalidMagic("vorbis: floor1 x 列表存在重复值 \{x_list[i]}")
      }
    }
  }
}

///|
/// residue header decode 的校验（规范 §8.6.1），三种 residue 类型共用：
/// begin(24)、end(24)、partition_size(24)+1、classifications(6)+1、classbook(8)、
/// 每类的 cascade（3 位 + 可选 5 位）与按 cascade 位图读出的 residue books（各 8 位）。
///
/// 校验：classbook 与所有 residue book 必须落在 codebook 范围内；
/// residue book 用到的 codebook 必须有 VQ lookup（lookup_type != 0）；
/// `classifications ^ classbook.dimensions` 不得超过 classbook.entries。
fn vorbis_validate_residue(
  br : VorbisBitReader,
  codebooks : Array[VorbisCodebook],
) -> Unit raise AudioError {
  let codebook_count = codebooks.length()
  ignore(br.read_bits(24)) // residue_begin
  ignore(br.read_bits(24)) // residue_end
  ignore(br.read_bits(24)) // residue_partition_size - 1
  let classifications = br.read_bits(6) + 1
  let classbook = br.read_bits(8)
  if classbook >= codebook_count {
    raise AudioError::InvalidMagic(
      "vorbis: residue classbook=\{classbook} 超出 codebook 数量 \{codebook_count}",
    )
  }
  let classifier = codebooks[classbook]
  if !vorbis_pow_within(classifications, classifier.dimensions, classifier.entries.to_int64()) {
    raise AudioError::InvalidMagic(
      "vorbis: residue classifications^dimensions 超过 classbook 的 entries 数",
    )
  }
  let cascade = Array::make(classifications, 0)
  for i = 0; i < classifications; i = i + 1 {
    let low_bits = br.read_bits(3)
    let high_bits = if br.read_flag() { br.read_bits(5) } else { 0 }
    cascade[i] = high_bits * 8 + low_bits
  }
  for i = 0; i < classifications; i = i + 1 {
    for j = 0; j < 8; j = j + 1 {
      if ((cascade[i] >> j) & 1) == 1 {
        let b = br.read_bits(8)
        if b >= codebook_count {
          raise AudioError::InvalidMagic(
            "vorbis: residue book=\{b} 超出 codebook 数量 \{codebook_count}",
          )
        }
        if codebooks[b].lookup_type == 0 {
          raise AudioError::InvalidMagic(
            "vorbis: residue 使用的 codebook \{b} 没有 VQ lookup（lookup_type == 0）",
          )
        }
      }
    }
  }
}

///|
/// mapping header decode 的校验（规范 §4.2.4 Mappings）。Vorbis I 只允许 mapping 类型 0。
///
/// 校验：耦合的 magnitude/angle 必须互不相同且不越界；reserved 字段必须为 0；
/// submaps 大于 1 时 mux 必须落在 submap 范围内；
/// 每个 submap 的 floor / residue 编号必须在已配置范围内。
fn vorbis_validate_mapping(
  br : VorbisBitReader,
  channels : Int,
  floor_count : Int,
  residue_count : Int,
) -> Unit raise AudioError {
  let mapping_type = br.read_bits(16)
  if mapping_type != 0 {
    raise AudioError::Unsupported("vorbis: mapping 类型 \{mapping_type} 非 0（Vorbis I 只有 0）")
  }
  let submaps = if br.read_flag() { br.read_bits(4) + 1 } else { 1 }
  let coupling_steps = if br.read_flag() { br.read_bits(8) + 1 } else { 0 }
  let bits = vorbis_ilog(channels - 1)
  for i = 0; i < coupling_steps; i = i + 1 {
    let m = br.read_bits(bits)
    let a = br.read_bits(bits)
    if a == m {
      raise AudioError::InvalidMagic("vorbis: coupling 的 magnitude 与 angle 相同（\{m}）")
    }
    if m >= channels || a >= channels {
      raise AudioError::InvalidMagic(
        "vorbis: coupling 声道号越界（magnitude=\{m} angle=\{a}，共 \{channels} 声道）",
      )
    }
  }
  let reserved = br.read_bits(2)
  if reserved != 0 {
    raise AudioError::InvalidMagic("vorbis: mapping reserved 字段为 \{reserved}（应为 0）")
  }
  if submaps > 1 {
    for i = 0; i < channels; i = i + 1 {
      let v = br.read_bits(4)
      if v >= submaps {
        raise AudioError::InvalidMagic(
          "vorbis: mapping mux[\{i}]=\{v} 超出 submap 数量 \{submaps}",
        )
      }
    }
  }
  for i = 0; i < submaps; i = i + 1 {
    ignore(br.read_bits(8)) // 未使用的 time configuration 占位
    let f = br.read_bits(8)
    if f >= floor_count {
      raise AudioError::InvalidMagic(
        "vorbis: submap \{i} 的 floor=\{f} 超出 floor 数量 \{floor_count}",
      )
    }
    let r = br.read_bits(8)
    if r >= residue_count {
      raise AudioError::InvalidMagic(
        "vorbis: submap \{i} 的 residue=\{r} 超出 residue 数量 \{residue_count}",
      )
    }
  }
}

// ---------------------------------------------------------------------------
// 解码入口
// ---------------------------------------------------------------------------

///|
/// 解码 Vorbis I。
///
/// 输入：identification header 解析出的 `info`、setup header packet（含 `"\x05vorbis"` 前缀）、
/// 三个 header 之后的全部音频 packet。
///
/// **当前实现程度（重要）**：本函数会完整解析并校验 setup header（codebook / floor /
/// residue / mapping / mode / framing），任何结构错误都抛出精确的 `AudioError`；
/// 但音频包解码与合成（floor 曲线、residue 解码、声道反耦合、IMDCT、overlap-add）
/// **尚未实现**，因此校验通过后一律抛
/// `Unsupported("vorbis: setup header 校验通过……音频包解码与合成尚未实现")`。
/// 也就是说本函数**永远不会返回音频数据**——调用方不会把未经验证的结果当成 PCM。
pub fn decode_vorbis(
  info : VorbisInfo,
  setup : Bytes,
  audio_packets : Array[Bytes],
) -> Audio raise AudioError {
  let parsed = vorbis_parse_setup(setup, info.channels)
  ignore(audio_packets)
  raise AudioError::Unsupported(
    "vorbis: setup header 校验通过（\{parsed.codebook_count} codebook、" +
    "floor 类型 \{vorbis_int_list(parsed.floor_types)}、" +
    "residue 类型 \{vorbis_int_list(parsed.residue_types)}、" +
    "\{parsed.mapping_count} mapping、" +
    "\{parsed.mode_count} mode blockflag \{vorbis_bool_list(parsed.mode_blockflags)}；" +
    "\{info.channels} 声道 \{info.sample_rate} Hz），但音频包解码与合成" +
    "（floor 曲线 / residue / 反耦合 / IMDCT / overlap-add）尚未实现",
  )
}
