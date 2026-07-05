# Pocket Artifacts — a mobile AI app for building single-page HTML tools

> **Status (July 2026):** Phases 1, 1.5, and 2 are complete; Phase 3 is next.
>
> - ✅ **Phase 1** — iOS skeleton: XcodeGen project, TCA editor loop
>   (chat → SSE stream → HTML extraction → WKWebView preview), Keychain
>   BYOK settings, unit + TestStore suites, simulator CI green.
> - ✅ **Phase 1.5** — Firebase App Distribution: signed ad-hoc builds from
>   CI, confirmed installing and launching on a physical iPhone.
> - ✅ **Phase 2** — persistence, library, versions: GRDB `DatabaseClient`
>   (artifacts/versions/messages, cascade delete), `LibraryFeature` at the
>   root of a navigation stack, editor wired to storage (transcript loaded
>   on appear, every finished turn persisted, a numbered `ArtifactVersion`
>   per HTML-bearing response, title derived from the generated `<title>`),
>   `VersionHistoryFeature` with full-screen previews and copy-forward
>   restore, model picker fed by `/models`, FlyingFox `MockServer`
>   TestSupport, and `GenerationFlowTests` integration suite (live client →
>   localhost SSE → reducers → GRDB rows). Simulator CI green.
> - ⬜ Phase 3 — editor polish
> - ⬜ Phase 4 — Android port
>
> **Deviations from the plan as written, discovered during execution:**
>
> - **CI runner/Xcode**: the plan pinned `macos-15` + Xcode 16.4, but that
>   toolchain fails linking TCA via XcodeGen (SwiftUI-previews debug dylib
>   + SPM package products). CI now pins the `macos-26` runner and selects
>   the newest Xcode 26.x on the image; simulator target is iPhone 17.
> - **Explicit SPM product linkage**: with the app and test bundle both
>   linking TCA, Xcode builds package products as dynamic frameworks, and
>   every module referenced through TCA's `@_exported` re-exports
>   (Dependencies, DependenciesMacros, CasePaths, IdentifiedCollections,
>   ConcurrencyExtras) must be declared explicitly in `project.yml`.
> - **Signing scope**: manual code-signing settings are injected via
>   `ios/Signing.xcconfig` (empty in the repo, written by CI) because
>   passing them as `xcodebuild` arguments applies them to SPM macro
>   targets, which reject provisioning profiles.
> - **Bundle ID** is `fyi.imdaniel.pocketartifacts` (matching the
>   registered Apple App ID), not a `com.dsyang.*` ID.
> - **Phase 1.5 signing** used the manual Mac route (Keychain Access CSR →
>   Apple Distribution cert → ad-hoc profile → `.p12` in repo secrets), not
>   fastlane match. Secrets: `IOS_DIST_CERT_P12_BASE64`,
>   `IOS_DIST_CERT_P12_PASSWORD`, `IOS_ADHOC_PROFILE_BASE64`,
>   `APPLE_TEAM_ID`, `FIREBASE_APP_ID`, `FIREBASE_SERVICE_ACCOUNT_JSON`.
>   Distribution triggers on push to `main` + manual dispatch and delivers
>   to the App Distribution group with alias `testers`.
>
> **Phase 2 deviations:**
>
> - **Model picker is category-limited**: `GET /api/v1/models` unfiltered
>   returns ~340 models, most useless here, so the picker defaults to
>   OpenRouter's curated `?category=programming` list (~19 models) with a
>   "Show all models" toggle for the full catalog; the current selection
>   stays visible even when it's off-list. Default model bumped to
>   `anthropic/claude-sonnet-4.6` — 4.5 had aged out of that category.
> - **Integration tests drive a live `Store`, not `TestStore`**: TestStore's
>   action-by-action bookkeeping timed out consuming effect-produced actions
>   in CI (and its assertable state lags unconsumed actions). Integration
>   asserts final state + persisted rows + recorded request payloads, which
>   a live store with `send(...).finish()` plus DB polling fits better.
>   TestStore remains the tool for the unit suites.
> - **More explicit SPM products**: FlyingFox *and* FlyingSocks are declared
>   on the test target (`Socket.Address` for reading the MockServer's
>   ephemeral port lives in FlyingSocks) — same autolinking constraint as
>   the TCA re-exports above.
> - **ATS**: `NSAllowsLocalNetworking` added to Info.plist so the loopback
>   MockServer works under App Transport Security in test runs.
> - **MockServer streams whole SSE bodies**: scripted responses are emitted
>   as one response body of real `data:` events rather than with
>   configurable transport-chunk boundaries/delays (TCP coalescing on
>   loopback makes those unreliable to script anyway); chunk-boundary
>   reassembly is covered by the `SSEParser.feed` unit tests.
> - **No Code tab** (user decision, supersedes §6's "Code view + Copy
>   button"): the editor has only Chat and Preview tabs, and Copy HTML is a
>   context menu on a long-press of the tab control. The copy affordance
>   deliberately does not live inside the preview — gestures in the
>   WKWebView belong to the artifact (§3).
>
> The original plan follows, unedited except for §Verification, where a
> stale session-branch name and the superseded runner/Xcode pin were
> scrubbed (see deviations above).

---

## Context

Build a native iOS app (SwiftUI + WKWebView) that lets anyone create "artifacts" — self-contained single-page HTML apps in the style of Claude Artifacts — entirely from their phone. Inspired by Simon Willison's [HTML tools](https://simonwillison.net/2025/Dec/10/html-tools/) workflow: single-file HTML+JS+CSS, no build step, CDN dependencies, localStorage/URL-param state, permanently hosted on GitHub Pages.

The app talks to AI models through **OpenRouter** (user's own API key), previews artifacts in an **in-app WKWebView**, refines them **conversationally** with version history, and stores them in a **local library**. Sharing is simple and manual: a **Copy HTML** button (paste into the GitHub app or anywhere else yourself) plus the OS share sheet.

Decisions made with the user:
- **Platform**: Native iOS first (SwiftUI + WKWebView, iOS 17+), built on **TCA (The Composable Architecture)**; a fully native Android app (Jetpack Compose + WebView) follows as a later phase with a mirrored MVI architecture — two native codebases, no KMP
- **AI access**: BYOK — OpenRouter key pasted by user, stored in Keychain
- **UX**: Chat-driven conversational refinement (like Claude Artifacts), not one-shot
- **Storage/sharing**: Local library (SQLite via GRDB, behind a TCA dependency client) + Copy HTML button + share sheet

Why TCA: the editor is a streaming state machine (user turn → SSE deltas → HTML extraction → version creation → preview reload), which maps directly onto TCA reducers + `Effect` streams. Since in-session verification is CI-only, TCA's `TestStore` lets us exhaustively test that state machine without a simulator UI. Trade-offs accepted: swift-syntax macro compilation slows CI builds, and we use GRDB instead of SwiftData (SwiftData's `@Model` observation fights TCA's value-type state).

## Repo & tooling constraints

This repo is developed via Claude Code remote sessions on Linux — **no Xcode available in-session**. Therefore:

- Use **XcodeGen**: check in a `project.yml` + source files; `.xcodeproj` is generated (and gitignored). This keeps the project fully editable as plain text.
- Add a **GitHub Actions CI workflow** (`macos-15` runner) that installs XcodeGen and runs `xcodebuild build` against the iPhone simulator. This is the primary in-session verification loop: push → CI compiles → fix errors.
  - The runner is **pinned** (not `macos-latest`) and the Xcode version is pinned via `xcode-select` inside the job: since CI is our only compiler, a floating alias flipping to a new image (new Xcode/SDK/simulator set) would break builds with no repo change and no local Xcode to diagnose with. Runner/Xcode bumps happen as deliberate, isolated commits when GitHub's deprecation warnings appear.
- Unit-testable logic (SSE parsing, HTML extraction) goes in plain Swift types so CI runs `xcodebuild test` too.

## Directory structure

```
ios/
├── project.yml                       # XcodeGen spec (app + test targets, iOS 17.0, TCA via SPM)
├── Sources/
│   ├── PocketArtifactsApp.swift      # @main, root Store
│   ├── Features/                     # TCA reducers + their SwiftUI views
│   │   ├── AppFeature.swift          # root: navigation stack, library ↔ editor ↔ settings
│   │   ├── LibraryFeature.swift      # artifact list, create/delete
│   │   ├── EditorFeature.swift       # chat state machine: send → stream → extract → version
│   │   ├── VersionHistoryFeature.swift
│   │   └── SettingsFeature.swift     # API key, model picker
│   ├── Dependencies/                 # @DependencyClient interfaces + live implementations
│   │   ├── OpenRouterClient.swift    # streamChat(messages) -> AsyncThrowingStream<Delta>, listModels()
│   │   ├── DatabaseClient.swift      # GRDB: artifacts, versions, messages CRUD
│   │   └── KeychainClient.swift      # get/set openrouter-api-key
│   ├── Core/                         # plain logic, no TCA imports (unit tested)
│   │   ├── SSEParser.swift           # incremental "data: {...}" line parser
│   │   ├── HTMLExtractor.swift       # pull ```html fenced block from model output
│   │   ├── ArtifactPrompt.swift      # system prompt (see below)
│   │   └── Models.swift              # Artifact, ArtifactVersion, ChatMessage (Codable structs)
│   └── Views/
│       ├── PreviewWebView.swift      # UIViewRepresentable WKWebView
│       ├── ChatView.swift            # message list, streaming indicator
│       └── CodeView.swift            # scrollable monospaced HTML source
├── Tests/                            # unit + integration (headless, fast-ish)
│   ├── EditorFeatureTests.swift      # TestStore: full turn incl. stream failure/cancel
│   ├── SSEParserTests.swift
│   ├── HTMLExtractorTests.swift
│   └── Integration/                  # live client vs localhost MockServer (see §9)
│       └── GenerationFlowTests.swift # store + real URLSession/SSE + in-memory GRDB
├── TestSupport/                      # shared target: MockServer + scenario fixtures
│   ├── MockServer.swift              # FlyingFox server: OpenRouter SSE stubs
│   └── Scenarios.swift               # named fixtures (happyPath, streamError, noFence)
└── UITests/                          # XCUITest golden paths (app launched with --mock-server)
    └── CreateArtifactUITests.swift
.github/workflows/ios-build.yml       # CI: xcodegen + xcodebuild build/test
android/                              # Phase 4 (see below) — Compose app mirroring ios/Features
```

## Key design decisions

### 1. System prompt (the heart of the product)
Codified in `ArtifactPrompt.swift`, following the article's playbook:
- Return **one complete self-contained HTML file** in a single ```html fenced code block; brief prose outside the fence is allowed but only one fence.
- **No React, no build step**; vanilla JS + CSS; CDN `<script>` tags OK when a library genuinely helps.
- **Mobile-first**: `<meta name="viewport">`, touch-friendly hit targets, responsive layout, `overscroll-behavior: none` + `touch-action: manipulation` so gestures feel app-like inside the WKWebView.
- Persist user state in `localStorage`; encode shareable config in URL params.
- On refinement turns, always re-emit the **entire updated file** (never a diff) — this is what makes extraction and versioning trivial.

### 2. OpenRouter client
- `POST https://openrouter.ai/api/v1/chat/completions` with `stream: true`, parsed via `URLSession.bytes(for:)` + `SSEParser`. Include `HTTP-Referer`/`X-Title` headers per OpenRouter convention.
- `GET /api/v1/models` populates the model picker in Settings (searchable list, sensible default like `anthropic/claude-sonnet-4.5`; remember last choice in `UserDefaults`).
- Context sent per turn: system prompt + prior chat messages, with **older assistant HTML bodies replaced by a short placeholder** ("[previous version N omitted]") and only the latest HTML included in full — keeps token cost linear instead of quadratic across refinements.

### 3. Preview: WKWebView
- `PreviewWebView` is a `UIViewRepresentable` that writes the HTML to a temp file and uses `loadFileURL(_:allowingReadAccessTo:)` — better baseline than `loadHTMLString` for localStorage and relative behavior; remote CDN loads still work.
- Inject a `WKUserScript` that forwards `window.onerror` and `console.error` to a script message handler; show a small error banner over the preview so users can say "fix that error" in chat.
- Reload button (toolbar, not pull-to-refresh — see below) re-loads the current version.
- **Gesture ownership — all swipes belong to the artifact** (fixing the Claude-app problem where swiping down on an artifact dismisses the sheet):
  - The preview is **never hosted in a drag-dismissable sheet**. It lives as a full-screen segmented tab inside the editor, so no `UISheetPresentationController` pan gesture competes for vertical swipes. Version previews use `.fullScreenCover` with an explicit Close button (no dismiss gesture exists), not `.sheet`.
  - Disable the NavigationStack's edge-swipe-back (`interactivePopGestureRecognizer`) while Preview is frontmost, so artifacts using horizontal/edge gestures (carousels, games) get them; back navigation is the toolbar button.
  - Keep `allowsBackForwardNavigationGestures = false` (default) so WKWebView doesn't claim edge swipes for history, and no pull-to-refresh recognizer on the scroll view.
  - System prompt requires artifacts to set `overscroll-behavior: none` and `touch-action: manipulation`, killing scroll-chaining/rubber-band interference and double-tap-zoom delay inside the artifact itself.

### 4. Conversational refinement + versions (TCA state machine)
- `EditorFeature` drives a turn as reducer actions: `.sendTapped` → `.streamDelta(String)` (appends to the in-flight bubble) → `.streamFinished` → `HTMLExtractor` pulls the fenced HTML → if found, create a new `ArtifactVersion`, switch Preview to it, and derive/keep the artifact title (ask the model for a `<title>`; use it). Streaming runs as a cancellable `Effect` consuming `OpenRouterClient.streamChat`'s `AsyncThrowingStream`; all of it is `TestStore`-tested with a scripted stream.
- If **no HTML fence** is found (model just answered a question), it's a plain chat turn — no version created.
- Version history sheet: browse versions, preview any, **Restore** copies an old version forward as the newest (never rewrites history).
- Streaming failures/cancellation keep the chat consistent: partial text stays visible and marked failed; no version is created.

### 5. Library + sharing
- SQLite via **GRDB** behind `DatabaseClient` (cascade delete `Artifact` → versions, messages); plain Codable structs as records so the same schema translates 1:1 to Room on Android.
- Library shows title, updated date, and a thumbnail (post-load `WKWebView.takeSnapshot` cached as PNG on disk; plain placeholder until first snapshot).
- Share = OS share sheet with the current version written as `<Title>.html` (opens in Safari, AirDrops, mails — matches the "single file is the distribution format" ethos).

### 6. Getting HTML out of the app: Copy button
- A prominent **Copy HTML** button (editor toolbar + Code view) puts the current version's full source on the clipboard via `UIPasteboard` — the user pastes it into the GitHub app (or anywhere) to host it themselves, e.g. on GitHub Pages per the article. This mirrors the article's emphasis on copy-to-clipboard as the mobile-friendly primitive.
- The share sheet (.html file export, §5) covers AirDrop/Files/Mail.

### 7. Keychain + first-run
- `KeychainClient`: minimal `kSecClassGenericPassword` wrapper, single key `openrouter-api-key`.
- First launch (no API key): friendly onboarding screen explaining BYOK with a link to openrouter.ai/keys and a paste field.

### 8. Device testing: Firebase App Distribution (both platforms)
Chosen to avoid Apple review/processing queues entirely — ad-hoc builds install the moment CI uploads them (TestFlight internal has no review but every build waits in Apple's processing queue). Costs: Apple Developer Program $99/yr (required for any distribution); Firebase App Distribution itself is free.

- **Signing setup (one-time, user does in browser/Xcode):** join Apple Developer Program; register iPhone UDID; create an ad-hoc distribution certificate + provisioning profile. Store as GitHub secrets: cert `.p12` + password, profile, plus a Firebase service-account JSON.
- **CI (`ios-distribute.yml`, manual `workflow_dispatch` + on main):** `xcodegen` → `xcodebuild archive` + `-exportArchive` (ad-hoc export options plist) → upload via `firebase appdistribution:distribute` with the service account. Installing = tap the link in the Firebase App Tester invite email.
- The existing `ios-build.yml` (simulator build + tests, no signing) remains the fast per-push loop; distribution runs only when a testable build is wanted.
- This lands as **Phase 1.5** — proving a signed physical-device build early de-risks the whole project before feature investment.
- **TestFlight as a secondary, non-default option:** a separate `ios-testflight.yml` (manual `workflow_dispatch` only) archives with App Store distribution signing and uploads via `xcrun altool`/fastlane using an App Store Connect API key from secrets. Useful when sharing with testers whose UDIDs aren't registered — no UDID management, but each build waits in Apple's processing queue (internal testing needs no App Review). Firebase remains the default day-to-day channel; the export-options plist and signing secrets are structured so both workflows share the same archive step.
- **Android phase:** same Firebase project, `gradle assembleRelease` (simple keystore in secrets) → `appdistribution:distribute`. No Play account needed.

### 9. Integration & user-flow testing against a mock server
Both network clients take an injectable base URL, which makes real multi-service testing cheap:

- **`TestSupport` target — `MockServer`:** embedded HTTP server via **FlyingFox** (pure-Swift SPM package, async/await, runs on localhost inside a test or app process). Serves scripted OpenRouter responses as real SSE (configurable chunk boundaries and delays — including `data:` lines split across chunks, mid-stream disconnects, and no-fence chat replies) plus the `/models` list. Records all requests for assertions. Named `Scenarios` fixtures are shared by both layers below.
- **Integration tests (`Tests/Integration`, headless):** compose the **live** `OpenRouterClient` (real URLSession + real SSE parsing) pointed at the MockServer, real reducers, in-memory GRDB `DatabaseClient`, and drive end-to-end flows through the TCA store: create artifact → send prompt → stream completes → version row persisted → restore old version → refine again → assert request payloads (system prompt, context-window placeholder behavior). This is where services + features are exercised *together*; runs in the normal `xcodebuild test` CI job.
- **UI tests (`UITests`, XCUITest):** the real app launched with `--mock-server` (starts MockServer in-process, in-memory DB, fake keychain, localhost base URLs). 2–3 golden paths only (simulator UI tests are slow): first-run key entry → prompt → preview renders (assert DOM text via `webViews.staticTexts`) → refine → version history shows 2. Separate CI step so the unit/integration loop stays fast.
- **Android phase** mirrors this with OkHttp `MockWebServer` + Compose UI tests, porting the same scenario fixtures.

### 10. Android (later phase): mirrored native app, no KMP
- Jetpack Compose + Android `WebView`; Kotlin coroutines/`StateFlow`.
- Architecture mirrors TCA shape without a framework: each screen is a `ViewModel` holding immutable `State`, a sealed `Action` type, and a pure `reduce` function, with effects as coroutines — so `EditorFeature.swift` and `EditorViewModel.kt` read as translations of each other.
- Services rewritten in Kotlin (small surface): OkHttp SSE for OpenRouter, Room for storage (same schema as GRDB), EncryptedSharedPreferences/Keystore for keys; the system prompt string is shared verbatim.
- Own CI job (`ubuntu` runner, `gradle assembleDebug test`) — Android unit tests are much cheaper in CI than iOS.

## Build order

**Phase 1 — iOS skeleton that generates and previews (core loop).**
`ios/project.yml` (with TCA SPM dependency) + CI workflow first (get a green build on empty scaffold), then `KeychainClient` + `SettingsFeature` (API key entry, hardcoded model), `OpenRouterClient` + `SSEParser` + `HTMLExtractor` with unit tests, minimal `EditorFeature` (chat input → streamed response → WKWebView preview). No persistence yet — prove the prompt→preview loop.

**Phase 1.5 — Firebase App Distribution (prove a physical build early).**
Immediately after the skeleton builds green in CI: `ios-distribute.yml` workflow with ad-hoc signing from GitHub secrets + `firebase appdistribution:distribute`, and confirm the app actually installs and launches on the user's iPhone before investing in features. Blocked on user-side setup (Apple Developer enrollment, UDID registration, cert/profile creation, Firebase project + secrets) — if that's not ready yet, later phases proceed against simulator CI, but the device-install milestone stays the gate before Phase 3 polish. A manual-trigger TestFlight workflow (`ios-testflight.yml`) is included as a secondary channel for UDID-less testers; Firebase stays the default.

**Phase 2 — Persistence, library, versions.**
GRDB `DatabaseClient`, `LibraryFeature`, `EditorFeature` wired to storage, version creation per HTML-bearing turn, `VersionHistoryFeature` with restore, model picker fed by `/models`. `EditorFeatureTests` via TestStore, plus the `TestSupport` MockServer and the first integration test (`GenerationFlowTests`: live client → SSE → reducer → GRDB row).

**Phase 3 — Polish the editor.**
Code view with **Copy HTML** button, console/JS-error capture banner, share sheet export, thumbnails, onboarding screen, streaming cancel/retry. XCUITest golden paths against `--mock-server` added as a separate CI step.

**Phase 4 — Android port.**
After the iOS app is validated on-device: scaffold `android/` Gradle project, port Core logic + services to Kotlin, build Compose screens mirroring the TCA features phase-by-phase (editor loop → library/versions → polish), with its own CI job.

## Verification

- **In-session (every phase)**: push to the working branch; the `ios-build.yml` CI runs `xcodegen generate` then `xcodebuild build test` against the iPhone simulator. Iterate until green.
- **Unit tests in CI**: `EditorFeature` TestStore tests (happy-path turn, stream error, cancel, no-fence chat turn), SSE chunk reassembly (split-across-chunk `data:` lines, `[DONE]`), HTML extraction (fence present/absent/multiple, prose around fence).
- **Integration tests in CI**: live client + reducers + in-memory GRDB against the localhost MockServer — full generation/refinement flows, asserting persisted rows and request payloads (§9).
- **UI tests in CI (separate step)**: XCUITest golden paths with the app in `--mock-server` mode, asserting rendered WKWebView content and version history through the real UI.
- **Android phase**: `gradle test` (reducer/service unit tests) + `assembleDebug` in CI; same on-device end-to-end script as iOS.
- **On-device (user)**: install via Firebase App Distribution link (or `xcodegen generate` + Xcode before distribution is set up). End-to-end script: paste OpenRouter key → "make me a tip calculator" → preview renders and works (swipes stay in the artifact) → "make the buttons bigger" → new version appears, history shows both → Copy HTML puts the full source on the clipboard (paste into the GitHub app) → share exports a working .html.
