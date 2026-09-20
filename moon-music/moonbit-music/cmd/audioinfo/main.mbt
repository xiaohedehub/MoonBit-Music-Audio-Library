// audioinfo —— moonbit-music（hym0721/moonbit-music）的命令行信息工具。只读，不做任何转码。
//
// ── 为什么这个 CLI 不能读文件 ────────────────────────────────────────────────
// moonbit-music 库本身是**零 I/O** 的：按 CONTRACT.md 的硬规则，所有解码入口的输入
// 都是内存里的 `Bytes`，读文件 / 下载 / 内存映射一律由调用方负责。
//
// 本 CLI 为保持同样的零依赖约束（只用 `moonbitlang/core`、零 FFI、不引入外部
// 包），也就拿不到读文件的能力：
//   * `moonbitlang/core` 里**没有任何文件 I/O API** —— 唯一沾边的是
//     `moonbitlang/core/env`，它只提供 `args` / 环境变量 / 当前目录 / 随机数；
//   * `moonbitlang/x` 的 `fs`（`@fs.read_file_to_bytes`）不在本沙箱的 registry
//     缓存里，且引入它需要改写 `moon.mod` —— 本代理无权改动库根目录。
// 真实项目里应该由调用方（或 `moonbitlang/x` 的 `fs`）把文件读成 `Bytes`，
// 再交给解码层 —— 这一层薄得只有 `probe()` 一个函数。
//
// 因此本构建的行为是：
//   * `--help` / `--version` 正常输出；
//   * 给文件路径时，明确说明「本构建不支持文件读取」并打印 `exit code: 2`；
//   * `--self-test` 用**内存里合成**的字节直接调用 `@audio.decode` /
//     `@audio.tags` / `@audio.detect_format`，演示「库可被外部调用」，
//     并把真实的 `AudioError` 按分支结构化打印出来。
//
// ── 退出码：为什么这里一个非零码都给不出来 ──────────────────────────────────
// 约定是 0 成功 / 1 参数错误 / 2 文件读不到 / 3 解码失败。本构建三条路都走不通，
// 全部是实测结论：
//   1. `moonbitlang/core` 没有 `exit` API；`main` 的返回类型被编译器固定为
//      `Unit`（写 `fn main -> Int { 7 }` 直接报错 [3003]）；
//   2. 唯一能表达失败的 `abort()` / `panic()` 在**本工具链上会挂死**：单独建一个
//      最小包（不 import 本库）验证 `fn main { panic() }` 同样不返回，debug 与
//      release 都一样。在 CLI 里用它会把调用方直接卡住，所以不能用；
//   3. 剩下的路只有 FFI（`extern "c" fn exit(code : Int) = "exit"`，core 的
//      `argparse` 内部就是这么做的），但本项目要求零 FFI，不采用。
// 所以失败时只打印一行可被脚本 grep 的
//     audioinfo: failed (intended exit code: N)
// 进程仍以 0 结束。要拿到真正的退出码，二选一：
//   (a) 加一行 `extern "c" fn exit(code : Int) = "exit"`，把 `finish()` 里的打印
//       换成 `exit(code)`；
//   (b) 升级工具链修掉 panic 挂死，再把 `finish()` 换成 `abort(...)`。

///|
/// 工具版本号。与 moon.mod 的 version 保持一致。
let tool_version : String = "0.1.1"

///|
/// 十六进制数字表。`String::substring` 在本工具链上已废弃，这里用查表避开它。
let hex_digits : Array[String] = [
  "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
]

///|
/// 用法文本。`--help` 输出它；参数错误时也打印一次。
fn usage_text() -> String {
  "audioinfo \{tool_version} - inspect audio through the hym0721/moonbit-music decoder (read only)\n" +
  "\n" +
  "usage:\n" +
  "  audioinfo <file>          print format, duration and tags\n" +
  "  audioinfo --json <file>   same, as one line of JSON\n" +
  "  audioinfo --tags <file>   print tags only\n" +
  "  audioinfo --check <file>  identify format only (skip full decode)\n" +
  "  audioinfo --self-test     run the built-in in-memory fixtures through the library\n" +
  "  audioinfo --version       print the version\n" +
  "  audioinfo --help          print this help\n" +
  "\n" +
  "modifiers:\n" +
  "  --json                    machine readable output\n" +
  "  --tags                    tags only\n" +
  "  --check, --check-only     format detection only, skip decode\n" +
  "\n" +
  "exit codes:\n" +
  "  intended: 0 success / 1 usage / 2 unreadable file / 3 decode failure.\n" +
  "  this build always exits 0: core has no exit(), and abort()/panic() hang on this\n" +
  "  toolchain. Failures print `audioinfo: failed (intended exit code: N)` instead.\n" +
  "\n" +
  "note: this build cannot open files. The hym0721/moonbit-music library is I/O-free by contract\n" +
  "      (every entry point takes an in-memory Bytes), and this CLI stays at zero\n" +
  "      dependencies (moonbitlang/core only, no FFI), while core ships no file API.\n" +
  "      Reading the file is the caller's job; --self-test exercises the library on\n" +
  "      bytes it synthesises in memory.\n"
}

// ---------------------------------------------------------------------------
// 命令行解析
// ---------------------------------------------------------------------------

///|
/// 解析后的动作。
enum Action {
  Help
  Version
  /// 文件模式：本构建读不到文件，只会打印说明。
  FileInfo(json~ : Bool, tags_only~ : Bool, check_only~ : Bool, path~ : String)
  /// 内存自检。
  SelfTest(json~ : Bool, tags_only~ : Bool, check_only~ : Bool)
}

///|
/// 解析 argv（含 argv[0]）；不合法时返回错误消息。
fn parse_args(argv : Array[String]) -> Result[Action, String] {
  let mut json = false
  let mut tags_only = false
  let mut check_only = false
  let mut self_test = false
  let mut path : String? = None
  for i = 1; i < argv.length(); i = i + 1 {
    let arg = argv[i]
    if arg == "--help" || arg == "-h" {
      return Ok(Action::Help)
    } else if arg == "--version" {
      return Ok(Action::Version)
    } else if arg == "--json" {
      json = true
    } else if arg == "--tags" {
      tags_only = true
    } else if arg == "--check" || arg == "--check-only" {
      check_only = true
    } else if arg == "--self-test" {
      self_test = true
    } else if starts_with_dash(arg) {
      return Err("unknown option: \{arg}")
    } else if path is Some(_) {
      return Err("expected at most one file path, got an extra: \{arg}")
    } else {
      path = Some(arg)
    }
  }
  if self_test {
    match path {
      Some(p) => Err("--self-test does not take a file path (got \{p})")
      None => Ok(Action::SelfTest(json~, tags_only~, check_only~))
    }
  } else {
    match path {
      Some(p) => Ok(Action::FileInfo(json~, tags_only~, check_only~, path=p))
      None => Err("missing file path (or use --self-test)")
    }
  }
}

///|
/// `-x` 形式的短选项判断。单个 `-` 当成路径，不算选项。
fn starts_with_dash(arg : String) -> Bool {
  arg.length() > 1 && arg.has_prefix("-")
}

// ---------------------------------------------------------------------------
// 内存自检用的夹具
// ---------------------------------------------------------------------------

///|
/// 一条自检用例。
///
/// * `expect` 是 `detect_format` 应该给出的名字（用 `Show` 的文本形式，
///   这样断言不依赖 `AudioFormatHint` 是否派生了 `Eq`）；
/// * `decodable` 标记这条夹具是不是完整音频 —— 只有合成的那个小 WAV 是，
///   其余几条都只有头部魔数，`decode()` 理应在它们身上抛错。
struct Fixture {
  name : String
  data : Bytes
  expect : String
  decodable : Bool
}

///|
/// 小端写 16 位。
fn put_u16_le(out : Buffer, value : Int) -> Unit {
  out.write_byte((value & 0xFF).to_byte())
  out.write_byte(((value >> 8) & 0xFF).to_byte())
}

///|
/// 小端写 32 位。
fn put_u32_le(out : Buffer, value : Int) -> Unit {
  put_u16_le(out, value & 0xFFFF)
  put_u16_le(out, (value >> 16) & 0xFFFF)
}

///|
/// 就地合成一个小 RIFF/WAVE：8 帧 / 单声道 / 16 bit / 8000 Hz。
///
/// 样本是 440 Hz 正弦在 8 kHz 下的前 8 个点（幅度 0.5），与
/// `sample/generate_sample.py` 用同一套参数算出，方便互相对照。
/// 这里刻意手写 RIFF 头，而不是读 `sample/demo.wav` —— 本构建读不到文件。
///
/// 注意这里只往 `Buffer` 写**原始字节**并用 `to_bytes()` 取回；
/// `Buffer::to_string()` 会把内容按 UTF-16LE 解释（见 `json_escape` 上的注释），
/// 不能用来做字符串。
fn synth_wav() -> Bytes {
  let samples : Array[Int] = [0, 5550, 10443, 14102, 16093, 16182, 14357, 10835]
  let channels = 1
  let bits = 16
  let frame_bytes = channels * bits / 8
  let data_len = samples.length() * frame_bytes
  let out = Buffer()
  out.write_bytes(b"RIFF")
  put_u32_le(out, 36 + data_len) // RIFF chunk size
  out.write_bytes(b"WAVE")
  out.write_bytes(b"fmt ")
  put_u32_le(out, 16) // PCM fmt chunk size
  put_u16_le(out, 1) // audio format = PCM
  put_u16_le(out, channels)
  put_u32_le(out, 8000) // sample rate
  put_u32_le(out, 8000 * frame_bytes) // byte rate
  put_u16_le(out, frame_bytes) // block align
  put_u16_le(out, bits)
  out.write_bytes(b"data")
  put_u32_le(out, data_len)
  for sample in samples {
    put_u16_le(out, sample & 0xFFFF)
  }
  out.to_bytes()
}

///|
/// 自检用例表：覆盖 `detect_format` 认识的全部容器，外加一个反例。
fn fixtures() -> Array[Fixture] {
  [
    {
      name: "synthetic WAV, 8 frames / 8000 Hz / mono / 16 bit",
      data: synth_wav(),
      expect: "Wav",
      decodable: true,
    },
    {
      name: "FLAC stream marker + STREAMINFO header",
      data: b"fLaC\x00\x00\x00\x22",
      expect: "Flac",
      decodable: false,
    },
    {
      name: "Ogg page header",
      data: b"OggS\x00\x02\x00\x00\x00\x00\x00\x00",
      expect: "Ogg",
      decodable: false,
    },
    {
      name: "ID3v2.4 tag header",
      data: b"ID3\x04\x00\x00\x00\x00\x00\x0A",
      expect: "Mp3",
      decodable: false,
    },
    {
      name: "MPEG-1 Layer III frame sync",
      data: b"\xFF\xFB\x90\x00",
      expect: "Mp3",
      decodable: false,
    },
    { name: "not audio (plain text)", data: b"hello, moonbit-music\n", expect: "Unknown", decodable: false },
  ]
}

// ---------------------------------------------------------------------------
// 解码层调用：唯一接触 moonbit-music 的地方
// ---------------------------------------------------------------------------

///|
/// 采集一个 `Bytes` 的全部信息。
///
/// 失败时按契约抛 `@audio.AudioError`，由 `run_probe()` 接住。
/// 真实的 CLI 里 `data` 由调用方读文件得到；本构建读不到文件，
/// 所以只喂内存里合成的夹具 —— 见文件头。
///
/// `check_only = true` 时只做 `detect_format` + `info()`（不解码样本），
/// 适合大文件快速预检。
fn probe(data : Bytes, tags_only : Bool, check_only : Bool) -> Probe raise @audio.AudioError {
  if check_only {
    // 预检模式：只调 info() + tags()，都只读头部、不解码样本。
    // info() 返回的是 AudioFormat 本身（不是 Audio），所以 format = Some(info)。
    let format = @audio.info(data)
    // tags() 同样只读头部（FLAC metadata / ID3v2 / Vorbis comment），成本可接受。
    // 标签解析失败不影响格式信息，用 try+catch 兜底，失败时给空数组。
    let tags = try { @audio.tags(data) } catch { _ => [] }
    {
      format: Some(format),
      frames: None,
      duration: None,
      tags: Some(tags),
    }
  } else if tags_only {
    { format: None, frames: None, duration: None, tags: Some(@audio.tags(data)) }
  } else {
    let audio = @audio.decode(data)
    {
      format: Some(audio.format),
      frames: Some(audio.frame_count()),
      duration: Some(audio.duration_seconds()),
      tags: Some(audio.tags),
    }
  }
}

///|
/// 一条查询结果。拿不到的字段是 `None`，渲染层会打 `n/a` / JSON `null`。
struct Probe {
  format : @audio.AudioFormat?
  frames : Int?
  duration : Double?
  tags : Array[(String, String)]?
}

///|
/// `probe()` 的两种结局：拿到结果，或者一个结构化的解码错误。
enum Outcome {
  Probed(Probe)
  /// `(分支名, 有序字段表)`
  DecodeFailed(String, Array[(String, String)])
}

///|
/// 跑一次 `probe()` 并把错误收敛成值。
///
/// 这里用 `try { } catch { }` 而不是让错误逃逸，有两个原因：
///   1. `AudioError` **没有实现 `Show`**，只有逐分支模式匹配才能拿到字段，
///      调用方才能真正按分支做不同处理；
///   2. 本工具链的 `panic()` / `abort()` 会挂死（见文件头），任何异常都必须在
///      进程内接住，不能指望运行时帮你退出。
fn run_probe(data : Bytes, tags_only : Bool, check_only : Bool) -> Outcome {
  try {
    Probed(probe(data, tags_only, check_only))
  } catch {
    @audio.Io(message) => DecodeFailed("Io", [("message", message)])
    @audio.InvalidMagic(message) => DecodeFailed("InvalidMagic", [("message", message)])
    @audio.Unsupported(feature) => DecodeFailed("Unsupported", [("feature", feature)])
    @audio.Truncated(offset~, needed~, available~) => DecodeFailed(
      "Truncated",
      [("offset", "\{offset}"), ("needed", "\{needed}"), ("available", "\{available}")],
    )
    @audio.ChecksumMismatch(expected~, actual~) => DecodeFailed(
      "ChecksumMismatch",
      [("expected", "\{expected}"), ("actual", "\{actual}")],
    )
    @audio.LimitExceeded(message) => DecodeFailed("LimitExceeded", [("message", message)])
  }
}

// ---------------------------------------------------------------------------
// 结构化错误的渲染
// ---------------------------------------------------------------------------

///|
/// 文本形式打印 `(分支名, 字段表)`，每个字段各占一行。
fn print_error_detail(
  indent : String,
  branch : String,
  fields : Array[(String, String)],
) -> Unit {
  println("\{indent}branch: \{branch}")
  for field in fields {
    println("\{indent}\{field.0}: \{field.1}")
  }
}

///|
/// JSON 形式打印 `(分支名, 字段表)`：`{"branch":"Truncated","offset":..,..}`。
fn error_json(branch : String, fields : Array[(String, String)]) -> String {
  let mut out = "{\"branch\":\"" + json_escape(branch) + "\""
  for field in fields {
    out = out + ",\"" + json_escape(field.0) + "\":\"" + json_escape(field.1) + "\""
  }
  out + "}"
}

// ---------------------------------------------------------------------------
// 输出渲染
// ---------------------------------------------------------------------------

///|
/// JSON 字符串转义。标签值来自文件，可能含引号 / 反斜杠 / 控制字符，
/// 不转义就会生成非法 JSON（Windows 路径里的反斜杠也一样）。
///
/// 用 `String` 拼接而不是 `Buffer`：本工具链上 `Buffer::to_string()` 会把
/// 缓冲区内容按 UTF-16LE 解释，配 `write_string_utf8` 用会得到乱码
/// （实测 `{"fixtures":` 变成了 `≻楦瑸牵獥㨢`）。
fn json_escape(text : String) -> String {
  let mut out = ""
  for ch in text {
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
    } else if ch.to_int() < 0x20 {
      let value = ch.to_int()
      out = out + "\\u00" + hex_digits[(value >> 4) & 0xF] + hex_digits[value & 0xF]
    } else {
      out = out + "\{ch}"
    }
  }
  out
}

///|
/// 保留 3 位小数的秒数（四舍五入到毫秒）。
fn format_seconds(value : Double) -> String {
  let total_ms = (value * 1000.0).round().to_int()
  let whole = total_ms / 1000
  let frac = total_ms % 1000
  let frac_text = if frac < 10 {
    "00\{frac}"
  } else if frac < 100 {
    "0\{frac}"
  } else {
    "\{frac}"
  }
  "\{whole}.\{frac_text}"
}

///|
/// `Int?` → 显示文本；未知打 `n/a`。
fn show_int(value : Int?) -> String {
  match value {
    Some(v) => "\{v}"
    None => "n/a"
  }
}

///|
/// `Double?` 时长 → 显示文本；未知打 `n/a`。
fn show_seconds(value : Double?) -> String {
  match value {
    Some(v) => "\{format_seconds(v)} s"
    None => "n/a"
  }
}

///|
/// 取 `(sample_rate, channels, bits_per_sample)`；格式未知时三个都是 `None`。
fn format_fields(format : @audio.AudioFormat?) -> (Int?, Int?, Int?) {
  match format {
    Some(f) => (Some(f.sample_rate), Some(f.channels), Some(f.bits_per_sample))
    None => (None, None, None)
  }
}

///|
/// 按键排序后的标签副本（不动调用方的数组）。
fn sorted_tags(tags : Array[(String, String)]) -> Array[(String, String)] {
  let copy = tags.copy()
  copy.sort_by(fn(a, b) { a.0.compare(b.0) })
  copy
}

///|
/// 人类可读模式下打印标签块。`None`（未知）打 `n/a`，空数组打 `(none)`。
fn print_tags(tags : Array[(String, String)]?, indent : String) -> Unit {
  match tags {
    None => println("\{indent}tags            : n/a")
    Some(list) =>
      if list.length() == 0 {
        println("\{indent}tags            : (none)")
      } else {
        println("\{indent}tags            :")
        for entry in sorted_tags(list) {
          println("\{indent}  \{entry.0} = \{entry.1}")
        }
      }
  }
}

///|
/// 打印 `Probe` 的字段（文本模式）。格式行由调用方单独打印，
/// 因为自检还要同时显示「期望」和「实测」。
fn print_probe_fields(result : Probe, indent : String) -> Unit {
  let (sample_rate, channels, bits) = format_fields(result.format)
  println("\{indent}sample_rate     : \{show_int(sample_rate)}")
  println("\{indent}channels        : \{show_int(channels)}")
  println("\{indent}bits_per_sample : \{show_int(bits)}")
  println("\{indent}frames          : \{show_int(result.frames)}")
  println("\{indent}duration        : \{show_seconds(result.duration)}")
  print_tags(result.tags, indent)
}

///|
/// 文本形式渲染一次查询结果（成功或失败）。
fn print_outcome(outcome : Outcome, indent : String, tags_only : Bool) -> Unit {
  match outcome {
    Probed(result) =>
      if tags_only {
        print_tags(result.tags, indent)
      } else {
        print_probe_fields(result, indent)
      }
    DecodeFailed(branch, fields) => {
      println("\{indent}decode failed:")
      print_error_detail(indent + "  ", branch, fields)
    }
  }
}

///|
/// `Int?` → JSON 值。
fn json_int(value : Int?) -> String {
  match value {
    Some(v) => "\{v}"
    None => "null"
  }
}

///|
/// `Double?` → JSON 值。
fn json_double(value : Double?) -> String {
  match value {
    Some(v) => v.to_string()
    None => "null"
  }
}

///|
/// 标签数组 → JSON 对象（按键排序）。未知是 `null`，空是 `{}`。
fn json_tags(tags : Array[(String, String)]?) -> String {
  match tags {
    None => "null"
    Some(list) => {
      let mut out = "{"
      let mut first = true
      for entry in sorted_tags(list) {
        if !first {
          out = out + ","
        }
        first = false
        out = out + "\"" + json_escape(entry.0) + "\":\"" + json_escape(entry.1) + "\""
      }
      out + "}"
    }
  }
}

///|
/// 一条记录 → JSON 对象。
///
/// 形状固定为
/// `{"path":..,"format":..,"sample_rate":..,"channels":..,"bits_per_sample":..,"frames":..,"duration":..,"tags":..}`；
/// `--tags` 模式只留 `path` + `tags`；解码失败时信息字段为 `null` 并多一个
/// `"error":{"branch":..,..}`。
fn render_json(
  label : String,
  hint : @audio.AudioFormatHint,
  outcome : Outcome,
  tags_only : Bool,
) -> String {
  let mut out = "{\"path\":\"" + json_escape(label) + "\""
  match outcome {
    DecodeFailed(branch, fields) => {
      if !tags_only {
        out = out + ",\"format\":\"" + json_escape(hint.to_string()) + "\""
        out = out +
          ",\"sample_rate\":null,\"channels\":null,\"bits_per_sample\":null" +
          ",\"frames\":null,\"duration\":null"
      }
      out = out + ",\"tags\":null,\"error\":" + error_json(branch, fields)
    }
    Probed(result) => {
      if !tags_only {
        let (sample_rate, channels, bits) = format_fields(result.format)
        out = out + ",\"format\":\"" + json_escape(hint.to_string()) + "\""
        out = out +
          ",\"sample_rate\":" +
          json_int(sample_rate) +
          ",\"channels\":" +
          json_int(channels) +
          ",\"bits_per_sample\":" +
          json_int(bits) +
          ",\"frames\":" +
          json_int(result.frames) +
          ",\"duration\":" +
          json_double(result.duration)
      }
      out = out + ",\"tags\":" + json_tags(result.tags)
    }
  }
  out + "}"
}

// ---------------------------------------------------------------------------
// 内存自检
// ---------------------------------------------------------------------------

///|
/// 检查合成 WAV 那一条是否真的解出了预期格式（8000 Hz / 1 ch / 16 bit / 8 帧）。
///
/// 这是本工具唯一一条「跑通完整解码链路」的硬断言：其余夹具只有头部魔数，
/// 只用来验证识别与错误分支。
fn wav_roundtrip_ok(outcome : Outcome) -> Bool {
  match outcome {
    DecodeFailed(_, _) => false
    Probed(result) => {
      let format_ok = match result.format {
        Some(f) => f.sample_rate == 8000 && f.channels == 1 && f.bits_per_sample == 16
        None => false
      }
      let frames_ok = match result.frames {
        Some(n) => n == 8
        None => false
      }
      format_ok && frames_ok
    }
  }
}

///|
/// 跑 `--self-test`：把内存夹具喂给库，并打印真实的解码结果与错误分支。
///
/// 不读文件、不依赖任何外部资源，所以在当前构建里也能跑通，
/// 用来证明「库可以被外部调用」。全部硬断言通过返回 0，否则返回 3。
fn run_self_test(json : Bool, tags_only : Bool, check_only : Bool) -> Int {
  let cases = fixtures()
  let mut matched = 0
  let mut wav_ok = false
  if json {
    let mut out = "{\"fixtures\":["
    for i = 0; i < cases.length(); i = i + 1 {
      if i > 0 {
        out = out + ","
      }
      let item = cases[i]
      let hint = @audio.detect_format(item.data)
      let outcome = run_probe(item.data, tags_only, check_only)
      if hint.to_string() == item.expect {
        matched = matched + 1
      }
      if item.decodable && wav_roundtrip_ok(outcome) {
        wav_ok = true
      }
      out = out + render_json(item.name, hint, outcome, tags_only)
    }
    let passed = matched + (if wav_ok { 1 } else { 0 })
    out = out +
      "],\"self_test\":{\"detect_matched\":" +
      matched.to_string() +
      ",\"total\":" +
      cases.length().to_string() +
      ",\"wav_roundtrip\":" +
      (if wav_ok { "true" } else { "false" }) +
      ",\"passed\":" +
      passed.to_string() +
      "}}"
    println(out)
  } else {
    println("audioinfo \{tool_version} - self test")
    println("  \{cases.length()} in-memory fixtures, no file I/O")
    if check_only {
      println("  --check-only: format detect + info() only, no full decode")
    }
    for i = 0; i < cases.length(); i = i + 1 {
      let item = cases[i]
      let hint = @audio.detect_format(item.data)
      let detected = hint.to_string()
      let ok = detected == item.expect
      let verdict = if ok { "ok" } else { "FAIL" }
      if ok {
        matched = matched + 1
      }
      let outcome = run_probe(item.data, tags_only, check_only)
      if item.decodable && wav_roundtrip_ok(outcome) {
        wav_ok = true
      }
      println("")
      println("  [\{i + 1}/\{cases.length()}] \{item.name}")
      if tags_only {
        print_outcome(outcome, "  ", tags_only)
      } else {
        println("        expected_format : \{item.expect}")
        println("        detected_format : \{detected}  [\{verdict}]")
        println("        extension_hint  : \{hint.extension()}")
        println("        display_name    : \{hint.display_name()}")
        print_outcome(outcome, "        ", tags_only)
      }
    }
    println("")
    let total = cases.length() + 1
    let passed = matched + (if wav_ok { 1 } else { 0 })
    println("summary:")
    println("  detect_format   : \{matched}/\{cases.length()}")
    println("  WAV round trip  : \{if wav_ok { "ok" } else { "FAIL" }}")
    println("  passed          : \{passed}/\{total}")
    if !wav_ok && !check_only {
      println("")
      println("note: the synthetic WAV did not decode to 8000 Hz / 1 ch / 16 bit / 8 frames.")
      println("      everything else (identification + structured errors) still ran.")
    }
    if check_only {
      println("")
      println("note: --check-only mode skips full decode; WAV round trip assertion is by design not validated.")
    }
  }
  let total = cases.length() + 1
  let passed = matched + (if wav_ok { 1 } else { 0 })
  // check-only 模式不校验 roundtrip，所以只要 detect 全部通过就算成功
  if check_only {
    if matched == cases.length() { 0 } else { 3 }
  } else if passed == total {
    0
  } else {
    3
  }
}

// ---------------------------------------------------------------------------
// 文件模式（本构建读不到文件）
// ---------------------------------------------------------------------------

///|
/// 从路径名中提取扩展名（最后一个 `.` 之后的部分，小写）。没有点返回空串。
fn path_extension(path : String) -> String {
  let mut last_dot = -1
  for i = 0; i < path.length(); i = i + 1 {
    if path.get(i) == '.' {
      last_dot = i
    }
  }
  if last_dot < 0 || last_dot == path.length() - 1 {
    return ""
  }
  let mut out = ""
  for i = last_dot + 1; i < path.length(); i = i + 1 {
    out = out + "\{path.get(i)}"
  }
  out.to_lowercase()
}

///|
/// 文件模式：说明本构建为什么读不到文件，并返回「本应是 2」的退出码。
///
/// 额外基于扩展名用 `format_from_extension()` 推断格式，并和实际字节的
/// `detect_format` 一起展示 —— 即使读不到文件，也演示了「扩展名推断 + 魔数
/// 识别」的双路策略。
fn run_file_info(json : Bool, tags_only : Bool, check_only : Bool, path : String) -> Int {
  ignore(tags_only)
  ignore(check_only)
  let ext = path_extension(path)
  let ext_hint = @audio.format_from_extension(ext)
  let reason = "no file I/O in this build: moonbitlang/core ships no file API and this CLI is kept dependency-free (no FFI, no external packages)"
  if json {
    println(
      "{\"path\":\"" +
      json_escape(path) +
      "\",\"extension\":\"" +
      json_escape(ext) +
      "\",\"extension_hint\":\"" +
      json_escape(ext_hint.to_string()) +
      "\",\"error\":{\"branch\":\"NoFileIo\",\"message\":\"" +
      json_escape(reason) +
      "\"}}",
    )
  } else {
    println("audioinfo: cannot read '\{path}'")
    println("  reason: \{reason}")
    if ext.length() > 0 {
      println("  extension: .\{ext}")
      println("  extension_hint: \{ext_hint.display_name()} (.{ext_hint.extension()})")
    } else {
      println("  extension: (none)")
    }
    println("  note  : hym0721/moonbit-music is I/O-free by contract - every decoder entry point takes")
    println("          an in-memory Bytes, and reading the file is the caller's job.")
    println("  hint  : run `audioinfo --self-test` to exercise the library, or feed the bytes")
    println("          in from your own code (e.g. moonbitlang/x @fs.read_file_to_bytes).")
    println("  exit code: 2 (unreadable file) is only reported, never returned - see the")
    println("          `exit codes` note at the top of main.mbt for why.")
  }
  2
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

///|
/// 收尾。非零 `code` 说明这次运行失败了。
///
/// 本构建**无法**真的设置退出码（原因见文件头：core 没有 `exit`，而
/// `abort()` / `panic()` 在本工具链上会挂死），所以只打印一行可被脚本 grep 的
/// `audioinfo: failed (intended exit code: N)`，进程以 0 结束。
fn finish(code : Int) -> Unit {
  if code != 0 {
    println("audioinfo: failed (intended exit code: \{code})")
  }
}

///|
/// 入口。退出码约定见文件头。
fn main {
  let code = match parse_args(@env.args()) {
    Err(message) => {
      println("audioinfo: \{message}")
      println("")
      println(usage_text())
      1
    }
    Ok(Action::Help) => {
      println(usage_text())
      0
    }
    Ok(Action::Version) => {
      println("audioinfo \{tool_version}")
      0
    }
    Ok(Action::SelfTest(json~, tags_only~, check_only~)) => run_self_test(json, tags_only, check_only)
    Ok(Action::FileInfo(json~, tags_only~, check_only~, path~)) => run_file_info(json, tags_only, check_only, path)
  }
  finish(code)
}
