"""生成真实 Ogg/Vorbis 样本，抽出三个 header，并生成一个 MoonBit 黑盒测试（仅用于自检，不交付）。

- 用 libsndfile（soundfile）编码一个真实 Vorbis 文件（这是真正的编码器产物，不是手工构造）。
- 用独立的 Python 实现（按规范 §2.1.4 / §3.2.1 从零写的 LSB-first 位读取 + codebook 解析）
  提取期望值。
- 把三个 header 的字节以字面量数组形式写进 `vorbis_real_test.mbt`，断言与 Python 侧一致。
"""

import io
import os
import struct
import sys

import numpy as np
import soundfile as sf

DST = r"D:\moon-culculate\_vorbis_selftest"
OGG = os.path.join(DST, "sample.ogg")
RATE = 22050
DURATION = 0.15

# ---------------------------------------------------------------------------
# 1. 编码一个真实的 Vorbis 文件
# ---------------------------------------------------------------------------
t = np.arange(int(RATE * DURATION)) / RATE
sig = 0.3 * np.sin(2 * np.pi * 440.0 * t)
sf.write(OGG, sig.astype(np.float32), RATE, format="OGG", subtype="VORBIS")
data = open(OGG, "rb").read()
ref, ref_rate = sf.read(OGG, dtype="float32", always_2d=True)
print(f"encoded {OGG}: {len(data)} bytes, ref samples={ref.shape}, rate={ref_rate}")


# ---------------------------------------------------------------------------
# 2. 最小 Ogg 解包（只取包，不校验 CRC）
# ---------------------------------------------------------------------------
def ogg_packets(blob):
    pos = 0
    packets = {}
    partial = {}
    while pos + 27 <= len(blob):
        assert blob[pos : pos + 4] == b"OggS", f"bad capture pattern at {pos}"
        nsegs = blob[pos + 26]
        lacing = blob[pos + 27 : pos + 27 + nsegs]
        body_start = pos + 27 + nsegs
        body_len = sum(lacing)
        body = blob[body_start : body_start + body_len]
        serial = struct.unpack_from("<I", blob, pos + 14)[0]
        partial.setdefault(serial, bytearray())
        packets.setdefault(serial, [])
        off = 0
        for seg in lacing:
            partial[serial] += body[off : off + seg]
            off += seg
            if seg < 255:
                packets[serial].append(bytes(partial[serial]))
                partial[serial] = bytearray()
        pos = body_start + body_len
    return packets


all_packets = ogg_packets(data)
serial = max(all_packets, key=lambda s: len(all_packets[s]))
packets = all_packets[serial]
print(f"serial={serial}, packets={len(packets)}")
ident, comment, setup = packets[0], packets[1], packets[2]
audio = packets[3:]
assert ident[:7] == b"\x01vorbis", ident[:8]
assert comment[:7] == b"\x03vorbis", comment[:8]
assert setup[:7] == b"\x05vorbis", setup[:8]
print(f"ident={len(ident)}B comment={len(comment)}B setup={len(setup)}B audio_packets={len(audio)}")
print("ident hex:", ident.hex())
print("comment hex:", comment.hex())


# ---------------------------------------------------------------------------
# 3. 独立的 Python 侧解析（按规范从零实现）
# ---------------------------------------------------------------------------
class Bits:
    """LSB-first 位读取器（规范 §2.1.4）。"""

    def __init__(self, buf):
        self.buf = buf
        self.pos = 0

    def read(self, n):
        v = 0
        for i in range(n):
            byte = self.buf[self.pos >> 3]
            bit = (byte >> (self.pos & 7)) & 1
            v |= bit << i
            self.pos += 1
        return v


def ilog(x):
    n = 0
    while x > 0:
        n += 1
        x >>= 1
    return n


def parse_ident(b):
    br = Bits(b)
    br.read(56)
    version = br.read(32)
    channels = br.read(8)
    rate = br.read(32)
    bmax = br.read(32)
    bnom = br.read(32)
    bmin = br.read(32)
    bs0 = 1 << br.read(4)
    bs1 = 1 << br.read(4)
    framing = br.read(1)
    return dict(
        version=version,
        channels=channels,
        rate=rate,
        bmax=bmax,
        bnom=bnom,
        bmin=bmin,
        bs0=bs0,
        bs1=bs1,
        framing=framing,
    )


def parse_comment(b):
    br = Bits(b)
    br.read(56)
    vl = br.read(32)
    vendor = b[11 : 11 + vl].decode("utf-8")
    br.read(vl * 8)
    count = br.read(32)
    out = []
    for _ in range(count):
        ln = br.read(32)
        raw = b[br.pos >> 3 : (br.pos >> 3) + ln]
        br.read(ln * 8)
        if b"=" in raw:
            k, v = raw.split(b"=", 1)
            out.append((k.decode("utf-8"), v.decode("utf-8")))
        else:
            out.append((raw.decode("utf-8"), ""))
    return vendor, out


def parse_codebooks(b):
    """只解析 codebook 段的字段（sync/dimensions/entries/ordered/lengths/lookup_type）。"""
    br = Bits(b)
    br.read(56)
    count = br.read(8) + 1
    books = []
    for _ in range(count):
        sync = br.read(24)
        assert sync == 0x564342, hex(sync)
        dim = br.read(16)
        entries = br.read(24)
        ordered = br.read(1)
        lengths = [0] * entries
        sparse = 0
        if ordered:
            cur = 0
            clen = br.read(5) + 1
            while cur < entries:
                num = br.read(ilog(entries - cur))
                for i in range(num):
                    lengths[cur + i] = clen
                cur += num
                clen += 1
        else:
            sparse = br.read(1)
            for i in range(entries):
                if sparse:
                    if br.read(1):
                        lengths[i] = br.read(5) + 1
                else:
                    lengths[i] = br.read(5) + 1
        lookup = br.read(4)
        if lookup:
            br.read(32)
            br.read(32)
            value_bits = br.read(4) + 1
            br.read(1)
            if lookup == 1:
                r = 1
                while (r + 1) ** dim <= entries:
                    r += 1
                nvals = r
            else:
                nvals = entries * dim
            br.read(nvals * value_bits)
        books.append(
            dict(
                dimensions=dim,
                entries=entries,
                ordered=ordered,
                sparse=sparse,
                lengths=lengths,
                lookup_type=lookup,
                bits_after=br.pos,
            )
        )
    return count, books, br.pos


info = parse_ident(ident)
vendor, comments = parse_comment(comment)
nbooks, books, codebook_bits = parse_codebooks(setup)
print("ident ->", info)
print("vendor ->", repr(vendor), "comments ->", comments)
print(f"codebooks: {nbooks}, bits used={codebook_bits} ({codebook_bits / 8:.1f} bytes of {len(setup)})")
for i, bk in enumerate(books):
    used = sum(1 for L in bk["lengths"] if L)
    print(
        f"  book{i}: dim={bk['dimensions']} entries={bk['entries']} ordered={bk['ordered']} "
        f"sparse={bk['sparse']} lookup={bk['lookup_type']} used={used} lensum={sum(bk['lengths'])}"
    )

with open(os.path.join(DST, "real_info.txt"), "w", encoding="utf-8") as fh:
    fh.write(repr(dict(info=info, vendor=vendor, comments=comments)))
    fh.write("\n")
    for i, bk in enumerate(books):
        fh.write(repr((i, bk)) + "\n")


# ---------------------------------------------------------------------------
# 4. 生成 MoonBit 自检测试
# ---------------------------------------------------------------------------
def mb_bytes(name, b):
    lines = [f"fn {name}() -> Bytes {{", "  Bytes::from_array(["]
    for i in range(0, len(b), 12):
        chunk = ", ".join(f"b'\\x{x:02X}'" for x in b[i : i + 12])
        lines.append("    " + chunk + ",")
    lines.append("  ])")
    lines.append("}")
    return "\n".join(lines)


def mb_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


out = []
out.append("// 由 make_real.py 生成：真实 libsndfile/Vorbis 编码器产物的自检（仅本地验证，不交付）。")
out.append("")
out.append(mb_bytes("vt_real_ident", ident))
out.append("")
out.append(mb_bytes("vt_real_comment", comment))
out.append("")
out.append(mb_bytes("vt_real_setup", setup))
out.append("")
expected_comments = ", ".join(f"({mb_str(k)}, {mb_str(v)})" for k, v in comments)
out.append('test "real: identification header" {')
out.append("  let info = vt_ident(vt_real_ident())")
out.append(f"  assert_eq(info.channels, {info['channels']})")
out.append(f"  assert_eq(info.sample_rate, {info['rate']})")
out.append(f"  assert_eq(info.bitrate_max, {info['bmax']})")
out.append(f"  assert_eq(info.bitrate_nominal, {info['bnom']})")
out.append(f"  assert_eq(info.bitrate_min, {info['bmin']})")
out.append("}")
out.append("")
out.append('test "real: comment header" {')
out.append("  let (vendor, comments) = vt_comment(vt_real_comment())")
out.append(f"  assert_eq(vendor, {mb_str(vendor)})")
out.append(f"  assert_eq(comments, [{expected_comments}])")
out.append("}")
out.append("")
out.append('test "real: codebook 段" {')
out.append("  let books = vt_books(vt_real_setup())")
out.append(f"  assert_eq(books.length(), {nbooks})")
for i, bk in enumerate(books):
    out.append(f"  // book{i}")
    out.append(f"  assert_eq(books[{i}].dimensions, {bk['dimensions']})")
    out.append(f"  assert_eq(books[{i}].entries, {bk['entries']})")
    out.append(f"  assert_eq(books[{i}].ordered, {bool(bk['ordered'])})".replace("True", "true").replace("False", "false"))
    out.append(f"  assert_eq(books[{i}].lookup_type, {bk['lookup_type']})")
    out.append(f"  assert_eq(sum_len(books[{i}].lengths), {sum(bk['lengths'])})")
    out.append(f"  assert_eq(count_used(books[{i}].lengths), {sum(1 for L in bk['lengths'] if L)})")
out.append("}")
out.append("")
out.append('test "real: 整个 setup header 校验通过" {')
out.append("  let msg = vt_unsupported_message(() => {")
out.append("    ignore(decode_vorbis(vt_info_for_real(), vt_real_setup(), []))")
out.append("  })")
out.append('  assert_true(msg.contains("尚未实现"))')
out.append(f'  assert_true(msg.contains("{nbooks} codebook"))')
out.append("}")
out.append("")
out.append("fn sum_len(a : Array[Int]) -> Int {")
out.append("  let mut s = 0")
out.append("  for v in a { s = s + v }")
out.append("  s")
out.append("}")
out.append("")
out.append("fn count_used(a : Array[Int]) -> Int {")
out.append("  let mut s = 0")
out.append("  for v in a { if v > 0 { s = s + 1 } }")
out.append("  s")
out.append("}")
out.append("")
out.append("fn vt_info_for_real() -> VorbisInfo {")
out.append("  {")
out.append(f"    channels: {info['channels']},")
out.append(f"    sample_rate: {info['rate']},")
out.append("    bitrate_max: 0,")
out.append("    bitrate_nominal: 0,")
out.append("    bitrate_min: 0,")
out.append("    comments: [],")
out.append("  }")
out.append("}")
out.append("")

with open(os.path.join(DST, "vorbis_real_test.mbt"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(out))
print("wrote vorbis_real_test.mbt")
