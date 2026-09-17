// moonbit-music —— MP3 测试（黑盒）
//
// 全部测试数据都是**手工构造的字节**，没有用任何自己写的编码器生成音频。
// 覆盖：帧头全字段、保留值报错、帧长公式、bitrate 查表、ID3v2/ID3v1、
// 帧扫描与重同步、side info 四种布局、位读取器、Huffman 表自洽、区域划分。

// ============================================================
// 构造辅助
// ============================================================

///|
/// 由 0..255 的整数列表构造 `Bytes`（`Bytes` 不可变，走 Array[Byte]）。
fn mp3_test_bytes(values : Array[Int]) -> Bytes {
  let arr : Array[Byte] = []
  for v in values {
    arr.push(v.to_byte())
  }
  Bytes::from_array(arr)
}

///|
/// 4 字节帧头。
fn mp3_test_header(b0 : Int, b1 : Int, b2 : Int, b3 : Int) -> Bytes {
  mp3_test_bytes([b0, b1, b2, b3])
}

///|
/// 一帧：给定帧头 + 补 0 到 `size` 字节。
fn mp3_test_frame(header : Array[Int], size : Int) -> Array[Int] {
  let out : Array[Int] = []
  for b in header {
    out.push(b)
  }
  while out.length() < size {
    out.push(0)
  }
  out
}

///|
/// 一帧：给定帧头 + 指定的帧体字节 + 补 0 到 `size` 字节。
fn mp3_test_frame_with_body(
  header : Array[Int],
  body : Array[Int],
  size : Int,
) -> Array[Int] {
  let out : Array[Int] = []
  for b in header {
    out.push(b)
  }
  for b in body {
    out.push(b)
  }
  while out.length() < size {
    out.push(0)
  }
  out
}

///|
/// 拼接若干 `Array[Int]`。
fn mp3_test_concat(parts : Array[Array[Int]]) -> Array[Int] {
  let out : Array[Int] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  out
}

///|
/// 把 0/1 位列表补齐到字节边界并打包成字节。
fn mp3_test_pack_bits(bits : Array[Int]) -> Array[Int] {
  let out : Array[Int] = []
  let mut index = 0
  while index < bits.length() {
    let mut byte = 0
    let mut j = 0
    while j < 8 {
      let bit = if index + j < bits.length() { bits[index + j] } else { 0 }
      byte = (byte << 1) | bit
      j = j + 1
    }
    out.push(byte)
    index = index + 8
  }
  out
}

///|
/// 把错误归类成短标签，便于断言。
fn mp3_test_err_tag(data : Bytes, offset : Int) -> String {
  try {
    ignore(mp3_parse_frame_header(data, offset))
    "none"
  } catch {
    AudioError::InvalidMagic(_) => "InvalidMagic"
    AudioError::Unsupported(_) => "Unsupported"
    AudioError::Truncated(..) => "Truncated"
    _ => "other"
  }
}

///|
/// 对可能抛错的调用取错误标签。
fn mp3_test_call_tag(f : () -> Unit raise) -> String {
  try {
    f()
    "none"
  } catch {
    AudioError::InvalidMagic(_) => "InvalidMagic"
    AudioError::Unsupported(_) => "Unsupported"
    AudioError::Truncated(..) => "Truncated"
    AudioError::ChecksumMismatch(..) => "ChecksumMismatch"
    AudioError::LimitExceeded(_) => "LimitExceeded"
    _ => "other"
  }
}

///|
/// 手工构造一个 granule 声道结构，用于区域划分测试。
fn mp3_test_granule(
  window_switching : Int,
  table_select : Array[Int],
  region0_count : Int,
  region1_count : Int,
) -> Mp3GranuleChannel {
  {
    part2_3_length: 0,
    big_values: 0,
    global_gain: 0,
    scalefac_compress: 0,
    window_switching_flag: window_switching,
    block_type: if window_switching == 1 {
      2
    } else {
      0
    },
    mixed_block_flag: 0,
    table_select,
    subblock_gain: [0, 0, 0],
    region0_count,
    region1_count,
    preflag: 0,
    scalefac_scale: 0,
    count1table_select: 0,
  }
}

// ============================================================
// 1. 帧头解析：MPEG1 Layer III 44100Hz 128kbps stereo
// ============================================================

///|
/// MPEG1 Layer III、44100 Hz、128 kbps、stereo 的标准帧头 `FF FB 90 00`。
test "MPEG1 Layer III 44100Hz 128kbps stereo 帧头" {
  let data = mp3_test_header(0xFF, 0xFB, 0x90, 0x00)
  let h = mp3_parse_frame_header(data, 0)
  assert_true(h.version == Mp3Version::Mpeg1)
  assert_true(h.channel_mode == Mp3ChannelMode::Stereo)
  assert_eq(h.bitrate_kbps, 128)
  assert_eq(h.sample_rate, 44100)
  assert_eq(h.padding, 0)
  assert_eq(h.private_bit, 0)
  assert_eq(h.mode_extension, 0)
  assert_eq(h.emphasis, 0)
  assert_eq(h.channels, 2)
  assert_eq(h.samples_per_frame, 1152)
  assert_eq(h.has_crc, false)
  assert_eq(h.copyright, false)
  assert_eq(h.original, false)
  // 144 * 128000 / 44100 = 417.9… → 417
  assert_eq(h.frame_size, 417)
}

///|
test "帧头可选位：protection / copyright / original / emphasis / 声道模式" {
  // 0xFA: protection bit = 0 → 有 CRC
  let with_crc = mp3_parse_frame_header(
    mp3_test_header(0xFF, 0xFA, 0x90, 0x00),
    0,
  )
  assert_eq(with_crc.has_crc, true)
  assert_eq(mp3_side_info_offset(with_crc, 0), 6)
  assert_eq(mp3_main_data_offset(with_crc, 0), 38)
  let no_crc = mp3_parse_frame_header(
    mp3_test_header(0xFF, 0xFB, 0x90, 0x00),
    0,
  )
  assert_eq(no_crc.has_crc, false)
  assert_eq(mp3_side_info_offset(no_crc, 0), 4)
  assert_eq(mp3_main_data_offset(no_crc, 0), 36)
  // b3 = 0b01_10_1_1_01 → JointStereo / mode_ext 2 / copyright 1 / original 1 / emphasis 01
  let b3 = (1 << 6) | (2 << 4) | (1 << 3) | (1 << 2) | 1
  let h = mp3_parse_frame_header(mp3_test_header(0xFF, 0xFB, 0x90, b3), 0)
  assert_true(h.channel_mode == Mp3ChannelMode::JointStereo)
  assert_eq(h.mode_extension, 2)
  assert_eq(h.copyright, true)
  assert_eq(h.original, true)
  assert_eq(h.emphasis, 1)
  assert_eq(h.channels, 2)
  // b3 = 0x80 → mode bits 10 → DualChannel
  let dual = mp3_parse_frame_header(mp3_test_header(0xFF, 0xFB, 0x90, 0x80), 0)
  assert_true(dual.channel_mode == Mp3ChannelMode::DualChannel)
  assert_eq(dual.channels, 2)
  // b2 = 0x91 → private bit 置位、padding 0
  let private_bit_header = mp3_parse_frame_header(
    mp3_test_header(0xFF, 0xFB, 0x91, 0x00),
    0,
  )
  assert_eq(private_bit_header.private_bit, 1)
  assert_eq(private_bit_header.padding, 0)
}

// ============================================================
// 2 & 9. padding 对帧长的影响
// ============================================================

///|
test "padding 位使帧长恰好 +1" {
  let no_pad = mp3_parse_frame_header(
    mp3_test_header(0xFF, 0xFB, 0x90, 0x00),
    0,
  )
  let pad = mp3_parse_frame_header(mp3_test_header(0xFF, 0xFB, 0x92, 0x00), 0)
  assert_eq(no_pad.padding, 0)
  assert_eq(pad.padding, 1)
  assert_eq(no_pad.frame_size, 417)
  assert_eq(pad.frame_size, 418)
  assert_eq(pad.frame_size, no_pad.frame_size + 1)
  // MPEG2 也要一样
  let no_pad2 = mp3_parse_frame_header(
    mp3_test_header(0xFF, 0xF3, 0x80, 0x00),
    0,
  )
  let pad2 = mp3_parse_frame_header(mp3_test_header(0xFF, 0xF3, 0x82, 0x00), 0)
  assert_eq(no_pad2.frame_size, 208)
  assert_eq(pad2.frame_size, 209)
}

// ============================================================
// 3. MPEG2 帧头：576 样本 & 72 公式
// ============================================================

///|
test "MPEG2 Layer III 22050Hz 64kbps：576 样本 / 72 公式" {
  // 0xF3 = 111 10 01 1 → MPEG2 / Layer III / 无 CRC
  let h = mp3_parse_frame_header(mp3_test_header(0xFF, 0xF3, 0x80, 0x00), 0)
  assert_true(h.version == Mp3Version::Mpeg2)
  assert_eq(h.sample_rate, 22050)
  assert_eq(h.bitrate_kbps, 64)
  assert_eq(h.samples_per_frame, 576)
  // 72 * 64000 / 22050 = 208.97… → 208
  assert_eq(h.frame_size, 208)
  assert_eq(h.channels, 2)
}

///|
test "MPEG2 采样率表 22050 / 24000 / 16000" {
  let a = mp3_parse_frame_header(mp3_test_header(0xFF, 0xF3, 0x80, 0x00), 0)
  let b = mp3_parse_frame_header(mp3_test_header(0xFF, 0xF3, 0x84, 0x00), 0)
  let c = mp3_parse_frame_header(mp3_test_header(0xFF, 0xF3, 0x88, 0x00), 0)
  assert_eq(a.sample_rate, 22050)
  assert_eq(b.sample_rate, 24000)
  assert_eq(c.sample_rate, 16000)
  assert_eq(a.samples_per_frame, 576)
  assert_eq(c.samples_per_frame, 576)
}

// ============================================================
// 4. MPEG2.5 采样率表
// ============================================================

///|
test "MPEG2.5 采样率表 11025 / 12000 / 8000" {
  // 0xE3 = 111 00 01 1 → MPEG2.5 / Layer III
  let a = mp3_parse_frame_header(mp3_test_header(0xFF, 0xE3, 0x60, 0x00), 0)
  assert_true(a.version == Mp3Version::Mpeg25)
  assert_eq(a.sample_rate, 11025)
  assert_eq(a.bitrate_kbps, 48)
  assert_eq(a.samples_per_frame, 576)
  // 72 * 48000 / 11025 = 313.46… → 313
  assert_eq(a.frame_size, 313)
  let b = mp3_parse_frame_header(mp3_test_header(0xFF, 0xE3, 0x64, 0x00), 0)
  assert_eq(b.sample_rate, 12000)
  let c = mp3_parse_frame_header(mp3_test_header(0xFF, 0xE3, 0x68, 0x00), 0)
  assert_eq(c.sample_rate, 8000)
  // MPEG2.5 也有 padding
  let d = mp3_parse_frame_header(mp3_test_header(0xFF, 0xE3, 0x62, 0x00), 0)
  assert_eq(d.frame_size, 314)
}

// ============================================================
// 5. bitrate index 查表
// ============================================================

///|
test "MPEG1 Layer III bitrate 查表（至少 3 个 index）" {
  let i1 = mp3_parse_frame_header(mp3_test_header(0xFF, 0xFB, 0x10, 0x00), 0)
  let i5 = mp3_parse_frame_header(mp3_test_header(0xFF, 0xFB, 0x50, 0x00), 0)
  let i9 = mp3_parse_frame_header(mp3_test_header(0xFF, 0xFB, 0x90, 0x00), 0)
  let i14 = mp3_parse_frame_header(mp3_test_header(0xFF, 0xFB, 0xE0, 0x00), 0)
  assert_eq(i1.bitrate_kbps, 32)
  assert_eq(i5.bitrate_kbps, 64)
  assert_eq(i9.bitrate_kbps, 128)
  assert_eq(i14.bitrate_kbps, 320)
  // 帧长随比特率变化
  assert_eq(i14.frame_size, 1044) // 144*320000/44100 = 1044.9 → 1044
}

///|
test "MPEG2 / 2.5 Layer III bitrate 查表走另一张表" {
  let i1 = mp3_parse_frame_header(mp3_test_header(0xFF, 0xF3, 0x10, 0x00), 0)
  let i9 = mp3_parse_frame_header(mp3_test_header(0xFF, 0xF3, 0x90, 0x00), 0)
  let i14 = mp3_parse_frame_header(mp3_test_header(0xFF, 0xF3, 0xE0, 0x00), 0)
  assert_eq(i1.bitrate_kbps, 8)
  assert_eq(i9.bitrate_kbps, 80)
  assert_eq(i14.bitrate_kbps, 160)
  let j = mp3_parse_frame_header(mp3_test_header(0xFF, 0xE3, 0xE0, 0x00), 0)
  assert_eq(j.bitrate_kbps, 160)
  // bitrate index 15 在 MPEG2.5 下同样非法
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xE3, 0xF0, 0x00), 0),
    "InvalidMagic",
  )
}

// ============================================================
// 6. 各保留值 / 非法值 → 正确报错
// ============================================================

///|
test "保留值与非法值全部报错" {
  // version = 01（保留）0xEB = 111 01 01 1
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xEB, 0x90, 0x00), 0),
    "InvalidMagic",
  )
  // layer = 00（保留）0xF9 = 111 11 00 1
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xF9, 0x90, 0x00), 0),
    "InvalidMagic",
  )
  // bitrate index 1111
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xFB, 0xF0, 0x00), 0),
    "InvalidMagic",
  )
  // sampling rate index 11
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xFB, 0x9C, 0x00), 0),
    "InvalidMagic",
  )
  // emphasis 10
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xFB, 0x90, 0x02), 0),
    "InvalidMagic",
  )
  // 同步字不匹配
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFE, 0xFB, 0x90, 0x00), 0),
    "InvalidMagic",
  )
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0x1B, 0x90, 0x00), 0),
    "InvalidMagic",
  )
}

///|
test "非 Layer III 与 free bitrate 抛 Unsupported" {
  // layer = 10 → Layer II
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xFD, 0x90, 0x00), 0),
    "Unsupported",
  )
  // layer = 11 → Layer I
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xFF, 0x90, 0x00), 0),
    "Unsupported",
  )
  // bitrate index 0000 → free
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xFB, 0x00, 0x00), 0),
    "Unsupported",
  )
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xF3, 0x00, 0x00), 0),
    "Unsupported",
  )
  // MPEG2.5 free
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xE3, 0x00, 0x00), 0),
    "Unsupported",
  )
}

///|
test "字节不足抛 Truncated 而不是 panic" {
  assert_eq(mp3_test_err_tag(mp3_test_bytes([0xFF, 0xFB]), 0), "Truncated")
  assert_eq(mp3_test_err_tag(mp3_test_bytes([]), 0), "Truncated")
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xFB, 0x90, 0x00), 1),
    "Truncated",
  )
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xFB, 0x90, 0x00), 99),
    "Truncated",
  )
  assert_eq(
    mp3_test_err_tag(mp3_test_header(0xFF, 0xFB, 0x90, 0x00), -1),
    "Truncated",
  )
}

// ============================================================
// 7. ID3v2 前缀
// ============================================================

///|
/// 构造一个 `10 + size` 字节的 ID3v2.3 头（syncsafe size）。
fn mp3_test_id3v2(size : Int) -> Array[Int] {
  let out : Array[Int] = [0x49, 0x44, 0x33, 3, 0, 0]
  out.push((size >> 21) & 0x7F)
  out.push((size >> 14) & 0x7F)
  out.push((size >> 7) & 0x7F)
  out.push(size & 0x7F)
  let mut i = 0
  while i < size {
    out.push(0)
    i = i + 1
  }
  out
}

///|
test "带 ID3v2 前缀的文件能定位到第一帧" {
  let frame = mp3_test_frame([0xFF, 0xFB, 0x90, 0x00], 417)
  let data = mp3_test_bytes(
    mp3_test_concat([mp3_test_id3v2(100), frame, frame]),
  )
  assert_eq(mp3_skip_id3v2(data), 110)
  assert_eq(mp3_first_frame_offset(data), 110)
  let frames = mp3_scan_frames(data)
  assert_eq(frames.length(), 2)
  assert_eq(frames[0], 110)
  assert_eq(frames[1], 527)
  let fmt = mp3_info(data)
  assert_eq(fmt.sample_rate, 44100)
  assert_eq(fmt.channels, 2)
  assert_eq(fmt.bits_per_sample, 16)
}

///|
test "ID3v2 头长度与 syncsafe 编码" {
  let data = mp3_test_bytes(
    mp3_test_concat([
      mp3_test_id3v2(0),
      mp3_test_frame([0xFF, 0xFB, 0x90, 0x00], 417),
    ]),
  )
  assert_eq(mp3_skip_id3v2(data), 10)
  // 没有 "ID3" 前缀 → 0
  assert_eq(mp3_skip_id3v2(mp3_test_bytes([0xFF, 0xFB, 0x90, 0x00])), 0)
  assert_eq(mp3_skip_id3v2(mp3_test_bytes([])), 0)
  // 只有 3 字节 → 0（不足 10 字节）
  assert_eq(mp3_skip_id3v2(mp3_test_bytes([0x49, 0x44, 0x33])), 0)
}

// ============================================================
// 8. ID3v1 尾部
// ============================================================

///|
/// 128 字节 ID3v1 标签。
fn mp3_test_id3v1() -> Array[Int] {
  let out : Array[Int] = [0x54, 0x41, 0x47]
  let mut i = 3
  while i < 128 {
    out.push(0)
    i = i + 1
  }
  out
}

///|
test "ID3v1 尾部不会被当成帧，也不会被计入音频区" {
  let frame = mp3_test_frame([0xFF, 0xFB, 0x90, 0x00], 417)
  let data = mp3_test_bytes(mp3_test_concat([frame, frame, mp3_test_id3v1()]))
  assert_eq(data.length(), 834 + 128)
  assert_eq(mp3_id3v1_offset(data), 834)
  let frames = mp3_scan_frames(data)
  assert_eq(frames.length(), 2)
  assert_eq(frames[0], 0)
  assert_eq(frames[1], 417)
  let fmt = mp3_info(data)
  assert_eq(fmt.sample_rate, 44100)
}

///|
test "没有 ID3v1 时返回 -1，且太短的文件不会误判" {
  assert_eq(mp3_id3v1_offset(mp3_test_bytes([])), -1)
  assert_eq(mp3_id3v1_offset(mp3_test_bytes([0x54, 0x41, 0x47])), -1)
  let frame = mp3_test_frame([0xFF, 0xFB, 0x90, 0x00], 417)
  assert_eq(
    mp3_id3v1_offset(mp3_test_bytes(mp3_test_concat([frame, frame]))),
    -1,
  )
}

// ============================================================
// 9. 帧间垃圾字节 → 重新同步
// ============================================================

///|
test "帧间有垃圾字节时字节对齐重同步" {
  let frame = mp3_test_frame([0xFF, 0xFB, 0x90, 0x00], 417)
  // 头部垃圾里埋一个「看起来合法但无法被下一帧确认」的假同步
  let junk_head : Array[Int] = [0x00, 0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00]
  let junk_mid : Array[Int] = [0x11, 0xFF, 0xFB, 0x90, 0x00, 0x22, 0x33, 0x44]
  let data = mp3_test_bytes(
    mp3_test_concat([junk_head, frame, frame, junk_mid, frame, frame]),
  )
  let frames = mp3_scan_frames(data)
  assert_eq(frames.length(), 4)
  assert_eq(frames[0], 8)
  assert_eq(frames[1], 425)
  assert_eq(frames[2], 850)
  assert_eq(frames[3], 1267)
}

///|
test "全都是垃圾时同步失败，抛 InvalidMagic" {
  let junk : Array[Int] = []
  let mut i = 0
  while i < 64 {
    junk.push(0x5A)
    i = i + 1
  }
  let data = mp3_test_bytes(junk)
  let tag = mp3_test_call_tag(() => ignore(mp3_first_frame_offset(data)))
  assert_eq(tag, "InvalidMagic")
  let tag2 = mp3_test_call_tag(() => ignore(mp3_info(data)))
  assert_eq(tag2, "InvalidMagic")
}

///|
test "只有一个合法帧头（后面没有帧）时不算同步成功" {
  let frame = mp3_test_frame([0xFF, 0xFB, 0x90, 0x00], 417)
  let data = mp3_test_bytes(mp3_test_concat([frame, [0x00, 0x00, 0x00, 0x00]]))
  let tag = mp3_test_call_tag(() => ignore(mp3_first_frame_offset(data)))
  assert_eq(tag, "InvalidMagic")
}

///|
test "末尾不完整的残帧被丢弃" {
  let frame = mp3_test_frame([0xFF, 0xFB, 0x90, 0x00], 417)
  let partial : Array[Int] = [0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00]
  let data = mp3_test_bytes(mp3_test_concat([frame, frame, partial]))
  let frames = mp3_scan_frames(data)
  // 尾部 6 字节不足以构成完整帧，`frame+frame` 之后的位置帧头会命中 partial，
  // 但 frame_size=417 超出音频区 → 不记录
  assert_eq(frames.length(), 2)
  assert_eq(frames[0], 0)
  assert_eq(frames[1], 417)
}

///|
test "帧头合法但帧尾越界的假同步不会中断后续真帧的扫描" {
  // f0/f1 是 MPEG1 44100（417 字节），f2/f3 是 MPEG2 22050（208 字节）
  let f1 = mp3_test_frame([0xFF, 0xFB, 0x90, 0x00], 417)
  let f2 = mp3_test_frame([0xFF, 0xF3, 0x80, 0x00], 208)
  // 垃圾恰好落在一个「合法但 frame_size=1044」的假帧头上（320kbps @44100）
  let junk : Array[Int] = [0xFF, 0xFB, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00]
  let data = mp3_test_bytes(mp3_test_concat([f1, f1, junk, f2, f2]))
  let frames = mp3_scan_frames(data)
  assert_eq(frames.length(), 4)
  assert_eq(frames[0], 0)
  assert_eq(frames[1], 417)
  assert_eq(frames[2], 842)
  assert_eq(frames[3], 1050)
}

// ============================================================
// 10. mp3_info / decode_mp3 / mp3_decoder
// ============================================================

///|
test "mp3_info 与 decode_mp3 的格式信息一致（decode_mp3 抛 Unsupported）" {
  let frame = mp3_test_frame([0xFF, 0xFB, 0x90, 0x00], 417)
  let data = mp3_test_bytes(mp3_test_concat([frame, frame]))
  let fmt = mp3_info(data)
  assert_eq(fmt.sample_rate, 44100)
  assert_eq(fmt.channels, 2)
  assert_eq(fmt.bits_per_sample, 16)
  // 单声道
  let mono = mp3_test_bytes(
    mp3_test_concat([
      mp3_test_frame([0xFF, 0xFB, 0x90, 0xC0], 417),
      mp3_test_frame([0xFF, 0xFB, 0x90, 0xC0], 417),
    ]),
  )
  assert_eq(mp3_info(mono).channels, 1)
  // MPEG2 22050
  let mpeg2 = mp3_test_bytes(
    mp3_test_concat([
      mp3_test_frame([0xFF, 0xF3, 0x80, 0x00], 208),
      mp3_test_frame([0xFF, 0xF3, 0x80, 0x00], 208),
    ]),
  )
  assert_eq(mp3_info(mpeg2).sample_rate, 22050)
  // decode_mp3 必须明确报 Unsupported，而不是返回占位音频
  let tag = mp3_test_call_tag(() => ignore(decode_mp3(data)))
  assert_eq(tag, "Unsupported")
  let tag_mono = mp3_test_call_tag(() => ignore(decode_mp3(mono)))
  assert_eq(tag_mono, "Unsupported")
}

///|
test "decode_mp3 对畸形输入仍然报结构错误" {
  let junk : Array[Int] = []
  let mut i = 0
  while i < 64 {
    junk.push(0x00)
    i = i + 1
  }
  assert_eq(
    mp3_test_call_tag(() => ignore(decode_mp3(mp3_test_bytes(junk)))),
    "InvalidMagic",
  )
  assert_eq(
    mp3_test_call_tag(() => ignore(decode_mp3(mp3_test_bytes([0xFF, 0xFB])))),
    "Truncated",
  )
}

///|
test "mp3_decoder 明确抛 Unsupported（Decoder 状态无法承载字节流）" {
  let frame = mp3_test_frame([0xFF, 0xFB, 0x90, 0x00], 417)
  let data = mp3_test_bytes(mp3_test_concat([frame, frame]))
  let tag = mp3_test_call_tag(() => ignore(mp3_decoder(data)))
  assert_eq(tag, "Unsupported")
}

// ============================================================
// MSB-first 位读取器
// ============================================================

///|
test "位读取器是 MSB-first 且能跨字节" {
  let data = mp3_test_bytes([0b10110010, 0b01011101])
  let r = Mp3BitReader::new(data, 0)
  assert_eq(r.bits_left(), 16)
  assert_eq(r.read_bits(3), 0b101)
  assert_eq(r.read_bits(5), 0b10010)
  assert_eq(r.bit_offset(), 8)
  assert_eq(r.read_bits(4), 0b0101)
  assert_eq(r.bits_left(), 4)
  assert_eq(r.read_bits(0), 0)
  assert_eq(r.read_bits(4), 0b1101)
  assert_eq(r.bits_left(), 0)
}

///|
test "位读取器越界抛 Truncated 不 panic" {
  let data = mp3_test_bytes([0xFF])
  let r = Mp3BitReader::new(data, 0)
  assert_eq(r.read_bits(8), 255)
  let tag = mp3_test_call_tag(() => ignore(r.read_bits(1)))
  assert_eq(tag, "Truncated")
  let tag2 = mp3_test_call_tag(() => r.skip_bits(1))
  assert_eq(tag2, "Truncated")
  let tag3 = mp3_test_call_tag(() => ignore(r.read_bits(25)))
  assert_eq(tag3, "Unsupported")
}

///|
test "位读取器可以从非零位偏移开始" {
  let data = mp3_test_bytes([0b00000101, 0b00000000])
  let r = Mp3BitReader::new(data, 5)
  assert_eq(r.bits_left(), 11)
  assert_eq(r.read_bits(3), 0b101)
  assert_eq(r.bit_offset(), 8)
}

// ============================================================
// side info：17 / 32 / 9 / 17 字节
// ============================================================

///|
/// 检查某种配置下 side info 的字节数，并验证解析**恰好**读满这些字节：
/// 缓冲区只放「帧头 + 正好 size 字节的 side info」，多读一位就会 Truncated。
fn mp3_test_side_info_exact(
  b1 : Int,
  b2 : Int,
  b3 : Int,
  size : Int,
) -> Unit raise {
  let header_bytes : Array[Int] = [0xFF, b1, b2, b3]
  let full = header_bytes.copy()
  let mut i = 0
  while i < size {
    full.push(0xFF)
    i = i + 1
  }
  let data = mp3_test_bytes(full)
  let header = mp3_parse_frame_header(data, 0)
  assert_eq(mp3_side_info_size(header), size)
  assert_eq(mp3_side_info_offset(header, 0), 4)
  assert_eq(mp3_main_data_offset(header, 0), 4 + size)
  let info = mp3_parse_side_info(data, header, 0)
  ignore(info)
  // 少一个字节 → 必须 Truncated
  let short = header_bytes.copy()
  let mut j = 0
  while j < size - 1 {
    short.push(0xFF)
    j = j + 1
  }
  let short_data = mp3_test_bytes(short)
  let tag = mp3_test_call_tag(() => {
    ignore(mp3_parse_side_info(short_data, header, 0))
  })
  assert_eq(tag, "Truncated")
}

///|
test "side info 字节数 17/32/9/17 且解析恰好读满" {
  // MPEG1 mono（b3 = 0xC0 → Mono）
  mp3_test_side_info_exact(0xFB, 0x90, 0xC0, 17)
  // MPEG1 stereo
  mp3_test_side_info_exact(0xFB, 0x90, 0x00, 32)
  // MPEG2 mono
  mp3_test_side_info_exact(0xF3, 0x80, 0xC0, 9)
  // MPEG2 stereo
  mp3_test_side_info_exact(0xF3, 0x80, 0x00, 17)
  // MPEG2.5 stereo
  mp3_test_side_info_exact(0xE3, 0x60, 0x00, 17)
}

///|
test "MPEG1 单声道 side info 全 0 字面向量" {
  let header_bytes : Array[Int] = [0xFF, 0xFB, 0x90, 0xC0]
  let frame = mp3_test_frame(header_bytes, 417)
  let data = mp3_test_bytes(mp3_test_concat([frame, frame]))
  let header = mp3_parse_frame_header(data, 0)
  assert_eq(header.channels, 1)
  let side = mp3_parse_side_info(data, header, 0)
  assert_true(side.version == Mp3Version::Mpeg1)
  assert_eq(side.channels, 1)
  assert_eq(side.main_data_begin, 0)
  assert_eq(side.private_bits, 0)
  assert_eq(side.scfsi.length(), 1)
  assert_eq(side.scfsi[0], 0)
  assert_eq(side.granules.length(), 2)
  assert_eq(side.granules[0].length(), 1)
  assert_eq(side.granules[1].length(), 1)
  let gc = side.granules[0][0]
  assert_eq(gc.part2_3_length, 0)
  assert_eq(gc.big_values, 0)
  assert_eq(gc.global_gain, 0)
  assert_eq(gc.scalefac_compress, 0)
  assert_eq(gc.window_switching_flag, 0)
  assert_eq(gc.block_type, 0)
  assert_eq(gc.mixed_block_flag, 0)
  assert_eq(gc.table_select.length(), 3)
  assert_eq(gc.table_select[2], 0)
  assert_eq(gc.subblock_gain.length(), 3)
  assert_eq(gc.region0_count, 0)
  assert_eq(gc.region1_count, 0)
  assert_eq(gc.preflag, 0)
  assert_eq(gc.scalefac_scale, 0)
  assert_eq(gc.count1table_select, 0)
  // 第二个 granule 也读到了同样的位置
  assert_eq(side.granules[1][0].part2_3_length, 0)
}

///|
test "MPEG1 单声道 side info 全 1 字面向量（136 bit 全 1）" {
  let header_bytes : Array[Int] = [0xFF, 0xFB, 0x90, 0xC0]
  let body : Array[Int] = []
  let mut i = 0
  while i < 17 {
    body.push(0xFF)
    i = i + 1
  }
  let frame = mp3_test_frame_with_body(header_bytes, body, 417)
  let data = mp3_test_bytes(mp3_test_concat([frame, frame]))
  let header = mp3_parse_frame_header(data, 0)
  let side = mp3_parse_side_info(data, header, 0)
  assert_eq(side.main_data_begin, 511) // 9 位
  assert_eq(side.private_bits, 31) // 5 位
  assert_eq(side.scfsi[0], 15) // 4 位
  let gc = side.granules[0][0]
  assert_eq(gc.part2_3_length, 4095) // 12 位
  assert_eq(gc.big_values, 511) // 9 位
  assert_eq(gc.global_gain, 255) // 8 位
  assert_eq(gc.scalefac_compress, 15) // MPEG1: 4 位
  assert_eq(gc.window_switching_flag, 1)
  assert_eq(gc.block_type, 3) // 2 位
  assert_eq(gc.mixed_block_flag, 1)
  assert_eq(gc.table_select[0], 31) // 5 位
  assert_eq(gc.table_select[1], 31) // 5 位
  assert_eq(gc.table_select[2], 0) // 窗口切换时不传输
  assert_eq(gc.subblock_gain[0], 7) // 3 位
  assert_eq(gc.subblock_gain[1], 7)
  assert_eq(gc.subblock_gain[2], 7)
  assert_eq(gc.region0_count, 0) // 窗口切换时不传输
  assert_eq(gc.region1_count, 0)
  assert_eq(gc.preflag, 1)
  assert_eq(gc.scalefac_scale, 1)
  assert_eq(gc.count1table_select, 1)
  // granule 1 与 granule 0 在 MPEG1 下同样占 59 位
  assert_eq(side.granules[1][0].part2_3_length, 4095)
}

///|
test "MPEG1 立体声 side info 全 1 字面向量（256 bit 全 1）" {
  let header_bytes : Array[Int] = [0xFF, 0xFB, 0x90, 0x00]
  let body : Array[Int] = []
  let mut i = 0
  while i < 32 {
    body.push(0xFF)
    i = i + 1
  }
  let frame = mp3_test_frame_with_body(header_bytes, body, 417)
  let data = mp3_test_bytes(mp3_test_concat([frame, frame]))
  let header = mp3_parse_frame_header(data, 0)
  assert_eq(header.channels, 2)
  let side = mp3_parse_side_info(data, header, 0)
  assert_eq(side.main_data_begin, 511) // 9 位
  assert_eq(side.private_bits, 7) // 立体声只有 3 位
  assert_eq(side.scfsi.length(), 2)
  assert_eq(side.scfsi[0], 15)
  assert_eq(side.scfsi[1], 15)
  assert_eq(side.granules.length(), 2)
  assert_eq(side.granules[0].length(), 2)
  assert_eq(side.granules[0][1].part2_3_length, 4095)
  assert_eq(side.granules[1][1].count1table_select, 1)
}

///|
test "MPEG2 单声道 side info 全 1 字面向量（72 bit 全 1）" {
  let header_bytes : Array[Int] = [0xFF, 0xF3, 0x80, 0xC0]
  let body : Array[Int] = []
  let mut i = 0
  while i < 9 {
    body.push(0xFF)
    i = i + 1
  }
  let frame = mp3_test_frame_with_body(header_bytes, body, 208)
  let data = mp3_test_bytes(mp3_test_concat([frame, frame]))
  let header = mp3_parse_frame_header(data, 0)
  assert_true(header.version == Mp3Version::Mpeg2)
  let side = mp3_parse_side_info(data, header, 0)
  assert_eq(side.main_data_begin, 255) // MPEG2: 8 位
  assert_eq(side.private_bits, 1) // MPEG2 单声道: 1 位
  assert_eq(side.scfsi.length(), 0) // MPEG2 没有 scfsi
  assert_eq(side.granules.length(), 1) // MPEG2 只有 1 个 granule
  assert_eq(side.granules[0].length(), 1)
  let gc = side.granules[0][0]
  assert_eq(gc.part2_3_length, 4095)
  assert_eq(gc.big_values, 511)
  assert_eq(gc.global_gain, 255)
  assert_eq(gc.scalefac_compress, 511) // MPEG2: 9 位
  assert_eq(gc.window_switching_flag, 1)
  assert_eq(gc.block_type, 3)
  assert_eq(gc.table_select[0], 31)
  assert_eq(gc.subblock_gain[2], 7)
  assert_eq(gc.preflag, 0) // MPEG2 没有 preflag
  assert_eq(gc.scalefac_scale, 1)
  assert_eq(gc.count1table_select, 1)
}

///|
test "MPEG2 立体声 side info 全 1 字面向量（136 bit 全 1）" {
  let header_bytes : Array[Int] = [0xFF, 0xF3, 0x80, 0x00]
  let body : Array[Int] = []
  let mut i = 0
  while i < 17 {
    body.push(0xFF)
    i = i + 1
  }
  let frame = mp3_test_frame_with_body(header_bytes, body, 208)
  let data = mp3_test_bytes(mp3_test_concat([frame, frame]))
  let header = mp3_parse_frame_header(data, 0)
  let side = mp3_parse_side_info(data, header, 0)
  assert_eq(side.main_data_begin, 255)
  assert_eq(side.private_bits, 3) // MPEG2 立体声: 2 位
  assert_eq(side.scfsi.length(), 0)
  assert_eq(side.granules.length(), 1)
  assert_eq(side.granules[0].length(), 2)
  assert_eq(side.granules[0][1].scalefac_compress, 511)
}

///|
test "granule 字段可以逐位区分（非全 0/全 1 的显式位串）" {
  // MPEG1 单声道，手工写出 136 位：
  //   main_data_begin=1 (9b), private_bits=2 (5b), scfsi=3 (4b)
  //   然后 granule0 ch0 的 59 位，再 granule1 ch0 的 59 位
  let bits : Array[Int] = []
  let push = (value : Int, width : Int) => {
    let mut i = width - 1
    while i >= 0 {
      bits.push((value >> i) & 1)
      i = i - 1
    }
  }
  push(1, 9)
  push(2, 5)
  push(3, 4)
  // granule 0
  push(100, 12)
  push(10, 9)
  push(128, 8)
  push(5, 4)
  push(0, 1) // window_switching_flag = 0
  push(1, 5)
  push(2, 5)
  push(3, 5)
  push(7, 4) // region0_count
  push(4, 3) // region1_count
  push(0, 1) // preflag
  push(1, 1) // scalefac_scale
  push(0, 1) // count1table_select
  // granule 1
  push(200, 12)
  push(20, 9)
  push(64, 8)
  push(9, 4)
  push(1, 1) // window_switching_flag = 1
  push(2, 2) // block_type
  push(1, 1) // mixed_block_flag
  push(4, 5)
  push(5, 5)
  push(1, 3) // 3 × subblock_gain
  push(2, 3)
  push(3, 3)
  push(1, 1) // preflag
  push(0, 1) // scalefac_scale
  push(1, 1) // count1table_select
  assert_eq(bits.length(), 136)
  let packed = mp3_test_pack_bits(bits)
  let header_bytes : Array[Int] = [0xFF, 0xFB, 0x90, 0xC0]
  let full = header_bytes.copy()
  for b in packed {
    full.push(b)
  }
  let data = mp3_test_bytes(full)
  assert_eq(data.length(), 4 + 17)
  let header = mp3_parse_frame_header(data, 0)
  let side = mp3_parse_side_info(data, header, 0)
  assert_eq(side.main_data_begin, 1)
  assert_eq(side.private_bits, 2)
  assert_eq(side.scfsi[0], 3)
  let g0 = side.granules[0][0]
  assert_eq(g0.part2_3_length, 100)
  assert_eq(g0.big_values, 10)
  assert_eq(g0.global_gain, 128)
  assert_eq(g0.scalefac_compress, 5)
  assert_eq(g0.window_switching_flag, 0)
  assert_eq(g0.table_select[0], 1)
  assert_eq(g0.table_select[1], 2)
  assert_eq(g0.table_select[2], 3)
  assert_eq(g0.region0_count, 7)
  assert_eq(g0.region1_count, 4)
  assert_eq(g0.preflag, 0)
  assert_eq(g0.scalefac_scale, 1)
  assert_eq(g0.count1table_select, 0)
  let g1 = side.granules[1][0]
  assert_eq(g1.part2_3_length, 200)
  assert_eq(g1.big_values, 20)
  assert_eq(g1.global_gain, 64)
  assert_eq(g1.scalefac_compress, 9)
  assert_eq(g1.window_switching_flag, 1)
  assert_eq(g1.block_type, 2)
  assert_eq(g1.mixed_block_flag, 1)
  assert_eq(g1.table_select[0], 4)
  assert_eq(g1.table_select[1], 5)
  assert_eq(g1.subblock_gain[0], 1)
  assert_eq(g1.subblock_gain[1], 2)
  assert_eq(g1.subblock_gain[2], 3)
  assert_eq(g1.region0_count, 0)
  assert_eq(g1.region1_count, 0)
  assert_eq(g1.preflag, 1)
  assert_eq(g1.scalefac_scale, 0)
  assert_eq(g1.count1table_select, 1)
}

///|
test "带 CRC 的帧 side info 起点后移 2 字节" {
  let header_bytes : Array[Int] = [0xFF, 0xFA, 0x90, 0x00] // protection = 0
  let body : Array[Int] = [0xAA, 0xBB] // CRC
  let mut i = 0
  while i < 32 {
    body.push(0xFF)
    i = i + 1
  }
  let frame = mp3_test_frame_with_body(header_bytes, body, 417)
  let data = mp3_test_bytes(mp3_test_concat([frame, frame]))
  let header = mp3_parse_frame_header(data, 0)
  assert_eq(header.has_crc, true)
  assert_eq(mp3_side_info_offset(header, 0), 6)
  assert_eq(mp3_main_data_offset(header, 0), 38)
  let side = mp3_parse_side_info(data, header, 0)
  assert_eq(side.main_data_begin, 511)
  assert_eq(side.private_bits, 7)
}

// ============================================================
// scalefactor band 表 / Huffman 区域划分
// ============================================================

///|
test "44.1kHz scalefactor band 表自洽" {
  let long = mp3_sfb_long(44100)
  assert_eq(long.length(), 23)
  assert_eq(long[0], 0)
  assert_eq(long[22], 576)
  let mut i = 1
  while i < long.length() {
    assert_true(long[i] > long[i - 1])
    i = i + 1
  }
  let short = mp3_sfb_short(44100)
  assert_eq(short.length(), 14)
  assert_eq(short[0], 0)
  assert_eq(short[13], 192)
  let mut j = 1
  while j < short.length() {
    assert_true(short[j] > short[j - 1])
    j = j + 1
  }
  // 表里的最后一个值就是系数总数
  let mut total = 0
  let mut k = 1
  while k < long.length() {
    total = total + (long[k] - long[k - 1])
    k = k + 1
  }
  assert_eq(total, 576)
}

///|
test "非 44100Hz 的 scalefactor band 表抛 Unsupported" {
  assert_eq(mp3_test_call_tag(() => ignore(mp3_sfb_long(48000))), "Unsupported")
  assert_eq(mp3_test_call_tag(() => ignore(mp3_sfb_long(32000))), "Unsupported")
  assert_eq(
    mp3_test_call_tag(() => ignore(mp3_sfb_short(22050))),
    "Unsupported",
  )
}

///|
test "Huffman 区域划分与 table_select 选择" {
  let gc = mp3_test_granule(0, [7, 8, 9], 5, 3)
  let (r1, r2) = mp3_huffman_regions(gc, 44100)
  // sfb_long[5+1] = 24 → 48；sfb_long[5+3+2] = sfb_long[10] = 52 → 104
  assert_eq(r1, 48)
  assert_eq(r2, 104)
  assert_eq(mp3_huffman_table_select(gc, 0, r1, r2), 7)
  assert_eq(mp3_huffman_table_select(gc, 47, r1, r2), 7)
  assert_eq(mp3_huffman_table_select(gc, 48, r1, r2), 8)
  assert_eq(mp3_huffman_table_select(gc, 103, r1, r2), 8)
  assert_eq(mp3_huffman_table_select(gc, 104, r1, r2), 9)
  assert_eq(mp3_huffman_table_select(gc, 575, r1, r2), 9)
  // 窗口切换 granule 的区域划分未实现
  let ws = mp3_test_granule(1, [7, 8, 0], 0, 0)
  assert_eq(
    mp3_test_call_tag(() => ignore(mp3_huffman_regions(ws, 44100))),
    "Unsupported",
  )
  // 非 44100 采样率没有 sfb 表
  assert_eq(
    mp3_test_call_tag(() => ignore(mp3_huffman_regions(gc, 48000))),
    "Unsupported",
  )
  // region0_count + region1_count 越界
  let bad = mp3_test_granule(0, [1, 2, 3], 15, 7)
  assert_eq(
    mp3_test_call_tag(() => ignore(mp3_huffman_regions(bad, 44100))),
    "InvalidMagic",
  )
}

// ============================================================
// Huffman 表
// ============================================================

///|
test "Huffman 表 1 是完备前缀码" {
  let table = mp3_huffman_table(1)
  assert_eq(table.length(), 4)
  let mut max_len = 0
  for e in table {
    if e.hlen > max_len {
      max_len = e.hlen
    }
  }
  assert_eq(max_len, 3)
  // Kraft 和必须恰好为 1
  let mut kraft = 0
  for e in table {
    kraft = kraft + (1 << (max_len - e.hlen))
  }
  assert_eq(kraft, 1 << max_len)
  // 前缀无关
  for a in table {
    for b in table {
      if a.hlen < b.hlen {
        assert_true(b.hcod >> (b.hlen - a.hlen) != a.hcod)
      }
    }
  }
  // 码字两两不同
  for a in table {
    for b in table {
      assert_true(
        !(a.hlen == b.hlen && a.hcod == b.hcod) || (a.x == b.x && a.y == b.y),
      )
    }
  }
}

///|
test "Huffman 表 1 解码往返" {
  let table = mp3_huffman_table(1)
  let bits : Array[Int] = []
  for e in table {
    let mut i = e.hlen - 1
    while i >= 0 {
      bits.push((e.hcod >> i) & 1)
      i = i - 1
    }
  }
  assert_eq(bits.length(), 9) // 1 + 3 + 2 + 3
  let data = mp3_test_bytes(mp3_test_pack_bits(bits))
  let r = Mp3BitReader::new(data, 0)
  assert_eq(mp3_huffman_decode_pair(r, 1), (0, 0))
  assert_eq(mp3_huffman_decode_pair(r, 1), (0, 1))
  assert_eq(mp3_huffman_decode_pair(r, 1), (1, 0))
  assert_eq(mp3_huffman_decode_pair(r, 1), (1, 1))
  assert_eq(r.bit_offset(), 9)
}

///|
test "Huffman 表 1 的期望码字（防止表格被改动而无人察觉）" {
  let table = mp3_huffman_table(1)
  let expected : Array[(Int, Int, Int, Int)] = [
    (1, 0b1, 0, 0),
    (3, 0b001, 0, 1),
    (2, 0b01, 1, 0),
    (3, 0b000, 1, 1),
  ]
  assert_eq(table.length(), expected.length())
  let mut i = 0
  while i < expected.length() {
    let (hlen, hcod, x, y) = expected[i]
    assert_eq(table[i].hlen, hlen)
    assert_eq(table[i].hcod, hcod)
    assert_eq(table[i].x, x)
    assert_eq(table[i].y, y)
    i = i + 1
  }
}

///|
test "除表 1 外的 Huffman 表抛 Unsupported" {
  assert_eq(
    mp3_test_call_tag(() => ignore(mp3_huffman_table(2))),
    "Unsupported",
  )
  assert_eq(
    mp3_test_call_tag(() => ignore(mp3_huffman_table(16))),
    "Unsupported",
  )
  assert_eq(
    mp3_test_call_tag(() => ignore(mp3_huffman_table(0))),
    "Unsupported",
  )
  let data = mp3_test_bytes([0xFF, 0xFF])
  let r = Mp3BitReader::new(data, 0)
  assert_eq(
    mp3_test_call_tag(() => ignore(mp3_huffman_decode_pair(r, 5))),
    "Unsupported",
  )
}
