# In-app update: what the app promises and how it is proven

Reference for `Sources/MijiaCore/Update*.swift`, `Sources/MenuBarMijiaApp/UpdateSection.swift`, and
`Tests/MijiaCoreTests/Update*.swift`. Trust-chain rationale is in
[ADR-0005](../adr/0005-update-signing-trust-chain.md); release mechanics are in
[`scripts/release.sh`](../../scripts/release.sh), `.github/workflows/release.yml` and
`.github/workflows/finalize.yml`.

## Order of operations (never reorder)

`AppUpdater.stageUpdate` runs these in sequence and stops at the first failure:

1. Download `MenuBarHome-<version>.dmg` into a `com.jryang1997.MenuBarMijia.update-*` staging root.
2. Fetch the signed manifest `MenuBarHome-<version>.update.json` and its detached
   `.update.json.ed25519.sig` from the same release.
3. `UpdateManifest.accept`: Ed25519 signature under a pinned public key, `key_id` must name that
   key, the signed version must equal the requested release, it must be newer than the running
   build, `min_from` must be satisfied, and the package's streamed SHA-256 must match.
4. Unpack (DMG attach with backoff, or `ditto` for ZIP) into the staging root.
5. Bundle identity: `CFBundleIdentifier` and `CFBundleShortVersionString` must match the signed
   manifest version.
6. `codesign --verify --strict --deep -R=<requirement>` where the requirement pins the leaf
   certificate SHA-1 from the running app's `MijiaCodeSignCertSHA1`.
7. Only then is `VerifiedStagedApp` constructed. It is the sole token `installStagedUpdateAndRelaunch`
   accepts.

Steps 3 and 6 fail closed. A missing or malformed `MijiaCodeSignCertSHA1` degrades the requirement
to `identifier "…" and never`, which rejects every package including same-ID ad-hoc builds.

## Package hashing is streamed

`UpdateManifest.accept` takes a `SHA256Digest`, not package bytes, and `stageUpdate` produces it with
`SHA256Digest.hashFile`. A release DMG is tens of megabytes; hashing must not read it into one `Data`.
The digest is the same value either way — `UpdateCheckerTests` pins `hashFile == hash(Data)`.

## Failure taxonomy (`UpdateFailureClassifier`)

Phase says where it broke; recovery says what the user can actually do about it.

- `retryInstall` — network, disk, package checksum mismatch (e.g. a truncated download), unpack, or
  the swap script. Re-running the same download can work while still enforcing full Ed25519 + SHA-256 +
  bundle metadata + codesign verification.
- `recheck` — the release metadata was wrong or stale; a fresh check is the useful next step.
- `manualDownload` — a signature, code-signature, bundle-identity, `min_from`, or target-location
  failure. Retrying the identical package cannot succeed, so the UI offers only the release page.

`AppUpdateFailure.canRetryInstall` is exactly `recovery == .retryInstall`. Do not add a retry button
that runs the same failing step again: the UI branches on `recovery`, and `startUpdateInstallation`
refuses to start from a non-retryable failure.

## Cancellation

`cancelUpdateInstallation` is ignored while `.installing`: the detached swap script already owns the
staging directory, so telling the user "cancelled" would be a lie. Every other phase cancels the
task, deletes the staging root, and returns to `.available`.

## Relaunch watchdog

`confirmRelaunchForUpdate` launches the detached swap, starts
`HomeStore.updateRelaunchWatchdogInterval` (default 30 s, longer than the script's nominal 15 s wait
for the app to exit), then terminates. While the detached swap process (`.swap.pid`) is still alive,
the watchdog defers so it never deletes staging out from under a slow swap. Once the swap process has
exited and this process is still alive, the update did not land because the app did not exit in time,
and the state becomes a retryable `.failed` instead of a permanent "正在重启…" that never moves.
A test freezes the watchdog by setting the interval to `nil`.

## The swap script

`UpdateSystemDriver.swapScript` waits for the current PID to exit, keeps the old bundle as a backup,
moves the staged bundle into place, and on failure restores the backup **and reopens the original
app** so a failed install returns the user to the version they had instead of leaving nothing
running. It is a constant string so `UpdateCheckerTests` can assert those guarantees without
executing it.

## Scheduling, launch jitter, and staged rollout (#30)

- **macOS background scheduling** (`Sources/MijiaCore/UpdateScheduler.swift`): automatic checks run
  through `NSBackgroundActivityScheduler` (`repeats = true`, `interval = 6 h`, `tolerance = 1 h`,
  `qualityOfService = .utility`, honoring `shouldDefer`) plus a 0–30 minute random post-launch
  jitter delay. Manual "check now" calls `HomeStore.checkForUpdates()` directly and is unaffected.
- **Staged rollout metadata** (`Sources/MijiaCore/UpdateRollout.swift`,
  `windows/src/core/updateChecker.ts`): the GitHub release metadata read during update checks may
  carry an optional `rollout_percentage` (0–100) either as a top-level JSON integer
  (`rollout_percentage` / `rolloutPercentage`) or as an HTML comment in the release `body`
  (`<!-- rollout_percentage: 25 -->` or `<!-- rollout: 25 -->`). Missing defaults to `100`.
  - The signed `.update.json` manifest schema is intentionally unchanged so older clients continue
    to verify releases without rejecting unknown keys.
  - Each installation generates a random local install ID once (`UserDefaults` on macOS,
    `localStorage` on Windows), never derived from hardware or account data and never sent over
    the network.
  - Automatic checks offer the update only when `SHA256("menubarhome-update-rollout-v1:<version>:<installId>")[0..<8] % 100 < rollout_percentage`.
    Manual "check now" always sees the update regardless of rollout percentage.
  - Cross-platform parity is pinned in `Tests/Fixtures/update_rollout_golden.json`.

## Verification

- `swift test --filter "UpdateCheckerTests|UpdateManifestTests|UpdateProgressAndRecoveryTests|UpdateRolloutAndSchedulerTests"`
- `bash scripts/check.sh` — full gate, including the cross-platform public-key consistency check.
- Real release, read-only: download the published manifest and signature and run
  `swift scripts/sign_update.swift --verify <manifest> <sig>`.
