---
name: ios-firebase-distribution
description: Set up signed ad-hoc iOS builds from GitHub Actions delivered to physical iPhones via Firebase App Distribution — manual signing with repo secrets, no fastlane, no Apple review or processing queue. Use when the user wants device/phone builds from CI, "install on my iPhone", beta distribution, or Firebase App Distribution setup.
---

# Firebase App Distribution from GitHub Actions

Add a manually-triggered workflow that archives the app, signs it with an
ad-hoc distribution profile (secrets-based manual signing — no fastlane
match, no signing repo), exports an IPA, and uploads it to Firebase App
Distribution. Testers install by tapping a link ~1 minute after upload —
no Apple review, no TestFlight processing queue.

Templates: [`templates/ios-distribute.yml`](templates/ios-distribute.yml),
[`templates/Signing.xcconfig`](templates/Signing.xcconfig). Deep dive:
`docs/cicd/03-code-signing.md` and `docs/cicd/04-firebase-distribution.md`
in the pocket-artifacts repo.

**Prerequisite:** working simulator CI (the `ios-ci-setup` skill) — get
builds green before adding signing to the mix. Reuse its exact runner pin
and Xcode-selection step here.

**Known constraint to tell the user upfront:** ad-hoc profiles install
only on iPhones whose UDIDs are registered in the Apple Developer portal
and baked into the profile (max 100/yr). For UDID-less testers, use the
`ios-testflight` skill instead/additionally.

## Step 1 — Walk the user through the one-time human setup

CI cannot do this part; it needs a browser, a Mac (for the CSR/.p12), and
the user's Apple/Google accounts. Give them this checklist and the exact
secret names, then wait for confirmation that all six secrets exist.

**Apple** (developer.apple.com; Program membership $99/yr required):

1. Keychain Access → Certificate Assistant → Request a Certificate From a
   Certificate Authority → save CSR.
2. Certificates → `+` → **Apple Distribution** → upload CSR → download
   `.cer` → double-click to install.
3. Keychain Access: select the certificate **and its private key** →
   Export 2 items → `.p12` with a password. (Cert-only export is the
   classic failure — the identity won't be found in CI.)
4. Identifiers → register the App ID (exact bundle ID).
5. Devices → `+` → register each test iPhone's UDID.
6. Profiles → `+` → **Ad Hoc** → App ID + cert + devices → download.

**Firebase** (console.firebase.google.com; free):

7. Create/reuse a project → add an **iOS app** with the exact bundle ID
   (no GoogleService-Info.plist needed in the app — App Distribution only
   delivers binaries). Copy the App ID (`1:…:ios:…`).
8. App Distribution → Get started → create tester group (note its alias,
   e.g. `testers`) → add tester emails.
9. Project settings → Service accounts → manage in Cloud console → create
   a service account with role **Firebase App Distribution Admin** → add
   a JSON key → download.

**GitHub secrets** (repo → Settings → Secrets and variables → Actions):

| Secret | Value |
| --- | --- |
| `IOS_DIST_CERT_P12_BASE64` | `base64 -i dist.p12 \| pbcopy` |
| `IOS_DIST_CERT_P12_PASSWORD` | the .p12 export password |
| `IOS_ADHOC_PROFILE_BASE64` | `base64 -i adhoc.mobileprovision \| pbcopy` |
| `APPLE_TEAM_ID` | 10-char team ID (portal → Membership) |
| `FIREBASE_APP_ID` | from step 7 |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | entire JSON from step 9 |

## Step 2 — Scope signing to the app target via xcconfig

**Critical mechanism — do not pass signing settings as `xcodebuild`
arguments.** Command-line build settings are global, and SPM package/macro
targets *reject* provisioning profiles, failing the archive with baffling
errors.

1. Add `templates/Signing.xcconfig` (intentionally empty) to the iOS
   directory, committed.
2. Attach it to **only the app target**:
   - XcodeGen — in `project.yml`:
     ```yaml
     targets:
       <AppTarget>:
         configFiles:
           Debug: Signing.xcconfig
           Release: Signing.xcconfig
     ```
   - Checked-in `.xcodeproj`: set the file as the app target's base
     configuration for both configurations (project editor → Info tab),
     commit.
3. Simulator CI keeps working (empty file = no signing settings); the
   distribute workflow overwrites the file at build time with manual
   signing settings, then generates/builds.

## Step 3 — Instantiate the workflow

Copy `templates/ios-distribute.yml` to
`.github/workflows/ios-distribute.yml`, substituting:

| Placeholder | Value |
| --- | --- |
| `__IOS_DIR__` | iOS directory, e.g. `ios` |
| `__PROJECT_NAME__` | project basename |
| `__SCHEME__` | scheme to archive |
| `__BUNDLE_ID__` | app bundle identifier (keys the provisioningProfiles dict) |
| `__RUNNER_IMAGE__`, `__XCODE_MAJOR__` | same values as ios-build.yml |
| `__TESTER_GROUP__` | Firebase group alias from Step 1.8, e.g. `testers` |

Adaptations: checked-in `.xcodeproj` → drop the xcodegen step;
workspace → `-workspace` on the archive step. Keep manual-only
`workflow_dispatch` (each run costs ~15–25 macOS-runner minutes) unless
the user asks for push-triggered distribution.

Do **not** simplify away: the ephemeral keychain's
`set-key-partition-list` (without it codesign hangs forever waiting for a
GUI prompt), copying the profile to both directories, deriving
`PROFILE_NAME` from the profile itself (profile rotation then never needs
a workflow edit), `set -o pipefail`, or the export method name
`release-testing` (Xcode 15.4+ name for ad-hoc).

## Step 4 — Verify end to end

1. Run from the Actions tab. Watch the "Import signing assets" step:
   `security find-identity` must print exactly one
   `Apple Distribution: …` identity — zero means the .p12 lacks the
   private key (Step 1.3).
2. Archive/export failures: almost always profile↔cert↔bundle-ID
   mismatch; the workflow logs the decoded profile name and UUID —
   compare against the portal.
3. The IPA is also attached as a workflow artifact (14-day retention) for
   debugging independent of Firebase.
4. Confirm with the user: invite email received → profile installed →
   app launches on the phone. That physical-install confirmation is the
   done criterion, not the green workflow.

## Troubleshooting index

Symptom → fix table lives in `docs/cicd/06-gotchas.md` (pocket-artifacts).
Highlights: hang at codesign → partition list; "No profiles found" →
name/UUID/location checklist; tester can't install → UDID not in profile
(regenerate profile, update secret).
