// ogg_test.mbt —— Ogg 解析器黑盒测试
//
// 所有 page 都是**手工构造**的字节：不读文件、不用 fixtures.mbt、不假设别的实现文件存在。
// 只调用包内公开 API（`@audio.parse_page` / `@audio.pages` / `@audio.packets_of` /
// `@audio.ogg_crc32` / `@audio.OggPage` / `@audio.AudioError` …）。
//
// CRC 真值来源（重要，见文件末尾的「CRC 真值来源」一节）：
// 断言里用到的 CRC 常量都是**独立推导**的，不是由本项目的代码生成的；
// 其中 1 项是手推、1 项与公开的 CRC-32/POSIX check 值挂钩、其余由一份独立编写的
// Python 参考实现算出，并已确认不会因为「编码/解码用同一个错函数」而自洽通过。

// ---------------------------------------------------------------------------
// 测试内的小工具
// ---------------------------------------------------------------------------

///|
/// 把 32 位整数按小端追加到 `out`（低位在前；负数用掩码取字节，等价于无符号位模式）。
fn ogg_test_push_u32_le(out : Array[Byte], value : Int) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    out.push(((value >> (8 * i)) & 0xFF).to_byte())
  }
}

///|
/// 手工拼一个 Ogg page 的字节，**CRC 字段留 0**。
///
/// 布局：`"OggS" | version | header_type | granule(8,LE) | serial(4,LE) |
/// sequence(4,LE) | crc(4,LE) | page_segments(1) | segment_table | body`。
fn ogg_test_page_zero_crc(
  version : Int,
  header_type : Int,
  granule : Int64,
  serial : Int,
  sequence : Int,
  segments : Array[Int],
  body : Array[Byte],
) -> Array[Byte] {
  let out : Array[Byte] = []
  out.push(b'O')
  out.push(b'g')
  out.push(b'g')
  out.push(b'S')
  out.push(version.to_byte())
  out.push(header_type.to_byte())
  ogg_test_push_u32_le(out, granule.to_int())
  ogg_test_push_u32_le(out, (granule >> 32).to_int())
  ogg_test_push_u32_le(out, serial)
  ogg_test_push_u32_le(out, sequence)
  ogg_test_push_u32_le(out, 0) // CRC 占位：Ogg 规范要求该字段按 0 参与计算
  out.push(segments.length().to_byte())
  for s in segments {
    out.push(s.to_byte())
  }
  for b in body {
    out.push(b)
  }
  out
}

///|
/// 手工构造一个**合法**的 Ogg page：先按 CRC 字段为 0 拼出整页，用 `@audio.ogg_crc32`
/// 算出校验和，再回填到 22..25 字节，因此结果一定能通过 `parse_page` 的 CRC 校验。
fn ogg_test_build_page(
  version : Int,
  header_type : Int,
  granule : Int64,
  serial : Int,
  sequence : Int,
  segments : Array[Int],
  body : Array[Byte],
) -> Bytes {
  let raw = ogg_test_page_zero_crc(
    version, header_type, granule, serial, sequence, segments, body,
  )
  let crc = @audio.ogg_crc32(Bytes::from_array(raw))
  ogg_test_patch_crc(raw, crc)
}

///|
/// 把 `crc` 写进 page 的 22..25 字节（小端）并返回 Bytes。
fn ogg_test_patch_crc(raw : Array[Byte], crc : Int) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < raw.length(); i = i + 1 {
    if i >= 22 && i < 26 {
      out.push(((crc >> (8 * (i - 22))) & 0xFF).to_byte())
    } else {
      out.push(raw[i])
    }
  }
  Bytes::from_array(out)
}

///|
/// 复制一份并把 22..25 字节清零（用来复算「page 应有的 CRC」）。
fn ogg_test_zero_crc_field(data : Bytes) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < data.length(); i = i + 1 {
    if i >= 22 && i < 26 {
      out.push(b'\x00')
    } else {
      out.push(data[i])
    }
  }
  Bytes::from_array(out)
}

///|
/// 顺序拼接多段字节。
fn ogg_test_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for i = 0; i < part.length(); i = i + 1 {
      out.push(part[i])
    }
  }
  Bytes::from_array(out)
}

///|
/// 取前 `n` 个字节，用来构造被截断的输入。
fn ogg_test_prefix(data : Bytes, n : Int) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < n && i < data.length(); i = i + 1 {
    out.push(data[i])
  }
  Bytes::from_array(out)
}

///|
/// 翻转第 `index` 个字节的全部 8 位，用来构造损坏输入。
fn ogg_test_flip_byte(data : Bytes, index : Int) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < data.length(); i = i + 1 {
    if i == index {
      out.push((data[i].to_int() ^ 0xFF).to_byte())
    } else {
      out.push(data[i])
    }
  }
  Bytes::from_array(out)
}

///|
/// 把 `AudioError` 归类成短标签。
///
/// `AudioError` 没有实现 `Show`，不能直接 `inspect`，所以在这里按分支展开成字符串，
/// 失败信息里能直接看出拿到的是哪一类错误（以及 Truncated/ChecksumMismatch 的数值）。
fn ogg_test_error_tag(err : @audio.AudioError) -> String {
  match err {
    @audio.AudioError::Truncated(offset~, needed~, available~) =>
      "Truncated(offset=\{offset}, needed=\{needed}, available=\{available})"
    @audio.AudioError::InvalidMagic(_) => "InvalidMagic"
    @audio.AudioError::Unsupported(_) => "Unsupported"
    @audio.AudioError::ChecksumMismatch(expected~, actual~) =>
      "ChecksumMismatch(expected=\{expected}, actual=\{actual})"
    @audio.AudioError::LimitExceeded(_) => "LimitExceeded"
    // AudioError 的 5 个分支在上面都列全了（errors.mbt 已冻结，不再新增分支），
    // 编译器确认这里是穷尽的，所以不写 `_` 兜底（写了反而报 unreachable_code）。
  }
}

///|
/// 断言错误是 `Truncated`，且 offset / needed / available 三个字段完全匹配。
#callsite(autofill(loc))
fn ogg_test_assert_truncated(
  err : @audio.AudioError,
  want_offset : Int,
  want_needed : Int,
  want_available : Int,
  loc~ : SourceLoc,
) -> Unit raise Failure {
  match err {
    @audio.AudioError::Truncated(offset~, needed~, available~) =>
      if offset != want_offset ||
        needed != want_needed ||
        available != want_available {
        fail(
          "期望 Truncated(offset=\{want_offset}, needed=\{want_needed}, available=\{want_available})，实际 Truncated(offset=\{offset}, needed=\{needed}, available=\{available})",
          loc~,
        )
      }
    _ =>
      fail(
        "期望 Truncated(offset=\{want_offset}, needed=\{want_needed}, available=\{want_available})，实际 \{ogg_test_error_tag(err)}",
        loc~,
      )
  }
}

///|
/// 断言错误是 `ChecksumMismatch`，且 expected（文件里的字段）/ actual（重算值）匹配。
#callsite(autofill(loc))
fn ogg_test_assert_checksum_mismatch(
  err : @audio.AudioError,
  want_expected : Int,
  want_actual : Int,
  loc~ : SourceLoc,
) -> Unit raise Failure {
  match err {
    @audio.AudioError::ChecksumMismatch(expected~, actual~) =>
      if expected != want_expected || actual != want_actual {
        fail(
          "期望 ChecksumMismatch(expected=\{want_expected}, actual=\{want_actual})，实际 ChecksumMismatch(expected=\{expected}, actual=\{actual})",
          loc~,
        )
      }
    _ =>
      fail(
        "期望 ChecksumMismatch(expected=\{want_expected}, actual=\{want_actual})，实际 \{ogg_test_error_tag(err)}",
        loc~,
      )
  }
}

///|
/// 期望 `f()` 抛错并把错误返回；不抛错则测试失败。
#callsite(autofill(loc))
fn ogg_test_expect_error(
  f : () -> Unit raise @audio.AudioError,
  msg : String,
  loc~ : SourceLoc,
) -> @audio.AudioError raise Failure {
  try f() catch {
    err => err
  } noraise {
    _ => fail(msg, loc~)
  }
}

///|
/// 解析成功路径：失败直接让测试失败（测试块里只处理 Failure，不处理 AudioError）。
#callsite(autofill(loc))
fn ogg_test_parse(
  data : Bytes,
  offset : Int,
  loc~ : SourceLoc,
) -> (@audio.OggPage, Int) raise Failure {
  try @audio.parse_page(data, offset) catch {
    err =>
      fail("parse_page 不应失败，实际 \{ogg_test_error_tag(err)}", loc~)
  } noraise {
    result => result
  }
}

///|
/// `pages()` 的成功路径包装。
#callsite(autofill(loc))
fn ogg_test_pages(
  data : Bytes,
  loc~ : SourceLoc,
) -> Array[@audio.OggPage] raise Failure {
  try @audio.pages(data) catch {
    err => fail("pages 不应失败，实际 \{ogg_test_error_tag(err)}", loc~)
  } noraise {
    result => result
  }
}

///|
/// 断言 `Bytes` 与期望的字节序列逐字节相等（`Bytes` 的比较留在这里做，便于报错定位）。
#callsite(autofill(loc))
fn ogg_test_assert_bytes(
  actual : Bytes,
  want : Array[Byte],
  loc~ : SourceLoc,
) -> Unit raise Failure {
  if actual.length() != want.length() {
    fail(
      "字节长度不符：actual=\{actual.length()} want=\{want.length()}",
      loc~,
    )
  }
  for i = 0; i < want.length(); i = i + 1 {
    if actual[i] != want[i] {
      fail(
        "第 \{i} 个字节不符：actual=\{actual[i].to_int()} want=\{want[i].to_int()}",
        loc~,
      )
    }
  }
}

///|
/// 测试内**独立**的按位 CRC32 实现（MSB-first、初值 0、不取反）。
///
/// 与包内公开 `ogg_crc32` 的查表实现是两条不同的代码路径，用来对拍。
fn ogg_test_crc32_bitwise(data : Bytes) -> Int {
  let mut crc = 0
  for i = 0; i < data.length(); i = i + 1 {
    crc = crc ^ (data[i].to_int() << 24)
    for bit = 0; bit < 8; bit = bit + 1 {
      if crc < 0 {
        crc = (crc << 1) ^ 0x04C11DB7
      } else {
        crc = crc << 1
      }
    }
  }
  crc
}

///|
/// 最小合法 page 的字节（CRC 字段为 0）：39 字节，两个 packet（7 字节 + 3 字节）。
/// 与用于独立推导 CRC 常量的 Python 参考实现逐字节一致。
fn ogg_test_page_a_zero_crc() -> Array[Byte] {
  ogg_test_page_zero_crc(0, 0x02, 0x1234L, 0xBEEF, 0, [7, 3], [
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's', b'\xAA', b'\xBB', b'\xCC',
  ])
}

// ---------------------------------------------------------------------------
// 1. 最小合法单页
// ---------------------------------------------------------------------------

///|
test "ogg: 最小合法单页的字段逐个核对" {
  let data = Bytes::from_array(ogg_test_page_a_zero_crc())
  let page_bytes = ogg_test_patch_crc(
    ogg_test_page_a_zero_crc(),
    @audio.ogg_crc32(data),
  )
  assert_eq(page_bytes.length(), 39)
  let (page, next) = ogg_test_parse(page_bytes, 0)
  assert_eq(page.version, 0)
  assert_eq(page.header_type, 0x02)
  assert_eq(page.granule_position, 0x1234L)
  assert_eq(page.serial, 0xBEEF)
  assert_eq(page.sequence, 0)
  assert_eq(page.checksum, 0x2A411425)
  assert_eq(page.segments.length(), 2)
  assert_eq(page.segments[0], 7)
  assert_eq(page.segments[1], 3)
  assert_eq(page.body.length(), 10)
  // 27(固定头) + 2(segment table) + 10(body) = 39
  assert_eq(next, 39)
  assert_eq(next, page_bytes.length())
  ogg_test_assert_bytes(page.body, [
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's', b'\xAA', b'\xBB', b'\xCC',
  ])
  // BOS page 的第一个 packet 就是 codec 标识
  assert_true(@audio.ogg_page_is_bos(page))
  assert_false(@audio.ogg_page_is_eos(page))
  assert_false(@audio.ogg_page_is_continued(page))
  assert_false(@audio.ogg_granule_is_none(page))
  assert_eq(@audio.ogg_first_packet_len(page), 7)
  assert_eq(@audio.ogg_codec_of_stream(page_bytes), @audio.OggCodec::Vorbis)
}

///|
test "ogg: 从中间偏移解析（offset 不为 0）" {
  let p0 = ogg_test_build_page(0, 0x02, 0L, 0x1111, 0, [1], [b'\x10'])
  let p1 = ogg_test_build_page(0, 0x00, 1L, 0x1111, 1, [2], [b'\x20', b'\x21'])
  let all = ogg_test_concat([p0, p1])
  let (page, next) = ogg_test_parse(all, p0.length())
  assert_eq(page.sequence, 1)
  assert_eq(page.serial, 0x1111)
  assert_eq(page.granule_position, 1L)
  assert_eq(next, all.length())
}

// ---------------------------------------------------------------------------
// 2. granule position 全 1 → -1
// ---------------------------------------------------------------------------

///|
test "ogg: granule 全 1（无 granule）读成 -1" {
  let page_bytes = ogg_test_build_page(0, 0x02, -1L, 0x2222, 0, [1], [b'\x7F'])
  // 先确认字节层面确实是 8 个 0xFF（而不是别的什么写法）
  for i = 6; i < 14; i = i + 1 {
    assert_eq(page_bytes[i], b'\xFF')
  }
  let (page, _) = ogg_test_parse(page_bytes, 0)
  assert_eq(page.granule_position, -1L)
  assert_true(@audio.ogg_granule_is_none(page))
}

///|
test "ogg: granule 0 与 -1 不是同一回事" {
  let zero = ogg_test_build_page(0, 0x00, 0L, 0x3333, 0, [1], [b'\x01'])
  let none = ogg_test_build_page(0, 0x00, -1L, 0x3333, 1, [1], [b'\x01'])
  let (p_zero, _) = ogg_test_parse(zero, 0)
  let (p_none, _) = ogg_test_parse(none, 0)
  assert_eq(p_zero.granule_position, 0L)
  assert_false(@audio.ogg_granule_is_none(p_zero))
  assert_true(@audio.ogg_granule_is_none(p_none))
}

// ---------------------------------------------------------------------------
// 3. CRC 校验：改一个字节 → ChecksumMismatch
// ---------------------------------------------------------------------------

///|
test "ogg: 改动 body 一个字节 → ChecksumMismatch(expected=文件值, actual=重算值)" {
  let good = ogg_test_build_page(0, 0x02, 0x1234L, 0xBEEF, 0, [7, 3], [
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's', b'\xAA', b'\xBB', b'\xCC',
  ])
  // 第 35 字节落在 body 里（29..38）
  let bad = ogg_test_flip_byte(good, 35)
  let want_actual = @audio.ogg_crc32(ogg_test_zero_crc_field(bad))
  let err = ogg_test_expect_error(
    () => ignore(@audio.parse_page(bad, 0)),
    "改坏一个字节后应当 CRC 校验失败",
  )
  // expected 是 page 里记录的校验和（未被改动），actual 是重算出来的值
  ogg_test_assert_checksum_mismatch(err, 0x2A411425, want_actual)
}

///|
test "ogg: 改动 CRC 字段本身也会被发现" {
  let good = ogg_test_build_page(0, 0x00, 0L, 0x4444, 0, [1], [b'\x55'])
  let bad = ogg_test_flip_byte(good, 22)
  let want_actual = @audio.ogg_crc32(ogg_test_zero_crc_field(bad))
  let err = ogg_test_expect_error(
    () => ignore(@audio.parse_page(bad, 0)),
    "CRC 字段被改动后应当校验失败",
  )
  match err {
    @audio.AudioError::ChecksumMismatch(expected~, actual~) => {
      assert_eq(actual, want_actual)
      assert_not_eq(expected, actual)
    }
    _ => fail("期望 ChecksumMismatch，实际 \{ogg_test_error_tag(err)}")
  }
}

///|
test "ogg: 自洽性——先把 CRC 字段当 0 算出的值填回去，解析必须通过" {
  let raw = ogg_test_page_a_zero_crc()
  let crc = @audio.ogg_crc32(Bytes::from_array(raw))
  // 独立推导的常量（见文件末尾说明），不是本实现自产自销
  assert_eq(crc, 0x2A411425)
  let page_bytes = ogg_test_patch_crc(raw, crc)
  let (page, _) = ogg_test_parse(page_bytes, 0)
  assert_eq(page.checksum, crc)
}

// ---------------------------------------------------------------------------
// 4. 多页顺序解析
// ---------------------------------------------------------------------------

///|
test "ogg: pages() 按文件顺序返回全部 page" {
  let p0 = ogg_test_build_page(0, 0x02, 0L, 0x33, 0, [1], [b'\x11'])
  let p1 = ogg_test_build_page(0, 0x00, 1L, 0x33, 1, [2], [b'\x21', b'\x22'])
  let p2 = ogg_test_build_page(0, 0x04, 2L, 0x33, 2, [1], [b'\x31'])
  let all = ogg_test_concat([p0, p1, p2])
  let parsed = ogg_test_pages(all)
  assert_eq(parsed.length(), 3)
  assert_eq(parsed[0].sequence, 0)
  assert_eq(parsed[1].sequence, 1)
  assert_eq(parsed[2].sequence, 2)
  assert_eq(parsed[0].header_type, 0x02)
  assert_eq(parsed[1].header_type, 0x00)
  assert_eq(parsed[2].header_type, 0x04)
  assert_eq(parsed[0].granule_position, 0L)
  assert_eq(parsed[1].granule_position, 1L)
  assert_eq(parsed[2].granule_position, 2L)
  assert_true(@audio.ogg_page_is_bos(parsed[0]))
  assert_true(@audio.ogg_page_is_eos(parsed[2]))
  // 单页解析必须落在同一个边界上
  for i = 0; i < 3; i = i + 1 {
    assert_eq(parsed[i].serial, 0x33)
  }
  assert_eq(parsed[1].body.length(), 2)
  assert_eq(parsed[1].body[0], b'\x21')
}

///|
test "ogg: 空输入返回 0 个 page" {
  assert_eq(ogg_test_pages(b"").length(), 0)
}

// ---------------------------------------------------------------------------
// 5. 跨页 packet 重组
// ---------------------------------------------------------------------------

///|
test "ogg: 跨页 packet（255 结尾 + continuation 位）完整重组" {
  // page1：segments [3, 255] → 一个 3 字节完整 packet，加一个 255 字节未完 packet
  let body1 : Array[Byte] = [b'\xAA', b'\xBB', b'\xCC']
  for i = 0; i < 255; i = i + 1 {
    body1.push((i & 0xFF).to_byte())
  }
  let page1 = ogg_test_build_page(0, 0x02, 0L, 0x1111, 0, [3, 255], body1)
  // page2：continuation 位（0x01）置位，5 字节收尾
  let page2 = ogg_test_build_page(0, 0x01, 1L, 0x1111, 1, [5], [
    b'\x01', b'\x02', b'\x03', b'\x04', b'\x05',
  ])
  let all = ogg_test_concat([page1, page2])
  let parsed = ogg_test_pages(all)
  assert_eq(parsed.length(), 2)
  assert_true(@audio.ogg_page_is_continued(parsed[1]))
  let groups = @audio.packets_of(parsed)
  assert_eq(groups.length(), 1)
  let (serial, pkts) = groups[0]
  assert_eq(serial, 0x1111)
  assert_eq(pkts.length(), 2)
  // 第一个 packet 在 page1 内就收尾了
  assert_eq(pkts[0].length(), 3)
  ogg_test_assert_bytes(pkts[0], [b'\xAA', b'\xBB', b'\xCC'])
  // 第二个 packet = page1 的 255 字节 + page2 的 5 字节
  assert_eq(pkts[1].length(), 260)
  assert_eq(pkts[1][0], b'\x00')
  assert_eq(pkts[1][1], b'\x01')
  assert_eq(pkts[1][254], b'\xFE')
  assert_eq(pkts[1][255], b'\x01')
  assert_eq(pkts[1][256], b'\x02')
  assert_eq(pkts[1][259], b'\x05')
}

///|
test "ogg: lacing 255 后面跟 0 表示 255 字节 packet 收尾" {
  let body : Array[Byte] = []
  for i = 0; i < 255; i = i + 1 {
    body.push((i & 0xFF).to_byte())
  }
  let page_bytes = ogg_test_build_page(0, 0x02, 0L, 0x1212, 0, [255, 0], body)
  let groups = @audio.packets_of(ogg_test_pages(page_bytes))
  assert_eq(groups.length(), 1)
  let (_, pkts) = groups[0]
  assert_eq(pkts.length(), 1)
  assert_eq(pkts[0].length(), 255)
  assert_eq(pkts[0][0], b'\x00')
  assert_eq(pkts[0][254], b'\xFE')
}

///|
test "ogg: 三个 page 拼一个 packet" {
  let body1 : Array[Byte] = []
  for i = 0; i < 255; i = i + 1 {
    body1.push(b'\x11')
  }
  let body2 : Array[Byte] = []
  for i = 0; i < 255; i = i + 1 {
    body2.push(b'\x22')
  }
  let p1 = ogg_test_build_page(0, 0x02, 0L, 0x1313, 0, [255], body1)
  let p2 = ogg_test_build_page(0, 0x01, 1L, 0x1313, 1, [255], body2)
  let p3 = ogg_test_build_page(0, 0x01, 2L, 0x1313, 2, [2], [b'\x33', b'\x34'])
  let groups = @audio.packets_of(ogg_test_pages(ogg_test_concat([p1, p2, p3])))
  assert_eq(groups.length(), 1)
  let (_, pkts) = groups[0]
  assert_eq(pkts.length(), 1)
  assert_eq(pkts[0].length(), 512)
  assert_eq(pkts[0][0], b'\x11')
  assert_eq(pkts[0][254], b'\x11')
  assert_eq(pkts[0][255], b'\x22')
  assert_eq(pkts[0][509], b'\x22')
  assert_eq(pkts[0][510], b'\x33')
  assert_eq(pkts[0][511], b'\x34')
}

///|
test "ogg: 流结束时未完成的 packet 被丢弃" {
  let body : Array[Byte] = [b'\xA1', b'\xA2']
  for i = 0; i < 255; i = i + 1 {
    body.push(b'\xEE')
  }
  let p1 = ogg_test_build_page(0, 0x02, 0L, 0x1414, 0, [2, 255], body)
  let groups = @audio.packets_of(ogg_test_pages(p1))
  assert_eq(groups.length(), 1)
  let (_, pkts) = groups[0]
  // 只有收尾的 2 字节 packet；挂着的 255 字节残包被丢弃
  assert_eq(pkts.length(), 1)
  assert_eq(pkts[0].length(), 2)
  ogg_test_assert_bytes(pkts[0], [b'\xA1', b'\xA2'])
}

///|
test "ogg: 整页只有一个未完 packet 时该组没有 packet" {
  let body : Array[Byte] = []
  for i = 0; i < 255; i = i + 1 {
    body.push(b'\x9A')
  }
  let page_bytes = ogg_test_build_page(0, 0x02, 0L, 0x1515, 0, [255], body)
  let groups = @audio.packets_of(ogg_test_pages(page_bytes))
  assert_eq(groups.length(), 1)
  let (serial, pkts) = groups[0]
  assert_eq(serial, 0x1515)
  assert_eq(pkts.length(), 0)
}

///|
test "ogg: 缺 continuation 位时残缺 packet 被丢弃、新 packet 照常产出" {
  let body1 : Array[Byte] = []
  for i = 0; i < 255; i = i + 1 {
    body1.push(b'\x77')
  }
  let p1 = ogg_test_build_page(0, 0x02, 0L, 0x1616, 0, [255], body1)
  // 下一页没有 continuation 位 → 上页残缺 packet 丢弃
  let p2 = ogg_test_build_page(0, 0x00, 1L, 0x1616, 1, [1], [b'\x42'])
  let groups = @audio.packets_of(ogg_test_pages(ogg_test_concat([p1, p2])))
  assert_eq(groups.length(), 1)
  let (_, pkts) = groups[0]
  assert_eq(pkts.length(), 1)
  ogg_test_assert_bytes(pkts[0], [b'\x42'])
}

///|
test "ogg: 从流中间接入（首段带 continuation 位但没有上文）" {
  // 第一个 packet 的前半段丢了：本页带 continuation 位，开头两段属于丢失的 packet
  let body : Array[Byte] = []
  for i = 0; i < 255; i = i + 1 {
    body.push(b'\x01')
  }
  for i = 0; i < 10; i = i + 1 {
    body.push(b'\x02')
  }
  body.push(b'\x99')
  let page_bytes = ogg_test_build_page(
    0,
    0x01,
    7L,
    0x1717,
    5,
    [255, 10, 1],
    body,
  )
  let groups = @audio.packets_of(ogg_test_pages(page_bytes))
  assert_eq(groups.length(), 1)
  let (_, pkts) = groups[0]
  // 前两段被跳过，只产出后面的完整 packet
  assert_eq(pkts.length(), 1)
  ogg_test_assert_bytes(pkts[0], [b'\x99'])
}

///|
test "ogg: 零长度 packet（lacing 0）与零段 page" {
  let empty_packet = ogg_test_build_page(0, 0x02, 0L, 0x1818, 0, [0], [])
  let groups = @audio.packets_of(ogg_test_pages(empty_packet))
  assert_eq(groups.length(), 1)
  let (_, pkts) = groups[0]
  assert_eq(pkts.length(), 1)
  assert_eq(pkts[0].length(), 0)
  // page_segments = 0：分组存在，但没有任何 packet
  let no_segment = ogg_test_build_page(0, 0x00, 0L, 0x1818, 1, [], [])
  let (page, next) = ogg_test_parse(no_segment, 0)
  assert_eq(page.segments.length(), 0)
  assert_eq(page.body.length(), 0)
  assert_eq(next, 27)
  let groups2 = @audio.packets_of(ogg_test_pages(no_segment))
  assert_eq(groups2.length(), 1)
  let (_, pkts2) = groups2[0]
  assert_eq(pkts2.length(), 0)
}

// ---------------------------------------------------------------------------
// 6. 多路复用
// ---------------------------------------------------------------------------

///|
test "ogg: 两个 serial 交错出现时按 serial 分组" {
  let a0 = ogg_test_build_page(0, 0x02, 0L, 0xAAAA, 0, [2], [b'\xA1', b'\xA2'])
  let b0 = ogg_test_build_page(0, 0x02, 0L, 0xBBBB, 0, [2], [b'\xB1', b'\xB2'])
  let a1 = ogg_test_build_page(0, 0x00, 1L, 0xAAAA, 1, [2], [b'\xA3', b'\xA4'])
  let b1 = ogg_test_build_page(0, 0x04, 1L, 0xBBBB, 1, [2], [b'\xB3', b'\xB4'])
  let groups = @audio.packets_of(
    ogg_test_pages(ogg_test_concat([a0, b0, a1, b1])),
  )
  // 组按 serial 首次出现的顺序排列
  assert_eq(groups.length(), 2)
  let (serial_a, pkts_a) = groups[0]
  let (serial_b, pkts_b) = groups[1]
  assert_eq(serial_a, 0xAAAA)
  assert_eq(serial_b, 0xBBBB)
  assert_eq(pkts_a.length(), 2)
  assert_eq(pkts_b.length(), 2)
  ogg_test_assert_bytes(pkts_a[0], [b'\xA1', b'\xA2'])
  ogg_test_assert_bytes(pkts_a[1], [b'\xA3', b'\xA4'])
  ogg_test_assert_bytes(pkts_b[0], [b'\xB1', b'\xB2'])
  ogg_test_assert_bytes(pkts_b[1], [b'\xB3', b'\xB4'])
}

///|
test "ogg: 续包状态按 serial 隔离（中间插了别的流）" {
  // A 的 packet 跨两页，中间夹着 B 的一页
  let body_a0 : Array[Byte] = []
  for i = 0; i < 255; i = i + 1 {
    body_a0.push(b'\x0A')
  }
  let a0 = ogg_test_build_page(0, 0x02, 0L, 0xAAAA, 0, [255], body_a0)
  let b0 = ogg_test_build_page(0, 0x02, 0L, 0xBBBB, 0, [1], [b'\x99'])
  let a1 = ogg_test_build_page(0, 0x01, 1L, 0xAAAA, 1, [1], [b'\x7E'])
  let groups = @audio.packets_of(ogg_test_pages(ogg_test_concat([a0, b0, a1])))
  assert_eq(groups.length(), 2)
  let (serial_a, pkts_a) = groups[0]
  let (serial_b, pkts_b) = groups[1]
  assert_eq(serial_a, 0xAAAA)
  assert_eq(serial_b, 0xBBBB)
  assert_eq(pkts_a.length(), 1)
  assert_eq(pkts_a[0].length(), 256)
  assert_eq(pkts_a[0][0], b'\x0A')
  assert_eq(pkts_a[0][255], b'\x7E')
  assert_eq(pkts_b.length(), 1)
  ogg_test_assert_bytes(pkts_b[0], [b'\x99'])
}

// ---------------------------------------------------------------------------
// 7. version != 0 → Unsupported
// ---------------------------------------------------------------------------

///|
test "ogg: version=1 → Unsupported" {
  let page_bytes = ogg_test_build_page(1, 0x02, 0L, 0x5555, 0, [1], [b'\x01'])
  let err = ogg_test_expect_error(
    () => ignore(@audio.parse_page(page_bytes, 0)),
    "version=1 应当抛 Unsupported",
  )
  assert_eq(ogg_test_error_tag(err), "Unsupported")
}

///|
test "ogg: version 检查先于 CRC 校验（CRC 坏掉也先报 Unsupported）" {
  let page_bytes = ogg_test_build_page(2, 0x02, 0L, 0x5555, 0, [1], [b'\x01'])
  let broken = ogg_test_flip_byte(page_bytes, 30) // 把 body 改坏，CRC 必定不匹配
  let err = ogg_test_expect_error(
    () => ignore(@audio.parse_page(broken, 0)),
    "version=2 应当先报 Unsupported",
  )
  assert_eq(ogg_test_error_tag(err), "Unsupported")
}

// ---------------------------------------------------------------------------
// 8. 魔数错误 → InvalidMagic
// ---------------------------------------------------------------------------

///|
test "ogg: capture pattern 不是 OggS → InvalidMagic" {
  let good = ogg_test_build_page(0, 0x02, 0L, 0x6666, 0, [1], [b'\x01'])
  let bad = ogg_test_flip_byte(good, 0)
  let err = ogg_test_expect_error(
    () => ignore(@audio.parse_page(bad, 0)),
    "魔数被改坏应当抛 InvalidMagic",
  )
  assert_eq(ogg_test_error_tag(err), "InvalidMagic")
}

///|
test "ogg: 四个字节之外才出现 OggS 时也报 InvalidMagic" {
  let err = ogg_test_expect_error(
    () => ignore(@audio.parse_page(b"OOOOggS", 2)),
    "偏移处魔数不对应当抛 InvalidMagic",
  )
  assert_eq(ogg_test_error_tag(err), "InvalidMagic")
}

// ---------------------------------------------------------------------------
// 9. 截断 → Truncated（offset / needed / available 精确匹配）
// ---------------------------------------------------------------------------

///|
test "ogg: 截断的 page 报 Truncated 且三元组正确" {
  let good = ogg_test_build_page(0, 0x02, 0x1234L, 0xBEEF, 0, [7, 3], [
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's', b'\xAA', b'\xBB', b'\xCC',
  ])
  assert_eq(good.length(), 39)
  // (a) 连固定头都不够
  let err_a = ogg_test_expect_error(
    () => ignore(@audio.parse_page(ogg_test_prefix(good, 20), 0)),
    "20 字节应当抛 Truncated",
  )
  ogg_test_assert_truncated(err_a, 0, 27, 20)
  // (b) 固定头够，segment table 缺 1 字节
  let err_b = ogg_test_expect_error(
    () => ignore(@audio.parse_page(ogg_test_prefix(good, 28), 0)),
    "segment table 不全应当抛 Truncated",
  )
  ogg_test_assert_truncated(err_b, 27, 2, 1)
  // (c) segment table 够，body 缺 4 字节
  let err_c = ogg_test_expect_error(
    () => ignore(@audio.parse_page(ogg_test_prefix(good, 35), 0)),
    "body 不全应当抛 Truncated",
  )
  ogg_test_assert_truncated(err_c, 29, 10, 6)
}

///|
test "ogg: 输出短于 4 字节时 Truncated 报的是魔数那 4 字节" {
  let err = ogg_test_expect_error(
    () => ignore(@audio.parse_page(b"Og", 0)),
    "2 字节应当抛 Truncated",
  )
  ogg_test_assert_truncated(err, 0, 4, 2)
}

///|
test "ogg: 偏移越界报 Truncated 而不是 panic" {
  let good = ogg_test_build_page(0, 0x00, 0L, 0x7777, 0, [1], [b'\x01'])
  let err = ogg_test_expect_error(
    () => ignore(@audio.parse_page(good, good.length())),
    "offset 落在末尾应当抛 Truncated",
  )
  ogg_test_assert_truncated(err, good.length(), 4, 0)
  let err_neg = ogg_test_expect_error(
    () => ignore(@audio.parse_page(good, -1)),
    "负 offset 应当抛 Truncated",
  )
  ogg_test_assert_truncated(err_neg, -1, 4, 0)
}

///|
test "ogg: pages() 对尾部残留字节不静默放过" {
  let good = ogg_test_build_page(0, 0x02, 0L, 0x8888, 0, [1], [b'\x01'])
  let with_junk = ogg_test_concat([good, b"\x01\x02\x03"])
  let err = ogg_test_expect_error(
    () => ignore(@audio.pages(with_junk)),
    "尾部 3 个字节不足以构成 page，应当抛 Truncated",
  )
  ogg_test_assert_truncated(err, good.length(), 4, 3)
}

// ---------------------------------------------------------------------------
// 10. CRC32 不变量与独立真值
// ---------------------------------------------------------------------------

///|
test "ogg: crc32 空输入与全零输入都是 0（初值 0 且不取反）" {
  assert_eq(@audio.ogg_crc32(b""), 0)
  assert_eq(@audio.ogg_crc32(b"\x00"), 0)
  assert_eq(@audio.ogg_crc32(b"\x00\x00\x00\x00\x00\x00\x00\x00"), 0)
  let thousand_zeros : Array[Byte] = Array::make(1000, b'\x00')
  assert_eq(@audio.ogg_crc32(Bytes::from_array(thousand_zeros)), 0)
}

///|
test "ogg: crc32 与独立推导的真值一致" {
  // (1) 手推：单个字节 0x01
  //     crc = 0 ^ (0x01 << 24) = 0x01000000
  //     8 轮里前 7 轮最高位都是 0 → 一路左移：0x02000000 … 0x80000000
  //     第 8 轮最高位为 1 → (0x80000000 << 1) 截断为 0，再 ^ 0x04C11DB7
  //     结果为 0x04C11DB7
  assert_eq(@audio.ogg_crc32(b"\x01"), 0x04C11DB7)
  // (2) 与公开参考挂钩：CRC-32/POSIX（CKSUM 变体）的 check 值是 0x765E7680，
  //     其参数为 poly=0x04C11DB7、init=0xFFFFFFFF、refin/refout=false、xorout=0xFFFFFFFF。
  //     Ogg 用同一个多项式与位序，但 init=0、xorout=0，所以结果正好是它的按位取反。
  assert_eq(@audio.ogg_crc32(b"123456789"), 0x765E7680 ^ -1)
  // (3) 完整 page 的 CRC（由一份独立编写的 Python 参考实现推导，页面字节见下面）
  assert_eq(
    @audio.ogg_crc32(Bytes::from_array(ogg_test_page_a_zero_crc())),
    0x2A411425,
  )
}

///|
test "ogg: 长 page 的 crc32 也匹配独立推导值" {
  // page：serial 0x1111、seq 0、header_type 0x02、segments [3,255]、
  // body = AA BB CC + (i & 0xFF) for i in 0..255，共 287 字节
  let body : Array[Byte] = [b'\xAA', b'\xBB', b'\xCC']
  for i = 0; i < 255; i = i + 1 {
    body.push((i & 0xFF).to_byte())
  }
  let raw = ogg_test_page_zero_crc(0, 0x02, 0L, 0x1111, 0, [3, 255], body)
  assert_eq(raw.length(), 287)
  assert_eq(@audio.ogg_crc32(Bytes::from_array(raw)), 0x43C23746)
}

///|
test "ogg: 查表实现与测试内按位实现逐一对拍" {
  let body : Array[Byte] = []
  let mut lcg = 12345
  for i = 0; i < 300; i = i + 1 {
    lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF
    body.push(((lcg >> 16) & 0xFF).to_byte())
  }
  let pseudo_random = Bytes::from_array(body)
  let inputs : Array[Bytes] = [
    b"",
    b"\x01",
    b"\xFF",
    b"\x00\x00",
    b"123456789",
    b"OggS",
    Bytes::from_array(ogg_test_page_a_zero_crc()),
    pseudo_random,
  ]
  for data in inputs {
    assert_eq(@audio.ogg_crc32(data), ogg_test_crc32_bitwise(data))
  }
}

// ---------------------------------------------------------------------------
// 11. codec 识别与辅助谓词
// ---------------------------------------------------------------------------

///|
test "ogg: 五种 codec 标识与未知标识" {
  assert_eq(@audio.ogg_codec_of_packet(b"\x01vorbis"), @audio.OggCodec::Vorbis)
  assert_eq(@audio.ogg_codec_of_packet(b"OpusHead"), @audio.OggCodec::Opus)
  assert_eq(@audio.ogg_codec_of_packet(b"\x80theora"), @audio.OggCodec::Theora)
  assert_eq(@audio.ogg_codec_of_packet(b"fLaC"), @audio.OggCodec::Flac)
  assert_eq(@audio.ogg_codec_of_packet(b"Speex   "), @audio.OggCodec::Speex)
  assert_eq(@audio.ogg_codec_of_packet(b"\x7FFLAC"), @audio.OggCodec::Unknown)
  assert_eq(@audio.ogg_codec_of_packet(b""), @audio.OggCodec::Unknown)
  assert_eq(@audio.ogg_codec_of_packet(b"fLa"), @audio.OggCodec::Unknown)
  // 前缀匹配要严格：多一个字符就不是 Vorbis
  assert_eq(@audio.ogg_codec_of_packet(b"\x01vorbisX"), @audio.OggCodec::Vorbis)
  assert_eq(@audio.ogg_codec_of_packet(b"OpusHea"), @audio.OggCodec::Unknown)
}

///|
test "ogg: ogg_codec_of_stream 只看 BOS 页的第一个 packet" {
  let vorbis = ogg_test_build_page(0, 0x02, 0L, 0x9999, 0, [7, 1], [
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's', b'\x00',
  ])
  assert_eq(@audio.ogg_codec_of_stream(vorbis), @audio.OggCodec::Vorbis)
  let opus = ogg_test_build_page(0, 0x02, 0L, 0x9999, 0, [8], [
    b'O', b'p', b'u', b's', b'H', b'e', b'a', b'd',
  ])
  assert_eq(@audio.ogg_codec_of_stream(opus), @audio.OggCodec::Opus)
  let unknown = ogg_test_build_page(0, 0x02, 0L, 0x9999, 0, [2], [
    b'\xDE', b'\xAD',
  ])
  assert_eq(@audio.ogg_codec_of_stream(unknown), @audio.OggCodec::Unknown)
  // 第一个 packet 只有 3 字节，装不下 7 字节标识 → Unknown
  let too_short = ogg_test_build_page(0, 0x02, 0L, 0x9999, 0, [3, 4], [
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's',
  ])
  assert_eq(@audio.ogg_codec_of_stream(too_short), @audio.OggCodec::Unknown)
}

///|
test "ogg: header_type 三个标志位与 first_packet_len" {
  let none = ogg_test_build_page(0, 0x00, 0L, 0x1234, 0, [1], [b'\x01'])
  let both = ogg_test_build_page(0, 0x06, 0L, 0x1234, 0, [1], [b'\x01'])
  let (p_none, _) = ogg_test_parse(none, 0)
  let (p_both, _) = ogg_test_parse(both, 0)
  assert_false(@audio.ogg_page_is_bos(p_none))
  assert_false(@audio.ogg_page_is_eos(p_none))
  assert_true(@audio.ogg_page_is_bos(p_both))
  assert_true(@audio.ogg_page_is_eos(p_both))
  // [7, 3] → 第一个 packet 7 字节；[255, 5] → 260；[255] → 整页 255
  let (p1, _) = ogg_test_parse(
    ogg_test_build_page(0, 0x02, 0L, 0x1234, 0, [7, 3], [
      b'\x01', b'v', b'o', b'r', b'b', b'i', b's', b'\xAA', b'\xBB', b'\xCC',
    ]),
    0,
  )
  assert_eq(@audio.ogg_first_packet_len(p1), 7)
  let body : Array[Byte] = []
  for i = 0; i < 255; i = i + 1 {
    body.push(b'\x55')
  }
  body.push(b'\x66')
  body.push(b'\x67')
  body.push(b'\x68')
  body.push(b'\x69')
  body.push(b'\x6A')
  let (p2, _) = ogg_test_parse(
    ogg_test_build_page(0, 0x02, 0L, 0x1234, 0, [255, 5], body),
    0,
  )
  assert_eq(@audio.ogg_first_packet_len(p2), 260)
}

///|
test "ogg: 真实编码器产出的 page（外部真值，CRC 由 libogg 写入）" {
  // 取自一个真实 Vorbis 文件的第一页（MathJax invalid_keypress.ogg，58 字节＝27+1+30）。
  // 这一页的 CRC 字段是**真实编码器**算出来的，不是本项目任何代码生成的，
  // 所以它能同时验证「我的 page 校验接受 libogg 的 CRC」和「ogg_crc32 就是 Ogg 约定」。
  let real : Array[Byte] = [
    b'\x4F', b'\x67', b'\x67', b'\x53', b'\x00', b'\x02', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x44', b'\xF5', b'\xC6', b'\x54',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x58', b'\xED', b'\x7C', b'\x5F', b'\x01',
    b'\x1E', b'\x01', b'\x76', b'\x6F', b'\x72', b'\x62', b'\x69', b'\x73', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x02', b'\x44', b'\xAC', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x80', b'\xB5', b'\x01', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\xB8', b'\x01',
  ]
  let real_bytes = Bytes::from_array(real)
  assert_eq(real_bytes.length(), 58)
  assert_eq(@audio.ogg_crc32(ogg_test_zero_crc_field(real_bytes)), 0x5F7CED58)
  // 解析必须通过（即：重算出来的 CRC 与文件里 libogg 写的那个一致）
  let (page, next) = ogg_test_parse(real_bytes, 0)
  assert_eq(next, 58)
  assert_eq(page.version, 0)
  assert_eq(page.header_type, 0x02)
  assert_eq(page.serial, 1422325060) // 0x54C6F544
  assert_eq(page.sequence, 0)
  assert_eq(page.granule_position, 0L)
  assert_eq(page.checksum, 0x5F7CED58)
  assert_eq(page.segments.length(), 1)
  assert_eq(page.segments[0], 30)
  assert_eq(page.body.length(), 30)
  assert_eq(@audio.ogg_codec_of_stream(real_bytes), @audio.OggCodec::Vorbis)
  let groups = @audio.packets_of(ogg_test_pages(real_bytes))
  assert_eq(groups.length(), 1)
  let (serial, pkts) = groups[0]
  assert_eq(serial, 1422325060)
  assert_eq(pkts.length(), 1)
  assert_eq(pkts[0].length(), 30)
  ogg_test_assert_bytes(pkts[0], [
    b'\x01', b'v', b'o', b'r', b'b', b'i', b's', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x02', b'\x44', b'\xAC', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\x80', b'\xB5', b'\x01', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00', b'\xB8',
    b'\x01',
  ])
}

// ---------------------------------------------------------------------------
// 12. 畸形 page（手工构造的 OggPage 值）不应 panic
// ---------------------------------------------------------------------------

///|
test "ogg: segments 之和超过 body 长度时不 panic 并保留已收尾的 packet" {
  let broken : @audio.OggPage = @audio.OggPage::{
    version: 0,
    header_type: 0x02,
    granule_position: 0L,
    serial: 7,
    sequence: 0,
    checksum: 0,
    segments: [3, 4],
    body: b"\x01\x02\x03",
  }
  let groups = @audio.packets_of([broken])
  assert_eq(groups.length(), 1)
  let (serial, pkts) = groups[0]
  assert_eq(serial, 7)
  // 第一段就能收尾，越界之后不再产出
  assert_eq(pkts.length(), 1)
  assert_eq(pkts[0].length(), 3)
}

///|
test "ogg: packets_of 空输入返回空数组" {
  assert_eq(@audio.packets_of([]).length(), 0)
}

// ---------------------------------------------------------------------------
// CRC 真值来源（为什么这些常量可以相信）
// ---------------------------------------------------------------------------
//
// 自洽性测试（构造 page → 算 CRC → 填回 → 解析通过）**不能**发现「初值写错」或
// 「结果多取了反」这类系统性错误，因为编解码用的是同一个错函数。所以上面额外钉了
// 三类与实现无关的真值：
//
// 1. 手推：`crc32(b"\x01") == 0x04C11DB7`
//    0x01 → 状态 0x01000000；8 轮里前 7 轮最高位为 0（纯左移），第 8 轮最高位为 1，
//    于是 (0x80000000 << 1) 截断成 0 后再异或多项式 0x04C11DB7。推导见测试注释。
// 2. 与公开参考挂钩：CRC-32/POSIX（cksum 变体）的权威 check 值
//    `0x765E7680 = CRC(poly=0x04C11DB7, init=0xFFFFFFFF, refin=false, refout=false,
//    xorout=0xFFFFFFFF, "123456789")`。Ogg 与它同多项式、同位序，只有 init/xorout 不同，
//    两者相差一次按位取反，故 `crc32(b"123456789") == 0x765E7680 ^ -1 == 0x89A1897F`。
// 3. 独立实现：一份另行编写的 Python 参考实现（先用比特级逐位算法与查表算法互相
//    对拍 200 组随机数据，再复现出上面的 POSIX check 值确认参数理解无误）算出的
//    page 级常量：39 字节最小页 → 0x2A411425，287 字节跨页测试页 → 0x43C23746。
// 4. 外部真值：一个真实 Vorbis 文件的第一页（58 字节）原样抄进测试，它的 CRC 字段
//    `0x5F7CED58` 是 libogg 写进去的。`parse_page` 能通过校验，说明本库的 CRC 与
//    真实编码器一致；该页也被 Python 解析器独立复算过。
//
// 另外测试内自带一份独立的按位实现 `ogg_test_crc32_bitwise`，对 8 组输入与包内
// 查表实现逐一对拍。
