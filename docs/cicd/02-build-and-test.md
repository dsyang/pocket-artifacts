# 02 — The build & test workflow (`ios-build.yml`)

The fast loop: every push that touches iOS code compiles the app and runs
the whole test suite on an iPhone simulator. No signing, no artifacts —
just the answer to "does it build and pass?" The live workflow is
[`.github/workflows/ios-build.yml`](../../.github/workflows/ios-build.yml);
this doc explains each decision so you can re-create it elsewhere.

## Triggers: don't burn macOS minutes on docs pushes

```yaml
on:
  push:
    branches: [main, "claude/**"]
    paths:
      - "ios/**"
      - ".github/workflows/ios-build.yml"
  workflow_dispatch:
```

- **Path-filtered** to the iOS tree *and the workflow file itself* (a
  workflow edit must trigger a run that exercises it). macOS runners bill
  at 10× Linux; docs-only pushes shouldn't spend that.
- **Branch-filtered** to main plus the bot/session branch prefix. Adjust
  the prefix to whatever your agent or team uses.
- `workflow_dispatch` for manual re-runs from the Actions tab.

```yaml
concurrency:
  group: ios-build-${{ github.ref }}
  cancel-in-progress: true
```

Rapid pushes to the same branch cancel the stale run — with CI as the
compiler you push often, and only the latest result matters.

## The job, step by step

```yaml
runs-on: macos-26        # pinned — see doc 01
timeout-minutes: 60
```

1. **Checkout.** `actions/checkout@v4`.

2. **Select the newest Xcode of the pinned major** (see
   [doc 01](01-xcodeless-development.md) for the rationale):

   ```bash
   XCODE_APP="$(ls -d /Applications/Xcode_26*.app | sort -V | tail -1)"
   sudo xcode-select -s "$XCODE_APP/Contents/Developer"
   xcodebuild -version
   ```

3. **Install tools:** `brew install xcodegen xcbeautify`. Both are small;
   installation is fast enough that caching isn't worth the complexity.

4. **Generate the project:** `xcodegen generate` in the iOS directory.
   (Skip if your repo checks in its `.xcodeproj`.)

5. **List simulators** (`xcrun simctl list devices available | head -40`) —
   costs nothing and is the first thing you need when a destination stops
   resolving after an image update.

6. **Build and test:**

   ```bash
   set -o pipefail
   xcodebuild test \
     -project ios/PocketArtifacts.xcodeproj \
     -scheme PocketArtifacts \
     -destination 'platform=iOS Simulator,name=iPhone 17' \
     -skipMacroValidation \
     -skipPackagePluginValidation \
     CODE_SIGNING_ALLOWED=NO \
     ENABLE_DEBUG_DYLIB=NO \
     2>&1 | xcbeautify --renderer github-actions
   ```

Every flag is load-bearing:

| Flag | Why |
| --- | --- |
| `set -o pipefail` | Without it, the pipe into xcbeautify swallows xcodebuild's exit code and failures go green. |
| `-destination name=iPhone 17` | A device *name* present on the pinned image. Names are stabler than OS-versioned destinations across minor image updates. |
| `-skipMacroValidation` | Swift macros (swift-syntax — TCA, swift-dependencies, GRDB use them) otherwise require interactive trust approval, which hangs headless CI. |
| `-skipPackagePluginValidation` | Same, for SPM build plugins. |
| `CODE_SIGNING_ALLOWED=NO` | Simulator builds need no signing; without this, xcodebuild may try to find an identity and fail on a bare runner. |
| `ENABLE_DEBUG_DYLIB=NO` | The SwiftUI-previews debug dylib fails to link against SPM package-product frameworks (undefined symbols from transitive products). Previews don't exist in CI, so turn the mechanism off. See [gotchas](06-gotchas.md). |
| `xcbeautify --renderer github-actions` | Compiler errors and test failures become inline PR annotations — essential when the Actions log is your only compiler output. |

Note the scheme comes from `project.yml`'s `scheme.testTargets`, so
`xcodebuild test` runs unit + integration suites in one invocation.

## Applying to another repo

Copy the workflow, then substitute: project path, scheme name, simulator
device name (run once and read the "List available simulators" output if
unsure), branch prefixes, and path filters. The
[`ios-ci-setup`](../../.claude/skills/ios-ci-setup/SKILL.md) skill walks
through exactly this.
