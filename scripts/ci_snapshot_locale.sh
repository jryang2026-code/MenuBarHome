#!/usr/bin/env bash
# Locale shared by macOS CI and the snapshot reference runner.
#
#   bash scripts/ci_snapshot_locale.sh
#   bash scripts/ci_snapshot_locale.sh --require-xcode 26.6
#
# Temperature and measurement units follow the system locale. GitHub-hosted Macs
# default to a US locale (Fahrenheit). Tests and the UI snapshot baselines use zh_CN.
# --require-xcode is enforced on the reference renderer jobs (macos-test and record-snapshots).
set -euo pipefail

require=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --require-xcode)
            if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
                echo "❌ --require-xcode 需要版本号，例如 26.6" >&2
                exit 2
            fi
            require="$2"
            shift 2
            ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *)
            echo "❌ 未知参数：$1（可用：--require-xcode <version>）" >&2
            exit 2
            ;;
    esac
done

if [ -n "$require" ]; then
    if ! command -v xcodebuild >/dev/null 2>&1; then
        echo "❌ 快照基准要求 Xcode ${require}，当前没有 xcodebuild。更换镜像后必须重录基线。" >&2
        exit 1
    fi
    # xcodebuild -version has aborted (exit 134) on a second call in the same job.
    # Retry, and do not call it again after the version is known.
    actual=""
    attempt=1
    while [ "$attempt" -le 3 ]; do
        if actual="$(xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2; exit }')" && [ -n "$actual" ]; then
            break
        fi
        actual=""
        attempt=$((attempt + 1))
        sleep 1
    done
    if [ "$actual" != "$require" ]; then
        echo "❌ 快照基准要求 Xcode ${require}，当前是 ${actual:-未知}。更换 Xcode 或 macos-26-intel 镜像后必须重录基线。" >&2
        sw_vers >&2 || true
        exit 1
    fi
    echo "Xcode ${actual}"
    sw_vers || true
fi

defaults write -g AppleLocale zh_CN
defaults write -g AppleMetricUnits -bool true
defaults write -g AppleMeasurementUnits Centimeters
defaults write -g AppleTemperatureUnit Celsius
