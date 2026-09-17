// moonbit-music —— PCM 工具函数：位深对齐、声道转换、幅度与比较
//
// 本文件与同目录的 pcm_test.mbt 由同一代理独占，其他代理不要改动。
//
// 集成须知 —— 其他模块依赖的确切移位/舍入语义（不要凭直觉假设）：
//
//   u8_to_signed(v)      = v - 128
//   signed_to_u8(v)      = clamp(v + 128, 0, 255)     // 饱和，不取模
//   scale_to_full_range(sample, bits)
//                        = sample << (32 - bits)       // Int64 中转后截断低 32 位
//                          bits <= 0 或 bits >= 32 时原样返回（不移位）
//   convert_bit_depth(sample, from_bits, to_bits)
//                        变宽：sample << (to_bits - from_bits)
//                        变窄：sample >> (from_bits - to_bits)，**算术右移**
//                              （向负无穷取整，floor；-1 >> 8 == -1，-300 >> 8 == -2）
//                        等宽：原样返回
//                        全程不做舍入、不做抖动、不做钳制
//   convert_channels 2->1：(l + r) >> 1，同样是算术右移（floor），Int64 求和防溢出
//
// 场景化理解：以上全部是 "把样本当作定点小数、保持高位比特" 的语义，
// 等价于 C 里对 int32_t 的 `<<` / `>>`（gcc/clang 的算术右移）。

///|
/// 8 位无符号样本转有符号：`v - 128`。
///
/// WAV 的 8-bit PCM 是无符号的，库内统一用有符号表示，因此需要这个平移。
/// 与 `signed_to_u8` 在 `-128..127` 范围内互逆。
///
/// 输入不做钳制：调用方需保证 `v` 落在 `0..255`。
pub fn u8_to_signed(v : Int) -> Int {
  v - 128
}

///|
/// 有符号样本转 8 位无符号：`v + 128`，并**钳制**（饱和）到 `0..255`。
///
/// 超出 `-128..127` 的输入被夹到端点，而不是取模回绕——后者会让一个正向
/// 削波样本突然变成满量程负样本，听感上是爆音。
pub fn signed_to_u8(v : Int) -> Int {
  let u = v + 128
  if u < 0 {
    0
  } else if u > 255 {
    255
  } else {
    u
  }
}

///|
/// 把 `bits` 位有符号样本左移对齐到 32 位满量程。
///
/// FLAC 子帧的位宽可以是 4..32 之间的任意值，解码后要统一到同一条时间轴上。
/// 返回 `sample << (32 - bits)`：
///
/// - 移位在 `Int64` 中进行，最后用 `Int64::to_int`（`%i64_to_i32`）截断到低 32 位。
/// - 合法输入（`sample` 落在 `[-2^(bits-1), 2^(bits-1)-1]`）左移后恰好填满 32 位，
///   不会有任何比特丢失：`-2^(bits-1) << (32-bits) == Int::min_value`。
/// - `bits <= 0` 或 `bits >= 32` 时不做移位，原样返回（`bits == 32` 是恒等映射）。
pub fn scale_to_full_range(sample : Int, bits : Int) -> Int {
  if bits <= 0 || bits >= 32 {
    return sample
  }
  (sample.to_int64() << (32 - bits)).to_int()
}

///|
/// 位深转换：`from_bits` 位的有符号样本转成 `to_bits` 位的有符号样本。
///
/// 语义（确定、无舍入）：
///
/// - `to_bits == from_bits`：原样返回。
/// - 变宽（`to_bits > from_bits`）：左移 `to_bits - from_bits` 位，低比特补 0。
///   这样 8→16 的 `127` 得 `32512`，与 `scale_to_full_range` 同一套定点语义。
/// - 变窄（`to_bits < from_bits`）：**算术**右移 `from_bits - to_bits` 位，
///   即向负无穷取整（floor）。关键边界：`-1 >> 8 == -1`、`-300 >> 8 == -2`、
///   `32767 >> 8 == 127`。**不是**向零截断，也不是四舍五入。
/// - 不做钳制、不做抖动（dithering）、不做溢出检查。
///
/// 移位量不小于 32 时按 32 位语义给出定义好的结果：变宽得 0，
/// 变窄时负数得 -1、非负数得 0（避免实现相关的移位计数回绕）。
pub fn convert_bit_depth(sample : Int, from_bits : Int, to_bits : Int) -> Int {
  if to_bits == from_bits {
    return sample
  }
  if to_bits > from_bits {
    let shift = to_bits - from_bits
    if shift >= 32 {
      0
    } else {
      (sample.to_int64() << shift).to_int()
    }
  } else {
    let shift = from_bits - to_bits
    if shift >= 32 {
      if sample < 0 {
        -1
      } else {
        0
      }
    } else {
      sample >> shift
    }
  }
}

///|
/// 声道数转换（作用于按帧交织的样本数组）。
///
/// 支持且仅支持三种组合：
///
/// - `from_channels == to_channels`：返回一份逐样本拷贝。
/// - `1 -> 2`：单声道复制到左右两声道，`[s] => [s, s]`。
/// - `2 -> 1`：`(l + r) >> 1`，即**算术右移一位**（向负无穷取整）。求和用 `Int64`，
///   因此满量程 32 位样本也不会溢出。注意这是 floor 而非向零截断：
///   `(-1 + -2) >> 1 == -2`。
///
/// 其余组合（如 1->3、3->1、2->4）抛 `AudioError::Unsupported`。
///
/// 尾部不足一帧的样本被忽略（只处理完整帧），不抛错。
pub fn convert_channels(
  samples : Array[Int],
  from_channels : Int,
  to_channels : Int,
) -> Array[Int] raise AudioError {
  if from_channels <= 0 || to_channels <= 0 {
    raise AudioError::Unsupported(
      "convert_channels: 声道数必须为正，from=\{from_channels} to=\{to_channels}",
    )
  }
  if from_channels == to_channels {
    return samples.copy()
  }
  if from_channels == 1 && to_channels == 2 {
    let frames = samples.length()
    let out : Array[Int] = []
    for i in 0..<frames {
      let s = samples[i]
      out.push(s)
      out.push(s)
    }
    return out
  }
  if from_channels == 2 && to_channels == 1 {
    let frames = samples.length() / 2
    let out : Array[Int] = []
    for i in 0..<frames {
      let l = samples[i * 2].to_int64()
      let r = samples[i * 2 + 1].to_int64()
      out.push(((l + r) >> 1).to_int())
    }
    return out
  }
  raise AudioError::Unsupported(
    "convert_channels: 不支持的声道转换 \{from_channels} -> \{to_channels}",
  )
}

///|
/// 从交织样本里抽出第 `ch` 声道（`ch` 从 0 开始）。
///
/// `[L0, R0, L1, R1, ...]` 在 `channels = 2, ch = 1` 时得到 `[R0, R1, ...]`。
/// 尾部不足一帧的样本被忽略。
///
/// `channels <= 0`，或 `ch` 不在 `0..channels-1` 内时抛 `AudioError::Unsupported`。
pub fn deinterleave_channel(
  samples : Array[Int],
  channels : Int,
  ch : Int,
) -> Array[Int] raise AudioError {
  if channels <= 0 {
    raise AudioError::Unsupported(
      "deinterleave_channel: channels 必须为正，得到 \{channels}",
    )
  }
  if ch < 0 || ch >= channels {
    raise AudioError::Unsupported(
      "deinterleave_channel: 声道下标 \{ch} 不在 0..=\{channels - 1} 内",
    )
  }
  let frames = samples.length() / channels
  let out : Array[Int] = []
  for i in 0..<frames {
    out.push(samples[i * channels + ch])
  }
  out
}

///|
/// 把多个声道数组交织成一个：[L, R, L, R, ...]。
///
/// `channels_data[c][i]` 是第 `c` 声道第 `i` 帧的样本，输出第 `i` 帧依次是
/// 各声道的第 `i` 个样本。空输入返回空数组。
///
/// **各声道的样本数必须完全一致**，否则抛 `AudioError::Unsupported`。
/// 这里刻意选择报错而不是按最短声道截断：本库的卖点是逐样本无损，
/// 悄悄丢掉样本比直接失败危险得多（长度不齐永远是调用方的 bug，
/// 而不是可以容忍的输入差异）。
pub fn interleave(channels_data : Array[Array[Int]]) -> Array[Int] raise AudioError {
  let n = channels_data.length()
  if n == 0 {
    return []
  }
  let frames = channels_data[0].length()
  for c = 1; c < n; c = c + 1 {
    let len = channels_data[c].length()
    if len != frames {
      raise AudioError::Unsupported(
        "interleave: 各声道样本数不一致，声道 0 有 \{frames} 个，声道 \{c} 有 \{len} 个",
      )
    }
  }
  let out : Array[Int] = []
  for i in 0..<frames {
    for c in 0..<n {
      out.push(channels_data[c][i])
    }
  }
  out
}

///|
/// 峰值绝对幅度：`max(|s|)`，空数组返回 0。
///
/// 用于测试与削波检测。取绝对值在 `Int64` 中进行，因此
/// `Int::min_value`（`-2147483648`）不会回绕；其真实绝对值超出 `Int` 上界，
/// 结果**饱和**为 `2147483647`。
pub fn peak_amplitude(samples : Array[Int]) -> Int {
  let mut peak : Int64 = 0L
  for s in samples {
    let v = s.to_int64()
    let a = if v < 0L { -v } else { v }
    if a > peak {
      peak = a
    }
  }
  if peak > 2147483647L {
    2147483647
  } else {
    peak.to_int()
  }
}

///|
/// 两段样本是否逐样本相同（长度也必须相同）。
pub fn samples_equal(a : Array[Int], b : Array[Int]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
/// 返回第一个不同的下标；完全相同时返回 -1。
///
/// 长度不等但公共前缀相同的情况，返回较短数组的长度（即第一个"缺失"的位置）：
/// `[1, 2]` 与 `[1, 2, 3]` 得 2。这样 `first_difference(a, b) == -1`
/// 当且仅当 `samples_equal(a, b)`。
pub fn first_difference(a : Array[Int], b : Array[Int]) -> Int {
  let n = Int::min(a.length(), b.length())
  for i in 0..<n {
    if a[i] != b[i] {
      return i
    }
  }
  if a.length() == b.length() {
    -1
  } else {
    n
  }
}
