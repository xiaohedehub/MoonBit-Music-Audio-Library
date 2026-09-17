// moonbit-music —— 校验和黑盒测试
//
// 期望值来源（全部为外部权威向量、独立实现算出的定值、或在测试内独立推导的
// 不变量，**不是**本实现的自我输出）：
//
//   * crc8(b"123456789") == 0xF4           —— CRC-8/SMBUS 标准校验值
//   * crc16(b"123456789") == 0xFEE8        —— CRC-16/UMTS (a.k.a. BUYPASS) 标准校验值
//   * adler32(b"Wikipedia") == 0x11E60398  —— RFC 1950 经典例子
//   * adler32(b"123456789") == 0x091E01DE  —— zlib 已发表向量（交叉验证用）
//   * Ogg page 向量 0x593222A3             —— 见对应 test 内注释
//   * 其余为可推导不变量（空输入 / 全零 / 增量一致 / 单比特翻转敏感性）

///|
/// 全零字节输入（长度由调用方给出）。
fn zeros(n : Int) -> Bytes {
  let out = Buffer()
  for i = 0; i < n; i = i + 1 {
    out.write_byte(b'\x00')
  }
  out.to_bytes()
}

///|
/// 把 `data` 的第 `bit` 位翻转（MSB-first 位序），返回新字节串。
fn flip_bit(data : Bytes, bit : Int) -> Bytes {
  let out = Buffer()
  let byte_index = bit / 8
  let mask = 1 << (7 - bit % 8)
  for i = 0; i < data.length(); i = i + 1 {
    if i == byte_index {
      out.write_byte((data[i].to_int() ^ mask).to_byte())
    } else {
      out.write_byte(data[i])
    }
  }
  out.to_bytes()
}

///|
/// CRC-8 的标准校验值：多项式 0x07、初值 0、非反射、不取反。
test "crc8 known vector \"123456789\" == 0xF4" {
  assert_eq(crc8(b"123456789"), 0xF4)
}

///|
/// 查表法必须与教科书写法（逐位 MSB-first 移位归约）一致。
///
/// 这个测试的锚点不是某个魔数，而是「预计算表 == 朴素逐位算法」这一事实：
/// 表构造写错（掩码漏掉、多项式错位、位序反转）时这里必然失败。
test "crc8 table-driven result matches bit-by-bit reference" {
  let cases : Array[Bytes] = [
    b"",
    b"\x00",
    b"\xFF",
    b"1",
    b"123456789",
    b"\x01vorbis",
    b"The quick brown fox jumps over the lazy dog",
    zeros(64),
    b"\x80\x00\x00\x00\x00\x00\x00\x01",
  ]
  for data in cases {
    assert_eq(crc8(data), crc8_bitwise(data))
  }
}

///|
/// CRC-8 逐位参考实现：多项式 x^8+x^2+x+1 (0x07)，初值 0，不反射，不取反。
/// MSB-first：每字节先异或进寄存器，再重复 8 次「看最高位 → 左移 → 条件异或」。
fn crc8_bitwise(data : Bytes) -> Int {
  let mut crc = 0
  for i = 0; i < data.length(); i = i + 1 {
    crc = crc ^ data[i].to_int()
    for bit = 0; bit < 8; bit = bit + 1 {
      if (crc & 0x80) != 0 {
        crc = ((crc << 1) ^ 0x07) & 0xFF
      } else {
        crc = (crc << 1) & 0xFF
      }
    }
  }
  crc
}

///|
/// 单比特翻转必须改变 CRC-8（除零长度外）。
test "crc8 detects every single-bit flip" {
  let data = b"123456789"
  let base = crc8(data)
  for bit = 0; bit < data.length() * 8; bit = bit + 1 {
    let flipped = crc8(flip_bit(data, bit))
    if flipped == base {
      abort("crc8 failed to detect flip of bit \{bit}")
    }
  }
}

///|
/// CRC-8 空输入返回初值 0。
test "crc8 empty input == 0" {
  assert_eq(crc8(b""), 0)
  assert_eq(crc8(zeros(0)), 0)
}

///|
/// 查表法表长必须是 256。
test "crc8_table_size == 256" {
  assert_eq(crc8_table_size(), 256)
}

///|
/// CRC-16 的标准校验值：多项式 0x8005、初值 0、非反射、不取反
/// （CRC-16/UMTS，即 BUYPASS 变体）。
test "crc16 known vector \"123456789\" == 0xFEE8" {
  assert_eq(crc16(b"123456789"), 0xFEE8)
}

///|
/// CRC-16 空输入返回初值 0。
test "crc16 empty input == 0" {
  assert_eq(crc16(b""), 0)
}

///|
/// 单比特翻转必须改变 CRC-16。
test "crc16 detects every single-bit flip" {
  let data = b"123456789"
  let base = crc16(data)
  for bit = 0; bit < data.length() * 8; bit = bit + 1 {
    let flipped = crc16(flip_bit(data, bit))
    if flipped == base {
      abort("crc16 failed to detect flip of bit \{bit}")
    }
  }
}

///|
/// CRC-16 输出必须落在 16 位内（表项已掩码，不会污染高位）。
test "crc16 stays within 16 bits" {
  let data = b"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF"
  let v = crc16(data)
  assert_true(v >= 0 && v <= 0xFFFF)
  let w = crc16(b"abcdefghijklmnopqrstuvwxyz")
  assert_true(w >= 0 && w <= 0xFFFF)
}

///|
/// Ogg CRC32 真实页向量。
///
/// 这是一个手工构造的合法 Ogg BOS page（35 字节），字节序列完整写死：
///
/// ```text
/// 4F 67 67 53  "OggS"
/// 00           version 0
/// 02           header_type = BOS
/// 00*8         granule_position = 0 (LE)
/// D2 04 00 00  serial = 1234 (LE)
/// 00 00 00 00  page sequence = 0 (LE)
/// 00 00 00 00  CRC 字段（按规范置零后参与计算）
/// 01           page_segments = 1
/// 07           lacing value = 7
/// 01 76 6F 72 62 69 73   body = "\x01vorbis"
/// ```
///
/// 期望值 `0x593222A3`（十进制 1496457891）由独立实现算出：Python 的逐位
/// 算法（多项式 0x04C11DB7、初值 0、非反射、不取反），并与另一条独立的
/// 256 项查表实现互相校验一致。
test "ogg_crc32 crafted Ogg BOS page == 0x593222A3" {
  let page = b"OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\xD2\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x07\x01vorbis"
  assert_eq(page.length(), 35)
  // 0x593222A3 == 1496457891
  assert_eq(ogg_crc32(page), 1496457891)
}

///|
/// Ogg 的真实性质：初值为 0 且不取反 ⇒ 全零输入恒得 0，与长度无关。
/// 这条不变量能在「实现整体偏移或错误取反」时立刻失败。
test "ogg_crc32 all-zero input is 0 for every length" {
  assert_eq(ogg_crc32(b""), 0)
  for n = 1; n <= 64; n = n + 1 {
    assert_eq(ogg_crc32(zeros(n)), 0)
  }
  assert_eq(ogg_crc32(zeros(255)), 0)
  assert_eq(ogg_crc32(zeros(256)), 0)
  assert_eq(ogg_crc32(zeros(257)), 0)
  assert_eq(ogg_crc32(zeros(1000)), 0)
}

///|
/// Ogg CRC32 空输入返回初值 0。
test "ogg_crc32 empty input == 0" {
  assert_eq(ogg_crc32(b""), 0)
}

///|
/// 单比特翻转必须改变 Ogg CRC32。
test "ogg_crc32 detects every single-bit flip" {
  let data = b"\x01vorbis"
  let base = ogg_crc32(data)
  for bit = 0; bit < data.length() * 8; bit = bit + 1 {
    let flipped = ogg_crc32(flip_bit(data, bit))
    if flipped == base {
      abort("ogg_crc32 failed to detect flip of bit \{bit}")
    }
  }
}

///|
/// 增量 API 与整体 API 必须一致：切成 2 段、3 段、逐字节都要对得上。
test "ogg_crc32_update is consistent with ogg_crc32 across chunkings" {
  let data = b"OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\xD2\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x07\x01vorbis"
  let whole = ogg_crc32(data)
  let n = data.length()

  // 三段（切片得到的是 BytesView，需转换成独立的 Bytes）
  let c1 = ogg_crc32_update(0, data[:10].to_owned())
  let c2 = ogg_crc32_update(c1, data[10:27].to_owned())
  let c3 = ogg_crc32_update(c2, data[27:].to_owned())
  assert_eq(c3, whole)

  // 两段：已算出的中间累积值也要与「前缀整体计算」一致
  assert_eq(c1, ogg_crc32(data[:10].to_owned()))
  assert_eq(c2, ogg_crc32(data[:27].to_owned()))

  // 每一处切分都必须成立
  for split = 0; split <= n; split = split + 1 {
    let acc = ogg_crc32_update(
      ogg_crc32_update(0, data[:split].to_owned()),
      data[split:].to_owned(),
    )
    assert_eq(acc, whole)
  }

  // 逐字节
  let mut acc = 0
  for i = 0; i < n; i = i + 1 {
    acc = ogg_crc32_update(acc, data[i:i + 1].to_owned())
  }
  assert_eq(acc, whole)

  // 空块不改变累积值
  assert_eq(ogg_crc32_update(whole, b""), whole)
}

///|
/// 增量版对任意 initial 都只取低 32 位，且空数据是恒等操作。
test "ogg_crc32_update with empty data returns the accumulated value" {
  assert_eq(ogg_crc32_update(0, b""), 0)
  assert_eq(ogg_crc32_update(0x593222A3, b""), 0x593222A3)
  assert_eq(ogg_crc32_update(-1, b""), -1)
}

///|
/// Adler-32 的经典向量：RFC 1950 / zlib 文档里的 "Wikipedia"。
test "adler32 known vector \"Wikipedia\" == 0x11E60398" {
  assert_eq(adler32(b"Wikipedia"), 0x11E60398)
}

///|
/// Adler-32 第二条已发表向量（zlib 的 "123456789" == 0x091E01DE）。
test "adler32 known vector \"123456789\" == 0x091E01DE" {
  assert_eq(adler32(b"123456789"), 0x091E01DE)
}

///|
/// Adler-32 空输入返回 s1 的初值 1（不是 0）。
test "adler32 empty input == 1" {
  assert_eq(adler32(b""), 1)
  assert_eq(adler32(zeros(0)), 1)
}

///|
/// Adler-32 单比特翻转必须改变结果。
test "adler32 detects every single-bit flip" {
  let data = b"Wikipedia"
  let base = adler32(data)
  for bit = 0; bit < data.length() * 8; bit = bit + 1 {
    let flipped = adler32(flip_bit(data, bit))
    if flipped == base {
      abort("adler32 failed to detect flip of bit \{bit}")
    }
  }
}

///|
/// Adler-32 结果必须始终落在 32 位无符号范围内，且 s1/s2 都能按位取出
/// （顺带验证取模 65521 的语义）。
test "adler32 stays within 32 bits" {
  // 60000 个 0 字节：s1 = 1 + 0 = 1，s2 = 60000
  let v = adler32(zeros(60000))
  let s1 = v & 0xFFFF
  let s2 = (v >> 16) & 0xFFFF
  assert_eq(s1, 1)
  assert_eq(s2, 60000)
}
