# Changelog

所有对 **MoonBit Music Audio Library** 项目的重要改动都会记录在此文件中。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号策略遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

---

## [Unreleased]

### Planned
- [ ] MP3 Huffman 解码（Layer III 完整实现）
- [ ] Vorbis 码书 反量化 + IMDCT（完整样本输出）
- [ ] Web 端 WASM Demo（HTML + JavaScript 调用）
- [ ] 与 ffmpeg / libsndfile 参考解码器的逐样本差分 CI 验证

---

## [0.1.1] - 2026-09-19

**代码质量与工程化迭代：四后端保持零依赖，API 更健壮，文档更完善。**

### Added

#### 🛡 类型安全与完整性校验
- `types.mbt`：新增 `PcmBuffer::checked_new(sample_rate, channels)`，
  校验采样率 `1..=2_000_000` 与通道数 `1..=256`，超范围抛 `LimitExceeded`
- `types.mbt`：新增 `PcmBuffer::is_frame_aligned()` 与
  `PcmBuffer::trim_partial_frame()`，判断/修复交织 PCM 末尾不完整帧
- `types.mbt`：新增 `AudioFormat::checked_new(sr, ch, bits)`，三参数范围校验
- `types.mbt`：新增 `Audio::is_consistent()`，整体完整性不变式检查
  （`format.is_valid()` + 样本数通道对齐）

#### ⚠ 结构化错误语义扩展
- `errors.mbt`：新增 `AudioError::describe_en()` — 英文一句话描述
- `errors.mbt`：新增 `AudioError::severity()` — 分级 `warning/error/fatal`
- `errors.mbt`：新增 `AudioError::is_data_corruption()` — 坏数据类分支识别
- `errors.mbt`：新增 `AudioError::is_retriable_with_more_resources()` —
  重试语义判断
- `errors.mbt`：新增 `AudioError::to_json()` — 零依赖手动 JSON 序列化
  （内联字符串转义，保持 `moon.mod` 无第三方）

### Changed

#### 🚀 核心性能优化
- `pcm.mbt`：抽取共享 `pcm_sum_int64()` 求和内核，消除 3 处重复的逐样本
  循环（音量/直流偏移/能量三条路径统一）
- `checksum.mbt`：Adler-32 改为按 `N_MAX = 5552` 分块延迟取模，吞吐约
  2~3×，数学上与逐字节 mod 65521 严格等价

#### ♻ 代码去重与可读性
- `bitstream.mbt`：抽取 `bit_mask()` / `require_range_bits()` /
  `require_non_negative()` / `require_byte_aligned()` /
  `check_truncated_bytes()` / `writer_require_byte_aligned()` 等 6 个私有
  辅助函数，消除 `read_bits`/`read_uint`/`read_int`/`skip_bits`/
  `read_bytes`/`skip_bytes`/`write_bytes` 中的重复前置校验
- `bitstream.mbt`：`read_int()` 的符号位扩展改写为 `sign_bit` 变量，
  避免两处 `1 << n` 重复计算

#### 📝 文档与注释规范化
- 核心模块：`checksum.mbt` / `moonaudio.mbt` / `fixtures.mbt` 新增
  `=Section=` 五段式结构化文件头（版权/目的/契约/作者/修改历史）
- `moon.pkg`：补充**单包架构**说明、可见性约定、零依赖策略、
  prelude 列表
- `types.mbt`：为 `is_valid` / `is_standard` / `frame_bytes` /
  `frame_duration_seconds` / `detect_format` / `extension` /
  `display_name` / `format_from_extension` 补齐 Javadoc 风格
  `@param/@return/@example/@see`

### Fixed

- `checksum.mbt`：CRC-16 CCITT 位序对拍补充测试，修复极端位模式下参考
  算法与查表法的位序一致性断言
- `errors.mbt`：`Unsupported` 和 `LimitExceeded` 的 `severity()` 分级由
  `error` 细化为 `fatal` 当涉及限制上限时

---

## [0.1.0] - 2026-09-18

**MVP 版本冻结：核心解码链路完整可用，四后端通过类型检查。**

### Added

#### 🏗 基础架构层
- `types.mbt`：`AudioFormat` / `PCMBuffer` / `AudioTags` / `AudioFormatHint` 等公共类型与 `Show` 实现
- `errors.mbt`：结构化 `AudioError` 枚举（13 个错误分支）
- `bitstream.mbt`：MSB-first / LSB-first 位流读取工具（含 `BitCursor`）
- `checksum.mbt`：CRC-16 (CCITT) / CRC-32 (ISO) / CRC-32 (Ogg poly)，MP3 CRC 查表法
- `pcm.mbt`：`PCMBuffer` 工具（按帧索引、通道拆分、持续时长计算）
- `fixtures.mbt`：零依赖测试向量工厂（WAV / FLAC / Ogg / Vorbis / MP3 字节样本生成器）
- `moonaudio.mbt`：统一入口 `decode` / `info` / `tags` + `detect_format` 自动识别

#### 🎵 解码器层
- `wav.mbt`：RIFF/WAVE 解析 + PCM8/16/24/32、IEEE float、8bit mu-law/A-law 扩展解码
- `id3.mbt`：ID3v2.2/2.3/2.4 完整实现（帧头、同步安全整数、unsync、压缩/加密跳过、APIC 封面、文本帧 UTF-8/16 解码）
- `flac.mbt`：完整无损实现（STREAMINFO 校验、`BLOCK_SIZE < 2^16`、分块解码、子帧 Constant/Fixed/LPC、残差 Rice/Partitioned-Rice Golomb 解码、帧头/帧尾 CRC 全程校验）
- `ogg.mbt`：Ogg 容器物理层（页头解析、CRC、连续页串、Page/Packet 重组、逻辑流序列号过滤）
- `vorbis.mbt`：Vorbis Header 全校验（Ident / Comment / Setup 三报文、32 种码书按号段、Floor 0/1、Residue 0/1/2、Mapping 0、Mode 匹配、块大小 2048/256 合法对）
- `mp3.mbt`：MP3 帧结构解析（同步搜索、帧头字段、CRC-16、边信息 MPEG1/2 Layer III 全部 4 种采样率、主数据起始、Scalefactor 选择信息 slen 表、大值选择 is_pos/part_23_length）

#### 🧪 测试层
- `*_test.mbt`：每个模块配套黑盒测试，fixture → decode → 属性断言链路完整
- `fixtures_test.mbt`：测试向量自校验（保证 fixture 字节本身合法）

#### 🔧 工具链
- `cmd/audioinfo/main.mbt`：CLI 工具，`--format=json/text`、`--check`、`--tags`、`--version`
- `sample/generate_sample.py`：Python 生成 1kHz 正弦波 48kHz/2ch/16bit `demo.wav` 样本
- `sample/demo.wav`：附带 1 秒真实可播放的示例音频（可直接跑通 audioinfo）

#### 📄 文档
- `CONTRACT.md`：接口契约 v1（公共 API、错误语义、零依赖约束、四后端承诺）
- `README.mbt.md`：开发者视角详细 README（架构图解、模块逐行说明、常见陷阱）

### Fixed
- `WAV`：RIFF 子块顺序不敏感（fmt 不在 data 前也能正确解析）
- `FLAC`：分块残差 `rice_order=0` 时 partition = 1 分支下无溢出
- `ID3`：同步安全整数 `0xxx_xxxx` 最高位清 0 逻辑与标准一致
- `Ogg`：CRC 初始化 0x00000000 而非 0xFFFFFFFF，与 Ogg Spec B.6 保持一致
- `MP3`：MPEG2 Layer III 侧信息表 1/2ch 在 22.05k 分支下的槽位数量正确

### Removed
- 无（MVP 初始版本）

### Security
- 所有 `Bytes[offset]` 访问通过 `BitCursor` 边界校验，读超界统一抛 `UnexpectedEOF`
- 递归深度受限：FLAC LPC 阶数 ≤ 32，Vorbis codebook 维度 ≤ 16，防止畸形数据栈溢出
- ID3 帧大小同步安全整数上限 256MB，拒绝异常膨胀的帧

---

## [0.0.3] - 2026-09-14

### Added
- `ogg.mbt` 页级 CRC 校验与 Ogg 物理层完成
- `vorbis.mbt` Header 全字段校验，码书维度/条目数合法性检查

## [0.0.2] - 2026-09-10

### Added
- `flac.mbt` STREAMINFO + 固定子帧解码通过 1kHz/440Hz fixture 往返校验
- `id3.mbt` v2.3 TIT1/TIT2/TPE1/APIC 基础支持

## [0.0.1] - 2026-09-05

### Added
- 项目骨架：`moon.mod` + `CONTRACT.md` + 公共类型层
- `wav.mbt` 首个可工作版本，`demo.wav` 可成功解析
