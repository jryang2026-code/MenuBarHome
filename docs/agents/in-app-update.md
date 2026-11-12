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

- `retryInstall` — network, disk, unpack, or the swap script. Re-running the same download can work.
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
`HomeStore.updateRelaunchWatchdogInterval` (default 20 s, longer than the script's own 15 s wait for
the app to exit), then terminates. If the process is still alive after that, the update did not
land and the state becomes a retryable `.failed` instead of a permanent "正在重启…" that never moves.
A test freezes the watchdog by setting the interval to `nil`.

## The swap script

`UpdateSystemDriver.swapScript` waits for the current PID to exit, keeps the old bundle as a backup,
moves the staged bundle into place, and on failure restores the backup **and reopens the original
app** so a failed install returns the user to the version they had instead of leaving nothing
running. It is a constant string so `UpdateCheckerTests` can assert those guarantees without
executing it.

## Verification

- `swift test --filter "UpdateCheckerTests|UpdateManifestTests|UpdateProgressAndRecoveryTests"`
- `bash scripts/check.sh` — full gate, including the cross-platform public-key consistency check.
- Real release, read-only: download the published manifest and signature and run
  `swift scripts/sign_update.swift --verify <manifest> <sig>`.
