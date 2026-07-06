# 03 — Code signing in CI, without fastlane

Device builds must be signed. This repo does manual signing with raw
`security` commands and repo secrets — no fastlane match, no signing repo,
no shared encryption passphrase. It's ~40 lines of shell you can read in
one sitting ([`ios-distribute.yml`](../../.github/workflows/ios-distribute.yml),
"Import signing assets" step).

There are two halves: a **one-time human setup** producing the assets, and
a **per-build CI dance** consuming them.

## One-time human setup (needs a Mac + browser, ~30 minutes)

Prerequisite: an [Apple Developer Program](https://developer.apple.com/programs/)
membership ($99/yr — required for *any* device distribution).

1. **Create a distribution certificate.**
   - On a Mac: Keychain Access → Certificate Assistant → *Request a
     Certificate From a Certificate Authority…* → save the CSR to disk.
   - [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
     → `+` → **Apple Distribution** → upload the CSR → download the `.cer`
     → double-click to install it into the login keychain.
   - In Keychain Access, expand the certificate to show its private key,
     select **both**, right-click → *Export 2 items…* → save as `.p12`
     with a password you choose. (Exporting only the cert, without the
     key, is the classic mistake — the `.p12` must contain both.)

2. **Register an App ID** for your bundle identifier (Identifiers → `+` →
   App IDs), if not already done.

3. **Register test-device UDIDs** (Devices → `+`). Needed for ad-hoc
   profiles only; get the UDID from Finder (device page, click the
   subtitle line) or Settings → General → About on newer iOS.

4. **Create provisioning profiles** (Profiles → `+`):
   - **Ad Hoc** profile (App ID + distribution cert + the devices) — for
     Firebase App Distribution, [doc 04](04-firebase-distribution.md).
   - **App Store** profile (App ID + distribution cert, no devices) — for
     TestFlight, [doc 05](05-testflight.md). The same certificate serves
     both profiles.
   Download the `.mobileprovision` files.

5. **Store everything as GitHub Actions repo secrets** (Settings →
   Secrets and variables → Actions):

   ```sh
   base64 -i dist.p12 | pbcopy                # → IOS_DIST_CERT_P12_BASE64
   # the export password you chose            # → IOS_DIST_CERT_P12_PASSWORD
   base64 -i adhoc.mobileprovision | pbcopy   # → IOS_ADHOC_PROFILE_BASE64
   base64 -i appstore.mobileprovision | pbcopy # → IOS_APPSTORE_PROFILE_BASE64 (TestFlight only)
   # 10-char team ID from the portal          # → APPLE_TEAM_ID
   ```

Renewals: the certificate lasts 1 year, profiles 1 year, and profiles die
with their certificate. When builds start failing with signing errors
around the anniversary, re-do steps 1/4/5.

## Per-build CI dance

### 1. Ephemeral keychain

The runner is a fresh VM; the cert must be importable and usable by
`codesign` without any UI prompt:

```bash
KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$RUNNER_TEMP/dist.p12" \
  -k "$KEYCHAIN_PATH" -P "$IOS_DIST_CERT_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" > /dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db
security find-identity -v -p codesigning "$KEYCHAIN_PATH"
```

The non-obvious line is `set-key-partition-list`: without it, macOS blocks
codesign's first use of the key behind a GUI password prompt that a
headless runner can never answer — the build just hangs. The final
`find-identity` is your smoke test; it must list exactly the identity the
build will request (`Apple Distribution: …`).

### 2. Install the provisioning profile where Xcode looks

```bash
security cms -D -i "$RUNNER_TEMP/profile.mobileprovision" > "$RUNNER_TEMP/profile.plist"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$RUNNER_TEMP/profile.plist")"
PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$RUNNER_TEMP/profile.plist")"
for DIR in \
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
  "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  mkdir -p "$DIR"
  cp "$RUNNER_TEMP/profile.mobileprovision" "$DIR/$PROFILE_UUID.mobileprovision"
done
echo "PROFILE_NAME=$PROFILE_NAME" >> "$GITHUB_ENV"
```

The profile's *name* is read out of the profile itself (via
`security cms -D`, which decodes the CMS wrapper) rather than hardcoded,
and exported for later steps — so replacing the profile secret never
requires a workflow edit. It's copied to **both** the modern and legacy
directories because different Xcode/tooling versions look in different
places.

### 3. Inject signing settings through an xcconfig — not xcodebuild args

**This is the trap that costs people days.** Passing
`PROVISIONING_PROFILE_SPECIFIER=…` as an `xcodebuild` argument applies it
to *every* target in the build graph — including SPM package and macro
targets, which **reject provisioning profiles** and fail the build with
baffling errors.

Instead, the repo contains a committed-but-empty
[`ios/Signing.xcconfig`](../../ios/Signing.xcconfig) attached to **only
the app target** in `project.yml`:

```yaml
targets:
  PocketArtifacts:
    configFiles:
      Debug: Signing.xcconfig
      Release: Signing.xcconfig
```

Simulator/test builds use it empty. The distribution workflow overwrites
it before generating the project:

```bash
cat > ios/Signing.xcconfig <<EOF
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM = $APPLE_TEAM_ID
CODE_SIGN_IDENTITY = Apple Distribution
PROVISIONING_PROFILE_SPECIFIER = $PROFILE_NAME
EOF
```

Signing settings reach exactly one target; SPM targets never see them.
(With a checked-in `.xcodeproj` instead of XcodeGen, achieve the same by
setting the xcconfig as the app target's base configuration in Xcode once,
and committing the empty file.)

## Security posture

- Secrets never touch the repo; base64 blobs are decoded into
  `$RUNNER_TEMP`, which is destroyed with the ephemeral VM.
- The keychain password is a per-run `uuidgen` value that is never stored.
- The keychain auto-locks after 6h (`-lut 21600`) as a backstop; jobs
  timeout at 60 minutes anyway.
- Rotation = replace the secrets; nothing in git history to scrub.
