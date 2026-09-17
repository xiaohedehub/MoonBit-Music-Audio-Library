// moonbit-music —— 入口层黑盒测试
//
// 覆盖四类东西：
//
//   1. `format_name` 的每个分支；
//   2. 认不出的输入：`decode` / `info` / `tags` 必须抛 `InvalidMagic`，而不是 panic；
//   3. WAV 的 `LIST/INFO` 标签（入口层自己的纯 RIFF 解析，不依赖任何解码器）；
//   4. 真实格式的分派：WAV 往返、FLAC 标签、MP3 标签、Ogg/Vorbis 头部。
//
// WAV 的字节在测试里手写（只用 `Buffer::write_byte` / `write_bytes`），这样第 3 类
// 断言不随 fixtures.mbt 的改动而变；第 4 类里 FLAC / MP3 / Ogg 的语料仍然借用
// fixtures.mbt 的公开构件（手搓合法 FLAC 帧或 Ogg page 不现实）。

// ---------------------------------------------------------------------------
// 测试内的最小 WAV 构造工具
// ---------------------------------------------------------------------------

///|
/// 小端写 16 位。
fn wr_u16le(buf : Buffer, value : Int) -> Unit {
  buf.write_byte((value & 0xFF).to_byte())
  buf.write_byte(((value >> 8) & 0xFF).to_byte())
}

///|
/// 小端写 32 位。
fn wr_u32le(buf : Buffer, value : Int) -> Unit {
  buf.write_byte((value & 0xFF).to_byte())
  buf.write_byte(((value >> 8) & 0xFF).to_byte())
  buf.write_byte(((value >> 16) & 0xFF).to_byte())
  buf.write_byte(((value >> 24) & 0xFF).to_byte())
}

///|
/// 一个 RIFF chunk：4 字节 id + 小端长度 + 数据（奇数长度补 1 字节对齐）。
fn riff_chunk(id : Bytes, payload : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(id.view())
  wr_u32le(buf, payload.length())
  buf.write_bytes(payload.view())
  if payload.length() % 2 == 1 {
    buf.write_byte(b'\x00')
  }
  buf.to_bytes()
}

///|
/// 组一个 `LIST/INFO`：每个字段是 `id + 长度 + NUL 结尾的值`（RIFF INFO 的惯例）。
fn riff_info_list(fields : Array[(Bytes, Bytes)]) -> Bytes {
  let body = Buffer()
  for field in fields {
    let (id, value) = field
    let payload = Buffer()
    payload.write_bytes(value.view())
    payload.write_byte(b'\x00')
    body.write_bytes(riff_chunk(id, payload.to_bytes()).view())
  }
  let payload = Buffer()
  payload.write_bytes(b"INFO".view())
  payload.write_bytes(body.to_bytes().view())
  riff_chunk(b"LIST", payload.to_bytes())
}

///|
/// 手写一个合法 WAV：`RIFF/WAVE` + `fmt `（8000 Hz / 16 bit / 单声道）+ 额外 chunk + `data`。
/// 音频数据是 4 字节 `00 01 FF 7F`，即两个 16 位小端样本 `[256, 32767]`。
fn wav_bytes(extra : Array[Bytes]) -> Bytes {
  let fmt = Buffer()
  wr_u16le(fmt, 1) // PCM
  wr_u16le(fmt, 1) // 单声道
  wr_u32le(fmt, 8000) // 采样率
  wr_u32le(fmt, 16000) // 字节率
  wr_u16le(fmt, 2) // 块对齐
  wr_u16le(fmt, 16) // 位深
  let data = Buffer()
  for byte in [b'\x00', b'\x01', b'\xFF', b'\x7F'] {
    data.write_byte(byte)
  }
  let body = Buffer()
  body.write_bytes(b"WAVE".view())
  body.write_bytes(riff_chunk(b"fmt ", fmt.to_bytes()).view())
  for chunk in extra {
    body.write_bytes(chunk.view())
  }
  body.write_bytes(riff_chunk(b"data", data.to_bytes()).view())
  let payload = body.to_bytes()
  let out = Buffer()
  out.write_bytes(b"RIFF".view())
  wr_u32le(out, payload.length())
  out.write_bytes(payload.view())
  out.to_bytes()
}

///|
/// 带 `LIST/INFO` 的最小 WAV。
fn wav_with_info(title : Bytes, artist : Bytes) -> Bytes {
  let info = riff_info_list([(b"INAM", title), (b"IART", artist)])
  wav_bytes([info])
}

///|
/// 只有一个 page 的 Ogg/Vorbis 流：page 里装着 30 字节的 identification header
/// （2 声道 / 44100 Hz）。够 `info` + codec 识别，不足以 `decode`。
fn ogg_vorbis_ident_only() -> Bytes {
  let ident = b"\x01vorbis\x00\x00\x00\x00\x02\x44\xAC\x00\x00\x00\x00\x00\x00\x00\xF4\x01\x00\x00\x00\x00\x00\xB8\x01"
  fixture_ogg_page(1, 0, 0L, 0x02, [ident.length()], ident)
}

// ---------------------------------------------------------------------------
// 错误分支断言工具
// ---------------------------------------------------------------------------

///|
/// 断言 `decode` 抛 `AudioError::InvalidMagic`（而不是 panic，也不是别的分支）。
fn expect_decode_invalid_magic(data : Bytes) -> Unit raise {
  let mut hit = false
  try {
    ignore(decode(data))
  } catch {
    AudioError::InvalidMagic(_) => hit = true
    _ => hit = false
  }
  assert_true(hit, msg="decode 应当抛 AudioError::InvalidMagic")
}

///|
/// 断言 `info` 抛 `AudioError::InvalidMagic`。
fn expect_info_invalid_magic(data : Bytes) -> Unit raise {
  let mut hit = false
  try {
    ignore(info(data))
  } catch {
    AudioError::InvalidMagic(_) => hit = true
    _ => hit = false
  }
  assert_true(hit, msg="info 应当抛 AudioError::InvalidMagic")
}

///|
/// 断言 `tags` 抛 `AudioError::InvalidMagic`。
fn expect_tags_invalid_magic(data : Bytes) -> Unit raise {
  let mut hit = false
  try {
    ignore(tags(data))
  } catch {
    AudioError::InvalidMagic(_) => hit = true
    _ => hit = false
  }
  assert_true(hit, msg="tags 应当抛 AudioError::InvalidMagic")
}

// ---------------------------------------------------------------------------
// format_name
// ---------------------------------------------------------------------------

///|
/// 每个 `AudioFormatHint` 分支都要有非空名字，五个名字互不相同，别名与主名一致。
test "format_name covers every hint with a distinct non-empty name" {
  let hints : Array[AudioFormatHint] = [
    AudioFormatHint::Wav,
    AudioFormatHint::Flac,
    AudioFormatHint::Ogg,
    AudioFormatHint::Mp3,
    AudioFormatHint::Unknown,
  ]
  let names : Array[String] = []
  for hint in hints {
    let name = format_name(hint)
    assert_true(name.length() > 0, msg="format_name 不应返回空串")
    names.push(name)
  }
  assert_eq(names.length(), 5)
  for i = 0; i < names.length(); i = i + 1 {
    for j = i + 1; j < names.length(); j = j + 1 {
      assert_true(names[i] != names[j], msg="format_name 的返回值必须互不相同")
    }
  }
  for hint in hints {
    assert_eq(moonbit_music_format_name(hint), format_name(hint))
  }
}

///|
/// 名字是稳定的小写标识符，可以直接拼进命令行与日志。
/// （区别于 `AudioFormatHint` 自带的 `Show`，那个给的是 `"Wav"` 这种类型名。）
test "format_name returns stable lowercase tokens" {
  assert_eq(format_name(AudioFormatHint::Wav), "wav")
  assert_eq(format_name(AudioFormatHint::Flac), "flac")
  assert_eq(format_name(AudioFormatHint::Ogg), "ogg")
  assert_eq(format_name(AudioFormatHint::Mp3), "mp3")
  assert_eq(format_name(AudioFormatHint::Unknown), "unknown")
}

// ---------------------------------------------------------------------------
// 认不出的输入：三个入口都必须抛 InvalidMagic，而不是 panic
// ---------------------------------------------------------------------------

///|
/// 空输入：长度连魔数都不够。
test "empty input raises InvalidMagic from decode/info/tags" {
  expect_decode_invalid_magic(b"")
  expect_info_invalid_magic(b"")
  expect_tags_invalid_magic(b"")
}

///|
/// 明显的非音频字节。
test "plain text raises InvalidMagic from decode/info/tags" {
  expect_decode_invalid_magic(b"hello world")
  expect_info_invalid_magic(b"hello world")
  expect_tags_invalid_magic(b"hello world")
}

///|
/// 前缀只差一两个字节：不能靠“像”就蒙混过关。
test "near-miss magics raise InvalidMagic" {
  for data in [b"RIF", b"RIFX", b"fLa", b"fLaX", b"Ogg", b"OggX", b"ID", b"ID4"] {
    expect_decode_invalid_magic(data)
    expect_info_invalid_magic(data)
    expect_tags_invalid_magic(data)
  }
}

///|
/// 全零字节是最容易被误判成“合法头部”的输入。
test "all-zero input raises InvalidMagic from decode/info/tags" {
  let zeros = Buffer()
  for i = 0; i < 64; i = i + 1 {
    zeros.write_byte(b'\x00')
  }
  let data = zeros.to_bytes()
  expect_decode_invalid_magic(data)
  expect_info_invalid_magic(data)
  expect_tags_invalid_magic(data)
}

///|
/// MPEG 帧同步要求第二字节的高 3 位全 1：`0xFF 0x00` 必须认不出来。
test "0xFF followed by 0x00 is not a frame sync" {
  expect_decode_invalid_magic(b"\xFF\x00")
  expect_decode_invalid_magic(b"\xFF\x1F\x00")
}

///|
/// 只有魔数、后面什么都没有：三个入口都必须抛 `AudioError`（任何分支都行），
/// 而且不能 panic —— 这是“头部之后立刻截断”的边界。
test "magic-only inputs raise AudioError instead of panicking" {
  for data in fixture_magic_only() {
    let mut decode_raised = false
    try {
      ignore(decode(data))
    } catch {
      _ => decode_raised = true
    }
    assert_true(decode_raised, msg="decode 对只有魔数的输入必须抛 AudioError")
    let mut info_raised = false
    try {
      ignore(info(data))
    } catch {
      _ => info_raised = true
    }
    assert_true(info_raised, msg="info 对只有魔数的输入必须抛 AudioError")
    // tags 允许返回空数组（WAV 就没有标签），但不能 panic。
    try {
      ignore(tags(data))
    } catch {
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// WAV 标签：RIFF LIST/INFO
// ---------------------------------------------------------------------------

///|
/// 不带 `LIST/INFO` 的 WAV：`tags` 返回空数组，不抛错。
test "wav without LIST/INFO yields empty tags" {
  let wav = wav_bytes([])
  assert_eq(tags(wav).length(), 0)
  assert_eq(ma_wav_tags(wav).length(), 0)
}

///|
/// `LIST/INFO` 里的 `INAM` / `IART` 要按统一键名 `TITLE` / `ARTIST` 取出来。
test "wav LIST/INFO maps INAM to TITLE and IART to ARTIST" {
  let wav = wav_with_info(b"Moon Audio", b"Shun Ge")
  let got = tags(wav)
  assert_eq(got.length(), 2)
  assert_eq(got[0].0, "TITLE")
  assert_eq(got[0].1, "Moon Audio")
  assert_eq(got[1].0, "ARTIST")
  assert_eq(got[1].1, "Shun Ge")
}

///|
/// 值是 UTF-8 时必须原样还原（不能被 Latin-1 回退弄成乱码）。
test "wav LIST/INFO decodes UTF-8 values" {
  // "月音" 的 UTF-8 字节。
  let wav = wav_with_info(b"\xE6\x9C\x88\xE9\x9F\xB3", b"A")
  let got = tags(wav)
  assert_eq(got.length(), 2)
  assert_eq(got[0].1, "月音")
}

///|
/// 不是合法 UTF-8 时按 Latin-1 解释：`0xE9` 是 U+00E9 `é`。
test "wav LIST/INFO falls back to Latin-1 for non-UTF-8 values" {
  let wav = wav_with_info(b"caf\xE9", b"A")
  let got = tags(wav)
  assert_eq(got.length(), 2)
  assert_eq(got[0].1, "café")
}

///|
/// 空值字段直接跳过，不产出 `("TITLE", "")` 这种噪音。
test "wav LIST/INFO skips empty values" {
  let wav = wav_with_info(b"", b"Shun Ge")
  let got = tags(wav)
  assert_eq(got.length(), 1)
  assert_eq(got[0].0, "ARTIST")
}

///|
/// 不认识的 INFO 字段（这里用 `ISBJ`）应当被忽略，而不是变成无意义的键。
test "wav LIST/INFO ignores unknown field ids" {
  let info = riff_info_list([(b"ISBJ", b"subject"), (b"INAM", b"T")])
  let got = tags(wav_bytes([info]))
  assert_eq(got.length(), 1)
  assert_eq(got[0].0, "TITLE")
  assert_eq(got[0].1, "T")
}

///|
/// 声明的 chunk 长度远超文件实际长度：只能提前收尾，绝不能越界或死循环。
test "malformed RIFF sizes terminate without panic" {
  let out = Buffer()
  out.write_bytes(b"RIFF".view())
  wr_u32le(out, 0x7FFFFFF0)
  out.write_bytes(b"WAVE".view())
  out.write_bytes(b"LIST".view())
  wr_u32le(out, 0x7FFFFFF0)
  out.write_bytes(b"INFO".view())
  out.write_bytes(b"INAM".view())
  wr_u32le(out, 0x7FFFFFF0)
  assert_eq(tags(out.to_bytes()).length(), 0)
}

///|
/// 长度刚好卡在边界上的截断输入：不能 panic，也不能抛出 InvalidMagic 以外的错误。
test "truncated RIFF headers are safe" {
  let full = wav_with_info(b"Moon Audio", b"Shun Ge")
  for cut in [0, 4, 8, 11, 12, 13, 20, 40, 70, 95] {
    if cut < full.length() {
      let head = Buffer()
      for i = 0; i < cut; i = i + 1 {
        head.write_byte(full[i])
      }
      let data = head.to_bytes()
      try {
        ignore(tags(data))
      } catch {
        AudioError::InvalidMagic(_) => ()
        _ => abort("截断输入只允许抛 InvalidMagic，cut=\{cut}")
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 真实格式的分派
// ---------------------------------------------------------------------------

///|
/// WAV 往返：`decode` 要认出 RIFF/WAVE 并解出 PCM，样本按小端有符号 16 位。
test "decode dispatches WAV and returns interleaved PCM" {
  let audio = decode(wav_bytes([]))
  assert_eq(audio.format.sample_rate, 8000)
  assert_eq(audio.format.channels, 1)
  assert_eq(audio.format.bits_per_sample, 16)
  assert_eq(audio.samples.length(), 2)
  assert_eq(audio.samples[0], 256)
  assert_eq(audio.samples[1], 32767)
}

///|
/// `info` 与 `decode` 对同一个 WAV 必须给出同一个格式（轻量路径不能和全量路径打架）。
test "info and decode agree on the WAV format" {
  let wav = wav_with_info(b"Moon Audio", b"Shun Ge")
  let light = info(wav)
  let full = decode(wav).format
  assert_eq(light.sample_rate, full.sample_rate)
  assert_eq(light.channels, full.channels)
  assert_eq(light.bits_per_sample, full.bits_per_sample)
  assert_eq(light.sample_rate, 8000)
}

///|
/// `decode_wav` 本身不填标签（WAV 的 LIST/INFO 属于入口层）；`decode` 必须把
/// `tags` 补上，这样 `decode(...).tags` 与 `tags(...)` 的结果一致。
test "decode fills WAV tags when the decoder returns none" {
  let wav = wav_with_info(b"Moon Audio", b"Shun Ge")
  let audio = decode(wav)
  assert_eq(audio.samples.length(), 2)
  assert_eq(audio.tags.length(), 2)
  assert_eq(audio.tags[0].0, "TITLE")
  assert_eq(audio.tags[0].1, "Moon Audio")
  assert_eq(audio.tags[1].0, "ARTIST")
  assert_eq(audio.tags[1].1, "Shun Ge")
}

///|
/// FLAC 的标签走 Vorbis comment 块。
test "tags dispatches FLAC to the Vorbis comment block" {
  let flac = fixture_flac_with_comment(44100, 2, 16, 0L, [
    ("TITLE", "Moon"),
    ("ARTIST", "Shun"),
  ])
  let got = tags(flac)
  assert_eq(got.length(), 2)
  assert_eq(got[0].0, "TITLE")
  assert_eq(got[0].1, "Moon")
  assert_eq(got[1].0, "ARTIST")
  assert_eq(got[1].1, "Shun")
}

///|
/// FLAC 的 `info` 走 STREAMINFO，不需要音频帧。
test "info dispatches FLAC to STREAMINFO" {
  let flac = fixture_flac_header_only(48000, 2, 24, 0L)
  let fmt = info(flac)
  assert_eq(fmt.sample_rate, 48000)
  assert_eq(fmt.channels, 2)
  assert_eq(fmt.bits_per_sample, 24)
}

///|
/// MP3 的标签走 ID3v2，键名统一成 Vorbis comment 风格。
test "tags dispatches MP3 to ID3v2" {
  let got = tags(fixture_id3v23("Moon", "Shun"))
  assert_eq(got.length(), 2)
  assert_eq(got[0].0, "TITLE")
  assert_eq(got[0].1, "Moon")
  assert_eq(got[1].0, "ARTIST")
  assert_eq(got[1].1, "Shun")
}

///|
/// Ogg 的 `info` 必须穿过容器拿到 identification header：
/// 2 声道 / 44100 Hz，Vorbis 输出固定 16 bit。
test "info dispatches Ogg/Vorbis through the container" {
  let fmt = info(ogg_vorbis_ident_only())
  assert_eq(fmt.sample_rate, 44100)
  assert_eq(fmt.channels, 2)
  assert_eq(fmt.bits_per_sample, 16)
}

///|
/// 只有 identification header 的 Ogg/Vorbis 流没有标签，也没有音频 packet：
/// `tags` 返回空数组，`decode` 抛 `AudioError`（缺 comment/setup header）而不是 panic。
test "Ogg/Vorbis with only an ident header reports an AudioError" {
  let ogg = ogg_vorbis_ident_only()
  assert_eq(tags(ogg).length(), 0)
  let mut raised = false
  try {
    ignore(decode(ogg))
  } catch {
    _ => raised = true
  }
  assert_true(raised, msg="只有 ident header 的 Ogg 流不该被当成解码成功")
}

///|
/// Ogg 里装的是 Opus 时，`decode` / `info` / `tags` 都要明确说“不支持 Opus”，
/// 而不是含糊地报 InvalidMagic（用户需要知道是编码不支持，还是文件坏了）。
test "Ogg/Opus is reported as Unsupported across the three entry points" {
  let opus = fixture_ogg_page(7, 0, 0L, 0x02, [19], b"OpusHead\x01\x02\x00\x00\x80\xBB\x00\x00\x00\x00\x00")
  let mut decode_unsupported = false
  try {
    ignore(decode(opus))
  } catch {
    AudioError::Unsupported(_) => decode_unsupported = true
    _ => decode_unsupported = false
  }
  assert_true(decode_unsupported, msg="decode 对 Ogg/Opus 应当抛 Unsupported")
  let mut info_unsupported = false
  try {
    ignore(info(opus))
  } catch {
    AudioError::Unsupported(_) => info_unsupported = true
    _ => info_unsupported = false
  }
  assert_true(info_unsupported, msg="info 对 Ogg/Opus 应当抛 Unsupported")
  let mut tags_unsupported = false
  try {
    ignore(tags(opus))
  } catch {
    AudioError::Unsupported(_) => tags_unsupported = true
    _ => tags_unsupported = false
  }
  assert_true(tags_unsupported, msg="tags 对 Ogg/Opus 应当抛 Unsupported")
}
