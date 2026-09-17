// moonbit-music —— Ogg 容器解析器（page / packet / CRC32）
//
// 归属：本文件由 Ogg 负责，其它实现文件不得引用本文件的私有成员。
// 契约见 CONTRACT.md 的 G 段：parse_page / pages / packets_of / ogg_crc32。
// 参考 RFC 3533（Ogg 封装格式）。只依赖 moonbitlang/core，不做任何 FFI / I/O。
//
// CRC32 归属说明：公开的 `ogg_crc32(Bytes) -> Int` 与 `ogg_crc32_update(Int, Bytes) -> Int`
// 由**同包的 checksum.mbt** 提供（poly 0x04C11DB7、非反射、初值 0、不取反，与本文件一致）。
// 同一个包内不能有两个同名顶层函数，因此本文件不再定义 `ogg_crc32`；这里只保留私有的
// `ogg_crc32_range` / `ogg_page_crc` 做 page 级校验（按切片喂状态机，免去整页拷贝）。
// 两条路径的一致性由 ogg_test.mbt 里独立推导的校验向量钉住。

// ---------------------------------------------------------------------------
// 公共类型
// ---------------------------------------------------------------------------

///|
/// 一个 Ogg page（RFC 3533 §6）。
///
/// 字段都按文件中的原始值给出：
/// - `version` 必须为 0；其它值在 `parse_page` 里直接抛 `Unsupported`。
/// - `header_type` 是位掩码，用 `ogg_page_is_continued` / `ogg_page_is_bos` /
///   `ogg_page_is_eos` 读取，不要自己写位运算。
/// - `granule_position` 是**有符号** 64 位小端。文件里的「无 granule」哨兵
///   （8 个 0xFF）按有符号解释就是 `-1L`，见 `ogg_granule_is_none`。
/// - `serial` / `sequence` / `checksum` 是 32 位小端**无符号**，用 `Int` 承载其位模式：
///   文件里最高位为 1 时，读出来的 `Int` 是负数。
/// - `segments` 是 lacing values（每项 0..255），`body` 的长度等于它们之和。
pub(all) struct OggPage {
  version : Int
  header_type : Int
  granule_position : Int64
  serial : Int
  sequence : Int
  checksum : Int
  segments : Array[Int] // lacing values
  body : Bytes
} derive(@debug.Debug)

///|
/// 一条 Ogg 逻辑流承载的编码类型（由 BOS page 的第一个 packet 判定）。
pub(all) enum OggCodec {
  Vorbis
  Opus
  Theora
  Flac
  Speex
  Unknown
} derive(Eq, @debug.Debug)

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

///|
/// Ogg page 固定头长度：capture pattern(4) + version(1) + header_type(1) +
/// granule(8) + serial(4) + sequence(4) + crc(4) + page_segments(1) = 27。
let ogg_fixed_header_size : Int = 27

///|
/// header_type 位 0：本页第一个 packet 是上一页未完 packet 的延续。
let ogg_header_continued : Int = 0x01

///|
/// header_type 位 1：beginning of stream。
let ogg_header_bos : Int = 0x02

///|
/// header_type 位 2：end of stream。
let ogg_header_eos : Int = 0x04

///|
/// 4 个 0 字节：校验 page 时 CRC 字段本身按 0 参与运算，等价于在状态机里喂 4 个 0。
let ogg_crc_zero4 : Bytes = b"\x00\x00\x00\x00"

// ---------------------------------------------------------------------------
// CRC32
// ---------------------------------------------------------------------------

///|
/// Ogg CRC32 查表。
///
/// `ogg_crc_table[i]` = 把 `i` 放在状态机最高字节、初值 0、跑 8 轮之后的结果，
/// 也就是 crc = i << 24 后反复 `(crc << 1) ^ (crc < 0 ? 0x04C11DB7 : 0)`。
let ogg_crc_table : Array[Int] = ogg_build_crc_table()

///|
/// 生成 256 项 MSB-first（不反射）CRC 表。
fn ogg_build_crc_table() -> Array[Int] {
  let table : Array[Int] = Array::make(256, 0)
  for i = 0; i < 256; i = i + 1 {
    let mut crc = i << 24
    for k = 0; k < 8; k = k + 1 {
      // Int 是 32 位有符号，`crc < 0` 就是「最高位为 1」，比写 0x80000000 字面量安全。
      if crc < 0 {
        crc = (crc << 1) ^ 0x04C11DB7
      } else {
        crc = crc << 1
      }
    }
    table[i] = crc
  }
  table
}

///|
/// 把 `data[start:end)` 喂进 CRC 状态机，返回新的状态。
///
/// 表驱动的 MSB-first 形式：`crc = (crc << 8) ^ table[((crc >> 24) & 0xFF) ^ byte]`。
/// 注意 `crc >> 24` 是**算术**右移（Int 有符号，crc 为负时高位补 1），
/// 必须用 `& 0xFF` 掩码修正成逻辑右移的结果——这是本文件最容易写错的一处。
fn ogg_crc32_range(crc : Int, data : Bytes, start : Int, end : Int) -> Int {
  let mut c = crc
  for i = start; i < end; i = i + 1 {
    c = (c << 8) ^ ogg_crc_table[((c >> 24) & 0xFF) ^ data[i].to_int()]
  }
  c
}

///|
/// 计算 `data` 中从 `offset` 开始的这个 page 的 CRC。
///
/// 范围是「header 前 22 字节 + 4 个 0 字节 + header 第 26 字节 + segment table + body」，
/// 其中 4 个 0 字节顶替 CRC 字段本身（RFC 3533 §6：计算时 CRC 字段置 0）。
/// 等价于对「把 CRC 字段清零后的整页」调用公开的 `ogg_crc32`；分段喂状态机可以省掉
/// 每个 page 一次整页拷贝。
fn ogg_page_crc(
  data : Bytes,
  offset : Int,
  segment_count : Int,
  body_len : Int,
) -> Int {
  let mut crc = ogg_crc32_range(0, data, offset, offset + 22)
  crc = ogg_crc32_range(crc, ogg_crc_zero4, 0, 4)
  crc = ogg_crc32_range(
    crc,
    data,
    offset + 26,
    offset + ogg_fixed_header_size + segment_count + body_len,
  )
  crc
}

// ---------------------------------------------------------------------------
// 私有小工具
// ---------------------------------------------------------------------------

///|
/// 越界检查：从 `offset` 起需要 `needed` 个字节。
///
/// 不满足时抛 `Truncated(offset=offset, needed=needed, available=data.length()-offset)`，
/// 语义固定为「相对 offset 还需要 needed 字节，但只剩 available 字节」。
/// 用 `needed > length - offset` 而不是 `offset + needed > length` 是为了避开 Int 溢出。
fn ogg_require(
  data : Bytes,
  offset : Int,
  needed : Int,
) -> Unit raise AudioError {
  if offset < 0 || offset > data.length() || needed > data.length() - offset {
    let available = if offset < 0 || offset > data.length() {
      0
    } else {
      data.length() - offset
    }
    raise AudioError::Truncated(offset~, needed~, available~)
  }
}

///|
/// 读 4 字节小端**无符号**，用 `Int` 承载 32 位位模式（最高位为 1 时结果为负）。
/// 调用前必须已用 `ogg_require` 保证 `offset + 4` 在界内。
fn ogg_u32_le(data : Bytes, offset : Int) -> Int {
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

///|
/// 读 8 字节小端**有符号** 64 位。
///
/// 逐字节或进 `Int64`，全 1 位自然得到 `-1L`（即 Ogg 的「无 granule」哨兵）。
/// 调用前必须已用 `ogg_require` 保证 `offset + 8` 在界内。
fn ogg_i64_le(data : Bytes, offset : Int) -> Int64 {
  let mut value : Int64 = 0L
  for i = 0; i < 8; i = i + 1 {
    value = value | (data[offset + i].to_int().to_int64() << (8 * i))
  }
  value
}

///|
/// `data[start:start+prefix.length()]` 是否逐字节等于 `prefix`。
/// 自己写而不用 `Bytes::has_prefix`，避免依赖 BytesView 的隐式转换。
fn ogg_has_prefix_at(data : Bytes, start : Int, prefix : Bytes) -> Bool {
  if start < 0 || start + prefix.length() > data.length() {
    return false
  }
  for i = 0; i < prefix.length(); i = i + 1 {
    if data[start + i] != prefix[i] {
      return false
    }
  }
  true
}

///|
/// 把 `data[start:end)` 逐字节追加到 `acc`。
fn ogg_append_range(
  acc : Array[Byte],
  data : Bytes,
  start : Int,
  end : Int,
) -> Unit {
  for i = start; i < end; i = i + 1 {
    acc.push(data[i])
  }
}

// ---------------------------------------------------------------------------
// page 解析
// ---------------------------------------------------------------------------

///|
/// 从头解析一个 Ogg page（含 CRC 校验）。
///
/// 返回 `(page, next_offset)`，`next_offset` 是紧跟在 body 之后、下一页的起始下标。
///
/// 校验顺序（先结构、后校验和）：
/// 1. 不足 4 字节 → `Truncated`；capture pattern 不是 `"OggS"` → `InvalidMagic`。
/// 2. 不足 27 字节固定头 → `Truncated`。
/// 3. `version != 0` → `Unsupported`（**先于** CRC 校验）。
/// 4. segment table / body 越界 → `Truncated`。
/// 5. CRC 不匹配 → `ChecksumMismatch(expected=文件里的 checksum, actual=重算值)`。
pub fn parse_page(
  data : Bytes,
  offset : Int,
) -> (OggPage, Int) raise AudioError {
  ogg_require(data, offset, 4)
  if data[offset] != b'O' ||
    data[offset + 1] != b'g' ||
    data[offset + 2] != b'g' ||
    data[offset + 3] != b'S' {
    raise AudioError::InvalidMagic(
      "Ogg capture pattern \"OggS\" 缺失（offset=\{offset}）",
    )
  }
  ogg_require(data, offset, ogg_fixed_header_size)
  let version = data[offset + 4].to_int()
  if version != 0 {
    raise AudioError::Unsupported(
      "Ogg page version=\{version}，RFC 3533 只定义 version=0",
    )
  }
  let header_type = data[offset + 5].to_int()
  let granule_position = ogg_i64_le(data, offset + 6)
  let serial = ogg_u32_le(data, offset + 14)
  let sequence = ogg_u32_le(data, offset + 18)
  let checksum = ogg_u32_le(data, offset + 22)
  let segment_count = data[offset + 26].to_int()
  ogg_require(data, offset + ogg_fixed_header_size, segment_count)
  let segments : Array[Int] = []
  let mut body_len = 0
  for i = 0; i < segment_count; i = i + 1 {
    let lacing = data[offset + ogg_fixed_header_size + i].to_int()
    segments.push(lacing)
    body_len = body_len + lacing
  }
  let body_start = offset + ogg_fixed_header_size + segment_count
  ogg_require(data, body_start, body_len)
  let actual = ogg_page_crc(data, offset, segment_count, body_len)
  if actual != checksum {
    raise AudioError::ChecksumMismatch(expected=checksum, actual~)
  }
  let body = data.view(start=body_start, end=body_start + body_len).to_owned()
  let page : OggPage = {
    version,
    header_type,
    granule_position,
    serial,
    sequence,
    checksum,
    segments,
    body,
  }
  (page, body_start + body_len)
}

///|
/// 依次产出所有 page：从下标 0 一直解析到输入末尾。
///
/// 严格要求输入正好由完整 page 构成：尾部残留不足以构成一个 page 时抛 `Truncated`
/// （不会静默丢掉尾字节）。需要容忍尾部垃圾的调用方请自行截断输入。
pub fn pages(data : Bytes) -> Array[OggPage] raise AudioError {
  let out : Array[OggPage] = []
  let mut offset = 0
  while offset < data.length() {
    let (page, next) = parse_page(data, offset)
    out.push(page)
    offset = next
  }
  out
}

// ---------------------------------------------------------------------------
// page 上的小查询（给 Vorbis 等上层用，不属于契约的四个函数）
// ---------------------------------------------------------------------------

///|
/// 本页第一个 packet 是否为上一页未完 packet 的延续（header_type 位 0）。
pub fn ogg_page_is_continued(page : OggPage) -> Bool {
  (page.header_type & ogg_header_continued) != 0
}

///|
/// 本页是否为 logical bitstream 的第一页（header_type 位 1）。
pub fn ogg_page_is_bos(page : OggPage) -> Bool {
  (page.header_type & ogg_header_bos) != 0
}

///|
/// 本页是否为 logical bitstream 的最后一页（header_type 位 2）。
pub fn ogg_page_is_eos(page : OggPage) -> Bool {
  (page.header_type & ogg_header_eos) != 0
}

///|
/// 本页是否带「无 granule position」哨兵（文件里 8 个 0xFF，即 `-1L`）。
///
/// 出现在 header packet 页、以及最后一页的 granule 未知时。
pub fn ogg_granule_is_none(page : OggPage) -> Bool {
  page.granule_position == -1L
}

///|
/// 本页 body 里第一个 packet 的长度（字节）。
///
/// 算法：累加 lacing value 直到遇到 < 255 的那一个（它标志 packet 结束）；
/// 若整页都是 255，则返回整页 body 长度（packet 未完，长度只是本页的部分）。
pub fn ogg_first_packet_len(page : OggPage) -> Int {
  let mut len = 0
  let mut i = 0
  let mut finished = false
  while i < page.segments.length() && !finished {
    let lacing = page.segments[i]
    len = len + lacing
    if lacing < 255 {
      finished = true
    }
    i = i + 1
  }
  if len > page.body.length() {
    len = page.body.length()
  }
  len
}

// ---------------------------------------------------------------------------
// packet 重组
// ---------------------------------------------------------------------------

///|
/// 把 page 按 serial 分组，并把 lacing 拼装成完整 packet（处理跨页续包）。
///
/// 返回顺序：组按 serial **首次出现**的顺序排列，组内 packet 按出现顺序排列。
/// 同一 serial 的多个 logical bitstream 互不干扰（Ogg 支持多路复用）。
///
/// 本实现明确选择的语义：
/// - **跨页续包**：一页最后一个 lacing value 为 255 时该 packet 未完，交给同 serial 的
///   下一页；下一页 header_type 的 continuation 位必须为 1。
/// - **流结束时仍未完成的 packet 直接丢弃**（不产出半个 packet）。
/// - **续包但上一页缺失**（下一页带 continuation 位而我们没有挂起的 packet）时，
///   跳过该页开头属于丢失 packet 的段，从第一个完整的 packet 开始产出。
/// - **有挂起 packet 但下一页没有 continuation 位**：视为数据流断裂，丢弃残缺 packet。
/// - 手工构造的 page 若 segment 之和大于 body 长度（正常解析不可能出现），
///   该页在越界处停止处理，已完整收尾的 packet 仍然保留；本函数不抛错。
pub fn packets_of(pages : Array[OggPage]) -> Array[(Int, Array[Bytes])] {
  // 每个 serial 一组，四个数组按下标对齐。
  let serials : Array[Int] = []
  let packets : Array[Array[Bytes]] = []
  // 正在拼接中的、尚未收尾的 packet 字节。
  let partials : Array[Array[Byte]] = []
  // 该组是否有未收尾的 packet（即上一页以 255 结尾）。
  let pendings : Array[Bool] = []
  for page in pages {
    let mut index = -1
    for i = 0; i < serials.length(); i = i + 1 {
      if serials[i] == page.serial {
        index = i
      }
    }
    if index < 0 {
      index = serials.length()
      serials.push(page.serial)
      packets.push([])
      partials.push([])
      pendings.push(false)
    }
    let segments = page.segments
    let body = page.body
    let body_len = body.length()
    let mut seg_index = 0
    let mut body_pos = 0
    // 手工构造的畸形 page 可能 segment 之和 > body 长度，越界就停止本页。
    let mut overrun = false
    if pendings[index] && ogg_page_is_continued(page) {
      // 续包：把开头的 255 段接着拼进挂起的 packet。
      while seg_index < segments.length() && segments[seg_index] == 255 {
        if body_pos + 255 > body_len {
          overrun = true
          break
        }
        ogg_append_range(partials[index], body, body_pos, body_pos + 255)
        body_pos = body_pos + 255
        seg_index = seg_index + 1
      }
      if !overrun && seg_index < segments.length() {
        let lacing = segments[seg_index]
        if body_pos + lacing > body_len {
          overrun = true
        } else {
          ogg_append_range(partials[index], body, body_pos, body_pos + lacing)
          body_pos = body_pos + lacing
          seg_index = seg_index + 1
          packets[index].push(Bytes::from_array(partials[index]))
          partials[index].clear()
          pendings[index] = false
        }
      }
    } else if !pendings[index] && ogg_page_is_continued(page) {
      // 从流中间接入：丢掉开头属于丢失 packet 的段。
      while seg_index < segments.length() && segments[seg_index] == 255 {
        if body_pos + 255 > body_len {
          overrun = true
          break
        }
        body_pos = body_pos + 255
        seg_index = seg_index + 1
      }
      if !overrun && seg_index < segments.length() {
        let lacing = segments[seg_index]
        if body_pos + lacing > body_len {
          overrun = true
        } else {
          body_pos = body_pos + lacing
          seg_index = seg_index + 1
        }
      }
    } else if pendings[index] && !ogg_page_is_continued(page) {
      // 数据流断裂：残缺 packet 丢弃。
      partials[index].clear()
      pendings[index] = false
    }
    // 逐段拼装本页剩余的 packet。lacing < 255 收尾；== 255 表示还要接着拼。
    while !overrun && seg_index < segments.length() {
      let lacing = segments[seg_index]
      if body_pos + lacing > body_len {
        overrun = true
      } else {
        ogg_append_range(partials[index], body, body_pos, body_pos + lacing)
        body_pos = body_pos + lacing
        seg_index = seg_index + 1
        if lacing < 255 {
          packets[index].push(Bytes::from_array(partials[index]))
          partials[index].clear()
          pendings[index] = false
        } else {
          pendings[index] = true
        }
      }
    }
  }
  let out : Array[(Int, Array[Bytes])] = []
  for i = 0; i < serials.length(); i = i + 1 {
    out.push((serials[i], packets[i]))
  }
  out
}

// ---------------------------------------------------------------------------
// codec 识别（辅助，不属于契约）
// ---------------------------------------------------------------------------

///|
/// 按 packet 开头的 codec 标识判断编码类型（BOS page 的第一个 packet 就是它）。
///
/// 识别：`"\x01vorbis"` → Vorbis，`"OpusHead"` → Opus，`"\x80theora"` → Theora，
/// `"fLaC"` → FLAC-in-Ogg，`"Speex   "`（尾部 3 个空格）→ Speex，其余 Unknown。
pub fn ogg_codec_of_packet(packet : Bytes) -> OggCodec {
  if ogg_has_prefix_at(packet, 0, b"\x01vorbis") {
    Vorbis
  } else if ogg_has_prefix_at(packet, 0, b"OpusHead") {
    Opus
  } else if ogg_has_prefix_at(packet, 0, b"\x80theora") {
    Theora
  } else if ogg_has_prefix_at(packet, 0, b"fLaC") {
    Flac
  } else if ogg_has_prefix_at(packet, 0, b"Speex   ") {
    Speex
  } else {
    Unknown
  }
}

///|
/// 解析 `data` 的第一个 page，并用它 body 里的第一个 packet 判断编码类型。
///
/// 供上层（例如 Vorbis 解码器、格式探测）使用；page 本身非法时照常抛 `AudioError`。
pub fn ogg_codec_of_stream(data : Bytes) -> OggCodec raise AudioError {
  let (page, _) = parse_page(data, 0)
  let len = ogg_first_packet_len(page)
  ogg_codec_of_packet(page.body.view(start=0, end=len).to_owned())
}
