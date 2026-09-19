// moonbit-music —— 零依赖测试语料工厂（纯函数合成字节样本）
//
// = 模块定位 =
//   为所有 *_test.mbt 提供可复现、可离线、不依赖外部样本文件的
//   字节级测试向量。覆盖 WAV / FLAC / Ogg / Vorbis / MP3 / ID3v2 的
//   头部、帧结构、以及典型的"坏数据"（截断、CRC 错、魔数错等）。
//
// = 核心原则 =
//   所有 `fixture_*` 函数都是严格**纯函数**：
//     * 不读文件 / 不下载 / 不访问系统随机数 / 不读系统时钟
//     * 相同参数 + 相同进程 → 字节级完全相同的输出
//     * 不依赖除 moonbitlang/core 之外的任何包
//   这样单元测试可以在 CI、沙箱、离线环境下一致通过，不受网络/缓存影响。
//
// = 字节序与对齐约定 =
//   各格式严格遵循其规范：
//     * WAV (RIFF)   → 小端，16/24/32-bit 有符号二补码，8-bit 无符号 (+128 偏移)
//     * Ogg Page     → 小端，segment_table 计数严格匹配 page_segments
//     * ID3v2        → 大端，size 为同步安全整数（高 bit 恒 0）
//     * FLAC frame   → 大端，子帧头 + 残差 Rice 码
//     * MP3 frame    → 大端，同步字 0xFFE 之后按规范位序
//   所有 chunk/size 字段**真的算出来**，不是写死的 magic number。
//
// = Ogg CRC 的特殊处理 =
//   `fixture_ogg_page` 会在输出前自行计算并填入**正确的 CRC**（多项式
//   0x04C11DB7，无反射，初值 0，不取反）。因此：
//     * 想测 "CRC 正确 → 通过" → 直接用 `fixture_ogg_page`
//     * 想测 "CRC 错误 → 失败" → 用 `fixture_ogg_page_with_crc(0xDEADBEEF)`
//   独立的 CRC 计算入口是 `fixture_ogg_crc32`，可直接被测试调用做对拍。
//
// = UTF-8 编码为什么自实现 =
//   两条**实测结论**，不要凭直觉改回去：
//     1. `String::to_bytes()` 产出的是 **UTF-16LE**，不是 UTF-8
//        （"Hi" → 48 00 69 00，10 字节而非 2 字节）。它也已被标记 deprecated。
//     2. `moonbitlang/core/encoding/utf8` 在当前 registry 沙箱里
//        显式 import 反而报 "Package encoding/utf8 not found"。
//   所以这里手写一个零依赖、零警告、行为确定的 UTF-8 编码器（含代理对处理），
//   正好满足 fixture 的可复现要求。

// ---------------------------------------------------------------------------
// 内部小工具
// ---------------------------------------------------------------------------

///|
/// 从 `Bytes` 读一个小端整数（`n` 为字节数）。仅供本文件与测试使用。
fn fixture_rd_le(data : Bytes, offset : Int, n : Int) -> Int {
  let mut v = 0
  let mut i = 0
  while i < n {
    v = v | (data[offset + i].to_int() << (8 * i))
    i = i + 1
  }
  v
}

///|
/// 取 `Bytes` 的一段（边界会被夹到合法范围内）。
fn fixture_slice(data : Bytes, start : Int, end : Int) -> Bytes {
  let s = if start < 0 {
    0
  } else if start > data.length() {
    data.length()
  } else {
    start
  }
  let e = if end < s {
    s
  } else if end > data.length() {
    data.length()
  } else {
    end
  }
  data.view(start=s, end=e).to_owned()
}

///|
/// UTF-8 编码（自实现，覆盖 U+0000..U+10FFFF，含代理对）。
///
/// **为什么不用标准库**（两条都是实测结论，别改回去）：
///
/// 1. `String::to_bytes()` 在当前工具链里产出的是 **UTF-16LE**，不是 UTF-8
///    —— `"Hello".to_bytes()` = `48 00 65 00 6C 00 6C 00 6F 00`（10 字节）。
///    用它写 ID3 文本帧或 RIFF INFO，生成的语料本身就是错的。
///    它同时被标记为 deprecated。
/// 2. core 的 `@encoding/utf8.encode` 能隐式解析（只报 `core_package_not_imported` 警告），
///    但显式写进 `moon.pkg` 的 `"moonbitlang/core/encoding/utf8"` 反而解析不到
///    （实测：`Package "encoding/utf8" not found in the loaded packages`）。
///    而 `moon.pkg` 是所有并行代理共用的文件，本文件作者不改它。
///
/// 因此这里自己编码：零依赖、零警告、行为完全确定，正好符合 fixture 的要求。
/// MoonBit 的 `String` 按 UTF-16 码元存储，所以这里显式处理代理对。
fn fixture_utf8(s : String) -> Bytes {
  let out = Buffer()
  let units : Array[Int] = []
  for ch in s {
    units.push(ch.to_int())
  }
  let mut i = 0
  while i < units.length() {
    let u = units[i]
    if u >= 0xD800 && u <= 0xDBFF && i + 1 < units.length() {
      let lo = units[i + 1]
      if lo >= 0xDC00 && lo <= 0xDFFF {
        // 代理对 → 一个补充平面码点 → 4 字节
        let cp = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
        out.write_byte((0xF0 | (cp >> 18)).to_byte())
        out.write_byte((0x80 | ((cp >> 12) & 0x3F)).to_byte())
        out.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
        out.write_byte((0x80 | (cp & 0x3F)).to_byte())
        i = i + 2
        continue
      }
    }
    if u < 0x80 {
      out.write_byte(u.to_byte())
    } else if u < 0x800 {
      out.write_byte((0xC0 | (u >> 6)).to_byte())
      out.write_byte((0x80 | (u & 0x3F)).to_byte())
    } else {
      // 单个代理（非法但可能出现）也按 3 字节走，保持确定性、不 panic
      out.write_byte((0xE0 | (u >> 12)).to_byte())
      out.write_byte((0x80 | ((u >> 6) & 0x3F)).to_byte())
      out.write_byte((0x80 | (u & 0x3F)).to_byte())
    }
    i = i + 1
  }
  out.to_bytes()
}

///|
/// 小端 16 位写入（无符号位模式）。
fn fixture_wr_u16le(buf : Buffer, value : Int) -> Unit {
  buf.write_byte((value & 0xFF).to_byte())
  buf.write_byte(((value >> 8) & 0xFF).to_byte())
}

///|
/// 小端 32 位写入（无符号位模式）。
fn fixture_wr_u32le(buf : Buffer, value : Int) -> Unit {
  buf.write_byte((value & 0xFF).to_byte())
  buf.write_byte(((value >> 8) & 0xFF).to_byte())
  buf.write_byte(((value >> 16) & 0xFF).to_byte())
  buf.write_byte(((value >> 24) & 0xFF).to_byte())
}

///|
/// 大端 24 位写入（无符号位模式）。用于 FLAC 元数据块长度。
fn fixture_wr_u24be(buf : Buffer, value : Int) -> Unit {
  buf.write_byte(((value >> 16) & 0xFF).to_byte())
  buf.write_byte(((value >> 8) & 0xFF).to_byte())
  buf.write_byte((value & 0xFF).to_byte())
}

///|
/// 大端 32 位写入（无符号位模式）。
fn fixture_wr_u32be(buf : Buffer, value : Int) -> Unit {
  buf.write_byte(((value >> 24) & 0xFF).to_byte())
  buf.write_byte(((value >> 16) & 0xFF).to_byte())
  buf.write_byte(((value >> 8) & 0xFF).to_byte())
  buf.write_byte((value & 0xFF).to_byte())
}

///|
/// 就地写入一个小端 32 位整数。用于伪造/修复 chunk size 与 Ogg CRC 字段。
fn fixture_patch_le32(arr : FixedArray[Byte], offset : Int, value : Int) -> Unit {
  arr[offset] = (value & 0xFF).to_byte()
  arr[offset + 1] = ((value >> 8) & 0xFF).to_byte()
  arr[offset + 2] = ((value >> 16) & 0xFF).to_byte()
  arr[offset + 3] = ((value >> 24) & 0xFF).to_byte()
}

///|
/// 把有符号样本夹到 `[-2^(bits-1), 2^(bits-1)-1]`（WAV PCM 的对称取值范围）。
///
/// 这是生成「满量程方波」语料的推荐做法：`±2^(bits-1)` 在二补码里已经越界，
/// 直接取低 `bits` 位会回绕成相反符号（`+32768` → `-32768`），
/// 而真实编码器会**削顶**到 `±(2^(bits-1)-1)`。两者是不同的信号，测试必须明确用哪一种。
/// 公开导出是为了让 `tools/gen_fixtures.py` 的 Python 参考实现与这里保持一致。
pub fn fixture_clamp_signed(value : Int, bits : Int) -> Int {
  let lo = -(1 << (bits - 1))
  let hi = (1 << (bits - 1)) - 1
  if value < lo {
    lo
  } else if value > hi {
    hi
  } else {
    value
  }
}

///|
/// 按位数把一个有符号样本写成 WAV PCM 的字节表示。
/// 8 位 → 无符号（+128）；16 / 24 / 32 位 → 有符号二补码小端，只取低 `bits` 位。
fn fixture_write_sample(buf : Buffer, sample : Int, bits : Int) -> Unit {
  if bits == 8 {
    buf.write_byte((((sample & 0xFF) + 128) & 0xFF).to_byte())
  } else if bits == 16 {
    fixture_wr_u16le(buf, sample & 0xFFFF)
  } else if bits == 24 {
    fixture_wr_u24le(buf, sample & 0xFFFFFF)
  } else if bits == 32 {
    fixture_wr_u32le(buf, sample & 0xFFFFFFFF)
  } else {
    abort("fixture: unsupported WAV bits=\{bits} (expect 8/16/24/32)")
  }
}

///|
/// 小端 24 位写入（无符号位模式）。
fn fixture_wr_u24le(buf : Buffer, value : Int) -> Unit {
  buf.write_byte((value & 0xFF).to_byte())
  buf.write_byte(((value >> 8) & 0xFF).to_byte())
  buf.write_byte(((value >> 16) & 0xFF).to_byte())
}

///|
/// 一个 `bits` 位样本占几个字节。
fn fixture_bytes_per_sample(bits : Int) -> Int {
  if bits == 8 {
    1
  } else if bits == 16 {
    2
  } else if bits == 24 {
    3
  } else if bits == 32 {
    4
  } else {
    abort("fixture: unsupported WAV bits=\{bits} (expect 8/16/24/32)")
  }
}

// ---------------------------------------------------------------------------
// WAV
// ---------------------------------------------------------------------------

///|
/// 合成一个完整的 WAV 文件字节流（显式参数版本，供上面几个便捷函数复用）。
///
/// * `channels` 声道数；`samples` 是**交织**样本（立体声为 `[L0, R0, L1, R1, ...]`）。
/// * `junk` 为 `Some((id, payload))` 时，会在 `fmt ` 与 `data` 之间插入一个 chunk
///   （id 必须是恰好 4 个字节；payload 为奇数长度时自动补 padding）。
/// * `riff_size_delta` 用来故意把 RIFF size 字段写错，供「畸形输入」测试使用。
///
/// 写出的结构固定为：`RIFF` + `fmt ` + `data`（`junk` 存在时插在 `fmt ` 与 `data` 之间）。
pub fn fixture_wav_build(
  sample_rate : Int,
  bits : Int,
  channels : Int,
  samples : Array[Int],
  junk : (Bytes, Bytes)?,
  riff_size_delta : Int,
) -> Bytes {
  let block_align = channels * fixture_bytes_per_sample(bits)
  let byte_rate = sample_rate * block_align
  let pcm = Buffer()
  for s in samples {
    fixture_write_sample(pcm, s, bits)
  }
  let pcm_bytes = pcm.to_bytes()
  let junk_bytes = match junk {
    None => Bytes::new(0)
    Some((id, payload)) => {
      if id.length() != 4 {
        abort("fixture_wav_build: junk chunk id must be exactly 4 bytes")
      }
      let b = Buffer()
      b.write_bytes(id.view())
      fixture_wr_u32le(b, payload.length())
      b.write_bytes(payload.view())
      if payload.length() % 2 == 1 {
        b.write_byte(b'\x00')
      }
      b.to_bytes()
    }
  }
  // RIFF 总大小 = 文件总长度 - 8
  let riff_size = 4 + (8 + 16) + junk_bytes.length() + (8 + pcm_bytes.length()) + riff_size_delta
  if riff_size < 0 || riff_size > 0x7FFFFFFF {
    abort("fixture_wav_build: RIFF size out of range: \{riff_size}")
  }
  let out = Buffer()
  out.write_bytes(b"RIFF".view())
  fixture_wr_u32le(out, riff_size)
  out.write_bytes(b"WAVE".view())
  out.write_bytes(b"fmt ".view())
  fixture_wr_u32le(out, 16) // fmt chunk size
  fixture_wr_u16le(out, 1) // audio format = 1 (PCM)
  fixture_wr_u16le(out, channels)
  fixture_wr_u32le(out, sample_rate)
  fixture_wr_u32le(out, byte_rate)
  fixture_wr_u16le(out, block_align)
  fixture_wr_u16le(out, bits)
  out.write_bytes(junk_bytes.view())
  out.write_bytes(b"data".view())
  fixture_wr_u32le(out, pcm_bytes.length())
  out.write_bytes(pcm_bytes.view())
  out.to_bytes()
}

///|
/// 合成最小合法单声道 WAV：`RIFF/WAVE` + `fmt `(PCM,16) + `data`。
///
/// `bits` 支持 8 / 16 / 24 / 32。8 位按无符号写出（样本 0 → 字节 128）。
pub fn fixture_wav_mono(sample_rate : Int, bits : Int, samples : Array[Int]) -> Bytes {
  fixture_wav_build(sample_rate, bits, 1, samples, None, 0)
}

///|
/// 合成立体声 WAV。`samples` 是**交织**的，即 `[L0, R0, L1, R1, ...]`。
/// 长度为奇数时最后一帧只有左声道（这种畸形输入故意保留给解码器处理）。
pub fn fixture_wav_stereo(sample_rate : Int, bits : Int, samples : Array[Int]) -> Bytes {
  fixture_wav_build(sample_rate, bits, 2, samples, None, 0)
}

///|
/// 合成 WAV，并在 `data` chunk **之前**插入一个大小为 `junk_size` 的未知 chunk
/// （id 为 `"junk"`）。用来测 chunk 跳过逻辑与奇数长度 chunk 的 padding。
///
/// `junk_size` 为奇数时会多写 1 个 padding 字节，而 size 字段仍写 `junk_size`：
/// 解码器必须按「对齐到偶数字节」前进，否则会读错 `data` 的起始位置。
pub fn fixture_wav_with_junk_chunk(
  sample_rate : Int,
  bits : Int,
  samples : Array[Int],
  junk_size : Int,
) -> Bytes {
  if junk_size < 0 {
    abort("fixture_wav_with_junk_chunk: junk_size must be >= 0")
  }
  let payload = Bytes::make(junk_size, b'\xAA')
  fixture_wav_build(sample_rate, bits, 1, samples, Some((b"junk", payload)), 0)
}

///|
/// 合成一个 RIFF size 字段**故意写错**的 WAV（写出的值 = 正确值 + `delta`）。
/// 供「解码器是否信任头部声明」的负向测试使用。
pub fn fixture_wav_bad_riff_size(
  sample_rate : Int,
  bits : Int,
  samples : Array[Int],
  delta : Int,
) -> Bytes {
  fixture_wav_build(sample_rate, bits, 1, samples, None, delta)
}

///|
/// 合成带 `LIST/INFO` 元数据 chunk 的 WAV（插在 `fmt ` 与 `data` 之间）。
/// 每个字段写成一个 `INFO` 子 chunk（`INAM` 标题 / `IART` 艺术家），
/// 值为 **NUL 结尾的 UTF-8**（RIFF INFO 的惯例）。
/// 音频数据固定为 8000 Hz / 16 位 / 单声道 / 3 个样本 `[0, 1, -1]`。
pub fn fixture_wav_with_info(title : String, artist : String) -> Bytes {
  let body = Buffer()
  let fields : Array[(String, String)] = [("INAM", title), ("IART", artist)]
  for pair in fields {
    let (id, value) = pair
    let raw = fixture_utf8(value)
    body.write_bytes(fixture_utf8(id).view())
    fixture_wr_u32le(body, raw.length() + 1) // +1：NUL 结尾
    body.write_bytes(raw.view())
    body.write_byte(b'\x00')
    if (raw.length() + 1) % 2 == 1 {
      body.write_byte(b'\x00') // 子 chunk padding
    }
  }
  let info = body.to_bytes()
  let list = Buffer()
  list.write_bytes(b"LIST".view())
  fixture_wr_u32le(list, 4 + info.length())
  list.write_bytes(b"INFO".view())
  list.write_bytes(info.view())
  let samples : Array[Int] = [0, 1, -1]
  fixture_wav_build(8000, 16, 1, samples, Some((b"LIST", list.to_bytes())), 0)
}

///|
/// 在已有 WAV 里把 `data` chunk 的 size 字段改成 `claimed_size`（字节数），
/// 但实际 payload 长度不变。用来测解码器是看声明长度还是看实际可用字节。
/// 找不到 `data` chunk 时原样返回。
pub fn fixture_wav_patch_data_size(wav : Bytes, claimed_size : Int) -> Bytes {
  let arr = wav.to_fixedarray()
  let mut pos = 12
  while pos + 8 <= arr.length() {
    let id = Bytes::from_array(arr[pos:pos + 4].view())
    let size = fixture_rd_le(wav, pos + 4, 4)
    if Bytes::equal(id, b"data") {
      fixture_patch_le32(arr, pos + 4, claimed_size)
      break
    }
    pos = pos + 8 + size + size % 2
  }
  Bytes::from_array(arr.view())
}

// ---------------------------------------------------------------------------
// Ogg
// ---------------------------------------------------------------------------

///|
/// Ogg CRC32：多项式 `0x04C11DB7`，无反射，初值 0，结果不取反。
/// 与 CONTRACT.md 中 `ogg_crc32` 的约定一致（注意：**不是** zlib 的 CRC32）。
///
/// 计算范围是**整个 page**（从 `"OggS"` 开始到 body 结尾），其中校验和字段自身按 0 参与。
pub fn fixture_ogg_crc32(data : Bytes) -> Int {
  let table : Array[Int] = []
  let mut i = 0
  while i < 256 {
    let mut r = i << 24
    let mut j = 0
    while j < 8 {
      if (r & 0x80000000) != 0 {
        r = ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
      } else {
        r = (r << 1) & 0xFFFFFFFF
      }
      j = j + 1
    }
    table.push(r)
    i = i + 1
  }
  let mut crc = 0
  for byte in data {
    let idx = ((crc >> 24) ^ byte.to_int()) & 0xFF
    crc = ((crc << 8) & 0xFFFFFFFF) ^ table[idx]
  }
  crc
}

///|
/// 合成一个 Ogg page，**自动填入正确的 CRC**。
///
/// * `segments` 是 lacing 表（每个元素 0..255，最多 255 项）。
///   `body` 的长度必须等于 `segments` 之和，否则直接 `abort`
///   —— 语料本身构造错误应该在建语料时就炸掉，而不是留给解码器。
/// * `granule` 按有符号 64 位小端写入（`-1` 表示 "no packet finishes on this page"）。
/// * `header_type` 位标志：0x01 续包、0x02 BOS、0x04 EOS。
///
/// 生成的 page 总长度 = 27 + `segments.length()` + `body.length()`。
pub fn fixture_ogg_page(
  serial : Int,
  sequence : Int,
  granule : Int64,
  header_type : Int,
  segments : Array[Int],
  body : Bytes,
) -> Bytes {
  let mut total = 0
  for s in segments {
    if s < 0 || s > 255 {
      abort("fixture_ogg_page: lacing value out of range: \{s}")
    }
    total = total + s
  }
  if total != body.length() {
    abort("fixture_ogg_page: lacing sum \{total} != body length \{body.length()}")
  }
  if segments.length() > 255 {
    abort("fixture_ogg_page: at most 255 lacing values per page")
  }
  let out = Buffer()
  out.write_bytes(b"OggS".view())
  out.write_byte(b'\x00') // stream structure version
  out.write_byte(header_type.to_byte())
  out.write_int64_le(granule) // granule position，有符号
  out.write_uint_le(serial.reinterpret_as_uint())
  out.write_uint_le(sequence.reinterpret_as_uint())
  out.write_uint_le(0) // checksum 占位，下面回填
  out.write_byte(segments.length().to_byte())
  for s in segments {
    out.write_byte(s.to_byte())
  }
  out.write_bytes(body.view())
  let arr = out.to_bytes().to_fixedarray()
  let crc = fixture_ogg_crc32(Bytes::from_array(arr.view()))
  fixture_patch_le32(arr, 22, crc)
  Bytes::from_array(arr.view())
}

///|
/// 同 `fixture_ogg_page`，但校验和字段写死成 `crc`。
/// 用于构造「CRC 故意错误」的 page，测试 `ChecksumMismatch` 分支。
pub fn fixture_ogg_page_with_crc(
  serial : Int,
  sequence : Int,
  granule : Int64,
  header_type : Int,
  segments : Array[Int],
  body : Bytes,
  crc : Int,
) -> Bytes {
  let page = fixture_ogg_page(serial, sequence, granule, header_type, segments, body)
  let arr = page.to_fixedarray()
  fixture_patch_le32(arr, 22, crc)
  Bytes::from_array(arr.view())
}

// ---------------------------------------------------------------------------
// ID3v2
// ---------------------------------------------------------------------------

///|
/// 同步安全整数编码：把 `n` 的 28 个低位按每字节 7 位写成 4 字节（大端）。
/// ID3v2.4 用这个格式表示标签与帧的长度。
pub fn fixture_syncsafe_bytes(n : Int) -> Bytes {
  if n < 0 || n > 0x0FFFFFFF {
    abort("fixture_syncsafe_bytes: out of 28-bit range: \{n}")
  }
  let arr : FixedArray[Byte] = FixedArray::make(4, b'\x00')
  arr[0] = ((n >> 21) & 0x7F).to_byte()
  arr[1] = ((n >> 14) & 0x7F).to_byte()
  arr[2] = ((n >> 7) & 0x7F).to_byte()
  arr[3] = (n & 0x7F).to_byte()
  Bytes::from_array(arr.view())
}

///|
/// 解码同步安全整数（`fixture_syncsafe_bytes` 的逆）。测试里用来复核。
pub fn fixture_unsyncsafe(data : Bytes) -> Int {
  if data.length() < 4 {
    abort("fixture_unsyncsafe: need 4 bytes, got \{data.length()}")
  }
  ((data[0].to_int() & 0x7F) << 21)
  | ((data[1].to_int() & 0x7F) << 14)
  | ((data[2].to_int() & 0x7F) << 7)
  | (data[3].to_int() & 0x7F)
}

///|
/// 构造一个 ID3v2 文本帧（frame id 恰好 4 字节）。
///
/// * 文本编码字节固定用 `0x03`（UTF-8），因此 `text` 可以放任意 Unicode。
/// * 帧头固定 10 字节，flags 全 0 —— **不使用** unsynchronisation / data length indicator，
///   所以帧大小就是「1 + UTF-8 字节数」。
/// * `syncsafe` 为 `true` 时帧大小用 ID3v2.4 的 syncsafe 编码，否则用 v2.3 的普通大端。
/// * 帧末尾按需补 1 个 `0x00`，让帧体长度为偶数（v2.3 的常见做法）。
fn fixture_id3_frame(id : String, text : String, syncsafe : Bool) -> Bytes {
  let id_bytes = fixture_utf8(id)
  if id_bytes.length() != 4 {
    abort("fixture_id3_frame: frame id must be 4 ASCII bytes, got \"\{id}\"")
  }
  let body = Buffer()
  body.write_byte(b'\x03') // UTF-8
  body.write_bytes(fixture_utf8(text).view())
  if body.length() % 2 == 1 {
    body.write_byte(b'\x00')
  }
  let payload = body.to_bytes()
  let out = Buffer()
  out.write_bytes(id_bytes.view())
  if syncsafe {
    out.write_bytes(fixture_syncsafe_bytes(payload.length()).view())
  } else {
    fixture_wr_u32be(out, payload.length())
  }
  out.write_byte(b'\x00') // frame flags (hi)
  out.write_byte(b'\x00') // frame flags (lo)
  out.write_bytes(payload.view())
  out.to_bytes()
}

///|
/// 拼出 ID3v2 标签本体：`"ID3"` + version + revision + flags(0) + syncsafe(size) + 帧区。
/// `size` = 帧区总字节数（v2.3 与 v2.4 都用 syncsafe 表示标签大小）。
fn fixture_id3_tag(version : Int, frames : Array[Bytes]) -> Bytes {
  let body = Buffer()
  for f in frames {
    body.write_bytes(f.view())
  }
  let frames_bytes = body.to_bytes()
  let out = Buffer()
  out.write_bytes(b"ID3".view())
  out.write_byte(version.to_byte())
  out.write_byte(b'\x00') // revision
  out.write_byte(b'\x00') // flags：无 unsynchronisation、无扩展头、无 footer
  out.write_bytes(fixture_syncsafe_bytes(frames_bytes.length()).view())
  out.write_bytes(frames_bytes.view())
  out.to_bytes()
}

///|
/// 合成 ID3v2.3 标签：`TIT2` = title，`TPE1` = artist。
/// 帧大小用普通 32 位大端（v2.3 语义），标签大小用 syncsafe。
pub fn fixture_id3v23(title : String, artist : String) -> Bytes {
  fixture_id3_tag(3, [
    fixture_id3_frame("TIT2", title, false),
    fixture_id3_frame("TPE1", artist, false),
  ])
}

///|
/// 合成 ID3v2.4 标签：`TIT2` = title，`TPE1` = artist。
/// 帧大小与标签大小**都用** syncsafe（v2.4 语义）。
pub fn fixture_id3v24(title : String, artist : String) -> Bytes {
  fixture_id3_tag(4, [
    fixture_id3_frame("TIT2", title, true),
    fixture_id3_frame("TPE1", artist, true),
  ])
}

// ---------------------------------------------------------------------------
// 伪随机 / 边界
// ---------------------------------------------------------------------------

///|
/// 确定性伪随机字节（LCG：`state = state * 1103515245 + 12345`，取第 16..23 位）。
///
/// **不使用任何随机数库、不读时间、不读系统状态**：同样的 `(len, seed)` 永远得到同样的字节。
/// 实现与 `tools/gen_fixtures.py` 中的 `lcg_bytes()` 逐字节一致，两侧可以互相对拍。
pub fn fixture_pseudo_random(len : Int, seed : Int) -> Bytes {
  if len < 0 {
    abort("fixture_pseudo_random: len must be >= 0")
  }
  // Bytes 不可变：先在 FixedArray 里生成，再一次性转成 Bytes。
  let arr : FixedArray[Byte] = FixedArray::make(len, b'\x00')
  let mut state = seed & 0xFFFFFFFF
  let mut i = 0
  while i < len {
    state = (state * 1103515245 + 12345) & 0xFFFFFFFF
    arr[i] = ((state >> 16) & 0xFF).to_byte()
    i = i + 1
  }
  Bytes::from_array(arr.view())
}

///|
/// 取 `prefix` 的前 `cut_at` 个字节，模拟被截断的输入。
/// `cut_at` 会被夹到 `[0, prefix.length()]`。
pub fn fixture_truncated(prefix : Bytes, cut_at : Int) -> Bytes {
  fixture_slice(prefix, 0, cut_at)
}

///|
/// 0 字节输入。
pub fn fixture_empty() -> Bytes {
  Bytes::new(0)
}

///|
/// 单个字节的输入。
pub fn fixture_single_byte(b : Byte) -> Bytes {
  let arr : FixedArray[Byte] = FixedArray::make(1, b)
  arr[0] = b
  Bytes::from_array(arr.view())
}

///|
/// 只有魔数、后面什么都没有的输入，用于测「头部之后立刻截断」。
pub fn fixture_magic_only() -> Array[Bytes] {
  [b"RIFF", b"fLaC", b"OggS", b"ID3", b"\xFF\xFB"]
}

// ---------------------------------------------------------------------------
// FLAC（metadata 层）
// ---------------------------------------------------------------------------

///|
/// 合成 `fLaC` 标记 + 一个 STREAMINFO 元数据块（payload 恰好 34 字节）。
/// **不含音频帧** —— 只够 `parse_flac_metadata` / `flac_info`，不足以 `decode_flac`。
///
/// STREAMINFO 位域按 FLAC 规范打包：
/// `min_block(16) max_block(16) min_frame(24) max_frame(24) sample_rate(20) channels-1(3)
///  bits-1(5) total_samples(36) md5(128)`。MD5 全 0 表示「未计算」。
fn fixture_flac_streaminfo(
  sample_rate : Int,
  channels : Int,
  bits : Int,
  total_samples : Int64,
  last : Bool,
) -> Bytes {
  let body = Buffer()
  body.write_uint16_be(4096) // min block size
  body.write_uint16_be(4096) // max block size
  fixture_wr_u24be(body, 0) // min frame size = 0（未知）
  fixture_wr_u24be(body, 0) // max frame size = 0（未知）
  // sample_rate(20) | channels-1(3) | bits-1 的高 1 位
  fixture_wr_u24be(
    body,
    ((sample_rate & 0xFFFFF) << 4)
    | (((channels - 1) & 0x07) << 1)
    | (((bits - 1) >> 4) & 0x01),
  )
  // bits-1 的低 4 位 | total_samples 的高 4 位
  let total_lo = (total_samples & 0xFFFFFFFFL).to_int()
  let total_hi = ((total_samples >> 32) & 0x0FL).to_int()
  body.write_byte(((((bits - 1) & 0x0F) << 4) | total_hi).to_byte())
  fixture_wr_u32be(body, total_lo)
  for _ in 0..<16 {
    body.write_byte(b'\x00') // MD5 = 全 0
  }
  let payload = body.to_bytes()
  let header = Buffer()
  header.write_byte(if last { b'\x80' } else { b'\x00' }) // last 标志 | 类型 0
  fixture_wr_u24be(header, payload.length())
  b"fLaC" + header.to_bytes() + payload
}

///|
/// 合成一个 Vorbis comment 块体（不含 FLAC 块头）：
/// `vendor_len(u32le) vendor comment_count(u32le) [len(u32le) "KEY=VALUE"]*`。
/// FLAC 的 VORBIS_COMMENT 块就是小端版的 Vorbis comment，与 Ogg 里的一致。
fn fixture_vorbis_comment_body(comments : Array[(String, String)]) -> Bytes {
  let vendor = b"moonaudio-fixture"
  let buf = Buffer()
  fixture_wr_u32le(buf, vendor.length())
  buf.write_bytes(vendor.view())
  fixture_wr_u32le(buf, comments.length())
  for pair in comments {
    let (k, v) = pair
    let entry = fixture_utf8("\{k}=\{v}")
    fixture_wr_u32le(buf, entry.length())
    buf.write_bytes(entry.view())
  }
  buf.to_bytes()
}

///|
/// 构造一个 FLAC 元数据块（4 字节块头 + payload）。
/// `last` 决定块头最高位；`block_type` 是 0..126 的类型号。长度由 payload 算出。
pub fn fixture_flac_block(last : Bool, block_type : Int, payload : Bytes) -> Bytes {
  if block_type < 0 || block_type > 126 {
    abort("fixture_flac_block: block_type out of range: \{block_type}")
  }
  let header = Buffer()
  header.write_byte(((if last { 0x80 } else { 0x00 }) | block_type).to_byte())
  fixture_wr_u24be(header, payload.length())
  header.to_bytes() + payload
}

///|
/// 合成只有 `fLaC` + STREAMINFO 的 FLAC 头（**无音频帧**）。
/// 足够 `parse_flac_metadata` / `flac_info`；`decode_flac` 应因无帧而失败或返回空。
pub fn fixture_flac_header_only(
  sample_rate : Int,
  channels : Int,
  bits : Int,
  total_samples : Int64,
) -> Bytes {
  fixture_flac_streaminfo(sample_rate, channels, bits, total_samples, true)
}

///|
/// 合成 `fLaC` + STREAMINFO + VORBIS_COMMENT（**无音频帧**）。
/// 用于测 FLAC 标签解析路径。
pub fn fixture_flac_with_comment(
  sample_rate : Int,
  channels : Int,
  bits : Int,
  total_samples : Int64,
  comments : Array[(String, String)],
) -> Bytes {
  let info = fixture_flac_streaminfo(sample_rate, channels, bits, total_samples, false)
  let comment = fixture_flac_block(true, 4, fixture_vorbis_comment_body(comments))
  info + comment
}

// ---------------------------------------------------------------------------
// MP3（仅供测 ID3 跳过 / 帧同步的合成输入）
// ---------------------------------------------------------------------------

///|
/// 合成一个 MPEG-1 Layer III 帧头（4 字节）：`0xFF 0xFB 0x90 0x00`
/// = MPEG-1、Layer III、无 CRC、128 kbps、44100 Hz、无 padding、joint stereo。
/// **只有帧头，没有帧数据** —— 不能拿来测真正的解码结果。
pub fn fixture_mp3_frame_header() -> Bytes {
  b"\xFF\xFB\x90\x00"
}

///|
/// 合成「ID3v2.3 标签 + 帧头 + 任意 payload」形状的 MP3 输入。
/// 用来测解码器是否正确地跳过 ID3v2 区域再找帧同步，不代表音频内容合法。
pub fn fixture_mp3_with_id3(title : String, artist : String, payload : Bytes) -> Bytes {
  fixture_id3v23(title, artist) + fixture_mp3_frame_header() + payload
}
