// moonbit-music —— wav.mbt 的黑盒测试。
//
// 所有输入都是**手写字节数组**，期望值按 WAV 规范手算，不依赖任何外部文件，
// 也不用本库自己的编码器生成数据（避免自证循环）。
//
// 注意：`AudioError` 是 `pub suberror`，构造子对外包不可见（测试文件属于独立的
// 黑盒测试包），所以错误分支只能用 `catch { AudioError::Xxx(_) => ... }` 匹配。

///|
/// 跑 `f`，返回它抛出的 `AudioError` 分支名；没抛错返回 `"ok"`。
///
/// 注意：`AudioError::Io` 这个名字在本工具链里无法写进 catch 模式（编译器报
/// “does not have the constructor Io”，疑似与内建错误类型重名），而其余 5 个
/// 分支已构成穷尽匹配；本解码器也不会抛 `Io`。
fn wav_err_kind(f : () -> Unit raise AudioError) -> String {
  try {
    f()
    "ok"
  } catch {
    AudioError::InvalidMagic(_) => "InvalidMagic"
    AudioError::Unsupported(_) => "Unsupported"
    AudioError::Truncated(..) => "Truncated"
    AudioError::ChecksumMismatch(..) => "ChecksumMismatch"
    AudioError::LimitExceeded(_) => "LimitExceeded"
  }
}

///|
/// `decode_wav` 包装：不该失败时失败就让测试直接挂掉，并打印具体错误。
fn wav_decode_ok(data : Bytes) -> Audio raise {
  decode_wav(data) catch {
    e => fail("decode_wav 不该抛错，实际抛出 \{@debug.to_string(e)}")
  }
}

///|
/// `wav_info` 包装：同上。
fn wav_info_ok(data : Bytes) -> AudioFormat raise {
  wav_info(data) catch {
    e => fail("wav_info 不该抛错，实际抛出 \{@debug.to_string(e)}")
  }
}

///|
/// 断言样本数组逐项相等（`Array[Int]` 没有方便的 Debug 输出，自己比更清楚）。
fn wav_assert_samples(
  actual : Array[Int],
  expected : Array[Int],
  what : String,
) -> Unit raise {
  if actual.length() != expected.length() {
    fail(
      "\{what}：样本个数是 \{actual.length()}，期望 \{expected.length()}",
    )
  }
  for i = 0; i < expected.length(); i = i + 1 {
    if actual[i] != expected[i] {
      fail(
        "\{what}：第 \{i} 个样本是 \{actual[i]}，期望 \{expected[i]}",
      )
    }
  }
}

///|
/// 断言 chunk 列表与 `(id, offset, size)` 三元组序列完全一致。
fn wav_assert_chunks(
  actual : Array[RiffChunk],
  expected : Array[(String, Int, Int)],
) -> Unit raise {
  if actual.length() != expected.length() {
    fail("chunk 个数是 \{actual.length()}，期望 \{expected.length()}")
  }
  for i = 0; i < expected.length(); i = i + 1 {
    let (id, offset, size) = expected[i]
    let chunk = actual[i]
    if chunk.id != id || chunk.offset != offset || chunk.size != size {
      fail(
        "第 \{i} 个 chunk 是 (\{chunk.id}, \{chunk.offset}, \{chunk.size})，期望 (\{id}, \{offset}, \{size})",
      )
    }
  }
}

///|
/// 断言格式三元组。
fn wav_assert_format(
  actual : AudioFormat,
  rate : Int,
  channels : Int,
  bits : Int,
) -> Unit raise {
  if actual.sample_rate != rate ||
    actual.channels != channels ||
    actual.bits_per_sample != bits {
    fail(
      "格式是 (\{actual.sample_rate}, \{actual.channels}, \{actual.bits_per_sample})，期望 (\{rate}, \{channels}, \{bits})",
    )
  }
}

///|
/// Int 的最小值。写成 `-2147483647 - 1` 是因为 `-2147483648` 字面量在 32 位 Int 上越界。
let wav_int_min : Int = -2147483647 - 1

// ---------------------------------------------------------------------------
// 1. 最小合法 WAV：mono / 8kHz / 16bit / 3 个样本
//
// 偏移  内容
//   0   "RIFF"
//   4   2a 00 00 00   RIFF 总长度 = 50 - 8 = 42
//   8   "WAVE"
//  12   "fmt "
//  16   10 00 00 00   fmt size = 16
//  20   01 00         format tag = 1 (PCM)
//  22   01 00         channels = 1
//  24   40 1f 00 00   sample rate = 0x1F40 = 8000
//  28   80 3e 00 00   byte rate = 16000
//  32   02 00         block align = 2
//  34   10 00         bits = 16
//  36   "data"
//  40   06 00 00 00   data size = 6
//  44   34 12         0x1234 = 4660
//  46   fe ff         0xFFFE = -2
//  48   ff 7f         0x7FFF = 32767
// ---------------------------------------------------------------------------

///|
test "wav: 最小合法文件 mono/8kHz/16bit 三个样本" {
  let wav = b"RIFF\x2a\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x80\x3e\x00\x00\x02\x00\x10\x00" +
    b"data\x06\x00\x00\x00" +
    b"\x34\x12\xfe\xff\xff\x7f"
  assert_true(wav.length() == 50)
  let audio = wav_decode_ok(wav)
  wav_assert_format(audio.format, 8000, 1, 16)
  wav_assert_samples(audio.samples, [4660, -2, 32767], "最小文件")
  assert_true(audio.frame_count() == 3)
  assert_true(audio.tags.length() == 0)
}

// ---------------------------------------------------------------------------
// 2. stereo 16bit：交织顺序必须是 [L0, R0, L1, R1]
//
// data 内容：e8 03 | 18 fc | ff ff | 01 00
//           1000    -1000   -1      1
// ---------------------------------------------------------------------------

///|
test "wav: stereo 16bit 交织顺序" {
  let wav = b"RIFF\x2c\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x02\x00\x44\xac\x00\x00" +
    b"\x10\xb1\x02\x00\x04\x00\x10\x00" +
    b"data\x08\x00\x00\x00" +
    b"\xe8\x03\x18\xfc\xff\xff\x01\x00"
  assert_true(wav.length() == 52)
  let audio = wav_decode_ok(wav)
  wav_assert_format(audio.format, 44100, 2, 16)
  // 左右声道写反会得到 [-1000, 1000, 1, -1]，这里能抓住。
  wav_assert_samples(audio.samples, [1000, -1000, -1, 1], "stereo 16bit")
  assert_true(audio.frame_count() == 2)
}

// ---------------------------------------------------------------------------
// 3. 8 位 WAV 是无符号：0x80 -> 0，0x00 -> -128，0xFF -> 127，0x7F -> -1
// ---------------------------------------------------------------------------

///|
test "wav: 8bit 无符号转有符号" {
  let wav = b"RIFF\x28\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x40\x1f\x00\x00\x01\x00\x08\x00" +
    b"data\x04\x00\x00\x00" +
    b"\x80\x00\xff\x7f"
  let audio = wav_decode_ok(wav)
  wav_assert_format(audio.format, 8000, 1, 8)
  wav_assert_samples(audio.samples, [0, -128, 127, -1], "8bit 无符号")
}

// ---------------------------------------------------------------------------
// 4. 24 位小端有符号（含负数、极端值）
//
// 00 00 00 -> 0
// ff ff ff -> -1
// 00 00 80 -> 0x800000 -> -8388608
// ff ff 7f -> 0x7FFFFF -> 8388607
// 01 00 00 -> 1
// fe ff ff -> 0xFFFFFE -> -2
// ---------------------------------------------------------------------------

///|
test "wav: 24bit 小端有符号" {
  let wav = b"RIFF\x36\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x01\x00\x80\xbb\x00\x00" +
    b"\x80\x32\x02\x00\x03\x00\x18\x00" +
    b"data\x12\x00\x00\x00" +
    b"\x00\x00\x00\xff\xff\xff\x00\x00\x80" +
    b"\xff\xff\x7f\x01\x00\x00\xfe\xff\xff"
  assert_true(wav.length() == 62)
  let audio = wav_decode_ok(wav)
  wav_assert_format(audio.format, 48000, 1, 24)
  wav_assert_samples(
    audio.samples,
    [0, -1, -8388608, 8388607, 1, -2],
    "24bit 有符号",
  )
}

// ---------------------------------------------------------------------------
// 5. 32 位 float（挑精确可表示的值）
//
// 0.0   00 00 00 00 -> 0
// 0.5   00 00 00 3f -> 0.5 * 2^31 = 1073741824
// -0.5  00 00 00 bf -> -1073741824
// -1.0  00 00 80 bf -> Int::MIN
// 0.25  00 00 80 3e -> 536870912
// 1.0   00 00 80 3f -> 2^31 溢出上端，截断为 2147483647
// ---------------------------------------------------------------------------

///|
test "wav: 32bit float 解码" {
  let wav = b"RIFF\x3c\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x03\x00\x01\x00\x80\xbb\x00\x00" +
    b"\x00\xee\x02\x00\x04\x00\x20\x00" +
    b"data\x18\x00\x00\x00" +
    b"\x00\x00\x00\x00\x00\x00\x00\x3f" +
    b"\x00\x00\x00\xbf\x00\x00\x80\xbf" +
    b"\x00\x00\x80\x3e\x00\x00\x80\x3f"
  assert_true(wav.length() == 68)
  let audio = wav_decode_ok(wav)
  wav_assert_format(audio.format, 48000, 1, 32)
  wav_assert_samples(
    audio.samples,
    [0, 1073741824, -1073741824, wav_int_min, 536870912, 2147483647],
    "float32",
  )
}

// ---------------------------------------------------------------------------
// 6. data 前面有 LIST 未知 chunk，仍要找到 data
//
//  12 "fmt " size 16            -> 12..36
//  36 "LIST" size 10            -> 36..54（偶长度，无 padding）
//  54 "data" size 4             -> 54..66
// ---------------------------------------------------------------------------

///|
test "wav: LIST 未知 chunk 在前面仍能找到 data" {
  let wav = b"RIFF\x3a\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x80\x3e\x00\x00\x02\x00\x10\x00" +
    b"LIST\x0a\x00\x00\x00" +
    b"INFOabcd\x00\x00" +
    b"data\x04\x00\x00\x00" +
    b"\x00\x01\x00\x02"
  assert_true(wav.length() == 66)
  let audio = wav_decode_ok(wav)
  wav_assert_format(audio.format, 8000, 1, 16)
  wav_assert_samples(audio.samples, [256, 512], "LIST 跳过")
  wav_assert_chunks(riff_chunks(wav), [
    ("fmt ", 12, 16),
    ("LIST", 36, 10),
    ("data", 54, 4),
  ])
}

// ---------------------------------------------------------------------------
// 7. 奇数长度 chunk 的 padding 字节
//
//  12 "fmt "  size 16   -> 12..36
//  36 "JUNK"  size 3    -> 头 36..44，数据 44..47，padding 47..48
//  48 "data"  size 4    -> 48..60
//
// 若不跳 padding，就会在偏移 47 读到假 chunk id，从而找不到 data。
// ---------------------------------------------------------------------------

///|
test "wav: 奇数 size chunk 的 padding" {
  let wav = b"RIFF\x34\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x80\x3e\x00\x00\x02\x00\x10\x00" +
    b"JUNK\x03\x00\x00\x00" +
    b"\xaa\xbb\xcc\x00" +
    b"data\x04\x00\x00\x00" +
    b"\x01\x00\xff\xff"
  assert_true(wav.length() == 60)
  let audio = wav_decode_ok(wav)
  wav_assert_samples(audio.samples, [1, -1], "padding")
  wav_assert_chunks(riff_chunks(wav), [
    ("fmt ", 12, 16),
    ("JUNK", 36, 3),
    ("data", 48, 4),
  ])
}

// ---------------------------------------------------------------------------
// 8. 魔数错误 -> InvalidMagic
// ---------------------------------------------------------------------------

///|
test "wav: RIFF/WAVE 魔数错误抛 InvalidMagic" {
  let bad_riff = b"RIFX\x2c\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x02\x00\x44\xac\x00\x00" +
    b"\x10\xb1\x02\x00\x04\x00\x10\x00" +
    b"data\x08\x00\x00\x00" +
    b"\xe8\x03\x18\xfc\xff\xff\x01\x00"
  assert_true(
    wav_err_kind(() => ignore(decode_wav(bad_riff))) == "InvalidMagic",
  )
  assert_true(wav_err_kind(() => ignore(wav_info(bad_riff))) == "InvalidMagic")
  assert_true(
    wav_err_kind(() => ignore(riff_chunks(bad_riff))) == "InvalidMagic",
  )
  let bad_wave = b"RIFF\x2c\x00\x00\x00WAVX" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x02\x00\x44\xac\x00\x00" +
    b"\x10\xb1\x02\x00\x04\x00\x10\x00" +
    b"data\x08\x00\x00\x00" +
    b"\xe8\x03\x18\xfc\xff\xff\x01\x00"
  assert_true(
    wav_err_kind(() => ignore(decode_wav(bad_wave))) == "InvalidMagic",
  )
}

// ---------------------------------------------------------------------------
// 9. 不支持的格式 -> Unsupported
// ---------------------------------------------------------------------------

///|
test "wav: 不支持的 format tag / 位深抛 Unsupported" {
  // A-law（tag = 6）
  let a_law = b"RIFF\x28\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x06\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x40\x1f\x00\x00\x01\x00\x08\x00" +
    b"data\x04\x00\x00\x00" +
    b"\x80\x00\xff\x7f"
  assert_true(wav_err_kind(() => ignore(decode_wav(a_law))) == "Unsupported")
  assert_true(wav_err_kind(() => ignore(wav_info(a_law))) == "Unsupported")
  // 12 位 PCM：tag 合法但位深不支持
  let bits12 = b"RIFF\x28\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x40\x1f\x00\x00\x02\x00\x0c\x00" +
    b"data\x04\x00\x00\x00" +
    b"\x80\x00\xff\x7f"
  assert_true(wav_err_kind(() => ignore(decode_wav(bits12))) == "Unsupported")
  // 16 位 float：float 只支持 32 位
  let float16 = b"RIFF\x28\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x03\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x40\x1f\x00\x00\x02\x00\x10\x00" +
    b"data\x04\x00\x00\x00" +
    b"\x00\x00\x00\x00"
  assert_true(wav_err_kind(() => ignore(decode_wav(float16))) == "Unsupported")
}

// ---------------------------------------------------------------------------
// 10. riff_chunks 结果与构造完全一致（5 个 chunk，含奇数长度与未知 chunk）
//
//  12 "fmt " size 16 -> 36
//  36 "LIST" size 6  -> 50
//  50 "JUNK" size 3  -> 62（8 + 3 + 1 padding）
//  62 "fact" size 4  -> 74
//  74 "data" size 4  -> 86
// ---------------------------------------------------------------------------

///|
test "wav: riff_chunks 返回的 chunk 列表与构造一致" {
  let wav = b"RIFF\x4e\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x80\x3e\x00\x00\x02\x00\x10\x00" +
    b"LIST\x06\x00\x00\x00" +
    b"INFO\x00\x00" +
    b"JUNK\x03\x00\x00\x00" +
    b"\x01\x02\x03\x00" +
    b"fact\x04\x00\x00\x00" +
    b"\x02\x00\x00\x00" +
    b"data\x04\x00\x00\x00" +
    b"\x01\x00\xff\xff"
  assert_true(wav.length() == 86)
  wav_assert_chunks(riff_chunks(wav), [
    ("fmt ", 12, 16),
    ("LIST", 36, 6),
    ("JUNK", 50, 3),
    ("fact", 62, 4),
    ("data", 74, 4),
  ])
  let audio = wav_decode_ok(wav)
  wav_assert_samples(audio.samples, [1, -1], "多 chunk")
}

// ---------------------------------------------------------------------------
// 11. wav_info 与 decode_wav 的格式信息一致；且 wav_info 不要求有 data chunk
// ---------------------------------------------------------------------------

///|
test "wav: wav_info 与 decode_wav 格式一致" {
  let wav = b"RIFF\x2c\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x02\x00\x44\xac\x00\x00" +
    b"\x10\xb1\x02\x00\x04\x00\x10\x00" +
    b"data\x08\x00\x00\x00" +
    b"\xe8\x03\x18\xfc\xff\xff\x01\x00"
  let info = wav_info_ok(wav)
  wav_assert_format(info, 44100, 2, 16)
  assert_true(info == wav_decode_ok(wav).format)
  // 只有 fmt、没有 data：wav_info 成功，decode_wav 抛 Truncated
  let no_data = b"RIFF\x1c\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x02\x00\x44\xac\x00\x00" +
    b"\x10\xb1\x02\x00\x04\x00\x10\x00"
  assert_true(no_data.length() == 36)
  wav_assert_format(wav_info_ok(no_data), 44100, 2, 16)
  assert_true(wav_err_kind(() => ignore(decode_wav(no_data))) == "Truncated")
}

// ---------------------------------------------------------------------------
// 12. fmt 的 size > 16：多出来的字节要跳过（cbSize = 0 的 18 字节 fmt）
//
//  12 "fmt " size 18 -> 38（18 是偶数，无 padding）
//  38 "data" size 2  -> 48
// ---------------------------------------------------------------------------

///|
test "wav: fmt size 大于 16 时跳过多余字节" {
  let wav = b"RIFF\x28\x00\x00\x00WAVE" +
    b"fmt \x12\x00\x00\x00" +
    b"\x01\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x80\x3e\x00\x00\x02\x00\x10\x00" +
    b"\x00\x00" +
    b"data\x02\x00\x00\x00" +
    b"\x00\x01"
  assert_true(wav.length() == 48)
  let audio = wav_decode_ok(wav)
  wav_assert_format(audio.format, 8000, 1, 16)
  wav_assert_samples(audio.samples, [256], "fmt 18 字节")
  wav_assert_chunks(riff_chunks(wav), [("fmt ", 12, 18), ("data", 38, 2)])
}

// ---------------------------------------------------------------------------
// 13. WAVE_FORMAT_EXTENSIBLE (0xFFFE)：读 cbSize 之后的 SubFormat GUID 前两字节
//
//  PCM GUID   01 00 00 00 00 00 10 00 80 00 00 aa 00 38 9b 71
//  float GUID 03 00 00 00 00 00 10 00 80 00 00 aa 00 38 9b 71
//
//  fmt 结构：tag(2) ch(2) rate(4) byterate(4) align(2) bits(2)
//            cbSize(2) validbits(2) mask(4) GUID(16) = 40 字节
// ---------------------------------------------------------------------------

///|
test "wav: WAVE_FORMAT_EXTENSIBLE 的 PCM 与 float 子格式" {
  let pcm = b"RIFF\x40\x00\x00\x00WAVE" +
    b"fmt \x28\x00\x00\x00" +
    b"\xfe\xff\x01\x00\x44\xac\x00\x00" +
    b"\x88\x58\x01\x00\x02\x00\x10\x00" +
    b"\x16\x00\x10\x00\x00\x00\x00\x00" +
    b"\x01\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71" +
    b"data\x04\x00\x00\x00" +
    b"\x00\x01\xff\xff"
  assert_true(pcm.length() == 72)
  wav_assert_format(wav_info_ok(pcm), 44100, 1, 16)
  wav_assert_samples(wav_decode_ok(pcm).samples, [256, -1], "extensible PCM")
  let floats = b"RIFF\x40\x00\x00\x00WAVE" +
    b"fmt \x28\x00\x00\x00" +
    b"\xfe\xff\x01\x00\x80\xbb\x00\x00" +
    b"\x00\xee\x02\x00\x04\x00\x20\x00" +
    b"\x16\x00\x20\x00\x00\x00\x00\x00" +
    b"\x03\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71" +
    b"data\x04\x00\x00\x00" +
    b"\x00\x00\x00\x3f"
  assert_true(floats.length() == 72)
  wav_assert_format(wav_info_ok(floats), 48000, 1, 32)
  wav_assert_samples(
    wav_decode_ok(floats).samples,
    [1073741824],
    "extensible float",
  )
  // 子格式 GUID 的 tag 不是 1/3 -> Unsupported
  let adpcm = b"RIFF\x40\x00\x00\x00WAVE" +
    b"fmt \x28\x00\x00\x00" +
    b"\xfe\xff\x01\x00\x44\xac\x00\x00" +
    b"\x88\x58\x01\x00\x02\x00\x10\x00" +
    b"\x16\x00\x10\x00\x00\x00\x00\x00" +
    b"\x02\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71" +
    b"data\x04\x00\x00\x00" +
    b"\x00\x01\xff\xff"
  assert_true(wav_err_kind(() => ignore(decode_wav(adpcm))) == "Unsupported")
}

// ---------------------------------------------------------------------------
// 14. data chunk 被截断：不报错，解出完整帧，零头字节丢弃（本模块选定的行为）
//
//  36 "data" 声明 size = 100，实际只有 5 字节（16bit mono -> 2 整帧 + 1 零头）
//  样本：00 01 | 02 03 | 04   -> [0x0100, 0x0302] = [256, 770]，尾字节 0x04 丢弃
// ---------------------------------------------------------------------------

///|
test "wav: data chunk 被截断时解出完整帧并丢弃零头" {
  let wav = b"RIFF\x29\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x80\x3e\x00\x00\x02\x00\x10\x00" +
    b"data\x64\x00\x00\x00" +
    b"\x00\x01\x02\x03\x04"
  assert_true(wav.length() == 49)
  let audio = wav_decode_ok(wav)
  wav_assert_format(audio.format, 8000, 1, 16)
  wav_assert_samples(audio.samples, [256, 770], "截断的 data")
  assert_true(audio.frame_count() == 2)
  // 遍历时仍把声明值原样记下，然后停止
  wav_assert_chunks(riff_chunks(wav), [("fmt ", 12, 16), ("data", 36, 100)])
  // 头部完好，wav_info 不受影响
  wav_assert_format(wav_info_ok(wav), 8000, 1, 16)
}

// ---------------------------------------------------------------------------
// 15. 声道数为 0 -> InvalidMagic；长度不足 -> Truncated
// ---------------------------------------------------------------------------

///|
test "wav: 声道数为 0 抛 InvalidMagic，长度不足抛 Truncated" {
  let zero_channels = b"RIFF\x28\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x00\x00\x40\x1f\x00\x00" +
    b"\x00\x00\x00\x00\x00\x00\x08\x00" +
    b"data\x04\x00\x00\x00" +
    b"\x80\x00\xff\x7f"
  assert_true(
    wav_err_kind(() => ignore(decode_wav(zero_channels))) == "InvalidMagic",
  )
  assert_true(
    wav_err_kind(() => ignore(wav_info(zero_channels))) == "InvalidMagic",
  )
  // 只有 2 字节
  assert_true(wav_err_kind(() => ignore(riff_chunks(b"RI"))) == "Truncated")
  // 有 RIFF 但没有 WAVE
  assert_true(
    wav_err_kind(() => ignore(riff_chunks(b"RIFF\x00\x00\x00\x00"))) ==
    "Truncated",
  )
  // 12 字节的空容器：chunk 列表为空，decode_wav 找不到 fmt
  assert_true(riff_chunks(b"RIFF\x04\x00\x00\x00WAVE").length() == 0)
  assert_true(
    wav_err_kind(() => ignore(decode_wav(b"RIFF\x04\x00\x00\x00WAVE"))) ==
    "Truncated",
  )
}

// ---------------------------------------------------------------------------
// 16. 8 声道 / 16bit：声道数循环与交织
// ---------------------------------------------------------------------------

///|
test "wav: 8 声道交织" {
  let wav = b"RIFF\x34\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x08\x00\x40\x1f\x00\x00" +
    b"\x00\xf4\x01\x00\x10\x00\x10\x00" +
    b"data\x10\x00\x00\x00" +
    b"\x01\x00\x02\x00\x03\x00\x04\x00" +
    b"\x05\x00\x06\x00\x07\x00\x08\x00"
  assert_true(wav.length() == 60)
  let audio = wav_decode_ok(wav)
  wav_assert_format(audio.format, 8000, 8, 16)
  wav_assert_samples(audio.samples, [1, 2, 3, 4, 5, 6, 7, 8], "8 声道")
  assert_true(audio.frame_count() == 1)
}

// ---------------------------------------------------------------------------
// 17. 空 data chunk：合法，样本为空
// ---------------------------------------------------------------------------

///|
test "wav: 空 data chunk" {
  let wav = b"RIFF\x24\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x80\x3e\x00\x00\x02\x00\x10\x00" +
    b"data\x00\x00\x00\x00"
  assert_true(wav.length() == 44)
  let audio = wav_decode_ok(wav)
  wav_assert_format(audio.format, 8000, 1, 16)
  wav_assert_samples(audio.samples, [], "空 data")
  assert_true(audio.frame_count() == 0)
  assert_true(audio.duration_seconds() == 0.0)
}

// ---------------------------------------------------------------------------
// 18. float 的边界：规格化 ±2.0、非规格化最小值、NaN、±Inf
//
//  2.0      00 00 00 40 -> 4294967296  -> 截断到 Int::MAX
//  -2.0     00 00 00 c0 -> -4294967296 -> 截断到 Int::MIN
//  2^-149   01 00 00 00 -> 最小非规格化数，约 1.4e-45 -> 四舍五入为 0
//  NaN      00 00 c0 7f -> 0
//  +Inf     00 00 80 7f -> Int::MAX
//  -Inf     00 00 80 ff -> Int::MIN
// ---------------------------------------------------------------------------

///|
test "wav: float 溢出/非规格化/NaN/Inf" {
  let wav = b"RIFF\x3c\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x03\x00\x01\x00\x80\xbb\x00\x00" +
    b"\x00\xee\x02\x00\x04\x00\x20\x00" +
    b"data\x18\x00\x00\x00" +
    b"\x00\x00\x00\x40\x00\x00\x00\xc0" +
    b"\x01\x00\x00\x00\x00\x00\xc0\x7f" +
    b"\x00\x00\x80\x7f\x00\x00\x80\xff"
  assert_true(wav.length() == 68)
  wav_assert_samples(
    wav_decode_ok(wav).samples,
    [2147483647, wav_int_min, 0, 0, 2147483647, wav_int_min],
    "float 边界",
  )
}

// ---------------------------------------------------------------------------
// 19. 未知 chunk 的 id 含非可打印字节：转义成 \xNN，且不影响后续 chunk 定位
//
//  12 "fmt "                     -> 36
//  36 01 02 03 04 size 4         -> 48（id 非 ASCII，转义后是 \x01\x02\x03\x04）
//  48 "data" size 2              -> 58
// ---------------------------------------------------------------------------

///|
test "wav: 非 ASCII 的 chunk id 转义" {
  let wav = b"RIFF\x32\x00\x00\x00WAVE" +
    b"fmt \x10\x00\x00\x00" +
    b"\x01\x00\x01\x00\x40\x1f\x00\x00" +
    b"\x80\x3e\x00\x00\x02\x00\x10\x00" +
    b"\x01\x02\x03\x04\x04\x00\x00\x00" +
    b"\xde\xad\xbe\xef" +
    b"data\x02\x00\x00\x00" +
    b"\x00\x01"
  assert_true(wav.length() == 58)
  wav_assert_chunks(riff_chunks(wav), [
    ("fmt ", 12, 16),
    ("\\x01\\x02\\x03\\x04", 36, 4),
    ("data", 48, 2),
  ])
  wav_assert_samples(wav_decode_ok(wav).samples, [256], "非 ASCII chunk id")
}
