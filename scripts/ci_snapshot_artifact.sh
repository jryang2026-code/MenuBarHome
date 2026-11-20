#!/usr/bin/env bash
# Check a downloaded snapshot artifact, then copy it into the baseline directory.
#
#   ci_snapshot_artifact.sh extract-zip ARCHIVE_ZIP OUT_DIR
#   ci_snapshot_artifact.sh validate DIR
#   ci_snapshot_artifact.sh install [--tests-source FILE] ARTIFACT_DIR DEST_DIR
#
# Limits:
#   - Archive size before unpacking: <= 64 MiB
#   - File count: 1..500 PNGs (current baseline suite has ~210 PNGs)
#   - Single file size: 64 B..8 MiB
#   - Total uncompressed PNG size: <= 64 MiB
#   - Image dimensions: 1..4096 px per side, <= 16,777,216 pixels
#
# Every entry must be a regular PNG directly in the directory that passes full
# chunk CRC-32, IHDR, IDAT zlib decompression, scanline filter, and IEND checks.
#
# install validates the artifact, rejects symlinked destination paths, and verifies
# completeness before writing or deleting anything in DEST_DIR: every existing
# baseline PNG in DEST_DIR must appear in the artifact unless its snapshot test
# function has been removed from SnapshotTests.swift.
set -euo pipefail

MIN_BYTES=64
MAX_BYTES=8388608
MAX_FILE_COUNT=500
MAX_TOTAL_BYTES=67108864
MAX_ARCHIVE_BYTES=67108864
MAX_DIMENSION=4096
MAX_PIXELS=16777216

find_python() {
    local cand
    for cand in python3 python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 python; do
        if command -v "$cand" >/dev/null 2>&1; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    echo "❌ 缺少 python3" >&2
    return 1
}

extract_zip() {
    local archive="$1"
    local out_dir="$2"
    local python_bin
    python_bin="$(find_python)"
    "$python_bin" -I - "$archive" "$out_dir" \
        "$MIN_BYTES" "$MAX_BYTES" "$MAX_FILE_COUNT" "$MAX_TOTAL_BYTES" "$MAX_ARCHIVE_BYTES" <<'PY'
import os
import re
import stat
import sys
import zipfile
import zlib

archive, out_dir = sys.argv[1], sys.argv[2]
min_bytes = int(sys.argv[3])
max_bytes = int(sys.argv[4])
max_files = int(sys.argv[5])
max_total = int(sys.argv[6])
max_archive = int(sys.argv[7])

name_re = re.compile(r"^[A-Za-z0-9._-]+\.png$")

def fail(msg: str) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    sys.exit(1)

if os.path.islink(archive) or not os.path.isfile(archive):
    fail(f"快照归档不存在或不是普通文件：{archive}")

archive_size = os.path.getsize(archive)
if archive_size <= 0 or archive_size > max_archive:
    fail(f"快照归档大小超限（{archive_size} 字节，上限 {max_archive} 字节）：{archive}")

if os.path.islink(out_dir):
    fail(f"解包目标目录不能是符号链接：{out_dir}")
os.makedirs(out_dir, exist_ok=True)
if any(os.scandir(out_dir)):
    fail(f"解包目标目录必须为空：{out_dir}")

try:
    zf = zipfile.ZipFile(archive, "r")
except (zipfile.BadZipFile, OSError) as exc:
    fail(f"快照归档不是有效的 ZIP：{exc}")

with zf:
    infos = zf.infolist()
    if not infos:
        fail("快照归档是空的")
    if len(infos) > max_files:
        fail(f"快照归档文件数超限（{len(infos)} > {max_files}）")

    seen: set[str] = set()
    declared_total = 0
    for info in infos:
        fname = info.filename
        if info.is_dir() or "/" in fname or "\\" in fname or ".." in fname:
            fail(f"快照归档包含非法路径或子目录：{fname}")
        if not name_re.fullmatch(fname):
            fail(f"快照归档只能包含顶层 .png 文件：{fname}")
        if fname in seen:
            fail(f"快照归档包含重复文件名：{fname}")
        seen.add(fname)
        if info.flag_bits & 0x1:
            fail(f"快照归档包含加密条目：{fname}")
        unix_mode = (info.external_attr >> 16) & 0xFFFF
        if stat.S_ISLNK(unix_mode):
            fail(f"快照归档包含符号链接：{fname}")
        if (unix_mode & 0o170000) != 0 and not stat.S_ISREG(unix_mode):
            fail(f"快照归档包含非普通文件：{fname}")
        if info.file_size < min_bytes or info.file_size > max_bytes:
            fail(f"快照归档声明的文件大小不合理（{info.file_size} 字节）：{fname}")
        declared_total += info.file_size
        if declared_total > max_total:
            fail(f"快照归档声明的总大小超限（>{max_total} 字节）")

    actual_total = 0
    try:
        for info in infos:
            dst = os.path.join(out_dir, info.filename)
            entry_bytes = 0
            with zf.open(info, "r") as src, open(dst, "xb") as out:
                while True:
                    chunk = src.read(65536)
                    if not chunk:
                        break
                    entry_bytes += len(chunk)
                    actual_total += len(chunk)
                    if entry_bytes > max_bytes:
                        fail(f"快照文件解压后超过单文件上限（>{max_bytes} 字节）：{info.filename}")
                    if actual_total > max_total:
                        fail(f"快照产物解压后总大小超限（>{max_total} 字节）")
                    out.write(chunk)
            if entry_bytes < min_bytes:
                fail(f"快照文件解压后过小（{entry_bytes} 字节）：{info.filename}")
    except (zipfile.BadZipFile, zlib.error, RuntimeError, OSError) as exc:
        fail(f"快照归档解压失败：{exc}")

print(f"已安全解包 {len(infos)} 张 PNG（归档 {archive_size} 字节，解包 {actual_total} 字节）")
PY
}

validate_dir() {
    local dir="$1"
    local python_bin
    python_bin="$(find_python)"
    "$python_bin" -I - "$dir" \
        "$MIN_BYTES" "$MAX_BYTES" "$MAX_FILE_COUNT" "$MAX_TOTAL_BYTES" "$MAX_DIMENSION" "$MAX_PIXELS" <<'PY'
import os
import re
import struct
import sys
import zlib

target_dir = sys.argv[1]
min_bytes = int(sys.argv[2])
max_bytes = int(sys.argv[3])
max_files = int(sys.argv[4])
max_total = int(sys.argv[5])
max_dim = int(sys.argv[6])
max_pixels = int(sys.argv[7])

PNG_SIG = b"\x89PNG\r\n\x1a\n"
NAME_RE = re.compile(r"^[A-Za-z0-9._-]+\.png$")
CHUNK_TYPE_RE = re.compile(rb"^[A-Za-z]{4}$")
COLOR_SPECS = {
    0: ((1, 2, 4, 8, 16), 1),
    2: ((8, 16), 3),
    3: ((1, 2, 4, 8), 1),
    4: ((8, 16), 2),
    6: ((8, 16), 4),
}
ADAM7_PASSES = (
    (0, 0, 8, 8),
    (4, 0, 8, 8),
    (0, 4, 4, 8),
    (2, 0, 4, 4),
    (0, 2, 2, 4),
    (1, 0, 2, 2),
    (0, 1, 1, 2),
)

def fail(msg: str) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    sys.exit(1)

def decode_and_verify_png(path: str, base: str) -> None:
    try:
        with open(path, "rb") as fh:
            blob = fh.read(max_bytes + 1)
    except OSError as exc:
        fail(f"无法读取快照产物 {base}：{exc}")

    size = len(blob)
    if size < min_bytes or size > max_bytes:
        fail(f"快照产物大小不合理（{size} 字节）：{base}")
    if blob[:8] != PNG_SIG:
        fail(f"快照产物不是 PNG：{base}")

    pos = 8
    ihdr = None
    has_plte = False
    idat_parts: list[bytes] = []
    seen_idat = False
    idat_closed = False
    seen_iend = False

    while pos < size:
        if seen_iend:
            fail(f"PNG 在 IEND 后存在多余数据：{base}")
        if pos + 12 > size:
            fail(f"PNG 块头截断：{base}")
        length = struct.unpack(">I", blob[pos : pos + 4])[0]
        if length > 0x7FFFFFFF or pos + 12 + length > size:
            fail(f"PNG 块长度越界：{base}")
        ctype = blob[pos + 4 : pos + 8]
        if not CHUNK_TYPE_RE.fullmatch(ctype):
            fail(f"PNG 块类型非法：{base}")
        data_start = pos + 8
        data_end = data_start + length
        data = blob[data_start:data_end]
        expected_crc = struct.unpack(">I", blob[data_end : data_end + 4])[0]
        actual_crc = zlib.crc32(ctype)
        actual_crc = zlib.crc32(data, actual_crc) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            fail(f"PNG 块 {ctype.decode('ascii')} CRC 校验失败：{base}")
        pos = data_end + 4

        if ihdr is None:
            if ctype != b"IHDR" or length != 13:
                fail(f"PNG 首块不是有效的 IHDR：{base}")
            width, height, bit_depth, color_type, comp, flt, interlace = struct.unpack(">IIBBBBB", data)
            if width < 1 or height < 1 or width > max_dim or height > max_dim:
                fail(f"PNG 尺寸超出上限（{width}x{height}，单边上限 {max_dim}）：{base}")
            if width * height > max_pixels:
                fail(f"PNG 总像素数超出上限（{width}x{height} > {max_pixels}）：{base}")
            if comp != 0 or flt != 0 or interlace not in (0, 1):
                fail(f"PNG IHDR 编码参数非法：{base}")
            spec = COLOR_SPECS.get(color_type)
            if spec is None or bit_depth not in spec[0]:
                fail(f"PNG 颜色类型/位深组合非法（color={color_type}, depth={bit_depth}）：{base}")
            ihdr = (width, height, bit_depth, color_type, spec[1], interlace)
            continue

        if ctype == b"IHDR":
            fail(f"PNG 存在重复 IHDR：{base}")
        if ctype == b"PLTE":
            if seen_idat or length == 0 or length % 3 != 0 or length > 256 * 3:
                fail(f"PNG PLTE 块非法：{base}")
            has_plte = True
        if ctype == b"IDAT":
            if idat_closed:
                fail(f"PNG IDAT 块不连续：{base}")
            seen_idat = True
            idat_parts.append(data)
        else:
            if seen_idat:
                idat_closed = True
            if ctype == b"IEND":
                if length != 0:
                    fail(f"PNG IEND 块长度必须为 0：{base}")
                seen_iend = True

    if ihdr is None or not seen_iend:
        fail(f"PNG 缺少 IHDR 或 IEND：{base}")
    if not idat_parts:
        fail(f"PNG 缺少 IDAT 图像数据：{base}")

    width, height, bit_depth, color_type, channels, interlace = ihdr
    if color_type == 3 and not has_plte:
        fail(f"索引色 PNG 缺少 PLTE 调色板：{base}")

    bpp = channels * bit_depth
    if interlace == 0:
        row_stride = 1 + (width * bpp + 7) // 8
        expected_raw_len = height * row_stride
    else:
        expected_raw_len = 0
        for x0, y0, dx, dy in ADAM7_PASSES:
            pw = (width - x0 + dx - 1) // dx if width > x0 else 0
            ph = (height - y0 + dy - 1) // dy if height > y0 else 0
            if pw > 0 and ph > 0:
                expected_raw_len += ph * (1 + (pw * bpp + 7) // 8)

    try:
        decomp = zlib.decompressobj()
        raw = decomp.decompress(b"".join(idat_parts), expected_raw_len + 1)
        if decomp.unconsumed_tail:
            fail(f"PNG IDAT 解压字节数超出 IHDR 尺寸声明：{base}")
        raw += decomp.flush()
    except zlib.error as exc:
        fail(f"PNG IDAT zlib 解码失败（{exc}）：{base}")

    if not decomp.eof:
        fail(f"PNG IDAT zlib 流不完整：{base}")
    if decomp.unused_data:
        fail(f"PNG IDAT zlib 流后存在多余数据：{base}")
    if len(raw) != expected_raw_len:
        fail(f"PNG 解码像素长度（{len(raw)}）与尺寸预期（{expected_raw_len}）不符：{base}")

    if interlace == 0:
        for offset in range(0, expected_raw_len, row_stride):
            if raw[offset] > 4:
                fail(f"PNG 扫描线滤波类型非法（{raw[offset]}）：{base}")
    else:
        offset = 0
        for x0, y0, dx, dy in ADAM7_PASSES:
            pw = (width - x0 + dx - 1) // dx if width > x0 else 0
            ph = (height - y0 + dy - 1) // dy if height > y0 else 0
            if pw == 0 or ph == 0:
                continue
            stride = 1 + (pw * bpp + 7) // 8
            for _ in range(ph):
                if raw[offset] > 4:
                    fail(f"PNG Adam7 扫描线滤波类型非法（{raw[offset]}）：{base}")
                offset += stride

if os.path.islink(target_dir) or not os.path.isdir(target_dir):
    fail(f"快照产物目录不存在：{target_dir}")

entries = sorted(os.scandir(target_dir), key=lambda e: e.name)
count = 0
total_bytes = 0
for entry in entries:
    base = entry.name
    if ".." in base or "/" in base:
        fail(f"快照产物路径不合法：{base}")
    if entry.is_symlink():
        fail(f"快照产物不能是符号链接：{base}")
    if entry.is_dir(follow_symlinks=False):
        fail(f"快照产物不能有子目录：{base}")
    if not entry.is_file(follow_symlinks=False):
        fail(f"快照产物必须是普通文件：{base}")
    if not NAME_RE.fullmatch(base):
        fail(f"快照产物必须是该目录下的 .png：{base}")
    count += 1
    if count > max_files:
        fail(f"快照产物文件数超限（>{max_files}）")
    st = entry.stat(follow_symlinks=False)
    if st.st_size < min_bytes or st.st_size > max_bytes:
        fail(f"快照产物大小不合理（{st.st_size} 字节）：{base}")
    total_bytes += st.st_size
    if total_bytes > max_total:
        fail(f"快照产物总大小超限（>{max_total} 字节）")
    decode_and_verify_png(entry.path, base)

if count == 0:
    fail("快照产物是空的")

print(f"已检查 {count} 张 PNG（总计 {total_bytes} 字节）")
PY
}

reject_destination_symlinks() {
    local dest="$1"
    local cur next rel part entry
    # Check each ancestor of the destination path (including itself), and then
    # the entries inside it. $dest points into a checkout of the target branch,
    # so any of these can be a symlink planted by that branch.
    if [[ "$dest" == /* ]]; then
        cur="/"
    else
        cur="."
    fi
    rel="${dest#/}"
    rel="${rel%/}"
    while IFS= read -r part; do
        [ -n "$part" ] || continue
        if [ "$cur" = "/" ]; then
            next="/$part"
        elif [ "$cur" = "." ]; then
            next="$part"
        else
            next="$cur/$part"
        fi
        if [ -L "$next" ]; then
            echo "❌ 目标路径上有符号链接，拒绝安装：$next" >&2
            return 1
        fi
        cur="$next"
    done < <(printf '%s\n' "$rel" | tr '/' '\n')
    if [ -d "$dest" ]; then
        while IFS= read -r -d '' entry; do
            if [ -L "$entry" ]; then
                echo "❌ 目标目录里已有符号链接，拒绝安装：$(basename "$entry")" >&2
                return 1
            fi
        done < <(find "$dest" -mindepth 1 -maxdepth 1 -print0)
    fi
}

check_completeness() {
    local artifact="$1"
    local dest="$2"
    local tests_source="$3"
    local python_bin
    python_bin="$(find_python)"
    "$python_bin" -I - "$artifact" "$dest" "$tests_source" <<'PY'
import os
import re
import sys

artifact_dir, dest_dir, explicit_tests = sys.argv[1], sys.argv[2], sys.argv[3]

def fail(msg: str) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    sys.exit(1)

if not os.path.isdir(dest_dir):
    sys.exit(0)

artifact_pngs = {
    e.name for e in os.scandir(artifact_dir)
    if e.is_file(follow_symlinks=False) and e.name.endswith(".png")
}
existing_pngs = sorted(
    e.name for e in os.scandir(dest_dir)
    if e.is_file(follow_symlinks=False) and e.name.endswith(".png")
)
missing = [name for name in existing_pngs if name not in artifact_pngs]
if not missing:
    sys.exit(0)

tests_path = explicit_tests
if tests_path:
    if os.path.islink(tests_path) or not os.path.isfile(tests_path):
        fail(f"指定的快照测试文件无效或为符号链接：{tests_path}")
else:
    candidate = os.path.normpath(os.path.join(dest_dir, "..", "..", "SnapshotTests.swift"))
    if os.path.isfile(candidate) and not os.path.islink(candidate):
        tests_path = candidate

if not tests_path:
    sample = ", ".join(missing[:5])
    fail(
        f"快照产物不完整：缺少 {len(missing)} 张现有基线（{sample}），"
        "未提供对应快照测试源码核验，拒绝删除并中止安装。"
    )

with open(tests_path, encoding="utf-8") as fh:
    src = fh.read()

funcs = set(
    re.findall(
        r"(?m)^\s*(?:(?:private|fileprivate|internal|public)\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(",
        src,
    )
)

still_active = []
for name in missing:
    stem = name[:-4].split(".", 1)[0]
    base_func = stem.split("-", 1)[0]
    if base_func in funcs:
        still_active.append(name)

if still_active:
    sample = ", ".join(still_active[:5])
    fail(
        f"快照产物不完整：缺少 {len(still_active)} 张仍在测试中的现有基线（{sample}），"
        "拒绝删除并中止安装。"
    )
PY
}

install_dir() {
    local tests_source=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --tests-source)
                [ "$#" -ge 2 ] || { echo "❌ --tests-source 需要参数" >&2; exit 2; }
                tests_source="$2"
                shift 2
                ;;
            -*)
                echo "❌ 未知参数：$1" >&2
                exit 2
                ;;
            *)
                break
                ;;
        esac
    done
    local artifact="${1:?}"
    local dest="${2:?}"
    local name src
    # Validate everything BEFORE creating, deleting, or overwriting anything in $dest.
    validate_dir "$artifact"
    reject_destination_symlinks "$dest"
    check_completeness "$artifact" "$dest" "$tests_source"
    mkdir -p "$dest"
    if [ -d "$dest" ]; then
        while IFS= read -r -d '' src; do
            name="$(basename "$src")"
            if [ ! -f "$artifact/$name" ]; then
                rm -f -- "$src"
            fi
        done < <(find "$dest" -mindepth 1 -maxdepth 1 -name '*.png' -print0)
    fi
    while IFS= read -r -d '' src; do
        name="$(basename "$src")"
        cp -- "$src" "$dest/$name"
    done < <(find "$artifact" -mindepth 1 -maxdepth 1 -type f -name '*.png' -print0)
}

case "${1:-}" in
    extract-zip)
        extract_zip "${2:?}" "${3:?}"
        ;;
    validate)
        validate_dir "${2:?}"
        ;;
    install)
        shift
        install_dir "$@"
        ;;
    -h|--help)
        awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
        ;;
    *)
        echo "❌ 用法：ci_snapshot_artifact.sh extract-zip ZIP OUT_DIR | validate DIR | install [--tests-source FILE] ARTIFACT_DIR DEST_DIR" >&2
        exit 2
        ;;
esac
