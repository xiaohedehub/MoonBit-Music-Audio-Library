// moonbit-music —— bitstream.mbt 的黑盒测试
//
// 覆盖：MSB-first 语义、跨字节边界、read_unary、read_utf8_int（1/2/3/5/6/7 字节，
// 含超过 32 位的值）、越界抛 Truncated、非法编码抛 InvalidMagic、
// BitWriter -> BitReader 往返、align_to_byte 对齐。

///|
/// 取 `v` 的低 `n` 位（`n == 32` 时原样返回，避免 `1 << 32` 溢出）。
fn bs_low_bits(v : Int, n : Int) -> Int {
  if n >= 32 {
    v
  } else {
    v & ((1 << n) - 1)
  }
}

///|
/// `f` 是否抛出 `AudioError::Truncated`（抛别的错或正常返回都是 `false`）。
fn bs_raises_truncated(f : () -> Unit raise AudioError) -> Bool {
  let mut hit = false
  try {
    f()
  } catch {
    AudioError::Truncated(..) => hit = true
    _ => hit = false
  }
  hit
}

///|
/// `f` 是否抛出 `AudioError::InvalidMagic`。
fn bs_raises_invalid_magic(f : () -> Unit raise AudioError) -> Bool {
  let mut hit = false
  try {
    f()
  } catch {
    AudioError::InvalidMagic(_) => hit = true
    _ => hit = false
  }
  hit
}

///|
/// `f` 是否抛出 `AudioError::Unsupported`。
fn bs_raises_unsupported(f : () -> Unit raise AudioError) -> Bool {
  let mut hit = false
  try {
    f()
  } catch {
    AudioError::Unsupported(_) => hit = true
    _ => hit = false
  }
  hit
}

// ---------------------------------------------------------------------------
// 1. MSB-first 语义
// ---------------------------------------------------------------------------

///|
test "MSB-first：read_bits(3) 对 0xA0 返回 0b101" {
  let br = BitReader::new(b"\xA0\x5C")
  assert_eq(br.remaining(), 16)
  assert_eq(br.read_bits(3), 0b101)
  assert_eq(br.read_bits(3), 0b000)
  assert_eq(br.read_bits(2), 0b00)
  assert_eq(br.read_bits(4), 0b0101)
  assert_eq(br.read_bits(4), 0b1100)
  assert_eq(br.bit_pos(), 16)
  assert_eq(br.remaining(), 0)
}

///|
test "MSB-first：逐位读 0xA0 得到 1,0,1,0,0,0,0,0" {
  let br = BitReader::new(b"\xA0")
  let expect = [1, 0, 1, 0, 0, 0, 0, 0]
  let mut i = 0
  while i < 8 {
    assert_eq(br.read_bits(1), expect[i], msg="第 \{i} 位")
    i = i + 1
  }
  assert_eq(br.bit_pos(), 8)
}

///|
test "read_bits(32) 一次读完整字（大端）" {
  let br = BitReader::new(b"\x12\x34\x56\x78")
  assert_eq(br.read_bits(32), 0x12345678)
  assert_eq(br.bit_pos(), 32)
}

///|
test "read_bits(0) 返回 0 且不移动位偏移" {
  let br = BitReader::new(b"\xFF")
  assert_eq(br.read_bits(0), 0)
  assert_eq(br.bit_pos(), 0)
  assert_eq(br.remaining(), 8)
}

///|
test "read_bits 支持到 64 位（Int 只有 32 位，返回低 32 位）" {
  let br = BitReader::new(b"\x00\x00\x00\x00\x01\x23\x45\x67")
  assert_eq(br.read_bits(64), 0x01234567)
  assert_eq(br.bit_pos(), 64)
  assert_eq(br.remaining(), 0)
  let br2 = BitReader::new(b"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF")
  assert_eq(br2.read_bits(40), -1, msg="40 个 1 的低 32 位按 Int 解释是 -1")
}

///|
test "read_bits 位宽越界抛 Unsupported" {
  let br = BitReader::new(b"\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF")
  assert_true(bs_raises_unsupported(() => { ignore(br.read_bits(65)) }))
  assert_true(bs_raises_unsupported(() => { ignore(br.read_bits(-1)) }))
  assert_true(bs_raises_unsupported(() => { ignore(br.read_uint(33)) }))
  assert_true(bs_raises_unsupported(() => { ignore(br.read_int(33)) }))
  assert_eq(br.bit_pos(), 0, msg="抛错不应移动位偏移")
}

// ---------------------------------------------------------------------------
// 2. 跨字节边界
// ---------------------------------------------------------------------------

///|
test "跨字节边界：从 bit 5 开始读 12 位" {
  // 0x12345678 的位序（MSB-first）：
  // 0001 0010 0011 0100 0101 0110 0111 1000
  // 从 bit 5 起的 12 位 = 0100 0110 1000 = 0x468
  let br = BitReader::new(b"\x12\x34\x56\x78")
  br.skip_bits(5)
  assert_eq(br.bit_pos(), 5)
  assert_eq(br.read_bits(12), 0x468)
  assert_eq(br.bit_pos(), 17)
  assert_eq(br.remaining(), 15)
}

///|
test "跨字节边界：任意 (offset, n) 与逐位参考实现一致" {
  let data = b"\xA5\x3C\xF0\x0F"
  let total = 32
  let mut off = 0
  while off <= total {
    let mut n = 0
    while off + n <= total {
      let br = BitReader::new(data)
      br.skip_bits(off)
      let got = br.read_bits(n)
      // 参考实现：逐位取，最先读出的是最高位
      let mut expect = 0
      let mut k = 0
      while k < n {
        let pos = off + k
        let byte = data[pos >> 3].to_int()
        let bit = (byte >> (7 - (pos & 7))) & 1
        expect = (expect << 1) | bit
        k = k + 1
      }
      assert_eq(got, expect, msg="offset=\{off} n=\{n}")
      assert_eq(br.bit_pos(), off + n, msg="offset=\{off} n=\{n}")
      n = n + 1
    }
    off = off + 1
  }
}

///|
test "read_int 二进制补码符号扩展" {
  // 0xFF 0x80 0x01 -> 1111 1111 1000 0000 0000 0001
  let br = BitReader::new(b"\xFF\x80\x01")
  assert_eq(br.read_int(3), -1) // 111
  assert_eq(br.read_int(3), -1) // 111
  assert_eq(br.read_int(2), -1) // 11
  assert_eq(br.read_int(4), -8) // 1000
  assert_eq(br.read_int(4), 0) // 0000
  assert_eq(br.read_int(8), 1) // 0000 0001
  assert_eq(br.bit_pos(), 24)
}

///|
test "read_int(32) 与 read_uint(32) 保留 32 位位模式" {
  let br = BitReader::new(b"\x7F\xFF\xFF\xFF")
  assert_eq(br.read_uint(32), 0x7FFFFFFF)
  let br2 = BitReader::new(b"\xFF\xFF\xFF\xFF")
  assert_eq(br2.read_int(32), -1)
  let br3 = BitReader::new(b"\xFF\xFF\xFF\xFF")
  assert_eq(br3.read_uint(32), -1, msg="Int 是 32 位有符号，位模式原样保留")
}

// ---------------------------------------------------------------------------
// 3. read_unary
// ---------------------------------------------------------------------------

///|
test "read_unary：首位即 1 返回 0" {
  let br = BitReader::new(b"\x80")
  assert_eq(br.read_unary(), 0)
  assert_eq(br.bit_pos(), 1)
  assert_eq(br.remaining(), 7)
}

///|
test "read_unary：0 个 / 多个 0 连续调用" {
  // 0x0F 0xFF -> 0000 1111 1111 1111
  let br = BitReader::new(b"\x0F\xFF")
  assert_eq(br.read_unary(), 4)
  assert_eq(br.bit_pos(), 5)
  assert_eq(br.read_unary(), 0)
  assert_eq(br.read_unary(), 0)
  assert_eq(br.bit_pos(), 7)
}

///|
test "read_unary：恰好跨过整个字节边界" {
  // 0x00 0x80 -> 8 个 0 后跟 1，位偏移 0 -> 9
  let br = BitReader::new(b"\x00\x80")
  assert_eq(br.read_unary(), 8)
  assert_eq(br.bit_pos(), 9)
  assert_eq(br.remaining(), 7)
}

///|
test "read_unary：0x00 0x01 的 1 恰好落在 16 位边界上" {
  let br = BitReader::new(b"\x00\x01")
  assert_eq(br.read_unary(), 15)
  assert_eq(br.bit_pos(), 16)
  assert_eq(br.remaining(), 0)
  assert_true(bs_raises_truncated(() => { ignore(br.read_unary()) }))
}

///|
test "read_unary：游标不在字节起点时也正确" {
  // 0x1F 0x00 -> 0001 1111 0000 0000
  let br = BitReader::new(b"\x1F\x00")
  br.skip_bits(3) // 从 bit 3 起是 1 1 1 1 1 0 0 0 0 0 0 0 0
  assert_eq(br.read_unary(), 0)
  assert_eq(br.read_unary(), 0)
  assert_eq(br.read_unary(), 0)
  assert_eq(br.read_unary(), 0)
  assert_eq(br.read_unary(), 0)
  assert_eq(br.bit_pos(), 8)
  // 剩下的 8 位全是 0，没有收尾的 1
  assert_true(bs_raises_truncated(() => { ignore(br.read_unary()) }))
  assert_eq(br.bit_pos(), 8, msg="抛错时位偏移不动")
}

///|
test "read_unary：非字节对齐起点且跨字节边界" {
  // 0x00 0x01 -> 15 个 0 后跟一个 1
  let br = BitReader::new(b"\x00\x01")
  br.skip_bits(5)
  assert_eq(br.read_unary(), 10, msg="bit 5 到 bit 14 共 10 个 0")
  assert_eq(br.bit_pos(), 16)
  assert_eq(br.remaining(), 0)
}

///|
test "read_unary：全是 0 抛 Truncated" {
  let br = BitReader::new(b"\x00\x00")
  assert_true(bs_raises_truncated(() => { ignore(br.read_unary()) }), msg="8+8 个 0 之后没有 1")
  let empty = BitReader::new(b"")
  assert_true(bs_raises_truncated(() => { ignore(empty.read_unary()) }), msg="空数据")
}

// ---------------------------------------------------------------------------
// 4. read_utf8_int
// ---------------------------------------------------------------------------

///|
test "read_utf8_int：1 字节 0xxxxxxx" {
  let br = BitReader::new(b"\x7F\x00")
  assert_eq(br.read_utf8_int(), 127L)
  assert_eq(br.bit_pos(), 8)
  let br2 = BitReader::new(b"\x00")
  assert_eq(br2.read_utf8_int(), 0L)
}

///|
test "read_utf8_int：2 字节 110xxxxx 10xxxxxx" {
  // 110 00010 / 10 000000 -> 0b00010000000 = 128
  let br = BitReader::new(b"\xC2\x80\xFF")
  assert_eq(br.read_utf8_int(), 128L)
  assert_eq(br.bit_pos(), 16)
  // 110 11111 / 10 111111 -> 0b11111111111 = 2047
  let br2 = BitReader::new(b"\xDF\xBF")
  assert_eq(br2.read_utf8_int(), 2047L)
}

///|
test "read_utf8_int：3 字节 1110xxxx" {
  // 1110 0000 / 10 100000 / 10 000000 -> 0b0000100000000000 = 2048
  let br = BitReader::new(b"\xE0\xA0\x80\xFF")
  assert_eq(br.read_utf8_int(), 2048L)
  assert_eq(br.bit_pos(), 24)
}

///|
test "read_utf8_int：5 字节 111110xx" {
  // 1111 1000 -> 5 字节，首字节贡献 2 位（0b00），4 个续字节各 6 位全 1
  // -> 0b00_111111_111111_111111_111111 = 0xFFFFFF = 16777215
  let br = BitReader::new(b"\xF8\xBF\xBF\xBF\xBF")
  assert_eq(br.read_utf8_int(), 16777215L)
  assert_eq(br.bit_pos(), 40)
}

///|
test "read_utf8_int：6 字节 1111110x（31 位）" {
  // 1111 1101 -> 首字节贡献 1 位（1），5 个续字节各 6 位全 1
  // -> 0b1 + 30 个 1 = 0x7FFFFFFF = 2147483647
  let br = BitReader::new(b"\xFD\xBF\xBF\xBF\xBF\xBF")
  assert_eq(br.read_utf8_int(), 2147483647L)
  assert_eq(br.bit_pos(), 48)
}

///|
test "read_utf8_int：7 字节 11111110（36 位，超出 Int32）" {
  // 0xFE 之后 6 个续字节，各 6 位全 1 -> 36 个 1 = 2^36 - 1
  let br = BitReader::new(b"\xFE\xBF\xBF\xBF\xBF\xBF\xBF")
  let v = br.read_utf8_int()
  assert_eq(v, 68719476735L)
  assert_true(v > 4294967295L, msg="36 位值必须超出 Int32 范围")
  assert_eq(br.bit_pos(), 56)
  // FLAC 常见的大样本号：0xFE 后全 0 的续字节 -> 0
  let br2 = BitReader::new(b"\xFE\x80\x80\x80\x80\x80\x80")
  assert_eq(br2.read_utf8_int(), 0L)
  assert_eq(br2.bit_pos(), 56)
  // 0xFE ... 0x81 -> 1
  let br3 = BitReader::new(b"\xFE\x80\x80\x80\x80\x80\x81")
  assert_eq(br3.read_utf8_int(), 1L)
}

///|
test "read_utf8_int：非法前导字节抛 InvalidMagic" {
  let br = BitReader::new(b"\xFF\x00")
  assert_true(bs_raises_invalid_magic(() => { ignore(br.read_utf8_int()) }), msg="11111111 未定义")
  let br2 = BitReader::new(b"\x80\x00")
  assert_true(
    bs_raises_invalid_magic(() => { ignore(br2.read_utf8_int()) }),
    msg="10xxxxxx 不能作前导",
  )
}

///|
test "read_utf8_int：续字节前缀错误抛 InvalidMagic" {
  let br = BitReader::new(b"\xC2\x40")
  assert_true(bs_raises_invalid_magic(() => { ignore(br.read_utf8_int()) }))
  let br2 = BitReader::new(b"\xE0\xA0\xC0")
  assert_true(bs_raises_invalid_magic(() => { ignore(br2.read_utf8_int()) }))
}

///|
test "read_utf8_int：字节不足抛 Truncated" {
  let br = BitReader::new(b"\xC2")
  assert_true(bs_raises_truncated(() => { ignore(br.read_utf8_int()) }))
  let br2 = BitReader::new(b"\xFE\xBF\xBF\xBF\xBF\xBF")
  assert_true(bs_raises_truncated(() => { ignore(br2.read_utf8_int()) }), msg="7 字节只给了 6 个")
  let empty = BitReader::new(b"")
  assert_true(bs_raises_truncated(() => { ignore(empty.read_utf8_int()) }))
}

// ---------------------------------------------------------------------------
// 5. 越界一律 Truncated
// ---------------------------------------------------------------------------

///|
test "越界读取抛 Truncated 且不移动位偏移" {
  let br = BitReader::new(b"\xA0")
  assert_true(bs_raises_truncated(() => { ignore(br.read_bits(9)) }))
  assert_true(bs_raises_truncated(() => { ignore(br.read_uint(9)) }))
  assert_true(bs_raises_truncated(() => { ignore(br.read_int(9)) }))
  assert_true(bs_raises_truncated(() => { br.skip_bits(9) }))
  assert_eq(br.bit_pos(), 0, msg="抛错后位偏移保持不动")
  assert_eq(br.remaining(), 8)
  // 恰好读完不算越界
  assert_eq(br.read_bits(8), 0xA0)
  assert_eq(br.remaining(), 0)
  br.skip_bits(0)
  assert_eq(br.bit_pos(), 8)
  // 读完了再读一定抛
  assert_true(bs_raises_truncated(() => { ignore(br.read_bits(1)) }))
}

///|
test "Truncated 携带 offset/needed/available" {
  let br = BitReader::new(b"\xA0\xB0")
  br.skip_bits(12)
  let mut seen = false
  try {
    ignore(br.read_bits(8))
  } catch {
    AudioError::Truncated(offset~, needed~, available~) => {
      assert_eq(offset, 12)
      assert_eq(needed, 8)
      assert_eq(available, 4)
      seen = true
    }
    _ => ()
  }
  assert_true(seen, msg="应当抛出 Truncated")
}

///|
test "空输入的任何读取都抛 Truncated" {
  let br = BitReader::new(b"")
  assert_eq(br.remaining(), 0)
  assert_true(bs_raises_truncated(() => { ignore(br.read_bits(1)) }))
  assert_true(bs_raises_truncated(() => { ignore(br.read_bits(64)) }))
  assert_true(bs_raises_truncated(() => { ignore(br.read_unary()) }))
  assert_true(bs_raises_truncated(() => { ignore(br.read_utf8_int()) }))
  assert_true(bs_raises_truncated(() => { br.skip_bits(1) }))
  assert_eq(br.bit_pos(), 0)
}

// ---------------------------------------------------------------------------
// 6. BitWriter -> BitReader 往返
// ---------------------------------------------------------------------------

///|
test "BitWriter 的字节布局是 MSB-first" {
  let bw = BitWriter::new()
  assert_eq(bw.bit_length(), 0)
  bw.write_bits(0b101, 3)
  bw.write_bits(0b00000, 5)
  assert_eq(bw.bit_length(), 8)
  assert_eq(bw.to_bytes(), b"\xA0")
  assert_eq(bw.to_bytes(), b"\xA0", msg="to_bytes 可重复调用，不修改状态")
  assert_eq(bw.bit_length(), 8)
}

///|
test "BitWriter -> BitReader 往返一致" {
  let bw = BitWriter::new()
  bw.write_bits(0b101, 3)
  bw.write_bits(0x1234, 16)
  bw.write_unary(3)
  bw.write_bits(-1, 8)
  bw.write_bits(0, 4)
  let bits = 3 + 16 + 4 + 8 + 4
  assert_eq(bw.bit_length(), bits)
  let bytes = bw.to_bytes()
  assert_eq(bytes.length(), 5, msg="35 位补齐到 5 字节")

  let br = BitReader::new(bytes)
  assert_eq(br.remaining(), 40)
  assert_eq(br.read_bits(3), 0b101)
  assert_eq(br.read_bits(16), 0x1234)
  assert_eq(br.read_unary(), 3)
  assert_eq(br.read_int(8), -1)
  assert_eq(br.read_bits(4), 0)
  assert_eq(br.bit_pos(), bits)
  assert_eq(br.remaining(), 40 - bits)
}

///|
test "BitWriter 往返：1..=32 位的各种位模式" {
  let patterns = [0x00000000, 0x7FFFFFFF, -1, 0x0F0F0F0F, 0x00000001, 0x0000FFFF, 0x12345678]
  for p in patterns {
    let mut n = 1
    while n <= 32 {
      let bw = BitWriter::new()
      bw.write_bits(p, n)
      assert_eq(bw.bit_length(), n)
      let br = BitReader::new(bw.to_bytes())
      assert_eq(br.read_bits(n), bs_low_bits(p, n), msg="p=\{p} n=\{n}")
      assert_eq(br.bit_pos(), n)
      n = n + 1
    }
  }
}

///|
test "BitWriter 往返：read_int / read_uint 与写入位宽一致" {
  let cases = [0, 1, -1, 7, -8, 63, -64, 127, -128, 4095, -4096]
  for c in cases {
    let bw = BitWriter::new()
    bw.write_bits(c, 13)
    let br = BitReader::new(bw.to_bytes())
    assert_eq(br.read_int(13), c, msg="c=\{c}")
    let bw2 = BitWriter::new()
    bw2.write_bits(c, 13)
    let br2 = BitReader::new(bw2.to_bytes())
    assert_eq(br2.read_uint(13), bs_low_bits(c, 13), msg="c=\{c}")
  }
}

///|
test "BitWriter write_unary 往返" {
  for c in [0, 1, 2, 7, 8, 9, 15, 16, 31, 32] {
    let bw = BitWriter::new()
    bw.write_unary(c)
    assert_eq(bw.bit_length(), c + 1, msg="c=\{c}")
    let br = BitReader::new(bw.to_bytes())
    assert_eq(br.read_unary(), c, msg="c=\{c}")
    assert_eq(br.bit_pos(), c + 1)
  }
}

///|
test "BitWriter write_unary(0) 只写一个 1" {
  let bw = BitWriter::new()
  bw.write_unary(0)
  assert_eq(bw.bit_length(), 1)
  assert_eq(bw.to_bytes(), b"\x80")
}

///|
test "BitWriter write_bits(.., 0) 与 write_unary(负数) 是空操作前缀" {
  let bw = BitWriter::new()
  bw.write_bits(0xAB, 0)
  bw.write_bits(0xAB, -3)
  assert_eq(bw.bit_length(), 0)
  assert_eq(bw.to_bytes(), b"")
  bw.write_unary(0)
  assert_eq(bw.bit_length(), 1)
}

///|
test "BitWriter 可以分段写出并与一次性写出等价" {
  let bw = BitWriter::new()
  bw.write_bits(0xA, 4)
  bw.write_bits(0x5, 4)
  bw.write_bits(0x1234, 16)
  bw.write_bits(0x9, 4)
  bw.write_bits(0xC, 4)
  let br = BitReader::new(bw.to_bytes())
  assert_eq(br.read_bits(8), 0xA5)
  assert_eq(br.read_bits(16), 0x1234)
  assert_eq(br.read_bits(8), 0x9C)
  assert_eq(br.remaining(), 0)
}

///|
test "BitWriter 未对齐时 to_bytes 补 0" {
  let bw = BitWriter::new()
  bw.write_bits(0b1, 1)
  assert_eq(bw.bit_length(), 1)
  let bytes = bw.to_bytes()
  assert_eq(bytes.length(), 1)
  assert_eq(bytes[0], b'\x80')
  // 补的位是 0
  let br = BitReader::new(bytes)
  assert_eq(br.read_bits(1), 1)
  assert_eq(br.read_bits(7), 0)
}

// ---------------------------------------------------------------------------
// 7. align_to_byte
// ---------------------------------------------------------------------------

///|
test "align_to_byte 之后 bit_pos 一定是 8 的倍数" {
  let data = b"\xA5\x3C\xF0\x0F"
  let mut i = 0
  while i <= 32 {
    let br = BitReader::new(data)
    br.skip_bits(i)
    br.align_to_byte()
    assert_true(br.bit_pos() % 8 == 0, msg="i=\{i} -> bit_pos=\{br.bit_pos()}")
    assert_true(br.bit_pos() >= i, msg="对齐不应回退：i=\{i}")
    assert_true(br.bit_pos() <= 32, msg="对齐不应越界：i=\{i}")
    assert_true(br.remaining() >= 0, msg="剩余位数不应为负：i=\{i}")
    i = i + 1
  }
}

///|
test "align_to_byte 的具体行为" {
  let br = BitReader::new(b"\xFF\xFF")
  br.align_to_byte()
  assert_eq(br.bit_pos(), 0, msg="已经对齐时是空操作")
  br.skip_bits(3)
  br.align_to_byte()
  assert_eq(br.bit_pos(), 8)
  br.skip_bits(5)
  assert_eq(br.bit_pos(), 13)
  br.align_to_byte()
  assert_eq(br.bit_pos(), 16)
  br.align_to_byte()
  assert_eq(br.bit_pos(), 16)
  assert_eq(br.remaining(), 0)
}

///|
test "align_to_byte 在数据末尾不越界" {
  let br = BitReader::new(b"\x1F")
  br.skip_bits(3)
  assert_eq(br.remaining(), 5)
  br.align_to_byte()
  assert_eq(br.bit_pos(), 8, msg="剩余不足一字节时停在数据末尾（仍是 8 的倍数）")
  assert_eq(br.bit_pos() % 8, 0)
  assert_eq(br.remaining(), 0)
}

///|
test "align_to_byte 后可继续按字节读" {
  let br = BitReader::new(b"\x05\xAB\xCD")
  br.skip_bits(3)
  br.align_to_byte()
  assert_eq(br.bit_pos(), 8)
  assert_eq(br.read_bits(8), 0xAB)
  assert_eq(br.read_bits(8), 0xCD)
}
