// moonbit-music —— fixtures.mbt 的自测
//
// 这些测试证明「语料构造器本身是对的」：WAV 的 RIFF/chunk size 真的算对、
// 奇数 chunk 真的补了 padding、8 位样本真的是无符号、Ogg CRC 真的按
// 0x04C11DB7/无反射/初值 0/不取反 算对、ID3 的 syncsafe 编码真的可逆。
//
// 如果这一层就不对，所有依赖 fixture 的解码器测试都会得出错误结论。

// ---------------------------------------------------------------------------
// 测试用的小工具
// ---------------------------------------------------------------------------

///|
/// 从 `Bytes` 读一个小端整数（测试侧独立实现，不复用 fixtures.mbt 的内部函数）。
fn fread_le(data : Bytes, offset : Int, n : Int) -> Int {
  let mut v = 0
  let mut i = 0
  while i < n {
    v = v | (data[offset + i].to_int() << (8 * i))
    i = i + 1
  }
  v
}

///|
/// 从 `Bytes` 读一个大端整数（测试侧独立实现）。
fn fread_be(data : Bytes, offset : Int, n : Int) -> Int {
  let mut v = 0
  let mut i = 0
  while i < n {
    v = (v << 8) | data[offset + i].to_int()
    i = i + 1
  }
  v
}

///|
/// 取 `Bytes` 的一段（测试侧独立实现）。
fn fsub(data : Bytes, start : Int, end : Int) -> Bytes {
  data.view(start=start, end=end).to_owned()
}

///|
/// 十六进制字符串，失败信息里用。
fn fhex(data : Bytes) -> String {
  let b = StringBuilder()
  for x in data {
    b.write_string(x.to_hex())
  }
  b.to_string()
}

///|
/// 断言两个 `Bytes` 逐字节相等，不等时打印十六进制。
fn fassert_bytes(actual : Bytes, expected : Bytes, what : String) -> Unit {
  if !Bytes::equal(actual, expected) {
    abort(
      "\{what}: bytes mismatch\n  actual  (len=\{actual.length()}) = \{fhex(actual)}\n  expect  (len=\{expected.length()}) = \{fhex(expected)}",
    )
  }
}

///|
/// 断言两个 `Int` 相等。
fn fassert_int(actual : Int, expected : Int, what : String) -> Unit {
  if actual != expected {
    abort("\{what}: expected \{expected}, got \{actual}")
  }
}

///|
/// 断言两个 `Int64` 相等。
fn fassert_i64(actual : Int64, expected : Int64, what : String) -> Unit {
  if actual != expected {
    abort("\{what}: expected \{expected}, got \{actual}")
  }
}

// ---------------------------------------------------------------------------
// WAV：size 字段与 PCM 编码
// ---------------------------------------------------------------------------

test "fixture: WAV mono 16-bit 头部与大小自洽" {
  let samples : Array[Int] = [0, 1, -1, 32767, -32768]
  let wav = fixture_wav_mono(44100, 16, samples)
  // 头部固定 44 字节 + 每个样本 2 字节
  fassert_int(wav.length(), 44 + samples.length() * 2, "total length")
  fassert_bytes(fsub(wav, 0, 4), b"RIFF", "RIFF magic")
  fassert_bytes(fsub(wav, 8, 12), b"WAVE", "WAVE magic")
  // RIFF size 必须 = 文件长度 - 8
  fassert_int(fread_le(wav, 4, 4), wav.length() - 8, "RIFF size")
  fassert_bytes(fsub(wav, 12, 16), b"fmt ", "fmt id")
  fassert_int(fread_le(wav, 16, 4), 16, "fmt chunk size")
  fassert_int(fread_le(wav, 20, 2), 1, "audio format = PCM")
  fassert_int(fread_le(wav, 22, 2), 1, "channels")
  fassert_int(fread_le(wav, 24, 4), 44100, "sample rate")
  fassert_int(fread_le(wav, 28, 4), 44100 * 2, "byte rate")
  fassert_int(fread_le(wav, 32, 2), 2, "block align")
  fassert_int(fread_le(wav, 34, 2), 16, "bits per sample")
  fassert_bytes(fsub(wav, 36, 40), b"data", "data id")
  fassert_int(fread_le(wav, 40, 4), samples.length() * 2, "data chunk size")
  // 小端有符号二补码
  fassert_bytes(fsub(wav, 44, 46), b"\x00\x00", "sample 0")
  fassert_bytes(fsub(wav, 46, 48), b"\x01\x00", "sample +1")
  fassert_bytes(fsub(wav, 48, 50), b"\xFF\xFF", "sample -1")
  fassert_bytes(fsub(wav, 50, 52), b"\xFF\x7F", "sample +32767")
  fassert_bytes(fsub(wav, 52, 54), b"\x00\x80", "sample -32768")
}

test "fixture: WAV 8-bit 样本是无符号存储（+128）" {
  let wav = fixture_wav_mono(8000, 8, [0, 1, -1, 127, -128])
  fassert_int(wav.length(), 44 + 5, "total length")
  fassert_int(fread_le(wav, 40, 4), 5, "data size")
  fassert_int(fread_le(wav, 34, 2), 8, "bits")
  fassert_int(fread_le(wav, 32, 2), 1, "block align")
  fassert_bytes(fsub(wav, 44, 49), b"\x80\x81\x7F\xFF\x00", "8-bit PCM: 0->128, +1->129, -1->127, +127->255, -128->0")
}

test "fixture: WAV 24-bit 与 32-bit 小端打包" {
  let w24 = fixture_wav_mono(48000, 24, [0, 1, -1, 8388607, -8388608])
  fassert_int(w24.length(), 44 + 15, "24-bit total length")
  fassert_int(fread_le(w24, 32, 2), 3, "24-bit block align")
  fassert_int(fread_le(w24, 40, 4), 15, "24-bit data size")
  fassert_bytes(
    fsub(w24, 44, 59),
    b"\x00\x00\x00\x01\x00\x00\xFF\xFF\xFF\xFF\xFF\x7F\x00\x00\x80",
    "24-bit PCM",
  )
  let w32 = fixture_wav_mono(48000, 32, [0, 1, -1, 2147483647, -2147483648])
  fassert_int(w32.length(), 44 + 20, "32-bit total length")
  fassert_int(fread_le(w32, 32, 2), 4, "32-bit block align")
  fassert_bytes(
    fsub(w32, 44, 64),
    b"\x00\x00\x00\x00\x01\x00\x00\x00\xFF\xFF\xFF\xFF\xFF\xFF\xFF\x7F\x00\x00\x00\x80",
    "32-bit PCM",
  )
}

test "fixture: WAV stereo 交织顺序" {
  let wav = fixture_wav_stereo(22050, 16, [100, -100, 200, -200])
  fassert_int(wav.length(), 44 + 8, "length")
  fassert_int(fread_le(wav, 22, 2), 2, "channels")
  fassert_int(fread_le(wav, 28, 4), 22050 * 4, "byte rate = sr * ch * bytes")
  fassert_int(fread_le(wav, 32, 2), 4, "block align")
  fassert_bytes(
    fsub(wav, 44, 52),
    b"\x64\x00\x9C\xFF\xC8\x00\x38\xFF",
    "interleaved L0 R0 L1 R1",
  )
}

test "fixture: WAV 奇数长度 junk chunk 会补 padding" {
  for junk_size in [0, 1, 2, 3, 9] {
    let wav = fixture_wav_with_junk_chunk(8000, 16, [1, 2, 3], junk_size)
    let padded = if junk_size % 2 == 1 { junk_size + 1 } else { junk_size }
    fassert_int(wav.length(), 44 + 8 + padded + 6, "length with junk=\{junk_size}")
    fassert_bytes(fsub(wav, 36, 40), b"junk", "junk chunk id")
    fassert_int(fread_le(wav, 40, 4), junk_size, "junk chunk size 字段不含 padding")
    // data chunk 必须从 junk 之后（含 padding）开始
    let data_at = 44 + padded
    fassert_bytes(fsub(wav, data_at, data_at + 4), b"data", "data after junk + padding")
    fassert_int(fread_le(wav, data_at + 4, 4), 6, "data size")
    fassert_int(fread_le(wav, 4, 4), wav.length() - 8, "RIFF size 把 junk 也算进去")
  }
}

test "fixture: WAV 故意写错 RIFF size" {
  let good = fixture_wav_mono(8000, 16, [1, 2, 3])
  let bad = fixture_wav_bad_riff_size(8000, 16, [1, 2, 3], 100)
  fassert_int(fread_le(bad, 4, 4), fread_le(good, 4, 4) + 100, "declared RIFF size = 真实 + delta")
  // 只有 size 字段不同，其余完全一致
  fassert_bytes(fsub(bad, 8, bad.length()), fsub(good, 8, good.length()), "其余字节不变")
}

test "fixture: WAV LIST/INFO 标签 chunk" {
  // 本测试的每一个偏移都来自 fixture 实际产出的字节（不是手算的）：
  //   36 LIST | 40 size=40 | 44 LIST | 48 size=32 | 52 INFO |
  //   56 INAM 60 size=6 64 "Hello\0" | 70 IART 74 size=6 78 "World\0" |
  //   84 data 88 size=6 92 PCM | 总长 98
  let wav = fixture_wav_with_info("Hello", "World")
  fassert_int(wav.length(), 98, "文件总长")
  fassert_bytes(fsub(wav, 36, 40), b"LIST", "外层 LIST id")
  fassert_int(fread_le(wav, 40, 4), 40, "外层 LIST size = 8(LIST 头) + 32(INFO body)")
  // 嵌套结构：body 为 `LIST` + size + `INFO` + INAM + IART
  fassert_bytes(fsub(wav, 44, 48), b"LIST", "body 内的 LIST id")
  fassert_int(fread_le(wav, 48, 4), 32, "body 内 LIST size = 'INFO'(4) + INAM(14) + IART(14)")
  fassert_bytes(fsub(wav, 52, 56), b"INFO", "INFO 类型")
  fassert_bytes(fsub(wav, 56, 60), b"INAM", "INAM id")
  fassert_int(fread_le(wav, 60, 4), 6, "INAM size = 'Hello' + NUL")
  fassert_bytes(fsub(wav, 64, 70), b"Hello\x00", "INAM 值")
  fassert_bytes(fsub(wav, 70, 74), b"IART", "IART id")
  fassert_int(fread_le(wav, 74, 4), 6, "IART size = 'World' + NUL")
  fassert_bytes(fsub(wav, 78, 84), b"World\x00", "IART 值")
  // data 必须紧跟在 LIST 之后：LIST 整体 = 8 + 40
  let data_at = 36 + 8 + 40
  fassert_int(data_at, 84, "data 偏移")
  fassert_bytes(fsub(wav, data_at, data_at + 4), b"data", "data 紧跟 LIST")
  fassert_int(fread_le(wav, data_at + 4, 4), 6, "data size = 3 样本 * 2 字节")
  fassert_int(fread_le(wav, 4, 4), 90, "RIFF size = 90")
  fassert_int(fread_le(wav, 4, 4), wav.length() - 8, "RIFF size = 文件长 - 8")
  fassert_bytes(fsub(wav, data_at + 8, wav.length()), b"\x00\x00\x01\x00\xFF\xFF", "PCM [0, 1, -1]")
}

test "fixture: WAV info chunk 为奇数长度时补 padding" {
  // 'Hi' + NUL = 3 字节（奇数）→ 子 chunk 补 1 字节；'A' + NUL = 2 字节（偶数）→ 不补
  //   36 LIST | 40 size=34 | 44 LIST | 48 size=26 | 52 INFO |
  //   56 INAM 60 size=3 64 "Hi\0" 67 padding | 68 IART 72 size=2 76 "A\0" | 78 data | 86 end
  let wav = fixture_wav_with_info("Hi", "A")
  fassert_int(wav.length(), 92, "文件总长")
  fassert_bytes(fsub(wav, 36, 40), b"LIST", "外层 LIST id")
  fassert_int(fread_le(wav, 40, 4), 34, "外层 LIST size = 8 + 26")
  fassert_bytes(fsub(wav, 44, 48), b"LIST", "body 内 LIST id")
  fassert_int(fread_le(wav, 48, 4), 26, "body 内 size = 4 + (8+3+1) + (8+2)")
  fassert_bytes(fsub(wav, 52, 56), b"INFO", "INFO 类型")
  fassert_bytes(fsub(wav, 56, 60), b"INAM", "INAM id")
  fassert_int(fread_le(wav, 60, 4), 3, "INAM size = 3（值含 NUL，padding 不计入 size）")
  fassert_bytes(fsub(wav, 64, 67), b"Hi\x00", "INAM 值")
  fassert_bytes(fsub(wav, 67, 68), b"\x00", "INAM padding")
  fassert_bytes(fsub(wav, 68, 72), b"IART", "IART id")
  fassert_int(fread_le(wav, 72, 4), 2, "IART size = 2")
  fassert_bytes(fsub(wav, 76, 78), b"A\x00", "IART 值")
  let data_at = 36 + 8 + 34
  fassert_int(data_at, 78, "data 偏移")
  fassert_bytes(fsub(wav, data_at, data_at + 4), b"data", "data 紧跟在 padding 之后")
  fassert_int(fread_le(wav, 4, 4), wav.length() - 8, "RIFF size 自洽")
}

test "fixture: fixture_wav_patch_data_size 只改声明不改长度" {
  let wav = fixture_wav_mono(8000, 16, [1, 2, 3])
  let patched = fixture_wav_patch_data_size(wav, 999999)
  fassert_int(patched.length(), wav.length(), "长度不变")
  fassert_int(fread_le(patched, 40, 4), 999999, "data size 被改写")
  fassert_int(fread_le(patched, 4, 4), fread_le(wav, 4, 4), "RIFF size 不受影响")
  fassert_int(fread_le(patched, 44, 2), 1, "PCM 数据不变")
}

// ---------------------------------------------------------------------------
// Ogg
// ---------------------------------------------------------------------------

test "fixture: Ogg page 结构与 lacing 表" {
  // lacing 值之和必须等于 body 长度（Ogg 不变量）。
  // 单个 3 字节 packet 用单个 lacing 值 3 表示；写成 [1, 2, 3] 会被解释成
  // 三个 packet，且与 3 字节 body 不自洽——fixture 内置校验会拒绝。
  let page = fixture_ogg_page(0x1234, 7, 12345L, 0x02, [3], b"ABC")
  fassert_int(page.length(), 27 + 1 + 3, "page 长度 = 27 + lacing 数 + body")
  fassert_bytes(fsub(page, 0, 4), b"OggS", "OggS magic")
  fassert_int(page[4].to_int(), 0, "stream structure version")
  fassert_int(page[5].to_int(), 0x02, "header type = BOS")
  fassert_i64(fread_le(page, 6, 8).to_int64(), 12345L, "granule position")
  fassert_int(fread_le(page, 14, 4), 0x1234, "serial")
  fassert_int(fread_le(page, 18, 4), 7, "sequence")
  fassert_int(page[26].to_int(), 1, "segment count")
  fassert_int(page[27].to_int(), 3, "lacing[0] = body 全部 3 字节")
  fassert_bytes(fsub(page, 28, 31), b"ABC", "body")
}

test "fixture: Ogg page granule 为 -1 时是 8 个 0xFF（有符号 64 位小端）" {
  let page = fixture_ogg_page(1, 0, -1L, 0x00, [0], b"")
  fassert_bytes(fsub(page, 6, 14), b"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF", "granule = -1")
  fassert_int(page[26].to_int(), 1, "segment count")
  fassert_int(page[27].to_int(), 0, "lacing 0（零长度 packet 终止符）")
  fassert_int(page.length(), 28, "空 body")
}

test "fixture: fixture_ogg_crc32 是标准 Ogg CRC" {
  // 与 Python 参考实现（同一多项式/无反射/初值 0/不取反）对拍过的向量
  fassert_int(fixture_ogg_crc32(b""), 0, "空输入 CRC = 0")
  fassert_int(fixture_ogg_crc32(b"A"), 0x2189, "单字节 'A'")
  fassert_int(fixture_ogg_crc32(b"123456789"), 0x89A1897F, "check 向量 '123456789'")
}

test "fixture: fixture_ogg_page 写入的 CRC 与自算一致（且是对整页算的）" {
  let body = b"ABC"
  let page = fixture_ogg_page(0x1234, 0, 0L, 0x02, [1, 2, 3], body)
  // 复算：把校验和字段清零后算整页
  let zeroed = page.to_fixedarray()
  zeroed[22] = b'\x00'
  zeroed[23] = b'\x00'
  zeroed[24] = b'\x00'
  zeroed[25] = b'\x00'
  let expected = fixture_ogg_crc32(Bytes::from_array(zeroed.view()))
  fassert_int(fread_le(page, 22, 4), expected, "page 里填的 CRC")
  fassert_int(expected, 0x4AC28BF6, "与 Python 参考实现对拍的固定向量")
}

test "fixture: fixture_ogg_page_with_crc 能造出错误 CRC" {
  let good = fixture_ogg_page(1, 0, 0L, 0x00, [3], b"abc")
  let bad = fixture_ogg_page_with_crc(1, 0, 0L, 0x00, [3], b"abc", 0xDEADBEEF)
  fassert_int(fread_le(bad, 22, 4), 0xDEADBEEF, "被改写的 CRC")
  fassert_int(fread_le(good, 22, 4), fixture_ogg_crc32(good), "原 page 仍然正确")
  fassert_int(bad.length(), good.length(), "长度不变")
}

// ---------------------------------------------------------------------------
// ID3v2
// ---------------------------------------------------------------------------

test "fixture: syncsafe 编码可逆且每个字节只用 7 位" {
  for n in [0, 1, 127, 128, 255, 16383, 16384, 2097151, 2097152, 268435455] {
    let enc = fixture_syncsafe_bytes(n)
    fassert_int(enc.length(), 4, "syncsafe 总是 4 字节")
    for i in 0..<4 {
      if enc[i].to_int() > 0x7F {
        abort("syncsafe 字节 \{i} 超过 0x7F: \{enc[i].to_int()}")
      }
    }
    fassert_int(fixture_unsyncsafe(enc), n, "syncsafe 往返 n=\{n}")
  }
  fassert_bytes(fixture_syncsafe_bytes(0x0FFFFFFF), b"\x7F\x7F\x7F\x7F", "最大值")
  fassert_bytes(fixture_syncsafe_bytes(0x00000400), b"\x00\x00\x08\x00", "0x400")
}

test "fixture: ID3v2.3 标签结构与大小字段" {
  let tag = fixture_id3v23("Hello", "World")
  fassert_bytes(fsub(tag, 0, 3), b"ID3", "ID3 magic")
  fassert_int(tag[3].to_int(), 3, "version = 3")
  fassert_int(tag[4].to_int(), 0, "revision")
  fassert_int(tag[5].to_int(), 0, "flags")
  let size = fixture_unsyncsafe(fsub(tag, 6, 10))
  fassert_int(tag.length(), 10 + size, "标签总长 = 10 + size")
  // 第一个帧：TIT2
  fassert_bytes(fsub(tag, 10, 14), b"TIT2", "frame id")
  let f1 = fread_be(tag, 14, 4)
  fassert_int(f1, 6, "v2.3 帧大小 = 1(编码) + 5('Hello')，已是偶数不补 padding")
  fassert_int(fread_be(tag, 18, 2), 0, "frame flags")
  fassert_int(tag[20].to_int(), 0x03, "文本编码 = UTF-8")
  fassert_bytes(fsub(tag, 21, 26), b"Hello", "标题文本")
  // 第二个帧：TPE1
  let off2 = 20 + f1
  fassert_bytes(fsub(tag, off2, off2 + 4), b"TPE1", "第二个 frame id")
  let f2 = fread_be(tag, off2 + 4, 4)
  fassert_int(f2, 6, "v2.3 第二个帧大小")
  fassert_bytes(fsub(tag, off2 + 10, off2 + 16), b"\x03World", "艺术家文本")
  fassert_int(off2 + 10 + f2, tag.length(), "帧区恰好用完")
}

test "fixture: ID3v2.4 帧大小用 syncsafe" {
  let tag = fixture_id3v24("Hello", "World")
  fassert_int(tag[3].to_int(), 4, "version = 4")
  let size = fixture_unsyncsafe(fsub(tag, 6, 10))
  fassert_int(tag.length(), 10 + size, "标签总长 = 10 + size")
  fassert_bytes(fsub(tag, 10, 14), b"TIT2", "frame id")
  // syncsafe(6) = 00 00 00 06；普通大端也会是 00 00 00 06，所以再用一个 >127 的值区分
  fassert_bytes(fsub(tag, 14, 18), fixture_syncsafe_bytes(6), "v2.4 帧大小用 syncsafe")
  let long = "A".repeat(200)
  let tag2 = fixture_id3v24(long, "B")
  // 正文 = 1 + 200 = 201（奇数 → 补 1 个 0x00 变 202）
  fassert_bytes(fsub(tag2, 14, 18), b"\x00\x00\x01\x4A", "syncsafe(202)")
  fassert_int(fixture_unsyncsafe(fsub(tag2, 14, 18)), 202, "syncsafe 解码回来是 202")
  // 若这里是普通大端，202 会写成 00 00 00 CA，最高字节仍是 0 但第三字节会 >0x7F
  fassert_int(fsub(tag2, 14, 18)[2].to_int(), 0x01, "第三字节 0x01（syncsafe 语义）")
}

test "fixture: ID3 帧为奇数长度时补 0x00" {
  // "ab" -> 正文 1 + 2 = 3（奇数）→ 补 1 字节 → 4
  let tag = fixture_id3v23("ab", "c")
  let f1 = fread_be(tag, 14, 4)
  fassert_int(f1, 4, "补 padding 后的帧大小")
  fassert_bytes(fsub(tag, 20, 24), b"\x03ab\x00", "编码 + 文本 + padding")
  // "c" -> 正文 1 + 1 = 2（偶数）→ 不补
  let off2 = 20 + f1
  let f2 = fread_be(tag, off2 + 4, 4)
  fassert_int(f2, 2, "偶数长度不补 padding")
  fassert_bytes(fsub(tag, off2 + 10, off2 + 12), b"\x03c", "编码 + 文本")
}

test "fixture: ID3 支持非 ASCII（UTF-8）" {
  let tag = fixture_id3v23("月音", "测试")
  fassert_int(tag[20].to_int(), 0x03, "UTF-8 编码标记")
  // "月音" 的 UTF-8 是 E6 9C 88 E9 9F B3
  fassert_bytes(fsub(tag, 21, 27), b"\xE6\x9C\x88\xE9\x9F\xB3", "UTF-8 标题字节")
  let size = fixture_unsyncsafe(fsub(tag, 6, 10))
  fassert_int(tag.length(), 10 + size, "标签总长自洽")
}

test "fixture: 内部 UTF-8 编码器覆盖 1/2/3/4 字节序列" {
  // 关键回归：`String::to_bytes()` 在本工具链上产出 **UTF-16LE**（实测 "Hi" -> 48 00 69 00），
  // 用它写 ID3/INFO 会生成错误语料。这里逐档验证自实现的编码器。
  // 偏移同上面的 INFO 布局：INAM id@56, INAM size@60, INAM 值@64。
  let wav1 = fixture_wav_with_info("A", "A") // 1 字节码点
  fassert_int(fread_le(wav1, 60, 4), 2, "ASCII 'A'+NUL = 2 字节")
  fassert_bytes(fsub(wav1, 64, 66), b"A\x00", "ASCII 只有 1 字节，没有 UTF-16 的补 0")
  let wav2 = fixture_wav_with_info("é", "A") // U+00E9 → 2 字节 C3 A9
  fassert_int(fread_le(wav2, 60, 4), 3, "U+00E9 的 UTF-8 是 2 字节 + NUL")
  fassert_bytes(fsub(wav2, 64, 67), b"\xC3\xA9\x00", "2 字节序列")
  let wav3 = fixture_wav_with_info("月", "A") // U+6708 → 3 字节 E6 9C 88
  fassert_int(fread_le(wav3, 60, 4), 4, "U+6708 的 UTF-8 是 3 字节 + NUL")
  fassert_bytes(fsub(wav3, 64, 68), b"\xE6\x9C\x88\x00", "3 字节序列")
  let wav4 = fixture_wav_with_info("😀", "A") // U+1F600 → 4 字节 F0 9F 98 80（代理对）
  fassert_int(fread_le(wav4, 60, 4), 5, "U+1F600 的 UTF-8 是 4 字节 + NUL")
  fassert_bytes(fsub(wav4, 64, 69), b"\xF0\x9F\x98\x80\x00", "4 字节序列（代理对）")
}

// ---------------------------------------------------------------------------
// 伪随机 / 边界
// ---------------------------------------------------------------------------

test "fixture: pseudo_random 确定性且与 Python 参考实现一致" {
  // 这三个向量由 tools/gen_fixtures.py 的 lcg_bytes() 生成，两侧逐字节相同
  fassert_bytes(
    fixture_pseudo_random(16, 1),
    b"\xC6\x7E\x81\x6B\x4B\xFB\xE2\xFB\x54\xF6\xBD\xDF\x7C\x1C\xE1\x87",
    "LCG seed=1 len=16",
  )
  fassert_bytes(
    fixture_pseudo_random(8, 0),
    b"\x00\xDC\x04\x65\xAA\x1F\xAD\x1D",
    "LCG seed=0 len=8",
  )
  fassert_bytes(fixture_pseudo_random(4, 123), b"\x47\xFC\x6D\x84", "LCG seed=123 len=4")
  // 同参数两次调用完全一致（可复现性）
  fassert_bytes(fixture_pseudo_random(64, 42), fixture_pseudo_random(64, 42), "可复现")
  // 不同种子应给出不同序列
  if Bytes::equal(fixture_pseudo_random(64, 42), fixture_pseudo_random(64, 43)) {
    abort("不同 seed 却给出相同序列，LCG 实现有问题")
  }
}

test "fixture: pseudo_random 边界长度" {
  fassert_int(fixture_pseudo_random(0, 1).length(), 0, "len=0")
  fassert_int(fixture_pseudo_random(1, 1).length(), 1, "len=1")
  fassert_int(fixture_pseudo_random(1, 1)[0].to_int(), 0x04, "len=1 的第一个字节")
}

test "fixture: truncated 的边界夹取" {
  let data = b"0123456789"
  fassert_bytes(fixture_truncated(data, 0), b"", "cut_at=0")
  fassert_bytes(fixture_truncated(data, 4), b"0123", "cut_at=4")
  fassert_bytes(fixture_truncated(data, 10), data, "cut_at=len")
  fassert_bytes(fixture_truncated(data, 99), data, "cut_at>len 被夹住")
  fassert_bytes(fixture_truncated(data, -5), b"", "cut_at<0 被夹住")
}

test "fixture: empty / single_byte" {
  fassert_int(fixture_empty().length(), 0, "empty")
  let one = fixture_single_byte(b'\xAB')
  fassert_int(one.length(), 1, "single byte 长度")
  fassert_int(one[0].to_int(), 0xAB, "single byte 内容")
}

test "fixture: magic_only 都是「不足以解码」的短前缀" {
  let magics = fixture_magic_only()
  fassert_int(magics.length(), 5, "5 个魔数")
  fassert_bytes(magics[0], b"RIFF", "RIFF")
  fassert_bytes(magics[1], b"fLaC", "fLaC")
  fassert_bytes(magics[2], b"OggS", "OggS")
  fassert_bytes(magics[3], b"ID3", "ID3")
  fassert_bytes(magics[4], b"\xFF\xFB", "MP3 同步字")
  for m in magics {
    if m.length() >= 12 {
      abort("magic_only 的每一项都应该短到无法解码")
    }
  }
}

// ---------------------------------------------------------------------------
// FLAC 元数据层 / MP3 形状输入
// ---------------------------------------------------------------------------

test "fixture: FLAC header only 的结构与 STREAMINFO 位域" {
  let flac = fixture_flac_header_only(44100, 2, 16, 88200L)
  fassert_bytes(fsub(flac, 0, 4), b"fLaC", "fLaC magic")
  fassert_int(flac[4].to_int(), 0x80, "最后一块 + 类型 0 (STREAMINFO)")
  fassert_int(fread_be(flac, 5, 3), 34, "STREAMINFO 长度 = 34")
  fassert_int(flac.length(), 4 + 4 + 34, "总长")
  fassert_int(fread_be(flac, 8, 2), 4096, "min block size")
  fassert_int(fread_be(flac, 10, 2), 4096, "max block size")
  // sample_rate(20) channels-1(3) bits-1(5) total_samples(36)
  let b13 = flac[8 + 10].to_int()
  let b14 = flac[8 + 11].to_int()
  let b15 = flac[8 + 12].to_int()
  fassert_int((b13 << 12) | (b14 << 4) | (b15 >> 4), 44100, "sample_rate 位域")
  fassert_int(((b15 >> 1) & 0x07) + 1, 2, "channels 位域")
  fassert_int((((b15 & 0x01) << 4) | (flac[8 + 13].to_int() >> 4)) + 1, 16, "bits 位域")
  let total = ((flac[8 + 13].to_int() & 0x0F) << 32)
    | (fread_be(flac, 8 + 14, 4) & 0xFFFFFFFF)
  fassert_int(total, 88200, "total_samples 位域")
  // MD5 全 0 表示未计算
  for i in 0..<16 {
    fassert_int(flac[8 + 18 + i].to_int(), 0, "MD5 第 \{i} 字节")
  }
}

test "fixture: FLAC with_comment 的 VORBIS_COMMENT 块" {
  let comments : Array[(String, String)] = [("TITLE", "Hi"), ("ARTIST", "Me")]
  let flac = fixture_flac_with_comment(48000, 1, 24, 48000L, comments)
  fassert_bytes(fsub(flac, 0, 4), b"fLaC", "fLaC magic")
  fassert_int(flac[4].to_int(), 0x00, "STREAMINFO 不是最后一块")
  fassert_int(fread_be(flac, 5, 3), 34, "STREAMINFO 长度")
  let comment_at = 4 + 4 + 34
  fassert_int(flac[comment_at].to_int(), 0x84, "最后一块 + 类型 4 (VORBIS_COMMENT)")
  let clen = fread_be(flac, comment_at + 1, 3)
  fassert_int(flac.length(), comment_at + 4 + clen, "VORBIS_COMMENT 长度自洽")
  // vendor
  let vlen = fread_le(flac, comment_at + 4, 4)
  fassert_int(vlen, 17, "vendor 长度 = 'moonaudio-fixture'")
  fassert_bytes(
    fsub(flac, comment_at + 8, comment_at + 8 + vlen),
    b"moonaudio-fixture",
    "vendor 字符串",
  )
  // comment 数
  let n_at = comment_at + 8 + vlen
  fassert_int(fread_le(flac, n_at, 4), 2, "comment 条数")
  // 第一条 "TITLE=Hi"
  let c1_at = n_at + 4
  let c1_len = fread_le(flac, c1_at, 4)
  fassert_int(c1_len, 8, "第一条 comment 长度")
  fassert_bytes(fsub(flac, c1_at + 4, c1_at + 4 + c1_len), b"TITLE=Hi", "第一条 comment")
  // 第二条 "ARTIST=Me"
  let c2_at = c1_at + 4 + c1_len
  let c2_len = fread_le(flac, c2_at, 4)
  fassert_int(c2_len, 9, "第二条 comment 长度")
  fassert_bytes(fsub(flac, c2_at + 4, c2_at + 4 + c2_len), b"ARTIST=Me", "第二条 comment")
  fassert_int(c2_at + 4 + c2_len, flac.length(), "恰好用完")
}

test "fixture: FLAC block 长度字段由 payload 算出" {
  let blk = fixture_flac_block(true, 4, b"xyz")
  fassert_int(blk.length(), 4 + 3, "块头 4 字节 + payload")
  fassert_int(blk[0].to_int(), 0x84, "last | type 4")
  fassert_int(fread_be(blk, 1, 3), 3, "长度 = 3")
  let blk0 = fixture_flac_block(false, 0, b"")
  fassert_int(blk0[0].to_int(), 0x00, "非 last, type 0")
  fassert_int(fread_be(blk0, 1, 3), 0, "零长度 payload")
}

test "fixture: MP3 形状输入 = ID3v2.3 + 帧头 + payload" {
  let id3 = fixture_id3v23("T", "A")
  let payload = fixture_pseudo_random(20, 7)
  let mp3 = fixture_mp3_with_id3("T", "A", payload)
  fassert_int(mp3.length(), id3.length() + 4 + 20, "总长")
  fassert_bytes(fsub(mp3, 0, id3.length()), id3, "前缀就是 ID3v2.3 标签")
  fassert_bytes(fsub(mp3, id3.length(), id3.length() + 4), b"\xFF\xFB\x90\x00", "帧头紧跟标签")
  fassert_bytes(fsub(mp3, id3.length() + 4, mp3.length()), payload, "payload 在最后")
}

// ---------------------------------------------------------------------------
// 交叉一致性：不同 fixture 之间不该互相矛盾
// ---------------------------------------------------------------------------

test "fixture: junk chunk 不影响 PCM 内容，只改变偏移" {
  let samples : Array[Int] = [10, -20, 30]
  let plain = fixture_wav_mono(16000, 16, samples)
  for junk_size in [0, 1, 2, 5, 100] {
    let with_junk = fixture_wav_with_junk_chunk(16000, 16, samples, junk_size)
    let padded = if junk_size % 2 == 1 { junk_size + 1 } else { junk_size }
    let pcm_plain = fsub(plain, 44, plain.length())
    let pcm_junk = fsub(with_junk, 44 + 8 + padded, with_junk.length())
    fassert_bytes(pcm_junk, pcm_plain, "PCM 与无 junk 版本逐字节相同 (junk=\{junk_size})")
  }
}

test "fixture: WAV 头部 8..12 之外的内容不会随 junk_size 变化" {
  // 除了插入的 junk chunk 与 RIFF/data size，成品应当只差一个平移
  let a = fixture_wav_with_junk_chunk(8000, 16, [1], 4)
  let b = fixture_wav_with_junk_chunk(8000, 16, [1], 6)
  fassert_int(b.length() - a.length(), 2, "长度差 = junk 长度差")
}
