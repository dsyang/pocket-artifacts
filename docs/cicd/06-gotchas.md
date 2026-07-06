# 06 — Gotchas: every non-obvious failure, in one place

Each of these was hit for real while building this setup (see
`docs/PLAN.md` "Deviations" for the history). Symptoms first, so this page
is greppable from an error message.

## Build & link

### Undefined symbols from the "PreviewsInjection" / debug dylib

**Symptom:** CI-only link failure of the app's *debug dylib* with
undefined symbols from transitive SPM products; local Xcode builds fine.

**Cause:** Xcode builds a SwiftUI-previews support dylib that fails to
link against SPM *package-product frameworks* (dynamic-framework case,
see next item).

**Fix:** `ENABLE_DEBUG_DYLIB=NO` on the CI `xcodebuild` invocation.
Previews aren't used in CI, so nothing is lost.

### "no such module" / autolinking failures for modules you never imported directly

**Symptom:** errors about `Dependencies`, `CasePaths`,
`IdentifiedCollections`, etc. — modules pulled in transitively (e.g.
through TCA's `@_exported` re-exports).

**Cause:** when the app target **and** the test target both link the same
SPM library, Xcode builds package products as **dynamic frameworks**, and
autolinking then cannot resolve products that aren't explicitly declared
on the target.

**Fix:** declare every directly-referenced module as an explicit product
dependency in `project.yml` — on both the app and test targets. If your
test code touches a submodule of a package (e.g. `FlyingSocks` inside
`FlyingFox`), declare that product too.

### Build hangs (or fails) at macro / plugin validation

**Symptom:** headless build stalls, or errors about untrusted macros
(swift-syntax macros: TCA, swift-dependencies, GRDB…).

**Fix:** `-skipMacroValidation -skipPackagePluginValidation` on every
`xcodebuild` invocation (test *and* archive).

### Toolchain breaks with no repo change

**Symptom:** yesterday's green commit fails today.

**Cause:** floating runner alias (`macos-latest`) moved to a new image —
new Xcode, new SDK, different simulator set.

**Fix:** pin the runner image; select Xcode by major version with
`ls -d /Applications/Xcode_<major>*.app | sort -V | tail -1`; bump the pin
in deliberate, isolated commits. ([Doc 01](01-xcodeless-development.md).)

### Simulator destination stops resolving

**Symptom:** `Unable to find a destination matching…` after a runner
image update.

**Fix:** keep the `xcrun simctl list devices available` step in the
workflow and pick a device name from its output. Prefer plain device
names (`iPhone 17`) over OS-pinned destinations.

## Signing

### SPM targets reject provisioning profiles

**Symptom:** archive fails with provisioning/signing errors on *package*
or *macro* targets you never asked to sign.

**Cause:** signing settings passed as `xcodebuild` command-line arguments
are global — every target in the graph gets them.

**Fix:** put signing settings in an xcconfig attached **only to the app
target** (committed empty, overwritten by CI). [Doc 03](03-code-signing.md)
has the full pattern.

### Build hangs at codesign

**Symptom:** archive step hangs forever at signing.

**Cause:** macOS wants an interactive password to let codesign use the
imported key.

**Fix:** `security set-key-partition-list -S apple-tool:,apple: -s -k …`
after `security import`. Also make sure the keychain is in the search
list (`security list-keychains -d user -s …`).

### Profile not found despite being installed

**Symptom:** `No profiles for '<bundle id>' were found`.

**Checklist:** profile copied to *both*
`~/Library/Developer/Xcode/UserData/Provisioning Profiles` and
`~/Library/MobileDevice/Provisioning Profiles`, filed under
`<UUID>.mobileprovision`; `PROVISIONING_PROFILE_SPECIFIER` uses the
profile **name** exactly as decoded from the profile; the profile's
certificate matches the imported `.p12`; the bundle ID in the profile
matches the target's.

### `.p12` imports but no identity is found

**Symptom:** `security find-identity -v -p codesigning` prints
`0 valid identities found`.

**Cause:** the `.p12` was exported with the certificate only — no private
key.

**Fix:** re-export from Keychain Access selecting the certificate *and*
its private key (two items).

### Export fails with a method warning/error

**Symptom:** complaints about the `method` in ExportOptions.plist.

**Fix:** Xcode 15.4 renamed methods: `ad-hoc` → `release-testing`,
`app-store` → `app-store-connect`. Use the new names on current Xcode.

## Distribution

### TestFlight rejects the upload: build number already used

**Fix:** `CURRENT_PROJECT_VERSION = $GITHUB_RUN_NUMBER` in the CI-written
xcconfig. ([Doc 05](05-testflight.md).)

### TestFlight build stuck on "Missing Compliance"

**Fix:** `ITSAppUsesNonExemptEncryption` → `false` in Info.plist (for
HTTPS-only apps).

### Firebase upload succeeds but tester can't install

**Cause:** the device UDID isn't in the ad-hoc profile.

**Fix:** register the UDID, regenerate the ad-hoc profile, update
`IOS_ADHOC_PROFILE_BASE64`, re-run. UDID gating is inherent to ad-hoc
signing; UDID-less testers are what TestFlight is for.

### CI goes green while the build actually failed

**Cause:** piping `xcodebuild` into a log formatter without
`set -o pipefail` — the pipeline reports the formatter's exit code.

**Fix:** `set -o pipefail` first in every piped build step.

## App/test configuration

### App icon missing or ignored

With a hand-written Info.plist (no `GENERATE_INFOPLIST_FILE`), set
`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` explicitly — Xcode won't
infer it. TestFlight processing hard-rejects missing icons.

### Localhost mock server unreachable in tests

**Symptom:** integration tests against an in-process HTTP server fail
with ATS errors.

**Fix:** `NSAppTransportSecurity` → `NSAllowsLocalNetworking: true` in
Info.plist — scoped to loopback only, not a blanket
`NSAllowsArbitraryLoads`.

### Docs pushes burn macOS minutes

**Fix:** `paths:` filter on the workflow (`ios/**` + the workflow file
itself). macOS runners cost 10× Linux.
