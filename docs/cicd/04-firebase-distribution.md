# 04 — Firebase App Distribution: phone builds in ~1 minute

The default way a build gets onto a physical iPhone. An ad-hoc signed IPA
is uploaded to [Firebase App Distribution](https://firebase.google.com/docs/app-distribution);
testers get a link in the Firebase App Tester flow and the build installs
**immediately** — no Apple review, no processing queue. (TestFlight
internal testing skips review but every build still sits in Apple's
processing queue; that's why Firebase is the day-to-day channel and
TestFlight the secondary one — see [doc 05](05-testflight.md).)

Live workflow: [`.github/workflows/ios-distribute.yml`](../../.github/workflows/ios-distribute.yml).

Costs: Firebase App Distribution is free; the Apple Developer Program
($99/yr) is required regardless for any device distribution.

Constraint to know upfront: **ad-hoc profiles only install on devices
whose UDIDs are registered** in the Apple Developer portal and included in
the profile (max 100 iPhones/yr). Perfect for a personal project or small
team; for UDID-less external testers, use the TestFlight channel.

## One-time Firebase setup (browser, ~15 minutes)

1. [console.firebase.google.com](https://console.firebase.google.com) →
   create a project (or reuse one; no Google Analytics needed).
2. Add an **iOS app** with your exact bundle ID. You do **not** need to
   add the GoogleService-Info.plist to the app — App Distribution only
   delivers the binary. Copy the **App ID** (`1:1234567890:ios:abc…`) from
   Project settings → General → `FIREBASE_APP_ID` secret.
3. Release & Monitor → App Distribution → click **Get started**, then
   create a tester **group** with alias `testers` (or your own alias —
   must match `--groups` in the workflow) and add tester emails.
4. Create a **service account** for CI: Project settings → Service
   accounts → *Manage service account permissions* (Cloud console) →
   create a service account with role **Firebase App Distribution Admin**
   → Keys → create a JSON key. Paste the whole JSON into the
   `FIREBASE_SERVICE_ACCOUNT_JSON` secret.

Plus the Apple-side assets and secrets from [doc 03](03-code-signing.md):
`IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_P12_PASSWORD`,
`IOS_ADHOC_PROFILE_BASE64`, `APPLE_TEAM_ID`.

## The workflow, step by step

Trigger is **manual-only** (`workflow_dispatch`): device builds are wanted
deliberately ("I want to try this on my phone"), not on every push — each
run costs ~15–25 macOS-runner minutes. `cancel-in-progress: false` so a
running distribution isn't killed halfway through an upload.

1. **Checkout, select Xcode, install tools** — identical to
   [doc 02](02-build-and-test.md).
2. **Import signing assets** — the full dance from
   [doc 03](03-code-signing.md): ephemeral keychain, install the ad-hoc
   profile, write `Signing.xcconfig`, export `PROFILE_NAME`.
3. **`xcodegen generate`** — after the xcconfig is written, so the
   generated project picks it up.
4. **Archive:**

   ```bash
   xcodebuild archive \
     -project ios/PocketArtifacts.xcodeproj \
     -scheme PocketArtifacts \
     -destination 'generic/platform=iOS' \
     -archivePath "$RUNNER_TEMP/PocketArtifacts.xcarchive" \
     -skipMacroValidation -skipPackagePluginValidation \
     2>&1 | xcbeautify --renderer github-actions
   ```

   `generic/platform=iOS` builds for device without needing one attached.
   No signing overrides on the command line — it all flows from the
   xcconfig (doc 03 explains why).

5. **Export the ad-hoc IPA** with an ExportOptions.plist written inline:

   ```xml
   <key>method</key>            <string>release-testing</string>
   <key>signingStyle</key>      <string>manual</string>
   <key>teamID</key>            <string>${APPLE_TEAM_ID}</string>
   <key>signingCertificate</key><string>Apple Distribution</string>
   <key>provisioningProfiles</key>
   <dict>
     <key>your.bundle.id</key>  <string>${PROFILE_NAME}</string>
   </dict>
   ```

   `release-testing` is the modern (Xcode 15.4+) name for what used to be
   `ad-hoc` — the old name still works but warns. The `provisioningProfiles`
   dict maps bundle ID → profile *name* (the `PROFILE_NAME` env var
   extracted in step 2).

6. **Upload the IPA as a workflow artifact** (14-day retention) — a
   debugging escape hatch: if the Firebase upload fails or you want to
   inspect/re-sign the IPA, it's downloadable from the run page.

7. **Upload to Firebase:**

   ```bash
   npm install -g firebase-tools
   printf '%s' "$FIREBASE_SERVICE_ACCOUNT_JSON" > "$RUNNER_TEMP/firebase-sa.json"
   export GOOGLE_APPLICATION_CREDENTIALS="$RUNNER_TEMP/firebase-sa.json"
   firebase appdistribution:distribute "$IPA" \
     --app "$FIREBASE_APP_ID" \
     --groups "testers" \
     --release-notes "$(git log -1 --pretty=%s) ($(git rev-parse --short HEAD))"
   ```

   Auth is pure `GOOGLE_APPLICATION_CREDENTIALS` — no `firebase login`,
   no token refresh. Release notes are auto-derived from the commit so
   every build in the tester UI says what it contains.

## Tester experience

First build: invite email → accept → install the Firebase profile the
flow walks you through (this is how ad-hoc installs work, not a Firebase
oddity) → install the app. Subsequent builds: a push/email with an
Install button. From `workflow_dispatch` click to app-on-phone is
typically under 25 minutes, almost all of it the Xcode build itself.

## Applying to another repo

The [`ios-firebase-distribution`](../../.claude/skills/ios-firebase-distribution/SKILL.md)
skill contains the workflow as a template plus the checklist above. The
substitution points: project path, scheme, bundle ID, tester group alias,
and (if not using XcodeGen) how the signing xcconfig attaches to the app
target.
