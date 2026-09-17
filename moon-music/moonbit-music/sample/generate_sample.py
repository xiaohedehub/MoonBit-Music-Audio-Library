#!/usr/bin/env python3
"""生成 audioinfo 演示用的示例 WAV。

产物默认写到与本脚本同目录的 ``demo.wav``：

    单声道 / 16 bit / 8000 Hz / 0.1 秒 / 440 Hz 正弦波

用法::

    D:\\Anaconda\\python.exe sample\\generate_sample.py
    D:\\Anaconda\\python.exe sample\\generate_sample.py --out D:\\tmp\\demo.wav

脚本完全确定：不使用随机数，正弦值用 ``math.sin`` 逐点计算，
因此同一台机器上重复运行会产生逐字节相同的文件。
"""

from __future__ import annotations

import argparse
import math
import os
import wave

import numpy as np

# 演示参数（固定，改动会让 README 里的输出数字失效）。
SAMPLE_RATE = 8000
DURATION_SECONDS = 0.1
FREQUENCY_HZ = 440.0
AMPLITUDE = 0.5
CHANNELS = 1
SAMPLE_WIDTH_BYTES = 2  # 16 bit
FULL_SCALE = 32767  # 16 bit 有符号上限


def frame_count() -> int:
    """总帧数。0.1 秒 @ 8000 Hz = 800 帧。"""
    return int(round(SAMPLE_RATE * DURATION_SECONDS))


def build_pcm() -> np.ndarray:
    """构造交织 PCM 数据（这里是单声道，所以就是一条样本序列）。

    用 ``math.sin`` 而不是 ``np.sin`` 是为了让结果只依赖 CPython 的
    libm，而不依赖 numpy 的 SIMD 实现。
    """
    frames = frame_count()
    samples = [
        int(round(math.sin(2.0 * math.pi * FREQUENCY_HZ * (i / SAMPLE_RATE)) * AMPLITUDE * FULL_SCALE))
        for i in range(frames)
    ]
    # 小端 16 bit 有符号。
    return np.array(samples, dtype="<i2")


def write_wav(path: str, pcm: np.ndarray) -> None:
    """写标准 RIFF/WAVE 文件（wave 模块生成规范的 44 字节头 + data 块）。"""
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(CHANNELS)
        handle.setsampwidth(SAMPLE_WIDTH_BYTES)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(pcm.tobytes())


def verify(path: str) -> None:
    """回读确认参数写对了；出错就抛，避免留下一个坏样本。"""
    with wave.open(path, "rb") as handle:
        assert handle.getnchannels() == CHANNELS, "声道数不对"
        assert handle.getsampwidth() == SAMPLE_WIDTH_BYTES, "位深不对"
        assert handle.getframerate() == SAMPLE_RATE, "采样率不对"
        assert handle.getnframes() == frame_count(), "帧数不对"


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="生成 audioinfo 演示用的示例 WAV")
    parser.add_argument(
        "--out",
        default=os.path.join(here, "demo.wav"),
        help="输出路径（默认 sample/demo.wav）",
    )
    args = parser.parse_args()

    pcm = build_pcm()
    write_wav(args.out, pcm)
    verify(args.out)

    size = os.path.getsize(args.out)
    print(f"已生成 {args.out}")
    print(f"  {CHANNELS} ch / {SAMPLE_WIDTH_BYTES * 8} bit / {SAMPLE_RATE} Hz / {FREQUENCY_HZ:g} Hz 正弦")
    print(f"  {frame_count()} 帧, {DURATION_SECONDS:g} 秒, {size} 字节")
    print(f"  试听/查看： audioinfo {os.path.relpath(args.out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
