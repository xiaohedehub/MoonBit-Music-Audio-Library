# moonbit-music · 月音

纯 MoonBit 音频解码库。WAV、FLAC（无损）、Ogg/Vorbis、MP3，
以及 ID3v2 标签解析。**零 FFI、零第三方依赖**，只用 `moonbitlang/core`。

## 状态

| 能力 | 状态 |
| --- | --- |
| 格式自动识别 | ✅ 完整 |
| WAV (PCM / IEEE float) | ✅ 完整 |
| FLAC（无损解码） | ✅ 实现完整（含全部子帧类型与声道去相关） |
| ID3v2 标签（v2.2 / v2.3 / v2.4） | ✅ 完整 |
| Ogg 容器 | ✅ 完整（page / packet / 多路复用重组 / CRC 校验） |
| MP3 帧结构（帧头 / ID3 / 同步 / side info） | ✅ 完整 |
| MP3 样本解码 | ❌ 未实现 |
| Vorbis header（ident / comment / setup） | ✅ 完整（含全部 codebook / floor / residue / mapping / mode 校验） |
| Vorbis 音频包解码与合成 | ❌ 未实现 |
| Ogg/Opus、Ogg/FLAC 封装 | ❌ 未实现 |

**关于「完整」的口径**：`decode_flac` 会返回真实的 PCM 样本。而 `decode_vorbis`
会完整解析并校验 setup header（codebook / floor / residue / mapping / mode / framing），
任何结构错误都抛出精确的 `AudioError`；但**音频包解码与合成（floor 曲线 / residue /
反耦合 / IMDCT / overlap-add）尚未实现，因此校验通过后一律抛 `Unsupported`**——
它永远不会返回音频数据。

未实现的部分**一律抛出 `AudioError::Unsupported` 并在消息里写明缺失步骤**，
不会返回未经校验的音频数据。这是本项目的一条硬规则：
宁可明确失败，也不输出可能错误的 PCM。

## 快速示例

```moonbit
fn main {
  // 内存中的字节，库本身不做任何文件 I/O
  let data : Bytes = read_somehow()

  match detect_format(data) {
    AudioFormatHint::Wav => {
      let audio = decode_wav(data)
      println("格式: \{audio.format}")
      println("时长: \{audio.duration_seconds()} 秒")
      println("帧数: \{audio.frame_count()}")
    }
    _ => println("其他格式")
  }
}
```

统一入口（自动识别格式）：

```moonbit
let audio = @audio.decode(data)     // Audio
let fmt   = @audio.info(data)       // AudioFormat
let tags  = @audio.tags(data)       // Array[(String, String)]
```

## 设计约束

- 只用 `moonbitlang/core`，不引入任何第三方包，不做 FFI。
- 输入一律是内存中的 `Bytes`，库本身不做文件或网络 I/O。
- 四个后端（native / js / wasm / wasm-gc）都要能编译。
- 错误统一为 `AudioError`，按分支可判别，不靠解析错误字符串。

### 为什么零依赖是硬约束，而不是偏好

这不只是设计洁癖，是**构建环境的事实限制**：

- MoonBit 标准库 `moonbitlang/core` **不提供任何文件读取 API**（`env` 包只有 `args()`）。
  文件访问在 `moonbitlang/x` 里，属于独立包。
- 本项目的开发环境无法执行 `moon add`（registry 缓存目录不可写），
  因此**任何外部依赖都拉不下来**。

结论：库只接受内存中的 `Bytes`，所有 I/O 由调用方负责。
对 wav/flac/mp3/ogg 这类格式解码器而言这是正确的分层——
输入是字节，输出是样本，本来就不该在库内部碰文件系统。

## 正确性验证思路

**FLAC 是无损格式，因此最强的正确性证明不需要参考解码器：**

> 解码 FLAC 得到的 PCM，必须与编码前的原始 WAV 逐样本、逐比特完全相同。

有损格式（MP3 / Vorbis）才需要外部参考实现（ffmpeg）做差分测试。

### 已知验证缺口（如实列出）

1. **本机没有 ffmpeg**，Python 侧也没有 `libsndfile` / `soundfile` / `mutagen`。
   因此 MP3 与 Vorbis 目前**只有单元测试，没有差分验证**。
2. **仓库内没有真实的 `.flac` / `.mp3` / `.ogg` 文件**。所有测试向量都是
   手工构造的字节数组。这能证明「实现符合规范理解」，但**不能证明「规范理解正确」**——
   如果对规范的理解有偏差，实现和测试会以同样的方式一起错。
3. MP3 的 Huffman 表 1 与 44.1kHz scalefactor band 表数值未经外部参考比对
   （代码注释里已标注）。它们不参与 `decode_mp3`（该方法恒抛 `Unsupported`），
   但作为公开 API 可直接调用。

**补齐方式**：拿到真实音频文件后，做「原始 WAV → 编码 → 解码 → 逐样本比对」的往返验证。

## 开发约定

- 单包结构：库根目录下所有 `.mbt` 同属一个包，文件之间不互相 import。
- 接口契约见 [CONTRACT.md](CONTRACT.md)，其中记录了实测过的工具链陷阱。
- 每个实现文件配一个同名 `*_test.mbt`（黑盒测试）。
