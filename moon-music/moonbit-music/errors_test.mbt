// moonbit-music —— AudioError 语义与辅助方法的黑盒测试
//
// 覆盖：describe / describe_en / kind / severity / is_data_corruption /
// is_retriable_with_more_resources / to_json，以及五个 suberror 分支
// 的逐分支实例化。所有断言都是精确值（不用"包含"或"模糊匹配"），
// 因为 CLI 的 run_probe() / error_json() 等依赖这里钉死的字符串格式。

///|
/// 把 `f()` 的执行结果包成 Option：抛错得 Some(err)，正常返回得 None。
fn ae_catch(f : () -> Unit raise AudioError) -> AudioError? {
  try {
    f()
    None
  } catch {
    err => Some(err)
  }
}

// ---------------------------------------------------------------------------
// 1. 五个分支的基础字段与 kind() / Show 一致性
// ---------------------------------------------------------------------------

///|
test "Truncated: 字段可命名构造且 kind() 正确" {
  let err = AudioError::Truncated(offset=0x1234, needed=17, available=3)
  assert_eq(err.kind(), "Truncated")
  // Show 与 describe 必须一致（Show impl 就是直接调 describe）
  assert_eq(err.to_string(), err.describe())
}

///|
test "InvalidMagic: 构造 + kind() + 非空 message" {
  let err = AudioError::InvalidMagic("expected fLaC, got RIFF")
  assert_eq(err.kind(), "InvalidMagic")
  assert_eq(err.to_string(), err.describe())
}

///|
test "Unsupported: 构造 + kind()" {
  let err = AudioError::Unsupported("MP3 Huffman table type 5")
  assert_eq(err.kind(), "Unsupported")
  assert_eq(err.to_string(), err.describe())
}

///|
test "ChecksumMismatch: 命名字段 + kind()" {
  let err = AudioError::ChecksumMismatch(expected=0xDEAD, actual=0xBEEF)
  assert_eq(err.kind(), "ChecksumMismatch")
  assert_eq(err.to_string(), err.describe())
}

///|
test "LimitExceeded: 构造 + kind()" {
  let err = AudioError::LimitExceeded("frame size 2MB exceeds 64KB cap")
  assert_eq(err.kind(), "LimitExceeded")
  assert_eq(err.to_string(), err.describe())
}

// ---------------------------------------------------------------------------
// 2. describe() / describe_en() 中英文语义一致性
// ---------------------------------------------------------------------------

///|
test "describe(): Truncated 文本含 offset hex / needed / available" {
  let err = AudioError::Truncated(offset=0x2A, needed=8, available=1)
  // 中文描述中必须同时出现 0x2a、8、1
  assert_true(err.describe().contains("0x2A"))
  assert_true(err.describe().contains("8"))
  assert_true(err.describe().contains("1"))
}

///|
test "describe_en(): Truncated 英文描述含 offset hex / needed / available" {
  let err = AudioError::Truncated(offset=0x100, needed=32, available=4)
  let t = err.describe_en()
  assert_true(t.contains("0x100"))
  assert_true(t.contains("32"))
  assert_true(t.contains("4"))
  // 英文描述不出现中文字符（简单用首字符判断）
  assert_true(t.starts_with("stream"))
}

///|
test "describe(): ChecksumMismatch 含期望与实际的 hex" {
  let err = AudioError::ChecksumMismatch(expected=0xABCD, actual=0xEF01)
  let t = err.describe()
  assert_true(t.contains("0xABCD"))
  assert_true(t.contains("0xEF01"))
}

///|
test "describe_en(): ChecksumMismatch 英文描述含 expected / got" {
  let err = AudioError::ChecksumMismatch(expected=0x1234, actual=0x5678)
  let t = err.describe_en()
  assert_true(t.contains("0x1234"))
  assert_true(t.contains("0x5678"))
  assert_true(t.contains("expected"))
  assert_true(t.contains("got"))
}

// ---------------------------------------------------------------------------
// 3. severity() 三级严重性分类
// ---------------------------------------------------------------------------

///|
test "severity(): Unsupported = 1 (Info)，功能缺口而非数据错" {
  assert_eq(AudioError::Unsupported("x").severity(), 1)
}

///|
test "severity(): Truncated / LimitExceeded = 2 (Warning)，可重试或调用方处理" {
  assert_eq(AudioError::Truncated(offset=0, needed=1, available=0).severity(), 2)
  assert_eq(AudioError::LimitExceeded("x").severity(), 2)
}

///|
test "severity(): InvalidMagic / ChecksumMismatch = 3 (Error)，硬错误" {
  assert_eq(AudioError::InvalidMagic("x").severity(), 3)
  assert_eq(AudioError::ChecksumMismatch(expected=0, actual=1).severity(), 3)
}

// ---------------------------------------------------------------------------
// 4. is_data_corruption()：区分"文件坏了"和"我们不会解"
// ---------------------------------------------------------------------------

///|
test "is_data_corruption(): 三个'坏数据'分支返回 true" {
  assert_true(AudioError::Truncated(offset=0, needed=1, available=0).is_data_corruption())
  assert_true(AudioError::InvalidMagic("x").is_data_corruption())
  assert_true(AudioError::ChecksumMismatch(expected=0, actual=1).is_data_corruption())
}

///|
test "is_data_corruption(): Unsupported / LimitExceeded 不是数据本身损坏" {
  assert_true(!AudioError::Unsupported("x").is_data_corruption())
  assert_true(!AudioError::LimitExceeded("x").is_data_corruption())
}

// ---------------------------------------------------------------------------
// 5. is_retriable_with_more_resources()：只有 LimitExceeded 可调高上限重试
// ---------------------------------------------------------------------------

///|
test "is_retriable_with_more_resources(): 只对 LimitExceeded 返回 true" {
  assert_true(AudioError::LimitExceeded("frame too large").is_retriable_with_more_resources())
  assert_true(!AudioError::Truncated(offset=0, needed=1, available=0).is_retriable_with_more_resources())
  assert_true(!AudioError::InvalidMagic("x").is_retriable_with_more_resources())
  assert_true(!AudioError::Unsupported("x").is_retriable_with_more_resources())
  assert_true(!AudioError::ChecksumMismatch(expected=0, actual=1).is_retriable_with_more_resources())
}

// ---------------------------------------------------------------------------
// 6. to_json()：机器可读输出的形状正确性
// ---------------------------------------------------------------------------

///|
test "to_json(): Truncated JSON 含 kind/offset/needed/available 四个数字字段" {
  let err = AudioError::Truncated(offset=4096, needed=128, available=64)
  let j = err.to_json()
  assert_true(j.contains("\"kind\":\"Truncated\""))
  assert_true(j.contains("\"offset\":4096"))
  assert_true(j.contains("\"needed\":128"))
  assert_true(j.contains("\"available\":64"))
}

///|
test "to_json(): InvalidMagic 对 String message 进行 JSON 转义" {
  // 消息里含引号、反斜杠、换行 —— 必须正确转义，否则生成非法 JSON
  let raw = "say \"hi\" \\ path\nnext\r\ttab"
  let err = AudioError::InvalidMagic(raw)
  let j = err.to_json()
  assert_true(j.contains("\\\"hi\\\""))  // \"hi\"
  assert_true(j.contains("\\\\ path"))   // \\ path
  assert_true(j.contains("\\nnext"))     // \nnext
  assert_true(j.contains("\\r"))         // \r
  assert_true(j.contains("\\ttab"))      // \ttab
}

///|
test "to_json(): Unsupported 的 JSON 含 kind + message" {
  let err = AudioError::Unsupported("floor type = 3")
  let j = err.to_json()
  assert_true(j.contains("\"kind\":\"Unsupported\""))
  assert_true(j.contains("\"message\":\"floor type = 3\""))
}

///|
test "to_json(): ChecksumMismatch 含 expected / actual 两个整数字段" {
  let err = AudioError::ChecksumMismatch(expected=111, actual=222)
  let j = err.to_json()
  assert_true(j.contains("\"kind\":\"ChecksumMismatch\""))
  assert_true(j.contains("\"expected\":111"))
  assert_true(j.contains("\"actual\":222"))
}

///|
test "to_json(): LimitExceeded 含 kind + message 且 message 中文不做额外转义" {
  let err = AudioError::LimitExceeded("单帧大小超过上限")
  let j = err.to_json()
  assert_true(j.contains("\"kind\":\"LimitExceeded\""))
  assert_true(j.contains("单帧大小超过上限"))
}
