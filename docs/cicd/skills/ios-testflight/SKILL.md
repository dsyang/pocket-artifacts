---
name: ios-testflight
description: Set up signed App Store builds from GitHub Actions uploaded to TestFlight via the App Store Connect API — manual signing with repo secrets, no fastlane, no altool. Use when the user wants TestFlight distribution, external/UDID-less testers, or an App Store upload pipeline from CI.
---

# TestFlight uploads from GitHub Actions

Add a manually-triggered workflow that archives the app with App Store
distribution signing and uploads it to TestFlight in a single
`xcodebuild -exportArchive` call (`destination: upload` + App Store
Connect API key — no fastlane, no deprecated `altool`, no Apple ID
password/2FA in CI).

Template: [`templates/ios-testflight.yml`](templates/ios-testflight.yml).
Deep dive: [`03-code-signing.md`](../../03-code-signing.md) and
[`05-testflight.md`](../../05-testflight.md) in the playbook this skill
ships with (`docs/cicd/` in the pocket-artifacts repo).

**When to use vs Firebase App Distribution** (`ios-firebase-distribution`
skill): TestFlight needs no UDID management and reaches up to 10,000
external testers, but every build waits in Apple's processing queue;
Firebase ad-hoc installs immediately but only on UDID-registered devices.
They share the certificate and signing mechanics — most repos want
Firebase for the day-to-day loop and this as the wider-audience channel.

**Prerequisites:** working simulator CI (`ios-ci-setup`), and the
signing-xcconfig mechanism from `ios-firebase-distribution` Step 2 (empty
`Signing.xcconfig` attached to the app target only). If Firebase
distribution is already set up, secrets `IOS_DIST_CERT_P12_BASE64`,
`IOS_DIST_CERT_P12_PASSWORD`, and `APPLE_TEAM_ID` already exist and are
reused — the same Apple Distribution certificate signs both channels.

## Step 1 — Walk the user through the one-time setup

Beyond the certificate/team-ID assets above (see the
`ios-firebase-distribution` skill for how those are produced):

1. **App Store provisioning profile**: developer.apple.com → Profiles →
   `+` → **App Store** → App ID + the distribution cert (no device list)
   → download. → secret `IOS_APPSTORE_PROFILE_BASE64`
   (`base64 -i appstore.mobileprovision | pbcopy`).
2. **App record**: appstoreconnect.apple.com → My Apps → `+` → New App →
   select the bundle ID. Uploads fail without a record to attach to.
3. **ASC API key**: Users and Access → Integrations → App Store Connect
   API → Team Keys → `+`, role **App Manager**. Download the `.p8`
   (single chance). Secrets:
   - `ASC_API_KEY_ID` — Key ID
   - `ASC_API_ISSUER_ID` — Issuer ID (shown above the key list)
   - `ASC_API_KEY_P8_BASE64` — `base64 -i AuthKey_XXXX.p8 | pbcopy`
4. TestFlight tab → add **internal testers** (App Store Connect team
   members; no review for their builds; the first build and any external
   testers go through beta review).

## Step 2 — Pre-flight the app configuration

Check and fix in the repo before the first run — these fail late (in
Apple's processing), so catching them now saves a full cycle:

- **Info.plist has `ITSAppUsesNonExemptEncryption`** (`false` for
  HTTPS-only apps); otherwise every build blocks on a manual export
  compliance question.
- **Complete app icon** in the asset catalog (with a hand-written
  Info.plist, `ASSETCATALOG_COMPILER_APPICON_NAME` must be set) —
  TestFlight processing rejects missing icons that ad-hoc installs
  tolerate.
- **`MARKETING_VERSION`** (CFBundleShortVersionString) is set and sane;
  the build number is handled by the workflow (next step).

## Step 3 — Instantiate the workflow

Copy `templates/ios-testflight.yml` to
`.github/workflows/ios-testflight.yml`, substituting `__IOS_DIR__`,
`__PROJECT_NAME__`, `__SCHEME__`, `__BUNDLE_ID__`, `__RUNNER_IMAGE__`,
`__XCODE_MAJOR__` — same values as the sibling workflows.

Mechanics preserved from the ad-hoc workflow, plus three TestFlight
specifics baked into the template:

- **Unique build numbers**: the CI-written `Signing.xcconfig` adds
  `CURRENT_PROJECT_VERSION = $GITHUB_RUN_NUMBER`. TestFlight rejects a
  build number it has already seen for that version; run_number is
  unique, monotonic, and traceable to the run with no state to store.
- **Export method `app-store-connect`** (Xcode 15.4+ name for
  `app-store`).
- **`destination: upload`**: export and upload are one `xcodebuild`
  step authenticated by the API key; no IPA on disk, no separate upload
  tool.

## Step 4 — Verify end to end

1. Run from the Actions tab. The export step's success means Apple
   accepted the binary — but the build then sits in **processing**
   (minutes to hours; not visible in the workflow).
2. Check App Store Connect → TestFlight: build appears, then finishes
   processing. First build may prompt for export compliance if Step 2's
   Info.plist key is missing.
3. Assign the build to internal testers; confirm a tester's phone gets
   the TestFlight notification and the app installs and launches. That's
   the done criterion.

Upload rejections worth knowing: "bundle version must be higher / already
used" → the run-number mechanism is missing or the xcconfig isn't
attached to the app target; authentication errors → check the three ASC
secrets (the `.p8` must be base64'd exactly once); "No suitable
application records found" → Step 1.2 skipped.
