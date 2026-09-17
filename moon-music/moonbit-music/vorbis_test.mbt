// moonbit-music —— vorbis.mbt 的黑盒测试。
//
// 只使用公开 API：`parse_vorbis_ident` / `parse_vorbis_comment` / `decode_vorbis`，
// 以及自检接口 `parse_vorbis_setup_codebooks`（codebook 层无法通过前三个函数观察到值，
// 因此这里把 codebook 解析结果暴露出来做断言）。
//
// 约定：所有**期望值**都是手工推导的常量，推导过程写在注释里；`VtWriter` 只用来构造
// **输入**字节流，它自身的 LSB-first 语义由 "bit writer 手算校验" 用例用字面量字节钉死。

// ---------------------------------------------------------------------------
// 测试用 LSB-first 位写入器（只用于构造输入）
// ---------------------------------------------------------------------------

///|
/// 测试用 LSB-first 位写入器：与 Vorbis bitpacking 约定一致——
/// 整数的 LSb 先写入当前字节最低的未使用位。
struct VtWriter {
  data : Array[Byte]
  mut count : Int
}

///|
/// 空写入器。
fn vt_writer() -> VtWriter {
  { data: [], count: 0 }
}

///|
/// 写入 `bits` 位的 `value`（低位先写）。
fn VtWriter::write(self : VtWriter, value : Int, bits : Int) -> Unit {
  for i = 0; i < bits; i = i + 1 {
    let bit = (value >> i) & 1
    let byte_index = self.count / 8
    let bit_index = self.count % 8
    if byte_index == self.data.length() {
      self.data.push(b'\x00')
    }
    if bit == 1 {
      let cur = self.data[byte_index].to_int()
      self.data[byte_index] = (cur | (1 << bit_index)).to_byte()
    }
    self.count = self.count + 1
  }
}

///|
/// 按字节写入（每字节 8 位，走同一条 LSB-first 路径）。
fn VtWriter::write_all(self : VtWriter, bytes : Array[Byte]) -> Unit {
  for b in bytes {
    self.write(b.to_int(), 8)
  }
}

///|
/// 当前内容（未写满的末字节高位补 0，符合规范 §2.1.8）。
fn VtWriter::to_bytes(self : VtWriter) -> Bytes {
  Bytes::from_array(self.data)
}

///|
/// header 的 7 字节前缀：`[type]` + "vorbis"。
fn vt_prefix(packet_type : Int) -> Array[Byte] {
  [packet_type.to_byte(), b'v', b'o', b'r', b'b', b'i', b's']
}

// ---------------------------------------------------------------------------
// 调用辅助：测试块里不能带 raise，这里统一转换
// ---------------------------------------------------------------------------

///|
/// 解析 ident header，意外抛错即测试失败。
fn vt_ident(data : Bytes) -> VorbisInfo {
  try {
    parse_vorbis_ident(data)
  } catch {
    _ => abort("parse_vorbis_ident 意外抛错")
  }
}

///|
/// 解析 comment header，意外抛错即测试失败。
fn vt_comment(data : Bytes) -> (String, Array[(String, String)]) {
  try {
    parse_vorbis_comment(data)
  } catch {
    _ => abort("parse_vorbis_comment 意外抛错")
  }
}

///|
/// 解析 setup header 里的 codebook 段，意外抛错即测试失败。
fn vt_books(data : Bytes) -> Array[VorbisCodebookInfo] {
  try {
    parse_vorbis_setup_codebooks(data)
  } catch {
    _ => abort("parse_vorbis_setup_codebooks 意外抛错")
  }
}

///| 断言 f 抛 `Truncated`。|
fn vt_truncated(f : () -> Unit raise AudioError) -> Bool {
  try {
    f()
    false
  } catch {
    AudioError::Truncated(_) => true
    _ => false
  }
}

///| 断言 f 抛 `InvalidMagic`。|
fn vt_invalid_magic(f : () -> Unit raise AudioError) -> Bool {
  try {
    f()
    false
  } catch {
    AudioError::InvalidMagic(_) => true
    _ => false
  }
}

///| 断言 f 抛 `Unsupported`。|
fn vt_unsupported(f : () -> Unit raise AudioError) -> Bool {
  try {
    f()
    false
  } catch {
    AudioError::Unsupported(_) => true
    _ => false
  }
}

///| 取 f 抛出的 `Unsupported` 消息；其它情况返回空串。|
fn vt_unsupported_message(f : () -> Unit raise AudioError) -> String {
  try {
    f()
    ""
  } catch {
    AudioError::Unsupported(msg) => msg
    _ => ""
  }
}

// ---------------------------------------------------------------------------
// 手工字节流
// ---------------------------------------------------------------------------

///|
/// 合法的 identification header（30 字节，全部手工写出）：
/// ```
/// 01 76 6F 72 62 69 73   "\x01vorbis"
/// 00 00 00 00            vorbis_version = 0
/// 02                     audio_channels = 2
/// 44 AC 00 00            audio_sample_rate = 0x0000AC44 = 44100（小端）
/// 00 00 00 00            bitrate_maximum = 0
/// 00 F4 01 00            bitrate_nominal = 0x0001F400 = 128000（小端）
/// 00 00 00 00            bitrate_minimum = 0
/// 86                     blocksize_0 指数 = 低 4 位 = 6 → 64；blocksize_1 指数 = 高 4 位 = 8 → 256
/// 01                     framing_flag = bit0 = 1
/// ```
fn vt_ident_ok() -> Bytes {
  Bytes::from_array([
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x02',
    b'\x44', b'\xAC', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\xF4', b'\x01', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x86',
    b'\x01',
  ])
}

///|
/// 改一个字节的 ident header（只用于构造非法输入）。
fn vt_ident_with(index : Int, value : Int) -> Bytes {
  let src = vt_ident_ok()
  let out : Array[Byte] = []
  for i = 0; i < src.length(); i = i + 1 {
    if i == index {
      out.push(value.to_byte())
    } else {
      out.push(src[i])
    }
  }
  Bytes::from_array(out)
}

///|
/// 取前 n 个字节（构造截断输入）。
fn vt_take(data : Bytes, n : Int) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < n; i = i + 1 {
    out.push(data[i])
  }
  Bytes::from_array(out)
}

// ---------------------------------------------------------------------------
// 1. 位序：LSB-first
// ---------------------------------------------------------------------------

test "bit writer 手算校验：LSB-first 打包" {
  // 依次写入：1(1 位)、0(1 位)、5(3 位)、0x1234(16 位)，共 21 位。
  //
  // 手算：流的位序（按写入顺序，也就是每个值的 bit0 起）
  //   1, 0, 1,0,1, 0,0,1,0,1,1,0,0, 0,1,0,0,1,0,0,0
  //   0x1234 = 0b0001_0010_0011_0100，低字节 0x34 = 0b00110100 → 位 0..7 = 0,0,1,0,1,1,0,0
  //                                          高字节 0x12 = 0b00010010 → 位 8..15 = 0,1,0,0,1,0,0,0
  // byte0 = 流的位 0..7 = [1,0,1,0,1,0,0,1] → 2^0+2^2+2^4+2^7 = 1+4+16+128 = 149 = 0x95
  // byte1 = 流的位 8..15 = [0,1,1,0,0,0,1,0] → 2+4+64 = 70 = 0x46
  // byte2 = 流的位 16..20 = [0,1,0,0,0]（其余补 0）→ 2 = 0x02
  let w = vt_writer()
  w.write(1, 1)
  w.write(0, 1)
  w.write(5, 3)
  w.write(0x1234, 16)
  assert_eq(w.to_bytes(), Bytes::from_array([b'\x95', b'\x46', b'\x02']))
}

test "ident: LSB-first 判别——blocksize 字节 0x86 合法、0x68 报错" {
  // 参考包最后一字节之前是 blocksize 字节（下标 28）。
  // LSB-first：先读低 4 位当 blocksize_0 指数，再读高 4 位当 blocksize_1 指数。
  //   0x86 → bs0 指数 6（64）、bs1 指数 8（256），合法。
  //   0x68 → bs0 指数 8（256）、bs1 指数 6（64），bs0 > bs1 → InvalidMagic。
  // 若实现是 MSB-first，这两个结果会完全反过来。
  let info = vt_ident(vt_ident_ok())
  assert_eq(info.channels, 2)
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_ident(vt_ident_with(28, 0x68))) }))
}

test "ident: LSB-first 判别——framing 字节 0x01 合法、0x80 报错" {
  // framing_flag 是最后一个字节的 bit0。
  //   0x01 → bit0 = 1 → 合法；0x80 → bit0 = 0（bit7 才是 1）→ InvalidMagic。
  // MSB-first 实现的判断会反号。
  ignore(vt_ident(vt_ident_with(29, 0x01)))
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_ident(vt_ident_with(29, 0x80))) }))
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_ident(vt_ident_with(29, 0x00))) }))
}

test "ident: sample_rate 的小端字节序" {
  // 0x44 0xAC 0x00 0x00 小端 = 0x0000AC44 = 44100。
  // 若按大端读会得到 0x44AC0000，断言 44100 即可排除。
  assert_eq(vt_ident(vt_ident_ok()).sample_rate, 44100)
}

// ---------------------------------------------------------------------------
// 2. identification header 全字段
// ---------------------------------------------------------------------------

test "ident: 全部字段（含 0 bitrate 与空 comments）" {
  let info = vt_ident(vt_ident_ok())
  assert_eq(info.channels, 2)
  assert_eq(info.sample_rate, 44100)
  assert_eq(info.bitrate_max, 0)
  assert_eq(info.bitrate_nominal, 128000)
  assert_eq(info.bitrate_min, 0)
  assert_eq(info.comments.length(), 0)
}

test "ident: 负 bitrate（32 位有符号）" {
  // bitrate_maximum = 0xFFFFFFFF = -1；bitrate_minimum = 0xFFFFE0C0 = -8000。
  // （4 字节全部手工写出，小端。）
  let data = Bytes::from_array([
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x01',
    b'\x80', b'\xBB', b'\x00', b'\x00', // 48000 = 0x0000BB80
    b'\xFF', b'\xFF', b'\xFF', b'\xFF', // -1
    b'\x00', b'\xF4', b'\x01', b'\x00', // 128000
    b'\xC0', b'\xE0', b'\xFF', b'\xFF', // -8000 = 0xFFFFE0C0
    b'\x66', // bs0 指数 6（64）、bs1 指数 6（64）
    b'\x01',
  ])
  let info = vt_ident(data)
  assert_eq(info.channels, 1)
  assert_eq(info.sample_rate, 48000)
  assert_eq(info.bitrate_max, -1)
  assert_eq(info.bitrate_nominal, 128000)
  assert_eq(info.bitrate_min, -8000)
}

test "ident: version != 0 → Unsupported" {
  // version 字段在字节 7..10，写成 01 00 00 00 即 version = 1。
  assert_true(vt_unsupported(() => { ignore(parse_vorbis_ident(vt_ident_with(7, 1))) }))
}

test "ident: framing_flag != 1 → InvalidMagic" {
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_ident(vt_ident_with(29, 0))) }))
}

test "ident: 魔数不对 → InvalidMagic" {
  // 用 comment header 的前缀喂给 ident 解析。
  let data = Bytes::from_array([
    b'\x03', b'v', b'o', b'r', b'b', b'i', b's',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x02',
    b'\x44', b'\xAC', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\xF4', b'\x01', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x86',
    b'\x01',
  ])
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_ident(data)) }))
}

test "ident: channels = 0 与 sample_rate = 0 → InvalidMagic" {
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_ident(vt_ident_with(11, 0))) }))
  // sample_rate 字段在字节 12..15，全部写 0
  let data = Bytes::from_array([
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x02',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\xF4', b'\x01', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x86',
    b'\x01',
  ])
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_ident(data)) }))
}

test "ident: sample_rate 最高位为 1（负数）→ InvalidMagic" {
  // 0x80000000 小端 = 00 00 00 80，作为有符号 32 位是 -2147483648。
  let data = Bytes::from_array([
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x02',
    b'\x00', b'\x00', b'\x00', b'\x80',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\xF4', b'\x01', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x86',
    b'\x01',
  ])
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_ident(data)) }))
}

test "ident: blocksize 越界（指数 5 → 32 < 64）→ Unsupported" {
  // 0x85：bs0 指数 5 → 32，超出 Vorbis I 允许的 64..8192。
  // 注意 32 <= 128，所以先被 blocksize 合法性拦下。
  assert_true(vt_unsupported(() => { ignore(parse_vorbis_ident(vt_ident_with(28, 0x85))) }))
}

test "ident: 截断 → Truncated" {
  let full = vt_ident_ok()
  // 前缀都不完整
  assert_true(vt_truncated(() => { ignore(parse_vorbis_ident(vt_take(full, 3))) }))
  // 只有前缀（缺 version 等）
  assert_true(vt_truncated(() => { ignore(parse_vorbis_ident(vt_take(full, 7))) }))
  // 缺最后一个 framing 字节
  assert_true(vt_truncated(() => { ignore(parse_vorbis_ident(vt_take(full, 29))) }))
}

// ---------------------------------------------------------------------------
// 3. comment header
// ---------------------------------------------------------------------------

///|
/// 手工构造的 comment header：vendor = "moonbit-music"，两条 comment：
/// "ARTIST=Bob"、"TITLE=Song"，结尾 framing 字节 0x01。
/// ```
/// 03 76 6F 72 62 69 73      "\x03vorbis"
/// 09 00 00 00               vendor_length = 9
/// 6D 6F 6F 6E 61 75 64 69 6F   "moonbit-music"
/// 02 00 00 00               user_comment_count = 2
/// 0A 00 00 00               length = 10
/// 41 52 54 49 53 54 3D 42 6F 62   "ARTIST=Bob"
/// 0A 00 00 00               length = 10
/// 54 49 54 4C 45 3D 53 6F 6E 67   "TITLE=Song"
/// 01                        framing
/// ```
fn vt_comment_ok() -> Bytes {
  Bytes::from_array([
    b'\x03', b'v', b'o', b'r', b'b', b'i', b's',
    b'\x09', b'\x00', b'\x00', b'\x00',
    b'\x6D', b'\x6F', b'\x6F', b'\x6E', b'\x61', b'\x75', b'\x64', b'\x69', b'\x6F',
    b'\x02', b'\x00', b'\x00', b'\x00',
    b'\x0A', b'\x00', b'\x00', b'\x00',
    b'\x41', b'\x52', b'\x54', b'\x49', b'\x53', b'\x54', b'\x3D', b'\x42', b'\x6F', b'\x62',
    b'\x0A', b'\x00', b'\x00', b'\x00',
    b'\x54', b'\x49', b'\x54', b'\x4C', b'\x45', b'\x3D', b'\x53', b'\x6F', b'\x6E', b'\x67',
    b'\x01',
  ])
}

test "comment: vendor + 多条 comment" {
  let (vendor, comments) = vt_comment(vt_comment_ok())
  assert_eq(vendor, "moonbit-music")
  assert_eq(comments.length(), 2)
  assert_eq(comments[0], ("ARTIST", "Bob"))
  assert_eq(comments[1], ("TITLE", "Song"))
}

test "comment: 空 comment 列表" {
  // 同样的字节流，只把 user_comment_count 改成 0，并去掉两条 comment。
  let data = Bytes::from_array([
    b'\x03', b'v', b'o', b'r', b'b', b'i', b's',
    b'\x09', b'\x00', b'\x00', b'\x00',
    b'\x6D', b'\x6F', b'\x6F', b'\x6E', b'\x61', b'\x75', b'\x64', b'\x69', b'\x6F',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x01',
  ])
  let (vendor, comments) = vt_comment(data)
  assert_eq(vendor, "moonbit-music")
  assert_eq(comments.length(), 0)
}

test "comment: 没有 '=' 的条目、空 value、多个 '='" {
  // three entries:
  //   "NOVALUE"       (7 字节，无 '=') → ("NOVALUE", "")
  //   "A="            (2 字节)         → ("A", "")
  //   "B=x=y"         (5 字节)         → ("B", "x=y")（只在第一个 '=' 处切）
  let data = Bytes::from_array([
    b'\x03', b'v', b'o', b'r', b'b', b'i', b's',
    b'\x01', b'\x00', b'\x00', b'\x00',
    b'\x56', // vendor = "V"
    b'\x03', b'\x00', b'\x00', b'\x00',
    b'\x07', b'\x00', b'\x00', b'\x00',
    b'\x4E', b'\x4F', b'\x56', b'\x41', b'\x4C', b'\x55', b'\x45',
    b'\x02', b'\x00', b'\x00', b'\x00',
    b'\x41', b'\x3D',
    b'\x05', b'\x00', b'\x00', b'\x00',
    b'\x42', b'\x3D', b'\x78', b'\x3D', b'\x79',
    b'\x01',
  ])
  let (vendor, comments) = vt_comment(data)
  assert_eq(vendor, "V")
  assert_eq(comments.length(), 3)
  assert_eq(comments[0], ("NOVALUE", ""))
  assert_eq(comments[1], ("A", ""))
  assert_eq(comments[2], ("B", "x=y"))
}

test "comment: UTF-8 vendor 与 value" {
  // vendor = "音频" (E9 9F B3 E9 A2 91, 6 字节)；comment = "K=值"（"K=" + E5 80 BC，共 5 字节）
  let data = Bytes::from_array([
    b'\x03', b'v', b'o', b'r', b'b', b'i', b's',
    b'\x06', b'\x00', b'\x00', b'\x00',
    b'\xE9', b'\x9F', b'\xB3', b'\xE9', b'\xA2', b'\x91',
    b'\x01', b'\x00', b'\x00', b'\x00',
    b'\x05', b'\x00', b'\x00', b'\x00',
    b'\x4B', b'\x3D', b'\xE5', b'\x80', b'\xBC',
    b'\x01',
  ])
  let (vendor, comments) = vt_comment(data)
  assert_eq(vendor, "音频")
  assert_eq(comments[0], ("K", "值"))
}

test "comment: framing bit 未置位 → InvalidMagic" {
  let src = vt_comment_ok()
  let out : Array[Byte] = []
  for i = 0; i < src.length(); i = i + 1 {
    if i == src.length() - 1 {
      out.push(b'\x00')
    } else {
      out.push(src[i])
    }
  }
  let data = Bytes::from_array(out)
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_comment(data)) }))
}

test "comment: 魔数不对 → InvalidMagic（拿 ident header 喂进去）" {
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_comment(vt_ident_ok())) }))
}

test "comment: 截断 → Truncated" {
  let full = vt_comment_ok()
  // 只有前缀
  assert_true(vt_truncated(() => { ignore(parse_vorbis_comment(vt_take(full, 7))) }))
  // vendor_length = 9 但只剩下 4 个字节
  assert_true(vt_truncated(() => { ignore(parse_vorbis_comment(vt_take(full, 16))) }))
  // 声明 3 条 comment，实际只给了 2 条（第 3 条的长度字段就缺了）
  let lying_count = Bytes::from_array([
    b'\x03', b'v', b'o', b'r', b'b', b'i', b's',
    b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x03', b'\x00', b'\x00', b'\x00',
    b'\x04', b'\x00', b'\x00', b'\x00',
    b'\x41', b'\x3D', b'\x31', b'\x32',
    b'\x04', b'\x00', b'\x00', b'\x00',
    b'\x42', b'\x3D', b'\x31', b'\x32',
  ])
  assert_true(vt_truncated(() => { ignore(parse_vorbis_comment(lying_count)) }))
}

// ---------------------------------------------------------------------------
// 4. codebook
// ---------------------------------------------------------------------------

test "codebook: 非 ordered 非 sparse，长度表 [1,2,3,3] 与规范码字" {
  // 手工写一个 setup header 的 codebook 段：
  //   codebook_count - 1 = 0        → 1 个 codebook
  //   sync = 0x564342 (24 位)
  //   dimensions = 1 (16 位)、entries = 4 (24 位)
  //   ordered = 0、sparse = 0
  //   4 个 entry 各 5 位：0,1,2,2 → 长度 1,2,3,3
  //   lookup_type = 0
  //
  // 期望码字（规范 §3.2.1 的分配规则，手工推）：
  //   entry0 长度 1 → 最低可用 1 位码字 '0'
  //   entry1 长度 2 → '0' 已占用，剩 '10' → 数值 2
  //   entry2 长度 3 → '10' 已占用前缀，剩 '110' → 数值 6
  //   entry3 长度 3 → '111' → 数值 7
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(4, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(0, 5)
  w.write(1, 5)
  w.write(2, 5)
  w.write(2, 5)
  w.write(0, 4)
  let books = vt_books(w.to_bytes())
  assert_eq(books.length(), 1)
  let cb = books[0]
  assert_eq(cb.dimensions, 1)
  assert_eq(cb.entries, 4)
  assert_eq(cb.ordered, false)
  assert_eq(cb.sparse, false)
  assert_eq(cb.lengths, [1, 2, 3, 3])
  assert_eq(cb.codewords, [0, 2, 6, 7])
  assert_eq(cb.lookup_type, 0)
  assert_eq(cb.multiplicands.length(), 0)
}

test "codebook: 规范 §3.2.1 的码字分配例子" {
  // 长度表 [2,4,4,4,4,2,3,3]（非 ordered、非 sparse），规范给出的码字是
  //   00、0100、0101、0110、0111、10、110、111
  // 即数值 0、4、5、6、7、2、6、7 —— 逐项手工对照规范原文：
  //   entry0 长度 2 → 00      = 0
  //   entry1 长度 4 → 0100    = 4
  //   entry2 长度 4 → 0101    = 5
  //   entry3 长度 4 → 0110    = 6
  //   entry4 长度 4 → 0111    = 7
  //   entry5 长度 2 → 10      = 2（不是 01：01 已是 0100..0111 的前缀）
  //   entry6 长度 3 → 110     = 6
  //   entry7 长度 3 → 111     = 7
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(8, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(1, 5) // entry0 长度 2
  w.write(3, 5) // entry1 长度 4
  w.write(3, 5) // entry2 长度 4
  w.write(3, 5) // entry3 长度 4
  w.write(3, 5) // entry4 长度 4
  w.write(1, 5) // entry5 长度 2
  w.write(2, 5) // entry6 长度 3
  w.write(2, 5) // entry7 长度 3
  w.write(0, 4)
  let cb = vt_books(w.to_bytes())[0]
  assert_eq(cb.lengths, [2, 4, 4, 4, 4, 2, 3, 3])
  assert_eq(cb.codewords, [0, 4, 5, 6, 7, 2, 6, 7])
}

test "codebook: ordered 长度表（两组长度）" {
  // entries = 6，ordered = 1，长度 [2,2,3,3,3,3]（Kraft: 2/4 + 4/8 = 1，完整树）
  // ordered 编码：先读 5 位初始长度，再反复读 ilog(剩余 entry) 位的个数：
  //   初始长度 5 位写 1 → current_length = 2
  //   个数 = ilog(6-0) = ilog(6) = 3 位，写 2 → 2 个 entry 用长度 2
  //   个数 = ilog(6-2) = ilog(4) = 3 位，写 4 → 4 个 entry 用长度 3
  // 手工推码字：
  //   entry0 长度 2 → 00 = 0；entry1 长度 2 → 01 = 1
  //   entry2 长度 3 → 100 = 4；entry3 → 101 = 5；entry4 → 110 = 6；entry5 → 111 = 7
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(6, 24)
  w.write(1, 1) // ordered = 1
  w.write(1, 5) // 初始长度 = 1+1 = 2
  w.write(2, 3) // 2 个 entry
  w.write(4, 3) // 4 个 entry
  w.write(0, 4) // lookup_type = 0
  let cb = vt_books(w.to_bytes())[0]
  assert_eq(cb.ordered, true)
  assert_eq(cb.lengths, [2, 2, 3, 3, 3, 3])
  assert_eq(cb.codewords, [0, 1, 4, 5, 6, 7])
}

test "codebook: sparse（未使用 entry 记为 0，码字为 -1）" {
  // entries = 4，ordered = 0，sparse = 1，present 标志依次 1,0,1,0：
  //   使用中的是 entry0 与 entry2，长度都是 1（Kraft: 1/2 + 1/2 = 1）
  // 手工推码字：entry0 → '0' = 0；entry2 → '1' = 1；entry1、entry3 未使用 → -1
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(4, 24)
  w.write(0, 1) // ordered = 0
  w.write(1, 1) // sparse = 1
  w.write(1, 1)
  w.write(0, 5) // entry0 长度 1
  w.write(0, 1) // entry1 未使用
  w.write(1, 1)
  w.write(0, 5) // entry2 长度 1
  w.write(0, 1) // entry3 未使用
  w.write(0, 4) // lookup_type = 0
  let cb = vt_books(w.to_bytes())[0]
  assert_eq(cb.sparse, true)
  assert_eq(cb.lengths, [1, 0, 1, 0])
  assert_eq(cb.codewords, [0, -1, 1, -1])
}

test "codebook: lookup type 1 与 Vorbis 自定义浮点" {
  // dimensions = 1、entries = 4、长度全 2（Kraft: 4 * 1/4 = 1）
  // lookup_type = 1 → lookup_values = lookup1_values(4, 1) = 4（4^1 <= 4）
  //
  // 浮点手算依据规范 §9.2.2：value = mantissa * 2^(exponent - 788)
  //   minimum_value = 1.0：取 mantissa = 0x100000 = 2^20，则 2^20 * 2^(e-788) = 1 → e = 768
  //     packed = (768 << 21) | 0x100000 = 0x60000000 | 0x100000 = 0x60100000
  //   delta_value = -0.5：mantissa = 2^20 取负，2^20 * 2^(e-788) = 0.5 → e = 767
  //     packed = 0x80000000 | (767 << 21) | 0x100000
  //            = 0x80000000 | 0x5FE00000 | 0x100000 = 0xDFF00000
  // value_bits 写 3 → 4；sequence_p = 0；4 个 multiplicand 各 4 位，写 0,1,2,3
  let min_packed = (768L << 21) | 0x100000L
  let delta_packed = 0x80000000L | (767L << 21) | 0x100000L
  assert_eq(min_packed, 0x60100000L)
  assert_eq(delta_packed, 0xDFF00000L)
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(4, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(1, 5)
  w.write(1, 5)
  w.write(1, 5)
  w.write(1, 5)
  w.write(1, 4) // lookup_type = 1
  w.write(min_packed.to_int(), 32)
  w.write(delta_packed.to_int(), 32)
  w.write(3, 4) // value_bits = 4
  w.write(0, 1) // sequence_p = 0
  w.write(0, 4)
  w.write(1, 4)
  w.write(2, 4)
  w.write(3, 4)
  let cb = vt_books(w.to_bytes())[0]
  assert_eq(cb.lookup_type, 1)
  assert_eq(cb.minimum_value, 1.0)
  assert_eq(cb.delta_value, -0.5)
  assert_eq(cb.value_bits, 4)
  assert_eq(cb.sequence_p, false)
  assert_eq(cb.multiplicands, [0, 1, 2, 3])
}

test "codebook: lookup type 2（值表 = entries * dimensions，sequence_p = 1）" {
  // dimensions = 2、entries = 2、长度 [1,1]（Kraft: 1/2 + 1/2 = 1）
  // lookup_type = 2 → lookup_values = entries * dimensions = 4
  //   delta_value = 0.25：mantissa = 2^20，2^20 * 2^(e-788) = 0.25 = 2^-2 → e = 766
  //     packed = (766 << 21) | 0x100000 = 0x5FC00000 | 0x100000 = 0x5FD00000
  //   minimum_value = 0 → packed = 0
  // value_bits 写 1 → 2；sequence_p = 1；4 个 multiplicand 各 2 位：0,1,2,3
  let delta_packed = (766L << 21) | 0x100000L
  assert_eq(delta_packed, 0x5FD00000L)
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(2, 16)
  w.write(2, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(0, 5)
  w.write(0, 5)
  w.write(2, 4) // lookup_type = 2
  w.write(0, 32) // minimum_value = 0
  w.write(delta_packed.to_int(), 32)
  w.write(1, 4) // value_bits = 2
  w.write(1, 1) // sequence_p = 1
  w.write(0, 2)
  w.write(1, 2)
  w.write(2, 2)
  w.write(3, 2)
  let cb = vt_books(w.to_bytes())[0]
  assert_eq(cb.lookup_type, 2)
  assert_eq(cb.minimum_value, 0.0)
  assert_eq(cb.delta_value, 0.25)
  assert_eq(cb.value_bits, 2)
  assert_eq(cb.sequence_p, true)
  assert_eq(cb.multiplicands, [0, 1, 2, 3])
}

test "codebook: 多个 codebook（count 字节 = n-1）" {
  // 两个 codebook：第一个 dimensions=1/entries=2/长度 [1,1]/lookup 0；
  // 第二个 dimensions=3/entries=2/长度 [1,1]/lookup 0。
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(1, 8) // codebook_count - 1 = 1 → 2 个
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(2, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(0, 5)
  w.write(0, 5)
  w.write(0, 4)
  w.write(0x564342, 24)
  w.write(3, 16)
  w.write(2, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(0, 5)
  w.write(0, 5)
  w.write(0, 4)
  let books = vt_books(w.to_bytes())
  assert_eq(books.length(), 2)
  assert_eq(books[0].dimensions, 1)
  assert_eq(books[0].codewords, [0, 1])
  assert_eq(books[1].dimensions, 3)
  assert_eq(books[1].entries, 2)
  assert_eq(books[1].codewords, [0, 1])
}

test "codebook: 同步字错误 → InvalidMagic" {
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564341, 24) // 少 1
  w.write(1, 16)
  w.write(2, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(0, 5)
  w.write(0, 5)
  w.write(0, 4)
  let data = w.to_bytes()
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_setup_codebooks(data)) }))
}

test "codebook: entries = 0 → InvalidMagic" {
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(0, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(0, 4)
  let data = w.to_bytes()
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_setup_codebooks(data)) }))
}

test "codebook: lookup_type = 3（保留值）→ Unsupported" {
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(2, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(0, 5)
  w.write(0, 5)
  w.write(3, 4)
  let data = w.to_bytes()
  assert_true(vt_unsupported(() => { ignore(parse_vorbis_setup_codebooks(data)) }))
}

test "codebook: Huffman 树欠指定（Kraft 和 != 1）→ InvalidMagic" {
  // 3 个 entry 长度都是 2：Kraft = 3/4 != 1。
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(3, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(1, 5)
  w.write(1, 5)
  w.write(1, 5)
  w.write(0, 4)
  let data = w.to_bytes()
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_setup_codebooks(data)) }))
}

test "codebook: Huffman 树过指定（码字溢出）→ InvalidMagic" {
  // 3 个 entry 长度都是 1：第 3 个码字需要 '10'/2，超过 1 位能表示的范围。
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(3, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(0, 5)
  w.write(0, 5)
  w.write(0, 5)
  w.write(0, 4)
  let data = w.to_bytes()
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_setup_codebooks(data)) }))
}

test "codebook: ordered 长度表写出界 → InvalidMagic" {
  // entries = 4，ordered：初始长度 = 1，个数写 5（3 位能表示 5）→ 5 > 4。
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(4, 24)
  w.write(1, 1) // ordered
  w.write(0, 5) // 长度 = 1
  w.write(5, 3) // ilog(4) = 3 位，写 5
  let data = w.to_bytes()
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_setup_codebooks(data)) }))
}

test "codebook: 截断 → Truncated" {
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(4, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(0, 5)
  let data = w.to_bytes()
  assert_true(vt_truncated(() => { ignore(parse_vorbis_setup_codebooks(data)) }))
  // 连前缀都不完整
  assert_true(vt_truncated(() => { ignore(parse_vorbis_setup_codebooks(vt_take(data, 4))) }))
}

test "codebook: setup 前缀错误 → InvalidMagic" {
  assert_true(vt_invalid_magic(() => { ignore(parse_vorbis_setup_codebooks(vt_ident_ok())) }))
}

// ---------------------------------------------------------------------------
// 5. setup header 校验 + decode_vorbis
// ---------------------------------------------------------------------------

///|
/// 手工拼一个结构最小的完整 setup header：
/// 1 个 codebook（dim=1、entries=2、长度 [1,1]、无 lookup）
/// + 1 个 time transform（必须为 0）+ 1 个 floor + 1 个 residue + 1 个 mapping + 1 个 mode
/// + framing bit。
///
/// 参数用于构造非法变体：
/// - `floor_type`：floor 类型（0/1 合法）
/// - `residue_type`：residue 类型（0/1/2 合法）
/// - `mode_mapping`：mode 引用的 mapping 号（必须 < mapping 数量 = 1）
/// - `framing`：setup 结尾的 framing bit
fn vt_setup(
  floor_type : Int,
  residue_type : Int,
  mode_mapping : Int,
  framing : Int,
) -> Bytes {
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  // codebook 0
  w.write(0, 8) // codebook_count - 1 = 0
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(2, 24)
  w.write(0, 1) // ordered
  w.write(0, 1) // sparse
  w.write(0, 5) // entry0 长度 1
  w.write(0, 5) // entry1 长度 1
  w.write(0, 4) // lookup_type = 0
  // time domain transforms
  w.write(0, 6) // time_count - 1 = 0
  w.write(0, 16)
  // floors
  w.write(0, 6) // floor_count - 1 = 0
  w.write(floor_type, 16)
  if floor_type == 0 {
    w.write(1, 8) // order
    w.write(0, 16) // rate
    w.write(0, 16) // bark_map_size
    w.write(0, 6) // amplitude_bits
    w.write(0, 8) // amplitude_offset
    w.write(0, 4) // number_of_books = 1
    w.write(0, 8) // book_list[0] = codebook 0
  } else {
    // floor 1：partitions = 1，class 0（dimensions = 1、subclasses = 0、book 0），
    // multiplier = 1、rangebits = 0 → x 列表 = [0, 1] 加 1 个 x（值 0）→ 重复 → 非法。
    // 这里给一个合法的最小 floor 1：partitions = 0（不读任何 x）。
    w.write(0, 5) // partitions = 0
    w.write(0, 2) // multiplier - 1 = 0 → 1
    w.write(0, 4) // rangebits = 0 → x_list = [0, 1]
  }
  // residues
  w.write(0, 6) // residue_count - 1 = 0
  w.write(residue_type, 16)
  w.write(0, 24) // begin
  w.write(0, 24) // end
  w.write(0, 24) // partition_size - 1
  w.write(0, 6) // classifications - 1
  w.write(0, 8) // classbook = 0
  w.write(0, 3) // cascade low bits = 0
  w.write(0, 1) // 无 high bits
  // mappings
  w.write(0, 6) // mapping_count - 1 = 0
  w.write(0, 16) // mapping type 0
  w.write(0, 1) // submaps flag = 0 → 1 个 submap
  w.write(0, 1) // coupling flag = 0
  w.write(0, 2) // reserved
  w.write(0, 8) // time placeholder
  w.write(0, 8) // submap floor 0
  w.write(0, 8) // submap residue 0
  // modes
  w.write(0, 6) // mode_count - 1 = 0
  w.write(0, 1) // blockflag = 0
  w.write(0, 16) // windowtype
  w.write(0, 16) // transformtype
  w.write(mode_mapping, 8)
  w.write(framing, 1)
  w.to_bytes()
}

///|
/// 与 setup 匹配的 info（1 声道 44100 Hz）。
fn vt_info() -> VorbisInfo {
  {
    channels: 1,
    sample_rate: 44100,
    bitrate_max: 0,
    bitrate_nominal: 0,
    bitrate_min: 0,
    comments: [],
  }
}

test "decode_vorbis: setup 合法 → Unsupported（不会返回音频）" {
  // 关键断言：本函数**永远不返回音频**，合法 setup 也抛 Unsupported；
  // 消息里带上解析摘要，说明 setup 已经完整校验通过。
  let msg = vt_unsupported_message(() => {
    ignore(decode_vorbis(vt_info(), vt_setup(0, 0, 0, 1), []))
  })
  assert_true(msg.contains("尚未实现"))
  assert_true(msg.contains("1 codebook"))
  // 有音频 packet 时同样不返回数据
  let msg2 = vt_unsupported_message(() => {
    ignore(decode_vorbis(vt_info(), vt_setup(0, 0, 0, 1), [b"\x00\x00"]))
  })
  assert_true(msg2.contains("尚未实现"))
}

test "decode_vorbis: floor 1 / residue 1 / residue 2 的合法 setup 也能通过校验" {
  let msg_floor1 = vt_unsupported_message(() => {
    ignore(decode_vorbis(vt_info(), vt_setup(1, 1, 0, 1), []))
  })
  assert_true(msg_floor1.contains("尚未实现"))
  let msg_res2 = vt_unsupported_message(() => {
    ignore(decode_vorbis(vt_info(), vt_setup(0, 2, 0, 1), []))
  })
  assert_true(msg_res2.contains("尚未实现"))
}

test "decode_vorbis: floor 类型 2 → Unsupported" {
  assert_true(vt_unsupported(() => { ignore(decode_vorbis(vt_info(), vt_setup(2, 0, 0, 1), [])) }))
}

test "decode_vorbis: residue 类型 3 → Unsupported" {
  assert_true(vt_unsupported(() => { ignore(decode_vorbis(vt_info(), vt_setup(0, 3, 0, 1), [])) }))
}

test "decode_vorbis: mode 引用不存在的 mapping → InvalidMagic" {
  assert_true(vt_invalid_magic(() => { ignore(decode_vorbis(vt_info(), vt_setup(0, 0, 1, 1), [])) }))
}

test "decode_vorbis: setup framing bit 未置位 → InvalidMagic" {
  assert_true(vt_invalid_magic(() => { ignore(decode_vorbis(vt_info(), vt_setup(0, 0, 0, 0), [])) }))
}

test "decode_vorbis: setup 截断 → Truncated" {
  let setup = vt_setup(0, 0, 0, 1)
  assert_true(vt_truncated(() => {
    ignore(decode_vorbis(vt_info(), vt_take(setup, setup.length() - 1), []))
  }))
  assert_true(vt_truncated(() => { ignore(decode_vorbis(vt_info(), vt_take(setup, 8), [])) }))
}

test "decode_vorbis: codebook 层错误会传到 decode_vorbis（同步字）" {
  // 单个 codebook，同步字错 → InvalidMagic。
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x000000, 24) // 错误的同步字
  let data = w.to_bytes()
  assert_true(vt_invalid_magic(() => { ignore(decode_vorbis(vt_info(), data, [])) }))
}

test "decode_vorbis: floor0 引用越界 codebook → InvalidMagic" {
  // 与 vt_setup 相同，但 floor0 的 book_list[0] 写 1（只有 1 个 codebook，合法编号只有 0）。
  let w = vt_writer()
  w.write_all(vt_prefix(5))
  w.write(0, 8)
  w.write(0x564342, 24)
  w.write(1, 16)
  w.write(2, 24)
  w.write(0, 1)
  w.write(0, 1)
  w.write(0, 5)
  w.write(0, 5)
  w.write(0, 4)
  w.write(0, 6)
  w.write(0, 16)
  w.write(0, 6)
  w.write(0, 16) // floor type 0
  w.write(1, 8)
  w.write(0, 16)
  w.write(0, 16)
  w.write(0, 6)
  w.write(0, 8)
  w.write(0, 4) // number_of_books = 1
  w.write(1, 8) // book_list[0] = 1 → 越界
  let data = w.to_bytes()
  assert_true(vt_invalid_magic(() => { ignore(decode_vorbis(vt_info(), data, [])) }))
}

// ---------------------------------------------------------------------------
// 6. 真实编码器产物的回归测试
// ---------------------------------------------------------------------------
//
// 数据来源：libsndfile 0.14.0（内含 Xiph.Org libVorbis I 20200704）把
// 22050 Hz 单声道 0.15 秒 440 Hz 正弦编码成 Ogg/Vorbis，再用最小 Ogg 解包脚本
// 原样抽出三个 header packet（下列字节字面量未做任何改动）。
//
// 期望值来源：同一份规范**另写一遍的独立 Python 实现**。关键值都能人工从字节里读出：
//   ident：channels=1（字节 11）、sample_rate=22050=0x5622（字节 12..15 小端）、
//          bitrate_nominal=45111=0xB037（字节 20..23 小端）、
//          blocksize 字节 0xA9 → bs0 指数 9（512）、bs1 指数 10（1024）
//   comment：vendor 字符串在字节里是明文，1 条 comment "ENCODER=libsndfile"
//   setup：codebook 数量 = 第 8 个字节 0x22 + 1 = 35；
//          下面按 codebook 逐个核对 dimensions/entries/ordered/lookup_type 与长度表统计
//
// 这一组用例覆盖了合成用例覆盖不到的东西：真实 libvorbis 产出的 35 个 codebook
// （含 sparse 表与 lookup type 1 的 VQ 表）、真实的 floor/residue/mapping/mode 组合。

fn vt_real_ident() -> Bytes {
  Bytes::from_array([
    b'\x01', b'\x76', b'\x6F', b'\x72', b'\x62', b'\x69', b'\x73', b'\x00', b'\x00', b'\x00', b'\x00', b'\x01',
    b'\x22', b'\x56', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x37', b'\xB0', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\xA9', b'\x01',
  ])
}

fn vt_real_comment() -> Bytes {
  Bytes::from_array([
    b'\x03', b'\x76', b'\x6F', b'\x72', b'\x62', b'\x69', b'\x73', b'\x34', b'\x00', b'\x00', b'\x00', b'\x58',
    b'\x69', b'\x70', b'\x68', b'\x2E', b'\x4F', b'\x72', b'\x67', b'\x20', b'\x6C', b'\x69', b'\x62', b'\x56',
    b'\x6F', b'\x72', b'\x62', b'\x69', b'\x73', b'\x20', b'\x49', b'\x20', b'\x32', b'\x30', b'\x32', b'\x30',
    b'\x30', b'\x37', b'\x30', b'\x34', b'\x20', b'\x28', b'\x52', b'\x65', b'\x64', b'\x75', b'\x63', b'\x69',
    b'\x6E', b'\x67', b'\x20', b'\x45', b'\x6E', b'\x76', b'\x69', b'\x72', b'\x6F', b'\x6E', b'\x6D', b'\x65',
    b'\x6E', b'\x74', b'\x29', b'\x01', b'\x00', b'\x00', b'\x00', b'\x12', b'\x00', b'\x00', b'\x00', b'\x45',
    b'\x4E', b'\x43', b'\x4F', b'\x44', b'\x45', b'\x52', b'\x3D', b'\x6C', b'\x69', b'\x62', b'\x73', b'\x6E',
    b'\x64', b'\x66', b'\x69', b'\x6C', b'\x65', b'\x01',
  ])
}

fn vt_real_setup() -> Bytes {
  Bytes::from_array([
    b'\x05', b'\x76', b'\x6F', b'\x72', b'\x62', b'\x69', b'\x73', b'\x22', b'\x42', b'\x43', b'\x56', b'\x01',
    b'\x00', b'\x40', b'\x00', b'\x00', b'\x18', b'\x42', b'\x10', b'\x2A', b'\x05', b'\xAD', b'\x63', b'\x8E',
    b'\x3A', b'\xC8', b'\x15', b'\x21', b'\x8C', b'\x19', b'\xA2', b'\xA0', b'\x42', b'\xCA', b'\x29', b'\xC7',
    b'\x1D', b'\x42', b'\xD0', b'\x21', b'\xA3', b'\x24', b'\x43', b'\x88', b'\x3A', b'\xC6', b'\x35', b'\xC7',
    b'\x18', b'\x63', b'\x47', b'\xB9', b'\x64', b'\x8A', b'\x42', b'\xC9', b'\x81', b'\xD0', b'\x90', b'\x55',
    b'\x00', b'\x00', b'\x40', b'\x00', b'\x00', b'\xA4', b'\x1C', b'\x57', b'\x50', b'\x72', b'\x49', b'\x2D',
    b'\xE7', b'\x9C', b'\x73', b'\xA3', b'\x18', b'\x57', b'\xCC', b'\x71', b'\xE8', b'\x20', b'\xE7', b'\x9C',
    b'\x73', b'\xE5', b'\x20', b'\x67', b'\xCC', b'\x71', b'\x09', b'\x25', b'\xE7', b'\x9C', b'\x73', b'\x8E',
    b'\x39', b'\xE7', b'\x92', b'\x72', b'\x8E', b'\x31', b'\xE7', b'\x9C', b'\x73', b'\xA3', b'\x18', b'\x57',
    b'\x0E', b'\x72', b'\x29', b'\x2D', b'\xE7', b'\x9C', b'\x73', b'\x81', b'\x14', b'\x47', b'\x8A', b'\x71',
    b'\xA7', b'\x18', b'\xE7', b'\x9C', b'\x73', b'\xA4', b'\x1C', b'\x47', b'\x8A', b'\x71', b'\xA8', b'\x18',
    b'\xE7', b'\x9C', b'\x73', b'\x6D', b'\x31', b'\xB7', b'\x92', b'\x72', b'\xCE', b'\x39', b'\xE7', b'\x9C',
    b'\x73', b'\xE6', b'\x20', b'\x87', b'\x52', b'\x72', b'\xAE', b'\x35', b'\xE7', b'\x9C', b'\x73', b'\xA4',
    b'\x18', b'\x67', b'\x0E', b'\x72', b'\x0B', b'\x25', b'\xE7', b'\x9C', b'\x73', b'\xC6', b'\x20', b'\x67',
    b'\xCC', b'\x71', b'\xEB', b'\x20', b'\xE7', b'\x9C', b'\x73', b'\x8C', b'\x35', b'\xB7', b'\xD4', b'\x72',
    b'\xCE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\xCE', b'\x39',
    b'\xE7', b'\x9C', b'\x73', b'\x8C', b'\x31', b'\xE7', b'\x9C', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C',
    b'\x73', b'\x6E', b'\x31', b'\xE7', b'\x16', b'\x73', b'\xAE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\xCE',
    b'\x39', b'\xE7', b'\x1C', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\x20', b'\x34', b'\x64',
    b'\x15', b'\x00', b'\x90', b'\x00', b'\x00', b'\xA0', b'\xA1', b'\x28', b'\x8A', b'\xE2', b'\x28', b'\x0E',
    b'\x10', b'\x1A', b'\xB2', b'\x0A', b'\x00', b'\xC8', b'\x00', b'\x00', b'\x10', b'\x40', b'\x71', b'\x14',
    b'\x47', b'\x91', b'\x14', b'\x4B', b'\xB1', b'\x1C', b'\xCB', b'\xD1', b'\x24', b'\x0D', b'\x08', b'\x0D',
    b'\x59', b'\x05', b'\x00', b'\x00', b'\x01', b'\x00', b'\x08', b'\x00', b'\x00', b'\xA0', b'\x48', b'\x86',
    b'\xA4', b'\x48', b'\x8A', b'\xA5', b'\x58', b'\x8E', b'\x66', b'\x69', b'\x9E', b'\x26', b'\x7A', b'\xA2',
    b'\x28', b'\x9A', b'\xA2', b'\x2A', b'\xAB', b'\xB2', b'\x69', b'\xCA', b'\xB2', b'\x2C', b'\xCB', b'\xB2',
    b'\xEB', b'\xBA', b'\x2E', b'\x10', b'\x1A', b'\xB2', b'\x0A', b'\x00', b'\x48', b'\x00', b'\x00', b'\x50',
    b'\x51', b'\x14', b'\xC5', b'\x70', b'\x14', b'\x07', b'\x08', b'\x0D', b'\x59', b'\x05', b'\x00', b'\x64',
    b'\x00', b'\x00', b'\x08', b'\x60', b'\x28', b'\x8A', b'\xA3', b'\x38', b'\x8E', b'\xE4', b'\x58', b'\x92',
    b'\xA5', b'\x59', b'\x9E', b'\x07', b'\x84', b'\x86', b'\xAC', b'\x02', b'\x00', b'\x80', b'\x00', b'\x00',
    b'\x04', b'\x00', b'\x00', b'\x50', b'\x0C', b'\x47', b'\xB1', b'\x14', b'\x4D', b'\xF1', b'\x24', b'\xCF',
    b'\xF2', b'\x3C', b'\xCF', b'\xF3', b'\x3C', b'\xCF', b'\xF3', b'\x3C', b'\xCF', b'\xF3', b'\x3C', b'\xCF',
    b'\xF3', b'\x3C', b'\xCF', b'\xF3', b'\x3C', b'\xCF', b'\xF3', b'\x3C', b'\x0D', b'\x08', b'\x0D', b'\x59',
    b'\x05', b'\x00', b'\x20', b'\x00', b'\x00', b'\x00', b'\x82', b'\x28', b'\x64', b'\x18', b'\x03', b'\x42',
    b'\x43', b'\x56', b'\x01', b'\x00', b'\x40', b'\x00', b'\x00', b'\x08', b'\x21', b'\x1A', b'\x19', b'\x43',
    b'\x9D', b'\x52', b'\x12', b'\x5C', b'\x0A', b'\x16', b'\x42', b'\x1C', b'\x11', b'\x43', b'\x1D', b'\x42',
    b'\xCE', b'\x43', b'\xA9', b'\xA5', b'\x83', b'\xE0', b'\x29', b'\x85', b'\x25', b'\x63', b'\xD2', b'\x53',
    b'\xAC', b'\x41', b'\x08', b'\x21', b'\x7C', b'\xEF', b'\x3D', b'\xF7', b'\xDE', b'\x7B', b'\xEF', b'\x81',
    b'\xD0', b'\x90', b'\x55', b'\x00', b'\x00', b'\x10', b'\x00', b'\x00', b'\x61', b'\x14', b'\x38', b'\x88',
    b'\x81', b'\xC7', b'\x24', b'\x08', b'\x21', b'\x84', b'\x62', b'\x14', b'\x27', b'\x44', b'\x71', b'\xA6',
    b'\x20', b'\x08', b'\x21', b'\x84', b'\xE5', b'\x24', b'\x58', b'\xCA', b'\x79', b'\xE8', b'\x24', b'\x08',
    b'\xDD', b'\x83', b'\x10', b'\x42', b'\xB8', b'\x9C', b'\x7B', b'\xCB', b'\xB9', b'\xF7', b'\xDE', b'\x7B',
    b'\x20', b'\x34', b'\x64', b'\x15', b'\x00', b'\x00', b'\x08', b'\x00', b'\xC0', b'\x20', b'\x84', b'\x10',
    b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x29', b'\xA4', b'\x94', b'\x52', b'\x48',
    b'\x29', b'\xA6', b'\x98', b'\x62', b'\x8A', b'\x29', b'\xC7', b'\x1C', b'\x73', b'\xCC', b'\x31', b'\xC7',
    b'\x20', b'\x83', b'\x0C', b'\x32', b'\xE8', b'\xA0', b'\x93', b'\x4E', b'\x3A', b'\xC9', b'\xA4', b'\x92',
    b'\x4E', b'\x3A', b'\xCA', b'\x24', b'\xA3', b'\x8E', b'\x52', b'\x6B', b'\x29', b'\xB5', b'\x14', b'\x53',
    b'\x4C', b'\xB1', b'\xE5', b'\x16', b'\x63', b'\xAD', b'\xB5', b'\xD6', b'\x9C', b'\x73', b'\xAF', b'\x41',
    b'\x29', b'\x63', b'\x8C', b'\x31', b'\xC6', b'\x18', b'\x63', b'\x8C', b'\x31', b'\xC6', b'\x18', b'\x63',
    b'\x8C', b'\x31', b'\xC6', b'\x18', b'\x23', b'\x08', b'\x0D', b'\x59', b'\x05', b'\x00', b'\x80', b'\x00',
    b'\x00', b'\x10', b'\x06', b'\x19', b'\x64', b'\x90', b'\x41', b'\x08', b'\x21', b'\x84', b'\x14', b'\x52',
    b'\x48', b'\x29', b'\xA6', b'\x98', b'\x72', b'\xCC', b'\x31', b'\xC7', b'\x1C', b'\x03', b'\x42', b'\x43',
    b'\x56', b'\x01', b'\x00', b'\x80', b'\x00', b'\x00', b'\x02', b'\x00', b'\x00', b'\x00', b'\x1C', b'\x45',
    b'\x52', b'\x24', b'\x47', b'\x72', b'\x24', b'\x47', b'\x92', b'\x24', b'\xC9', b'\x92', b'\x2C', b'\x49',
    b'\x93', b'\x3C', b'\xCB', b'\xB3', b'\x3C', b'\xCB', b'\xB3', b'\x3C', b'\x4D', b'\xD4', b'\x44', b'\x4D',
    b'\x15', b'\x55', b'\xD5', b'\x55', b'\x6D', b'\xD7', b'\xF6', b'\x6D', b'\x5F', b'\xF6', b'\x6D', b'\xDF',
    b'\xD5', b'\x65', b'\xDF', b'\xF6', b'\x65', b'\xDB', b'\xD5', b'\x65', b'\x5D', b'\x96', b'\x65', b'\xDD',
    b'\xB5', b'\x6D', b'\x5D', b'\xD6', b'\x5D', b'\x5D', b'\xD7', b'\x75', b'\x5D', b'\xD7', b'\x75', b'\x5D',
    b'\xD7', b'\x75', b'\x5D', b'\xD7', b'\x75', b'\x5D', b'\xD7', b'\x75', b'\x5D', b'\xD7', b'\x81', b'\xD0',
    b'\x90', b'\x55', b'\x00', b'\x80', b'\x04', b'\x00', b'\x80', b'\x8E', b'\xE4', b'\x38', b'\x8E', b'\xE4',
    b'\x38', b'\x8E', b'\xE4', b'\x48', b'\x8E', b'\xA4', b'\x48', b'\x0A', b'\x10', b'\x1A', b'\xB2', b'\x0A',
    b'\x00', b'\x90', b'\x01', b'\x00', b'\x10', b'\x00', b'\x80', b'\xA3', b'\x38', b'\x8A', b'\xE3', b'\x48',
    b'\x8E', b'\xE4', b'\x58', b'\x8E', b'\x25', b'\x59', b'\x92', b'\x26', b'\x69', b'\x96', b'\x67', b'\x79',
    b'\x96', b'\xA7', b'\x79', b'\x9A', b'\xA8', b'\x89', b'\x1E', b'\x10', b'\x1A', b'\xB2', b'\x0A', b'\x00',
    b'\x00', b'\x04', b'\x00', b'\x10', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x80', b'\xA2', b'\x28',
    b'\x8A', b'\xA3', b'\x38', b'\x8E', b'\x24', b'\x59', b'\x96', b'\xA6', b'\x69', b'\x9E', b'\xA7', b'\x7A',
    b'\xA2', b'\x28', b'\x9A', b'\xAA', b'\xAA', b'\x8A', b'\xA6', b'\xA9', b'\xAA', b'\xAA', b'\x6A', b'\x9A',
    b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A',
    b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A',
    b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x9A', b'\xA6', b'\x69', b'\x02', b'\xA1', b'\x21', b'\xAB',
    b'\x00', b'\x00', b'\x09', b'\x00', b'\x00', b'\x1D', b'\xC7', b'\x71', b'\x1C', b'\x47', b'\x71', b'\x1C',
    b'\xC7', b'\x71', b'\x24', b'\x47', b'\x92', b'\x24', b'\x20', b'\x34', b'\x64', b'\x15', b'\x00', b'\x20',
    b'\x03', b'\x00', b'\x20', b'\x00', b'\x00', b'\x43', b'\x51', b'\x1C', b'\x45', b'\x72', b'\x2C', b'\xC7',
    b'\x92', b'\x34', b'\x4B', b'\xB3', b'\x3C', b'\xCB', b'\xD3', b'\x44', b'\xCF', b'\xF4', b'\x5C', b'\x51',
    b'\x36', b'\x75', b'\x53', b'\x57', b'\x6D', b'\x20', b'\x34', b'\x64', b'\x15', b'\x00', b'\x00', b'\x08',
    b'\x00', b'\x20', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\xC7', b'\x73', b'\x3C', b'\xC7',
    b'\x73', b'\x3C', b'\xC9', b'\x93', b'\x3C', b'\xCB', b'\x73', b'\x3C', b'\xC7', b'\x93', b'\x3C', b'\x49',
    b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D',
    b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D',
    b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D',
    b'\xD3', b'\x34', b'\x4D', b'\xD3', b'\x34', b'\x4D', b'\x03', b'\x42', b'\x43', b'\x56', b'\x02', b'\x00',
    b'\x64', b'\x00', b'\x00', b'\x10', b'\x93', b'\x90', b'\x4A', b'\x4E', b'\xB1', b'\x57', b'\x46', b'\x29',
    b'\xC6', b'\x24', b'\xB4', b'\x5E', b'\x2A', b'\xA4', b'\x14', b'\x93', b'\xD4', b'\x7B', b'\xA8', b'\x98',
    b'\x62', b'\x4C', b'\x3A', b'\xED', b'\xA9', b'\x42', b'\x06', b'\x29', b'\x07', b'\xB9', b'\x87', b'\x4A',
    b'\x21', b'\xA5', b'\xA0', b'\xD3', b'\xDE', b'\x32', b'\xA5', b'\x90', b'\x52', b'\x0C', b'\x7B', b'\xA7',
    b'\x98', b'\x42', b'\xC8', b'\x18', b'\xEA', b'\xA1', b'\x83', b'\x90', b'\x31', b'\x85', b'\xB0', b'\xD7',
    b'\xDA', b'\x73', b'\xCF', b'\xBD', b'\xF7', b'\x1E', b'\x08', b'\x0D', b'\x59', b'\x11', b'\x00', b'\x44',
    b'\x01', b'\x00', b'\x00', b'\xC6', b'\x20', b'\xC6', b'\x10', b'\x63', b'\xC8', b'\x31', b'\x26', b'\x25',
    b'\x83', b'\x12', b'\x31', b'\xC7', b'\x24', b'\x64', b'\x52', b'\x22', b'\xE7', b'\x9C', b'\x94', b'\x4E',
    b'\x4A', b'\x26', b'\xA5', b'\xA4', b'\x56', b'\x5A', b'\xCC', b'\xA4', b'\x84', b'\x98', b'\x4A', b'\x8B',
    b'\x91', b'\x73', b'\x4E', b'\x4A', b'\x27', b'\x25', b'\x93', b'\x52', b'\x5A', b'\x0B', b'\xA9', b'\x65',
    b'\x92', b'\x4A', b'\x6B', b'\x25', b'\xA6', b'\x02', b'\x00', b'\x00', b'\x02', b'\x1C', b'\x00', b'\x00',
    b'\x02', b'\x2C', b'\x84', b'\x42', b'\x43', b'\x56', b'\x04', b'\x00', b'\x51', b'\x00', b'\x00', b'\x88',
    b'\x31', b'\x48', b'\x29', b'\xA4', b'\x14', b'\x52', b'\x4A', b'\x31', b'\xA7', b'\x98', b'\x43', b'\x4A',
    b'\x29', b'\xC7', b'\x94', b'\x63', b'\x48', b'\x29', b'\xE5', b'\x9C', b'\x72', b'\x4E', b'\x39', b'\xC7',
    b'\x98', b'\x74', b'\x10', b'\x2A', b'\xE7', b'\x18', b'\x74', b'\x0E', b'\x4A', b'\xA4', b'\x94', b'\x72',
    b'\x8E', b'\x39', b'\xA7', b'\x9C', b'\x73', b'\x12', b'\x32', b'\x07', b'\x95', b'\x73', b'\x0E', b'\x42',
    b'\x26', b'\x9D', b'\x00', b'\x00', b'\x80', b'\x00', b'\x07', b'\x00', b'\x80', b'\x00', b'\x0B', b'\xA1',
    b'\xD0', b'\x90', b'\x15', b'\x01', b'\x40', b'\x9C', b'\x00', b'\x00', b'\x80', b'\x90', b'\x73', b'\x8A',
    b'\x31', b'\x08', b'\x11', b'\x63', b'\x10', b'\x42', b'\x09', b'\x29', b'\x85', b'\x50', b'\x52', b'\xAA',
    b'\x9C', b'\x93', b'\xD2', b'\x41', b'\x49', b'\xA9', b'\x83', b'\x92', b'\x52', b'\x49', b'\xA9', b'\xC5',
    b'\x92', b'\x52', b'\x8C', b'\x95', b'\x73', b'\x52', b'\x3A', b'\x09', b'\x29', b'\x75', b'\x12', b'\x52',
    b'\x2A', b'\x29', b'\xC5', b'\x58', b'\x52', b'\x8A', b'\x2D', b'\xA4', b'\x54', b'\x63', b'\x69', b'\x2D',
    b'\xD7', b'\xD2', b'\x52', b'\x8D', b'\x2D', b'\xC6', b'\x9C', b'\x5B', b'\x8C', b'\xBD', b'\x86', b'\x94',
    b'\x62', b'\x2D', b'\xA9', b'\xD5', b'\x5A', b'\x5A', b'\xAB', b'\xB9', b'\xC5', b'\x58', b'\x73', b'\x8B',
    b'\x35', b'\xF7', b'\xC8', b'\x39', b'\x4A', b'\x9D', b'\x94', b'\xD6', b'\x3A', b'\x29', b'\xAD', b'\xA5',
    b'\xD6', b'\x6A', b'\x4D', b'\xAD', b'\xD5', b'\xDA', b'\x49', b'\x69', b'\x2D', b'\xA4', b'\xD6', b'\x62',
    b'\x69', b'\x2D', b'\xC6', b'\xD6', b'\x62', b'\xCD', b'\x29', b'\xC6', b'\x9C', b'\x33', b'\x29', b'\xAD',
    b'\x85', b'\x96', b'\x62', b'\x2B', b'\xA9', b'\xC5', b'\xD8', b'\x62', b'\xCB', b'\x35', b'\xB5', b'\x98',
    b'\x73', b'\x69', b'\x2D', b'\xD7', b'\x14', b'\x63', b'\xCF', b'\x29', b'\xC6', b'\x9E', b'\x6B', b'\xAC',
    b'\xB9', b'\xC7', b'\x9C', b'\x83', b'\x30', b'\xAD', b'\xD5', b'\x9C', b'\x5A', b'\xCB', b'\x39', b'\xC5',
    b'\x98', b'\x7B', b'\xCC', b'\xB1', b'\xE7', b'\x98', b'\x73', b'\x0F', b'\x92', b'\x73', b'\x94', b'\x3A',
    b'\x29', b'\xAD', b'\x75', b'\x52', b'\x5A', b'\x4B', b'\xAD', b'\xD5', b'\x9A', b'\x5A', b'\xAB', b'\x35',
    b'\x93', b'\xD2', b'\x5A', b'\x69', b'\xAD', b'\xC6', b'\x90', b'\x5A', b'\x8B', b'\x2D', b'\xC6', b'\x9C',
    b'\x5B', b'\x8B', b'\x31', b'\x67', b'\x52', b'\x5A', b'\x2C', b'\xA9', b'\xC5', b'\x58', b'\x5A', b'\x8A',
    b'\x31', b'\xC5', b'\x98', b'\x73', b'\x8B', b'\x2D', b'\xD7', b'\xD0', b'\x5A', b'\xAE', b'\x29', b'\xC6',
    b'\x9C', b'\x53', b'\x8B', b'\x39', b'\xC7', b'\x5A', b'\x83', b'\x92', b'\xB1', b'\xF6', b'\x5E', b'\x5A',
    b'\xAB', b'\x39', b'\xC5', b'\x98', b'\x7B', b'\x8A', b'\xAD', b'\xE7', b'\x98', b'\x73', b'\x30', b'\x36',
    b'\xC7', b'\x9E', b'\x3B', b'\x4A', b'\xB9', b'\x96', b'\xD6', b'\x7A', b'\x2E', b'\xAD', b'\xF5', b'\x5E',
    b'\x73', b'\x2E', b'\x42', b'\xD6', b'\xDC', b'\x8B', b'\x68', b'\x2D', b'\xE7', b'\xD4', b'\x6A', b'\x0F',
    b'\x2A', b'\xC6', b'\x9E', b'\x73', b'\xCE', b'\xC1', b'\xD8', b'\xDC', b'\x83', b'\x10', b'\xAD', b'\xE5',
    b'\x9C', b'\x6A', b'\xEC', b'\x3D', b'\xC5', b'\xD8', b'\x7B', b'\xEE', b'\x39', b'\x18', b'\xDB', b'\x73',
    b'\xF0', b'\xAD', b'\xD6', b'\xE0', b'\x5B', b'\xCD', b'\x45', b'\xC8', b'\x9C', b'\x83', b'\xD0', b'\xB9',
    b'\xF8', b'\xA6', b'\x7B', b'\x30', b'\x46', b'\xD5', b'\xDA', b'\x83', b'\xCC', b'\xB5', b'\x08', b'\x99',
    b'\x73', b'\x10', b'\x3A', b'\xE8', b'\x22', b'\x74', b'\xF0', b'\xC9', b'\x78', b'\x94', b'\x6A', b'\x2E',
    b'\xAD', b'\xE5', b'\x5C', b'\x5A', b'\xEB', b'\x3D', b'\xD6', b'\x1A', b'\x7C', b'\xCD', b'\x39', b'\x08',
    b'\xD1', b'\x5A', b'\xEE', b'\x29', b'\xC6', b'\xDE', b'\x53', b'\x8B', b'\xBD', b'\xD7', b'\x9E', b'\x9B',
    b'\xB0', b'\xBD', b'\x07', b'\x21', b'\x5A', b'\xCB', b'\x3D', b'\xC5', b'\xD8', b'\x83', b'\x8A', b'\x31',
    b'\xF8', b'\x9A', b'\x73', b'\x30', b'\x3A', b'\xE7', b'\x62', b'\x54', b'\xAD', b'\xC1', b'\xC7', b'\x9C',
    b'\x83', b'\x90', b'\xB5', b'\x16', b'\xA1', b'\x7B', b'\x2F', b'\x4A', b'\xE7', b'\x20', b'\x94', b'\xAA',
    b'\xB5', b'\x07', b'\x99', b'\x6B', b'\x50', b'\x32', b'\xD7', b'\x22', b'\x74', b'\xF0', b'\xC5', b'\xE8',
    b'\xA0', b'\x8B', b'\x2F', b'\x00', b'\x00', b'\x60', b'\xC0', b'\x01', b'\x00', b'\x20', b'\xC0', b'\x84',
    b'\x32', b'\x50', b'\x68', b'\xC8', b'\x8A', b'\x00', b'\x20', b'\x4E', b'\x00', b'\x80', b'\x41', b'\xC8',
    b'\x39', b'\xA5', b'\x18', b'\x84', b'\x4A', b'\x29', b'\x08', b'\xA1', b'\x84', b'\x94', b'\x42', b'\x28',
    b'\x29', b'\x55', b'\x8C', b'\x49', b'\xC8', b'\x98', b'\x83', b'\x92', b'\x31', b'\x27', b'\xA5', b'\x94',
    b'\x52', b'\x5A', b'\x08', b'\x25', b'\xB5', b'\x8A', b'\x31', b'\x08', b'\x99', b'\x63', b'\x52', b'\x32',
    b'\xC7', b'\xA4', b'\x84', b'\x12', b'\x5A', b'\x2A', b'\x25', b'\xB4', b'\x12', b'\x4A', b'\x69', b'\xA9',
    b'\x94', b'\xD2', b'\x5A', b'\x28', b'\xA5', b'\xB5', b'\x96', b'\x5A', b'\x8C', b'\x29', b'\xB5', b'\x16',
    b'\x43', b'\x29', b'\xA9', b'\x85', b'\x52', b'\x5A', b'\x2B', b'\xA5', b'\xB4', b'\x96', b'\x5A', b'\xAA',
    b'\x31', b'\xB5', b'\x56', b'\x63', b'\xC4', b'\x98', b'\x94', b'\xCC', b'\x39', b'\x29', b'\x99', b'\x63',
    b'\x52', b'\x4A', b'\x29', b'\xAD', b'\x95', b'\x52', b'\x5A', b'\xAB', b'\x1C', b'\x93', b'\x92', b'\x31',
    b'\x28', b'\xA9', b'\x83', b'\x90', b'\x4A', b'\x29', b'\x29', b'\xC5', b'\x52', b'\x52', b'\x8B', b'\x95',
    b'\x73', b'\x52', b'\x32', b'\xE8', b'\xA8', b'\x74', b'\x10', b'\x4A', b'\x2A', b'\xA9', b'\xC4', b'\x54',
    b'\x52', b'\x69', b'\xAD', b'\xA4', b'\xD2', b'\x52', b'\x29', b'\xA5', b'\xC5', b'\x92', b'\x52', b'\x6C',
    b'\x29', b'\xC5', b'\x54', b'\x5B', b'\x8B', b'\xB5', b'\x86', b'\x52', b'\x5A', b'\x2C', b'\xA9', b'\xC4',
    b'\x56', b'\x52', b'\x6A', b'\x31', b'\xB5', b'\x54', b'\x5B', b'\x8B', b'\x31', b'\xD7', b'\x88', b'\x31',
    b'\x29', b'\x19', b'\x73', b'\x52', b'\x32', b'\xE7', b'\xA4', b'\x94', b'\x52', b'\x52', b'\x2B', b'\xA5',
    b'\xB4', b'\x96', b'\x39', b'\x27', b'\xA5', b'\x83', b'\x8E', b'\x4A', b'\xE6', b'\xA0', b'\xA4', b'\x92',
    b'\x52', b'\x6B', b'\xA5', b'\xA4', b'\x14', b'\x33', b'\xE6', b'\xA4', b'\x74', b'\x0E', b'\x4A', b'\xCA',
    b'\x20', b'\xA3', b'\x52', b'\x52', b'\x8A', b'\x2D', b'\xA5', b'\x12', b'\x53', b'\x28', b'\xA5', b'\xB5',
    b'\x92', b'\x52', b'\x6C', b'\xA5', b'\xA4', b'\xD6', b'\x5A', b'\x8C', b'\xB5', b'\xA6', b'\xD4', b'\x5A',
    b'\x2D', b'\x25', b'\xB5', b'\x56', b'\x52', b'\x6A', b'\xB1', b'\x94', b'\x12', b'\x5B', b'\x8B', b'\x31',
    b'\xD7', b'\x16', b'\x4B', b'\x4D', b'\x9D', b'\x94', b'\xD6', b'\x4A', b'\x2A', b'\x31', b'\x86', b'\x52',
    b'\x5A', b'\x6B', b'\x31', b'\xE6', b'\x9A', b'\x5A', b'\x8B', b'\x31', b'\x94', b'\x12', b'\x5B', b'\x29',
    b'\x29', b'\xC6', b'\x92', b'\x4A', b'\x6C', b'\xAD', b'\xC5', b'\x9A', b'\x5B', b'\x6C', b'\x39', b'\x86',
    b'\x52', b'\x5A', b'\x2C', b'\xA9', b'\xC4', b'\x56', b'\x4A', b'\x6A', b'\xB1', b'\xD5', b'\x96', b'\x63',
    b'\x6B', b'\xB1', b'\xE6', b'\xD4', b'\x52', b'\x8D', b'\x29', b'\xB5', b'\x9A', b'\x5B', b'\x6C', b'\xB9',
    b'\xC6', b'\x94', b'\x53', b'\x8F', b'\xB5', b'\xF6', b'\x9C', b'\x5A', b'\xAB', b'\x35', b'\xB5', b'\x54',
    b'\x63', b'\x6B', b'\xB1', b'\xE6', b'\x58', b'\x5B', b'\x6F', b'\xB5', b'\xD6', b'\x9C', b'\x3B', b'\x29',
    b'\xAD', b'\x85', b'\x52', b'\x5A', b'\x2B', b'\x25', b'\xC5', b'\x98', b'\x5A', b'\x8B', b'\xB1', b'\xC5',
    b'\x58', b'\x73', b'\x28', b'\x25', b'\xB6', b'\x92', b'\x52', b'\x6C', b'\xA5', b'\xA4', b'\x18', b'\x5B',
    b'\x6C', b'\xB9', b'\xB6', b'\x16', b'\x63', b'\x0F', b'\xA1', b'\xB4', b'\x58', b'\x4A', b'\x6A', b'\xB1',
    b'\xA4', b'\x12', b'\x63', b'\x6B', b'\x31', b'\xE6', b'\x18', b'\x5B', b'\x8E', b'\xA9', b'\xB5', b'\x5A',
    b'\x5B', b'\x6C', b'\xB9', b'\xA6', b'\xD4', b'\x62', b'\xAD', b'\xB5', b'\xF6', b'\x1C', b'\x5B', b'\x6E',
    b'\x3D', b'\xA5', b'\x16', b'\x6B', b'\x8B', b'\xB1', b'\xE6', b'\xD2', b'\x52', b'\x8D', b'\x35', b'\xD7',
    b'\xDE', b'\x63', b'\x4D', b'\x39', b'\x15', b'\x00', b'\x00', b'\x30', b'\xE0', b'\x00', b'\x00', b'\x10',
    b'\x60', b'\x42', b'\x19', b'\x28', b'\x34', b'\x64', b'\x25', b'\x00', b'\x10', b'\x05', b'\x00', b'\x00',
    b'\x18', b'\xC3', b'\x18', b'\x63', b'\x10', b'\x1A', b'\xA5', b'\x9C', b'\x73', b'\x4E', b'\x4A', b'\x83',
    b'\x94', b'\x73', b'\xCE', b'\x49', b'\xC9', b'\x9C', b'\x83', b'\x10', b'\x42', b'\x4A', b'\x99', b'\x73',
    b'\x10', b'\x42', b'\x48', b'\x29', b'\x73', b'\x4E', b'\x42', b'\x4A', b'\x2D', b'\x65', b'\xCE', b'\x41',
    b'\x48', b'\xA9', b'\xB5', b'\x50', b'\x4A', b'\x4A', b'\xAD', b'\xC5', b'\x16', b'\x4A', b'\x49', b'\xA9',
    b'\xB5', b'\x16', b'\x0B', b'\x00', b'\x00', b'\x28', b'\x70', b'\x00', b'\x00', b'\x08', b'\xB0', b'\x41',
    b'\x53', b'\x62', b'\x71', b'\x80', b'\x42', b'\x43', b'\x56', b'\x02', b'\x00', b'\x51', b'\x00', b'\x00',
    b'\x88', b'\x31', b'\x4A', b'\x31', b'\x06', b'\xA1', b'\x31', b'\x46', b'\x29', b'\xE7', b'\x20', b'\x34',
    b'\xC6', b'\x28', b'\xC5', b'\x18', b'\x84', b'\x4A', b'\x29', b'\xC6', b'\x9C', b'\x93', b'\x50', b'\x29',
    b'\xC5', b'\x98', b'\x73', b'\x50', b'\x32', b'\xC7', b'\x9C', b'\x83', b'\x50', b'\x4A', b'\xE6', b'\x9C',
    b'\x73', b'\x10', b'\x4A', b'\x09', b'\x21', b'\x94', b'\x52', b'\x4A', b'\x4A', b'\x21', b'\x84', b'\x52',
    b'\x4A', b'\x49', b'\xA9', b'\x00', b'\x00', b'\x80', b'\x02', b'\x07', b'\x00', b'\x80', b'\x00', b'\x1B',
    b'\x34', b'\x25', b'\x16', b'\x07', b'\x28', b'\x34', b'\x64', b'\x45', b'\x00', b'\x10', b'\x05', b'\x00',
    b'\x00', b'\x18', b'\x63', b'\x9C', b'\x33', b'\xCE', b'\x21', b'\x0A', b'\x9D', b'\xA5', b'\xCE', b'\x52',
    b'\x24', b'\xA9', b'\xA3', b'\xD6', b'\x51', b'\x6B', b'\x28', b'\xA5', b'\x1A', b'\x4B', b'\x8C', b'\x9D',
    b'\xC6', b'\x56', b'\x7B', b'\xEB', b'\xB9', b'\xD3', b'\x1A', b'\x7B', b'\x6D', b'\xB9', b'\x37', b'\x94',
    b'\x4A', b'\x8D', b'\xA9', b'\xD6', b'\x8E', b'\x6B', b'\xCB', b'\xB9', b'\xD5', b'\xDE', b'\x69', b'\x4D',
    b'\x3D', b'\xB7', b'\x1C', b'\x0B', b'\x00', b'\x00', b'\x3B', b'\x70', b'\x00', b'\x00', b'\x3B', b'\xB0',
    b'\x10', b'\x0A', b'\x0D', b'\x59', b'\x09', b'\x00', b'\xE4', b'\x01', b'\x00', b'\x10', b'\xC6', b'\x28',
    b'\xC5', b'\x98', b'\x73', b'\xCE', b'\x19', b'\x85', b'\x18', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x0C',
    b'\x52', b'\x8C', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\x8A', b'\x31', b'\xE7', b'\x9C', b'\x83', b'\x10',
    b'\x42', b'\xC5', b'\x98', b'\x73', b'\xCE', b'\x41', b'\x08', b'\x21', b'\x73', b'\xCE', b'\x39', b'\x08',
    b'\xA1', b'\x84', b'\x92', b'\x39', b'\xE7', b'\x1C', b'\x84', b'\x10', b'\x4A', b'\xE8', b'\x9C', b'\x83',
    b'\x50', b'\x4A', b'\x29', b'\xA5', b'\x74', b'\xCE', b'\x41', b'\x08', b'\xA1', b'\x94', b'\x52', b'\x3A',
    b'\xE7', b'\x20', b'\x84', b'\x52', b'\x4A', b'\x29', b'\x9D', b'\x73', b'\x10', b'\x4A', b'\x29', b'\xA5',
    b'\x94', b'\x02', b'\x00', b'\x80', b'\x0A', b'\x1C', b'\x00', b'\x00', b'\x02', b'\x6C', b'\x14', b'\xD9',
    b'\x9C', b'\x60', b'\x24', b'\xA8', b'\xD0', b'\x90', b'\x95', b'\x00', b'\x40', b'\x1E', b'\x00', b'\x00',
    b'\x60', b'\x0C', b'\x42', b'\xCE', b'\x49', b'\x69', b'\xAD', b'\x61', b'\xCC', b'\x39', b'\x08', b'\x2D',
    b'\xD5', b'\xD8', b'\x30', b'\xC6', b'\x1C', b'\x94', b'\x94', b'\x62', b'\x8B', b'\x9C', b'\x83', b'\x90',
    b'\x52', b'\x8B', b'\xB9', b'\x46', b'\xCC', b'\x41', b'\x48', b'\x29', b'\xC6', b'\xA0', b'\x3B', b'\x28',
    b'\x29', b'\xB5', b'\x18', b'\x6C', b'\xF0', b'\x9D', b'\x84', b'\x94', b'\x5A', b'\x8B', b'\x39', b'\x07',
    b'\x93', b'\x52', b'\x8B', b'\x35', b'\xE7', b'\xDE', b'\x83', b'\x48', b'\xA9', b'\xB5', b'\x9A', b'\x83',
    b'\xCE', b'\x3D', b'\xD5', b'\x56', b'\x73', b'\xCF', b'\xBD', b'\xF7', b'\x9C', b'\x62', b'\xAC', b'\x35',
    b'\xE7', b'\xDE', b'\x73', b'\x2F', b'\x00', b'\x00', b'\x77', b'\xC1', b'\x01', b'\x00', b'\xEC', b'\xC0',
    b'\x46', b'\x91', b'\xCD', b'\x09', b'\x46', b'\x82', b'\x0A', b'\x0D', b'\x59', b'\x09', b'\x00', b'\xE4',
    b'\x01', b'\x00', b'\x10', b'\x08', b'\x29', b'\xC5', b'\x98', b'\x73', b'\xCE', b'\x19', b'\xA5', b'\x18',
    b'\x73', b'\xCC', b'\x39', b'\xE7', b'\x8C', b'\x52', b'\x8C', b'\x31', b'\xE6', b'\x9C', b'\x73', b'\x8A',
    b'\x31', b'\xC6', b'\x9C', b'\x73', b'\xCE', b'\x41', b'\xC5', b'\x18', b'\x63', b'\xCE', b'\x39', b'\x07',
    b'\x21', b'\x63', b'\xCC', b'\x39', b'\xE7', b'\x20', b'\x84', b'\x90', b'\x31', b'\xE6', b'\x9C', b'\x73',
    b'\x10', b'\x42', b'\xE8', b'\x9C', b'\x73', b'\x0E', b'\x42', b'\x08', b'\x21', b'\x74', b'\xCE', b'\x39',
    b'\x07', b'\x21', b'\x84', b'\x10', b'\x3A', b'\xE7', b'\xA0', b'\x83', b'\x10', b'\x42', b'\x08', b'\x9D',
    b'\x73', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x02', b'\x00', b'\x80', b'\x0A', b'\x1C', b'\x00',
    b'\x00', b'\x02', b'\x6C', b'\x14', b'\xD9', b'\x9C', b'\x60', b'\x24', b'\xA8', b'\xD0', b'\x90', b'\x95',
    b'\x00', b'\x40', b'\x38', b'\x00', b'\x00', b'\x00', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21',
    b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10',
    b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08',
    b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84',
    b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42',
    b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21',
    b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10',
    b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08',
    b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84',
    b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42',
    b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\xE8', b'\x9C', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C',
    b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\xCE', b'\x39', b'\xE7', b'\x9C', b'\x73', b'\xCE',
    b'\x39', b'\x27', b'\x00', b'\xC8', b'\xB7', b'\xC2', b'\x01', b'\xC0', b'\xFF', b'\xC1', b'\xC6', b'\x19',
    b'\x56', b'\x92', b'\xCE', b'\x0A', b'\x47', b'\x83', b'\x0B', b'\x0D', b'\x59', b'\x09', b'\x00', b'\x84',
    b'\x03', b'\x00', b'\x00', b'\x0A', b'\x41', b'\x28', b'\xA5', b'\x62', b'\x10', b'\x4A', b'\x29', b'\x25',
    b'\x92', b'\x4E', b'\x3A', b'\x29', b'\x9D', b'\x93', b'\x50', b'\x4A', b'\x29', b'\x91', b'\x83', b'\x52',
    b'\x4A', b'\xE9', b'\xA4', b'\x94', b'\x52', b'\x4A', b'\x09', b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x08',
    b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x08', b'\x1D', b'\x94', b'\x52', b'\x42', b'\x29', b'\xA5', b'\x94',
    b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x94', b'\x52', b'\x3A',
    b'\x29', b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x94', b'\xCA', b'\x39', b'\x29', b'\xA5',
    b'\x93', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x44', b'\xCE', b'\x49', b'\x29', b'\x21', b'\x94', b'\x52',
    b'\x4A', b'\x29', b'\xA5', b'\x84', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x29',
    b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x94', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x84',
    b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42',
    b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21',
    b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x10', b'\x42', b'\x08', b'\x21', b'\x84', b'\x02',
    b'\x00', b'\xB8', b'\x1B', b'\x1C', b'\x00', b'\x20', b'\x12', b'\x6C', b'\x9C', b'\x61', b'\x25', b'\xE9',
    b'\xAC', b'\x70', b'\x34', b'\xB8', b'\xD0', b'\x90', b'\x95', b'\x00', b'\x40', b'\x48', b'\x00', b'\x00',
    b'\xA0', b'\x14', b'\x73', b'\x8E', b'\x4A', b'\x08', b'\x29', b'\x94', b'\x90', b'\x52', b'\xA8', b'\x98',
    b'\xA2', b'\x8E', b'\x42', b'\x29', b'\x29', b'\xA4', b'\x52', b'\x4A', b'\x0A', b'\x11', b'\x63', b'\xCE',
    b'\x49', b'\xEA', b'\x1C', b'\x85', b'\x50', b'\x52', b'\x28', b'\xA9', b'\x83', b'\xCA', b'\x39', b'\x08',
    b'\xA5', b'\xA4', b'\x94', b'\x42', b'\x2A', b'\x21', b'\x75', b'\xCE', b'\x41', b'\x07', b'\x25', b'\x85',
    b'\x90', b'\x52', b'\x09', b'\x21', b'\x95', b'\x8E', b'\x3A', b'\xE8', b'\x28', b'\x94', b'\x50', b'\x52',
    b'\x2A', b'\x25', b'\x94', b'\xD2', b'\x39', b'\x28', b'\xA5', b'\x84', b'\x14', b'\x4A', b'\x4A', b'\x29',
    b'\x95', b'\x90', b'\x42', b'\x48', b'\xA9', b'\x74', b'\x94', b'\x52', b'\x28', b'\x25', b'\x95', b'\x94',
    b'\x42', b'\x2A', b'\x21', b'\x95', b'\x52', b'\x4A', b'\x48', b'\x25', b'\x95', b'\x10', b'\x4A', b'\x0A',
    b'\x9D', b'\xA4', b'\x54', b'\x4A', b'\x0A', b'\xA9', b'\xA4', b'\x54', b'\x52', b'\x08', b'\x9D', b'\x74',
    b'\x90', b'\x42', b'\x27', b'\x25', b'\xA4', b'\x92', b'\x4A', b'\x0A', b'\xA9', b'\x93', b'\x94', b'\x52',
    b'\x2A', b'\x25', b'\xA5', b'\x94', b'\x4A', b'\x4A', b'\x25', b'\x74', b'\x52', b'\x42', b'\x2A', b'\x29',
    b'\xA5', b'\x10', b'\x42', b'\x4A', b'\xA9', b'\x94', b'\x10', b'\x4A', b'\x48', b'\x29', b'\xA5', b'\x4E',
    b'\x52', b'\x49', b'\xA9', b'\xA4', b'\x14', b'\x42', b'\x28', b'\x21', b'\x85', b'\x94', b'\x52', b'\x4A',
    b'\x25', b'\xA5', b'\x92', b'\x4A', b'\x4A', b'\x21', b'\x95', b'\x54', b'\x42', b'\x09', b'\xA5', b'\xA4',
    b'\x94', b'\x52', b'\x28', b'\xA1', b'\xA4', b'\x54', b'\x52', b'\x4A', b'\x29', b'\xA5', b'\x92', b'\x52',
    b'\x29', b'\x00', b'\x00', b'\xE0', b'\xC0', b'\x01', b'\x00', b'\x20', b'\xC0', b'\x08', b'\x3A', b'\xC9',
    b'\xA8', b'\xB2', b'\x08', b'\x1B', b'\x4D', b'\xB8', b'\xF0', b'\x00', b'\x14', b'\x1A', b'\xB2', b'\x12',
    b'\x00', b'\x20', b'\x03', b'\x00', b'\x40', b'\x94', b'\x74', b'\xD6', b'\x69', b'\xA7', b'\x49', b'\x22',
    b'\x08', b'\x31', b'\x45', b'\x99', b'\x27', b'\x0D', b'\x29', b'\xC6', b'\x20', b'\xB5', b'\xA4', b'\x2C',
    b'\xC3', b'\x10', b'\x53', b'\x92', b'\x89', b'\xF1', b'\x14', b'\x63', b'\x8C', b'\x39', b'\x28', b'\x46',
    b'\x43', b'\x0E', b'\x31', b'\xE4', b'\x94', b'\x18', b'\x17', b'\x4A', b'\x08', b'\xA1', b'\x83', b'\x62',
    b'\x3C', b'\x26', b'\x95', b'\x43', b'\xCA', b'\x50', b'\x51', b'\xB9', b'\xB7', b'\xD4', b'\x39', b'\x05',
    b'\xC5', b'\x16', b'\x63', b'\x7C', b'\xEF', b'\xB1', b'\x17', b'\x01', b'\x00', b'\x00', b'\x08', b'\x02',
    b'\x00', b'\x04', b'\x84', b'\x04', b'\x00', b'\x18', b'\x20', b'\x28', b'\x98', b'\x01', b'\x00', b'\x06',
    b'\x07', b'\x08', b'\x23', b'\x07', b'\x02', b'\x1D', b'\x01', b'\x04', b'\x0E', b'\x6D', b'\x00', b'\x80',
    b'\x81', b'\x08', b'\x99', b'\x09', b'\x0C', b'\x0A', b'\xA1', b'\xC1', b'\x41', b'\x26', b'\x00', b'\x3C',
    b'\x40', b'\x44', b'\x48', b'\x05', b'\x00', b'\x89', b'\x09', b'\x8A', b'\xD2', b'\x85', b'\x2E', b'\x08',
    b'\x21', b'\x82', b'\x74', b'\x11', b'\x64', b'\xF1', b'\xC0', b'\x85', b'\x13', b'\x37', b'\x9E', b'\xB8',
    b'\xE1', b'\x84', b'\x0E', b'\x6D', b'\x10', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x10', b'\x00',
    b'\xF0', b'\x01', b'\x00', b'\x90', b'\x50', b'\x00', b'\x11', b'\x11', b'\xD1', b'\xCC', b'\x55', b'\x58',
    b'\x5C', b'\x60', b'\x64', b'\x68', b'\x6C', b'\x70', b'\x74', b'\x78', b'\x7C', b'\x80', b'\x84', b'\x04',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x08', b'\x00', b'\x7C', b'\x00', b'\x00', b'\x24', b'\x22',
    b'\x40', b'\x44', b'\x44', b'\x34', b'\x73', b'\x15', b'\x16', b'\x17', b'\x18', b'\x19', b'\x1A', b'\x1B',
    b'\x1C', b'\x1D', b'\x1E', b'\x1F', b'\x20', b'\x21', b'\x01', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x40', b'\x40', b'\x40', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x20',
    b'\x00', b'\x00', b'\x00', b'\x40', b'\x40',
  ])
}

///| 长度表求和（用于压缩地核对整张表）。
fn vt_length_sum(values : Array[Int]) -> Int {
  let mut total = 0
  for v in values {
    total = total + v
  }
  total
}

///| 使用中的 entry 个数。
fn vt_used_count(values : Array[Int]) -> Int {
  let mut total = 0
  for v in values {
    if v > 0 {
      total = total + 1
    }
  }
  total
}

test "real: identification header（libvorbis 编码器产物）" {
  let info = vt_ident(vt_real_ident())
  assert_eq(info.channels, 1)
  assert_eq(info.sample_rate, 22050)
  assert_eq(info.bitrate_max, 0)
  assert_eq(info.bitrate_nominal, 45111)
  assert_eq(info.bitrate_min, 0)
}

test "real: comment header（libvorbis 编码器产物）" {
  let (vendor, comments) = vt_comment(vt_real_comment())
  assert_eq(vendor, "Xiph.Org libVorbis I 20200704 (Reducing Environment)")
  assert_eq(comments.length(), 1)
  assert_eq(comments[0], ("ENCODER", "libsndfile"))
}

test "real: 35 个 codebook 的全部字段" {
  let books = vt_books(vt_real_setup())
  assert_eq(books.length(), 35)
  // book0: dim=1 entries=64 ordered=0 sparse=0 lookup=0
  assert_eq(books[0].dimensions, 1)
  assert_eq(books[0].entries, 64)
  assert_eq(books[0].ordered, false)
  assert_eq(books[0].sparse, false)
  assert_eq(books[0].lookup_type, 0)
  assert_eq(vt_length_sum(books[0].lengths), 537)
  assert_eq(vt_used_count(books[0].lengths), 64)
  // book1: dim=1 entries=256 ordered=0 sparse=0 lookup=0
  assert_eq(books[1].dimensions, 1)
  assert_eq(books[1].entries, 256)
  assert_eq(books[1].ordered, false)
  assert_eq(books[1].sparse, false)
  assert_eq(books[1].lookup_type, 0)
  assert_eq(vt_length_sum(books[1].lengths), 3199)
  assert_eq(vt_used_count(books[1].lengths), 256)
  // book2: dim=1 entries=9 ordered=0 sparse=1 lookup=0
  assert_eq(books[2].dimensions, 1)
  assert_eq(books[2].entries, 9)
  assert_eq(books[2].ordered, false)
  assert_eq(books[2].sparse, true)
  assert_eq(books[2].lookup_type, 0)
  assert_eq(vt_length_sum(books[2].lengths), 25)
  assert_eq(vt_used_count(books[2].lengths), 8)
  // book3: dim=1 entries=25 ordered=0 sparse=1 lookup=0
  assert_eq(books[3].dimensions, 1)
  assert_eq(books[3].entries, 25)
  assert_eq(books[3].ordered, false)
  assert_eq(books[3].sparse, true)
  assert_eq(books[3].lookup_type, 0)
  assert_eq(vt_length_sum(books[3].lengths), 73)
  assert_eq(vt_used_count(books[3].lengths), 16)
  // book4: dim=1 entries=64 ordered=0 sparse=1 lookup=0
  assert_eq(books[4].dimensions, 1)
  assert_eq(books[4].entries, 64)
  assert_eq(books[4].ordered, false)
  assert_eq(books[4].sparse, true)
  assert_eq(books[4].lookup_type, 0)
  assert_eq(vt_length_sum(books[4].lengths), 337)
  assert_eq(vt_used_count(books[4].lengths), 39)
  // book5: dim=1 entries=9 ordered=0 sparse=1 lookup=0
  assert_eq(books[5].dimensions, 1)
  assert_eq(books[5].entries, 9)
  assert_eq(books[5].ordered, false)
  assert_eq(books[5].sparse, true)
  assert_eq(books[5].lookup_type, 0)
  assert_eq(vt_length_sum(books[5].lengths), 25)
  assert_eq(vt_used_count(books[5].lengths), 8)
  // book6: dim=1 entries=25 ordered=0 sparse=1 lookup=0
  assert_eq(books[6].dimensions, 1)
  assert_eq(books[6].entries, 25)
  assert_eq(books[6].ordered, false)
  assert_eq(books[6].sparse, true)
  assert_eq(books[6].lookup_type, 0)
  assert_eq(vt_length_sum(books[6].lengths), 78)
  assert_eq(vt_used_count(books[6].lengths), 16)
  // book7: dim=1 entries=64 ordered=0 sparse=1 lookup=0
  assert_eq(books[7].dimensions, 1)
  assert_eq(books[7].entries, 64)
  assert_eq(books[7].ordered, false)
  assert_eq(books[7].sparse, true)
  assert_eq(books[7].lookup_type, 0)
  assert_eq(vt_length_sum(books[7].lengths), 273)
  assert_eq(vt_used_count(books[7].lengths), 39)
  // book8: dim=1 entries=8 ordered=0 sparse=0 lookup=0
  assert_eq(books[8].dimensions, 1)
  assert_eq(books[8].entries, 8)
  assert_eq(books[8].ordered, false)
  assert_eq(books[8].sparse, false)
  assert_eq(books[8].lookup_type, 0)
  assert_eq(vt_length_sum(books[8].lengths), 35)
  assert_eq(vt_used_count(books[8].lengths), 8)
  // book9: dim=1 entries=64 ordered=0 sparse=0 lookup=0
  assert_eq(books[9].dimensions, 1)
  assert_eq(books[9].entries, 64)
  assert_eq(books[9].ordered, false)
  assert_eq(books[9].sparse, false)
  assert_eq(books[9].lookup_type, 0)
  assert_eq(vt_length_sum(books[9].lengths), 688)
  assert_eq(vt_used_count(books[9].lengths), 64)
  // book10: dim=1 entries=64 ordered=0 sparse=0 lookup=0
  assert_eq(books[10].dimensions, 1)
  assert_eq(books[10].entries, 64)
  assert_eq(books[10].ordered, false)
  assert_eq(books[10].sparse, false)
  assert_eq(books[10].lookup_type, 0)
  assert_eq(vt_length_sum(books[10].lengths), 768)
  assert_eq(vt_used_count(books[10].lengths), 64)
  // book11: dim=1 entries=128 ordered=0 sparse=0 lookup=0
  assert_eq(books[11].dimensions, 1)
  assert_eq(books[11].entries, 128)
  assert_eq(books[11].ordered, false)
  assert_eq(books[11].sparse, false)
  assert_eq(books[11].lookup_type, 0)
  assert_eq(vt_length_sum(books[11].lengths), 1371)
  assert_eq(vt_used_count(books[11].lengths), 128)
  // book12: dim=1 entries=32 ordered=0 sparse=0 lookup=0
  assert_eq(books[12].dimensions, 1)
  assert_eq(books[12].entries, 32)
  assert_eq(books[12].ordered, false)
  assert_eq(books[12].sparse, false)
  assert_eq(books[12].lookup_type, 0)
  assert_eq(vt_length_sum(books[12].lengths), 183)
  assert_eq(vt_used_count(books[12].lengths), 32)
  // book13: dim=1 entries=128 ordered=0 sparse=1 lookup=0
  assert_eq(books[13].dimensions, 1)
  assert_eq(books[13].entries, 128)
  assert_eq(books[13].ordered, false)
  assert_eq(books[13].sparse, true)
  assert_eq(books[13].lookup_type, 0)
  assert_eq(vt_length_sum(books[13].lengths), 1071)
  assert_eq(vt_used_count(books[13].lengths), 96)
  // book14: dim=1 entries=18 ordered=0 sparse=1 lookup=0
  assert_eq(books[14].dimensions, 1)
  assert_eq(books[14].entries, 18)
  assert_eq(books[14].ordered, false)
  assert_eq(books[14].sparse, true)
  assert_eq(books[14].lookup_type, 0)
  assert_eq(vt_length_sum(books[14].lengths), 72)
  assert_eq(vt_used_count(books[14].lengths), 17)
  // book15: dim=1 entries=50 ordered=0 sparse=1 lookup=0
  assert_eq(books[15].dimensions, 1)
  assert_eq(books[15].entries, 50)
  assert_eq(books[15].ordered, false)
  assert_eq(books[15].sparse, true)
  assert_eq(books[15].lookup_type, 0)
  assert_eq(vt_length_sum(books[15].lengths), 188)
  assert_eq(vt_used_count(books[15].lengths), 32)
  // book16: dim=1 entries=128 ordered=0 sparse=1 lookup=0
  assert_eq(books[16].dimensions, 1)
  assert_eq(books[16].entries, 128)
  assert_eq(books[16].ordered, false)
  assert_eq(books[16].sparse, true)
  assert_eq(books[16].lookup_type, 0)
  assert_eq(vt_length_sum(books[16].lengths), 698)
  assert_eq(vt_used_count(books[16].lengths), 78)
  // book17: dim=1 entries=18 ordered=0 sparse=1 lookup=0
  assert_eq(books[17].dimensions, 1)
  assert_eq(books[17].entries, 18)
  assert_eq(books[17].ordered, false)
  assert_eq(books[17].sparse, true)
  assert_eq(books[17].lookup_type, 0)
  assert_eq(vt_length_sum(books[17].lengths), 71)
  assert_eq(vt_used_count(books[17].lengths), 17)
  // book18: dim=1 entries=50 ordered=0 sparse=1 lookup=0
  assert_eq(books[18].dimensions, 1)
  assert_eq(books[18].entries, 50)
  assert_eq(books[18].ordered, false)
  assert_eq(books[18].sparse, true)
  assert_eq(books[18].lookup_type, 0)
  assert_eq(vt_length_sum(books[18].lengths), 244)
  assert_eq(vt_used_count(books[18].lengths), 32)
  // book19: dim=1 entries=128 ordered=0 sparse=1 lookup=0
  assert_eq(books[19].dimensions, 1)
  assert_eq(books[19].entries, 128)
  assert_eq(books[19].ordered, false)
  assert_eq(books[19].sparse, true)
  assert_eq(books[19].lookup_type, 0)
  assert_eq(vt_length_sum(books[19].lengths), 529)
  assert_eq(vt_used_count(books[19].lengths), 78)
  // book20: dim=2 entries=100 ordered=0 sparse=0 lookup=0
  assert_eq(books[20].dimensions, 2)
  assert_eq(books[20].entries, 100)
  assert_eq(books[20].ordered, false)
  assert_eq(books[20].sparse, false)
  assert_eq(books[20].lookup_type, 0)
  assert_eq(vt_length_sum(books[20].lengths), 942)
  assert_eq(vt_used_count(books[20].lengths), 100)
  // book21: dim=4 entries=81 ordered=0 sparse=0 lookup=1
  assert_eq(books[21].dimensions, 4)
  assert_eq(books[21].entries, 81)
  assert_eq(books[21].ordered, false)
  assert_eq(books[21].sparse, false)
  assert_eq(books[21].lookup_type, 1)
  assert_eq(vt_length_sum(books[21].lengths), 726)
  assert_eq(vt_used_count(books[21].lengths), 81)
  // book22: dim=4 entries=81 ordered=0 sparse=0 lookup=1
  assert_eq(books[22].dimensions, 4)
  assert_eq(books[22].entries, 81)
  assert_eq(books[22].ordered, false)
  assert_eq(books[22].sparse, false)
  assert_eq(books[22].lookup_type, 1)
  assert_eq(vt_length_sum(books[22].lengths), 577)
  assert_eq(vt_used_count(books[22].lengths), 81)
  // book23: dim=4 entries=625 ordered=0 sparse=0 lookup=1
  assert_eq(books[23].dimensions, 4)
  assert_eq(books[23].entries, 625)
  assert_eq(books[23].ordered, false)
  assert_eq(books[23].sparse, false)
  assert_eq(books[23].lookup_type, 1)
  assert_eq(vt_length_sum(books[23].lengths), 8190)
  assert_eq(vt_used_count(books[23].lengths), 625)
  // book24: dim=4 entries=625 ordered=0 sparse=0 lookup=1
  assert_eq(books[24].dimensions, 4)
  assert_eq(books[24].entries, 625)
  assert_eq(books[24].ordered, false)
  assert_eq(books[24].sparse, false)
  assert_eq(books[24].lookup_type, 1)
  assert_eq(vt_length_sum(books[24].lengths), 6911)
  assert_eq(vt_used_count(books[24].lengths), 625)
  // book25: dim=2 entries=81 ordered=0 sparse=0 lookup=1
  assert_eq(books[25].dimensions, 2)
  assert_eq(books[25].entries, 81)
  assert_eq(books[25].ordered, false)
  assert_eq(books[25].sparse, false)
  assert_eq(books[25].lookup_type, 1)
  assert_eq(vt_length_sum(books[25].lengths), 726)
  assert_eq(vt_used_count(books[25].lengths), 81)
  // book26: dim=2 entries=81 ordered=0 sparse=0 lookup=1
  assert_eq(books[26].dimensions, 2)
  assert_eq(books[26].entries, 81)
  assert_eq(books[26].ordered, false)
  assert_eq(books[26].sparse, false)
  assert_eq(books[26].lookup_type, 1)
  assert_eq(vt_length_sum(books[26].lengths), 634)
  assert_eq(vt_used_count(books[26].lengths), 81)
  // book27: dim=4 entries=81 ordered=0 sparse=0 lookup=1
  assert_eq(books[27].dimensions, 4)
  assert_eq(books[27].entries, 81)
  assert_eq(books[27].ordered, false)
  assert_eq(books[27].sparse, false)
  assert_eq(books[27].lookup_type, 1)
  assert_eq(vt_length_sum(books[27].lengths), 907)
  assert_eq(vt_used_count(books[27].lengths), 81)
  // book28: dim=2 entries=121 ordered=0 sparse=0 lookup=1
  assert_eq(books[28].dimensions, 2)
  assert_eq(books[28].entries, 121)
  assert_eq(books[28].ordered, false)
  assert_eq(books[28].sparse, false)
  assert_eq(books[28].lookup_type, 1)
  assert_eq(vt_length_sum(books[28].lengths), 992)
  assert_eq(vt_used_count(books[28].lengths), 121)
  // book29: dim=2 entries=121 ordered=0 sparse=0 lookup=1
  assert_eq(books[29].dimensions, 2)
  assert_eq(books[29].entries, 121)
  assert_eq(books[29].ordered, false)
  assert_eq(books[29].sparse, false)
  assert_eq(books[29].lookup_type, 1)
  assert_eq(vt_length_sum(books[29].lengths), 1399)
  assert_eq(vt_used_count(books[29].lengths), 121)
  // book30: dim=2 entries=121 ordered=0 sparse=0 lookup=1
  assert_eq(books[30].dimensions, 2)
  assert_eq(books[30].entries, 121)
  assert_eq(books[30].ordered, false)
  assert_eq(books[30].sparse, false)
  assert_eq(books[30].lookup_type, 1)
  assert_eq(vt_length_sum(books[30].lengths), 947)
  assert_eq(vt_used_count(books[30].lengths), 121)
  // book31: dim=2 entries=225 ordered=0 sparse=0 lookup=1
  assert_eq(books[31].dimensions, 2)
  assert_eq(books[31].entries, 225)
  assert_eq(books[31].ordered, false)
  assert_eq(books[31].sparse, false)
  assert_eq(books[31].lookup_type, 1)
  assert_eq(vt_length_sum(books[31].lengths), 1985)
  assert_eq(vt_used_count(books[31].lengths), 225)
  // book32: dim=2 entries=225 ordered=0 sparse=0 lookup=1
  assert_eq(books[32].dimensions, 2)
  assert_eq(books[32].entries, 225)
  assert_eq(books[32].ordered, false)
  assert_eq(books[32].sparse, false)
  assert_eq(books[32].lookup_type, 1)
  assert_eq(vt_length_sum(books[32].lengths), 2107)
  assert_eq(vt_used_count(books[32].lengths), 225)
  // book33: dim=2 entries=289 ordered=0 sparse=0 lookup=1
  assert_eq(books[33].dimensions, 2)
  assert_eq(books[33].entries, 289)
  assert_eq(books[33].ordered, false)
  assert_eq(books[33].sparse, false)
  assert_eq(books[33].lookup_type, 1)
  assert_eq(vt_length_sum(books[33].lengths), 2836)
  assert_eq(vt_used_count(books[33].lengths), 289)
  // book34: dim=2 entries=100 ordered=0 sparse=0 lookup=0
  assert_eq(books[34].dimensions, 2)
  assert_eq(books[34].entries, 100)
  assert_eq(books[34].ordered, false)
  assert_eq(books[34].sparse, false)
  assert_eq(books[34].lookup_type, 0)
  assert_eq(vt_length_sum(books[34].lengths), 1029)
  assert_eq(vt_used_count(books[34].lengths), 100)
  // 全部长度表的合计
  let mut total_len = 0
  let mut total_used = 0
  for b in books {
    total_len = total_len + vt_length_sum(b.lengths)
    total_used = total_used + vt_used_count(b.lengths)
  }
  assert_eq(total_len, 41373)
  assert_eq(total_used, 4049)
}

test "real: 整个 setup header（floor/residue/mapping/mode）校验通过" {
  let msg = vt_unsupported_message(() => {
    ignore(decode_vorbis(vt_info(), vt_real_setup(), []))
  })
  assert_true(msg.contains("尚未实现"))
  assert_true(msg.contains("35 codebook"))
}

