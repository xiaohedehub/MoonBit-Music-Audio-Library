name = "hym0721/moonbit-music"

version = "0.1.1"

readme = "README.mbt.md"

repository = "https://github.com/xiaohedehub/MoonBit-Music-Audio-Library"

license = "MIT"

keywords = [
  "audio",
  "flac",
  "mp3",
  "vorbis",
  "ogg",
  "wav",
  "id3",
  "decoder",
  "moonbit",
  "wasm",
  "cross-platform",
  "zero-dependency",
]

preferred_target = "native"

description = "纯 MoonBit 跨平台音频解码库：WAV、FLAC 无损解码、Ogg/Vorbis 帧校验、MP3 帧结构解析、ID3v2 标签解析。零 FFI、零外部依赖，native / js / wasm / wasm-gc 四后端统一可用。"

options(
  authors: [ { "name": "hym0721", "email": "hym0721@users.noreply.github.com" } ],
)
