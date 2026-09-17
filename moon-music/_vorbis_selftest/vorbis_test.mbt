// moonaudio —— vorbis.mbt 的黑盒测试。
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
/// 手工构造的 comment header：vendor = "moonaudio"，两条 comment：
/// "ARTIST=Bob"、"TITLE=Song"，结尾 framing 字节 0x01。
/// ```
/// 03 76 6F 72 62 69 73      "\x03vorbis"
/// 09 00 00 00               vendor_length = 9
/// 6D 6F 6F 6E 61 75 64 69 6F   "moonaudio"
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
  assert_eq(vendor, "moonaudio")
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
  assert_eq(vendor, "moonaudio")
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
