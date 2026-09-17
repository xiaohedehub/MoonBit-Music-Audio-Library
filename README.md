# MoonBit Music Audio Library · 月音音频库

<p align="center">
  <img src="https://coresg-normal.trae.ai/api/ide/v1/text_to_image?prompt=abstract%20music%20sound%20wave%20visualization%20with%20blue%20purple%20gradient%20flow%20geometric%20minimal%20modern%20banner&image_size=landscape_16_9" alt="banner" width="100%" style="border-radius:16px;max-height:240px;object-fit:cover;"/>
</p>

<p align="center">
  <a href="#-功能特性"><kbd>功能特性</kbd></a>
  &nbsp;·&nbsp;
  <a href="#-支持格式"><kbd>支持格式</kbd></a>
  &nbsp;·&nbsp;
  <a href="#-快速开始"><kbd>快速开始</kbd></a>
  &nbsp;·&nbsp;
  <a href="#-构建目标"><kbd>构建目标</kbd></a>
</p>

---

纯 **MoonBit** 实现的跨平台音频解码库。零 FFI、零第三方依赖，仅使用 `moonbitlang/core` 标准库，可编译至 **Native / JS / WASM / WASM-GC** 四大后端。

---

## ✨ 功能特性

| 特性 | 说明 |
| :-- | :-- |
| 🔌 **零依赖** | 不引入任何第三方包，不做 FFI，开箱即用 |
| 🧠 **格式自动识别** | 通过魔数自动探测 WAV / FLAC / OGG / MP3 |
| 📦 **纯内存 I/O** | 输入统一为 `Bytes`，不触碰文件/网络/线程，易于跨平台 |
| 🧩 **单包架构** | 整个库为一个 MoonBit 包，便于集成和理解 |
| 🏷️ **标签解析** | 支持 ID3v2（v2.2/2.3/2.4）与 Vorbis Comment |
| ✅ **错误可判别** | 所有错误分支使用 `AudioError` 结构化枚举，不靠字符串解析 |
| 🔒 **宁可失败不输出错数据** | 未实现的解码器统一抛 `Unsupported`，绝不返回未经校验的 PCM |

---

## 🎵 支持格式

| 格式 | 元数据 | 格式解析 | 样本解码 |
| :-- | :--: | :--: | :--: |
| **WAV** (PCM / IEEE float) | ✅ | ✅ 完整 | ✅ 完整 |
| **FLAC** (无损) | ✅ Vorbis Comment | ✅ 完整 | ✅ 完整 |
| **ID3v2** (v2.2 / 2.3 / 2.4) | ✅ 完整标签与封面 | ✅ 完整 | — |
| **Ogg** 容器 | ✅ Page / Packet / CRC | ✅ 完整 | — |
| **MP3** 帧结构 | ✅ 帧头 / Side Info / 同步 | ✅ 完整 | ❌ 未实现 |
| **Vorbis** Header | ✅ Ident / Comment / Setup 全校验 | ✅ 完整 | ❌ 未实现 |

> **FLAC 无损验证原则**：解码所得 PCM 必须与编码前的原始 WAV 逐样本、逐比特完全一致。
> 有损格式（MP3 / Vorbis）需使用外部参考解码器（ffmpeg）做差分比对验证。

---

## 🚀 快速开始

### 统一入口（自动识别）

```moonbit
// 一次性解码，自动识别格式
let audio = @audio.decode(data)  // -> Audio

// 只取格式信息（不消耗 CPU 解码样本）
let fmt = @audio.info(data)      // -> AudioFormat

// 只解析标签（WAV/FLAC → Vorbis Comment，MP3 → ID3v2，OGG → Comment Header）
let tags = @audio.tags(data)     // -> Array[(String, String)]
```

### 按格式分别调用

```moonbit
match detect_format(data) {
  AudioFormatHint::Wav => {
    let audio = decode_wav(data)
    println("格式: \{audio.format}")                  // 例: "44100Hz/2ch/16bit"
    println("时长: \{audio.duration_seconds()} 秒")
    println("帧数: \{audio.frame_count()}")
  }
  AudioFormatHint::Flac => {
    let audio = decode_flac(data)
  }
  AudioFormatHint::Mp3  => println("MP3 样本解码暂未实现")
  _ => println("非音频格式")
}
```

### 命令行工具（`cmd/audioinfo`）

```bash
cd moonbit-music
moon run cmd/audioinfo -- sample/demo.wav
```

---

## 🎯 构建目标

本项目在以下所有后端均可正常编译：

| 后端 | 命令 | 典型场景 |
| :-- | :-- | :-- |
| **Native** | `moon build --target native` | CLI 工具、桌面程序 |
| **JavaScript** | `moon build --target js` | Node.js、浏览器脚本 |
| **WASM (MVP)** | `moon build --target wasm` | 浏览器、WASM 运行时 |
| **WASM-GC** | `moon build --target wasm-gc` | 现代浏览器 + GC 提案 |

---

## 📐 设计约束

1. **只用 `moonbitlang/core`**：不引入任何第三方包，不做 FFI。
2. **纯内存输入**：所有 API 接受 `Bytes`，不做文件/网络 I/O（I/O 由调用方负责）。
3. **四后端兼容**：任何 API 必须同时通过 `native / js / wasm / wasm-gc` 编译。
4. **结构化错误**：错误必须以 `AudioError` 枚举分支返回，不得靠字符串做逻辑分支。

> **为什么零依赖是硬约束？**  
> MoonBit 标准库不含文件 API；开发环境无法执行 `moon add`（registry 缓存不可写）。
> 对音频解码器而言这也是正确的分层：输入是字节，输出是样本，不应触碰文件系统。

---

## 📁 项目结构

```
moon-music/
├── .gitignore
├── LICENSE                          # MIT License
├── README.md                        # 本文件
├── _vorbis_selftest/                # Vorbis 独立自检工程
│   └── *.mbt                        # 真实 Ogg/Vorbis 样本回归测试
└── moonbit-music/                   # 主库（单 MoonBit 包）
    ├── moon.mod
    ├── moon.pkg
    ├── README.mbt.md                # 开发视角详细说明
    ├── CONTRACT.md                  # 接口契约 v1（冻结）
    ├── types.mbt                    # 公共类型 + Show 实现（冻结）
    ├── errors.mbt                   # AudioError 枚举（冻结）
    ├── moonaudio.mbt                # 库入口（decode / info / tags）
    ├── bitstream.mbt                # 位流读取工具
    ├── checksum.mbt                 # CRC / 校验和
    ├── wav.mbt  + wav_test.mbt      # WAV 解码器
    ├── id3.mbt  + id3_test.mbt      # ID3v2 标签解析
    ├── flac.mbt + flac_test.mbt     # FLAC 无损解码器
    ├── ogg.mbt  + ogg_test.mbt      # Ogg 容器解析 + CRC32
    ├── vorbis.mbt + vorbis_test.mbt # Vorbis Header 全量校验
    ├── mp3.mbt  + mp3_test.mbt      # MP3 帧结构解析
    ├── pcm.mbt  + pcm_test.mbt      # PCM Buffer 工具
    ├── fixtures.mbt                 # 测试向量工厂
    ├── sample/
    │   ├── demo.wav                 # 示例 WAV
    │   └── generate_sample.py       # 构造测试样本
    └── cmd/
        └── audioinfo/               # CLI: 打印音频格式信息
            ├── main.mbt
            └── moon.pkg
```

---

## ✅ 测试与验证

```bash
# 全部后端类型检查
moon check --target native
moon check --target js
moon check --target wasm
moon check --target wasm-gc

# 运行单测（黑盒）
moon test --target native
moon test --target wasm-gc
```

### 已知验证缺口（如实列出）

1. 本机尚未安装 `ffmpeg`，Python 侧也没有 `libsndfile / mutagen`。
   因此 **MP3 / Vorbis 目前只有单元测试，没有与参考解码器的差分验证**。
2. 仓库内没有真实的 `.flac` / `.mp3` / `.ogg` 文件。所有测试向量都是手工构造的字节数组，
   能证明「实现符合规范理解」，但不能保证「规范理解本身正确」。
3. MP3 Huffman 表 1 与 44.1kHz scalefactor band 表数值未经外部参考比对。
   （它们不参与 `decode_mp3`，但作为公开 API 可直接调用。）

**补齐方式**：拿到真实音频文件后，做「原始 WAV → 编码 → 解码 → 逐样本比对」的往返验证。

---

## 🔗 相关链接

- MoonBit 官网：[moonbitlang.com](https://www.moonbitlang.com/)
- MoonBit Core 文档：[docs.moonbitlang.com](https://docs.moonbitlang.com/)
- 接口契约（冻结）：[`CONTRACT.md`](./moon-music/moonbit-music/CONTRACT.md)
- 开发 README：[`README.mbt.md`](./moon-music/moonbit-music/README.mbt.md)

---

## 📄 License

**MIT License** — 见 [`LICENSE`](./LICENSE) 文件。
允许商业使用、修改、分发，仅要求在副本中保留版权和许可声明。
