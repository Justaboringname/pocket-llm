# CLAUDE.md — Pocket LLM (working name), on-device LLM chat for iPhone

_Last updated: 2026-11-19_

This file is for coding sessions in this repo. User-facing docs are in `README.md` / `README.zh-CN.md`. App Store status, in Chinese, is in `docs/APP_STORE_CHECKLIST.md`.

**Published 2026-11-19** as the public repository `Justaboringname/pocket-llm` under the MIT license (`LICENSE`). The README's screenshots (`docs/images/`) are frames of a real-device screen recording. From here on, everything committed is public: the "No personal data in tracked files" rule below applies to every commit.

**Status (2026-11-18).**
- **Builds and tests.** The app builds for the simulator and for a device. LLMCore had 115 unit tests, all passing, at the last run.
- **On a phone.** First real-device runs on an iPhone 18 Pro Max (iOS 27.2.1, Release, free Personal Team). All five presets downloaded from Hugging Face, loaded and completed the three-turn self-test with thinking off. Thinking on was run for Qwen3 1.7B (all turns fine) and SmolLM3 3B (turn 3 failed, see Known pitfalls). Numbers are in README › Performance.
- **Not built or run yet.** The fix for replies that end inside an unclosed thinking block (`ChatMessage.promoteUnterminatedThinkingIfNeeded()`, the `MessageRow` footer markers and auto-expanded thinking, the self-test's `thinkingPromoted`) and its tests (`Tests/LLMCoreTests/UnterminatedThinkingTests.swift`) are written but have **not** been compiled or run.
- **Still unverified on a device.** See `docs/APP_STORE_CHECKLIST.md`, part 2, item 1.
- **The phone now.** It has the plain Release build (no self-test code), with all five models kept (about 7.5 GB).

## Architecture

- **`Packages/LLMCore`** is the MLX-free core. It holds:
  - the model catalog (`Catalog/ModelCatalog.swift`, the only place sizes and revisions live)
  - the memory-fit math (`Device/DeviceCapability.swift`), `MemoryProbe`, and the entitlement reader
  - the `InferenceEngine` protocol, `MockEngine` and `GenerationTaskRegistry`
  - `SafetyMonitor` (thermal)
  - the `ModelStore` protocol, `LiveModelStore` (manifests, disk-space checks, delete) and `MockModelStore`
  - `ChatViewModel`, the only object the UI talks to, plus `ThinkingParser` and conversation persistence.
- **LLMCore must never import MLX or any Hugging Face package.** It builds and tests on the Mac host with plain `swift test`.
- **`App/Sources/MLX`** holds the MLX-side code:
  - `MLXEngine` (an actor over mlx-swift-lm; loads from a local directory with `OfflineOnlyDownloader`)
  - `HubModelDownloader` (swift-huggingface `HubClient`; cache in `Application Support/Models/hub`; no token; session without cookie storage or URL cache; User-Agent `<display name>/<version>` built from the bundle by LLMCore's `UserAgent.current`, so renaming needs no code change)
  - `MLXRuntimeInfo`.
- **`App/Sources/AppEnvironment.swift`** is the composition root.
  - On a device: `LiveModelStore` + `HubModelDownloader` + `MLXEngine`.
  - In the simulator (`#if targetEnvironment(simulator)`): `MockModelStore` + `MockEngine`.
  - In DEBUG with `LLM_UI_DEMO=<scene>`: seeded demo scenes (`App/Sources/Demo`).
- **`App/Sources/SelfTest/SelfTestRunner.swift`** is the on-device harness. It is compiled only with the `SELFTEST` condition: the scripts' `--selftest` passes `SELFTEST_FLAG=SELFTEST`. It is driven by the env vars `LLM_SELFTEST=<catalog id>`, `LLM_SELFTEST_THINKING`, `_GREEDY` (temperature 0 for every turn), `_SCREENSHOTS`, `_DELETE_AFTER` and `_KEEP_ALIVE`. It runs three turns in one conversation: pick a number, double it (`dependentTurnCheck`), and a ~200-word explanation for a realistic tokens/s and thermal reading (`longTurnCheck`: ≥150 generated tokens; both checks are informational). It writes `Documents/selftest-result.json` (`formatVersion` 3: per-turn `sampling`, answer and thinking text capped at 4,000 characters, download `retries`; later optional keys within format 3: per-turn `thinkingPromoted`) and `SELFTEST {json}` lines on stdout.
- **`App/UITests`** holds the `LLMOnIPhoneUITests` target: XCUITest flows that run in the simulator against the DEBUG demo backend (`LLM_UI_DEMO`). They find views by accessibility identifiers such as `composer.send`, `onboarding.download`, `suggestion.N` and `toolbar.*`; keep those stable. The scheme's test action runs this target.
- **`App/Sources/UI`** is SwiftUI. Chat is the root screen; Models and Settings are sheets. It also has the Markdown renderer and `Theme` (accent `Theme.accentHex`; DEBUG override `LLM_ACCENT`).
- **Config.**
  - `project.yml` (XcodeGen; dependency versions pinned exactly).
  - `Config/Base.xcconfig` (committed: display name, version, privacy/support URLs).
  - `Config/Local.xcconfig` (gitignored: team, bundle-id prefix).
- **Strings.** Two String Catalogs, `App/Resources/Localizable.xcstrings` and LLMCore's `Resources/Localizable.xcstrings`, each in en + zh-Hans.
- **On-device data.**
  - Models: `Application Support/Models` (`manifests/`, `hub/`), excluded from backup.
  - Conversation: `Application Support/Conversations/current.json`, which is backed up. Self-test runs use `selftest.json`.

## Commands

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig    # once; set DEVELOPMENT_TEAM, BUNDLE_ID_PREFIX
xcodegen generate                                         # after every project.yml change
scripts/test-core.sh [--filter ChatViewModelTests]        # swift test in Packages/LLMCore (Mac host, no Metal needed)
scripts/test-ui.sh [--device "iPhone 18 Pro"]             # xcodebuild test of App/UITests in the simulator → .build/logs/ui-tests.log
scripts/build-sim.sh [--selftest] [--release]             # → .build/products/<Config>[-selftest]-iphonesimulator/LLMOnIPhone.app
scripts/build-device.sh [--selftest] [--debug] [--destination 'id=<udid>']   # Release by default → …-iphoneos/LLMOnIPhone.app
scripts/selftest-sim.sh [--model ID] [--thinking] [--greedy] [--no-build]   # harness on the mock backend → .build/selftest/
scripts/selftest-device.sh [--model ID] [--thinking] [--greedy] [--delete-after] [--no-build] [--dry-run]   # harness on the connected iPhone → .build/selftest-device/<model>/
scripts/screenshots.sh [--scenes "…"] [--languages "en zh-Hans"]  # DEBUG demo scenes → .build/screenshots/
scripts/check-strings.py                                  # after build-sim.sh: catalog keys vs. compiled strings, zh-Hans coverage
scripts/gen-acknowledgements.py --check                   # after dependency changes (needs a sim build)
swift scripts/make-app-icon.swift                         # after changing Theme.accentHex
xcrun devicectl device install app --device <device> <path/to/LLMOnIPhone.app>
```

- **Logs.** The scripts write logs to `.build/logs/` (gitignored). `build-device.sh` redacts the team ID and the "Apple Development: …" name in its log, but the signing certificate's hash still appears there. Do not paste device build logs anywhere public.
- **Device self-test.** `scripts/selftest-device.sh` builds with `--selftest`, installs, launches with the console attached, copies the result JSON and the three screenshots back and prints a summary (`--summary FILE` reprints one; it reads result formats 2 and 3). First run against a phone on 2026-11-18, for all five presets. Results land in `.build/selftest-device/<model>/` (gitignored, one run per model, overwritten by the next). The raw JSON contains on-device container paths (`resultFile`), so never copy it into docs. It refuses (and lists names) when the app is not installed and the phone already has 3 other development-signed apps.

## Hard rules

- **No personal data in tracked files.** No team ID, bundle-ID prefix, device UDIDs, signing identities, real names, emails or other personal data in tracked files, logs you paste, or commit messages.
  - One exception, by the owner's decision (2026-11-19): the copyright line in `LICENSE` carries the owner's real name, the same as in the mlx-device-bench repository. Leave it; it is not a leak.
  - These values live only in `Config/Local.xcconfig`, which is gitignored. Do not print or quote it.
  - Scripts keep the bundle ID in a variable and never echo it. Keep it that way.
- **The generated `.xcodeproj` is not committed.** The only exception is `LLMOnIPhone.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Change `project.yml`, never the project file.
- **Keep the dependency pins:** mlx-swift 0.31.4, mlx-swift-lm 3.31.3, swift-huggingface 0.9.0, swift-transformers 1.3.0.
  - 3.33.0 / 0.33.0 are source-breaking and are a planned post-v1 migration. Do not bump casually.
- **LLMCore stays free of MLX and Hugging Face.** New engine or download code goes in `App/Sources/MLX` behind the LLMCore protocols.
- **Loading a model must never touch the network.**
  - Keep `.directory` configurations + `OfflineOnlyDownloader` in `MLXEngine.load`.
  - The only network code is `HubModelDownloader`, and it runs only on a user's confirmed download (or in SELFTEST).
  - Adding any other network use, analytics or crash reporting means updating `docs/PRIVACY*.md`, `PrivacyInfo.xcprivacy` and the checklist.
- **Required-reason APIs.** `PrivacyInfo.xcprivacy` declares only DiskSpace (`E174.1`, `85F4.1`). Adding `UserDefaults`/`@AppStorage`, file timestamp APIs (`creationDate`, `modificationDate`, `stat`…) or `systemUptime`/`mach_absolute_time` requires a new reason code.
- **Model presets.**
  - Upstream must be Apache-2.0 or MIT.
  - Pin a full commit SHA.
  - `downloadBytes` is the sum of the files matched by `ModelDownloadPatterns.all` at that revision.
  - Update `CatalogTests`, the String Catalog blurb key (en + zh-Hans) and `docs/MODEL_LICENSES.md`.
- **Never touch MLX in the simulator.** Guard with `#if targetEnvironment(simulator)` (see `MLXRuntimeInfo`).
- **No GPU work unless `lifecycle == .active`.** Keep the `scenePhase → AppEnvironment.handleScenePhase → ChatViewModel.handleLifecycle` path. It stops generation on `.inactive` and waits for the GPU inside a background-task assertion.
- **Command-line `xcodebuild` needs `-skipMacroValidation`** (the MLXHuggingFace macro uses swift-syntax), plus `-skipPackagePluginValidation`. The scripts pass both.
- **The Metal Toolchain component must be installed** for app builds: `xcodebuild -downloadComponent metaltoolchain`. `scripts/test-core.sh` does not need it.
- **Free Personal Team** (current signing setup):
  - Profiles last 7 days.
  - At most 3 sideloaded apps per device and 3 devices.
  - At most 10 App IDs, which expire after 7 days. Do not create throwaway bundle IDs.
  - The UI-test target (`$(BUNDLE_ID_PREFIX).llmoniphone.uitests`) is simulator-only (`SUPPORTED_PLATFORMS: iphonesimulator`), so it never registers an App ID. Keep it that way.
  - It does grant `increased-memory-limit`.
  - Do **not** add `extended-virtual-addressing`; free teams cannot sign it.
- **Every user-facing string goes in both languages.** Run `scripts/check-strings.py` after a simulator build.
- **Persistence changes must keep old files decodable.**
  - `ConversationSnapshot.formatVersion` is 1.
  - New `ChatMessage` fields must be **optional**, as `thinkingDuration` and `thinkingPromoted` are. `ChatMessage` uses synthesized `Codable`, which ignores default values: a non-optional field with a default makes every older file fail with `keyNotFound`.
  - Such a failure is silent: `restore()` loads with `try?`, so the user's conversation would just disappear. A non-optional field needs a hand-written `init(from:)`.

## Known pitfalls

- **mlx-swift-lm 3.31.3 stop-reason bug (worked around).** In `MLXLMCommon/Evaluate.swift` (generateTask, around lines 1722–1729), `for token in iterator` iterates a *copy* of the `TokenIterator` struct, so `iterator.tokenCount` stays 0. Hitting `maxTokens` is therefore reported as `.cancelled`, not `.length`.
  - **Workaround.** `MLXEngine` passes the library's reason through `StopReason.resolved(libraryReason:stopRequested:generatedTokens:maxTokens:)` (LLMCore, unit-tested): `.cancelled` with no requested stop (no `stopGeneration()`, no consumer cancellation, no safety stop) and `generatedTokens >= maxTokens` becomes `.maxTokens`. `ChatViewModel` then shows the reply as done with the "Length limit" footer, and the self-test counts it as a finished turn (`truncated: true`).
  - **Status.** The bug was confirmed by reading the source and observed with LLMEval. In this app's device runs of 2026-11-18 every reply ended at end of sequence and none reached `maxTokens`, so the workaround has still not run on a device. Remove it when upgrading past 3.31.3 (check the fixed library first).
- **The simulator cannot run MLX** (it needs a real Metal GPU family). The simulator always uses mocks, so a passing `selftest-sim.sh` proves the harness and UI path only.
- **Generation must stop before backgrounding.** iOS terminates apps that submit GPU work in the background. `.inactive` already stops generation, because by `.background` it may be too late.
- **Prefill cannot be cancelled in 3.31.3.** `TokenIterator.init` prefills synchronously inside `container.perform`, so Stop and backgrounding wait for it. Cooperative prefill cancellation arrived in 3.32.3.
- **The sampling seed does nothing in mlx-swift-lm 3.31.3.** `TopPSampler` and `CategoricalSampler` each create their own `MLXRandom.RandomState()` (seeded from the uptime) and sample inside `withRandomState` (`Evaluate.swift` 220–257, 294–308; mlx-swift `State.swift` 34–36, 93–95). `MLXEngine`'s `MLXRandom.seed(…)` only sets the global state, so `GenerationOptions.seed` cannot reproduce a sampled reply; the self-test records `seedControlsSampling: false`. For deterministic runs use temperature 0 (`ArgMaxSampler`; `LLM_SELFTEST_GREEDY`). Filters run on the temperature-1 distribution (top-p → min-p → top-k), then temperature is applied, as in Python mlx-lm; `topK: 0` and `minP: 0` mean off.
- **No KV cache is kept between replies.** `cache: nil`; every reply re-templates and re-prefills the trimmed conversation. `PromptBuilder` (in `MLXEngine.swift`) trims to `promptTokenBudget` (4,096) and always keeps the system prompt and the newest user message.
- **`xcodegen generate` runs only when the project is missing.** The scripts skip it otherwise, so regenerate by hand after editing `project.yml`. `App/Sources` and `App/Resources` are synced folders: new files there need no regeneration.
- **URLs in xcconfig files.** `//` starts a comment, so write them as `https:/$()/example.com/…` (see `Config/Base.xcconfig`). Empty `PRIVACY_POLICY_URL` / `SUPPORT_URL` hide the Settings rows, including "Report a problematic response".
- **Downloads.**
  - **Transient failures are retried automatically.** The first device download of Qwen3 1.7B failed 5 s in with `NSURLErrorDomain -1005` ("The network connection was lost") as the 968 MB `model.safetensors` started on the CDN; an immediate second attempt took 11 s. The retry below was added afterwards. A later fresh download through it (snapshot completeness check included) succeeded with 0 retries, so **the retry itself has not yet been seen firing on a real network error**.
    - `LiveModelStore` wraps each `ModelDownloader.download` call in `DownloadRetryPolicy` (LLMCore, unit-tested): 3 retries after 1, 2 and 4 s, inside the stored download task, so joining callers and `cancelDownload` keep working. A cancel never retries and never waits out a backoff.
    - Retried (`classify`, walking `NSUnderlyingError`; `kCFErrorDomainCFNetwork` uses the same codes): URL -1001, -1003, -1004, -1005, -1006; POSIX 50–54 and 60; HTTP 408, 429 and 5xx; `ModelStoreError.incompleteDownload`. **Not retried:** -1009 / -1018 / -1020 (offline: fails fast with "No internet connection…"), -999 and `CancellationError`, other HTTP statuses, everything else.
    - The state stays `.downloading` during retries and its progress never goes backwards (`applyProgress` ignores lower fractions and clamps bytes). The final `.failed` message comes from `LiveModelStore.failureMessage(for:)` using the **last** error; the thrown error is unchanged, so the self-test still records its domain and code. Retries are in `downloadRetries(for:)` and the self-test's `download.retries`.
  - **swift-huggingface 0.9.0 error types.** Network failures surface as the plain `URLError` from `URLSession` (HubClient rethrows them unwrapped). Its own `HTTPClientError` is not a `LocalizedError` ("…HTTPClientError error 1."), so `HubModelDownloader` translates it into `ModelDownloadError` (status kept).
  - **Partial-snapshot fallback.** When listing the repo fails and some files are on disk, `HubClient.downloadSnapshot` returns that partial snapshot instead of throwing (`HubClient+Files.swift` 1271–1287). `HubModelDownloader` compares the snapshot with the file list HubClient saved (`<cache>/.metadata/models--…/<commit>.json`, via LLMCore's `SnapshotCompleteness`; skipped if unreadable), lists again to surface the real error, and otherwise throws `incompleteDownload` (retried).
  - Resume works per file: completed files are kept and skipped on the next attempt; an interrupted file restarts from zero.
  - `HubClient` leaves `CFNetworkDownload_*.tmp` files behind. `HubModelDownloader.cleanUpTemporaryFiles()` removes them when no download runs; on APFS they are clones that would keep deleted models' blocks allocated.
  - Downloads do not continue in the background: there is no background `URLSession`.
  - The UI shows a failed download's message with **Retry** (Models card) or **Try again** (onboarding card). Both reopen the download confirmation, which states the full model size even when part of it is already on disk.
- **Simulator memory reporting.** In the simulator `os_proc_available_memory()` reports 0, and the memory budget falls back to 50% of physical memory. Simulator fit badges therefore say nothing about phones.
- **Computed properties are missing from the self-test JSON.** `MemorySnapshot.processLimitBytes` and `EntitlementReport.increasedMemoryLimitLikelyEffective` are computed, so they are not encoded. Derive them as `availableBytes + footprintBytes` and `signed == true && inProfile != false`.
- **Template quirks.**
  - The Qwen3 mlx-community repos ship no `generation_config.json`; the catalog adds `<|endoftext|>` as an extra EOS.
  - In SmolLM3, `<think>`/`</think>` are non-special tokens and reach `ThinkingParser` as text. Its template always injects a dated system header.
- **SmolLM3 3B with thinking on can leave its thinking block open (device, 2026-11-18, one run).**
  - **What happened.** Turns 1 and 2 were fine: turn 1 had 830 characters of thinking and the answer "30", turn 2 had no thinking and "60". In turn 3 (the ~200-word essay) the model wrote its reasoning and then the whole essay inside `<think>`, then ended at EOS without ever emitting `</think>`. The app was left with 1,943 characters of "thinking" and an empty answer, and the self-test failed the turn with `emptyAnswer`.
  - **Handling (written, not yet built or run).** At the end of each reply, `ChatViewModel.consume` calls `ChatMessage.promoteUnterminatedThinkingIfNeeded()`. It acts only when all of these hold: state `.done`, `stopReason == .endOfSequence`, the block is unterminated, the answer is blank and the thinking is not. Then the thinking text moves to `text`, `thinking` and `thinkingDuration` are cleared, `isThinkingUnterminated` stays `true`, and `thinkingPromoted = true`.
  - **What the user and the self-test see.** The footer shows "Reasoning shown as answer". The self-test counts the turn as answered and records `thinkingPromoted: true`. The promoted text is sent back as the assistant turn in later prompts.
  - **Not promoted.** Replies that hit `maxTokens` while thinking, were stopped, or failed keep their thinking. `MessageRow` expands the thinking of any finished reply with no answer. A length-limited one gets "Length limit while thinking".
- **Qwen3 1.7B with thinking off often answers out of range (device, 2026-11-18).**
  - **What happened.** For the self-test's "pick a whole number between 11 and 49", it answered out of range in roughly half the runs (e.g. 57, 67). This also happened under greedy decoding: argmax gives 67, which it then doubled correctly to 134.
  - **Why it looks like the model.** The other four presets answer correctly through the identical code path, and a source review of the sampling path found nothing wrong. So this looks like a limitation of this small quantized model without thinking.
  - **Not cross-checked.** It has **not** been compared with a reference implementation on a Mac. With thinking on, Qwen3 1.7B got all three turns right (25 → 50 and a coherent essay). The self-test's `dependentTurnCheck` only checks the doubling, so it does not flag this.
- **Script guard (opt-in).** Set `LLM_BUILD_GUARD='<regex>'` and the build, test, self-test and screenshot scripts refuse to start while a process whose command line matches it (`pgrep -if`) is running; unset means no guard.
