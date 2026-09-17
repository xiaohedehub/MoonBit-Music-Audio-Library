// moonbit-music —— FLAC 无损解码器
//
// 实现范围：
//   * 元数据层：STREAMINFO / PADDING / APPLICATION / SEEKTABLE / VORBIS_COMMENT /
//     CUESHEET / PICTURE（未知类型跳过）。
//   * 帧层：固定与可变块大小两种 blocking strategy；CONSTANT / VERBATIM /
//     FIXED 0..4 / LPC 1..32 子帧；Rice（4 位参数）与 Rice2（5 位参数）残差；
//     独立 / 左+侧 / 右+侧 / 中+侧声道分配；帧头 CRC-8 与帧尾 CRC-16 校验；
//     STREAMINFO 的 MD5 校验。
//
// 本文件归 FLAC 代理独占，内部符号一律带 `Flac` / `flac_` 前缀，
// 避免与并行开发的其他文件（bitstream.mbt / checksum.mbt 等）重名。
// 只依赖 moonbitlang/core，无 FFI。
//
// 规范依据：xiph FLAC format.html 与 RFC 9639。

// ---------------------------------------------------------------------------
// 公开数据结构
// ---------------------------------------------------------------------------

///|
/// FLAC STREAMINFO 元数据块的内容。
///
/// 字段与规范一一对应；`md5` 为 16 字节原始摘要，全 0 表示编码器未填写。
pub(all) struct FlacStreamInfo {
  min_block_size : Int
  max_block_size : Int
  min_frame_size : Int
  max_frame_size : Int
  sample_rate : Int
  channels : Int
  bits_per_sample : Int
  total_samples : Int64
  md5 : Bytes
} derive(@debug.Debug)

///|
/// FLAC 流的全部元数据。
///
/// `comments` 中的键名已统一转成大写（Vorbis comment 的字段名大小写不敏感）；
/// `seektable` 按契约只保留每个 seek point 的样本号（占位点为 -1）。
pub(all) struct FlacMetadata {
  info : FlacStreamInfo
  comments : Array[(String, String)]
  seektable : Array[Int64]
  pictures : Array[Bytes]
} derive(@debug.Debug)

// ---------------------------------------------------------------------------
// 公共常量（`flac_` 前缀）
// ---------------------------------------------------------------------------

///|
/// FLAC 帧同步码的低 14 位（规范：`11111111111110`）。
let flac_sync_code : Int = 0x3FFE

// ---------------------------------------------------------------------------
// 字节读取小工具
// ---------------------------------------------------------------------------

///|
/// 断言 `data[off .. off+needed)` 可读，否则抛 `Truncated`。
fn flac_require(data : Bytes, off : Int, needed : Int) -> Unit raise AudioError {
  let len = data.length()
  if off < 0 || needed < 0 || off + needed > len {
    let available = if off < 0 || off > len { 0 } else { len - off }
    raise AudioError::Truncated(offset=off, needed=needed, available=available)
  }
}

///|
/// 复制 `data[start .. end)`。调用方必须先做边界检查。
fn flac_slice(data : Bytes, start : Int, end : Int) -> Bytes {
  let buf = Buffer()
  let mut i = start
  while i < end {
    buf.write_byte(data[i])
    i += 1
  }
  buf.to_bytes()
}

///|
/// 大端 16 位无符号。
fn flac_u16_be(data : Bytes, off : Int) -> Int raise AudioError {
  flac_require(data, off, 2)
  (data[off].to_int() << 8) | data[off + 1].to_int()
}

///|
/// 大端 24 位无符号。
fn flac_u24_be(data : Bytes, off : Int) -> Int raise AudioError {
  flac_require(data, off, 3)
  (data[off].to_int() << 16) | (data[off + 1].to_int() << 8) | data[off + 2].to_int()
}

///|
/// 大端 32 位。返回值是 32 位补码位型，最高位为 1 时结果为负，
/// 用于长度字段前必须先判负。
fn flac_u32_be(data : Bytes, off : Int) -> Int raise AudioError {
  flac_require(data, off, 4)
  (data[off].to_int() << 24) |
  (data[off + 1].to_int() << 16) |
  (data[off + 2].to_int() << 8) |
  data[off + 3].to_int()
}

///|
/// 大端 64 位。
fn flac_u64_be(data : Bytes, off : Int) -> Int64 raise AudioError {
  flac_require(data, off, 8)
  let mut v : Int64 = 0L
  let mut i = 0
  while i < 8 {
    v = (v << 8) | data[off + i].to_int().to_int64()
    i += 1
  }
  v
}

///|
/// 小端 32 位（Vorbis comment 的长度字段是唯一的小端例外）。
fn flac_u32_le(data : Bytes, off : Int) -> Int raise AudioError {
  flac_require(data, off, 4)
  data[off].to_int() |
  (data[off + 1].to_int() << 8) |
  (data[off + 2].to_int() << 16) |
  (data[off + 3].to_int() << 24)
}

///|
/// 读取 Vorbis comment 的 32 位小端长度，并保证它是非负数。
fn flac_u32_le_len(data : Bytes, off : Int) -> Int raise AudioError {
  let v = flac_u32_le(data, off)
  if v < 0 {
    raise AudioError::Truncated(offset=off, needed=4, available=data.length() - off)
  }
  v
}

// ---------------------------------------------------------------------------
// CRC-8 / CRC-16
// ---------------------------------------------------------------------------

///|
/// FLAC 帧头 CRC-8。
///
/// 多项式 `x^8 + x^2 + x + 1`（0x07），初值 0，非反射，无输出异或。
/// 已知答案：`"123456789"` → 0xF4（CRC-8 标准 check 值）。
fn flac_crc8(data : Bytes, start : Int, end : Int) -> Int {
  let mut crc = 0
  let mut i = start
  while i < end {
    crc = crc ^ data[i].to_int()
    let mut b = 0
    while b < 8 {
      if (crc & 0x80) != 0 {
        crc = ((crc << 1) ^ 0x07) & 0xFF
      } else {
        crc = (crc << 1) & 0xFF
      }
      b += 1
    }
    i += 1
  }
  crc
}

///|
/// FLAC 帧尾 CRC-16。
///
/// 多项式 `x^16 + x^15 + x^2 + 1`（0x8005），初值 0，非反射，无输出异或。
/// 已知答案：`"123456789"` → 0xFEE8（CRC-16/UMTS 标准 check 值）。
fn flac_crc16(data : Bytes, start : Int, end : Int) -> Int {
  let mut crc = 0
  let mut i = start
  while i < end {
    crc = crc ^ ((data[i].to_int() & 0xFF) << 8)
    let mut b = 0
    while b < 8 {
      if (crc & 0x8000) != 0 {
        crc = ((crc << 1) ^ 0x8005) & 0xFFFF
      } else {
        crc = (crc << 1) & 0xFFFF
      }
      b += 1
    }
    i += 1
  }
  crc
}

// ---------------------------------------------------------------------------
// MSB-first 位读取器
// ---------------------------------------------------------------------------

///|
/// FLAC 帧内部的 MSB-first 位读取器。
///
/// FLAC 的帧头是字节对齐的，但子帧（尤其是 Rice 残差）不是，
/// 因此需要一个可以停在任意 bit 位置的读取器。
priv struct FlacBitReader {
  data : Bytes
  mut byte_pos : Int
  mut bit_pos : Int
}

///|
/// 从 `data[pos]` 的 bit 0 开始读。
fn FlacBitReader::at(data : Bytes, pos : Int) -> FlacBitReader {
  { data, byte_pos: pos, bit_pos: 0 }
}

///|
/// 读 1 位。
fn FlacBitReader::read_bit(self : FlacBitReader) -> Int raise AudioError {
  if self.byte_pos >= self.data.length() {
    raise AudioError::Truncated(offset=self.byte_pos, needed=1, available=0)
  }
  let v = (self.data[self.byte_pos].to_int() >> (7 - self.bit_pos)) & 1
  self.bit_pos += 1
  if self.bit_pos == 8 {
    self.bit_pos = 0
    self.byte_pos += 1
  }
  v
}

///|
/// 读 `n` 位无符号（`0 <= n <= 32`），MSB first。
fn FlacBitReader::read_bits(self : FlacBitReader, n : Int) -> Int raise AudioError {
  if n <= 0 {
    return 0
  }
  if n > 32 {
    raise AudioError::Unsupported("FLAC 位字段超过 32 位：\{n}")
  }
  let mut result = 0
  let mut left = n
  while left > 0 {
    if self.byte_pos >= self.data.length() {
      raise AudioError::Truncated(offset=self.byte_pos, needed=1, available=0)
    }
    let avail = 8 - self.bit_pos
    let take = if left < avail { left } else { avail }
    let cur = self.data[self.byte_pos].to_int()
    let chunk = (cur >> (avail - take)) & ((1 << take) - 1)
    result = (result << take) | chunk
    self.bit_pos += take
    left -= take
    if self.bit_pos == 8 {
      self.bit_pos = 0
      self.byte_pos += 1
    }
  }
  result
}

///|
/// 读 `n` 位有符号（二进制补码）。
fn FlacBitReader::read_signed(self : FlacBitReader, n : Int) -> Int raise AudioError {
  if n <= 0 {
    return 0
  }
  let v = self.read_bits(n)
  if n >= 32 {
    return v
  }
  if (v & (1 << (n - 1))) != 0 {
    v - (1 << n)
  } else {
    v
  }
}

///|
/// 读一元码：数字 `q` 编码为 `q` 个 0 后跟 1 个 1，返回 `q`。
fn FlacBitReader::read_unary(self : FlacBitReader) -> Int raise AudioError {
  let mut count = 0
  while self.read_bit() == 0 {
    count += 1
  }
  count
}

///|
/// 读一个整字节。要求当前处于字节边界（FLAC 的 UTF-8 式变长整数是字节对齐的）。
fn FlacBitReader::read_byte_aligned(self : FlacBitReader) -> Int raise AudioError {
  if self.bit_pos != 0 {
    raise AudioError::InvalidMagic("FLAC 变长整数未按字节对齐")
  }
  if self.byte_pos >= self.data.length() {
    raise AudioError::Truncated(offset=self.byte_pos, needed=1, available=0)
  }
  let v = self.data[self.byte_pos].to_int()
  self.byte_pos += 1
  v
}

///|
/// 跳到下一个字节边界（丢弃不足一字节的填充位）。
fn FlacBitReader::align_to_byte(self : FlacBitReader) -> Unit {
  if self.bit_pos != 0 {
    self.bit_pos = 0
    self.byte_pos += 1
  }
}

///|
/// 读 FLAC 的 UTF-8 式变长整数（最多 7 字节 / 36 位，必须用 Int64）。
fn flac_read_utf8_number(br : FlacBitReader) -> Int64 raise AudioError {
  let b0 = br.read_byte_aligned()
  if (b0 & 0x80) == 0 {
    return b0.to_int64()
  }
  let mut n = 0
  let mut mask = 0x80
  while (b0 & mask) != 0 {
    n += 1
    mask = mask >> 1
  }
  if n < 2 || n > 7 {
    raise AudioError::InvalidMagic("FLAC 变长整数首字节非法：\{b0}")
  }
  let mut value = (b0 & ((1 << (7 - n)) - 1)).to_int64()
  let mut i = 1
  while i < n {
    let b = br.read_byte_aligned()
    if (b & 0xC0) != 0x80 {
      raise AudioError::InvalidMagic("FLAC 变长整数续字节非法：\{b}")
    }
    value = (value << 6) | (b & 0x3F).to_int64()
    i += 1
  }
  value
}

// ---------------------------------------------------------------------------
// UTF-8 → String（不依赖 moonbitlang/core/encoding/utf8，因为它不在 moon.pkg 的 import 里）
// ---------------------------------------------------------------------------

///|
/// 把 `data[start .. end)` 当作 UTF-8 解码成 String。
///
/// 非法序列替换成 U+FFFD。只用 `StringBuilder` + `Int::unsafe_to_char`，
/// 避免依赖本包 moon.pkg 未导入的编码子包。
/// （注意：`Buffer::write_char` 目前写的是 UTF-16LE，不能用来拼字符串。）
fn flac_utf8_to_string(data : Bytes, start : Int, end : Int) -> String {
  let buf = StringBuilder()
  let mut i = start
  while i < end {
    let b0 = data[i].to_int()
    let mut cp = 0xFFFD
    let mut size = 1
    if b0 < 0x80 {
      cp = b0
    } else if (b0 & 0xE0) == 0xC0 && i + 1 < end {
      cp = ((b0 & 0x1F) << 6) | (data[i + 1].to_int() & 0x3F)
      size = 2
    } else if (b0 & 0xF0) == 0xE0 && i + 2 < end {
      cp = ((b0 & 0x0F) << 12) |
        ((data[i + 1].to_int() & 0x3F) << 6) |
        (data[i + 2].to_int() & 0x3F)
      size = 3
    } else if (b0 & 0xF8) == 0xF0 && i + 3 < end {
      cp = ((b0 & 0x07) << 18) |
        ((data[i + 1].to_int() & 0x3F) << 12) |
        ((data[i + 2].to_int() & 0x3F) << 6) |
        (data[i + 3].to_int() & 0x3F)
      size = 4
    }
    if cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
      cp = 0xFFFD
    }
    buf.write_char(cp.unsafe_to_char())
    i += size
  }
  buf.to_string()
}

///|
/// 把字符串里的 ASCII 小写字母转成大写（Vorbis comment 字段名大小写不敏感）。
fn flac_ascii_upper(s : String) -> String {
  let buf = StringBuilder()
  for c in s {
    let v = c.to_int()
    if v >= 0x61 && v <= 0x7A {
      buf.write_char((v - 32).unsafe_to_char())
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

// ---------------------------------------------------------------------------
// 元数据解析
// ---------------------------------------------------------------------------

///|
/// STREAMINFO 块体（34 字节，不含 4 字节块头）。
fn flac_parse_streaminfo(data : Bytes, start : Int, blen : Int) -> FlacStreamInfo raise AudioError {
  if blen < 34 {
    raise AudioError::Truncated(offset=start, needed=34, available=blen)
  }
  flac_require(data, start, 34)
  let min_block_size = flac_u16_be(data, start)
  let max_block_size = flac_u16_be(data, start + 2)
  let min_frame_size = flac_u24_be(data, start + 4)
  let max_frame_size = flac_u24_be(data, start + 7)
  // 打包区：20 位 sample_rate + 3 位 (channels-1) + 5 位 (bps-1) + 36 位 total_samples
  let p = start + 10
  let b0 = data[p].to_int()
  let b1 = data[p + 1].to_int()
  let b2 = data[p + 2].to_int()
  let b3 = data[p + 3].to_int()
  let b4 = data[p + 4].to_int()
  let b5 = data[p + 5].to_int()
  let b6 = data[p + 6].to_int()
  let b7 = data[p + 7].to_int()
  let sample_rate = (b0 << 12) | (b1 << 4) | (b2 >> 4)
  let channels = ((b2 >> 1) & 0x07) + 1
  let bits_per_sample = (((b2 & 0x01) << 4) | (b3 >> 4)) + 1
  let total_samples = ((b3 & 0x0F).to_int64() << 32) |
    (b4.to_int64() << 24) |
    (b5.to_int64() << 16) |
    (b6.to_int64() << 8) |
    b7.to_int64()
  let md5 = flac_slice(data, start + 18, start + 34)
  {
    min_block_size,
    max_block_size,
    min_frame_size,
    max_frame_size,
    sample_rate,
    channels,
    bits_per_sample,
    total_samples,
    md5,
  }
}

///|
/// VORBIS_COMMENT 块体。注意所有长度字段都是**小端**。
///
/// 字段名统一转成大写后写入 `out`；没有 `=` 的字段整体作为键、值为空串。
fn flac_parse_vorbis_comment(
  data : Bytes,
  start : Int,
  end : Int,
  out : Array[(String, String)],
) -> Unit raise AudioError {
  let mut pos = start
  let vendor_len = flac_u32_le_len(data, pos)
  pos += 4
  if pos + vendor_len > end {
    raise AudioError::Truncated(offset=pos, needed=vendor_len, available=end - pos)
  }
  pos += vendor_len // vendor string 不保留
  let count = flac_u32_le_len(data, pos)
  pos += 4
  let mut i = 0
  while i < count {
    let flen = flac_u32_le_len(data, pos)
    pos += 4
    if pos + flen > end {
      raise AudioError::Truncated(offset=pos, needed=flen, available=end - pos)
    }
    let mut eq = -1
    let mut k = pos
    while k < pos + flen {
      if data[k] == b'=' {
        eq = k
        break
      }
      k += 1
    }
    if eq >= 0 {
      out.push((
        flac_ascii_upper(flac_utf8_to_string(data, pos, eq)),
        flac_utf8_to_string(data, eq + 1, pos + flen),
      ))
    } else {
      out.push((flac_ascii_upper(flac_utf8_to_string(data, pos, pos + flen)), ""))
    }
    pos += flen
    i += 1
  }
}

///|
/// SEEKTABLE 块体：每项 18 字节，只保留 sample_number（占位点 0xFFFF... 会变成 -1）。
fn flac_parse_seektable(
  data : Bytes,
  start : Int,
  end : Int,
  out : Array[Int64],
) -> Unit raise AudioError {
  let mut pos = start
  while pos + 18 <= end {
    out.push(flac_u64_be(data, pos))
    pos += 18
  }
}

///|
/// PICTURE 块体，返回最后的图片数据字节。
fn flac_parse_picture(data : Bytes, start : Int, end : Int) -> Bytes raise AudioError {
  let mut pos = start
  let _ptype = flac_u32_be(data, pos)
  pos += 4
  let mime_len = flac_u32_be(data, pos)
  pos += 4
  if mime_len < 0 || pos + mime_len > end {
    raise AudioError::Truncated(offset=pos, needed=mime_len, available=end - pos)
  }
  pos += mime_len
  let desc_len = flac_u32_be(data, pos)
  pos += 4
  if desc_len < 0 || pos + desc_len > end {
    raise AudioError::Truncated(offset=pos, needed=desc_len, available=end - pos)
  }
  pos += desc_len
  // width / height / depth / colors，共 16 字节，我们不需要
  if pos + 16 > end {
    raise AudioError::Truncated(offset=pos, needed=16, available=end - pos)
  }
  pos += 16
  let pic_len = flac_u32_be(data, pos)
  pos += 4
  if pic_len < 0 || pos + pic_len > end {
    raise AudioError::Truncated(offset=pos, needed=pic_len, available=end - pos)
  }
  flac_slice(data, pos, pos + pic_len)
}

///|
/// 扫描 `fLaC` 标记与整条元数据链。
///
/// 返回 `(streaminfo, comments, seektable, pictures, 第一个音频帧的偏移)`。
fn flac_scan_metadata(
  data : Bytes,
) -> (FlacStreamInfo, Array[(String, String)], Array[Int64], Array[Bytes], Int) raise AudioError {
  flac_require(data, 0, 4)
  if !(data[0] == b'f' && data[1] == b'L' && data[2] == b'a' && data[3] == b'C') {
    raise AudioError::InvalidMagic("FLAC 流必须以 \"fLaC\" 开头")
  }
  let comments : Array[(String, String)] = []
  let seektable : Array[Int64] = []
  let pictures : Array[Bytes] = []
  let mut info : FlacStreamInfo? = None
  let mut pos = 4
  let mut last = false
  while !last {
    flac_require(data, pos, 4)
    let b0 = data[pos].to_int()
    last = (b0 & 0x80) != 0
    let btype = b0 & 0x7F
    let blen = (data[pos + 1].to_int() << 16) |
      (data[pos + 2].to_int() << 8) |
      data[pos + 3].to_int()
    pos += 4
    flac_require(data, pos, blen)
    let body_start = pos
    let body_end = pos + blen
    if btype == 0 {
      info = Some(flac_parse_streaminfo(data, body_start, blen))
    } else if btype == 3 {
      flac_parse_seektable(data, body_start, body_end, seektable)
    } else if btype == 4 {
      flac_parse_vorbis_comment(data, body_start, body_end, comments)
    } else if btype == 6 {
      pictures.push(flac_parse_picture(data, body_start, body_end))
    }
    // 1=PADDING / 2=APPLICATION / 5=CUESHEET / 7..126=保留：整块跳过
    pos = body_end
  }
  match info {
    Some(i) => (i, comments, seektable, pictures, pos)
    None => raise AudioError::InvalidMagic("FLAC 流缺少 STREAMINFO 元数据块")
  }
}

// ---------------------------------------------------------------------------
// 帧头
// ---------------------------------------------------------------------------

///|
/// 解析后的 FLAC 帧头。
///
/// 帧号 / 首样本号（`coded_number`）与 blocking strategy 也解析了，
/// 但当前只有流式 seek 用得上，所以不放进结构体。
priv struct FlacFrameHeader {
  block_size : Int
  sample_rate : Int
  channels : Int
  channel_assignment : Int
  bits_per_sample : Int
  header_len : Int
}

///|
/// 解析一个帧头，并校验帧头 CRC-8。
///
/// `start` 是同步码第一个字节的位置。`info` 用于 sample rate / bit depth
/// 的 `0000` / `000` 回退。
fn flac_parse_frame_header(
  data : Bytes,
  start : Int,
  info : FlacStreamInfo,
) -> FlacFrameHeader raise AudioError {
  flac_require(data, start, 5)
  let br = FlacBitReader::at(data, start)
  let sync = br.read_bits(14)
  if sync != flac_sync_code {
    raise AudioError::InvalidMagic("FLAC 帧同步码不匹配")
  }
  if br.read_bit() != 0 {
    raise AudioError::InvalidMagic("FLAC 帧头保留位必须为 0")
  }
  // blocking strategy（0=固定块大小，1=可变）与 coded number 都要消费掉；
  // coded number 是固定块流的帧号或可变块流的首样本号，最多 36 位，必须用 Int64。
  let _blocking_strategy = br.read_bit()
  let bs_code = br.read_bits(4)
  let sr_code = br.read_bits(4)
  let ch_code = br.read_bits(4)
  let ss_code = br.read_bits(3)
  if br.read_bit() != 0 {
    raise AudioError::InvalidMagic("FLAC 帧头保留位必须为 0")
  }
  let _coded_number = flac_read_utf8_number(br)
  let mut block_size = 0
  if bs_code == 0 {
    // 旧版规范：从 STREAMINFO 取。RFC 9639 把 0b0000 标为保留，这里按旧版兼容处理。
    block_size = info.min_block_size
  } else if bs_code == 1 {
    block_size = 192
  } else if bs_code >= 2 && bs_code <= 5 {
    block_size = 576 << (bs_code - 2)
  } else if bs_code == 6 {
    block_size = br.read_bits(8) + 1
  } else if bs_code == 7 {
    block_size = br.read_bits(16) + 1
  } else {
    block_size = 1 << bs_code
  }
  if block_size <= 0 {
    raise AudioError::Unsupported("FLAC 帧块大小非法：\{block_size}")
  }
  if block_size > 65535 {
    raise AudioError::Unsupported("FLAC 帧块大小超过 65535：\{block_size}")
  }
  let mut sample_rate = 0
  if sr_code == 0 {
    sample_rate = info.sample_rate
  } else if sr_code == 1 {
    sample_rate = 88200
  } else if sr_code == 2 {
    sample_rate = 176400
  } else if sr_code == 3 {
    sample_rate = 192000
  } else if sr_code == 4 {
    sample_rate = 8000
  } else if sr_code == 5 {
    sample_rate = 16000
  } else if sr_code == 6 {
    sample_rate = 22050
  } else if sr_code == 7 {
    sample_rate = 24000
  } else if sr_code == 8 {
    sample_rate = 32000
  } else if sr_code == 9 {
    sample_rate = 44100
  } else if sr_code == 10 {
    sample_rate = 48000
  } else if sr_code == 11 {
    sample_rate = 96000
  } else if sr_code == 12 {
    sample_rate = br.read_bits(8) * 1000
  } else if sr_code == 13 {
    sample_rate = br.read_bits(16)
  } else if sr_code == 14 {
    sample_rate = br.read_bits(16) * 10
  } else {
    raise AudioError::Unsupported("FLAC 帧头 sample rate 位型 0b1111 被禁止")
  }
  let mut channels = 0
  if ch_code <= 7 {
    channels = ch_code + 1
  } else if ch_code <= 10 {
    channels = 2
  } else {
    raise AudioError::Unsupported("FLAC 帧头声道分配 0b\{ch_code} 为保留值")
  }
  let mut bits_per_sample = 0
  if ss_code == 0 {
    bits_per_sample = info.bits_per_sample
  } else if ss_code == 1 {
    bits_per_sample = 8
  } else if ss_code == 2 {
    bits_per_sample = 12
  } else if ss_code == 3 {
    raise AudioError::Unsupported("FLAC 帧头 bit depth 位型 0b011 为保留值")
  } else if ss_code == 4 {
    bits_per_sample = 16
  } else if ss_code == 5 {
    bits_per_sample = 20
  } else if ss_code == 6 {
    bits_per_sample = 24
  } else {
    bits_per_sample = 32
  }
  if bits_per_sample <= 0 || bits_per_sample > 32 {
    raise AudioError::Unsupported("FLAC 帧 bit depth 非法：\{bits_per_sample}")
  }
  if sample_rate <= 0 {
    raise AudioError::Unsupported("FLAC 帧头采样率非法")
  }
  if br.bit_pos != 0 {
    raise AudioError::InvalidMagic("FLAC 帧头未按字节对齐")
  }
  let crc_pos = br.byte_pos
  flac_require(data, crc_pos, 1)
  let stored = data[crc_pos].to_int()
  let computed = flac_crc8(data, start, crc_pos)
  if stored != computed {
    raise AudioError::ChecksumMismatch(expected=stored, actual=computed)
  }
  {
    block_size,
    sample_rate,
    channels,
    channel_assignment: ch_code,
    bits_per_sample,
    header_len: crc_pos + 1 - start,
  }
}

// ---------------------------------------------------------------------------
// 残差解码
// ---------------------------------------------------------------------------

///|
/// 反 zigzag：`folded = 2n` → `n`，`folded = -2n-1` → `n`。
fn flac_unzigzag(v : Int) -> Int {
  (v >> 1) ^ (-(v & 1))
}

///|
/// 解码 coded residual（FIXED 与 LPC 共用）。
///
/// 支持 method `00`（Rice，4 位参数）与 `01`（Rice2，5 位参数），
/// 以及每个分区的 escape（固定位宽原值）形式。
fn flac_decode_residual(
  br : FlacBitReader,
  block_size : Int,
  order : Int,
) -> Array[Int] raise AudioError {
  let method_code = br.read_bits(2)
  if method_code > 1 {
    raise AudioError::Unsupported("FLAC residual 编码方法 0b\{method_code} 为保留值")
  }
  let param_bits = if method_code == 0 { 4 } else { 5 }
  let escape = if method_code == 0 { 15 } else { 31 }
  let porder = br.read_bits(4)
  let partitions = 1 << porder
  if block_size % partitions != 0 {
    raise AudioError::Unsupported("FLAC residual 分区数不能整除块大小")
  }
  let psize = block_size / partitions
  if psize <= order {
    raise AudioError::Unsupported("FLAC residual 分区样本数不大于 predictor order")
  }
  let out = Array::make(block_size - order, 0)
  let mut idx = 0
  let mut p = 0
  while p < partitions {
    let n = if p == 0 { psize - order } else { psize }
    let param = br.read_bits(param_bits)
    if param == escape {
      let nbits = br.read_bits(5)
      let mut i = 0
      while i < n {
        out[idx] = if nbits == 0 { 0 } else { br.read_signed(nbits) }
        idx += 1
        i += 1
      }
    } else {
      let mut i = 0
      while i < n {
        let q = br.read_unary()
        let r = if param > 0 { br.read_bits(param) } else { 0 }
        out[idx] = flac_unzigzag((q << param) | r)
        idx += 1
        i += 1
      }
    }
    p += 1
  }
  out
}

// ---------------------------------------------------------------------------
// 子帧解码
// ---------------------------------------------------------------------------

///|
/// 二项式系数 C(n, k)（n 很小，逐次乘除即可精确）。
fn flac_binomial(n : Int, k : Int) -> Int {
  let mut r = 1
  let mut i = 0
  while i < k {
    r = r * (n - i) / (i + 1)
    i += 1
  }
  r
}

///|
/// FIXED 预测器的第 `j` 阶系数：`(-1)^(j+1) * C(order, j)`。
fn flac_fixed_coef(order : Int, j : Int) -> Int {
  let c = flac_binomial(order, j)
  if j % 2 == 1 {
    c
  } else {
    -c
  }
}

///|
/// CONSTANT 子帧。
fn flac_decode_constant(
  br : FlacBitReader,
  block_size : Int,
  bps : Int,
) -> Array[Int] raise AudioError {
  Array::make(block_size, br.read_signed(bps))
}

///|
/// VERBATIM 子帧。
fn flac_decode_verbatim(
  br : FlacBitReader,
  block_size : Int,
  bps : Int,
) -> Array[Int] raise AudioError {
  let out = Array::make(block_size, 0)
  let mut i = 0
  while i < block_size {
    out[i] = br.read_signed(bps)
    i += 1
  }
  out
}

///|
/// FIXED 子帧（order 0..4）：先读 order 个 warmup 样本，再读残差，
/// 然后用固定多项式逐样本还原。
fn flac_decode_fixed(
  br : FlacBitReader,
  block_size : Int,
  bps : Int,
  order : Int,
) -> Array[Int] raise AudioError {
  if order >= block_size {
    raise AudioError::InvalidMagic("FLAC FIXED 预测阶数不小于块大小")
  }
  let out = Array::make(block_size, 0)
  let mut i = 0
  while i < order {
    out[i] = br.read_signed(bps)
    i += 1
  }
  let residual = flac_decode_residual(br, block_size, order)
  let mut n = order
  while n < block_size {
    let mut pred = 0
    let mut j = 1
    while j <= order {
      pred = pred + flac_fixed_coef(order, j) * out[n - j]
      j += 1
    }
    out[n] = residual[n - order] + pred
    n += 1
  }
  out
}

///|
/// LPC 子帧（order 1..32）。
///
/// 系数精度字段是 `(precision - 1)`，`0b1111` 是禁止值（规范明确禁止），
/// 因此 precision 的取值范围是 1..15。shift 是 5 位补码：
/// 规范要求非负（`sum >> shift`）；若遇到历史流里的负值，我们按左移处理。
fn flac_decode_lpc(
  br : FlacBitReader,
  block_size : Int,
  bps : Int,
  order : Int,
) -> Array[Int] raise AudioError {
  if order >= block_size {
    raise AudioError::InvalidMagic("FLAC LPC 预测阶数不小于块大小")
  }
  let out = Array::make(block_size, 0)
  let mut i = 0
  while i < order {
    out[i] = br.read_signed(bps)
    i += 1
  }
  let prec_field = br.read_bits(4)
  if prec_field == 15 {
    raise AudioError::Unsupported("FLAC LPC 系数精度 0b1111 是禁止值")
  }
  let precision = prec_field + 1
  let shift = br.read_signed(5)
  let coef = Array::make(order, 0)
  let mut k = 0
  while k < order {
    coef[k] = br.read_signed(precision)
    k += 1
  }
  let residual = flac_decode_residual(br, block_size, order)
  let mut n = order
  while n < block_size {
    let mut sum : Int64 = 0L
    let mut j = 0
    while j < order {
      sum = sum + coef[j].to_int64() * out[n - 1 - j].to_int64()
      j += 1
    }
    let pred = if shift >= 0 {
      (sum >> shift).to_int()
    } else {
      (sum << (-shift)).to_int()
    }
    out[n] = residual[n - order] + pred
    n += 1
  }
  out
}

///|
/// 解码一个子帧。`bps` 是该子帧的名义位深（侧声道已经 +1）。
///
/// 返回长度为 `block_size` 的样本数组，wasted bits 已经左移还原。
fn flac_decode_subframe(
  br : FlacBitReader,
  block_size : Int,
  bps : Int,
) -> Array[Int] raise AudioError {
  if br.read_bit() != 0 {
    raise AudioError::InvalidMagic("FLAC 子帧头首 bit 必须为 0")
  }
  let stype = br.read_bits(6)
  let wasted_flag = br.read_bit()
  let mut wasted = 0
  if wasted_flag == 1 {
    // 规范：k-1 以一元码跟在标志位后，即 wasted = unary + 1
    wasted = br.read_unary() + 1
  }
  let eff = bps - wasted
  if eff <= 0 {
    raise AudioError::Unsupported("FLAC 子帧 wasted bits 过大，有效位深 \{eff}")
  }
  if eff > 32 {
    raise AudioError::Unsupported("FLAC 子帧有效位深超过 32：\{eff}")
  }
  let out = if stype == 0 {
    flac_decode_constant(br, block_size, eff)
  } else if stype == 1 {
    flac_decode_verbatim(br, block_size, eff)
  } else if stype >= 8 && stype <= 12 {
    flac_decode_fixed(br, block_size, eff, stype - 8)
  } else if stype >= 32 {
    flac_decode_lpc(br, block_size, eff, stype - 31)
  } else {
    raise AudioError::Unsupported("FLAC 子帧类型 0b\{stype} 为保留值")
  }
  if wasted > 0 {
    let mut i = 0
    while i < out.length() {
      out[i] = out[i] << wasted
      i += 1
    }
  }
  out
}

// ---------------------------------------------------------------------------
// 帧解码
// ---------------------------------------------------------------------------

///|
/// 解码一个完整帧（含帧头 CRC-8 与帧尾 CRC-16 校验）。
///
/// 返回 `(交织样本, 下一个帧的起始偏移)`。
fn flac_decode_frame(
  data : Bytes,
  start : Int,
  info : FlacStreamInfo,
) -> (Array[Int], Int) raise AudioError {
  let hdr = flac_parse_frame_header(data, start, info)
  // 规范允许解码器在流中途改变采样率时停止解码；本实现选择报错而不是输出错误格式的数据。
  if info.sample_rate > 0 && hdr.sample_rate != info.sample_rate {
    raise AudioError::Unsupported("FLAC 流中途改变采样率：\{hdr.sample_rate} != \{info.sample_rate}")
  }
  let br = FlacBitReader::at(data, start + hdr.header_len)
  let chans : Array[Array[Int]] = []
  let mut c = 0
  while c < hdr.channels {
    let mut sbps = hdr.bits_per_sample
    // 侧声道比标称位深多 1 位。
    // 左+侧（8）/ 中+侧（10）：ch0 是主声道，ch1 是 side；
    // 右+侧（9）：ch0 是 side，ch1 是 right（xiph format.html）。
    if (hdr.channel_assignment == 8 || hdr.channel_assignment == 10) && c == 1 {
      sbps = sbps + 1
    } else if hdr.channel_assignment == 9 && c == 0 {
      sbps = sbps + 1
    }
    chans.push(flac_decode_subframe(br, hdr.block_size, sbps))
    c += 1
  }
  let block = hdr.block_size
  let total = block * hdr.channels
  let out = Array::make(total, 0)
  if hdr.channel_assignment <= 7 {
    let mut i = 0
    while i < block {
      let mut k = 0
      while k < hdr.channels {
        out[i * hdr.channels + k] = chans[k][i]
        k += 1
      }
      i += 1
    }
  } else if hdr.channel_assignment == 8 {
    // 左+侧：ch0 = left，ch1 = side，right = left - side
    let left = chans[0]
    let side = chans[1]
    let mut i = 0
    while i < block {
      out[i * 2] = left[i]
      out[i * 2 + 1] = left[i] - side[i]
      i += 1
    }
  } else if hdr.channel_assignment == 9 {
    // 右+侧：ch0 = side，ch1 = right，left = right + side
    let side = chans[0]
    let right = chans[1]
    let mut i = 0
    while i < block {
      out[i * 2] = right[i] + side[i]
      out[i * 2 + 1] = right[i]
      i += 1
    }
  } else {
    // 中+侧：ch0 = mid，ch1 = side
    let mid_ch = chans[0]
    let side = chans[1]
    let mut i = 0
    while i < block {
      let s = side[i]
      let m = (mid_ch[i] << 1) | (s & 1)
      out[i * 2] = (m + s) >> 1
      out[i * 2 + 1] = (m - s) >> 1
      i += 1
    }
  }
  br.align_to_byte()
  let footer = br.byte_pos
  flac_require(data, footer, 2)
  let stored = (data[footer].to_int() << 8) | data[footer + 1].to_int()
  let computed = flac_crc16(data, start, footer)
  if stored != computed {
    raise AudioError::ChecksumMismatch(expected=stored, actual=computed)
  }
  (out, footer + 2)
}

// ---------------------------------------------------------------------------
// MD5（STREAMINFO 里的整体校验）
//
// 契约要求只依赖 moonbitlang/core 且不许改 moon.pkg，所以这里自带一份 MD5，
// 而不是去 import moonbitlang/core/crypto。已知答案测试见 flac_test.mbt：
// 8 位样本 [97,98,99] 的 PCM 字节恰好是 "abc"，
// 其 MD5 必须是 900150983cd24fb0d6963f7d28e17f72。
// ---------------------------------------------------------------------------

///|
/// MD5 每轮的左移位数。
let flac_md5_shift : Array[Int] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14,
  20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6,
  10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
]

///|
/// MD5 的 64 个加法常量 K[i] = floor(2^32 * |sin(i + 1)|)。
let flac_md5_k : Array[UInt] = [
  0xD76AA478U, 0xE8C7B756U, 0x242070DBU, 0xC1BDCEEEU, 0xF57C0FAFU, 0x4787C62AU, 0xA8304613U,
  0xFD469501U, 0x698098D8U, 0x8B44F7AFU, 0xFFFF5BB1U, 0x895CD7BEU, 0x6B901122U, 0xFD987193U,
  0xA679438EU, 0x49B40821U, 0xF61E2562U, 0xC040B340U, 0x265E5A51U, 0xE9B6C7AAU, 0xD62F105DU,
  0x02441453U, 0xD8A1E681U, 0xE7D3FBC8U, 0x21E1CDE6U, 0xC33707D6U, 0xF4D50D87U, 0x455A14EDU,
  0xA9E3E905U, 0xFCEFA3F8U, 0x676F02D9U, 0x8D2A4C8AU, 0xFFFA3942U, 0x8771F681U, 0x6D9D6122U,
  0xFDE5380CU, 0xA4BEEA44U, 0x4BDECFA9U, 0xF6BB4B60U, 0xBEBFBC70U, 0x289B7EC6U, 0xEAA127FAU,
  0xD4EF3085U, 0x04881D05U, 0xD9D4D039U, 0xE6DB99E5U, 0x1FA27CF8U, 0xC4AC5665U, 0xF4292244U,
  0x432AFF97U, 0xAB9423A7U, 0xFC93A039U, 0x655B59C3U, 0x8F0CCC92U, 0xFFEFF47DU, 0x85845DD1U,
  0x6FA87E4FU, 0xFE2CE6E0U, 0xA3014314U, 0x4E0811A1U, 0xF7537E82U, 0xBD3AF235U, 0x2AD7D2BBU,
  0xEB86D391U,
]

///|
/// 处理 `data[offset .. offset+64)` 一个块并就地更新状态。
fn flac_md5_block(state : Array[UInt], data : Bytes, offset : Int) -> Unit {
  let m : Array[UInt] = Array::make(16, 0U)
  let mut i = 0
  while i < 16 {
    let p = offset + i * 4
    m[i] = data[p].to_int().reinterpret_as_uint() |
      (data[p + 1].to_int().reinterpret_as_uint() << 8) |
      (data[p + 2].to_int().reinterpret_as_uint() << 16) |
      (data[p + 3].to_int().reinterpret_as_uint() << 24)
    i += 1
  }
  let mut a = state[0]
  let mut b = state[1]
  let mut c = state[2]
  let mut d = state[3]
  let mut r = 0
  while r < 64 {
    let mut f = 0U
    let mut g = 0
    if r < 16 {
      f = (b & c) | ((b ^ 0xFFFFFFFFU) & d)
      g = r
    } else if r < 32 {
      f = (d & b) | ((d ^ 0xFFFFFFFFU) & c)
      g = (5 * r + 1) % 16
    } else if r < 48 {
      f = b ^ c ^ d
      g = (3 * r + 5) % 16
    } else {
      f = c ^ (b | (d ^ 0xFFFFFFFFU))
      g = (7 * r) % 16
    }
    f = f + a + flac_md5_k[r] + m[g]
    a = d
    d = c
    c = b
    let s = flac_md5_shift[r]
    b = b + ((f << s) | (f >> (32 - s)))
    r += 1
  }
  state[0] = state[0] + a
  state[1] = state[1] + b
  state[2] = state[2] + c
  state[3] = state[3] + d
}

///|
/// 计算 `data[start .. end)` 的 MD5 摘要（16 字节）。
fn flac_md5(data : Bytes, start : Int, end : Int) -> Bytes {
  let state : Array[UInt] = [0x67452301U, 0xEFCDAB89U, 0x98BADCFEU, 0x10325476U]
  let total = end - start
  let mut offset = start
  let mut remaining = total
  while remaining >= 64 {
    flac_md5_block(state, data, offset)
    offset += 64
    remaining -= 64
  }
  let buf = Buffer()
  let mut i = 0
  while i < remaining {
    buf.write_byte(data[offset + i])
    i += 1
  }
  buf.write_byte(b'\x80')
  while buf.length() % 64 != 56 {
    buf.write_byte(b'\x00')
  }
  let bit_len = total.to_int64() * 8L
  let mut k = 0
  while k < 8 {
    buf.write_byte((((bit_len >> (8 * k)) & 0xFFL).to_int()).to_byte())
    k += 1
  }
  let tail = buf.to_bytes()
  let mut p = 0
  while p < tail.length() {
    flac_md5_block(state, tail, p)
    p += 64
  }
  let out = Buffer()
  for s in state {
    let mut k2 = 0
    while k2 < 4 {
      out.write_byte(((s >> (8 * k2)) & 0xFFU).reinterpret_as_int().to_byte())
      k2 += 1
    }
  }
  out.to_bytes()
}

///|
/// 按 FLAC 规范把交织样本序列化成 MD5 的输入：
/// 所有声道按样本交织、有符号、小端，位深不足整字节时符号扩展到下一个整字节。
fn flac_md5_pcm(samples : Array[Int], bps : Int) -> Bytes {
  let width = (bps + 7) / 8
  let buf = Buffer()
  for s in samples {
    let mut k = 0
    while k < width {
      buf.write_byte(((s >> (8 * k)) & 0xFF).to_byte())
      k += 1
    }
  }
  let bytes = buf.to_bytes()
  flac_md5(bytes, 0, bytes.length())
}

///|
/// 是否 16 字节全 0（FLAC 用全 0 表示 MD5 未知）。
fn flac_bytes_all_zero(data : Bytes) -> Bool {
  let mut i = 0
  while i < data.length() {
    if data[i] != b'\x00' {
      return false
    }
    i += 1
  }
  true
}

///|
/// 字节序列相等比较。
fn flac_bytes_equal(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  while i < a.length() {
    if a[i] != b[i] {
      return false
    }
    i += 1
  }
  true
}

///|
/// 取前 4 字节按大端解释成 `Int`，只用于 `ChecksumMismatch` 的错误信息。
fn flac_bytes_head_int(data : Bytes) -> Int {
  let n = if data.length() < 4 { data.length() } else { 4 }
  let mut v = 0
  let mut i = 0
  while i < n {
    v = (v << 8) | data[i].to_int()
    i += 1
  }
  v
}

// ---------------------------------------------------------------------------
// 公开 API
// ---------------------------------------------------------------------------

///|
/// 只解析 `fLaC` 标记 + 全部 metadata block，不碰音频帧。
pub fn parse_flac_metadata(data : Bytes) -> FlacMetadata raise AudioError {
  let (info, comments, seektable, pictures, _frame_pos) = flac_scan_metadata(data)
  { info, comments, seektable, pictures }
}

///|
/// 取 FLAC 流的音频格式（只读 STREAMINFO）。
pub fn flac_info(data : Bytes) -> AudioFormat raise AudioError {
  let meta = parse_flac_metadata(data)
  {
    sample_rate: meta.info.sample_rate,
    channels: meta.info.channels,
    bits_per_sample: meta.info.bits_per_sample,
  }
}

///|
/// 完整解码为交织 PCM（`[L0, R0, L1, R1, ...]`）。
///
/// 当 STREAMINFO 给出 `total_samples` 时，末尾多余样本会被截断到该长度；
/// 帧头 CRC-8 / 帧尾 CRC-16 不符会抛 `ChecksumMismatch`。
pub fn decode_flac(data : Bytes) -> Audio raise AudioError {
  let (info, comments, _seektable, _pictures, frame_pos) = flac_scan_metadata(data)
  let channels = info.channels
  let total = info.total_samples
  let samples : Array[Int] = []
  let mut decoded : Int64 = 0L
  let mut pos = frame_pos
  let len = data.length()
  while pos < len {
    if total > 0L && decoded >= total {
      break
    }
    // 帧必须恰好从字节边界开始且以同步码开头；否则视为流结束（容忍尾部填充/ID3v1）
    if pos + 2 > len {
      break
    }
    if !(data[pos] == b'\xFF' && (data[pos + 1].to_int() & 0xFE) == 0xF8) {
      break
    }
    let (frame, next) = flac_decode_frame(data, pos, info)
    let frame_count = frame.length() / channels
    let mut keep = frame_count
    if total > 0L {
      let remain = total - decoded
      if remain < keep.to_int64() {
        keep = remain.to_int()
      }
    }
    let mut i = 0
    while i < keep * channels {
      samples.push(frame[i])
      i += 1
    }
    decoded += frame_count.to_int64()
    pos = next
  }
  let format : AudioFormat = {
    sample_rate: info.sample_rate,
    channels: info.channels,
    bits_per_sample: info.bits_per_sample,
  }
  // STREAMINFO 的 MD5 覆盖全部交织样本；全 0 表示编码器未填写，跳过校验。
  if !flac_bytes_all_zero(info.md5) {
    let digest = flac_md5_pcm(samples, info.bits_per_sample)
    if !flac_bytes_equal(digest, info.md5) {
      raise AudioError::ChecksumMismatch(
        expected=flac_bytes_head_int(info.md5),
        actual=flac_bytes_head_int(digest),
      )
    }
  }
  { format, samples, tags: comments }
}

///|
/// 逐帧解码句柄。
///
/// 当前**无法实现**：`Decoder` 的唯一字段 `state : DecoderState` 是 `priv` 的，
/// 而 `DecoderState::FlacDecoder(Int)` 只携带一个 `Int`，既存不下输入 `Bytes`
/// 也存不下帧游标；同时 `Decoder::next` / `Decoder::format` 在已冻结的
/// `types.mbt` 里是固定的 `Unsupported` 占位实现，任何工厂函数造出来的
/// `Decoder` 都不可能真正产出数据。在不修改 `types.mbt` 的前提下
/// 这个函数没有任何有意义的实现，因此按约定直接抛 `Unsupported`。
pub fn flac_decoder(data : Bytes) -> Decoder raise AudioError {
  ignore(data)
  raise AudioError::Unsupported("flac_decoder 待接入")
}
