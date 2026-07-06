# Pocket Artifacts

A native iOS app for building **artifacts** — self-contained single-page HTML
apps in the style of Claude Artifacts — entirely from your phone. Inspired by
Simon Willison's [HTML tools](https://simonwillison.net/2025/Dec/10/html-tools/)
workflow: single-file HTML+JS+CSS, no build step, CDN dependencies,
localStorage state.

- **BYOK**: talks to AI models through [OpenRouter](https://openrouter.ai)
  with your own API key (stored in the iOS Keychain).
- **Conversational**: refine the artifact in a chat; each HTML-bearing reply
  becomes a new version.
- **Previewed in-app**: WKWebView, mobile-first, gestures belong to the artifact.
- **Yours to keep**: Copy HTML puts the full source on the clipboard — paste
  it into the GitHub app, host it on GitHub Pages, or share the `.html` file.

## Development

There is no Xcode in the development environment — the project is plain text:

- `ios/project.yml` is the [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  spec; the `.xcodeproj` is generated and gitignored.
- CI (`.github/workflows/ios-build.yml`, pinned `macos-26` runner, newest
  Xcode 26.x on the image) runs `xcodegen generate` then `xcodebuild test`
  against the iPhone 17 simulator. That's the compile/test loop.
- Device builds (`.github/workflows/ios-distribute.yml`, manual dispatch
  from the Actions tab) produce a manually-signed ad-hoc IPA and upload it to
  Firebase App Distribution's `testers` group. Signing/config comes from
  repo secrets: `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD`,
  `IOS_ADHOC_PROFILE_BASE64`, `APPLE_TEAM_ID`, `FIREBASE_APP_ID`,
  `FIREBASE_SERVICE_ACCOUNT_JSON`. Signing settings reach only the app
  target via `ios/Signing.xcconfig` (empty in the repo, written in CI).

The whole CI/CD setup is documented as a reusable playbook in
[`docs/cicd/`](docs/cicd/README.md) — docs plus portable skills in
[`docs/cicd/skills/`](docs/cicd/skills/) that apply the same setup
(simulator CI, Firebase App Distribution, TestFlight) to any other iOS
app repo. That one directory is all you need to copy or reference.

To work on it locally with Xcode:

```sh
brew install xcodegen
cd ios && xcodegen generate && open PocketArtifacts.xcodeproj
```

## Architecture

SwiftUI + [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture),
iOS 17+.

- `ios/Sources/Core/` — plain Swift logic, no TCA imports (SSE parsing, HTML
  fence extraction, system prompt, model-context building). Unit tested.
- `ios/Sources/Dependencies/` — `@DependencyClient` interfaces + live
  implementations (OpenRouter streaming, Keychain).
- `ios/Sources/Features/` — TCA reducers (app root, editor state machine,
  settings). The editor turn — send → SSE deltas → HTML extraction → version →
  preview reload — is a cancellable `Effect` stream, exhaustively tested with
  `TestStore`.
- `ios/Sources/Views/` — SwiftUI views + the WKWebView preview.
