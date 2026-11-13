---
paths:
  - "Sources/MijiaCore/Device*.swift"
  - "Sources/MijiaCore/*Intent*.swift"
  - "Sources/MijiaCore/Assistant*.swift"
  - "Sources/MijiaCore/UserHabitMemory.swift"
  - "Sources/MijiaCore/Model*.swift"
  - "Sources/MijiaCore/ManualControlPolicy.swift"
  - "Sources/MijiaCore/GrokBall*.swift"
  - "Sources/MijiaCore/HA*.swift"
  - "Sources/MijiaCore/FragmentedMP4Demuxer.swift"
  - "Sources/MijiaCore/Models.swift"
  - "Sources/MijiaCore/MiCloud/**/*.swift"
  - "windows/src/core/**/*.ts"
  - "windows/src/ui/cloudRefresh.ts"
  - "Tests/Fixtures/**"
  - "docs/capabilities.json"
---

# 设备合成、领域边界、跨端黄金语料与外部报文回放

## 1. Entity Registry Exclusions Block State Fallbacks

When synthesizing Home Assistant entities in `Sources/MijiaCore/DeviceSynthesizer.swift` with a primary pass over `snapshot.entityRegistry` followed by a fallback pass over `snapshot.states`:

- Record every matched registry `entity_id` into the seen set (`seen...Ids`) **before** skipping `disabled_by != nil || hidden_by != nil` entries.
- Skipping before recording leaks disabled or hidden entities back into the UI through the `states` fallback loop.

## 5. Domain Vocabulary & Single Source of Truth

- Keep `MijiaCore` free of `AppKit` / `SwiftUI` imports so all synthesis, optimistic locking, and store state remain fast-testable via `MockHomeProvider`.
- Align type and property names with [`GLOSSARY.md`](GLOSSARY.md) and [`docs/adr/0001-ha-as-single-source-of-truth.md`](docs/adr/0001-ha-as-single-source-of-truth.md).
- A climate card is a heater when its model contains `heater` or `blanket`, or its name contains 电暖, 暖气, 取暖, or 暖风. A 热水器 stays `climate` only when the model misses both. Owner: `deviceCategory.ts:isHeaterDevice`, `CommandIntent.swift:IntentDeviceCategory`. Partly pinned by `windows/tests/facetPolicy.test.ts` ("uses the four macOS heater name hints and the same model checks") for the four words and the `heater` / `blanket` model. That test never builds a 热水器.
- Switching to 自定义 must not save the previous provider's address with an empty key. Latch custom endpoint/model input disclosure on explicit picker selection (`showsCustomEndpointFields` / `showsAdvanced`) rather than gating mount conditions on a preset inferred live from the edited URL text, so typing a recognized host (`http://localhost:11434`) keeps the active field mounted. Owner: `AssistantCommandBar.swift:AssistantSettingsDraft`, `OnboardingGuideView.swift`. Pinned by `SettingsPlainLanguageTests.customPresetSwitchKeepsSavedKey`.
- Before deleting a stored `HomeStore` property, search every `extension HomeStore`, including files that are not named `HomeStore+`.
- A decision reads the value it changes, not a wrapping container. Owner: `ManualControlPolicy.facetRequiresConfirmation` (`facet.value`), `StatusItemEventDecision.decide`, `PanelKeyRouter.beforeSearch`, `PanelFoldMeasure.Reading.cardTop`. Pinned by `FacetSafetyTests.waterHeaterTemperatureUsesFacetOrigin` and `PanelFoldLayoutTests.firstDeviceCardIsAboveTheFold`.

## 6. Cross-Platform Golden Corpora & AI Provider Parity

`PanelTheme` is a macOS-only `ViewPreference`: `.classic` is the default on every supported macOS version; `.liquidGlass` is selectable on macOS 26 and later. Windows keeps its existing panel. The two macOS layouts share device control, search, keyboard routing and saved layout preferences; their presentation and window geometry remain separate.

When adding or changing spoken command, delay, undo, habit-memory, proactive-suggestion, MIoT synthesis, MIoT command mapping, or AI provider preset rules, or model confirmation rules, in `Sources/MijiaCore/LocalIntentParser.swift`, `Sources/MijiaCore/UserHabitMemory.swift`, `Sources/MijiaCore/AssistantSchedule.swift`, `Sources/MijiaCore/AssistantConfig.swift`, `Sources/MijiaCore/ModelActionPolicy.swift`, `Sources/MijiaCore/MiCloud/MiotSynthesizer.swift`, `Sources/MijiaCore/MiCloud/MiotCommandMapper.swift`, `windows/src/core/assistant.ts`, or `windows/src/core/miCloudClient.ts`:

- Add a representative test case to [`Tests/Fixtures/intent_golden.json`](Tests/Fixtures/intent_golden.json) or [`Tests/Fixtures/miot_golden.json`](Tests/Fixtures/miot_golden.json) so both `Tests/MijiaCoreTests/GoldenCorpusTests.swift` and `windows/tests/core.test.ts` assert the exact same behavior. AI provider preset rules (domain matching, which hosts may receive API keys) live in [`Tests/Fixtures/provider_golden.json`](Tests/Fixtures/provider_golden.json); Mi cloud region codes/order in [`Tests/Fixtures/region_golden.json`](Tests/Fixtures/region_golden.json); the Jev `/v1/systemone` request skeleton in [`Tests/Fixtures/ai_request_golden.json`](Tests/Fixtures/ai_request_golden.json); habit-memory record/unrecord and the Top-4 proactive engine in [`Tests/Fixtures/habit_golden.json`](Tests/Fixtures/habit_golden.json) — all asserted by `Tests/MijiaCoreTests/GoldenCorpusTests.swift` and `windows/tests/core.test.ts`.
- Keep `AssistantProviderPreset.allCases.map(\.rawValue)` (macOS) and `ASSISTANT_PROVIDER_PRESETS.map(p => p.id)` (Windows) identical in order and membership, and isolate user-saved API keys per provider (`KeychainHelper.assistantProviderAPIKeyAccount(for:)`, `secureStore.ts:assistantApiKeyCredentialName`).
- Credential-slot migrations are two-phase per owner: (1) pin the legacy entry's owner before any preset switch (`assistantLegacyKeyEndpoint`), (2) delete the legacy entry only after `await`ing its own replacement slot's write — never concurrently and never inferred from another populated slot, (3) isolate migration write/delete errors so unrelated credentials (`mi_session`, `ha_token`) still hydrate and retry on the next `persist`, and (4) store the `custom` slot's host binding (`assistantCustomKeyEndpoint`) separately from built-in presets. Owner: `windows/src/core/secureStore.ts:CredentialVault`, `AssistantConfig.swift`. Pinned by `windows/tests/core.test.ts` and `windows/tests/ui.test.ts`.
- Never let one platform silently diverge on Chinese or English command parsing, delay limits (`<= 86400s`), unknown-word fallback (`nil` / `null`), MIoT `0`/`1` boolean coercion, multi-service property resolution, or command range/step clamping.
- GrokBall emotion priority and radial slot order live in [`Tests/Fixtures/grok_ball_golden.json`](Tests/Fixtures/grok_ball_golden.json), asserted by both `GoldenCorpusTests` and `windows/tests/core.test.ts`. Preserve the upstream MIT notice when updating the bundled engine or native geometry.
- [`Tests/Fixtures/air_quality_golden.json`](Tests/Fixtures/air_quality_golden.json) pins the purifier air-quality grade (raw grade word or PM2.5) that drives both the label and the card colour, asserted by `AirQualityLevelTests` and `windows/tests/core.test.ts`. Views map `AirQualityLevel.tone` to a colour; they never re-derive the grade.
- [`Tests/Fixtures/confirmation_golden.json`](Tests/Fixtures/confirmation_golden.json) is the shared confirmation table asserted by `GoldenCorpusTests` and `windows/tests/core.test.ts`.
- [`Tests/Fixtures/miot_coverage_golden.json`](Tests/Fixtures/miot_coverage_golden.json) pins how MIoT synthesis classifies one real public spec per device type (`miot_coverage_specs.json`), asserted by `MiotCoverageBaselineTests` and `windows/tests/miotCoverage.test.ts`. A synthesis change that moves a spec between categories must re-record it (`RECORD_MIOT_COVERAGE=1 swift test --filter MiotCoverageBaselineTests`); `windowsDivergences` lists the specs Windows still classifies differently, and must be pruned by hand when a Windows synthesis fix catches up (the recorder keeps the previous list). `miot_golden.json` also pins the generic-card summary (`genericCases`) and the 更多设置 control list (`facetCases`) for both platforms. Rows of [`docs/capabilities.json`](docs/capabilities.json) that carry `miotTypes` take both platforms' README status from this baseline (`scripts/check_capability_matrix.py`), so a re-record that matches or drops a listed type also updates that row in both READMEs.
- [`Tests/Fixtures/miot_facets.json`](Tests/Fixtures/miot_facets.json) is the hand-written rule fixture for generic facets (#303), asserted by `MiotFacetsTests` and `windows/tests/miotFacets.test.ts`; [`miot_facets_coverage_golden.json`](Tests/Fixtures/miot_facets_coverage_golden.json) pins facet membership over the `miot_coverage_specs.json` models. A rule change must update the hand-written case and re-record the golden (`RECORD_MIOT_FACETS=1 swift test --filter MiotFacetsTests`).
- Multi-key wall switches inherit their parent panel's room (`roomByDid[record.did] ?? record.splitParentDid.flatMap { roomByDid[$0] }`). Any per-home discovery fallback that appends unlisted `did`s into an unnamed `home_<id>` bucket must skip records whose `splitParentDid` is already assigned to a room of that home, otherwise the child keys lose their named room and land in 全屋. Owner: `MiCloudDiscovery.appendMissingDids`, `windows/src/core/miCloud/discovery.ts:appendMissingRoomDids`. Pinned by `MiCloudSyncResilienceTests.roomlessSharedHome` and `windows/tests/miCloudSync.test.ts`.

## 11. External Payload Replay & Deterministic Fuzzing

External payloads (Mi cloud responses, MIoT instance JSON, Home Assistant WebSocket frames, go2rtc MP4 bytes) are untrusted and change without notice:

- Sanitised recordings live in `Tests/Fixtures/contracts/`. Each fixture carries a `_fixture` object with its endpoint, capture date and sanitisation note; identifiers, names, MAC addresses and IP addresses are synthetic. Addresses use TEST-NET ranges (`192.0.2.0/24`), never a real LAN.
- `ContractReplayTests` decodes each fixture and asserts the exact stable fields the app consumes. When the upstream shape changes, update the fixture and the assertions together; never weaken an assertion to make a changed payload pass.
- Fuzz tests use `SeededFuzzGenerator` with a fixed base seed and bounded iterations, and print `seed=<n> iteration=<n> input=<hex>` in every failure message. They must finish in milliseconds so the normal `swift test` suite keeps them.
- A fuzzer that finds a trap ships with the fix and a minimal regression case (see the `tfhd` / `trun` short-payload and huge-number cases). Production code must not convert external numbers with trapping initialisers or signed `abs(...)` (which traps on `.min`): use `Int(exactly:)` / `DeviceSynthesizer.roundedInt` / `.magnitude` and degrade to "no reading" when out of range.
- A separate libFuzzer target is intentionally not wired into SwiftPM. The parsers are pure functions with deterministic seeds already reproducible on macOS and Linux; libFuzzer would add an LLVM-only build path without covering more code. Revisit only if a parser starts consuming non-deterministic process state.
