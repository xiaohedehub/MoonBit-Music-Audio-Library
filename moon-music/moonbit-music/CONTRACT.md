# moonbit-music 接口契约 v1（冻结）

本文件是**唯一权威接口定义**。所有并行开发都必须严格遵守此处的签名与类型名。

## 硬规则

1. **单包结构**。整个库是 module 根部的**一个** MoonBit 包。子代理之间**不得**互相 import，
   也不得假设别的文件存在——只允许依赖 `moonbitlang/core`。
2. **文件所有权**。每个文件只能由被指派的那个代理改写。共用文件（`types.mbt`、`errors.mbt`）
   已冻结，任何人不得修改。
3. **类型名与签名一字不改**。签名对不上 = 集成失败。
4. **所有解码器零 FFI、零外部依赖、不假设目标后端**（native / js / wasm / wasm-gc 都要能编）。
5. 每个实现文件配一个同名的 `*_test.mbt`（黑盒测试，`test "..." { }` 块）。

## 已冻结的共用类型（`types.mbt` / `errors.mbt`，任何人都不要改）

```moonbit
pub suberror AudioError {
  Io(String)
  InvalidMagic(String)
  Unsupported(String)
  Truncated(offset~ : Int, needed~ : Int, available~ : Int)
  ChecksumMismatch(expected~ : Int, actual~ : Int)
  LimitExceeded(String)
} derive(@debug.Debug)

pub(all) struct PcmBuffer {
  mut samples : Array[Int]
  sample_rate : Int
  channels : Int
}
pub fn PcmBuffer::new(sample_rate : Int, channels : Int) -> PcmBuffer
pub fn PcmBuffer::push(Self, Int) -> Unit
pub fn PcmBuffer::extend(Self, ArrayView[Int]) -> Unit
pub fn PcmBuffer::frame_count(Self) -> Int
pub fn PcmBuffer::to_bytes_le(Self, bits : Int) -> Bytes
pub fn PcmBuffer::empty() -> PcmBuffer

pub(all) struct AudioFormat {
  sample_rate : Int
  channels : Int
  bits_per_sample : Int
} derive(Eq, @debug.Debug)

pub(all) struct Audio {
  format : AudioFormat
  samples : Array[Int]
  tags : Array[(String, String)]
} derive(@debug.Debug)
pub fn Audio::duration_seconds(Self) -> Double
pub fn Audio::frame_count(Self) -> Int

pub(all) enum AudioFormatHint {
  Wav
  Flac
  Ogg
  Mp3
  Unknown
}
pub fn detect_format(Bytes) -> AudioFormatHint

pub(all) struct Decoder {
  // private fields
}
pub fn Decoder::from_wav(Bytes) -> Decoder raise AudioError
pub fn Decoder::from_flac(Bytes) -> Decoder raise AudioError
pub fn Decoder::from_ogg(Bytes) -> Decoder raise AudioError
pub fn Decoder::from_mp3(Bytes) -> Decoder raise AudioError
pub fn Decoder::next(Self) -> PcmBuffer? raise AudioError
pub fn Decoder::format(Self) -> AudioFormat raise AudioError
```

## 各代理负责的公开接口

### D — `wav.mbt`

```moonbit
pub fn decode_wav(Bytes) -> Audio raise AudioError
pub fn wav_info(Bytes) -> AudioFormat raise AudioError
```

### E — `id3.mbt`

```moonbit
pub(all) struct Id3v2Tag {
  version : Int
  title : String?
  artist : String?
  album : String?
  year : String?
  track : String?
  genre : String?
  comment : String?
  composer : String?
  pictures : Array[Bytes]
  raw_frames : Array[(String, Bytes)]
} derive(@debug.Debug)

/// 无标签时返回 None；有标签时返回 Some。
pub fn parse_id3v2(Bytes) -> Id3v2Tag? raise AudioError
/// 跳过 ID3v2 头所需的字节数；无标签返回 0。用于 MP3 帧同步起始偏移。
pub fn id3v2_size(Bytes) -> Int
/// 同步安全整数（每字节低 7 位）。
pub fn unsync(Bytes) -> Bytes
```

### F — `flac.mbt`

```moonbit
pub(all) struct FlacStreamInfo {
  min_block_size : Int
  max_block_size : Int
  min_frame_size : Int
  max_frame_size : Int
  sample_rate : Int
  channels : Int
  bits_per_sample : Int
  total_samples : Int64
  md5 : Bytes
} derive(@debug.Debug)

pub(all) struct FlacMetadata {
  info : FlacStreamInfo
  comments : Array[(String, String)]
  seektable : Array[Int64]
  pictures : Array[Bytes]
} derive(@debug.Debug)

/// 只解析 fLaC 标记 + 全部 metadata block，不碰音频帧。
pub fn parse_flac_metadata(Bytes) -> FlacMetadata raise AudioError
/// 完整解码为交织 PCM。
pub fn decode_flac(Bytes) -> Audio raise AudioError
pub fn flac_info(Bytes) -> AudioFormat raise AudioError
/// 逐帧解码，用于流式与内存受限场景。
pub fn flac_decoder(Bytes) -> Decoder raise AudioError
```

### G — `ogg.mbt`

```moonbit
pub(all) struct OggPage {
  version : Int
  header_type : Int
  granule_position : Int64
  serial : Int
  sequence : Int
  checksum : Int
  segments : Array[Int]   // lacing values
  body : Bytes
} derive(@debug.Debug)

/// 从头解析一个 Ogg page（含 CRC 校验）。
pub fn parse_page(Bytes, offset : Int) -> (OggPage, Int) raise AudioError
/// 依次产出所有 page。
pub fn pages(Bytes) -> Array[OggPage] raise AudioError
/// 把 page 按 serial 分组，并把 lacing 拼装成完整 packet（处理续包）。
/// 每个 packet 附带是否恰好结束于 page 边界。
pub fn packets_of(pages : Array[OggPage]) -> Array[(Int, Array[Bytes])]
/// Ogg CRC32（多项式 0x04C11DB7，无反射，初值 0，不取反）。
pub fn ogg_crc32(Bytes) -> Int
```

### H — `vorbis.mbt`

```moonbit
pub(all) struct VorbisInfo {
  channels : Int
  sample_rate : Int
  bitrate_max : Int
  bitrate_nominal : Int
  bitrate_min : Int
  comments : Array[(String, String)]
} derive(@debug.Debug)

/// identification header（含 "\x01vorbis" 前缀）。
pub fn parse_vorbis_ident(Bytes) -> VorbisInfo raise AudioError
/// comment header，返回 (vendor, comments)。
pub fn parse_vorbis_comment(Bytes) -> (String, Array[(String, String)]) raise AudioError
/// 解 Vorbis I，输入为三个 header packet 之后的全部音频 packet。
pub fn decode_vorbis(
  info : VorbisInfo,
  setup : Bytes,
  audio_packets : Array[Bytes],
) -> Audio raise AudioError
```

### I — `mp3.mbt`

```moonbit
pub fn decode_mp3(Bytes) -> Audio raise AudioError
pub fn mp3_info(Bytes) -> AudioFormat raise AudioError
/// 逐帧解码（不含 ID3v2 区域）。
pub fn mp3_decoder(Bytes) -> Decoder raise AudioError
```

### J — `moonbit-music.mbt`（库入口，须最后集成）

```moonbit
/// 按魔数自动识别并解码。不是音频格式时抛 InvalidMagic。
pub fn decode(Bytes) -> Audio raise AudioError
/// 不解码，只取格式信息。
pub fn info(Bytes) -> AudioFormat raise AudioError
/// 只解析标签（WAV/FLAC 走 Vorbis comment，MP3 走 ID3v2，Ogg 走 comment header）。
pub fn tags(Bytes) -> Array[(String, String)] raise AudioError
```

## 实现要点（避免各自踩坑）

### ⚠️ 工具链实测过的 API 陷阱（2026-09 验证，务必遵守）

以下写法**已实测通过**（`moon check` + `moon test` 均通过）：

```moonbit
// ✅ Bytes 是不可变的！没有 data[i] = x
//    要构造/修改字节，走 Array[Byte] 或 Buffer：
let arr : Array[Byte] = Array::make(4, b'\x00')
arr[0] = (0x11).to_byte()            // Array[Byte] 支持下标赋值
let built = Bytes::from_array(arr)   // 转成 Bytes

// ✅ Buffer 的可用方法：
let buf = Buffer()
buf.write_byte(b'\xAA')
buf.write_bytes(built)
let out = buf.to_bytes()
// ❌ Buffer 没有 write_uint32_le / write_uint16_be 之类的方法，需要自己拼字节

// ✅ String 切片必须用具名参数（位置参数形式已废弃）：
text.substring(start=0, end=5)
text.substring(start=6)
// ❌ text.substring(0, end) —— 编译错误：requires 1 positional arguments, but given 3

// ❌ Int 没有 .reinterpret() 方法
// ❌ extend 是保留字，不能做方法名（改用 append_all 之类）

// ✅ Int codepoint -> Char -> String（实测通过）：
let a : Char = Char::from_int(65)      // Int -> Char
let c : Char = '\u{4E2D}'              // 字符字面量
let buf = Buffer()
buf.write_char(a)                      // Buffer 追加 Char
buf.write_string("BC")
let s : String = buf.to_string()
// ❌ Char::unsafe_to_char(...) 不存在
// 拼字符串优先用 Buffer 累积再 to_string()，不要 out = out + ...
```

如果遇到不确定的标准库 API，**先写一个 3 行的临时测试文件用 `moon check` 试探**，
不要凭记忆写一大段再一起调试。

### 其他实现要点

- **位数语义**：FLAC 的 UTF-8 式编码整数最多 36 bit，**必须用 `Int64`**；CRC 表用 `Int` 但要注意
  逻辑右移（`Int` 有符号，用 `(v >> 8) & 0x00FFFFFF` 掩码修正）。
- **字节序**：FLAC / WAV / MP3 是大端（WAV 内部是小端），Ogg 是小端。别搞混。
- **有符号样本**：一律解成 `Int`，范围 `[-2^(bits-1), 2^(bits-1)-1]`。WAV 8-bit 是无符号，
  要减 128 转有符号。
- **PCM 交织顺序**：按帧交织，即 `[L0, R0, L1, R1, ...]`。
- **不做**：网络 I/O、文件 I/O、线程、FFI。输入一律是内存中的 `Bytes`。

## 公共 API 的 Show 实现（已提供，直接用）

`types.mbt` 已为下列类型实现 `Show`，可直接字符串插值：
- `AudioFormatHint` → `"Wav"` / `"Flac"` / `"Ogg"` / `"Mp3"` / `"Unknown"`
- `AudioFormat` → `"44100Hz/2ch/16bit"`

**不要**对 `AudioError` 做插值（未实现 `Show`），要用 `match` 分支处理。
