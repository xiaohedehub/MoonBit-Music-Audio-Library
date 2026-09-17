name = "hym0721/moonbit-music"

version = "0.1.0"

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
]

preferred_target = "native"

description = "纯 MoonBit 跨平台音频解码库：WAV、FLAC 无损解码、Ogg/Vorbis、MP3 帧解析、ID3v2 标签解析。零 FFI、零外部依赖，native / js / wasm / wasm-gc 四后端可用。"

options(
  authors: [ { "name": "hym0721", "email": "hym0721@users.noreply.github.com" } ],
)
