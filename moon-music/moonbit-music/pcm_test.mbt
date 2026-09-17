// moonbit-music —— pcm.mbt 的黑盒测试
//
// 只使用公开接口。所有断言都是**确定性**的精确值，不用"约等于"，
// 因为其他模块（WAV / FLAC / MP3 解码器）依赖这里钉死的移位与舍入语义。

///|
/// `f()` 是否抛出 `AudioError::Unsupported`。
/// 抛出别的分支或根本没抛都算 false。
fn pcm_raises_unsupported(f : () -> Unit raise AudioError) -> Bool {
  try {
    f()
    false
  } catch {
    AudioError::Unsupported(_) => true
    _ => false
  }
}

///|
test "u8_to_signed：边界与整段映射" {
  assert_eq(u8_to_signed(0), -128)
  assert_eq(u8_to_signed(1), -127)
  assert_eq(u8_to_signed(128), 0)
  assert_eq(u8_to_signed(254), 126)
  assert_eq(u8_to_signed(255), 127)
}

///|
test "signed_to_u8：边界与饱和钳制" {
  assert_eq(signed_to_u8(-128), 0)
  assert_eq(signed_to_u8(-127), 1)
  assert_eq(signed_to_u8(0), 128)
  assert_eq(signed_to_u8(126), 254)
  assert_eq(signed_to_u8(127), 255)
  // 超范围饱和到端点，不取模回绕
  assert_eq(signed_to_u8(-129), 0)
  assert_eq(signed_to_u8(-1000), 0)
  assert_eq(signed_to_u8(128), 255)
  assert_eq(signed_to_u8(100000), 255)
}

///|
test "u8_to_signed / signed_to_u8：双向往返 0..255" {
  for i in 0..<256 {
    assert_eq(signed_to_u8(u8_to_signed(i)), i)
  }
  for v in -128..<128 {
    assert_eq(u8_to_signed(signed_to_u8(v)), v)
  }
}

///|
test "convert_bit_depth：16 -> 8 的确定值（算术右移 / floor）" {
  assert_eq(convert_bit_depth(32767, 16, 8), 127) // 0x7FFF >> 8
  assert_eq(convert_bit_depth(256, 16, 8), 1)
  assert_eq(convert_bit_depth(255, 16, 8), 0)
  assert_eq(convert_bit_depth(1, 16, 8), 0)
  assert_eq(convert_bit_depth(0, 16, 8), 0)
  // 负数：向负无穷取整，不是向零截断
  assert_eq(convert_bit_depth(-1, 16, 8), -1) // 向零截断会得到 0
  assert_eq(convert_bit_depth(-255, 16, 8), -1)
  assert_eq(convert_bit_depth(-256, 16, 8), -1)
  assert_eq(convert_bit_depth(-257, 16, 8), -2)
  assert_eq(convert_bit_depth(-300, 16, 8), -2)
  assert_eq(convert_bit_depth(-32768, 16, 8), -128) // 0x8000 >> 8
}

///|
test "convert_bit_depth：8 -> 16 的确定值（左移补零）" {
  assert_eq(convert_bit_depth(127, 8, 16), 32512) // 127 << 8
  assert_eq(convert_bit_depth(1, 8, 16), 256)
  assert_eq(convert_bit_depth(0, 8, 16), 0)
  assert_eq(convert_bit_depth(-1, 8, 16), -256)
  assert_eq(convert_bit_depth(-128, 8, 16), -32768)
}

///|
test "convert_bit_depth：8 -> 16 -> 8 往返无损" {
  for v in -128..<128 {
    assert_eq(convert_bit_depth(convert_bit_depth(v, 8, 16), 16, 8), v)
  }
  assert_eq(convert_bit_depth(convert_bit_depth(32767, 16, 8), 8, 16), 32512)
}

///|
test "convert_bit_depth：等宽恒等与 24 位" {
  assert_eq(convert_bit_depth(5, 16, 16), 5)
  assert_eq(convert_bit_depth(-2147483648, 32, 32), -2147483648)
  assert_eq(convert_bit_depth(8388607, 24, 16), 32767) // 0x7FFFFF >> 8
  assert_eq(convert_bit_depth(-8388608, 24, 16), -32768)
  assert_eq(convert_bit_depth(256, 16, 24), 65536)
  assert_eq(convert_bit_depth(-2147483648, 32, 16), -32768)
}

///|
test "convert_bit_depth：移位量 >= 32 时的定义好的结果" {
  assert_eq(convert_bit_depth(5, 8, 40), 0) // 变宽 32 位：低 32 位全为 0
  assert_eq(convert_bit_depth(-7, 40, 8), -1) // 变窄 32 位：负数饱和到 -1
  assert_eq(convert_bit_depth(7, 40, 8), 0) // 变窄 32 位：非负数得 0
}

///|
/// 独立公式交叉验证：全部 65536 个 16 位值都必须等于 floor(v / 256)。
/// 这里用"先取非负余数再整除"来算 floor，与实现里的算术右移是两条独立路径。
test "convert_bit_depth：16 -> 8 全量扫描等于 floor(v / 256)" {
  for v = -32768; v <= 32767; v = v + 1 {
    let rem = (v % 256 + 256) % 256
    let expected = (v - rem) / 256
    assert_eq(convert_bit_depth(v, 16, 8), expected)
  }
}

///|
/// 独立公式交叉验证：2 -> 1 的平均对全部 -3..3 组合都等于 floor((l + r) / 2)。
test "convert_channels：2 -> 1 全量扫描等于 floor((l + r) / 2)" {
  for l = -3; l <= 3; l = l + 1 {
    for r = -3; r <= 3; r = r + 1 {
      let sum = l + r
      let rem = (sum % 2 + 2) % 2
      let expected = (sum - rem) / 2
      assert_eq(convert_channels([l, r], 2, 1), [expected])
    }
  }
}

///|
test "scale_to_full_range：左移对齐到 32 位满量程" {
  assert_eq(scale_to_full_range(1, 16), 65536)
  assert_eq(scale_to_full_range(-1, 16), -65536)
  assert_eq(scale_to_full_range(32767, 16), 2147418112) // 0x7FFF << 16
  assert_eq(scale_to_full_range(-32768, 16), -2147483648) // 0x8000 << 16
  assert_eq(scale_to_full_range(7, 4), 1879048192) // 4 位 ±7 的左端
  assert_eq(scale_to_full_range(-8, 4), -2147483648) // 4 位 -8 触底
}

///|
test "scale_to_full_range：bits >= 32 或 <= 0 时为恒等映射" {
  assert_eq(scale_to_full_range(1, 32), 1)
  assert_eq(scale_to_full_range(-2147483648, 32), -2147483648)
  assert_eq(scale_to_full_range(12345, 40), 12345)
  assert_eq(scale_to_full_range(12345, 0), 12345)
  assert_eq(scale_to_full_range(12345, -8), 12345)
}

///|
test "convert_channels：1 -> 2 逐样本复制" {
  assert_eq(convert_channels([1, -2, 3], 1, 2), [1, 1, -2, -2, 3, 3])
  assert_eq(convert_channels([], 1, 2), [])
  assert_eq(convert_channels([-2147483648], 1, 2), [-2147483648, -2147483648])
}

///|
test "convert_channels：2 -> 1 取平均（算术右移一位 / floor）" {
  assert_eq(convert_channels([1, 2], 2, 1), [1]) // (1+2)>>1
  assert_eq(convert_channels([1, 4], 2, 1), [2]) // 5>>1
  assert_eq(convert_channels([-1, -2], 2, 1), [-2]) // (-3)>>1 = -2，不是 -1
  assert_eq(convert_channels([-3, 0], 2, 1), [-2]) // (-3)>>1 = -2
  assert_eq(convert_channels([0, 1], 2, 1), [0])
  assert_eq(convert_channels([32767, 32767], 2, 1), [32767])
  // Int64 求和：满量程也不会溢出
  assert_eq(convert_channels([2147483647, 2147483647], 2, 1), [2147483647])
  assert_eq(convert_channels([-2147483648, -2147483648], 2, 1), [-2147483648])
  // 多帧 + 尾部不足一帧的样本被忽略
  assert_eq(convert_channels([1, 2, 3, 4, 5, 6], 2, 1), [1, 3, 5])
  assert_eq(convert_channels([1, 2, 3], 2, 1), [1])
}

///|
test "convert_channels：等声道数为恒等拷贝（且是新数组）" {
  assert_eq(convert_channels([1, 2, 3], 1, 1), [1, 2, 3])
  assert_eq(convert_channels([1, 2, 3, 4], 2, 2), [1, 2, 3, 4])
  let src = [1, 2, 3]
  let out = convert_channels(src, 1, 1)
  out[0] = 99
  assert_eq(src[0], 1) // 拷贝，不共享底层存储
}

///|
test "convert_channels：非法组合抛 Unsupported" {
  assert_true(
    pcm_raises_unsupported(() => ignore(convert_channels([1, 2, 3], 1, 3))),
    msg="1->3 应抛 Unsupported",
  )
  assert_true(
    pcm_raises_unsupported(() => ignore(convert_channels([1, 2, 3], 3, 1))),
    msg="3->1 应抛 Unsupported",
  )
  assert_true(
    pcm_raises_unsupported(() => ignore(convert_channels([1, 2, 3, 4], 2, 4))),
    msg="2->4 应抛 Unsupported",
  )
  assert_true(
    pcm_raises_unsupported(() => ignore(convert_channels([1, 2], 0, 1))),
    msg="0 声道应抛 Unsupported",
  )
  assert_true(
    pcm_raises_unsupported(() => ignore(convert_channels([1, 2], 2, 0))),
    msg="目标 0 声道应抛 Unsupported",
  )
}

///|
test "deinterleave_channel：抽出单声道" {
  let stereo = [1, 2, 3, 4, 5, 6]
  assert_eq(deinterleave_channel(stereo, 2, 0), [1, 3, 5])
  assert_eq(deinterleave_channel(stereo, 2, 1), [2, 4, 6])
  let tri = [1, 2, 3, 4, 5, 6]
  assert_eq(deinterleave_channel(tri, 3, 0), [1, 4])
  assert_eq(deinterleave_channel(tri, 3, 1), [2, 5])
  assert_eq(deinterleave_channel(tri, 3, 2), [3, 6])
  assert_eq(deinterleave_channel([], 2, 0), [])
  // 尾部不足一帧的样本被忽略
  assert_eq(deinterleave_channel([1, 2, 3], 2, 0), [1])
  assert_eq(deinterleave_channel([1, 2, 3], 2, 1), [2])
}

///|
test "deinterleave_channel：非法参数抛 Unsupported" {
  assert_true(
    pcm_raises_unsupported(() => ignore(deinterleave_channel([1, 2], 2, 2))),
    msg="ch 越界（== channels）应抛 Unsupported",
  )
  assert_true(
    pcm_raises_unsupported(() => ignore(deinterleave_channel([1, 2], 2, -1))),
    msg="ch 为负应抛 Unsupported",
  )
  assert_true(
    pcm_raises_unsupported(() => ignore(deinterleave_channel([1, 2], 0, 0))),
    msg="channels 为 0 应抛 Unsupported",
  )
  assert_true(
    pcm_raises_unsupported(() => ignore(deinterleave_channel([1, 2], -1, 0))),
    msg="channels 为负应抛 Unsupported",
  )
}

///|
test "interleave：基本交织与空输入" {
  assert_eq(interleave([[1, 3, 5], [2, 4, 6]]), [1, 2, 3, 4, 5, 6])
  assert_eq(interleave([[1, 4], [2, 5], [3, 6]]), [1, 2, 3, 4, 5, 6])
  assert_eq(interleave([[7]]), [7])
  assert_eq(interleave([]), [])
  assert_eq(interleave([[]]), [])
  assert_eq(interleave([[], []]), [])
}

///|
test "interleave：各声道长度不一致抛 Unsupported" {
  assert_true(
    pcm_raises_unsupported(() => ignore(interleave([[1, 2, 3], [4]]))),
    msg="声道 0 长 3、声道 1 长 1，应抛 Unsupported",
  )
  assert_true(
    pcm_raises_unsupported(() => ignore(interleave([[1], [2, 3, 4]]))),
    msg="声道 0 长 1、声道 1 长 3，应抛 Unsupported",
  )
  assert_true(
    pcm_raises_unsupported(() => ignore(interleave([[], [1]]))),
    msg="空声道与非空声道混用，应抛 Unsupported",
  )
}

///|
test "deinterleave_channel / interleave：立体声往返一致" {
  let original = [1, 2, 3, 4, 5, 6, 7, 8]
  let l = deinterleave_channel(original, 2, 0)
  let r = deinterleave_channel(original, 2, 1)
  assert_eq(interleave([l, r]), original)
  // 三声道往返
  let tri = [10, 20, 30, 40, 50, 60, 70, 80, 90]
  let c0 = deinterleave_channel(tri, 3, 0)
  let c1 = deinterleave_channel(tri, 3, 1)
  let c2 = deinterleave_channel(tri, 3, 2)
  assert_eq(interleave([c0, c1, c2]), tri)
  // 再交织回去又拆开，仍然一致
  assert_eq(deinterleave_channel(interleave([l, r]), 2, 1), r)
  // 1 -> 2 之后拆出两个相同声道
  let mono = [5, -5, 0]
  let doubled = convert_channels(mono, 1, 2)
  assert_eq(deinterleave_channel(doubled, 2, 0), mono)
  assert_eq(deinterleave_channel(doubled, 2, 1), mono)
}

///|
test "peak_amplitude：空数组为 0，含负数取绝对最大" {
  assert_eq(peak_amplitude([]), 0)
  assert_eq(peak_amplitude([0]), 0)
  assert_eq(peak_amplitude([0, 0, 0]), 0)
  assert_eq(peak_amplitude([1, -5, 3]), 5)
  assert_eq(peak_amplitude([-7, -2, -3]), 7)
  assert_eq(peak_amplitude([32767, -32768]), 32768)
  assert_eq(peak_amplitude([2147483647]), 2147483647)
  // Int::min_value 的绝对值超出 Int 上界，饱和为 Int::max_value
  assert_eq(peak_amplitude([-2147483648]), 2147483647)
}

///|
test "samples_equal：相同 / 不同 / 长度不等" {
  assert_true(samples_equal([], []))
  assert_true(samples_equal([1, 2, 3], [1, 2, 3]))
  assert_true(samples_equal([-2147483648, 2147483647], [-2147483648, 2147483647]))
  assert_false(samples_equal([1, 2, 3], [1, 2, 4]))
  assert_false(samples_equal([1, 2, 3], [1, 2]))
  assert_false(samples_equal([1, 2], [1, 2, 3]))
  assert_false(samples_equal([], [0]))
  assert_false(samples_equal([0], []))
}

///|
test "first_difference：相同 / 不同 / 长度不等" {
  assert_eq(first_difference([], []), -1)
  assert_eq(first_difference([1, 2, 3], [1, 2, 3]), -1)
  assert_eq(first_difference([1, 2, 3], [1, 9, 3]), 1)
  assert_eq(first_difference([1, 2, 3], [9, 2, 3]), 0)
  assert_eq(first_difference([1, 2, 3], [1, 2, 4]), 2)
  // 公共前缀相同但长度不等：返回较短数组的长度（第一个"缺失"位置）
  assert_eq(first_difference([1, 2], [1, 2, 3]), 2)
  assert_eq(first_difference([1, 2, 3], [1, 2]), 2)
  assert_eq(first_difference([], [1]), 0)
  assert_eq(first_difference([1], []), 0)
}

///|
test "first_difference 与 samples_equal 互相一致" {
  let cases : Array[(Array[Int], Array[Int])] = [
    ([], []),
    ([0], [0]),
    ([1, 2, 3], [1, 2, 3]),
    ([1, 2, 3], [1, 2, 4]),
    ([1, 2], [1, 2, 3]),
    ([1, 2, 3], [1, 2]),
  ]
  for pair in cases {
    let (a, b) = pair
    assert_eq(first_difference(a, b) == -1, samples_equal(a, b))
  }
}
