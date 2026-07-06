# iOS CI/CD playbook

How this repo builds, tests, signs, and ships an iOS app **entirely from
GitHub Actions** — no local Xcode, no fastlane, no Mac required for
day-to-day development. These docs generalize the setup so it can be
applied to any other iOS app repo.

The portable, executable versions of these docs live in
[`skills/`](skills/) right here in the playbook — this `docs/cicd/`
directory is the single thing to reference when applying the setup to
another iOS repo. Either point Claude Code at a skill's `SKILL.md` and ask
it to apply it, or copy a skill directory into the target repo's
`.claude/skills/` to make it auto-discoverable there.

## The pipeline at a glance

```
push (ios/** changed)                 workflow_dispatch            workflow_dispatch
        │                                    │                           │
        ▼                                    ▼                           ▼
 ios-build.yml                       ios-distribute.yml           ios-testflight.yml (template)
 macOS runner (pinned)               macOS runner (pinned)        macOS runner (pinned)
 xcodegen generate                   import signing assets        import signing assets
 xcodebuild test (simulator,         xcodegen generate            xcodegen generate
   no signing)                       xcodebuild archive           xcodebuild archive
        │                            export ad-hoc IPA            export + upload (ASC API key)
        ▼                                    │                           │
 green check = "it compiles          ▼                            ▼
   and tests pass"                   Firebase App Distribution    TestFlight
                                     (installable in ~1 min)      (Apple processing queue)
```

## The docs

| Doc | What it covers |
| --- | --- |
| [01 — Xcode-less development](01-xcodeless-development.md) | The philosophy: XcodeGen plain-text project, CI as the only compiler, why the runner is pinned |
| [02 — Build & test workflow](02-build-and-test.md) | Anatomy of `ios-build.yml`: simulator build + test on every push |
| [03 — Code signing](03-code-signing.md) | The one-time human setup (certs, profiles, secrets) and how CI signs without fastlane |
| [04 — Firebase App Distribution](04-firebase-distribution.md) | Ad-hoc IPA → phone in about a minute, no Apple review queue |
| [05 — TestFlight](05-testflight.md) | The secondary channel: App Store signing + ASC API key upload (template — not yet instantiated in this repo) |
| [06 — Gotchas](06-gotchas.md) | Every non-obvious failure we hit and the fix, in one place |

## The skills

| Skill | What it applies |
| --- | --- |
| [`ios-ci-setup`](skills/ios-ci-setup/SKILL.md) | Simulator build + test workflow (doc 01 + 02) |
| [`ios-firebase-distribution`](skills/ios-firebase-distribution/SKILL.md) | Signed ad-hoc builds → Firebase App Distribution (doc 03 + 04) |
| [`ios-testflight`](skills/ios-testflight/SKILL.md) | Signed App Store builds → TestFlight (doc 03 + 05) |

## All repo secrets, in one table

| Secret | Used by | Contents |
| --- | --- | --- |
| `IOS_DIST_CERT_P12_BASE64` | distribute, testflight | Apple Distribution certificate + private key, `.p12`, base64 |
| `IOS_DIST_CERT_P12_PASSWORD` | distribute, testflight | Password chosen when exporting the `.p12` |
| `IOS_ADHOC_PROFILE_BASE64` | distribute | Ad-hoc provisioning profile, base64 |
| `APPLE_TEAM_ID` | distribute, testflight | 10-character team ID from the Apple Developer portal |
| `FIREBASE_APP_ID` | distribute | Firebase iOS app ID (`1:…:ios:…`) |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | distribute | Service-account JSON with the Firebase App Distribution Admin role |
| `IOS_APPSTORE_PROFILE_BASE64` | testflight | App Store provisioning profile, base64 |
| `ASC_API_KEY_ID` | testflight | App Store Connect API key ID |
| `ASC_API_ISSUER_ID` | testflight | App Store Connect API issuer ID |
| `ASC_API_KEY_P8_BASE64` | testflight | App Store Connect API private key, `.p8`, base64 |

How to produce each of these is covered in [doc 03](03-code-signing.md)
(Apple assets), [doc 04](04-firebase-distribution.md) (Firebase), and
[doc 05](05-testflight.md) (ASC API key).
