// moonbit-music —— ID3v2 解析器的黑盒测试
//
// 全部字节数组都是手工构造的常量，期望值手算，**不用自己写的编码器生成再解码**
// （避免自证循环）。v2.3 的帧 size 用普通大端写法、v2.4 用 syncsafe 写法，
// 两种写法在每个用例里都刻意展开成字节，方便人工核对。

///|
/// v2.3 帧头：4 字节 ID + 普通大端 uint32 size + 2 字节 flags（共 10 字节）。
fn t_frame23(id : Bytes, size : Int) -> Array[Byte] {
  let out : Array[Byte] = []
  out.push(id[0])
  out.push(id[1])
  out.push(id[2])
  out.push(id[3])
  out.push(((size >> 24) & 0xFF).to_byte())
  out.push(((size >> 16) & 0xFF).to_byte())
  out.push(((size >> 8) & 0xFF).to_byte())
  out.push((size & 0xFF).to_byte())
  out.push(b'\x00')
  out.push(b'\x00')
  out
}

///|
/// v2.4 帧头：4 字节 ID + **syncsafe** 4 字节 size + 2 字节 flags（共 10 字节）。
fn t_frame24(id : Bytes, size : Int) -> Array[Byte] {
  let out : Array[Byte] = []
  out.push(id[0])
  out.push(id[1])
  out.push(id[2])
  out.push(id[3])
  out.push(((size >> 21) & 0x7F).to_byte())
  out.push(((size >> 14) & 0x7F).to_byte())
  out.push(((size >> 7) & 0x7F).to_byte())
  out.push((size & 0x7F).to_byte())
  out.push(b'\x00')
  out.push(b'\x00')
  out
}

///|
/// v2.2 帧头：3 字节 ID + 普通大端 uint24 size（共 6 字节）。
fn t_frame22(id : Bytes, size : Int) -> Array[Byte] {
  let out : Array[Byte] = []
  out.push(id[0])
  out.push(id[1])
  out.push(id[2])
  out.push(((size >> 16) & 0xFF).to_byte())
  out.push(((size >> 8) & 0xFF).to_byte())
  out.push((size & 0xFF).to_byte())
  out
}

///|
/// 10 字节 ID3v2 标签头。`size` 是帧区长度，按 syncsafe 写入。
fn t_header(major : Int, minor : Int, flags : Int, size : Int) -> Array[Byte] {
  let out : Array[Byte] = []
  out.push(b'I')
  out.push(b'D')
  out.push(b'3')
  out.push(major.to_byte())
  out.push(minor.to_byte())
  out.push(flags.to_byte())
  out.push(((size >> 21) & 0x7F).to_byte())
  out.push(((size >> 14) & 0x7F).to_byte())
  out.push(((size >> 7) & 0x7F).to_byte())
  out.push((size & 0x7F).to_byte())
  out
}

///|
/// 把若干字节块拼成一个 `Bytes`。
fn t_bytes(parts : Array[Array[Byte]]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
/// 把字符串的每个字符按低 8 位展开成字节（测试里的文本都是 ASCII）。
fn t_ascii(s : String) -> Array[Byte] {
  let out : Array[Byte] = []
  for c in s {
    out.push(c.to_int().to_byte())
  }
  out
}

///|
/// 一个帧：(帧 ID, 帧体)。
struct TFrame {
  id : Bytes
  body : Array[Byte]
}

///|
/// 构造帧。
fn t_frame(id : Bytes, body : Array[Byte]) -> TFrame {
  { id, body }
}

///|
/// 帧头长度：v2.2 是 6 字节（3 ID + 3 size），v2.3/v2.4 是 10 字节。
fn t_frame_header_len(version : Int) -> Int {
  if version == 2 {
    6
  } else {
    10
  }
}

///|
/// 帧区总字节数：每个帧的帧头 + 帧体长度之和。
fn t_frames_len(version : Int, frames : Array[TFrame]) -> Int {
  let mut total = 0
  for f in frames {
    total = total + t_frame_header_len(version) + f.body.length()
  }
  total
}

///|
/// 用"帧区字节"拼出完整的标签（10 字节 header + 帧区）。
/// `body_size` 作为独立参数显式传入（不自动算），这样每个用例里
/// **声明长度与真实字节数是否一致**本身也是被测内容。
fn t_tag(
  version : Int,
  flags : Int,
  body_size : Int,
  frames : Array[TFrame],
) -> Bytes {
  let parts : Array[Array[Byte]] = [t_header(version, 0, flags, body_size)]
  for f in frames {
    if version == 2 {
      parts.push(t_frame22(f.id, f.body.length()))
    } else if version == 4 {
      parts.push(t_frame24(f.id, f.body.length()))
    } else {
      parts.push(t_frame23(f.id, f.body.length()))
    }
    parts.push(f.body)
  }
  t_bytes(parts)
}

///|
/// 用真实帧区长度拼出标签，并核对 `id3v2_size` 与真实字节数一致。
///
/// 必须声明 `raise`：`assert_eq` 本身是可抛错的，而普通函数里不能调用可抛错函数
/// （`test { }` 块允许抛错，所以调用点不需要改动）。
fn t_check_tag(
  version : Int,
  flags : Int,
  frames : Array[TFrame],
) -> Bytes raise {
  let size = t_frames_len(version, frames)
  let tag = t_tag(version, flags, size, frames)
  assert_eq(tag.length(), 10 + size)
  assert_eq(id3v2_size(tag), 10 + size)
  tag
}

///|
/// 用例 1：最小 v2.3 标签（TIT2 Latin-1 + TPE1 UTF-8），
/// 同时核对 `id3v2_size` 与 `raw_frames` 保留的 4 字节 ID。
test "v2.3 最小标签：Latin-1 与 UTF-8 正文" {
  // Latin-1：0x48 0x65 0x69 0xE9 = 'H' 'e' 'i' 'é'（0xE9 在 Latin-1 里就是 U+00E9）。
  let title_latin1 : Array[Byte] = [b'\x00', b'H', b'e', b'i', b'\xE9']
  // 纯 ASCII 的 Latin-1。
  let album_latin1 : Array[Byte] = [
    b'\x00', b'A', b'l', b'b', b'u', b'm', b' ', b'1',
  ]
  // "歌曲" 的 UTF-8 是 E6 AD 8C E6 9B B2。
  let artist_utf8 : Array[Byte] = [
    b'\x03', b'\xE6', b'\xAD', b'\x8C', b'\xE6', b'\x9B', b'\xB2',
  ]
  let tag = t_check_tag(3, 0, [
    t_frame(b"TIT2", title_latin1),
    t_frame(b"TPE1", artist_utf8),
    t_frame(b"TALB", album_latin1),
  ])
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.version, 3)
  assert_eq(parsed.title, Some("Heié"))
  assert_eq(parsed.artist, Some("歌曲"))
  assert_eq(parsed.album, Some("Album 1"))
  assert_eq(parsed.year, None)
  assert_eq(parsed.raw_frames.length(), 3)
  assert_eq(parsed.raw_frames[0].0, "TIT2")
  assert_eq(parsed.raw_frames[1].0, "TPE1")
  assert_eq(parsed.raw_frames[2].0, "TALB")
}

///|
/// 用例 2：v2.4 的帧 size 是 **syncsafe**。size=129 时 size 字段是
/// `00 00 01 01`，普通大端解读会得到 257（帧体越界），syncsafe 解读才是 129。
test "v2.4 帧 size 用 syncsafe（> 127）" {
  let body : Array[Byte] = [b'\x03', b'a']
  for _ in 0..<127 {
    body.push(b'A')
  }
  assert_eq(body.length(), 129)
  let tag = t_check_tag(4, 0, [t_frame(b"TIT2", body)])
  assert_eq(tag.length(), 149)
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.version, 4)
  assert_eq(parsed.raw_frames[0].1.length(), 129)
  // 正文 = 'a' + 127 个 'A'，共 128 个字符（每个 1 字节，UTF-8 与 Latin-1 同形）。
  assert_eq(parsed.title.unwrap().length(), 128)
  // 对照组：同样的 size 字节在 v2.3 是普通大端 = 257 > 129 → Truncated。
  let v23 = t_bytes([t_header(3, 0, 0, 139), t_frame23(b"TIT2", 257), body])
  let outcome = try {
    let _ = parse_id3v2(v23)
    "no error"
  } catch {
    AudioError::Truncated(_) => "truncated"
    _ => "other"
  }
  assert_eq(outcome, "truncated")
}

///|
/// 用例 3：TCON 的 `"(17)"` 与 `"(17)Rock"` 都提取出数字 17。
test "TCON 的括号数字形式" {
  let plain : Array[Byte] = [b'\x00', b'(', b'1', b'7', b')']
  let mixed : Array[Byte] = [
    b'\x00', b'(', b'1', b'7', b')', b'R', b'o', b'c', b'k',
  ]
  let tag = t_check_tag(3, 0, [
    t_frame(b"TCON", plain),
    t_frame(b"TCON", mixed),
  ])
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.genre, Some("17"))
  assert_eq(parsed.raw_frames.length(), 2)
  assert_eq(parsed.raw_frames[0].1.length(), 5)
  assert_eq(parsed.raw_frames[1].1.length(), 9)
}

///|
/// 用例 4：COMM = 编码(1) + 语言(3) + 空描述(1) + 正文（Latin-1）。
test "COMM 帧：语言 + 空描述 + 正文" {
  let body : Array[Byte] = [b'\x00', b'E', b'N', b'G', b'\x00']
  for b in t_ascii("hello") {
    body.push(b)
  }
  assert_eq(body.length(), 10)
  let tag = t_check_tag(3, 0, [t_frame(b"COMM", body)])
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.comment, Some("hello"))
}

///|
/// 用例 5：APIC = 编码(1) + "image/png"\0 + 图片类型(1) + 空描述(1) + 图片数据。
test "APIC 帧：图片字节被提取到 pictures" {
  let body : Array[Byte] = [b'\x00']
  for b in t_ascii("image/png") {
    body.push(b)
  }
  body.push(b'\x00')
  body.push(b'\x03') // 图片类型：front cover
  body.push(b'\x00') // 空描述
  body.push(b'\x89')
  body.push(b'P')
  body.push(b'N')
  body.push(b'G')
  // 1(编码) + 9("image/png") + 1(NUL) + 1(图片类型) + 1(空描述 NUL) + 4(PNG 签名) = 17。
  assert_eq(body.length(), 17)
  let tag = t_check_tag(3, 0, [t_frame(b"APIC", body)])
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.pictures.length(), 1)
  assert_eq(parsed.pictures[0], b"\x89PNG")
  assert_eq(parsed.raw_frames[0].1.length(), 17)
}

///|
/// 用例 6：unsynchronisation —— 帧体里的 `0xFF 0x00` 还原成 `0xFF`。
test "unsynchronisation：0xFF 0x00 还原为 0xFF" {
  assert_eq(unsync(b"\xFF\x00"), b"\xFF")
  // 逐对消除：三字节还原成 0xFF 0x00。
  assert_eq(unsync(b"\xFF\x00\x00"), b"\xFF\x00")
  // 没有 0xFF 时原样返回。
  assert_eq(unsync(b"abc"), b"abc")
  assert_eq(unsync(b"\xFF"), b"\xFF")
  assert_eq(unsync(b""), b"")
  // 标签级 unsync：帧体在**未还原**的字节流里是 5 字节
  // （编码 0x00 + 'A' + 'B' + 0xFF + 插入的 0x00），但帧头里的 size 描述的是
  // **还原之后**的长度 4。标签 header 的 size 覆盖的是未还原的字节数。
  let body : Array[Byte] = [b'\x00', b'A', b'B', b'\xFF', b'\x00']
  assert_eq(body.length(), 5)
  let tag = t_bytes([
    t_header(3, 0, 0x80, 15),
    t_frame23(b"TIT2", 4),
    body,
  ])
  assert_eq(tag.length(), 25)
  assert_eq(id3v2_size(tag), 25)
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.version, 3)
  assert_eq(parsed.raw_frames.length(), 1)
  assert_eq(parsed.raw_frames[0].1.length(), 4)
  assert_eq(parsed.title, Some("ABÿ"))
  // 还原后的帧体 = 编码字节 0x00 + 'A' 'B' 0xFF（插入的 0x00 已去掉）。
  assert_eq(parsed.raw_frames[0].1, b"\x00AB\xFF")
}

///|
/// 用例 7：没有 ID3v2 头 → None + 0；`ID3` 前缀但版本未知也是 None + 0。
test "无标签：parse_id3v2 = None 且 id3v2_size = 0" {
  // `Id3v2Tag` 没有实现 `Eq`（契约里只有 Debug），所以用 `is` 模式判断而非 assert_eq。
  assert_true(parse_id3v2(b"RIFF....WAVEfmt ") is None)
  assert_eq(id3v2_size(b"RIFF....WAVEfmt "), 0)
  assert_true(parse_id3v2(b"") is None)
  assert_eq(id3v2_size(b""), 0)
  assert_true(parse_id3v2(b"ID") is None)
  assert_eq(id3v2_size(b"ID"), 0)
  // 版本号 5 不是 2/3/4，帧头布局不可知 → 头部就判为"无标签"。
  let unknown_version = t_bytes([t_header(5, 0, 0, 0)])
  assert_eq(unknown_version.length(), 10)
  assert_eq(unknown_version[3].to_int(), 5)
  let unknown_tag = parse_id3v2(unknown_version)
  match unknown_tag {
    None => assert_true(true)
    Some(_) => fail("版本号 5 应当返回 None")
  }
  assert_eq(id3v2_size(unknown_version), 0)
}

///|
/// 用例 8：padding（全 0 帧 ID）之后停止解析，raw_frames 只保留有效帧。
test "padding 之后停止解析" {
  let title_body : Array[Byte] = [b'\x00', b'A']
  let padding : Array[Byte] = Array::make(8, b'\x00')
  let tag = t_bytes([
    t_header(3, 0, 0, 20),
    t_frame23(b"TIT2", 2),
    title_body,
    padding,
  ])
  assert_eq(tag.length(), 30)
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.title, Some("A"))
  assert_eq(parsed.raw_frames.length(), 1)
  assert_eq(id3v2_size(tag), 30)
}

///|
/// 用例 9：截断的 header（3 字节 `ID3` 但不足 10 字节）→ Truncated；
/// 另外覆盖"header 声明长度超出数据"的 Truncated。
test "截断的 header 抛 Truncated" {
  assert_eq(id3v2_size(b"ID3"), 0)
  let outcome = try {
    let _ = parse_id3v2(b"ID3")
    "no error"
  } catch {
    AudioError::Truncated(_) => "truncated"
    _ => "other"
  }
  assert_eq(outcome, "truncated")
  // header 声称帧区 32 字节，实际一个字节都没给。
  let short = t_bytes([t_header(3, 0, 0, 32)])
  assert_eq(id3v2_size(short), 0)
  let outcome2 = try {
    let _ = parse_id3v2(short)
    "no error"
  } catch {
    AudioError::Truncated(_) => "truncated"
    _ => "other"
  }
  assert_eq(outcome2, "truncated")
}

///|
/// 用例 10：raw_frames 保留**原始帧 ID**，未映射的帧也原样保留。
test "raw_frames 保留原始帧 ID 与未映射帧" {
  let title_body : Array[Byte] = [b'\x00', b'T']
  let txxx_body : Array[Byte] = [b'\x00', b'k', b'\x00', b'v']
  let tag = t_check_tag(3, 0, [
    t_frame(b"TIT2", title_body),
    t_frame(b"TXXX", txxx_body),
  ])
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.raw_frames.length(), 2)
  assert_eq(parsed.raw_frames[0].0, "TIT2")
  assert_eq(parsed.raw_frames[0].1, b"\x00T")
  assert_eq(parsed.raw_frames[1].0, "TXXX")
  assert_eq(parsed.raw_frames[1].1, b"\x00k\x00v")
  assert_eq(parsed.title, Some("T"))
  assert_eq(parsed.composer, None)
}

///|
/// 用例 11：v2.2 的 3 字节帧头（ID + 3 字节 size）。字段要正确归一化填充，
/// 但 raw_frames 里仍是原始 ID（`TT2` / `TP1` / `TRK`）。
test "v2.2 的 3 字节帧头" {
  let title_body : Array[Byte] = [b'\x00', b'O', b'k']
  let artist_body : Array[Byte] = [b'\x00', b'B', b'o', b'b']
  let track_body : Array[Byte] = [b'\x00', b'7']
  let tag = t_check_tag(2, 0, [
    t_frame(b"TT2", title_body),
    t_frame(b"TP1", artist_body),
    t_frame(b"TRK", track_body),
  ])
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.version, 2)
  assert_eq(parsed.title, Some("Ok"))
  assert_eq(parsed.artist, Some("Bob"))
  assert_eq(parsed.track, Some("7"))
  assert_eq(parsed.raw_frames.length(), 3)
  assert_eq(parsed.raw_frames[0].0, "TT2")
  assert_eq(parsed.raw_frames[1].0, "TP1")
  assert_eq(parsed.raw_frames[2].0, "TRK")
}

///|
/// 附加：UTF-16 正文 —— 带 BOM 的 LE（含代理对 U+1F600）与无 BOM 的 BE（编码 2）。
test "UTF-16 正文：BOM 字节序与代理对" {
  // FF FE = LE BOM；'A' 是 41 00；'你' 是 60 4F；U+1F600 是 3D D8 00 DE。
  let le : Array[Byte] = [
    b'\x01', b'\xFF', b'\xFE', b'A', b'\x00', b'\x60', b'\x4F', b'\x3D',
    b'\xD8', b'\x00', b'\xDE',
  ]
  let tag_le = t_check_tag(3, 0, [t_frame(b"TIT2", le)])
  assert_eq(parse_id3v2(tag_le).unwrap().title, Some("A你😀"))
  // 编码 2 = UTF-16BE 无 BOM：00 41 4F 60 → "A你"
  let be : Array[Byte] = [b'\x02', b'\x00', b'A', b'\x4F', b'\x60']
  let tag_be = t_check_tag(3, 0, [t_frame(b"TIT2", be)])
  assert_eq(parse_id3v2(tag_be).unwrap().title, Some("A你"))
}

///|
/// 附加：v2.3 扩展头（4 字节 size 是**非** syncsafe 的普通大端）整块跳过，
/// 之后正常读到帧。
test "v2.3 扩展头被跳过" {
  // size = 6（00 00 00 06）+ flags(2) + padding size(4)，共 10 字节。
  let ext : Array[Byte] = [
    b'\x00', b'\x00', b'\x00', b'\x06', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00',
  ]
  let title_body : Array[Byte] = [b'\x00', b'Z']
  // 帧区 = 扩展头 10 + 帧 10 + 帧体 2 = 22 字节。
  let tag = t_bytes([
    t_header(3, 0, 0x40, 22),
    ext,
    t_frame23(b"TIT2", 2),
    title_body,
  ])
  assert_eq(tag.length(), 32)
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.title, Some("Z"))
  assert_eq(parsed.raw_frames.length(), 1)
}

///|
/// 附加：v2.4 footer（flags bit4）—— 总长度要再加 10 字节 footer。
test "v2.4 footer 计入总长度" {
  let title_body : Array[Byte] = [b'\x00', b'F']
  let footer : Array[Byte] = [
    b'3', b'D', b'I', b'\x04', b'\x00', b'\x10', b'\x00', b'\x00', b'\x00',
    b'\x0C',
  ]
  let tag = t_bytes([
    t_header(4, 0, 0x10, 12),
    t_frame24(b"TIT2", 2),
    title_body,
    footer,
  ])
  assert_eq(tag.length(), 32)
  assert_eq(id3v2_size(tag), 32)
  assert_eq(parse_id3v2(tag).unwrap().title, Some("F"))
}

///|
/// 附加：TDRC（v2.4）取 ISO 8601 时间戳前 4 位作为年份；TRCK 直接取文本。
test "v2.4 TDRC 与 TRCK" {
  let tdrc_body : Array[Byte] = [
    b'\x00', b'2', b'0', b'1', b'1', b'-', b'0', b'5', b'-', b'0', b'3',
  ]
  let trck_body : Array[Byte] = [b'\x00', b'3', b'/', b'1', b'2']
  let tag = t_check_tag(4, 0, [
    t_frame(b"TDRC", tdrc_body),
    t_frame(b"TRCK", trck_body),
  ])
  let parsed = parse_id3v2(tag).unwrap()
  assert_eq(parsed.year, Some("2011"))
  assert_eq(parsed.track, Some("3/12"))
}
