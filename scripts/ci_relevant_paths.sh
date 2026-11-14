#!/usr/bin/env bash
# Read a newline-separated path list on stdin and print which CI surfaces are affected:
#   code=true            repository-wide lint & secret scan (nas-safety)
#   macos=true           macOS Swift unit & snapshot tests
#   windows=true         Windows frontend tests & Vite build (windows-core)
#   core=true            Linux MijiaCore suite (linux-core)
#   raycast=true         Raycast extension test & typecheck
#   scripts=true         scripts/* & harness self-tests
#   macos_build=true     macOS Release universal build (macos-release)
#   appintents=true      App Intents metadata build check (macos-appintents)
#   windows_native=true  Windows camera-bin, Rust cargo test, Win32 test & Tauri installer
#   nas=true             NAS deployment safety suite
#   go2rtc=true          go2rtc PTZ patch verify.sh
# Unknown paths and empty input fall back to every surface, so a failed diff never skips CI.
set -euo pipefail

code=false
macos=false
windows=false
core=false
raycast=false
scripts=false
macos_build=false
appintents=false
windows_native=false
nas=false
go2rtc=false
saw=0

mark_all() {
    code=true
    macos=true
    windows=true
    core=true
    raycast=true
    scripts=true
    macos_build=true
    appintents=true
    windows_native=true
    nas=true
    go2rtc=true
}

while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    saw=1
    case "$path" in
        # Logo SVGs are byte-compared with the app icon in scripts/check.sh.
        docs/assets/*.svg)
            code=true
            ;;
        # Capability matrix lint validates links and counts inside READMEs and docs/capabilities.json.
        README.md|README.zh-CN.md|docs/capabilities.json)
            code=true
            ;;
        # check_model_tables.py reads the patch SHA-256 row from this README inside the lint job.
        scripts/go2rtc-ptz/README.md)
            code=true
            scripts=true
            go2rtc=true
            ;;
        *.md|docs/*|LICENSE|.github/ISSUE_TEMPLATE/*|.cursor/*|.claude/*|.agents/*)
            ;;
        # Changing the main CI workflow exercises every job on the PR.
        .github/workflows/ci.yml)
            mark_all
            ;;
        # Each of these has its own workflow or triggers only repo-level script/lint checks.
        packaging/homebrew/*|.github/workflows/homebrew-tap.yml|.github/workflows/snapshot-guard.yml)
            code=true
            scripts=true
            ;;
        # windows/tests/companionBridge.test.ts imports raycast/src/snapshot-validation.ts.
        raycast/src/snapshot-validation.ts)
            code=true
            raycast=true
            windows=true
            ;;
        raycast/*)
            code=true
            raycast=true
            ;;
        nas/*)
            code=true
            nas=true
            ;;
        # MiotFacetsTests and MiotFallbackSpecTests compare these byte for byte with the macOS copies.
        windows/src/core/miCloud/*.json)
            code=true
            windows=true
            macos=true
            core=true
            ;;
        windows/src-tauri/*|.github/workflows/camera-bin.yml)
            code=true
            windows=true
            windows_native=true
            ;;
        windows/scripts/build-installer.ps1|windows/build-win.bat)
            code=true
            windows=true
            windows_native=true
            scripts=true
            ;;
        # Inputs of the camera-bin build and its cache key: a PR that edits them must run the
        # native jobs, not only the TypeScript ones.
        windows/scripts/build-ffmpeg-min.sh|windows/scripts/prepare-camera-bin.sh|windows/scripts/patch_pe_subsystem.py)
            code=true
            windows=true
            windows_native=true
            ;;
        windows/package.json|windows/package-lock.json|windows/vite.config.*|windows/tsconfig*.json|windows/index.html)
            code=true
            windows=true
            windows_native=true
            ;;
        windows/*)
            code=true
            windows=true
            ;;
        Package.swift|Package.resolved)
            code=true
            macos=true
            core=true
            macos_build=true
            appintents=true
            ;;
        Sources/MijiaCore/CommandIntent.swift)
            code=true
            macos=true
            core=true
            appintents=true
            ;;
        Sources/MijiaCore/*)
            code=true
            macos=true
            core=true
            ;;
        Sources/MenuBarMijiaApp/AppIntents*.swift)
            code=true
            macos=true
            appintents=true
            ;;
        Sources/MenuBarMijiaApp/*)
            code=true
            macos=true
            ;;
        # Shared golden corpora pin both the Swift and TypeScript implementations.
        Tests/Fixtures/*)
            code=true
            macos=true
            windows=true
            core=true
            ;;
        Tests/MijiaCoreTests/*)
            code=true
            macos=true
            core=true
            ;;
        Tests/MenuBarMijiaAppTests/*)
            code=true
            macos=true
            ;;
        Resources/*)
            code=true
            macos=true
            macos_build=true
            ;;
        scripts/linux-check/*)
            code=true
            core=true
            scripts=true
            ;;
        scripts/ci_swift_test.sh|scripts/ci_restore_mtimes.sh)
            code=true
            macos=true
            scripts=true
            ;;
        scripts/go2rtc-ptz/*)
            code=true
            scripts=true
            go2rtc=true
            macos=true
            macos_build=true
            ;;
        scripts/build_app.sh|scripts/generate_app_icon.swift|scripts/release.sh|scripts/sign_update.swift|scripts/update_manifest.py|.github/workflows/release.yml|.github/workflows/finalize.yml)
            code=true
            scripts=true
            macos=true
            macos_build=true
            appintents=true
            ;;
        scripts/*)
            code=true
            scripts=true
            ;;
        *)
            mark_all
            ;;
    esac
done

if [ "$saw" -eq 0 ]; then
    mark_all
fi

printf 'code=%s\nmacos=%s\nwindows=%s\ncore=%s\nraycast=%s\nscripts=%s\nmacos_build=%s\nappintents=%s\nwindows_native=%s\nnas=%s\ngo2rtc=%s\n' \
    "$code" "$macos" "$windows" "$core" "$raycast" "$scripts" "$macos_build" "$appintents" "$windows_native" "$nas" "$go2rtc"
