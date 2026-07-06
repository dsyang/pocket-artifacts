---
name: ios-ci-setup
description: Set up GitHub Actions CI for an iOS app — simulator build + test on every push, no signing, no Mac needed for development. Use when adding CI to an iOS repo, adopting XcodeGen, or when the user wants the "CI is the compiler" Xcode-less workflow. Works with XcodeGen project.yml or a checked-in .xcodeproj.
---

# iOS CI setup: simulator build + test on every push

Give an iOS repo a fast verification loop: every push that touches iOS
code compiles the app and runs the test suite on an iPhone simulator in
GitHub Actions. After this, a green check means "compiles and tests pass"
— which makes the repo fully developable from environments with no Xcode
(Linux, remote agents), using CI as the only compiler.

Template: [`templates/ios-build.yml`](templates/ios-build.yml). Deep
explanation of every decision: [`01-xcodeless-development.md`](../../01-xcodeless-development.md)
and [`02-build-and-test.md`](../../02-build-and-test.md) in the playbook
this skill ships with (`docs/cicd/` in the pocket-artifacts repo).

## Step 1 — Survey the repo

Find and record:

- **Project layout**: where is the `.xcodeproj`/`project.yml`? (Below,
  `__IOS_DIR__` is that directory — often `ios/` or the repo root.)
- **XcodeGen or checked-in project?** `project.yml` present → XcodeGen.
  Only `.xcodeproj` → checked-in (workflow still works; skip the xcodegen
  bits, see Step 3).
- **Scheme name** (`__SCHEME__`): from `project.yml` targets, or
  `.xcodeproj/xcshareddata/xcschemes/*.xcscheme`. The scheme must be
  shared and must have test targets attached, or `xcodebuild test` finds
  nothing.
- **Does the project use Swift macros or SPM plugins?** (TCA,
  swift-dependencies, GRDB, swift-syntax anywhere in the dependency
  graph → yes.) Affects flags in Step 3.
- **Branch naming**: which branches should trigger CI (default branch +
  any bot/session prefix like `claude/**`).

## Step 2 — Pick the runner pin and Xcode major

Pin a concrete macOS runner image (e.g. `macos-26`) — never
`macos-latest`. Check the project's minimum deployment target and Swift
features against the Xcode versions on that image
(github.com/actions/runner-images lists them). Record the Xcode major
(`__XCODE_MAJOR__`, e.g. `26`) — the workflow selects the newest
`Xcode_<major>*` on the image via `sort -V`, so point releases float but
majors never surprise you.

Rationale to preserve in the workflow's comments: with CI as the only
compiler, a floating alias flipping images breaks builds with no repo
change to explain it; runner bumps must be deliberate isolated commits.

## Step 3 — Instantiate the template

Copy `templates/ios-build.yml` to `.github/workflows/ios-build.yml` and
substitute:

| Placeholder | Value |
| --- | --- |
| `__IOS_DIR__` | iOS directory relative to repo root (no trailing slash), e.g. `ios` |
| `__PROJECT_NAME__` | Xcode project basename, e.g. `PocketArtifacts` |
| `__SCHEME__` | scheme to test |
| `__RUNNER_IMAGE__` | pinned runner image, e.g. `macos-26` — never `macos-latest` |
| `__XCODE_MAJOR__` | pinned Xcode major available on that image, e.g. `26` (note: image version ≠ Xcode major in general; check the image's toolchain list) |
| `__SIMULATOR_NAME__` | e.g. `iPhone 17` — must exist on the pinned image; if unsure, guess, then correct from the workflow's "List available simulators" output on the first run |
| `__BRANCHES__` | trigger branches list |

Adaptations:

- **Checked-in `.xcodeproj`** (no XcodeGen): delete the "Generate Xcode
  project" step and drop `xcodegen` from the brew install.
- **Workspace/CocoaPods**: use `-workspace X.xcworkspace` instead of
  `-project`, and add `pod install` before building.
- **No macros/plugins anywhere in the graph**: `-skipMacroValidation
  -skipPackagePluginValidation` are harmless to keep; keep them.
- **App with UI tests**: keep them out of the default scheme's test plan
  or this job gets slow; give them their own job/step later.

Do **not** remove: `set -o pipefail` (without it failures go green
through the xcbeautify pipe), `CODE_SIGNING_ALLOWED=NO`,
`ENABLE_DEBUG_DYLIB=NO` (SwiftUI-previews dylib fails linking SPM
package-product frameworks in CI), the path filter, or the concurrency
group.

## Step 4 — If adopting XcodeGen in a repo that doesn't have it

Optional but recommended (plain-text project, no pbxproj conflicts):

1. `brew install xcodegen` locally isn't required — write `project.yml`
   by hand mirroring the existing targets (name, platform, deployment
   target, sources globs, SPM packages, Info.plist path, bundle ID,
   scheme with testTargets).
2. **Declare every directly-imported SPM product explicitly** on both app
   and test targets — including modules reached through `@_exported`
   re-exports. When app + tests both link a package, products build as
   dynamic frameworks and autolinking cannot resolve undeclared products.
3. Gitignore the generated project: `__IOS_DIR__/*.xcodeproj`, then
   `git rm -r --cached` the old one.
4. Add a README note: `brew install xcodegen && cd __IOS_DIR__ &&
   xcodegen generate && open *.xcodeproj`.

## Step 5 — Verify

Push to a triggering branch (or `workflow_dispatch`) and iterate until
green. First-run failure triage:

- Destination not found → read the job's "List available simulators"
  output, fix `__SIMULATOR_NAME__`.
- Undefined symbols / "no such module" for transitively-imported modules
  → add the missing explicit product dependency in `project.yml` (Step 4
  point 2).
- Hang at macro validation → the skip flags are missing.
- Scheme not found → scheme isn't shared / wrong name; for XcodeGen check
  the `scheme:` block in `project.yml`.

## Companion skills

Once this is green, `ios-firebase-distribution` adds signed device builds
delivered to phones, and `ios-testflight` adds the TestFlight channel.
Both reuse this skill's runner pin and Xcode selection step verbatim.
