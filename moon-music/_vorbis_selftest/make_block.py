"""把真实编码器产物（libsndfile/libvorbis）的回归测试块生成出来，追加到交付的 vorbis_test.mbt。

只在自检流程里运行；生成的内容会插到 `// 6. 真实编码器产物` 一节。
"""

import os

DST = r"D:\moon-culculate\_vorbis_selftest"
TARGET = r"D:\moon-culculate\moonaudio\vorbis_test.mbt"
sys_path = os.path.join(DST, "libs")
import sys

sys.path.insert(0, sys_path)

# 复用 make_real.py 里的解析逻辑：直接 exec 它产出的中间信息
ns = {}
src = open(os.path.join(DST, "make_real.py"), encoding="utf-8").read()
src = src.split("# 4. 生成 MoonBit 自检测试")[0]
exec(compile(src, "make_real.py", "exec"), ns)

ident, comment, setup = ns["ident"], ns["comment"], ns["setup"]
info, vendor, comments = ns["info"], ns["vendor"], ns["comments"]
books, nbooks = ns["books"], ns["nbooks"]

total_len = sum(sum(bk["lengths"]) for bk in books)
total_used = sum(sum(1 for L in bk["lengths"] if L) for bk in books)


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
out.append("")
out.append("// ---------------------------------------------------------------------------")
out.append("// 6. 真实编码器产物的回归测试")
out.append("// ---------------------------------------------------------------------------")
out.append("//")
out.append("// 数据来源：libsndfile 0.14.0（内含 Xiph.Org libVorbis I 20200704）把")
out.append("// 22050 Hz 单声道 0.15 秒 440 Hz 正弦编码成 Ogg/Vorbis，再用最小 Ogg 解包脚本")
out.append("// 原样抽出三个 header packet（下列字节字面量未做任何改动）。")
out.append("//")
out.append("// 期望值来源：同一份规范**另写一遍的独立 Python 实现**。关键值都能人工从字节里读出：")
out.append("//   ident：channels=1（字节 11）、sample_rate=22050=0x5622（字节 12..15 小端）、")
out.append("//          bitrate_nominal=45111=0xB037（字节 20..23 小端）、")
out.append("//          blocksize 字节 0xA9 → bs0 指数 9（512）、bs1 指数 10（1024）")
out.append("//   comment：vendor 字符串在字节里是明文，1 条 comment \"ENCODER=libsndfile\"")
out.append(f"//   setup：codebook 数量 = 第 8 个字节 0x{setup[7]:02X} + 1 = {nbooks}；")
out.append("//          下面按 codebook 逐个核对 dimensions/entries/ordered/lookup_type 与长度表统计")
out.append("//")
out.append("// 这一组用例覆盖了合成用例覆盖不到的东西：真实 libvorbis 产出的 35 个 codebook")
out.append("// （含 sparse 表与 lookup type 1 的 VQ 表）、真实的 floor/residue/mapping/mode 组合。")
out.append("")
out.append(mb_bytes("vt_real_ident", ident))
out.append("")
out.append(mb_bytes("vt_real_comment", comment))
out.append("")
out.append(mb_bytes("vt_real_setup", setup))
out.append("")
out.append("///| 长度表求和（用于压缩地核对整张表）。")
out.append("fn vt_length_sum(values : Array[Int]) -> Int {")
out.append("  let mut total = 0")
out.append("  for v in values {")
out.append("    total = total + v")
out.append("  }")
out.append("  total")
out.append("}")
out.append("")
out.append("///| 使用中的 entry 个数。")
out.append("fn vt_used_count(values : Array[Int]) -> Int {")
out.append("  let mut total = 0")
out.append("  for v in values {")
out.append("    if v > 0 {")
out.append("      total = total + 1")
out.append("    }")
out.append("  }")
out.append("  total")
out.append("}")
out.append("")
out.append('test "real: identification header（libvorbis 编码器产物）" {')
out.append("  let info = vt_ident(vt_real_ident())")
out.append(f"  assert_eq(info.channels, {info['channels']})")
out.append(f"  assert_eq(info.sample_rate, {info['rate']})")
out.append(f"  assert_eq(info.bitrate_max, {info['bmax']})")
out.append(f"  assert_eq(info.bitrate_nominal, {info['bnom']})")
out.append(f"  assert_eq(info.bitrate_min, {info['bmin']})")
out.append("}")
out.append("")
out.append('test "real: comment header（libvorbis 编码器产物）" {')
out.append("  let (vendor, comments) = vt_comment(vt_real_comment())")
out.append(f"  assert_eq(vendor, {mb_str(vendor)})")
out.append(f"  assert_eq(comments.length(), {len(comments)})")
out.append(f"  assert_eq(comments[0], ({mb_str(comments[0][0])}, {mb_str(comments[0][1])}))")
out.append("}")
out.append("")
out.append('test "real: 35 个 codebook 的全部字段" {')
out.append("  let books = vt_books(vt_real_setup())")
out.append(f"  assert_eq(books.length(), {nbooks})")
for i, bk in enumerate(books):
    out.append(
        f"  // book{i}: dim={bk['dimensions']} entries={bk['entries']} "
        f"ordered={bk['ordered']} sparse={bk['sparse']} lookup={bk['lookup_type']}"
    )
    out.append(
        f"  assert_eq(books[{i}].dimensions, {bk['dimensions']}); "
        f"assert_eq(books[{i}].entries, {bk['entries']}); "
        f"assert_eq(books[{i}].lookup_type, {bk['lookup_type']})"
        if False
        else f"  assert_eq(books[{i}].dimensions, {bk['dimensions']})"
    )
    out.append(f"  assert_eq(books[{i}].entries, {bk['entries']})")
    out.append(f"  assert_eq(books[{i}].ordered, {'true' if bk['ordered'] else 'false'})")
    out.append(f"  assert_eq(books[{i}].sparse, {'true' if bk['sparse'] else 'false'})")
    out.append(f"  assert_eq(books[{i}].lookup_type, {bk['lookup_type']})")
    out.append(f"  assert_eq(vt_length_sum(books[{i}].lengths), {sum(bk['lengths'])})")
    out.append(
        f"  assert_eq(vt_used_count(books[{i}].lengths), {sum(1 for L in bk['lengths'] if L)})"
    )
out.append("  // 全部长度表的合计")
out.append(f"  let mut total_len = 0")
out.append(f"  let mut total_used = 0")
out.append("  for b in books {")
out.append("    total_len = total_len + vt_length_sum(b.lengths)")
out.append("    total_used = total_used + vt_used_count(b.lengths)")
out.append("  }")
out.append(f"  assert_eq(total_len, {total_len})")
out.append(f"  assert_eq(total_used, {total_used})")
out.append("}")
out.append("")
out.append('test "real: 整个 setup header（floor/residue/mapping/mode）校验通过" {')
out.append("  let msg = vt_unsupported_message(() => {")
out.append("    ignore(decode_vorbis(vt_info(), vt_real_setup(), []))")
out.append("  })")
out.append('  assert_true(msg.contains("尚未实现"))')
out.append(f'  assert_true(msg.contains("{nbooks} codebook"))')
out.append("}")
out.append("")

block = "\n".join(out) + "\n"
with open(os.path.join(DST, "real_block.txt"), "w", encoding="utf-8") as fh:
    fh.write(block)

with open(TARGET, "a", encoding="utf-8") as fh:
    fh.write(block)
print(f"appended {len(block)} chars to {TARGET}")
print(f"nbooks={nbooks} total_len={total_len} total_used={total_used}")
