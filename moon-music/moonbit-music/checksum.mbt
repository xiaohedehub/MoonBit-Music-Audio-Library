// moonbit-music —— 校验和
//
// 本文件实现库内用到的四种校验算法：
//   * CRC-8       多项式 0x07       FLAC frame header
//   * CRC-16      多项式 0x8005     FLAC frame footer
//   * Ogg CRC-32  多项式 0x04C11DB7 Ogg page
//   * Adler-32                      zlib（以及 FLAC 之外的容器）
//
// 全部为「非反射」（MSB-first）实现，查表法。四个算法都不做最终取反。
//
// 位运算注意：MoonBit 的 `Int` 是 32 位有符号，`>>` 是算术右移，
// 对负数会符号扩展。所有右移都必须用掩码截断高位，否则查表下标会被
// 高位污染而算出错误结果。见下面各表的生成函数。

///|
/// CRC-8（多项式 x^8+x^2+x+1 = 0x07）的 256 项查找表。
///
/// `table[b]` 是「寄存器初值为 `b`、再喂入一个 0x00 字节」的结果。
/// 于是对每个数据字节有：`crc = table[crc ^ byte]`。
let crc8_table : Array[Int] = build_crc8_table()

///|
/// 生成 CRC-8 查找表。
///
/// 每个表项由 8 次移位归约得到；`(r << 1) & 0xFF` 把结果限制在一个字节内，
/// 因为 CRC-8 的寄存器宽度就是 8 位。
fn build_crc8_table() -> Array[Int] {
  let table : Array[Int] = Array::make(256, 0)
  for i = 0; i < 256; i = i + 1 {
    let mut r = i
    for bit = 0; bit < 8; bit = bit + 1 {
      if (r & 0x80) != 0 {
        r = ((r << 1) & 0xFF) ^ 0x07
      } else {
        r = (r << 1) & 0xFF
      }
    }
    table[i] = r
  }
  table
}

///|
/// CRC-8，多项式 x^8+x^2+x+1 (0x07)，初值 0，不反射，不取反。FLAC frame header 用。
///
/// 空输入返回 0（即初值）。
///
/// ```text
/// crc8(b"123456789") == 0xF4
/// ```
pub fn crc8(data : Bytes) -> Int {
  let mut crc = 0
  for i = 0; i < data.length(); i = i + 1 {
    crc = crc8_table[crc ^ data[i].to_int()]
  }
  crc
}

///|
/// CRC-16（多项式 x^16+x^15+x^2+1 = 0x8005）的 256 项查找表。
///
/// `table[b]` 是「寄存器高字节为 `b`、再喂入一个 0x00 字节」的结果。
/// 于是对每个数据字节有：
/// `crc = ((crc << 8) & 0xFFFF) ^ table[((crc >> 8) & 0xFF) ^ byte]`。
let crc16_table : Array[Int] = build_crc16_table()

///|
/// 生成 CRC-16 查找表。
///
/// 表项是 16 位值，`& 0xFFFF` 保证不溢出到高位。
fn build_crc16_table() -> Array[Int] {
  let table : Array[Int] = Array::make(256, 0)
  for i = 0; i < 256; i = i + 1 {
    let mut r = i << 8
    for bit = 0; bit < 8; bit = bit + 1 {
      if (r & 0x8000) != 0 {
        r = ((r << 1) & 0xFFFF) ^ 0x8005
      } else {
        r = (r << 1) & 0xFFFF
      }
    }
    table[i] = r
  }
  table
}

///|
/// CRC-16，多项式 x^16+x^15+x^2+1 (0x8005)，初值 0，不反射，不取反。FLAC frame footer 用。
///
/// 即 CRC-16/UMTS（又称 CRC-16/BUYPASS）变体。空输入返回 0（即初值）。
///
/// ```text
/// crc16(b"123456789") == 0xFEE8
/// ```
pub fn crc16(data : Bytes) -> Int {
  let mut crc = 0
  for i = 0; i < data.length(); i = i + 1 {
    let idx = ((crc >> 8) & 0xFF) ^ data[i].to_int()
    crc = ((crc << 8) & 0xFFFF) ^ crc16_table[idx]
  }
  crc
}

///|
/// Ogg CRC-32（多项式 0x04C11DB7）的 256 项查找表。
///
/// 这是「反射版」CRC-32 表的位反转形态，因此**不能**用 zlib/PKZIP 的
/// `crc32()` 代替：两者多项式虽同，但位序与初值/取反都不同。
let ogg_crc32_table : Array[Int] = build_ogg_crc32_table()

///|
/// 生成 Ogg CRC-32 查找表（非反射，MSB-first）。
///
/// 表项是 32 位值；MoonBit 的 `Int` 恰好 32 位，所以最高位为 1 的表项
/// 会表现为负数，这是正常的、也是期望的。
fn build_ogg_crc32_table() -> Array[Int] {
  let table : Array[Int] = Array::make(256, 0)
  for i = 0; i < 256; i = i + 1 {
    let mut r = i << 24
    for bit = 0; bit < 8; bit = bit + 1 {
      if (r & 0x80000000) != 0 {
        r = (r << 1) ^ 0x04C11DB7
      } else {
        r = r << 1
      }
    }
    table[i] = r
  }
  table
}

///|
/// CRC-32，多项式 0x04C11DB7，初值 0，不反射，不取反。Ogg page 用。
///
/// 注意：调用方必须先把 Ogg page 头里 22..25 字节的 CRC 字段清零后再传入，
/// 这是 Ogg 规范的要求（该字段本身不参与计算）。
///
/// 空输入返回 0（即初值）。
pub fn ogg_crc32(data : Bytes) -> Int {
  ogg_crc32_update(0, data)
}

///|
/// 增量版 Ogg CRC32：传入累积值继续计算，`initial` 为 0 表示从头开始。
///
/// 用于流式校验（先喂 page 头、再喂 body），等价于对拼接后的完整数据
/// 一次性调用 `ogg_crc32`。任意 `initial` 值都被接受（只取低 32 位）。
pub fn ogg_crc32_update(initial : Int, data : Bytes) -> Int {
  let mut crc = initial
  for i = 0; i < data.length(); i = i + 1 {
    // `crc >> 24` 是算术右移，负 crc 会符号扩展，故掩码取低 8 位再异或。
    let idx = ((crc >> 24) & 0xFF) ^ data[i].to_int()
    crc = (crc << 8) ^ ogg_crc32_table[idx]
  }
  crc
}

///|
/// Adler-32（zlib 用）。s1 初值 1，s2 初值 0，模 65521。
///
/// 空输入返回 1（即 s1 的初值），不是 0。
///
/// ```text
/// adler32(b"Wikipedia") == 0x11E60398
/// ```
pub fn adler32(data : Bytes) -> Int {
  let mut s1 = 1
  let mut s2 = 0
  for i = 0; i < data.length(); i = i + 1 {
    s1 = s1 + data[i].to_int()
    s2 = s2 + s1
  }
  ((s2 % 65521) << 16) | (s1 % 65521)
}

///|
/// 预计算表的可见性测试钩子：返回 CRC-8 查表法的表长度（应为 256）。
pub fn crc8_table_size() -> Int {
  crc8_table.length()
}

// ---------------------------------------------------------------------------
// 增量式与子范围版本（便于流式解析 / 多次拼接）
// ---------------------------------------------------------------------------

///|
/// 增量式 CRC-8：传入上一轮的累加值继续计算。`initial = 0` 等价于全新调用。
pub fn crc8_update(initial : Int, data : Bytes) -> Int {
  let mut crc = initial & 0xFF
  for i = 0; i < data.length(); i = i + 1 {
    crc = crc8_table[crc ^ data[i].to_int()]
  }
  crc
}

///|
/// 只在字节范围 `[start, start+length)` 内做 CRC-8。越界抛 `Unsupported`。
pub fn crc8_range(data : Bytes, start : Int, length : Int) -> Int raise AudioError {
  if start < 0 || length < 0 || start + length > data.length() {
    raise AudioError::Unsupported(
      "crc8_range: 越界 start=\{start} len=\{length} data_len=\{data.length()}",
    )
  }
  let mut crc = 0
  for i = start..<start + length {
    crc = crc8_table[crc ^ data[i].to_int()]
  }
  crc
}

///|
/// 增量式 CRC-16：传入上一轮的累加值继续计算。`initial = 0` 等价于全新调用。
pub fn crc16_update(initial : Int, data : Bytes) -> Int {
  let mut crc = initial & 0xFFFF
  for i = 0; i < data.length(); i = i + 1 {
    let idx = ((crc >> 8) & 0xFF) ^ data[i].to_int()
    crc = ((crc << 8) & 0xFFFF) ^ crc16_table[idx]
  }
  crc
}

///|
/// 只在字节范围 `[start, start+length)` 内做 CRC-16。越界抛 `Unsupported`。
pub fn crc16_range(data : Bytes, start : Int, length : Int) -> Int raise AudioError {
  if start < 0 || length < 0 || start + length > data.length() {
    raise AudioError::Unsupported(
      "crc16_range: 越界 start=\{start} len=\{length} data_len=\{data.length()}",
    )
  }
  let mut crc = 0
  for i = start..<start + length {
    let idx = ((crc >> 8) & 0xFF) ^ data[i].to_int()
    crc = ((crc << 8) & 0xFFFF) ^ crc16_table[idx]
  }
  crc
}

///|
/// 只在字节范围 `[start, start+length)` 内做 Ogg CRC-32。越界抛 `Unsupported`。
pub fn ogg_crc32_range(data : Bytes, start : Int, length : Int) -> Int raise AudioError {
  if start < 0 || length < 0 || start + length > data.length() {
    raise AudioError::Unsupported(
      "ogg_crc32_range: 越界 start=\{start} len=\{length} data_len=\{data.length()}",
    )
  }
  let mut crc = 0
  for i = start..<start + length {
    let idx = ((crc >> 24) & 0xFF) ^ data[i].to_int()
    crc = (crc << 8) ^ ogg_crc32_table[idx]
  }
  crc
}

///|
/// 增量式 Adler-32：传入上一轮的 (s1, s2) 继续计算，返回新的 (s1, s2)。
///
/// 这样调用方可以分批喂数据，最后再 `(s2 % 65521) << 16 | (s1 % 65521)` 合并结果。
/// 首次调用传 `(1, 0)`（与 `adler32` 的初值一致）。
pub fn adler32_step(s1_in : Int, s2_in : Int, data : Bytes) -> (Int, Int) {
  let mut s1 = s1_in
  let mut s2 = s2_in
  for i = 0; i < data.length(); i = i + 1 {
    s1 = s1 + data[i].to_int()
    s2 = s2 + s1
    // 每 5552 字节取一次模，避免 s1/s2 无限增长（NMAX 优化）
    if s1 >= 65521 * 4 {
      s1 = s1 % 65521
    }
    if s2 >= 65521 * 4 {
      s2 = s2 % 65521
    }
  }
  (s1, s2)
}

///|
/// 校验 32 位整数的 CRC 是否匹配；不匹配抛 `ChecksumMismatch`。
///
/// 统一把 expected/actual 规范化到无符号 32 位比较（避免负数因符号位看起来不等）。
pub fn assert_crc32_match(expected : Int, actual : Int, label : String) -> Unit raise AudioError {
  let exp = expected.to_int64() & 4294967295L
  let act = actual.to_int64() & 4294967295L
  if exp != act {
    raise AudioError::ChecksumMismatch(expected=exp.to_int(), actual=act.to_int())
  }
  ignore(label)
}

///|
/// 校验 16 位整数的 CRC 是否匹配；不匹配抛 `ChecksumMismatch`。
pub fn assert_crc16_match(expected : Int, actual : Int, label : String) -> Unit raise AudioError {
  let exp = expected & 0xFFFF
  let act = actual & 0xFFFF
  if exp != act {
    raise AudioError::ChecksumMismatch(expected=exp, actual=act)
  }
  ignore(label)
}
