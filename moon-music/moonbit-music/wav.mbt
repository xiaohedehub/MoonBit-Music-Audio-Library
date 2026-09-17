// moonbit-music —— WAV (RIFF/WAVE) 解码器。
//
// 只用 moonbitlang/core，不 import 包内其他实现文件，本文件自带所需的小端字节
// 读取函数。为避免与并行开发的其它文件重名，所有内部辅助函数/类型一律带
// `wav_` / `Wav` 前缀。
//
// 支持范围（见 CONTRACT.md）：
//   * RIFF/WAVE 容器，小端字节序；chunk 头 8 字节；chunk 之间 2 字节对齐；
//   * `fmt ` 的 PCM (tag 1) / IEEE float (tag 3) / WAVE_FORMAT_EXTENSIBLE (0xFFFE)；
//   * 位深 8（无符号）/ 16 / 24 / 32（有符号小端），以及 32 位 float32；
//   * `LIST` / `fact` / `JUNK` 等未知 chunk 一律跳过，不报错；
//   * `fmt ` 的 size 大于 16 时跳过多余字节（extensible 走 cbSize 之后的 SubFormat）。
//
// 越界一律抛 `AudioError::Truncated`，绝不 panic；不认识的格式抛 `Unsupported`。

///|
/// RIFF chunk 遍历结果（测试与调试用）。
///
/// * `id`：chunk 的 4 字节 id。全部是可打印 ASCII 时原样返回；含其它字节时
///   逐字节转义成 `\xNN`，保证结果一定是合法 UTF-8 字符串。
/// * `offset`：chunk 头（4 字节 id 的第一个字节）在输入中的偏移。
/// * `size`：chunk 自己声明的数据字节数，不含 8 字节头，也不含奇数长度后面的
///   padding 字节。若声明值 >= 2^31（畸形的 u32），这里会是负数。
pub(all) struct RiffChunk {
  id : String
  offset : Int
  size : Int
} derive(@debug.Debug)

///|
/// 解析 WAV 并解码为交织 PCM。
///
/// * 交织顺序为 `[L0, R0, L1, R1, ...]`；
/// * 样本范围是 `[-2^(bits-1), 2^(bits-1)-1]`；8 位 WAV 是无符号的，已减 128；
/// * `data` chunk 声明的大小超过实际可用字节（截断文件）时**不报错**：按完整帧
///   尽量解码，末尾不足一帧的零头字节直接丢弃；
/// * 找不到 `fmt ` 或 `data` chunk 抛 `Truncated`；
/// * `tags` 恒为空数组（WAV 的 LIST/INFO 标签不在本模块范围内）。
pub fn decode_wav(data : Bytes) -> Audio raise AudioError {
  let chunks = riff_chunks(data)
  let spec = wav_spec_of(data, chunks)
  let format : AudioFormat = {
    sample_rate: spec.sample_rate,
    channels: spec.channels,
    bits_per_sample: spec.bits_per_sample,
  }
  let data_chunk = match wav_find_chunk(chunks, "data") {
    Some(chunk) => chunk
    None =>
      raise AudioError::Truncated(offset=data.length(), needed=8, available=0)
  }
  let payload = data_chunk.offset + 8
  let available = wav_bytes_available(data, payload)
  // 声明大小越界（含畸形的负值）时按实际可用字节解，这是「截断文件」的策略。
  let usable = if data_chunk.size < 0 || data_chunk.size > available {
    available
  } else {
    data_chunk.size
  }
  let bytes_per_sample = spec.bits_per_sample / 8
  let frame_bytes = spec.channels * bytes_per_sample
  let frames = usable / frame_bytes
  let samples : Array[Int] = Array::make(frames * spec.channels, 0)
  let mut index = 0
  for f = 0; f < frames; f = f + 1 {
    let frame_start = payload + f * frame_bytes
    for c = 0; c < spec.channels; c = c + 1 {
      samples[index] = wav_read_sample(
        data,
        frame_start + c * bytes_per_sample,
        spec,
      )
      index = index + 1
    }
  }
  { format, samples, tags: [], }
}

///|
/// 只解析头部，不解码数据。
///
/// 只要求存在合法的 `fmt ` chunk：`data` chunk 缺失或内容被截断都不影响本函数。
/// 与 `decode_wav` 共用同一条解析路径，因此 `wav_info(d) == decode_wav(d).format`
/// 对任何 `decode_wav` 能成功的输入都成立。
pub fn wav_info(data : Bytes) -> AudioFormat raise AudioError {
  let spec = wav_spec_of(data, riff_chunks(data))
  {
    sample_rate: spec.sample_rate,
    channels: spec.channels,
    bits_per_sample: spec.bits_per_sample,
  }
}

///|
/// 遍历 RIFF/WAVE 容器的子 chunk（不包含顶层的 `RIFF` 头本身）。
///
/// * 从偏移 12 开始（`RIFF` + u32 总长度 + `WAVE`）；
/// * 步进 `8 + size + (size & 1)`：奇数长度的 chunk 后面有 1 个 padding 字节；
/// * 忽略 `RIFF` 头里的 u32 总长度字段（写码器常常写错，按实际字节走更稳）；
/// * 末尾不足 8 字节的零头直接忽略；
/// * 某个 chunk 声明的大小越过缓冲区末尾（截断文件）时，仍然把它记进结果，
///   然后停止遍历——这样 `decode_wav` 还能拿到那个被截断的 `data` chunk；
/// * `RIFF` 魔数或 `WAVE` 标识不对抛 `InvalidMagic`，长度不足抛 `Truncated`。
pub fn riff_chunks(data : Bytes) -> Array[RiffChunk] raise AudioError {
  if data.length() < 4 {
    raise AudioError::Truncated(offset=0, needed=4, available=data.length())
  }
  if !(data[0] == b'R' && data[1] == b'I' && data[2] == b'F' && data[3] == b'F') {
    raise AudioError::InvalidMagic("WAV: 前 4 字节不是 \"RIFF\"")
  }
  if data.length() < 12 {
    raise AudioError::Truncated(offset=4, needed=8, available=data.length() - 4)
  }
  if !(data[8] == b'W' &&
    data[9] == b'A' &&
    data[10] == b'V' &&
    data[11] == b'E') {
    raise AudioError::InvalidMagic("WAV: RIFF 容器类型不是 \"WAVE\"")
  }
  let chunks : Array[RiffChunk] = []
  let length = data.length()
  let mut pos = 12
  while pos + 8 <= length {
    let id = wav_chunk_id(data, pos)
    let size = wav_read_u32_le(data, pos + 4)
    chunks.push({ id, offset: pos, size, })
    if size < 0 || pos + 8 + size > length {
      break
    }
    pos = pos + 8 + size + (size & 1)
  }
  chunks
}

///|
/// `fmt ` chunk 的解析结果（包内私有，不导出）。
priv struct WavFmtSpec {
  sample_rate : Int
  channels : Int
  bits_per_sample : Int
  // 样本是 IEEE float（true）还是整数 PCM（false）。
  is_float : Bool
}

///|
/// 找到并解析 `fmt ` chunk；`decode_wav` 与 `wav_info` 共用，保证两者格式一致。
fn wav_spec_of(
  data : Bytes,
  chunks : Array[RiffChunk],
) -> WavFmtSpec raise AudioError {
  match wav_find_chunk(chunks, "fmt ") {
    Some(chunk) => wav_parse_fmt(data, chunk)
    None =>
      raise AudioError::Truncated(offset=data.length(), needed=8, available=0)
  }
}

///|
/// 在 chunk 列表里按 id 找第一个匹配项（`fmt ` 的 id 带一个尾空格）。
fn wav_find_chunk(chunks : Array[RiffChunk], id : String) -> RiffChunk? {
  for chunk in chunks {
    if chunk.id == id {
      return Some(chunk)
    }
  }
  None
}

///|
/// 解析 `fmt ` chunk。
///
/// * PCM (1) / IEEE float (3) 直接看 wFormatTag；
/// * WAVE_FORMAT_EXTENSIBLE (0xFFFE)：先读 `cbSize`，再读它后面 SubFormat GUID 的
///   前两个字节（即 GUID Data1 的低 16 位），1 是 PCM、3 是 float，其它抛 `Unsupported`；
/// * `wValidBitsPerSample` 与 `dwChannelMask` 被忽略：样本按容器位深
///   `wBitsPerSample` 解读，`AudioFormat.bits_per_sample` 也报告容器位深；
/// * `channels == 0`（或 > 65535）抛 `InvalidMagic`；
/// * 位深不是 8/16/24/32（float 只允许 32）抛 `Unsupported`。
fn wav_parse_fmt(
  data : Bytes,
  chunk : RiffChunk,
) -> WavFmtSpec raise AudioError {
  let base = chunk.offset + 8
  let available = wav_bytes_available(data, base)
  // 声明大小是畸形的 u32（>= 2^31）时，按实际可用字节处理。
  let declared = if chunk.size < 0 { available } else { chunk.size }
  if declared < 16 {
    raise AudioError::Truncated(offset=base, needed=16, available=declared)
  }
  wav_require(data, base, 16)
  let tag = wav_read_u16_le(data, base)
  let channels = wav_read_u16_le(data, base + 2)
  let sample_rate = wav_read_u32_le(data, base + 4)
  let bits = wav_read_u16_le(data, base + 14)
  if channels == 0 || channels > 65535 {
    raise AudioError::InvalidMagic("WAV: 声道数非法（\{channels}）")
  }
  let mut is_float = false
  if tag == 1 {
    is_float = false
  } else if tag == 3 {
    is_float = true
  } else if tag == 0xFFFE {
    // WAVE_FORMAT_EXTENSIBLE：18 字节固定部分 + cbSize(22) + GUID(16) = 40 字节起。
    if declared < 40 {
      raise AudioError::Truncated(offset=base, needed=40, available=declared)
    }
    wav_require(data, base, 40)
    let cbsize = wav_read_u16_le(data, base + 16)
    if cbsize < 22 {
      raise AudioError::Unsupported(
        "WAV: WAVE_FORMAT_EXTENSIBLE 的 cbSize=\{cbsize}（应 >= 22，否则没有 SubFormat）",
      )
    }
    let sub_format = wav_read_u16_le(data, base + 24)
    if sub_format == 1 {
      is_float = false
    } else if sub_format == 3 {
      is_float = true
    } else {
      raise AudioError::Unsupported(
        "WAV: 不支持的 WAVE_FORMAT_EXTENSIBLE 子格式 tag \{sub_format}",
      )
    }
  } else {
    raise AudioError::Unsupported("WAV: 不支持的 format tag \{tag}")
  }
  if is_float {
    if bits != 32 {
      raise AudioError::Unsupported(
        "WAV: 只支持 32 位 IEEE float，声明为 \{bits} 位",
      )
    }
  } else if !(bits == 8 || bits == 16 || bits == 24 || bits == 32) {
    raise AudioError::Unsupported("WAV: 不支持的 PCM 位深 \{bits}")
  }
  { sample_rate, channels, bits_per_sample: bits, is_float, }
}

///|
/// 读一个样本，返回 `[-2^(bits-1), 2^(bits-1)-1]` 范围内的 Int。
///
/// 8 位 WAV 是无符号，减 128 转有符号；16/24/32 位是有符号小端，需要符号扩展；
/// float32 按 `[-1, 1] -> [-2^31, 2^31-1]` 映射。
fn wav_read_sample(
  data : Bytes,
  offset : Int,
  spec : WavFmtSpec,
) -> Int raise AudioError {
  if spec.is_float {
    wav_float32_bits_to_int(wav_read_u32_le(data, offset))
  } else if spec.bits_per_sample == 8 {
    wav_read_u8(data, offset) - 128
  } else if spec.bits_per_sample == 16 {
    wav_sign_extend(wav_read_u16_le(data, offset), 16)
  } else if spec.bits_per_sample == 24 {
    let raw = wav_read_u8(data, offset) |
      (wav_read_u8(data, offset + 1) << 8) |
      (wav_read_u8(data, offset + 2) << 16)
    wav_sign_extend(raw, 24)
  } else {
    // 32 位有符号整数：二补码位模式当成 Int 读出来就是样本值本身。
    wav_read_u32_le(data, offset)
  }
}

///|
/// 把 IEEE-754 binary32 的位模式转成 32 位有符号整数样本。
///
/// 名义范围 `[-1, 1]` 线性映射到 `[-2^31, 2^31-1]`（乘 2^31 后四舍五入），
/// 超出范围的（含 ±Inf）截断到端点，NaN 记为 0。
///
/// 这里用整数 + Double 手工还原，不依赖 `Float` 类型的任何方法：本包只 import 了
/// `moonbitlang/core/debug`，`Float` 的 `to_double` 等方法不在可见范围内。
fn wav_float32_bits_to_int(bits : Int) -> Int {
  let sign = (bits >> 31) & 1
  let exponent = (bits >> 23) & 0xFF
  let mantissa = bits & 0x7FFFFF
  if exponent == 0xFF {
    if mantissa != 0 {
      0 // NaN
    } else if sign == 1 {
      -2147483647 - 1 // -Inf -> Int::MIN
    } else {
      2147483647 // +Inf -> Int::MAX
    }
  } else if exponent == 0 && mantissa == 0 {
    0 // ±0
  } else {
    // 有限值：binary32 的每个有限值都能被 binary64 精确表示，所以下面没有舍入误差。
    let significand = if exponent == 0 {
      mantissa.to_double() // 非规格化数，没有隐含的 1
    } else {
      (mantissa + 0x800000).to_double() // 补上隐含的最高位 1
    }
    let scale = if exponent == 0 { -149 } else { exponent - 150 }
    let magnitude = significand * wav_pow2(scale)
    let value = if sign == 1 { -magnitude } else { magnitude }
    let scaled = (value * 2147483648.0).round()
    if scaled >= 2147483647.0 {
      2147483647
    } else if scaled <= -2147483648.0 {
      -2147483647 - 1
    } else {
      scaled.to_int()
    }
  }
}

///|
/// 2 的 `k` 次幂（`k` 可为负），二进制快速幂，全程 Double 精确无舍入。
///
/// `k` 的取值范围由 float32 的指数域决定：规格化时是 `[-149, 104]`，非规格化
/// 固定 `-149`，都在 Double 的表示范围内。
fn wav_pow2(k : Int) -> Double {
  let mut e = if k < 0 { -k } else { k }
  let mut base = 2.0
  let mut result = 1.0
  while e > 0 {
    if (e & 1) == 1 {
      result = result * base
    }
    base = base * base
    e = e >> 1
  }
  if k < 0 {
    1.0 / result
  } else {
    result
  }
}

///|
/// 把低 `bits` 位的无符号值按二补码符号扩展成 Int。
fn wav_sign_extend(value : Int, bits : Int) -> Int {
  let half = 1 << (bits - 1)
  if value >= half {
    value - (half << 1)
  } else {
    value
  }
}

///|
/// `data[offset..]` 还剩多少字节；`offset` 越界或为负时返回 0。
fn wav_bytes_available(data : Bytes, offset : Int) -> Int {
  let length = data.length()
  if offset < 0 || offset >= length {
    0
  } else {
    length - offset
  }
}

///|
/// 越界检查：要求 `data[offset .. offset+needed)` 全部存在，否则抛 `Truncated`。
fn wav_require(
  data : Bytes,
  offset : Int,
  needed : Int,
) -> Unit raise AudioError {
  if offset < 0 || needed < 0 || offset + needed > data.length() {
    raise AudioError::Truncated(
      offset~,
      needed~,
      available=wav_bytes_available(data, offset),
    )
  }
}

///|
/// 读 1 字节，返回 0..255。
fn wav_read_u8(data : Bytes, offset : Int) -> Int raise AudioError {
  wav_require(data, offset, 1)
  data[offset].to_int()
}

///|
/// 读 16 位小端无符号整数，返回 0..65535。
fn wav_read_u16_le(data : Bytes, offset : Int) -> Int raise AudioError {
  wav_require(data, offset, 2)
  data[offset].to_int() | (data[offset + 1].to_int() << 8)
}

///|
/// 读 32 位小端整数，返回该 32 位位模式按二补码解释的 Int。
///
/// 最高位是 1 时结果是负数（等价于同一个 u32 减 2^32），调用方按需自行加掩码。
/// 拼字节时先把最高字节转成有符号，避免 `u8 << 24` 在 32 位 Int 上溢出。
fn wav_read_u32_le(data : Bytes, offset : Int) -> Int raise AudioError {
  wav_require(data, offset, 4)
  let high_byte = data[offset + 3].to_int()
  let high = if high_byte >= 0x80 { high_byte - 0x100 } else { high_byte }
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (high << 24)
}

///|
/// 取 4 字节 chunk id，转成字符串；非可打印 ASCII 的字节转义成 `\xNN`。
///
/// 用 `String::from_array` 逐字符拼，不用 `Bytes::to_unchecked_string`：
/// 后者按 UTF-16LE 解释字节（`length` 的单位是字节而不是字符），对 ASCII
/// 会把两个字节错并成一个字符。
fn wav_chunk_id(data : Bytes, offset : Int) -> String {
  let chars : Array[Char] = []
  for i = 0; i < 4; i = i + 1 {
    let value = data[offset + i].to_int()
    if value >= 0x20 && value < 0x7F {
      chars.push(value.to_byte().to_char())
    } else {
      chars.push('\\')
      chars.push('x')
      chars.push(wav_hex_digit(value >> 4))
      chars.push(wav_hex_digit(value & 0x0F))
    }
  }
  String::from_array(chars[:])
}

///|
/// 0..15 转小写十六进制字符。
fn wav_hex_digit(value : Int) -> Char {
  if value < 10 {
    (0x30 + value).to_byte().to_char()
  } else {
    (0x57 + value).to_byte().to_char()
  }
}
