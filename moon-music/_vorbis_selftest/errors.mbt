// moonaudio —— 公共错误类型
// 本文件已冻结。所有解码器共用 AudioError，不要新增 sub-error 分支。

///|
/// 音频解码统一错误类型。
///
/// 每个分支都携带足够定位问题的信息，调用方可以按分支做不同处理，
/// 而不是解析错误字符串。
///
/// 声明为 `pub(all)` 而非 `pub`：调用方与测试需要**构造**这些值
/// （例如断言某个输入恰好产生 `InvalidMagic`），只读类型无法构造。
pub(all) suberror AudioError {
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
