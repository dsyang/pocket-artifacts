# 05 — TestFlight: the secondary channel

> **Status in this repo:** designed (see `docs/PLAN.md` §8) but not yet
> instantiated — there is no `.github/workflows/ios-testflight.yml` here
> today. This doc + the [`ios-testflight`](skills/ios-testflight/SKILL.md)
> skill contain the complete ready-to-apply workflow; drop it into this
> repo or any other when the channel is needed.

## When TestFlight instead of Firebase

| | Firebase (ad-hoc) — [doc 04](04-firebase-distribution.md) | TestFlight |
| --- | --- | --- |
| Install latency | ~immediate after upload | Apple processing queue (minutes–hours) |
| Review | none | none for internal testers; first build + external testers reviewed |
| Tester devices | UDIDs registered in profile (≤100 iPhones) | any device, no UDID management |
| Tester cap | profile device limit | 100 internal / 10,000 external |
| Extra assets | Firebase project + service account | App Store profile + ASC API key |

Rule of thumb: Firebase for the tight build-try-fix loop with yourself and
teammates; TestFlight when you need to hand the app to people whose UDIDs
you'll never collect. Both workflows share the same certificate, archive
step, and signing mechanics, so running both is cheap.

## One-time setup beyond doc 03

1. **App Store provisioning profile** (doc 03 step 4, the App Store
   variant — same certificate, no device list) →
   `IOS_APPSTORE_PROFILE_BASE64` secret.
2. **App Store Connect app record**: [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
   → My Apps → `+` → New App → pick the bundle ID. Uploads fail without an
   app record to attach to.
3. **App Store Connect API key**: Users and Access → Integrations → App
   Store Connect API → Team Keys → `+`, role **App Manager**. Download the
   `.p8` (one chance only). Secrets:
   - `ASC_API_KEY_ID` — the Key ID
   - `ASC_API_ISSUER_ID` — the Issuer ID shown above the key list
   - `ASC_API_KEY_P8_BASE64` — `base64 -i AuthKey_XXXX.p8 | pbcopy`
4. In App Store Connect → TestFlight, add internal testers (members of
   your team; they get builds with no review).

## The workflow

Full template: [`skills/ios-testflight/templates/ios-testflight.yml`](skills/ios-testflight/templates/ios-testflight.yml).
It is `ios-distribute.yml` with three substitutions:

### 1. App Store profile + unique build numbers

Same keychain/profile/xcconfig dance as [doc 03](03-code-signing.md), with
the App Store profile secret — and one addition to the generated
`Signing.xcconfig`:

```
CURRENT_PROJECT_VERSION = $GITHUB_RUN_NUMBER
```

TestFlight **rejects an upload whose build number (CFBundleVersion) it has
seen before** for that version. `github.run_number` increments per
workflow run, giving unique, monotonic, traceable build numbers with no
state to store. (Firebase has no such constraint, which is why
`ios-distribute.yml` doesn't bother.)

### 2. Export method

```xml
<key>method</key>      <string>app-store-connect</string>
```

(`app-store-connect` is the Xcode 15.4+ name for the old `app-store`
method, same rename family as `ad-hoc` → `release-testing`.)

### 3. Upload via xcodebuild + ASC API key — no fastlane, no altool

The consistent-with-this-setup upload path is `xcodebuild -exportArchive`
itself, with `destination: upload` in the plist:

```xml
<key>destination</key> <string>upload</string>
```

```bash
echo -n "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$RUNNER_TEMP/AuthKey.p8"
xcodebuild -exportArchive \
  -archivePath "$RUNNER_TEMP/App.xcarchive" \
  -exportOptionsPlist "$RUNNER_TEMP/ExportOptions.plist" \
  -authenticationKeyPath "$RUNNER_TEMP/AuthKey.p8" \
  -authenticationKeyID "$ASC_API_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_API_ISSUER_ID" \
  2>&1 | xcbeautify --renderer github-actions
```

With `destination: upload`, export and upload are one step — no IPA lands
on disk and no separate `altool`/Transporter invocation is needed
(`altool` upload is deprecated anyway). The API key means no Apple ID
password, no 2FA, no session cookies in CI.

After upload, the build appears in App Store Connect → TestFlight once
Apple's processing finishes; internal testers are notified automatically
if assigned to the build group.

Two ITC gotchas the template pre-empts:

- `ITSAppUsesNonExemptEncryption` should be set (`false` for
  HTTPS-only apps) in Info.plist, or every build waits on a manual export
  compliance question before testers can install.
- The app icon must be a full asset catalog entry — TestFlight processing
  rejects builds with missing icons that ad-hoc installs tolerate.
