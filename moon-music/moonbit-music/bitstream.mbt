// moonbit-music —— MSB-first 位流读写
//
// 只依赖 moonbitlang/core，不 import 任何其他包，也不假设别的 .mbt 文件存在。
// 接口契约见 CONTRACT.md。
//
// 本文件提供两个类型：
//   - BitReader：FLAC / MP3 / Vorbis 共用的 MSB-first 位读取器
//   - BitWriter：MSB-first 位写入器（为后续编码器预留，也用于往返测试）

///|
/// MSB-first 位读取器（FLAC / MP3 / Vorbis 都是 MSB-first 打包）。
///
/// 位偏移从 0 开始计，位 0 是 `data[0]` 的最高位。例如对字节 `0xA0`
/// （`1010_0000`）调用 `read_bits(3)` 得到 `0b101` = 5。
///
/// 所有读取方法在剩余位不足时抛 `AudioError::Truncated`，不会 panic。
/// 字段与契约一致（`priv data : Bytes` / `priv bit_pos : Int`），只是按 MoonBit
/// 的语法要求把游标声明为 `mut`；字段是私有的，这不影响任何公开签名。
pub(all) struct BitReader {
  priv data : Bytes
  priv mut bit_pos : Int
}

///|
/// 从字节序列构造读取器，位偏移为 0。
pub fn BitReader::new(data : Bytes) -> BitReader {
  { data, bit_pos: 0 }
}

///|
/// 当前可读的剩余位数（`bit_pos` 永远不会超过总位数，因此结果 >= 0）。
pub fn BitReader::remaining(self : BitReader) -> Int {
  self.data.length() * 8 - self.bit_pos
}

///|
/// 当前位偏移（单位是**位**，不是字节）。
pub fn BitReader::bit_pos(self : BitReader) -> Int {
  let pos = self.bit_pos
  pos
}

///|
/// MSB-first 读取 `n` 位（`0 <= n <= 64`）。
///
/// 最先读出的是最高位：`read_bits(3)` 对 `0xA0` 返回 `0b101` = 5。
/// `n == 0` 返回 0 且不移动位偏移；`n` 超出 `0..=64` 抛 `Unsupported`。
///
/// 返回类型是 32 位有符号的 `Int`，因此 `n > 32` 时只保留读到的 64 位里的
/// **低 32 位**。需要完整的宽值请改用 `read_utf8_int` 之类的 Int64 接口。
pub fn BitReader::read_bits(self : BitReader, n : Int) -> Int raise AudioError {
  if n < 0 || n > 64 {
    raise AudioError::Unsupported(
      "BitReader::read_bits: 位宽必须在 0..=64 之间，实际为 \{n}",
    )
  }
  if n == 0 {
    return 0
  }
  let available = self.remaining()
  if available < n {
    raise AudioError::Truncated(
      offset=self.bit_pos,
      needed=n,
      available~,
    )
  }
  // 累积到 Int64：Int 只有 32 位，直接左移会在 n > 32 时丢位。
  let mut acc : Int64 = 0
  let mut pos = self.bit_pos
  let stop = pos + n
  while pos < stop {
    let bit_off = pos & 7
    let mut take = 8 - bit_off
    if take > stop - pos {
      take = stop - pos
    }
    // 本字节里从 bit_off 起、共 take 位，右移到最低位后取出。
    let byte = self.data[pos >> 3].to_int()
    let chunk = (byte >> (8 - bit_off - take)) & ((1 << take) - 1)
    acc = (acc << take) | chunk.to_int64()
    pos = pos + take
  }
  self.bit_pos = stop
  acc.to_int()
}

///|
/// 读取 `n` 位**无符号**值，`0 <= n <= 32`。
///
/// `n == 0` 返回 0。注意 `Int` 是 32 位有符号类型，所以 `read_uint(32)` 在
/// 最高位为 1 时会得到负数（位模式原样保留，语义上等价于无符号值）。
pub fn BitReader::read_uint(self : BitReader, n : Int) -> Int raise AudioError {
  if n < 0 || n > 32 {
    raise AudioError::Unsupported(
      "BitReader::read_uint: 位宽必须在 0..=32 之间，实际为 \{n}",
    )
  }
  self.read_bits(n)
}

///|
/// 读取 `n` 位**有符号**值（二进制补码），`0 <= n <= 32`。
///
/// `read_int(3)` 对 `0b101` 返回 `-3`；`read_int(32)` 直接返回 32 位位模式。
pub fn BitReader::read_int(self : BitReader, n : Int) -> Int raise AudioError {
  if n < 0 || n > 32 {
    raise AudioError::Unsupported(
      "BitReader::read_int: 位宽必须在 0..=32 之间，实际为 \{n}",
    )
  }
  if n == 0 {
    return 0
  }
  let raw = self.read_bits(n)
  // n == 32 时 1 << 32 会溢出 Int，而 raw 本身就是补码表示，直接返回。
  if n >= 32 {
    return raw
  }
  if (raw & (1 << (n - 1))) != 0 {
    raw - (1 << n)
  } else {
    raw
  }
}

///|
/// 读取一元码：连续 `count` 个 0 之后跟一个 1，返回 `count`（FLAC / MP3 用）。
///
/// 遇到首位就是 1 时返回 0。一路读到数据末尾都没有 1 时抛 `Truncated`。
pub fn BitReader::read_unary(self : BitReader) -> Int raise AudioError {
  let total = self.data.length() * 8
  let mut pos = self.bit_pos
  let mut count = 0
  while pos < total {
    let byte = self.data[pos >> 3].to_int()
    let bit = (byte >> (7 - (pos & 7))) & 1
    pos = pos + 1
    if bit == 1 {
      self.bit_pos = pos
      return count
    }
    count = count + 1
  }
  raise AudioError::Truncated(offset=pos, needed=1, available=0)
}

///|
/// 丢弃 `n` 位。剩余位不足时抛 `Truncated`；`n == 0` 是空操作。
pub fn BitReader::skip_bits(self : BitReader, n : Int) -> Unit raise AudioError {
  if n < 0 {
    raise AudioError::Unsupported("BitReader::skip_bits: 位宽不能为负，实际为 \{n}")
  }
  let available = self.remaining()
  if available < n {
    raise AudioError::Truncated(
      offset=self.bit_pos,
      needed=n,
      available~,
    )
  }
  self.bit_pos = self.bit_pos + n
}

///|
/// 对齐到下一个字节边界（丢弃当前字节里剩余的位）。
///
/// 已经对齐时是空操作。若剩余位不足以走完当前字节，则停在数据末尾
/// （`data.length() * 8` 本身是 8 的倍数，所以对齐后 `bit_pos()` 一定
/// 是 8 的倍数，且不会抛错、不会越界）。
pub fn BitReader::align_to_byte(self : BitReader) -> Unit {
  let total = self.data.length() * 8
  let rem = self.bit_pos & 7
  if rem != 0 {
    let aligned = self.bit_pos + (8 - rem)
    self.bit_pos = if aligned < total { aligned } else { total }
  }
}

///|
/// 读取 FLAC 风格的 UTF-8 式变长整数，返回 `Int64`。
///
/// 首字节前导 1 的个数决定总字节数：
/// `0xxxxxxx` = 1 字节、`110xxxxx` = 2 字节、`1110xxxx` = 3 字节、
/// `11110xxx` = 4 字节、`111110xx` = 5 字节、`1111110x` = 6 字节、
/// `11111110` + 6 个续字节 = 7 字节（共 36 位）。
///
/// 续字节必须是 `10xxxxxx`。非法前导字节（`10xxxxxx` 或 `11111111`）与
/// 前缀错误的续字节抛 `AudioError::InvalidMagic`；字节不够抛 `Truncated`。
///
/// 用 `Int64` 返回是必须的：36 位会溢出 `Int`。FLAC 的 frame header 用它
/// 编码帧号 / 样本号，可能超出 `Int32`。
pub fn BitReader::read_utf8_int(self : BitReader) -> Int64 raise AudioError {
  let first = self.read_bits(8)
  if (first & 0x80) == 0 {
    // 0xxxxxxx —— 单字节，7 位有效。
    return first.to_int64()
  }
  // 数前导 1 的个数（= 总字节数）。
  let mut total_bytes = 0
  let mut mask = 0x80
  while (first & mask) != 0 {
    total_bytes = total_bytes + 1
    mask = mask >> 1
  }
  // total_bytes == 1 表示首字节是 10xxxxxx，不能作前导；
  // total_bytes == 8 表示 11111111，FLAC 未定义。
  if total_bytes == 1 || total_bytes > 7 {
    raise AudioError::InvalidMagic(
      "BitReader::read_utf8_int: 非法前导字节 \{first}（前导 1 的个数为 \{total_bytes}）",
    )
  }
  let mut value : Int64 = (first & ((1 << (7 - total_bytes)) - 1)).to_int64()
  let mut i = 1
  while i < total_bytes {
    let cont = self.read_bits(8)
    if (cont & 0xC0) != 0x80 {
      raise AudioError::InvalidMagic(
        "BitReader::read_utf8_int: 续字节缺少 10 前缀（第 \{i} 个续字节为 \{cont}）",
      )
    }
    value = (value << 6) | (cont & 0x3F).to_int64()
    i = i + 1
  }
  value
}

///|
/// MSB-first 位写入器（为后续编码器预留，也用于和 `BitReader` 做往返验证）。
///
/// 内部保存已完成的整字节 `buf`，以及不足一个字节的待定低位 `acc`。
pub(all) struct BitWriter {
  priv buf : Array[Byte]
  priv mut bit_len : Int
  priv mut acc : Int
}

///|
/// 构造空写入器。
pub fn BitWriter::new() -> BitWriter {
  { buf: [], bit_len: 0, acc: 0 }
}

///|
/// 已写入的位数（**不含**末尾补齐到字节边界的补零位）。
pub fn BitWriter::bit_length(self : BitWriter) -> Int {
  self.bit_len
}

///|
/// MSB-first 写入 `value` 的**低 `n` 位**。
///
/// 参数顺序是 `(value, n)`，与 `BitReader::read_bits(n) -> value` 互逆。
/// `n <= 0` 是空操作；`n > 32` 时按 32 位处理（`value` 本身只有 32 位）。
pub fn BitWriter::write_bits(self : BitWriter, value : Int, n : Int) -> Unit {
  if n <= 0 {
    return
  }
  let width = if n > 32 { 32 } else { n }
  let mut i = width - 1
  while i >= 0 {
    let bit = (value >> i) & 1
    self.acc = (self.acc << 1) | bit
    self.bit_len = self.bit_len + 1
    if (self.bit_len & 7) == 0 {
      self.buf.push(self.acc.to_byte())
      self.acc = 0
    }
    i = i - 1
  }
}

///|
/// 写入一元码：`count` 个 0 后跟一个 1（与 `BitReader::read_unary` 互逆）。
///
/// `count <= 0` 时只写一个 1，之后 `read_unary()` 返回 0。
pub fn BitWriter::write_unary(self : BitWriter, count : Int) -> Unit {
  let mut i = 0
  while i < count {
    self.write_bits(0, 1)
    i = i + 1
  }
  self.write_bits(1, 1)
}

///|
/// 补齐到字节边界（补 0）并返回结果。
///
/// 不修改写入器状态：可以重复调用，多次结果一致；之后还能继续写入。
pub fn BitWriter::to_bytes(self : BitWriter) -> Bytes {
  let out = Buffer()
  for b in self.buf {
    out.write_byte(b)
  }
  let tail = self.bit_len & 7
  if tail != 0 {
    out.write_byte((self.acc << (8 - tail)).to_byte())
  }
  out.to_bytes()
}
