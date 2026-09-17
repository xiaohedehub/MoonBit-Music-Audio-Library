// moonbit-music —— ID3v2 标签解析（ID3v2.2 / v2.3 / v2.4）
//
// 只解析标签区域，不依赖任何其他实现文件，只使用 moonbitlang/core。
// 所有私有辅助函数统一加 `id3_` 前缀，避免与并行开发的其他文件重名。
//
// 参考：ID3v2.2 / v2.3.0 / v2.4.0 规范（id3.org）。

///|
/// 已解析的 ID3v2 标签。
///
/// `version` 是主版本号（2、3 或 4）。各字段为 `None` 表示标签中没有对应的帧。
/// `raw_frames` 保留**原始帧 ID**（v2.2 不归一化）与**原始帧体**，便于调用方
/// 取用本结构未覆盖的私有帧。
pub(all) struct Id3v2Tag {
  /// 主版本号：2、3 或 4。
  version : Int
  /// 标题：`TIT2` / `TT2`。
  title : String?
  /// 艺术家：`TPE1` / `TP1`。
  artist : String?
  /// 专辑：`TALB` / `TAL`。
  album : String?
  /// 年份：`TYER`(v2.3) / `TDRC`(v2.4) / `TYE`(v2.2)。
  year : String?
  /// 音轨：`TRCK` / `TRK`。
  track : String?
  /// 流派：`TCON` / `TCO`。带括号的数值形式会归一化成纯数字。
  genre : String?
  /// 注释：`COMM` / `COM` 的正文（描述非空时拼成 `描述 正文`）。
  comment : String?
  /// 作曲：`TCOM` / `TCM`。
  composer : String?
  /// `APIC` / `PIC` 帧中的图片数据，按出现顺序排列。
  pictures : Array[Bytes]
  /// 全部已解析帧的 `(原始帧 ID, 帧体)`，按出现顺序排列。
  raw_frames : Array[(String, Bytes)]
} derive(Eq, @debug.Debug)

///|
/// 字段累加器。`Id3v2Tag` 的字段是只读的，解析过程中先用可变局部量收集，
/// 最后一次性构造不可变的 `Id3v2Tag`。
priv struct Id3Fields {
  mut title : String?
  mut artist : String?
  mut album : String?
  mut year : String?
  mut track : String?
  mut genre : String?
  mut comment : String?
  mut composer : String?
  mut pictures : Array[Bytes]
  mut raw_frames : Array[(String, Bytes)]
}

///|
/// 空累加器。
fn id3_new_fields() -> Id3Fields {
  {
    title: None,
    artist: None,
    album: None,
    year: None,
    track: None,
    genre: None,
    comment: None,
    composer: None,
    pictures: [],
    raw_frames: [],
  }
}

///|
/// 追加一条原始帧记录。
///
/// 用"取出—追加—放回"的写法而不是 `fields.raw_frames.push(...)`：
/// 后者在该工具链上会误报 `unused_mut`。
fn id3_fields_push_raw(fields : Id3Fields, id : String, body : Bytes) -> Unit {
  let frames = fields.raw_frames
  frames.push((id, body))
  fields.raw_frames = frames
}

///|
/// 追加一张图片。
fn id3_fields_push_picture(fields : Id3Fields, picture : Bytes) -> Unit {
  let pictures = fields.pictures
  pictures.push(picture)
  fields.pictures = pictures
}

///|
/// 文本编码（帧体首字节）。
///
/// `Keep` 用于 `APIC` 的 MIME 类型字段与 `COMM` 的语言字段——这两处永远是
/// Latin-1，与帧的编码字节无关。
priv enum Id3Encoding {
  Id3Latin1
  Id3Utf16Bom
  Id3Utf16Be
  Id3Utf8
  Id3Keep
}

///|
/// 解析 ID3v2 标签。数据开头不是 `ID3` 头（或版本号无法识别）时返回 `None`。
///
/// 越界的结构抛 `AudioError::Truncated`；畸形但可跳过的帧被跳过，不中断解析。
pub fn parse_id3v2(data : Bytes) -> Id3v2Tag? raise AudioError {
  let header = match id3_header(data) {
    None => return None
    Some(h) => h
  }
  // 版本号已由 `id3_header` 校验为 2/3/4。
  // v2.4 带 footer 时，标签体之后还有 10 字节 footer，帧区从 10 开始、到 footer 前结束。
  let start = 10
  let end = if header.has_footer { header.total - 10 } else { header.total }
  // 帧区字节（footer 不属于帧区）。`[start:end]` 得到视图，转成独立的 Bytes。
  let body = if start <= end { id3_copy_range(data, start, end - start) } else { b"" }
  // 标签级 unsynchronisation（v2.3 常见）：先还原整个标签体，再做所有解析。
  // 规范里扩展头也参与 unsynchronisation，所以放在跳过扩展头之前。
  let region = if header.unsync { unsync(body) } else { body }
  // 扩展头：跳过（v2.3 的 size 是普通大端 uint32，v2.4 是 syncsafe）。
  let mut offset = id3_skip_extended_header(region, 0, header.version)
  let fields = id3_new_fields()
  while true {
    let frame = match id3_next_frame(region, offset, header.version) {
      None => break
      Some(f) => f
    }
    offset = frame.next_offset
    id3_fields_push_raw(fields, frame.id, frame.body)
    id3_apply_frame(fields, frame.id, frame.body)
  }
  Some(id3_tag_of(header.version, fields))
}

///|
/// 用累加器构造不可变标签。
fn id3_tag_of(version : Int, fields : Id3Fields) -> Id3v2Tag {
  {
    version,
    title: fields.title,
    artist: fields.artist,
    album: fields.album,
    year: fields.year,
    track: fields.track,
    genre: fields.genre,
    comment: fields.comment,
    composer: fields.composer,
    pictures: fields.pictures,
    raw_frames: fields.raw_frames,
  }
}

///|
/// 跳过 ID3v2 区域所需的字节数（含 10 字节 header、扩展头、帧区、padding，
/// 以及 v2.4 的 footer）。数据开头不是 `ID3` 头、版本号不是 2/3/4、
/// 或 header 声明的长度超出数据时返回 0。
///
/// MP3 解码器用它定位第一个音频帧。返回值保证不会超过 `data.length()`，
/// 因此调用方可以直接 `data[id3v2_size(data):]` 而不必再判越界。
pub fn id3v2_size(data : Bytes) -> Int {
  let header = match id3_header_opt(data) {
    None => return 0
    Some(h) => h
  }
  header.total
}

///|
/// 应用 unsynchronisation 还原：`0xFF 0x00` → `0xFF`。
///
/// 注意 `0xFF 0x00 0x00` 还原为 `0xFF 0x00`（逐对消除，符合规范）。
pub fn unsync(data : Bytes) -> Bytes {
  let len = data.length()
  if len == 0 {
    return b""
  }
  if !id3_contains_ff00(data) {
    // 没有需要还原的字节，原样返回，避免无谓拷贝。
    return data
  }
  let out = Buffer()
  let mut i = 0
  while i < len {
    let b = data[i].to_int()
    out.write_byte(b.to_byte())
    if b == 0xFF && i + 1 < len && data[i + 1].to_int() == 0x00 {
      i += 2
    } else {
      i += 1
    }
  }
  out.to_bytes()
}

///|
/// 标签头解析结果。
priv struct Id3Header {
  version : Int
  /// 需要跳过的总字节数：10 + 声明长度 + (footer ? 10 : 0)。
  total : Int
  unsync : Bool
  has_footer : Bool
}

///|
/// 宽松版标签头解析：任何"不能确认存在完整标签"的情况都返回 `None`。
/// 供 `id3v2_size` 使用（该函数不允许抛错）。
fn id3_header_opt(data : Bytes) -> Id3Header? {
  id3_header(data) catch {
    AudioError::Truncated(_) => None
    _ => None
  }
}

///|
/// 解析 10 字节标签头，同时校验声明的总长度是否真的有数据。
///
/// - 数据长度 < 3 或前三字节不是 `ID3` 时返回 `None`（本来就没有标签）。
/// - 数据长度 >= 3 但 < 10 时抛 `Truncated`（声明了标签却截断）。
/// - 头部声明长度超出数据时抛 `Truncated`。
/// - 版本号不是 2/3/4 时返回 `None`（帧头布局不可知，无法可靠跳过）。
fn id3_header(data : Bytes) -> Id3Header? raise AudioError {
  let len = data.length()
  if len < 3 {
    return None
  }
  if data[0] != b'I' || data[1] != b'D' || data[2] != b'3' {
    return None
  }
  if len < 10 {
    raise AudioError::Truncated(offset=0, needed=10, available=len)
  }
  let version = data[3].to_int()
  if version != 2 && version != 3 && version != 4 {
    // 帧头布局不可知，无法可靠解析或跳过，按"无标签"处理（`parse_id3v2` 与
    // `id3v2_size` 因此对未知版本给出一致结果）。
    return None
  }
  let flags = data[5].to_int()
  let body_size = id3_syncsafe32(data, 6)
  // bit4（footer present）只在 v2.4 有定义。
  let has_footer = version == 4 && (flags & 0x10) != 0
  let total = 10 + body_size + (if has_footer { 10 } else { 0 })
  if total > len {
    raise AudioError::Truncated(offset=0, needed=total, available=len)
  }
  Some({ version, total, unsync: (flags & 0x80) != 0, has_footer })
}

///|
/// syncsafe 整数：每字节只用低 7 位，`b0<<21 | b1<<14 | b2<<7 | b3`。
/// 最多 28 位，`Int`（32 位有符号）足够。
fn id3_syncsafe32(data : Bytes, offset : Int) -> Int {
  ((data[offset].to_int() & 0x7F) << 21) |
  ((data[offset + 1].to_int() & 0x7F) << 14) |
  ((data[offset + 2].to_int() & 0x7F) << 7) |
  (data[offset + 3].to_int() & 0x7F)
}

///|
/// 普通大端 uint32（v2.3 的帧 size 与扩展头 size）。
fn id3_read_u32_be(data : Bytes, offset : Int) -> Int {
  (data[offset].to_int() << 24) |
  (data[offset + 1].to_int() << 16) |
  (data[offset + 2].to_int() << 8) |
  data[offset + 3].to_int()
}

///|
/// 普通大端 uint24（v2.2 的帧 size）。
fn id3_read_u24_be(data : Bytes, offset : Int) -> Int {
  (data[offset].to_int() << 16) |
  (data[offset + 1].to_int() << 8) |
  data[offset + 2].to_int()
}

///|
/// 判断区间内是否存在 `0xFF 0x00`；`unsync` 的快路径判据。
fn id3_contains_ff00(data : Bytes) -> Bool {
  let len = data.length()
  let mut i = 0
  while i + 1 < len {
    if data[i].to_int() == 0xFF && data[i + 1].to_int() == 0x00 {
      return true
    }
    i += 1
  }
  false
}

///|
/// 跳过扩展头，返回帧区起始偏移。
///
/// v2.3：4 字节 size（**非** syncsafe，语义是"不含这 4 字节"的长度），
/// 结构为 flags(2) + padding size(4) [+ CRC(4)]，最小合法值 6。
/// v2.4：4 字节 size（syncsafe，语义是"整块扩展头含 size 字段"的长度），
/// 结构为 size(4) + flag bytes(1) + flags(1) [+ CRC 数据]，最小合法值 6。
/// v2.2 没有扩展头。
///
/// 只跳过、不解释内容（CRC 与 padding size 都不使用）。size 明显不可信时
/// 不跳过，直接按帧区解析，避免把整个标签体误当成扩展头吃掉。
fn id3_skip_extended_header(region : Bytes, offset : Int, version : Int) -> Int {
  if version == 3 {
    if offset + 4 > region.length() {
      return offset
    }
    let ext_size = id3_read_u32_be(region, offset)
    if ext_size < 6 || offset + 4 + ext_size > region.length() {
      return offset
    }
    offset + 4 + ext_size
  } else if version == 4 {
    if offset + 4 > region.length() {
      return offset
    }
    let ext_size = id3_syncsafe32(region, offset)
    if ext_size < 6 || offset + ext_size > region.length() {
      return offset
    }
    offset + ext_size
  } else {
    offset
  }
}

///|
/// 一个已取出的帧。
priv struct Id3Frame {
  id : String
  body : Bytes
  /// 下一个帧头的偏移（帧头 + 帧体之后）。
  next_offset : Int
}

///|
/// 读取从 `offset` 开始的一个帧。
///
/// 返回 `None` 表示遇到 padding（全 0 的帧 ID）或帧头非法/长度不可信，
/// 调用方应停止解析。帧体声明长度超出剩余数据时抛 `Truncated`。
fn id3_next_frame(
  region : Bytes,
  offset : Int,
  version : Int,
) -> Id3Frame? raise AudioError {
  let len = region.length()
  if version == 2 {
    // v2.2：3 字节 ID + 3 字节 size（普通大端），共 6 字节帧头。
    if offset + 6 > len {
      return None
    }
    let id = id3_frame_id(region, offset, 3)
    if id.length() == 0 {
      return None
    }
    let size = id3_read_u24_be(region, offset + 3)
    if size <= 0 {
      return None
    }
    if offset + 6 + size > len {
      raise AudioError::Truncated(
        offset=offset + 6,
        needed=size,
        available=len - offset - 6,
      )
    }
    Some({
      id,
      body: id3_copy_range(region, offset + 6, size),
      next_offset: offset + 6 + size,
    })
  } else {
    // v2.3 / v2.4：4 字节 ID + 4 字节 size + 2 字节 flags，共 10 字节帧头。
    if offset + 10 > len {
      return None
    }
    let id = id3_frame_id(region, offset, 4)
    if id.length() == 0 {
      return None
    }
    let size = if version == 4 {
      // v2.4 的帧 size 是 syncsafe 整数。
      id3_syncsafe32(region, offset + 4)
    } else {
      // v2.3 的帧 size 是普通大端 uint32。
      id3_read_u32_be(region, offset + 4)
    }
    if size <= 0 {
      return None
    }
    if offset + 10 + size > len {
      raise AudioError::Truncated(
        offset=offset + 10,
        needed=size,
        available=len - offset - 10,
      )
    }
    Some({
      id,
      body: id3_copy_range(region, offset + 10, size),
      next_offset: offset + 10 + size,
    })
  }
}

///|
/// 读一个 `width` 字节的帧 ID。
///
/// 合法字符是 `A`–`Z` 与 `0`–`9`（含 v2.2 的 3 字节 ID 如 `TT2`）。
/// 遇到 `\0`（padding）或非法字符时返回空串，调用方据此停止。
fn id3_frame_id(region : Bytes, offset : Int, width : Int) -> String {
  let chars : Array[Char] = []
  for i in 0..<width {
    let b = region[offset + i].to_int()
    let ok = (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39)
    if !ok {
      return ""
    }
    chars.push(b.unsafe_to_char())
  }
  String::from_array(chars)
}

///|
/// 拷贝区间字节，返回独立的 `Bytes`
/// （用 `Bytes::makei` 逐字节取值，不依赖任何切片别名/共享语义）。
fn id3_copy_range(data : Bytes, offset : Int, length : Int) -> Bytes {
  if length <= 0 || offset < 0 || offset + length > data.length() {
    return b""
  }
  Bytes::makei(length, i => data[offset + i])
}

///|
/// 把帧体分派到对应的字段上。
fn id3_apply_frame(fields : Id3Fields, id : String, body : Bytes) -> Unit {
  if body.length() == 0 {
    return
  }
  match id {
    "TIT2" | "TT2" => fields.title = id3_text_frame(body)
    "TPE1" | "TP1" => fields.artist = id3_text_frame(body)
    "TALB" | "TAL" => fields.album = id3_text_frame(body)
    "TYER" | "TYE" => fields.year = id3_text_frame(body)
    "TDRC" => fields.year = id3_frame_year(id3_text_frame(body))
    "TRCK" | "TRK" => fields.track = id3_text_frame(body)
    "TCOM" | "TCM" => fields.composer = id3_text_frame(body)
    "TCON" | "TCO" => fields.genre = id3_frame_genre(id3_text_frame(body))
    "COMM" | "COM" =>
      // 多注释时保留第一条，避免结果依赖解析顺序之外的东西。
      if fields.comment is None {
        fields.comment = id3_comment_frame(body)
      }
    "APIC" | "PIC" =>
      match id3_picture_frame(body) {
        Some(pic) => id3_fields_push_picture(fields, pic)
        None => ()
      }
    _ => ()
  }
}

///|
/// 解码文本帧：首字节是编码，其余是文本。
fn id3_text_frame(body : Bytes) -> String? {
  if body.length() == 0 {
    return None
  }
  let enc = match id3_encoding_of(body[0].to_int()) {
    None => return None
    Some(e) => e
  }
  let text = id3_decode_text(body, 1, body.length(), enc)
  if text.length() == 0 {
    None
  } else {
    Some(text)
  }
}

///|
/// `TDRC` 是 ISO 8601 时间戳（如 `2011-05-03T12:00`），年份取前 4 个字符。
fn id3_frame_year(text : String?) -> String? {
  match text {
    None => None
    Some(t) => {
      let trimmed = id3_trim_string(t)
      if trimmed.length() == 0 {
        None
      } else if trimmed.length() <= 4 {
        Some(trimmed)
      } else {
        Some(trimmed[:4].to_owned())
      }
    }
  }
}

///|
/// `TCON` 归一化：
/// - `"(17)"` → `"17"`
/// - `"(17)Rock"` → `"17"`
/// - 其他（`"Rock"`、`"17"` 等）去首尾空白后原样返回。
///
/// 按题目约定不做 ID3v1 的 148 项流派名表映射。
fn id3_frame_genre(text : String?) -> String? {
  match text {
    None => None
    Some(t) => {
      let trimmed = id3_trim_string(t)
      if trimmed.length() == 0 {
        return None
      }
      // 括号内的数字（只看第一个括号对）。
      let close = trimmed.find(")")
      if close is Some(c) && c > 1 && trimmed[:1].to_owned() == "(" {
        let inner = trimmed[1:c].to_owned()
        if id3_all_ascii_digits(inner) {
          return Some(inner)
        }
      }
      // 括号形式但内容非数字（如 "(RX)"）时退回原文。
      Some(trimmed)
    }
  }
}

///|
/// 解析 `COMM` / `COM`：
/// 编码(1) + 语言(3, Latin-1) + 短描述(按编码宽度以 0x00 结尾) + 正文。
///
/// 描述非空时返回 `"描述 正文"`，否则只返回正文。
fn id3_comment_frame(body : Bytes) -> String? {
  let len = body.length()
  if len < 4 {
    return None
  }
  let enc = match id3_encoding_of(body[0].to_int()) {
    None => return None
    Some(e) => e
  }
  // 语言字段永远是 3 字节 Latin-1，与编码字节无关。
  let desc_start = 4
  let term = id3_find_terminator(body, desc_start, enc)
  let desc_end = match term {
    Some(t) => t
    None => len
  }
  let description = id3_decode_text(body, desc_start, desc_end, enc)
  let text_start = match term {
    Some(t) => t + id3_terminator_width(enc)
    None => desc_end
  }
  let text = id3_decode_text(body, text_start, len, enc)
  if description.length() == 0 {
    Some(text)
  } else if text.length() == 0 {
    Some(description)
  } else {
    Some("\{description} \{text}")
  }
}

///|
/// 解析 `APIC` / `PIC`：
/// 编码(1) + MIME 类型(以 0x00 结尾, Latin-1) + 图片类型(1)
/// + 描述(按编码宽度以 0x00 结尾) + 图片数据。
///
/// MIME 或描述缺失、图片数据为空时返回 `None`。
fn id3_picture_frame(body : Bytes) -> Bytes? {
  let len = body.length()
  if len < 4 {
    return None
  }
  let enc = match id3_encoding_of(body[0].to_int()) {
    None => return None
    Some(e) => e
  }
  // MIME 类型（v2.2 的 PIC 帧这里是 3 字符图片格式，处理方式相同）。
  let mime_end = match id3_find_terminator(body, 1, Id3Keep) {
    Some(t) => t
    None => return None
  }
  // 图片类型字节紧随 MIME 的终止符之后（本实现不解释其取值）。
  let desc_start = mime_end + 2
  let pic_start = match id3_find_terminator(body, desc_start, enc) {
    Some(t) => t + id3_terminator_width(enc)
    None => len
  }
  if pic_start >= len {
    // 有描述但没有图片数据。
    return None
  }
  Some(id3_copy_range(body, pic_start, len - pic_start))
}

///|
/// 帧体首字节 → 编码。非法编码字节返回 `None`。
fn id3_encoding_of(byte : Int) -> Id3Encoding? {
  match byte {
    0 => Some(Id3Latin1)
    1 => Some(Id3Utf16Bom)
    2 => Some(Id3Utf16Be)
    3 => Some(Id3Utf8)
    _ => None
  }
}

///|
/// 该编码的正文终止符宽度：单字节编码用 1 个 0x00，UTF-16 用 2 个。
fn id3_terminator_width(enc : Id3Encoding) -> Int {
  match enc {
    Id3Latin1 | Id3Utf8 | Id3Keep => 1
    Id3Utf16Bom | Id3Utf16Be => 2
  }
}

///|
/// 在 `[offset, data.length())` 里找正文终止符，返回其起始下标（不含终止符本身）。
///
/// 单字节编码找 `0x00`；UTF-16 找 `0x00 0x00`。
fn id3_find_terminator(data : Bytes, offset : Int, enc : Id3Encoding) -> Int? {
  let len = data.length()
  let width = id3_terminator_width(enc)
  let mut i = offset
  while i + width <= len {
    if width == 1 {
      if data[i].to_int() == 0x00 {
        return Some(i)
      }
    } else if data[i].to_int() == 0x00 && data[i + 1].to_int() == 0x00 {
      return Some(i)
    }
    i += 1
  }
  None
}

///|
/// 按编码解码 `data` 的 `[start, end)` 区间，并去掉尾部 NUL。
///
/// 区间非法或解码失败时返回空串（畸形帧按"无内容"处理，不抛错）。
fn id3_decode_text(data : Bytes, start : Int, end : Int, enc : Id3Encoding) -> String {
  let len = data.length()
  if start < 0 || end > len || start >= end {
    return ""
  }
  let raw = match enc {
    Id3Latin1 | Id3Keep => id3_decode_latin1(data, start, end)
    Id3Utf8 => id3_decode_utf8(data, start, end)
    Id3Utf16Bom => id3_decode_utf16(data, start, end, true)
    Id3Utf16Be => id3_decode_utf16(data, start, end, false)
  }
  id3_strip_trailing_nuls(raw)
}

///|
/// Latin-1（ISO-8859-1）：每个字节直接映射到 U+0000–U+00FF。
fn id3_decode_latin1(data : Bytes, start : Int, end : Int) -> String {
  let chars : Array[Char] = []
  let mut i = start
  while i < end {
    chars.push(data[i].to_int().unsafe_to_char())
    i += 1
  }
  id3_chars_to_string(chars)
}

///|
/// UTF-8 解码。校验续字节与过长编码；非法序列返回空串（放弃整个字段）。
fn id3_decode_utf8(data : Bytes, start : Int, end : Int) -> String {
  let chars : Array[Char] = []
  let mut i = start
  while i < end {
    let b0 = data[i].to_int()
    if b0 < 0x80 {
      chars.push(b0.unsafe_to_char())
      i += 1
    } else if b0 >= 0xC2 && b0 <= 0xDF {
      // 2 字节：U+0080..U+07FF（0xC0/0xC1 必为过长编码，已排除）。
      if i + 1 >= end || !id3_is_continuation(data[i + 1].to_int()) {
        return ""
      }
      let cp = ((b0 & 0x1F) << 6) | (data[i + 1].to_int() & 0x3F)
      chars.push(cp.unsafe_to_char())
      i += 2
    } else if b0 >= 0xE0 && b0 <= 0xEF {
      // 3 字节：U+0800..U+FFFF，排除过长编码与代理区。
      if i + 2 >= end ||
        !id3_is_continuation(data[i + 1].to_int()) ||
        !id3_is_continuation(data[i + 2].to_int()) {
        return ""
      }
      let cp = ((b0 & 0x0F) << 12) |
        ((data[i + 1].to_int() & 0x3F) << 6) |
        (data[i + 2].to_int() & 0x3F)
      if cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF) {
        return ""
      }
      chars.push(cp.unsafe_to_char())
      i += 3
    } else if b0 >= 0xF0 && b0 <= 0xF4 {
      // 4 字节：U+10000..U+10FFFF（码点一律用十进制字面量构造 Char，
      // 不写 `\u{...}` 转义以免依赖转义语法细节）。
      if i + 3 >= end ||
        !id3_is_continuation(data[i + 1].to_int()) ||
        !id3_is_continuation(data[i + 2].to_int()) ||
        !id3_is_continuation(data[i + 3].to_int()) {
        return ""
      }
      let cp = ((b0 & 0x07) << 18) |
        ((data[i + 1].to_int() & 0x3F) << 12) |
        ((data[i + 2].to_int() & 0x3F) << 6) |
        (data[i + 3].to_int() & 0x3F)
      if cp < 0x10000 || cp > 0x10FFFF {
        return ""
      }
      chars.push(cp.unsafe_to_char())
      i += 4
    } else {
      // 0x80..0xC1、0xF5..0xFF 都不是合法的 UTF-8 起始字节。
      return ""
    }
  }
  id3_chars_to_string(chars)
}

///|
/// UTF-8 续字节判定：`10xxxxxx`。
fn id3_is_continuation(byte : Int) -> Bool {
  (byte & 0xC0) == 0x80
}

///|
/// UTF-16 解码。
///
/// `with_bom = true` 时，帧体开头的 `FF FE` / `FE FF` 决定字节序（无 BOM 时按
/// 小端处理，与常见实现一致）；`with_bom = false` 时按大端（编码 2 = UTF-16BE）。
/// 代理对（U+10000 以上）会被正确合成，落单的代理码元用 U+FFFD 占位。
fn id3_decode_utf16(
  data : Bytes,
  start : Int,
  end : Int,
  with_bom : Bool,
) -> String {
  let mut i = start
  let mut big_endian = !with_bom
  if with_bom {
    if end - i < 2 {
      return ""
    }
    let b0 = data[i].to_int()
    let b1 = data[i + 1].to_int()
    if b0 == 0xFF && b1 == 0xFE {
      big_endian = false
      i += 2
    } else if b0 == 0xFE && b1 == 0xFF {
      big_endian = true
      i += 2
    }
    // 没有 BOM：保持小端（默认值）。
  }
  // 先一次性收成 UTF-16 码元，再处理代理对，避免边解码边回退。
  let units : Array[Int] = []
  while i + 2 <= end {
    let u = if big_endian {
      (data[i].to_int() << 8) | data[i + 1].to_int()
    } else {
      (data[i + 1].to_int() << 8) | data[i].to_int()
    }
    units.push(u)
    i += 2
  }
  let chars : Array[Char] = []
  let mut k = 0
  while k < units.length() {
    let u = units[k]
    if u >= 0xD800 && u <= 0xDBFF && k + 1 < units.length() {
      let low = units[k + 1]
      if low >= 0xDC00 && low <= 0xDFFF {
        let cp = 0x10000 + (u - 0xD800) * 0x400 + (low - 0xDC00)
        chars.push(cp.unsafe_to_char())
        k += 2
        continue
      }
    }
    if u >= 0xD800 && u <= 0xDFFF {
      // 落单的代理码元：用替换字符占位，不抛错。
      chars.push((65533).unsafe_to_char())
    } else {
      chars.push(u.unsafe_to_char())
    }
    k += 1
  }
  id3_chars_to_string(chars)
}

///|
/// `Array[Char]` → `String`。
///
/// 用 `String::from_array`（而不是先拼 UTF-8 字节再 `Bytes::to_unchecked_string()`）：
/// 后者在 wasm 后端上对"动态构造的 Bytes"会按 UTF-16 码元解释，得到字节序错乱的字符串
/// （实测 `b"AB".to_unchecked_string()` 返回 `"䉁"`）。`String::from_array` 没有这个问题。
fn id3_chars_to_string(chars : Array[Char]) -> String {
  String::from_array(chars)
}

///|
/// 去掉字符串尾部的 NUL（ID3 文本帧常见尾部填充）。
fn id3_strip_trailing_nuls(text : String) -> String {
  let mut end = text.length()
  while end > 0 && text.unsafe_get(end - 1).to_int() == 0 {
    end -= 1
  }
  if end == text.length() {
    text
  } else {
    text[:end].to_owned()
  }
}

///|
/// 去掉字符串首尾空白（空格、制表、回车、换行、NUL）。
fn id3_trim_string(text : String) -> String {
  let mut start = 0
  let mut end = text.length()
  while start < end && id3_is_blank(text.unsafe_get(start).to_int()) {
    start += 1
  }
  while end > start && id3_is_blank(text.unsafe_get(end - 1).to_int()) {
    end -= 1
  }
  text[start:end].to_owned()
}

///|
/// 是否空白或 NUL。
fn id3_is_blank(code : Int) -> Bool {
  code == 0x00 || code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D
}

///|
/// 是否全部是 ASCII 数字（`"17"` 为真，`"17a"`、`""` 为假）。
fn id3_all_ascii_digits(text : String) -> Bool {
  if text.length() == 0 {
    return false
  }
  for c in text {
    let code = c.to_int()
    if code < 0x30 || code > 0x39 {
      return false
    }
  }
  true
}
