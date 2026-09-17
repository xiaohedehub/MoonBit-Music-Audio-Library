// moonbit-music —— FLAC 解码器黑盒测试
//
// 这里**手写**最小合法 FLAC 流：所有字节都由本文件按位拼出来，期望样本值
// 也是手工推导后写死在断言里的。
//
// 关于 CRC：`flac.mbt` 里的 `flac_crc8` / `flac_crc16` 是私有的，黑盒测试
// 够不到，所以本文件带一份**独立的**参考实现 `flac_t_crc8` / `flac_t_crc16`，
// 并先用公开的 CRC 标准 check 值（"123456789" → 0xF4 / 0xFEE8）自检。
// 由它算出的帧 CRC 能被解码器接受、被篡改后能被拒绝，等价于交叉验证了
// `flac.mbt` 里的 CRC 实现。
//
// 所有辅助符号都带 `flac_t_` / `FlacT` 前缀，避免与其他代理的测试文件重名。

// ---------------------------------------------------------------------------
// 测试侧独立 CRC 参考实现
// ---------------------------------------------------------------------------

///|
/// CRC-8：多项式 0x07，初值 0，非反射，无输出异或。
fn flac_t_crc8(data : Bytes, start : Int, end : Int) -> Int {
  let mut crc = 0
  let mut i = start
  while i < end {
    crc = crc ^ data[i].to_int()
    let mut b = 0
    while b < 8 {
      crc = if (crc & 0x80) != 0 {
        ((crc << 1) ^ 0x07) & 0xFF
      } else {
        (crc << 1) & 0xFF
      }
      b += 1
    }
    i += 1
  }
  crc
}

///|
/// CRC-16：多项式 0x8005，初值 0，非反射，无输出异或。
fn flac_t_crc16(data : Bytes, start : Int, end : Int) -> Int {
  let mut crc = 0
  let mut i = start
  while i < end {
    crc = crc ^ ((data[i].to_int() & 0xFF) << 8)
    let mut b = 0
    while b < 8 {
      crc = if (crc & 0x8000) != 0 {
        ((crc << 1) ^ 0x8005) & 0xFFFF
      } else {
        (crc << 1) & 0xFFFF
      }
      b += 1
    }
    i += 1
  }
  crc
}

// ---------------------------------------------------------------------------
// 字节拼接小工具
// ---------------------------------------------------------------------------

///|
/// 把 `data` 逐字节追加到 `buf`（`Buffer` 不保证有 write_bytes 语义，故手写）。
fn flac_t_append(buf : Buffer, data : Bytes) -> Unit {
  let mut i = 0
  while i < data.length() {
    buf.write_byte(data[i])
    i += 1
  }
}

///|
/// 顺序拼接若干字节串。
fn flac_t_join(parts : Array[Bytes]) -> Bytes {
  let buf = Buffer()
  for p in parts {
    flac_t_append(buf, p)
  }
  buf.to_bytes()
}

///|
/// 解析十六进制字符串成字节（非十六进制字符一律忽略）。
fn flac_t_hex(s : String) -> Bytes {
  let buf = Buffer()
  let mut hi = -1
  for c in s {
    let v = c.to_int()
    let d = if v >= 48 && v <= 57 {
      v - 48
    } else if v >= 97 && v <= 102 {
      v - 87
    } else if v >= 65 && v <= 70 {
      v - 55
    } else {
      -1
    }
    if d >= 0 {
      if hi < 0 {
        hi = d
      } else {
        buf.write_byte((hi * 16 + d).to_byte())
        hi = -1
      }
    }
  }
  buf.to_bytes()
}

///|
/// 返回一个改写掉第 `index` 个字节的副本。
fn flac_t_patch_byte(data : Bytes, index : Int, value : Int) -> Bytes {
  let buf = Buffer()
  let mut i = 0
  while i < data.length() {
    buf.write_byte(if i == index { value.to_byte() } else { data[i] })
    i += 1
  }
  buf.to_bytes()
}

///|
/// 全 0 的 16 字节 MD5（表示"编码器未填写"，解码时不校验）。
fn flac_t_zero_md5() -> Bytes {
  let buf = Buffer()
  let mut i = 0
  while i < 16 {
    buf.write_byte(b'\x00')
    i += 1
  }
  buf.to_bytes()
}

// ---------------------------------------------------------------------------
// 测试侧 MSB-first 位写入器
// ---------------------------------------------------------------------------

///|
/// 按位拼字节的子帧构造器。子帧之间**不能**各自补齐到字节边界，
/// 必须共用同一个 writer，只在整帧子帧数据结束后补一次零。
struct FlacTBitWriter {
  buf : Buffer
  mut cur : Int
  mut nbits : Int
}

///|
/// 新建位写入器。
fn flac_t_bit_writer() -> FlacTBitWriter {
  { buf: Buffer(), cur: 0, nbits: 0 }
}

///|
/// 写入 `count` 位无符号值（取低 `count` 位）。
fn FlacTBitWriter::put(self : FlacTBitWriter, value : Int, count : Int) -> Unit {
  let mut i = count - 1
  while i >= 0 {
    self.cur = (self.cur << 1) | ((value >> i) & 1)
    self.nbits += 1
    if self.nbits == 8 {
      self.buf.write_byte(self.cur.to_byte())
      self.cur = 0
      self.nbits = 0
    }
    i -= 1
  }
}

///|
/// 写入 `count` 位二进制补码有符号值。
fn FlacTBitWriter::put_signed(self : FlacTBitWriter, value : Int, count : Int) -> Unit {
  let masked = if count >= 32 { value } else { value & ((1 << count) - 1) }
  self.put(masked, count)
}

///|
/// 写入一元码：`q` 个 0 后跟一个 1。
fn FlacTBitWriter::put_unary(self : FlacTBitWriter, q : Int) -> Unit {
  let mut i = 0
  while i < q {
    self.put(0, 1)
    i += 1
  }
  self.put(1, 1)
}

///|
/// 写一个 Rice 码字。`folded` 是 zigzag 之后的无符号值：
/// 商 `folded >> k` 走一元码，余数 `folded & (2^k - 1)` 走定长二进制。
fn FlacTBitWriter::put_rice(self : FlacTBitWriter, folded : Int, k : Int) -> Unit {
  self.put_unary(folded >> k)
  if k > 0 {
    self.put(folded & ((1 << k) - 1), k)
  }
}

///|
/// 收尾：补 0 到字节边界并取出字节。
fn flac_t_finish(w : FlacTBitWriter) -> Bytes {
  if w.nbits > 0 {
    w.buf.write_byte((w.cur << (8 - w.nbits)).to_byte())
    w.cur = 0
    w.nbits = 0
  }
  w.buf.to_bytes()
}

// ---------------------------------------------------------------------------
// 子帧构造（写入共享 writer，不自行补齐）
// ---------------------------------------------------------------------------

///|
/// CONSTANT 子帧：子帧头 `0 | 000000 | 0` + 一个 `bps` 位有符号常量。
fn flac_t_constant_into(w : FlacTBitWriter, value : Int, bps : Int) -> Unit {
  w.put(0, 1)
  w.put(0, 6)
  w.put(0, 1)
  w.put_signed(value, bps)
}

///|
/// VERBATIM 子帧：子帧头 `0 | 000001 | 0` + `samples` 个 `bps` 位样本。
fn flac_t_verbatim_into(w : FlacTBitWriter, samples : Array[Int], bps : Int) -> Unit {
  w.put(0, 1)
  w.put(1, 6)
  w.put(0, 1)
  for s in samples {
    w.put_signed(s, bps)
  }
}

///|
/// FIXED 子帧：子帧头 `0 | 001xxx | 0`，warmup 原样写，残差用单个 Rice 分区。
/// `folded` 直接给 zigzag 之后的码字值，方便逐条核对反 zigzag。
/// `coding_method` = 0 → 4 位参数（Rice），1 → 5 位参数（Rice2）。
fn flac_t_fixed_rice_into(
  w : FlacTBitWriter,
  order : Int,
  warmup : Array[Int],
  folded : Array[Int],
  bps : Int,
  k : Int,
  coding_method : Int,
) -> Unit {
  w.put(0, 1)
  w.put(8 + order, 6)
  w.put(0, 1)
  for s in warmup {
    w.put_signed(s, bps)
  }
  w.put(coding_method, 2)
  w.put(0, 4) // partition order = 0 → 单个分区
  w.put(k, if coding_method == 0 { 4 } else { 5 })
  for f in folded {
    w.put_rice(f, k)
  }
}

///|
/// FIXED 子帧 + escape 分区：残差以 `nbits` 位有符号原值存储。
fn flac_t_fixed_escape_into(
  w : FlacTBitWriter,
  order : Int,
  warmup : Array[Int],
  values : Array[Int],
  bps : Int,
  nbits : Int,
) -> Unit {
  w.put(0, 1)
  w.put(8 + order, 6)
  w.put(0, 1)
  for s in warmup {
    w.put_signed(s, bps)
  }
  w.put(0, 2) // method 00
  w.put(0, 4) // partition order 0
  w.put(15, 4) // escape
  w.put(nbits, 5)
  for v in values {
    w.put_signed(v, nbits)
  }
}

///|
/// LPC 子帧：子帧头 `0 | 1xxxxx | 0`，warmup → precision-1 → shift → 系数 → 残差。
fn flac_t_lpc_into(
  w : FlacTBitWriter,
  order : Int,
  warmup : Array[Int],
  precision : Int,
  shift : Int,
  coef : Array[Int],
  folded : Array[Int],
  bps : Int,
  k : Int,
) -> Unit {
  w.put(0, 1)
  w.put(31 + order, 6)
  w.put(0, 1)
  for s in warmup {
    w.put_signed(s, bps)
  }
  w.put(precision - 1, 4)
  w.put_signed(shift, 5)
  for c in coef {
    w.put_signed(c, precision)
  }
  w.put(0, 2)
  w.put(0, 4)
  w.put(k, 4)
  for f in folded {
    w.put_rice(f, k)
  }
}

// ---------------------------------------------------------------------------
// 帧 / 元数据 / 整文件构造
// ---------------------------------------------------------------------------

///|
/// FLAC 的 UTF-8 式变长整数（1..7 字节，最多 36 位）。
fn flac_t_utf8_number(v : Int64) -> Bytes {
  let b = Buffer()
  let mut n = 1
  if v < 0x80L {
    n = 1
  } else if v < 0x800L {
    n = 2
  } else if v < 0x10000L {
    n = 3
  } else if v < 0x200000L {
    n = 4
  } else if v < 0x4000000L {
    n = 5
  } else if v < 0x80000000L {
    n = 6
  } else {
    n = 7
  }
  if n == 1 {
    b.write_byte(v.to_int().to_byte())
  } else {
    let lead = (0xFF << (8 - n)) & 0xFF
    // n == 7 时首字节不携带数据位（0xFE + 6 个续字节 = 36 位）
    let top = if n == 7 { 0 } else { ((v >> (6 * (n - 1))) & 0x3FL).to_int() }
    b.write_byte((lead | top).to_byte())
    let mut j = n - 2
    while j >= 0 {
      b.write_byte((0x80 | ((v >> (6 * j)) & 0x3FL).to_int()).to_byte())
      j -= 1
    }
  }
  b.to_bytes()
}

///|
/// 拼一个完整帧。
///
/// 帧头布局：`FF F8|blocking | (bs_code<<4)|sr_code | (ch_code<<4)|(ss_code<<1)`
/// → UTF-8 帧号 → 非常用块大小/采样率的附加字节 → CRC-8；
/// 之后是子帧数据，最后是 CRC-16（覆盖从同步码起、CRC 之前的所有字节）。
///
/// `crc8_bias` / `crc16_bias` 用于故意写坏校验和（测试 ChecksumMismatch）。
fn flac_t_frame_ex(
  blocking : Int,
  bs_code : Int,
  sr_code : Int,
  ch_code : Int,
  ss_code : Int,
  frame_number : Int64,
  extra : Bytes,
  subframes : Bytes,
  crc8_bias : Int,
  crc16_bias : Int,
) -> Bytes {
  let head = Buffer()
  head.write_byte(b'\xFF')
  head.write_byte((0xF8 | blocking).to_byte())
  head.write_byte(((bs_code << 4) | sr_code).to_byte())
  head.write_byte(((ch_code << 4) | (ss_code << 1)).to_byte())
  flac_t_append(head, flac_t_utf8_number(frame_number))
  flac_t_append(head, extra)
  let hb = head.to_bytes()
  let crc8 = (flac_t_crc8(hb, 0, hb.length()) + crc8_bias) & 0xFF
  let frame = Buffer()
  flac_t_append(frame, hb)
  frame.write_byte(crc8.to_byte())
  flac_t_append(frame, subframes)
  let fb = frame.to_bytes()
  let crc16 = (flac_t_crc16(fb, 0, fb.length()) + crc16_bias) & 0xFFFF
  let out = Buffer()
  flac_t_append(out, fb)
  out.write_byte(((crc16 >> 8) & 0xFF).to_byte())
  out.write_byte((crc16 & 0xFF).to_byte())
  out.to_bytes()
}

///|
/// 校验和正确的帧。
fn flac_t_frame(
  blocking : Int,
  bs_code : Int,
  sr_code : Int,
  ch_code : Int,
  ss_code : Int,
  frame_number : Int64,
  extra : Bytes,
  subframes : Bytes,
) -> Bytes {
  flac_t_frame_ex(
    blocking, bs_code, sr_code, ch_code, ss_code, frame_number, extra, subframes, 0, 0,
  )
}

///|
/// 34 字节 STREAMINFO 块体（打包区：20 位采样率 + 3 位(声道-1) + 5 位(位深-1) + 36 位总样本数）。
fn flac_t_streaminfo(
  min_bs : Int,
  max_bs : Int,
  min_fs : Int,
  max_fs : Int,
  sample_rate : Int,
  channels : Int,
  bps : Int,
  total : Int64,
  md5 : Bytes,
) -> Bytes {
  let b = Buffer()
  b.write_byte(((min_bs >> 8) & 0xFF).to_byte())
  b.write_byte((min_bs & 0xFF).to_byte())
  b.write_byte(((max_bs >> 8) & 0xFF).to_byte())
  b.write_byte((max_bs & 0xFF).to_byte())
  b.write_byte(((min_fs >> 16) & 0xFF).to_byte())
  b.write_byte(((min_fs >> 8) & 0xFF).to_byte())
  b.write_byte((min_fs & 0xFF).to_byte())
  b.write_byte(((max_fs >> 16) & 0xFF).to_byte())
  b.write_byte(((max_fs >> 8) & 0xFF).to_byte())
  b.write_byte((max_fs & 0xFF).to_byte())
  let chm1 = channels - 1
  let bpsm1 = bps - 1
  b.write_byte(((sample_rate >> 12) & 0xFF).to_byte())
  b.write_byte(((sample_rate >> 4) & 0xFF).to_byte())
  b.write_byte(
    (((sample_rate & 0x0F) << 4) | ((chm1 & 0x07) << 1) | ((bpsm1 >> 4) & 1)).to_byte(),
  )
  b.write_byte((((bpsm1 & 0x0F) << 4) | ((total >> 32).to_int() & 0x0F)).to_byte())
  b.write_byte((((total >> 24).to_int()) & 0xFF).to_byte())
  b.write_byte((((total >> 16).to_int()) & 0xFF).to_byte())
  b.write_byte((((total >> 8).to_int()) & 0xFF).to_byte())
  b.write_byte(((total.to_int()) & 0xFF).to_byte())
  let mut i = 0
  while i < 16 {
    b.write_byte(if i < md5.length() { md5[i] } else { b'\x00' })
    i += 1
  }
  b.to_bytes()
}

///|
/// VORBIS_COMMENT 块体：vendor 长度(LE32) + vendor + 条数(LE32) + 每条 长度(LE32) + 内容。
fn flac_t_vorbis_comment(vendor : Bytes, fields : Array[Bytes]) -> Bytes {
  let b = Buffer()
  let vlen = vendor.length()
  b.write_byte((vlen & 0xFF).to_byte())
  b.write_byte(((vlen >> 8) & 0xFF).to_byte())
  b.write_byte(((vlen >> 16) & 0xFF).to_byte())
  b.write_byte(((vlen >> 24) & 0xFF).to_byte())
  flac_t_append(b, vendor)
  let n = fields.length()
  b.write_byte((n & 0xFF).to_byte())
  b.write_byte(((n >> 8) & 0xFF).to_byte())
  b.write_byte(((n >> 16) & 0xFF).to_byte())
  b.write_byte(((n >> 24) & 0xFF).to_byte())
  for f in fields {
    let l = f.length()
    b.write_byte((l & 0xFF).to_byte())
    b.write_byte(((l >> 8) & 0xFF).to_byte())
    b.write_byte(((l >> 16) & 0xFF).to_byte())
    b.write_byte(((l >> 24) & 0xFF).to_byte())
    flac_t_append(b, f)
  }
  b.to_bytes()
}

///|
/// SEEKTABLE 块体：每项 18 字节（样本号 8 + 偏移 8 + 帧内样本数 2，全大端）。
fn flac_t_seektable(samples : Array[Int64], offsets : Array[Int64], counts : Array[Int]) -> Bytes {
  let b = Buffer()
  let mut i = 0
  while i < samples.length() {
    let s = samples[i]
    let mut k = 7
    while k >= 0 {
      b.write_byte(((s >> (8 * k)) & 0xFFL).to_int().to_byte())
      k -= 1
    }
    let o = offsets[i]
    k = 7
    while k >= 0 {
      b.write_byte(((o >> (8 * k)) & 0xFFL).to_int().to_byte())
      k -= 1
    }
    b.write_byte(((counts[i] >> 8) & 0xFF).to_byte())
    b.write_byte((counts[i] & 0xFF).to_byte())
    i += 1
  }
  b.to_bytes()
}

///|
/// PICTURE 块体：type(4) + mime_len(4) + mime + desc_len(4) + desc
/// + width/height/depth/colors(各 4) + data_len(4) + data。
fn flac_t_picture(
  ptype : Int,
  mime : Bytes,
  desc : Bytes,
  width : Int,
  height : Int,
  depth : Int,
  colors : Int,
  data : Bytes,
) -> Bytes {
  let b = Buffer()
  let mut vals : Array[Int] = [ptype, mime.length()]
  for v in vals {
    b.write_byte(((v >> 24) & 0xFF).to_byte())
    b.write_byte(((v >> 16) & 0xFF).to_byte())
    b.write_byte(((v >> 8) & 0xFF).to_byte())
    b.write_byte((v & 0xFF).to_byte())
  }
  flac_t_append(b, mime)
  vals = [desc.length()]
  for v in vals {
    b.write_byte(((v >> 24) & 0xFF).to_byte())
    b.write_byte(((v >> 16) & 0xFF).to_byte())
    b.write_byte(((v >> 8) & 0xFF).to_byte())
    b.write_byte((v & 0xFF).to_byte())
  }
  flac_t_append(b, desc)
  vals = [width, height, depth, colors, data.length()]
  for v in vals {
    b.write_byte(((v >> 24) & 0xFF).to_byte())
    b.write_byte(((v >> 16) & 0xFF).to_byte())
    b.write_byte(((v >> 8) & 0xFF).to_byte())
    b.write_byte((v & 0xFF).to_byte())
  }
  flac_t_append(b, data)
  b.to_bytes()
}

///|
/// 拼一个完整 FLAC 文件：`fLaC` + 元数据块链（最后一块置 last 标志）+ 音频帧。
fn flac_t_file(blocks : Array[(Int, Bytes)], frames : Bytes) -> Bytes {
  let b = Buffer()
  b.write_byte(b'f')
  b.write_byte(b'L')
  b.write_byte(b'a')
  b.write_byte(b'C')
  let n = blocks.length()
  let mut i = 0
  while i < n {
    let (btype, body) = blocks[i]
    let len = body.length()
    let flag = if i == n - 1 { 0x80 } else { 0x00 }
    b.write_byte((flag | btype).to_byte())
    b.write_byte(((len >> 16) & 0xFF).to_byte())
    b.write_byte(((len >> 8) & 0xFF).to_byte())
    b.write_byte((len & 0xFF).to_byte())
    flac_t_append(b, body)
    i += 1
  }
  flac_t_append(b, frames)
  b.to_bytes()
}

// ---------------------------------------------------------------------------
// 错误断言小工具
// ---------------------------------------------------------------------------

///|
/// 返回 metadata 解析失败的类别名；成功则返回 `"<没有抛错>"`。
///
/// 刻意返回 String 而不是在 `try` 里断言：`assert_eq` 自己也会抛错，
/// 放在 `try` 块里会被 catch 吞掉。
fn flac_t_meta_error_kind(data : Bytes) -> String {
  try {
    ignore(parse_flac_metadata(data))
    "<没有抛错>"
  } catch {
    AudioError::InvalidMagic(_) => "InvalidMagic"
    AudioError::Truncated(..) => "Truncated"
    AudioError::Unsupported(_) => "Unsupported"
    AudioError::ChecksumMismatch(..) => "ChecksumMismatch"
    AudioError::LimitExceeded(_) => "LimitExceeded"
  }
}

///|
/// 返回整流解码失败的类别名；成功则返回 `"<没有抛错>"`。
fn flac_t_decode_error_kind(data : Bytes) -> String {
  try {
    ignore(decode_flac(data))
    "<没有抛错>"
  } catch {
    AudioError::InvalidMagic(_) => "InvalidMagic"
    AudioError::Truncated(..) => "Truncated"
    AudioError::Unsupported(_) => "Unsupported"
    AudioError::ChecksumMismatch(..) => "ChecksumMismatch"
    AudioError::LimitExceeded(_) => "LimitExceeded"
  }
}

///|
/// 断言 metadata 解析抛出指定类别的 `AudioError`。
fn flac_t_expect_meta_error(data : Bytes, kind : String) -> Unit raise {
  assert_eq(flac_t_meta_error_kind(data), kind)
}

///|
/// 断言整流解码抛出指定类别的 `AudioError`。
fn flac_t_expect_decode_error(data : Bytes, kind : String) -> Unit raise {
  assert_eq(flac_t_decode_error_kind(data), kind)
}

///|
/// 单声道 8kHz / 16bit 的常用 STREAMINFO（块大小用 8 位非常用码，故写 16..65535）。
fn flac_t_mono16(total : Int64) -> Bytes {
  flac_t_streaminfo(16, 65535, 0, 0, 8000, 1, 16, total, flac_t_zero_md5())
}

///|
/// 单声道帧：bs_code=6（8 位"块大小-1"）、sr_code=4（8kHz）、ch_code=0（mono）、
/// ss_code=4（16bit）。
fn flac_t_mono_frame(block_size : Int, frame_number : Int64, subframes : Bytes) -> Bytes {
  flac_t_frame(0, 6, 4, 0, 4, frame_number, [(block_size - 1).to_byte()], subframes)
}

///|
/// 用可变块大小策略（blocking=1，帧号即首样本号）的帧。
fn flac_t_var_frame(block_size : Int, sample_number : Int64, subframes : Bytes) -> Bytes {
  flac_t_frame(1, 6, 4, 0, 4, sample_number, [(block_size - 1).to_byte()], subframes)
}

// ===========================================================================
// 测试
// ===========================================================================

///|
/// 先用公开的 CRC 标准 check 值验证测试侧的参考实现，
/// 之后所有帧 CRC 才有可信度。
test "flac: 测试侧 CRC 参考实现对齐标准 check 值" {
  let check = b"123456789"
  assert_eq(flac_t_crc8(check, 0, check.length()), 0xF4)
  assert_eq(flac_t_crc16(check, 0, check.length()), 0xFEE8)
}

///|
/// 1) 只有 STREAMINFO 的最小流。
test "flac: 最小流 STREAMINFO 各字段" {
  let md5 = b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F"
  let si = flac_t_streaminfo(4096, 4096, 100, 200, 44100, 2, 16, 12345L, md5)
  let file = flac_t_file([(0, si)], b"")
  let meta = parse_flac_metadata(file)
  assert_eq(meta.info.min_block_size, 4096)
  assert_eq(meta.info.max_block_size, 4096)
  assert_eq(meta.info.min_frame_size, 100)
  assert_eq(meta.info.max_frame_size, 200)
  assert_eq(meta.info.sample_rate, 44100)
  assert_eq(meta.info.channels, 2)
  assert_eq(meta.info.bits_per_sample, 16)
  assert_eq(meta.info.total_samples, 12345L)
  assert_eq(meta.info.md5.length(), 16)
  assert_eq(meta.info.md5, md5)
  assert_eq(meta.comments.length(), 0)
  assert_eq(meta.seektable.length(), 0)
  assert_eq(meta.pictures.length(), 0)
  assert_eq(flac_info(file), { sample_rate: 44100, channels: 2, bits_per_sample: 16 })
}

///|
/// STREAMINFO 的打包字段要能吃满 36 位总样本数与各种位深/声道数。
test "flac: STREAMINFO 打包字段边界（36 位总样本数 / 8 声道 / 24bit）" {
  let cases : Array[(Int, Int, Int, Int64)] = [
    (8000, 1, 8, 0L),
    (192000, 8, 24, 68719476735L),
    (96000, 3, 20, 4294967296L),
    (22050, 2, 4, 1L),
  ]
  for c in cases {
    let (sr, ch, bps, total) = c
    let si = flac_t_streaminfo(16, 16, 0, 0, sr, ch, bps, total, flac_t_zero_md5())
    let meta = parse_flac_metadata(flac_t_file([(0, si)], b""))
    assert_eq(meta.info.sample_rate, sr)
    assert_eq(meta.info.channels, ch)
    assert_eq(meta.info.bits_per_sample, bps)
    assert_eq(meta.info.total_samples, total)
  }
}

///|
/// 2) VORBIS_COMMENT：多条字段、键名大小写不敏感（统一转大写）、UTF-8 值、无 `=` 的字段。
test "flac: VORBIS_COMMENT 解析" {
  let body = flac_t_vorbis_comment(b"reference libFLAC 1.4.3", [
    b"TITLE=Hello",
    b"artist=World",
    b"ALBUM=caf\xc3\xa9",
    b"comment=\xe4\xb8\xad\xe6\x96\x87",
    b"NOEQUALS",
    b"EMPTY=",
  ])
  let si = flac_t_streaminfo(4096, 4096, 0, 0, 44100, 2, 16, 0L, flac_t_zero_md5())
  let meta = parse_flac_metadata(flac_t_file([(0, si), (4, body)], b""))
  assert_eq(meta.comments, [
    ("TITLE", "Hello"),
    ("ARTIST", "World"),
    ("ALBUM", "caf\u{00E9}"),
    ("COMMENT", "\u{4E2D}\u{6587}"),
    ("NOEQUALS", ""),
    ("EMPTY", ""),
  ])
}

///|
/// 3) SEEKTABLE：每项 18 字节，我们只保留样本号；占位点 0xFFFF... 变成 -1。
test "flac: SEEKTABLE 解析" {
  let body = flac_t_seektable(
    [0L, 44100L, 88200L, -1L],
    [0L, 1234L, 5678L, 0L],
    [4096, 4096, 4096, 0],
  )
  let si = flac_t_streaminfo(4096, 4096, 0, 0, 44100, 2, 16, 0L, flac_t_zero_md5())
  let meta = parse_flac_metadata(flac_t_file([(0, si), (3, body)], b""))
  assert_eq(meta.seektable, [0L, 44100L, 88200L, -1L])
}

///|
/// 4) PICTURE：提取最后的图片数据，跳过 MIME / 描述 / 尺寸字段。
test "flac: PICTURE 提取图片数据" {
  let pic = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
  let body = flac_t_picture(3, b"image/png", b"front cover", 32, 48, 24, 0, pic)
  let si = flac_t_streaminfo(4096, 4096, 0, 0, 44100, 2, 16, 0L, flac_t_zero_md5())
  let meta = parse_flac_metadata(flac_t_file([(0, si), (6, body)], b""))
  assert_eq(meta.pictures.length(), 1)
  assert_eq(meta.pictures[0], pic)
}

///|
/// PADDING / APPLICATION / CUESHEET / 保留类型都要被整块跳过而不影响后续块。
test "flac: 未知与无关元数据块被跳过" {
  let si = flac_t_streaminfo(4096, 4096, 0, 0, 44100, 2, 16, 0L, flac_t_zero_md5())
  let padding = b"\x00\x00\x00\x00\x00"
  let application = b"APPLdata"
  let cuesheet = b"\x00\x00\x00\x00"
  let reserved = b"\xDE\xAD\xBE\xEF"
  let vc = flac_t_vorbis_comment(b"x", [b"TITLE=after"])
  let file = flac_t_file([
    (0, si),
    (1, padding),
    (2, application),
    (5, cuesheet),
    (77, reserved),
    (4, vc),
  ], b"")
  let meta = parse_flac_metadata(file)
  assert_eq(meta.info.sample_rate, 44100)
  assert_eq(meta.comments, [("TITLE", "after")])
}

///|
/// 5) 魔数错误 → InvalidMagic。
test "flac: 魔数错误 -> InvalidMagic" {
  flac_t_expect_meta_error(b"FLAC\x00\x00\x00\x00", "InvalidMagic")
  flac_t_expect_meta_error(b"fLaX\x00\x00\x00\x00", "InvalidMagic")
  flac_t_expect_meta_error(b"OggS\x00\x00\x00\x00", "InvalidMagic")
  // 太短，连魔数都放不下 → Truncated
  flac_t_expect_meta_error(b"fLa", "Truncated")
}

///|
/// 6) metadata 截断 → Truncated（块头声明 34 字节但实际只有 10 字节）。
test "flac: metadata 截断 -> Truncated" {
  let truncated_block = b"fLaC\x00\x00\x00\x22\x00\x10\x00\x10\x00"
  flac_t_expect_meta_error(truncated_block, "Truncated")
  // 只有 fLaC + 半个块头
  flac_t_expect_meta_error(b"fLaC\x00\x00", "Truncated")
  // 合法块头但立刻 EOF
  flac_t_expect_meta_error(b"fLaC\x80\x00\x00\x22", "Truncated")
  // 有元数据但没有 STREAMINFO
  let vc = flac_t_vorbis_comment(b"x", [b"A=B"])
  flac_t_expect_meta_error(flac_t_file([(4, vc)], b""), "InvalidMagic")
  // STREAMINFO 长度不足 34
  let short_si = b"\x10\x00\x10\x00\x00\x00\x00"
  flac_t_expect_meta_error(flac_t_file([(0, short_si)], b""), "Truncated")
}

///|
/// 7) CONSTANT 子帧：mono / 8kHz / 16bit / block size 16 / 常量 -3。
///    子帧字节 = 0x00（头） + 0xFFFD（-3 的补码）。
test "flac: CONSTANT 子帧解码" {
  let w = flac_t_bit_writer()
  flac_t_constant_into(w, -3, 16)
  let sub = flac_t_finish(w)
  assert_eq(sub, b"\x00\xFF\xFD") // 手工核对子帧字节
  let file = flac_t_file([(0, flac_t_mono16(16L))], flac_t_mono_frame(16, 0L, sub))
  let audio = decode_flac(file)
  assert_eq(audio.format, { sample_rate: 8000, channels: 1, bits_per_sample: 16 })
  assert_eq(audio.samples.length(), 16)
  for s in audio.samples {
    assert_eq(s, -3)
  }
}

///|
/// CONSTANT + wasted bits：值 8 = 0b1000 有 3 个 wasted 位，
/// 码流里存 8>>3 = 1（13 位），解码后左移 3 位还原成 8。
/// 比特序列 `0 | 000000 | 1 | 001(unary k-1=2) | 0000000000001` = 0x01 0x20 0x01。
test "flac: CONSTANT + wasted bits 子帧" {
  let w = flac_t_bit_writer()
  w.put(0, 1)
  w.put(0, 6)
  w.put(1, 1) // wasted bits flag
  w.put_unary(2) // k - 1 = 2 → k = 3
  w.put_signed(1, 13)
  let sub = flac_t_finish(w)
  assert_eq(sub, b"\x01\x20\x01")
  let file = flac_t_file([(0, flac_t_mono16(16L))], flac_t_mono_frame(16, 0L, sub))
  let audio = decode_flac(file)
  for s in audio.samples {
    assert_eq(s, 8)
  }
}

///|
/// 8) VERBATIM 子帧：逐样本精确。
///    样本 [1, -2, 32767, -32768] → 0x0001 0xFFFE 0x7FFF 0x8000。
test "flac: VERBATIM 子帧解码" {
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [1, -2, 32767, -32768], 16)
  let sub = flac_t_finish(w)
  assert_eq(sub, b"\x02\x00\x01\xFF\xFE\x7F\xFF\x80\x00")
  let file = flac_t_file([(0, flac_t_mono16(4L))], flac_t_mono_frame(4, 0L, sub))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [1, -2, 32767, -32768])
}

///|
/// 9a) FIXED order 0：预测恒为 0，样本 == 反 zigzag 后的残差。
///     folded [0,2,1,4] → 残差 [0,1,-1,2]。
test "flac: FIXED order 0 解码" {
  let w = flac_t_bit_writer()
  flac_t_fixed_rice_into(w, 0, [], [0, 2, 1, 4], 16, 2, 0)
  let file = flac_t_file([(0, flac_t_mono16(4L))], flac_t_mono_frame(4, 0L, flac_t_finish(w)))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [0, 1, -1, 2])
}

///|
/// 9b) FIXED order 1：x[i] = r[i] + x[i-1]，warmup x[0] = 100。
///     残差 [0,1,1,-1,2,-2,0] → folded [0,2,2,1,4,3,0]
///     → [100, 100, 101, 102, 101, 103, 101, 101]。
test "flac: FIXED order 1 解码" {
  let w = flac_t_bit_writer()
  flac_t_fixed_rice_into(w, 1, [100], [0, 2, 2, 1, 4, 3, 0], 16, 2, 0)
  let file = flac_t_file([(0, flac_t_mono16(8L))], flac_t_mono_frame(8, 0L, flac_t_finish(w)))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [100, 100, 101, 102, 101, 103, 101, 101])
}

///|
/// 9c) FIXED order 2：x[i] = r[i] + 2*x[i-1] - x[i-2]。
///     warmup [10, 12]，残差全 0 → 等差数列 [10,12,14,16,18,20,22,24]。
test "flac: FIXED order 2 解码" {
  let w = flac_t_bit_writer()
  flac_t_fixed_rice_into(w, 2, [10, 12], [0, 0, 0, 0, 0, 0], 16, 2, 0)
  let file = flac_t_file([(0, flac_t_mono16(8L))], flac_t_mono_frame(8, 0L, flac_t_finish(w)))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [10, 12, 14, 16, 18, 20, 22, 24])
}

///|
/// 9d) FIXED order 3 与 order 4 的三/四项式系数（含负号）。
///     order 3：x[i] = r[i] + 3*x[i-1] - 3*x[i-2] + x[i-3]
///     warmup [0, 0, 0]，残差 [1, 0, 0, 0, 0]
///     → [0,0,0,1,3,6,10,15]（三阶差分恒定 → 三角形数）
test "flac: FIXED order 3/4 解码" {
  let w3 = flac_t_bit_writer()
  // folded [2,0,0,0,0] → 残差 [1,0,0,0,0]
  flac_t_fixed_rice_into(w3, 3, [0, 0, 0], [2, 0, 0, 0, 0], 16, 1, 0)
  let f3 = flac_t_file([(0, flac_t_mono16(8L))], flac_t_mono_frame(8, 0L, flac_t_finish(w3)))
  assert_eq(decode_flac(f3).samples, [0, 0, 0, 1, 3, 6, 10, 15])
  let w4 = flac_t_bit_writer()
  // order 4：x[i] = r[i] + 4x[i-1] - 6x[i-2] + 4x[i-3] - x[i-4]
  // warmup [0,0,0,0]，残差 [1,0,0,0] → [0,0,0,0,1,4,10,20]
  flac_t_fixed_rice_into(w4, 4, [0, 0, 0, 0], [2, 0, 0, 0], 16, 1, 0)
  let f4 = flac_t_file([(0, flac_t_mono16(8L))], flac_t_mono_frame(8, 0L, flac_t_finish(w4)))
  assert_eq(decode_flac(f4).samples, [0, 0, 0, 0, 1, 4, 10, 20])
}

///|
/// 10a) LPC order 1、precision 4、shift 1、系数 3：
///      x[i] = r[i] + ((3 * x[i-1]) >> 1)，warmup x[0] = 8，残差 [1,0,0,0,0,0,0]
///      → [8, 13, 19, 28, 42, 63, 94, 141]。
test "flac: LPC order 1 / shift 1 / 正系数" {
  let w = flac_t_bit_writer()
  flac_t_lpc_into(w, 1, [8], 4, 1, [3], [2, 0, 0, 0, 0, 0, 0], 16, 2)
  let file = flac_t_file([(0, flac_t_mono16(8L))], flac_t_mono_frame(8, 0L, flac_t_finish(w)))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [8, 13, 19, 28, 42, 63, 94, 141])
}

///|
/// 10b) LPC 负系数（验证系数按补码读取、以及负数算术右移）：
///      系数 -2、shift 1 → x[i] = r[i] - x[i-1]；
///      warmup x[0] = 100，残差 [5,0,0,0,0,0,0]
///      → [100, -95, 95, -95, 95, -95, 95, -95]。
test "flac: LPC order 1 / 负系数 / 负数右移" {
  let w = flac_t_bit_writer()
  // folded [10,0,...] → 残差 [5,0,...]
  flac_t_lpc_into(w, 1, [100], 4, 1, [-2], [10, 0, 0, 0, 0, 0, 0], 16, 2)
  let file = flac_t_file([(0, flac_t_mono16(8L))], flac_t_mono_frame(8, 0L, flac_t_finish(w)))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [100, -95, 95, -95, 95, -95, 95, -95])
}

///|
/// 10c) LPC precision 字段是 (precision-1)：precision=1 时字段为 0，
///      系数只能取 1 位补码值 -1/0。这里用 0 表示"预测恒为 0"，
///      结果应与 FIXED order 0 相同。
test "flac: LPC precision=1（字段 0）" {
  let w = flac_t_bit_writer()
  flac_t_lpc_into(w, 1, [42], 1, 0, [0], [0, 2, 1, 4], 16, 2)
  let file = flac_t_file([(0, flac_t_mono16(5L))], flac_t_mono_frame(5, 0L, flac_t_finish(w)))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [42, 0, 1, -1, 2])
}

///|
/// 11a) Rice 残差：k = 3，folded [0,1,2,3,4,5,6,7,38]
///      → [0,-1,1,-2,2,-3,3,-4,19]（38 = 0b100110 → q=4, r=6，取自规范示例）。
test "flac: Rice 残差反 zigzag" {
  let w = flac_t_bit_writer()
  flac_t_fixed_rice_into(w, 0, [], [0, 1, 2, 3, 4, 5, 6, 7, 38], 16, 3, 0)
  let file = flac_t_file([(0, flac_t_mono16(9L))], flac_t_mono_frame(9, 0L, flac_t_finish(w)))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [0, -1, 1, -2, 2, -3, 3, -4, 19])
}

///|
/// 11b) Rice2（coding method 01，5 位参数）：k = 16 超出 4 位参数范围，
///      只有按 5 位读才对。folded [0,2,4,6] → [0,1,2,3]。
test "flac: Rice2（5 位参数）残差" {
  let w = flac_t_bit_writer()
  flac_t_fixed_rice_into(w, 0, [], [0, 2, 4, 6], 16, 16, 1)
  let file = flac_t_file([(0, flac_t_mono16(4L))], flac_t_mono_frame(4, 0L, flac_t_finish(w)))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [0, 1, 2, 3])
}

///|
/// 11c) escape 分区：参数 1111 后跟 5 位位宽 n，残差按 n 位有符号原值存储。
test "flac: escape 分区" {
  let w = flac_t_bit_writer()
  flac_t_fixed_escape_into(w, 0, [], [7, -8, -1, 0], 16, 4)
  let file = flac_t_file([(0, flac_t_mono16(4L))], flac_t_mono_frame(4, 0L, flac_t_finish(w)))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [7, -8, -1, 0])
}

///|
/// 11d) escape 分区且 n = 0：该分区所有残差都是 0，不占任何位。
test "flac: escape 分区 n=0" {
  let w = flac_t_bit_writer()
  flac_t_fixed_escape_into(w, 0, [], [], 16, 0)
  let file = flac_t_file([(0, flac_t_mono16(5L))], flac_t_mono_frame(5, 0L, flac_t_finish(w)))
  let audio = decode_flac(file)
  assert_eq(audio.samples, [0, 0, 0, 0, 0])
}

///|
/// 11e) Rice2 的 escape（参数 11111 = 31）与 5 位位宽：
///      FIXED order 0、block_size 4、method 01、escape、n = 3、残差 [3,-4,0,3]。
test "flac: Rice2 escape 分区" {
  let w = flac_t_bit_writer()
  w.put(0, 1)
  w.put(8, 6) // FIXED order 0
  w.put(0, 1)
  w.put(1, 2) // method 01 = Rice2
  w.put(0, 4) // partition order 0
  w.put(31, 5) // 5 位参数全 1 = escape
  w.put(3, 5) // 每个残差 3 位
  w.put_signed(3, 3)
  w.put_signed(-4, 3)
  w.put_signed(0, 3)
  w.put_signed(3, 3)
  let file = flac_t_file([(0, flac_t_mono16(4L))], flac_t_mono_frame(4, 0L, flac_t_finish(w)))
  assert_eq(decode_flac(file).samples, [3, -4, 0, 3])
}

///|
/// 11f) 多分区残差（partition order = 1 → 2 个分区，各自带 Rice 参数，
///      且第一个分区的样本数要减去 predictor order）：
///      FIXED order 1、block_size 8、warmup x[0] = 10、7 个残差全为 1
///      → [10, 11, 12, 13, 14, 15, 16, 17]。
///      分区 0（3 个样本）用 k=0，分区 1（4 个样本）用 k=1。
test "flac: 多分区残差（partition order 1）" {
  let w = flac_t_bit_writer()
  w.put(0, 1)
  w.put(9, 6) // FIXED order 1
  w.put(0, 1)
  w.put_signed(10, 16)
  w.put(0, 2) // method 00
  w.put(1, 4) // partition order 1
  w.put(0, 4) // 分区 0：k = 0
  w.put_rice(2, 0)
  w.put_rice(2, 0)
  w.put_rice(2, 0)
  w.put(1, 4) // 分区 1：k = 1
  w.put_rice(2, 1)
  w.put_rice(2, 1)
  w.put_rice(2, 1)
  w.put_rice(2, 1)
  let file = flac_t_file([(0, flac_t_mono16(8L))], flac_t_mono_frame(8, 0L, flac_t_finish(w)))
  assert_eq(decode_flac(file).samples, [10, 11, 12, 13, 14, 15, 16, 17])
}

///|
/// 12a) 独立立体声（assignment 1）：按帧交织 [L0,R0,L1,R1,...]。
test "flac: 独立立体声交织" {
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [1, 2, 3], 16)
  flac_t_verbatim_into(w, [-1, -2, -3], 16)
  let frame = flac_t_frame(0, 6, 4, 1, 4, 0L, [b'\x02'], flac_t_finish(w))
  let si = flac_t_streaminfo(16, 65535, 0, 0, 8000, 2, 16, 3L, flac_t_zero_md5())
  let audio = decode_flac(flac_t_file([(0, si)], frame))
  assert_eq(audio.format, { sample_rate: 8000, channels: 2, bits_per_sample: 16 })
  assert_eq(audio.samples, [1, -1, 2, -2, 3, -3])
}

///|
/// 12b) 左+侧（assignment 8）：ch0 = left（16 位），ch1 = side（17 位），right = left - side。
///      left  [100, 200, -300, 400]
///      right [90, 210, -290, 410]
///      side = left - right = [10, -10, -10, -10]
///      → 交织 [100,90, 200,210, -300,-290, 400,410]
test "flac: 左+侧声道去相关（assignment 8）" {
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [100, 200, -300, 400], 16)
  flac_t_verbatim_into(w, [10, -10, -10, -10], 17)
  let frame = flac_t_frame(0, 6, 4, 8, 4, 0L, [b'\x03'], flac_t_finish(w))
  let si = flac_t_streaminfo(16, 65535, 0, 0, 8000, 2, 16, 4L, flac_t_zero_md5())
  let audio = decode_flac(flac_t_file([(0, si)], frame))
  assert_eq(audio.samples, [100, 90, 200, 210, -300, -290, 400, 410])
}

///|
/// 12c) 右+侧（assignment 9）：**ch0 = side（17 位），ch1 = right（16 位）**，
///      left = right + side。顺序取自 xiph format.html：
///      "1001 : right/side stereo: channel 0 is the side(difference) channel,
///       channel 1 is the right channel"。
///      同样的 left/right → side = [10,-10,-10,-10]、right = [90,210,-290,410]
///      → 交织 [100,90, 200,210, -300,-290, 400,410]。
///      若把 ch0/ch1 的顺序弄反，不只位宽错位，交织结果的奇数位也会变成 side。
test "flac: 右+侧声道去相关（assignment 9）" {
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [10, -10, -10, -10], 17) // ch0 = side
  flac_t_verbatim_into(w, [90, 210, -290, 410], 16) // ch1 = right
  let frame = flac_t_frame(0, 6, 4, 9, 4, 0L, [b'\x03'], flac_t_finish(w))
  let si = flac_t_streaminfo(16, 65535, 0, 0, 8000, 2, 16, 4L, flac_t_zero_md5())
  let audio = decode_flac(flac_t_file([(0, si)], frame))
  assert_eq(audio.samples, [100, 90, 200, 210, -300, -290, 400, 410])
}

///|
/// 12d) 中+侧（assignment 10）：mid = (L+R)>>1（16 位），side = L-R（17 位）。
///      left  [100, 201, -300, 401]，right [90, 200, -290, 400]
///      mid  [95, 200, -295, 400]，side [10, 1, -10, 1]
///      还原时 mid 左移 1 位并补上 side 的最低位（奇数 side 的情形必须还原正确）
///      → 交织 [100,90, 201,200, -300,-290, 401,400]。
test "flac: 中+侧声道去相关（assignment 10，含奇数 side）" {
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [95, 200, -295, 400], 16)
  flac_t_verbatim_into(w, [10, 1, -10, 1], 17)
  let frame = flac_t_frame(0, 6, 4, 10, 4, 0L, [b'\x03'], flac_t_finish(w))
  let si = flac_t_streaminfo(16, 65535, 0, 0, 8000, 2, 16, 4L, flac_t_zero_md5())
  let audio = decode_flac(flac_t_file([(0, si)], frame))
  assert_eq(audio.samples, [100, 90, 201, 200, -300, -290, 401, 400])
}

///|
/// 13a) 帧头 CRC-8 不符 → ChecksumMismatch。
test "flac: 帧头 CRC-8 不符 -> ChecksumMismatch" {
  let w = flac_t_bit_writer()
  flac_t_constant_into(w, 7, 16)
  let sub = flac_t_finish(w)
  let bad = flac_t_frame_ex(0, 6, 4, 0, 4, 0L, [b'\x0F'], sub, 1, 0)
  flac_t_expect_decode_error(flac_t_file([(0, flac_t_mono16(16L))], bad), "ChecksumMismatch")
}

///|
/// 13b) 帧尾 CRC-16 不符 → ChecksumMismatch。
test "flac: 帧尾 CRC-16 不符 -> ChecksumMismatch" {
  let w = flac_t_bit_writer()
  flac_t_constant_into(w, 7, 16)
  let sub = flac_t_finish(w)
  let bad = flac_t_frame_ex(0, 6, 4, 0, 4, 0L, [b'\x0F'], sub, 0, 1)
  flac_t_expect_decode_error(flac_t_file([(0, flac_t_mono16(16L))], bad), "ChecksumMismatch")
}

///|
/// 13c) 篡改子帧里的字节：帧头 CRC-8 仍然正确，但帧尾 CRC-16 覆盖整帧，必须报错。
test "flac: 子帧字节被篡改 -> ChecksumMismatch" {
  let w = flac_t_bit_writer()
  flac_t_constant_into(w, 7, 16)
  let sub = flac_t_finish(w)
  let frame = flac_t_frame(0, 6, 4, 0, 4, 0L, [b'\x0F'], sub)
  let file = flac_t_file([(0, flac_t_mono16(16L))], frame)
  let frame_start = file.length() - frame.length()
  // 帧头 7 字节（FF F8 64 08 00 0F + CRC-8），子帧 3 字节 00 00 07：
  // 改掉常量样本的高字节，帧头 CRC-8 仍然正确，但帧尾 CRC-16 必须发现。
  let corrupted = flac_t_patch_byte(file, frame_start + 8, 0x01)
  flac_t_expect_decode_error(corrupted, "ChecksumMismatch")
}

///|
/// 14) 固定块大小多帧流：帧号连续，样本按帧顺序拼接。
test "flac: 多帧拼接" {
  let w0 = flac_t_bit_writer()
  flac_t_verbatim_into(w0, [1, 2, 3, 4], 16)
  let w1 = flac_t_bit_writer()
  flac_t_verbatim_into(w1, [5, 6, 7, 8], 16)
  let frames = flac_t_join([
    flac_t_mono_frame(4, 0L, flac_t_finish(w0)),
    flac_t_mono_frame(4, 1L, flac_t_finish(w1)),
  ])
  let audio = decode_flac(flac_t_file([(0, flac_t_mono16(8L))], frames))
  assert_eq(audio.samples, [1, 2, 3, 4, 5, 6, 7, 8])
  assert_eq(audio.frame_count(), 8)
}

///|
/// 15) 可变块大小（blocking strategy 1）：帧号是首样本号，用 UTF-8 式变长整数编码。
///     这里刻意用 2 字节（300）与 7 字节（2^36-1）两种长度：
///     如果变长整数解析错位，帧头 CRC-8 立刻会不符。
test "flac: 可变块大小与多字节 UTF-8 帧号" {
  // 1 字节帧号（0）
  let wa = flac_t_bit_writer()
  flac_t_verbatim_into(wa, [11, 12], 16)
  let a = flac_t_file([(0, flac_t_mono16(2L))], flac_t_var_frame(2, 0L, flac_t_finish(wa)))
  assert_eq(decode_flac(a).samples, [11, 12])
  // 2 字节帧号（300）：0xC0|4 = 0xC4, 0x80|44 = 0xAC
  assert_eq(flac_t_utf8_number(300L), b"\xC4\xAC")
  let wb = flac_t_bit_writer()
  flac_t_verbatim_into(wb, [21, 22], 16)
  let b = flac_t_file([(0, flac_t_mono16(2L))], flac_t_var_frame(2, 300L, flac_t_finish(wb)))
  assert_eq(decode_flac(b).samples, [21, 22])
  // 7 字节帧号（2^36 - 1）：0xFE + 6 个续字节
  assert_eq(flac_t_utf8_number(68719476735L).length(), 7)
  let wc = flac_t_bit_writer()
  flac_t_verbatim_into(wc, [31, 32], 16)
  let c = flac_t_file([(0, flac_t_mono16(2L))], flac_t_var_frame(2, 68719476735L, flac_t_finish(wc)))
  assert_eq(decode_flac(c).samples, [31, 32])
}

///|
/// 16) total_samples 截断：最后一帧多出来的填充样本要被丢掉。
test "flac: 按 total_samples 截断" {
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [1, 2, 3, 4, 5, 6, 7, 8], 16)
  let file = flac_t_file([(0, flac_t_mono16(3L))], flac_t_mono_frame(8, 0L, flac_t_finish(w)))
  assert_eq(decode_flac(file).samples, [1, 2, 3])
}

///|
/// total_samples = 0 表示未知，此时应输出全部解码到的样本。
test "flac: total_samples=0 时输出全部样本" {
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [1, 2, 3, 4], 16)
  let file = flac_t_file([(0, flac_t_mono16(0L))], flac_t_mono_frame(4, 0L, flac_t_finish(w)))
  assert_eq(decode_flac(file).samples, [1, 2, 3, 4])
}

///|
/// 端到端：元数据 + 音频，标签应进入 `Audio.tags`，且可同时解析出格式信息。
test "flac: 端到端 metadata + 音频 + 标签" {
  let si = flac_t_streaminfo(4, 4, 0, 0, 44100, 1, 16, 4L, flac_t_zero_md5())
  let vc = flac_t_vorbis_comment(b"libFLAC 1.4.3", [b"title=Song", b"Artist=Someone"])
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [1000, -1000, 2000, -2000], 16)
  let frame = flac_t_frame(0, 6, 9, 0, 4, 0L, [b'\x03'], flac_t_finish(w))
  let file = flac_t_file([(0, si), (4, vc)], frame)
  let audio = decode_flac(file)
  assert_eq(audio.format, { sample_rate: 44100, channels: 1, bits_per_sample: 16 })
  assert_eq(audio.samples, [1000, -1000, 2000, -2000])
  assert_eq(audio.tags, [("TITLE", "Song"), ("ARTIST", "Someone")])
  assert_eq(flac_info(file), { sample_rate: 44100, channels: 1, bits_per_sample: 16 })
}

///|
/// 不支持的 / 保留的位型要抛 `Unsupported` 而不是 panic。
test "flac: 保留位型 -> Unsupported 或 InvalidMagic" {
  let si = flac_t_mono16(0L)
  let sub = flac_t_finish(flac_t_bit_writer())
  // 采样率位型 1111 被禁止
  let bad_sr = flac_t_frame(0, 6, 15, 0, 4, 0L, [b'\x03'], sub)
  flac_t_expect_decode_error(flac_t_file([(0, si)], bad_sr), "Unsupported")
  // 声道分配 1011 保留
  let bad_ch = flac_t_frame(0, 6, 4, 11, 4, 0L, [b'\x03'], sub)
  flac_t_expect_decode_error(flac_t_file([(0, si)], bad_ch), "Unsupported")
  // 位深位型 011 保留
  let bad_ss = flac_t_frame(0, 6, 4, 0, 3, 0L, [b'\x03'], sub)
  flac_t_expect_decode_error(flac_t_file([(0, si)], bad_ss), "Unsupported")
  // 子帧类型 000010 保留
  let w = flac_t_bit_writer()
  w.put(0, 1)
  w.put(2, 6)
  w.put(0, 1)
  let bad_sub = flac_t_frame(0, 6, 4, 0, 4, 0L, [b'\x03'], flac_t_finish(w))
  flac_t_expect_decode_error(flac_t_file([(0, si)], bad_sub), "Unsupported")
  // 残差编码方法 10 保留（FIXED order 0 子帧，读到方法位就应拒绝）
  let w2 = flac_t_bit_writer()
  w2.put(0, 1)
  w2.put(8, 6)
  w2.put(0, 1)
  w2.put(2, 2)
  let bad_method = flac_t_frame(0, 6, 4, 0, 4, 0L, [b'\x03'], flac_t_finish(w2))
  flac_t_expect_decode_error(flac_t_file([(0, si)], bad_method), "Unsupported")
}

///|
/// 帧数据被截断 → Truncated（不能 panic）。
test "flac: 帧截断 -> Truncated" {
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [1, 2, 3, 4], 16)
  let frame = flac_t_mono_frame(4, 0L, flac_t_finish(w))
  // 砍掉帧尾部 4 字节（含 CRC-16）
  let buf = Buffer()
  let mut i = 0
  while i < frame.length() - 4 {
    buf.write_byte(frame[i])
    i += 1
  }
  let file = flac_t_file([(0, flac_t_mono16(4L))], buf.to_bytes())
  flac_t_expect_decode_error(file, "Truncated")
}

///|
/// `flac_decoder` 在不改 `types.mbt` 的前提下无法实现，按约定抛 `Unsupported`。
test "flac: flac_decoder 抛 Unsupported" {
  let w = flac_t_bit_writer()
  flac_t_constant_into(w, 0, 16)
  let file = flac_t_file([(0, flac_t_mono16(16L))], flac_t_mono_frame(16, 0L, flac_t_finish(w)))
  let kind = try {
    ignore(flac_decoder(file))
    "<没有抛错>"
  } catch {
    AudioError::Unsupported(_) => "Unsupported"
    _ => "<其他错误>"
  }
  assert_eq(kind, "Unsupported")
}

///|
/// MD5 已知答案：8 位单声道样本 [97, 98, 99] 的 PCM 字节恰好是 ASCII "abc"，
/// 其 MD5 是公开的标准测试向量 900150983cd24fb0d6963f7d28e17f72。
/// 这条同时验证了 `flac.mbt` 里自带的 MD5 实现是对的。
test "flac: MD5 校验（标准向量 abc）" {
  let md5 = b"\x90\x01\x50\x98\x3C\xD2\x4F\xB0\xD6\x96\x3F\x7D\x28\xE1\x7F\x72"
  let si = flac_t_streaminfo(16, 65535, 0, 0, 8000, 1, 8, 3L, md5)
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [97, 98, 99], 8)
  let frame = flac_t_frame(0, 6, 4, 0, 1, 0L, [b'\x02'], flac_t_finish(w))
  let audio = decode_flac(flac_t_file([(0, si)], frame))
  assert_eq(audio.samples, [97, 98, 99])
}

///|
/// MD5 的样本序列化：16 位单声道 [1000, -1000, 2000, -2000]
/// → 小端字节 E8 03 18 FC D0 07 30 F8 → c704b47f331c8299710705221cee5a76
/// （期望值由 .NET `MD5` 独立算出）。
test "flac: MD5 校验（16 位小端序列化）" {
  let md5 = b"\xC7\x04\xB4\x7F\x33\x1C\x82\x99\x71\x07\x05\x22\x1C\xEE\x5A\x76"
  let si = flac_t_streaminfo(16, 65535, 0, 0, 8000, 1, 16, 4L, md5)
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [1000, -1000, 2000, -2000], 16)
  let frame = flac_t_frame(0, 6, 4, 0, 4, 0L, [b'\x03'], flac_t_finish(w))
  let audio = decode_flac(flac_t_file([(0, si)], frame))
  assert_eq(audio.samples, [1000, -1000, 2000, -2000])
}

///|
/// MD5 与解出来的样本不符 → ChecksumMismatch。
test "flac: MD5 不符 -> ChecksumMismatch" {
  let md5 = b"\xC7\x04\xB4\x7F\x33\x1C\x82\x99\x71\x07\x05\x22\x1C\xEE\x5A\x77"
  let si = flac_t_streaminfo(16, 65535, 0, 0, 8000, 1, 16, 4L, md5)
  let w = flac_t_bit_writer()
  flac_t_verbatim_into(w, [1000, -1000, 2000, -2000], 16)
  let frame = flac_t_frame(0, 6, 4, 0, 4, 0L, [b'\x03'], flac_t_finish(w))
  flac_t_expect_decode_error(flac_t_file([(0, si)], frame), "ChecksumMismatch")
}

///|
/// 端到端：完全由 Python 侧独立实现的 FLAC 编码器生成的 209 字节流
/// （单声道 8kHz/16bit、48 样本、3 个 16 样本帧、FIXED order 2、
/// partition order 2 的多分区 Rice；STREAMINFO 里带真实 MD5 = 7c0783e81c975174b4aa43fe29142241）。
/// 期望样本就是编码前的输入信号。
test "flac: 端到端解码独立编码器产生的多帧流" {
  let file = flac_t_hex(
  "664c6143000000220010001000000000000001f400f0000000307c0783e81c975174b4aa43fe291422418400003b0a00" +
  "00007079666c61632d726566020000000f0000005449544c453d526f756e6454726970120000006172746973743d696e" +
  "646570656e64656e74fff86408000fce14ffec042f0a362aacfaa9cd04a3d87c57d4a615176449946a803244fff86408" +
  "010fdb14fa49fb8a0a1c0541fdb61365ccf82987fd46b0fbafe98c2081ccfff86408020fe414f7bcf44f0a1b474a54d2" +
  "5243ddb3b99995ad585848cb8e44c0b607"
  )
  let audio = decode_flac(file)
  assert_eq(audio.format, { sample_rate: 8000, channels: 1, bits_per_sample: 16 })
  assert_eq(audio.tags, [("TITLE", "RoundTrip"), ("ARTIST", "independent")])
  assert_eq(audio.samples, [
  -20, 1071, 2073, 2904, 3500, 3782, 3803, 3537,
  3022, 2316, 1461, 611, -180, -834, -1286, -1525,
  -1463, -1142, -597, 116, 888, 1704, 2442, 3023,
  3379, 3430, 3226, 2739, 2000, 1069, -15, -1095,
  -2116, -2993, -3652, -4078, -4171, -3967, -3492, -2798,
  -1989, -1078, -190, 591, 1195, 1530, 1637, 1478,
  ])
  assert_eq(parse_flac_metadata(file).info.total_samples, 48L)
}
