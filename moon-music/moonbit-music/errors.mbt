// moonbit-music —— 公共错误类型
//
// = 冻结契约 =
//   AudioError 的 suberror 分支集合（Truncated / InvalidMagic / Unsupported /
//   ChecksumMismatch / LimitExceeded）已在 CONTRACT.md v1 中**冻结**。
//   任何时候都不要新增、删除、重命名分支，也不要修改现有分支的字段签名。
//   如果需要携带更多信息，可以：
//     (a) 塞进现有的 String 字段（用结构化文本，如 "key=val; key2=val2"）
//     (b) 增加辅助方法（像本文件的 severity() / is_data_corruption() 等）
//     (c) 在调用方用 wrapper enum，而不是改动本文件
//
// = 语义分类（不是 derive，是人为约定） =
//   Io              → 外部 I/O 失败（读文件/网络/内存映射错误等），调用方负责
//   Truncated       → 输入本身截断，重传/换文件可能恢复
//   InvalidMagic    → 不是音频 / 数据损坏，通常是硬错误
//   Unsupported     → 文件合法但本实现未覆盖，属于"非致命功能缺口"
//   ChecksumMismatch→ 数据已损坏（比特翻转或截断在块边界之后），硬错误
//   LimitExceeded   → 资源保护（防 DoS），调用方可自行调高上限后重试

///|
/// 音频解码统一错误类型。
///
/// 每个分支都携带足够定位问题的信息，调用方可以按分支做不同处理，
/// 而不是解析错误字符串。
///
/// 声明为 `pub(all)` 而非 `pub`：调用方与测试需要**构造**这些值
/// （例如断言某个输入恰好产生 `InvalidMagic`），只读类型无法构造。
pub(all) suberror AudioError {
  /// 外部 I/O 错误（调用方读文件/网络失败时用此分支包装）。
  Io(String)
  /// 字节流太短、结构不完整。
  Truncated(offset~ : Int, needed~ : Int, available~ : Int)
  /// 魔数或同步字不匹配。
  InvalidMagic(String)
  /// 格式合法但本实现不支持该特性（例如 Vorbis 的某些 floor 类型）。
  Unsupported(String)
  /// 校验和不匹配（CRC-8/CRC-16/Ogg CRC32/MD5）。
  ChecksumMismatch(expected~ : Int, actual~ : Int)
  /// 超出资源上限（防止畸形输入导致内存爆炸）。
  LimitExceeded(String)
} derive(@debug.Debug)

// ---------------------------------------------------------------------------
// 描述与文本化
// ---------------------------------------------------------------------------

///|
/// 将错误转为人类可读的中文描述（用于 CLI 和日志打印）。
pub fn AudioError::describe(self : AudioError) -> String {
  match self {
    AudioError::Io(msg) =>
      "外部 I/O 错误：\{msg}",
    AudioError::Truncated(offset, needed, available) =>
      "字节流截断：在偏移 0x\{offset.to_hex()} 处需要 \{needed} 字节，但只剩 \{available} 字节",
    AudioError::InvalidMagic(msg) =>
      "魔数/同步字不匹配：\{msg}",
    AudioError::Unsupported(msg) =>
      "不支持的特性：\{msg}",
    AudioError::ChecksumMismatch(expected, actual) =>
      "校验和失败：期望 0x\{expected.to_hex()}，实际 0x\{actual.to_hex()}",
    AudioError::LimitExceeded(msg) =>
      "超出资源上限：\{msg}",
  }
}

///|
/// 英文描述（给非中文用户或英文日志管道）。
///
/// 与 `describe()` 语义一一对应，避免中英文信息不对称导致的排查困难。
pub fn AudioError::describe_en(self : AudioError) -> String {
  match self {
    AudioError::Io(msg) =>
      "external I/O error: \{msg}",
    AudioError::Truncated(offset, needed, available) =>
      "stream truncated: need \{needed} bytes at offset 0x\{offset.to_hex()}, only \{available} bytes left",
    AudioError::InvalidMagic(msg) =>
      "invalid magic / sync word: \{msg}",
    AudioError::Unsupported(msg) =>
      "unsupported feature: \{msg}",
    AudioError::ChecksumMismatch(expected, actual) =>
      "checksum mismatch: expected 0x\{expected.to_hex()}, got 0x\{actual.to_hex()}",
    AudioError::LimitExceeded(msg) =>
      "resource limit exceeded: \{msg}",
  }
}

///|
/// 错误类型短标签（枚举分支名），用于聚合统计与 JSON 序列化。
pub fn AudioError::kind(self : AudioError) -> String {
  match self {
    AudioError::Io(_) => "Io",
    AudioError::Truncated(..) => "Truncated",
    AudioError::InvalidMagic(_) => "InvalidMagic",
    AudioError::Unsupported(_) => "Unsupported",
    AudioError::ChecksumMismatch(..) => "ChecksumMismatch",
    AudioError::LimitExceeded(_) => "LimitExceeded",
  }
}

// ---------------------------------------------------------------------------
// 语义分类辅助方法（不破坏冻结结构，纯派生判断）
// ---------------------------------------------------------------------------

///|
/// 严重性级别：
///   - 1 = Info（功能缺口，如 Unsupported，可降级为警告）
///   - 2 = Warning（可能是截断文件，调用方可重试）
///   - 3 = Error（数据确实损坏，必须处理）
///
/// 严重性与"是否致命"是两条独立维度：Unsupported(level=1) 对播放器而言
/// 可能是致命的（不能播放），但对目录扫描工具而言只是个可跳过的 info。
pub fn AudioError::severity(self : AudioError) -> Int {
  match self {
    AudioError::Unsupported(_) => 1,
    AudioError::Truncated(..) => 2,
    AudioError::LimitExceeded(_) => 2,
    AudioError::Io(_) => 2,
    AudioError::InvalidMagic(_) => 3,
    AudioError::ChecksumMismatch(..) => 3,
  }
}

///|
/// 是否**数据已经损坏**（即磁盘或网络上的字节本身就错了，而不是我们不会解）。
///
/// 用于决定是否要尝试其它解码器、是否报告给用户、是否触发缓存失效。
///   - true  → 文件坏了，换解码器也没用
///   - false → 文件本身合法，或者至少无法判断是否损坏
pub fn AudioError::is_data_corruption(self : AudioError) -> Bool {
  match self {
    AudioError::InvalidMagic(_) => true,
    AudioError::ChecksumMismatch(..) => true,
    AudioError::Truncated(..) => true,
    AudioError::Unsupported(_) => false,
    AudioError::LimitExceeded(_) => false,
    AudioError::Io(_) => false,
  }
}

///|
/// 是否可能通过「调高资源上限后重试」来解决。
///
/// 典型场景：调用方默认限制单帧 64KB，遇到真实的 128KB 高码率帧就抛
/// LimitExceeded；调用方检测到此函数返回 true，把上限翻倍再试一次即可。
pub fn AudioError::is_retriable_with_more_resources(self : AudioError) -> Bool {
  match self {
    AudioError::LimitExceeded(_) => true,
    _ => false,
  }
}

// ---------------------------------------------------------------------------
// 机器可读输出
// ---------------------------------------------------------------------------

///|
/// 转成最小 JSON 对象：`{"kind":"Truncated","offset":..,...}`。
///
/// 字段集合与分支严格对应，调用方可直接 `JSON.parse` 后用 `kind` 做 switch。
/// 注意：我们不引入外部 JSON 库，这里手动拼字符串以维持零依赖承诺。
pub fn AudioError::to_json(self : AudioError) -> String {
  let esc = fn (s : String) -> String {
    let mut out = ""
    for ch in s {
      if ch == '"' {
        out = out + "\\\""
      } else if ch == '\\' {
        out = out + "\\\\"
      } else if ch == '\n' {
        out = out + "\\n"
      } else if ch == '\r' {
        out = out + "\\r"
      } else if ch == '\t' {
        out = out + "\\t"
      } else {
        out = out + "\{ch}"
      }
    }
    out
  }
  match self {
    AudioError::Io(msg) =>
      "{\"kind\":\"Io\",\"message\":\"" + esc(msg) + "\"}",
    AudioError::Truncated(offset, needed, available) =>
      "{\"kind\":\"Truncated\",\"offset\":\{offset},\"needed\":\{needed},\"available\":\{available}}",
    AudioError::InvalidMagic(msg) =>
      "{\"kind\":\"InvalidMagic\",\"message\":\"" + esc(msg) + "\"}",
    AudioError::Unsupported(msg) =>
      "{\"kind\":\"Unsupported\",\"message\":\"" + esc(msg) + "\"}",
    AudioError::ChecksumMismatch(expected, actual) =>
      "{\"kind\":\"ChecksumMismatch\",\"expected\":\{expected},\"actual\":\{actual}}",
    AudioError::LimitExceeded(msg) =>
      "{\"kind\":\"LimitExceeded\",\"message\":\"" + esc(msg) + "\"}",
  }
}

///|
/// `Show` 实现：直接调用 `describe`，便于字符串插值与 println。
pub impl Show for AudioError with fn to_string(self : AudioError) -> String {
  self.describe()
}
