// moonbit-music —— 库入口层：按魔数把一段内存字节分派给对应的解码器。
//
// 公开 API：`decode` / `info` / `tags` / `format_name`。
// 本文件不实现任何具体格式，只做三件事：识别容器 → 分派 → 把标签整理成统一形状。
//
// 依赖的全是 CONTRACT.md 里冻结的签名（写这个文件时它们都已落地）：
//   wav.mbt    → decode_wav / wav_info
//   flac.mbt   → decode_flac / flac_info / parse_flac_metadata
//   mp3.mbt    → decode_mp3 / mp3_info
//   id3.mbt    → parse_id3v2
//   ogg.mbt    → pages / packets_of
//   vorbis.mbt → parse_vorbis_ident / parse_vorbis_comment / decode_vorbis
//
// 已知状态：`vorbis.mbt` 的 `decode_vorbis` 目前校验完 setup header 就抛
// `Unsupported`（音频包解码与合成尚未实现），Ogg/Vorbis 的 `decode` 会如实把它抛出来；
// 等它落地后本文件一行都不用改。
//
// 本文件里所有内部辅助函数都带 `ma_` 前缀，私有枚举带 `Ma` 前缀：整个库是单包结构，
// 各文件共享同一个顶层命名空间，不加前缀会和 wav/flac/mp3/ogg/vorbis 的内部函数撞名。

// ---------------------------------------------------------------------------
// 公开 API
// ---------------------------------------------------------------------------

///|
/// `AudioFormatHint` 的人类可读格式名（小写，与常见文件扩展名一致），
/// 供 CLI 输出与错误信息使用。
///
/// 注意不要和 `AudioFormatHint` 自带的 `Show` 混用：`Show` 给的是类型名
/// （`"Wav"`），这里给的是给人看的格式名（`"wav"`）。
pub fn format_name(hint : AudioFormatHint) -> String {
  match hint {
    AudioFormatHint::Wav => "wav"
    AudioFormatHint::Flac => "flac"
    AudioFormatHint::Ogg => "ogg"
    AudioFormatHint::Mp3 => "mp3"
    AudioFormatHint::Unknown => "unknown"
  }
}

///|
/// `format_name` 的带库名前缀别名：与其他库处在同一个命名域里时不容易重名。
pub fn moonbit_music_format_name(hint : AudioFormatHint) -> String {
  format_name(hint)
}

///|
/// 按魔数自动识别格式并解码。
///
/// * `Wav` / `Flac` / `Mp3` → `decode_wav` / `decode_flac` / `decode_mp3`
/// * `Ogg` → 先看第一个 packet 的签名，再决定容器里装的是什么编码
///   （Vorbis 走 `parse_vorbis_ident` + `decode_vorbis`；Opus 与 FLAC-in-Ogg 抛 `Unsupported`）
/// * `Unknown` → 抛 `InvalidMagic`
///
/// 各解码器不一定会填 `tags`；如果解码结果里一个标签都没有，这里会补一次
/// “只解析头部”的标签解析（FLAC metadata / ID3v2 / RIFF LIST），代价是再扫一遍头部，
/// 相比整个文件已经解完码，这点开销可以忽略。Ogg 的 comment header 在分派时顺手取到，
/// 所以不再重复扫容器。
pub fn decode(data : Bytes) -> Audio raise AudioError {
  match detect_format(data) {
    AudioFormatHint::Wav => ma_fill_tags(data, decode_wav(data))
    AudioFormatHint::Flac => ma_fill_tags(data, decode_flac(data))
    AudioFormatHint::Mp3 => ma_fill_tags(data, decode_mp3(data))
    AudioFormatHint::Ogg => ma_decode_ogg(data)
    AudioFormatHint::Unknown => raise ma_invalid_magic(data)
  }
}

///|
/// 只解析头部，不解码音频数据。
///
/// 各格式都走各自的轻量路径，不会退化成“解码完再取格式”：
/// * WAV → `wav_info`（只读 `fmt ` chunk）
/// * FLAC → `flac_info`（只读 STREAMINFO 与 metadata block）
/// * MP3 → `mp3_info`（只做帧同步并读第一个帧头）
/// * Ogg → 只取第一个 page 的 identification header
///
/// 认不出魔数时抛 `InvalidMagic`，与 `decode` 保持一致。
pub fn info(data : Bytes) -> AudioFormat raise AudioError {
  match detect_format(data) {
    AudioFormatHint::Wav => wav_info(data)
    AudioFormatHint::Flac => flac_info(data)
    AudioFormatHint::Mp3 => mp3_info(data)
    AudioFormatHint::Ogg => ma_ogg_info(data)
    AudioFormatHint::Unknown => raise ma_invalid_magic(data)
  }
}

///|
/// 只解析标签，不解码音频数据。
///
/// * FLAC → Vorbis comment（`parse_flac_metadata(...).comments`）
/// * Ogg/Vorbis → comment header（`parse_vorbis_comment`）
/// * MP3 → ID3v2（`parse_id3v2`），键名统一成 Vorbis comment 风格
/// * WAV → RIFF `LIST`/`INFO` chunk；RIFF 一般不带标签，没有就返回空数组
///
/// 键名在所有格式之间统一（`TITLE` / `ARTIST` / `ALBUM` / `DATE` / `TRACKNUMBER` /
/// `GENRE` / `COMMENT` / `COMPOSER` / `COPYRIGHT` / `ENCODER`），调用方拿标签时不用分格式。
/// 没有标签一律返回空数组，不抛错；只有魔数认不出时才抛 `InvalidMagic`。
pub fn tags(data : Bytes) -> Array[(String, String)] raise AudioError {
  match detect_format(data) {
    AudioFormatHint::Wav => ma_wav_tags(data)
    AudioFormatHint::Flac => parse_flac_metadata(data).comments
    AudioFormatHint::Mp3 => ma_id3v2_tags(data)
    AudioFormatHint::Ogg => ma_ogg_tags(data)
    AudioFormatHint::Unknown => raise ma_invalid_magic(data)
  }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

///|
/// 统一的“认不出格式”错误。带上头部若干字节，方便对着真实输入排查。
fn ma_invalid_magic(data : Bytes) -> AudioError {
  AudioError::InvalidMagic(
    "无法识别的音频格式：头部字节 \{ma_head_hex(data)} 既不是 RIFF/WAV、fLaC、OggS、ID3v2，也没有 MPEG 帧同步",
  )
}

///|
/// 一个码点 → `String`。
///
/// 这里刻意不用 `Bytes::to_unchecked_string`：在本工具链的 native 目标上，它把
/// 字节直接当成 `String` 的内部表示（UTF-16 码元）复制，`b"fmt "` 会变成 `"浦⁴"`；
/// 也不能用 `Bytes::to_string`，那个是 `Show` 实现，给出的是 `b"..."` 调试形式。
/// 逐码点用 `Int::to_char` 拼字符是实测可用的路径（`Char::from_int` 已废弃）。
fn ma_codepoint_to_string(cp : Int) -> String {
  match cp.to_char() {
    Some(c) => c.to_string()
    None => ""
  }
}

///|
/// 0..15 → 一个大写十六进制字符。
fn ma_hex_digit(v : Int) -> String {
  if v < 10 {
    ma_codepoint_to_string(48 + v)
  } else {
    ma_codepoint_to_string(55 + v)
  }
}

///|
/// 头部最多 8 字节的大写十六进制，空格分隔。空输入返回 `<空>`。
fn ma_head_hex(data : Bytes) -> String {
  let n = if data.length() < 8 { data.length() } else { 8 }
  if n == 0 {
    return "<空>"
  }
  let mut out = ""
  for i = 0; i < n; i = i + 1 {
    if i > 0 {
      out = out + " "
    }
    let b = data[i].to_int()
    out = out + ma_hex_digit((b >> 4) & 0xF) + ma_hex_digit(b & 0xF)
  }
  out
}

///|
/// 重建 `Audio` 并替换标签（`Audio` 的字段不可变，只能新建一个）。
fn ma_with_tags(audio : Audio, new_tags : Array[(String, String)]) -> Audio {
  { format: audio.format, samples: audio.samples, tags: new_tags }
}

///|
/// 构造 `AudioFormat` 的小工具，免得在 match 分支里写结构体字面量。
fn ma_format(sample_rate : Int, channels : Int, bits_per_sample : Int) -> AudioFormat {
  { sample_rate, channels, bits_per_sample }
}

///|
/// 解码器没填标签时，补一次只读头部的标签解析。
///
/// 只在 `audio.tags` 为空时执行，而且标签解析失败不影响已经成功的解码：
/// 标签拿不到是小事，不该把整个 `decode` 拖崩。
fn ma_fill_tags(data : Bytes, audio : Audio) -> Audio {
  if audio.tags.length() > 0 {
    return audio
  }
  let extra = try {
    tags(data)
  } catch {
    _ => []
  }
  if extra.length() == 0 {
    audio
  } else {
    ma_with_tags(audio, extra)
  }
}

///|
/// 按码点逐位比较前缀。只用于 ASCII 签名（`"OpusHead"` 这类），
/// 这时码点下标与字节下标一致。
///
/// 这里刻意不用 `String::to_bytes`（已被标记 deprecated，且换成
/// `@encoding/utf8.encode` 需要改 moon.pkg 的 import）。`String` 下标取出来是
/// `UInt16` 码点，和字节比之前统一转成 `Int`。
fn ma_prefix_is(data : Bytes, prefix : String) -> Bool {
  let n = prefix.length()
  if data.length() < n {
    return false
  }
  let mut i = 0
  while i < n {
    if data[i].to_int() != prefix[i].to_int() {
      return false
    }
    i += 1
  }
  true
}

///|
/// `data[offset ..< offset+4)` 是否正好是四字符标识 `text`（ASCII）。
fn ma_is_fourcc(data : Bytes, offset : Int, text : String) -> Bool {
  if text.length() != 4 || offset < 0 || offset + 4 > data.length() {
    return false
  }
  let mut i = 0
  while i < 4 {
    if data[offset + i].to_int() != text[i].to_int() {
      return false
    }
    i += 1
  }
  true
}

///|
/// 读四个字节并拼成一个四字符标识（ASCII）。
/// 调用方必须保证 `offset + 4 <= data.length()`。
fn ma_fourcc(data : Bytes, offset : Int) -> String {
  let mut out = ""
  for i = 0; i < 4; i = i + 1 {
    out = out + ma_codepoint_to_string(data[offset + i].to_int())
  }
  out
}

///|
/// 小端读 32 位。注意 `Int` 在 32 位后端上可能返回负数（最高位为 1 时），
/// 调用方需要按“声明长度不可信”处理。
fn ma_u32_le(data : Bytes, offset : Int) -> Int {
  let b0 = data[offset].to_int()
  let b1 = data[offset + 1].to_int()
  let b2 = data[offset + 2].to_int()
  let b3 = data[offset + 3].to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

// ---------------------------------------------------------------------------
// Ogg 容器内的编码分派
// ---------------------------------------------------------------------------

///|
/// Ogg 容器里承载的编码。按 identification header 的签名区分。
priv enum MaOggCodec {
  MaOggVorbis
  MaOggOpus
  MaOggFlac
  MaOggOther
} derive(Eq)

///|
/// 按第一个 packet 的签名判断 Ogg 里装的是哪种编码：
/// Vorbis `"\x01vorbis"`、Opus `"OpusHead"`、FLAC-in-Ogg `"\x7fFLAC"`。
fn ma_ogg_codec_of(packet : Bytes) -> MaOggCodec {
  if packet.length() >= 7 &&
    packet[0] == b'\x01' &&
    packet[1] == b'v' &&
    packet[2] == b'o' &&
    packet[3] == b'r' &&
    packet[4] == b'b' &&
    packet[5] == b'i' &&
    packet[6] == b's' {
    MaOggCodec::MaOggVorbis
  } else if ma_prefix_is(packet, "OpusHead") {
    MaOggCodec::MaOggOpus
  } else if packet.length() >= 5 &&
    packet[0] == b'\x7F' &&
    packet[1] == b'F' &&
    packet[2] == b'L' &&
    packet[3] == b'A' &&
    packet[4] == b'C' {
    MaOggCodec::MaOggFlac
  } else {
    MaOggCodec::MaOggOther
  }
}

///|
/// 取出 Ogg 里“看起来是音频”的那条逻辑流。
///
/// 先解析全部 page 并按 serial 拼装 packet，然后优先挑第一个带已知编码签名的流
/// （多路复用的 Ogg 里可能把视频流排在前面），都认不出才退回第一条流。
fn ma_ogg_select_stream(data : Bytes) -> (MaOggCodec, Array[Bytes]) raise AudioError {
  let groups = packets_of(pages(data))
  for group in groups {
    let packets = group.1
    if packets.length() > 0 {
      let codec = ma_ogg_codec_of(packets[0])
      if codec != MaOggCodec::MaOggOther {
        return (codec, packets)
      }
    }
  }
  if groups.length() > 0 {
    (MaOggCodec::MaOggOther, groups[0].1)
  } else {
    raise AudioError::InvalidMagic("Ogg 容器里没有任何 packet")
  }
}

///|
/// Ogg/Vorbis 完整解码。
///
/// Vorbis 逻辑流的前三个 packet 依次是 identification header、comment header、
/// setup header，`decode_vorbis` 只吃这之后的音频 packet。标签直接从 comment header
/// 取（解码器拿不到 comment header），所以这里不用再补一次。
fn ma_decode_ogg(data : Bytes) -> Audio raise AudioError {
  let (codec, packets) = ma_ogg_select_stream(data)
  match codec {
    MaOggCodec::MaOggVorbis => {
      if packets.length() < 3 {
        raise AudioError::Truncated(offset=0, needed=3, available=packets.length())
      }
      let ident = parse_vorbis_ident(packets[0])
      let (_, comments) = parse_vorbis_comment(packets[1])
      let audio_packets : Array[Bytes] = []
      let mut i = 3
      while i < packets.length() {
        audio_packets.push(packets[i])
        i += 1
      }
      ma_with_tags(decode_vorbis(ident, packets[2], audio_packets), comments)
    }
    MaOggCodec::MaOggOpus =>
      raise AudioError::Unsupported("Ogg 容器内是 Opus 编码；本库目前只支持 Ogg/Vorbis")
    MaOggCodec::MaOggFlac =>
      raise AudioError::Unsupported("Ogg 容器内是 FLAC 编码（FLAC-in-Ogg）；尚未接入")
    MaOggCodec::MaOggOther =>
      raise AudioError::InvalidMagic(
        "Ogg 容器内的编码无法识别：第一个 packet 既不是 Vorbis，也不是 Opus 或 FLAC",
      )
  }
}

///|
/// Ogg 的轻量 info：解析 page 到第一个 packet 为止。
/// Vorbis 解码输出固定 16 bit PCM，所以 `bits_per_sample` 恒为 16。
fn ma_ogg_info(data : Bytes) -> AudioFormat raise AudioError {
  let (codec, packets) = ma_ogg_select_stream(data)
  match codec {
    MaOggCodec::MaOggVorbis => {
      if packets.length() < 1 {
        raise AudioError::Truncated(offset=0, needed=1, available=0)
      }
      let ident = parse_vorbis_ident(packets[0])
      ma_format(ident.sample_rate, ident.channels, 16)
    }
    MaOggCodec::MaOggOpus =>
      raise AudioError::Unsupported("Ogg 容器内是 Opus 编码；本库目前只支持 Ogg/Vorbis")
    MaOggCodec::MaOggFlac =>
      raise AudioError::Unsupported("Ogg 容器内是 FLAC 编码（FLAC-in-Ogg）；尚未接入")
    MaOggCodec::MaOggOther =>
      raise AudioError::InvalidMagic(
        "Ogg 容器内的编码无法识别：第一个 packet 既不是 Vorbis，也不是 Opus 或 FLAC",
      )
  }
}

///|
/// Ogg 的标签：Vorbis 的 comment header 是第二个 packet。
fn ma_ogg_tags(data : Bytes) -> Array[(String, String)] raise AudioError {
  let (codec, packets) = ma_ogg_select_stream(data)
  match codec {
    MaOggCodec::MaOggVorbis =>
      if packets.length() >= 2 {
        parse_vorbis_comment(packets[1]).1
      } else {
        []
      }
    MaOggCodec::MaOggOpus =>
      raise AudioError::Unsupported("Ogg 容器内是 Opus 编码；本库目前只支持 Ogg/Vorbis")
    MaOggCodec::MaOggFlac =>
      raise AudioError::Unsupported("Ogg 容器内是 FLAC 编码（FLAC-in-Ogg）；尚未接入")
    MaOggCodec::MaOggOther =>
      raise AudioError::InvalidMagic(
        "Ogg 容器内的编码无法识别：第一个 packet 既不是 Vorbis，也不是 Opus 或 FLAC",
      )
  }
}

// ---------------------------------------------------------------------------
// MP3 标签（ID3v2）
// ---------------------------------------------------------------------------

///|
/// ID3v2 → `(键, 值)` 数组。
///
/// 键名与 Vorbis comment 对齐（`TITLE` / `ARTIST` / `ALBUM` / `DATE` /
/// `TRACKNUMBER` / `GENRE` / `COMMENT` / `COMPOSER`），这样跨格式取标签的代码不用分支。
/// 字段缺失或为空串时跳过；封面（`pictures`）与原始帧（`raw_frames`）不是字符串对，
/// 需要的话直接调 `parse_id3v2`。没有 ID3v2 标签时返回空数组，不抛错。
fn ma_id3v2_tags(data : Bytes) -> Array[(String, String)] raise AudioError {
  match parse_id3v2(data) {
    None => []
    Some(tag) => {
      let out : Array[(String, String)] = []
      ma_push_tag(out, "TITLE", tag.title)
      ma_push_tag(out, "ARTIST", tag.artist)
      ma_push_tag(out, "ALBUM", tag.album)
      ma_push_tag(out, "DATE", tag.year)
      ma_push_tag(out, "TRACKNUMBER", tag.track)
      ma_push_tag(out, "GENRE", tag.genre)
      ma_push_tag(out, "COMMENT", tag.comment)
      ma_push_tag(out, "COMPOSER", tag.composer)
      out
    }
  }
}

///|
/// 值存在且非空时才追加，避免产出 `("TITLE", "")` 这种噪音标签。
fn ma_push_tag(out : Array[(String, String)], key : String, value : String?) -> Unit {
  match value {
    Some(v) =>
      if v != "" {
        out.push((key, v))
      }
    None => ()
  }
}

// ---------------------------------------------------------------------------
// WAV 标签（RIFF LIST/INFO）
//
// 这一段是纯 RIFF 解析，不调用 wav.mbt 的任何东西。wav.mbt 里其实有一个公开的
// `riff_chunks`，但它不在 CONTRACT.md 的冻结签名里；为了不让入口层被一个未冻结的
// 内部函数绑住，这里自带一份最小的 chunk 遍历（只认 LIST/INFO，其余一律跳过）。
// ---------------------------------------------------------------------------

///|
/// WAV 的标签：RIFF 本身没有标签容器，但很多写入器会塞一个 `LIST`/`INFO` chunk。
///
/// 结构：`"RIFF" <size> "WAVE"` 之后是若干 chunk，每个 chunk =
/// 4 字节 id + 4 字节小端 size + 数据（奇数长度补 1 字节对齐）。
/// `LIST` chunk 的头 4 字节是列表类型，`INFO` 类型下的子 chunk 就是标签，
/// 值是以 NUL 结尾的文本。字段映射见 `ma_riff_info_key`。
///
/// 任何结构异常都只当作“标签到此为止”，返回已经拿到的部分，不抛错：
/// 缺标签不该让一个音频文件解析失败。
pub fn ma_wav_tags(data : Bytes) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  let len = data.length()
  if len < 12 || !ma_is_fourcc(data, 0, "RIFF") || !ma_is_fourcc(data, 8, "WAVE") {
    return out
  }
  let mut offset = 12
  while offset + 8 <= len {
    let id = ma_fourcc(data, offset)
    let size = ma_u32_le(data, offset + 4)
    let body = offset + 8
    if size < 0 || body + size < body {
      break
    }
    if id == "LIST" && size >= 4 && body + 4 <= len && ma_fourcc(data, body) == "INFO" {
      let end = if body + size > len { len } else { body + size }
      ma_collect_riff_info(data, body + 4, end, out)
    }
    let next = body + size + (size & 1)
    if next <= offset {
      break
    }
    offset = next
  }
  out
}

///|
/// 遍历一个 `INFO` 列表的子 chunk，把认识的字段追加到 `out`。
fn ma_collect_riff_info(
  data : Bytes,
  start : Int,
  end : Int,
  out : Array[(String, String)],
) -> Unit {
  let mut offset = start
  while offset + 8 <= end {
    let id = ma_fourcc(data, offset)
    let size = ma_u32_le(data, offset + 4)
    let body = offset + 8
    if size < 0 || body + size < body || body + size > end {
      break
    }
    match ma_riff_info_key(id) {
      Some(key) => {
        let value = ma_riff_text(data, body, size)
        if value != "" {
          out.push((key, value))
        }
      }
      None => ()
    }
    let next = body + size + (size & 1)
    if next <= offset {
      break
    }
    offset = next
  }
}

///|
/// RIFF `INFO` 子 chunk 的四字符 id → 统一键名。不认识的 id 返回 `None`
/// （比如 `ISBJ`/`IKEY` 这类冷门字段，宁可丢掉也不要塞一个没人认识的键）。
fn ma_riff_info_key(id : String) -> String? {
  if id == "INAM" {
    Some("TITLE")
  } else if id == "IART" {
    Some("ARTIST")
  } else if id == "IPRD" {
    Some("ALBUM")
  } else if id == "ICRD" {
    Some("DATE")
  } else if id == "ITRK" || id == "IPRT" {
    Some("TRACKNUMBER")
  } else if id == "IGNR" {
    Some("GENRE")
  } else if id == "ICMT" {
    Some("COMMENT")
  } else if id == "IMUS" {
    Some("COMPOSER")
  } else if id == "ICOP" {
    Some("COPYRIGHT")
  } else if id == "ISFT" {
    Some("ENCODER")
  } else {
    None
  }
}

///|
/// 取 RIFF INFO 的文本值：去掉尾部的 NUL 与空格。
///
/// 值绝大多数是 UTF-8，但按 Latin-1 写入的老文件也不少。合法 UTF-8 直接采用，
/// 否则按 Latin-1 升级（每个字节一个码点），避免 0xE9 这类字节变成乱码。
fn ma_riff_text(data : Bytes, offset : Int, len : Int) -> String {
  let mut end = offset + len
  while end > offset && (data[end - 1] == b'\x00' || data[end - 1] == b' ') {
    end -= 1
  }
  if end <= offset {
    return ""
  }
  if ma_is_valid_utf8(data, offset, end - offset) {
    ma_utf8_to_string(data, offset, end)
  } else {
    ma_latin1_to_string(data, offset, end)
  }
}

///|
/// 解码 `data[offset ..< end)` 里的 UTF-8 码点。调用前必须先用
/// `ma_is_valid_utf8` 验过，这里不再重复做边界检查。
fn ma_utf8_to_string(data : Bytes, offset : Int, end : Int) -> String {
  let mut out = ""
  let mut i = offset
  while i < end {
    let b0 = data[i].to_int()
    let (cp, width) = if b0 < 0x80 {
      (b0, 1)
    } else if b0 >= 0xC2 && b0 <= 0xDF {
      (((b0 & 0x1F) << 6) | (data[i + 1].to_int() & 0x3F), 2)
    } else if b0 >= 0xE0 && b0 <= 0xEF {
      (
        ((b0 & 0x0F) << 12) |
        ((data[i + 1].to_int() & 0x3F) << 6) |
        (data[i + 2].to_int() & 0x3F),
        3,
      )
    } else {
      (
        ((b0 & 0x07) << 18) |
        ((data[i + 1].to_int() & 0x3F) << 12) |
        ((data[i + 2].to_int() & 0x3F) << 6) |
        (data[i + 3].to_int() & 0x3F),
        4,
      )
    }
    out = out + ma_codepoint_to_string(cp)
    i += width
  }
  out
}

///|
/// Latin-1（ISO-8859-1）：每个字节就是一个码点 U+00XX。
fn ma_latin1_to_string(data : Bytes, offset : Int, end : Int) -> String {
  let mut out = ""
  let mut i = offset
  while i < end {
    out = out + ma_codepoint_to_string(data[i].to_int())
    i += 1
  }
  out
}

///|
/// `data[offset ..< offset+len)` 是否是合法 UTF-8（拒绝过长编码、代理区、越界续字节）。
/// 用它把“真 UTF-8”和“Latin-1 误打误撞”区分开。
fn ma_is_valid_utf8(data : Bytes, offset : Int, len : Int) -> Bool {
  let end = offset + len
  if offset < 0 || len < 0 || end > data.length() {
    return false
  }
  let mut i = offset
  while i < end {
    let b0 = data[i].to_int()
    let mut n = 0
    if b0 < 0x80 {
      n = 1
    } else if b0 >= 0xC2 && b0 <= 0xDF {
      n = 2
    } else if b0 >= 0xE0 && b0 <= 0xEF {
      n = 3
    } else if b0 >= 0xF0 && b0 <= 0xF4 {
      n = 4
    } else {
      return false
    }
    if i + n > end {
      return false
    }
    let mut j = 1
    while j < n {
      let b = data[i + j].to_int()
      if b < 0x80 || b > 0xBF {
        return false
      }
      j += 1
    }
    let b1 = if n > 1 { data[i + 1].to_int() } else { 0 }
    if n == 3 && ((b0 == 0xE0 && b1 < 0xA0) || (b0 == 0xED && b1 > 0x9F)) {
      return false
    }
    if n == 4 && ((b0 == 0xF0 && b1 < 0x90) || (b0 == 0xF4 && b1 > 0x8F)) {
      return false
    }
    i += n
  }
  true
}
