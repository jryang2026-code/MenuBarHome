#!/usr/bin/env bash
# Stages the two Windows camera helpers that ship inside the installer:
#   go2rtc.exe        MIT, built from the pinned source with the shared patch
#   ffmpeg-silent.exe minimal LGPL build produced by build-ffmpeg-min.sh
#
# The runtime still downloads go2rtc when this staging step was skipped (for
# example a local `tauri build`), but a shipped installer must include both so
# a fresh offline-ish Windows machine never needs GitHub release assets (#200).
set -euo pipefail

go2rtc_version="1.9.15"
go2rtc_commit="7c05066c90ab6ad1fccb506d5f0408aa31ebe60f"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
out_dir="${1:-${repo_root}/windows/src-tauri/camera-bin}"

mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"
if command -v sha256sum >/dev/null 2>&1; then
  sha256=(sha256sum)
else
  sha256=(shasum -a 256)
fi

patch_file="${repo_root}/scripts/go2rtc-ptz/patches/0001-xiaomi-ptz.patch"
patch_sha="$("${sha256[@]}" "${patch_file}" | awk '{print $1}')"
if [[ ! -s "${out_dir}/go2rtc.exe" || ! -s "${out_dir}/go2rtc.exe.sha256" ||
      ! -s "${out_dir}/GO2RTC-LICENSE.txt" ||
      "$("${sha256[@]}" "${out_dir}/go2rtc.exe" | awk '{print $1}')" != "$(cat "${out_dir}/go2rtc.exe.sha256")" ||
      "$(cat "${out_dir}/go2rtc.patch.sha256" 2>/dev/null || true)" != "${patch_sha}" ||
      "${FORCE:-0}" == "1" ]]; then
  work_dir="$(mktemp -d)"
  trap 'rm -rf "${work_dir}"' EXIT
  go_bin="$(bash "${repo_root}/scripts/go2rtc-ptz/go_ready.sh")"
  git -c advice.detachedHead=false clone -c core.autocrlf=false --quiet --depth 1 --branch "v${go2rtc_version}" https://github.com/AlexxIT/go2rtc.git "${work_dir}/go2rtc"
  test "$(git -C "${work_dir}/go2rtc" rev-parse HEAD)" = "${go2rtc_commit}"
  awk '{sub(/\r$/, ""); print}' "${patch_file}" | git -C "${work_dir}/go2rtc" apply --index

  echo "▶ 构建 Windows go2rtc ${go2rtc_version}"
  (
    cd "${work_dir}/go2rtc"
    CGO_ENABLED=0 GOOS=windows GOARCH=amd64 "${go_bin}" build -trimpath -buildvcs=false -ldflags "-s -w" -o "${work_dir}/go2rtc.exe" .
  )
  "${sha256[@]}" "${work_dir}/go2rtc.exe" | awk '{print $1}' > "${work_dir}/go2rtc.exe.sha256"
  cp "${work_dir}/go2rtc.exe" "${work_dir}/go2rtc.exe.sha256" "${out_dir}/"
  cp "${work_dir}/go2rtc/LICENSE" "${out_dir}/GO2RTC-LICENSE.txt"
  printf '%s\n' "${patch_sha}" > "${out_dir}/go2rtc.patch.sha256"
fi

if [[ "${2:-}" == "--go2rtc-only" ]]; then
  exit 0
fi
bash "${script_dir}/build-ffmpeg-min.sh" "${out_dir}"

echo "✅ Windows 摄像机组件已就绪："
ls -lh "${out_dir}/go2rtc.exe" "${out_dir}/ffmpeg-silent.exe"
