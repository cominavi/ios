# First-time iOS development setup

This guide is for a developer working on the `cominavi/ios` repository. A
normal app build does not require the ComiNavi server, collector, Cloudflare,
App Store Connect, or production credentials. Configure those capabilities
only when the work needs them.

## What you need before cloning

- A Mac supported by Xcode 26.6 or later.
- Xcode 26.6 or later with an iOS Simulator runtime installed.
- Git and Git LFS. Two bundled demo-catalog databases are stored with LFS.
- SSH access to `git@github.com:cominavi/ios.git`.
- Enough free space for Xcode, simulator runtimes, Swift packages, and derived
  data; a clean first build compiles a large dependency graph.

The app's deployment target is iOS 18, but the source also compiles guarded
iOS 26 APIs such as Liquid Glass button styles and navigation subtitles.
Consequently, an iOS 18 runtime alone is not a substitute for the current
Xcode SDK.

Install Git LFS before cloning if it is not already available:

```sh
brew install git-lfs
git lfs install
```

Clone the iOS repository directly. The parent directory does not need to be a
Git repository:

```sh
git clone git@github.com:cominavi/ios.git
cd ios
git lfs pull
git lfs fsck
```

`git lfs ls-files` should list the two C104 demo-catalog SQLite files. If they
remain small text pointer files, builds may succeed but demo data will fail at
runtime; rerun `git lfs pull` before debugging the app.

## Configure Xcode

1. Install Xcode 26.6 or later.
2. Launch Xcode once, accept the license, and let it install required
   components.
3. In **Xcode > Settings > Components**, install at least one iOS Simulator
   runtime. Keep an iOS 18 runtime when testing fallback UI and the latest
   runtime for normal iteration.
4. Select this Xcode for command-line builds. Replace the path if Xcode is
   installed elsewhere:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch
xcodebuild -version
xcrun simctl list devices available
```

The project uses Swift Package Manager and its resolved versions are checked in
at `ComiNavi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Resolve them once after cloning:

```sh
xcodebuild \
  -resolvePackageDependencies \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi
```

Do not update package versions as part of ordinary setup. A package update is a
separate source change and should be reviewed and tested as such.

## Make the first build

Open `ComiNavi.xcodeproj`, select the shared `ComiNavi` scheme, choose an iPhone
or iPad simulator, and run the app. The Debug scheme uses
`llc.mikunet.cominavi.debug`; simulator builds do not require code signing or
an Apple Developer account.

The equivalent command-line smoke build is independent of a specific simulator
name:

```sh
xcodebuild \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/ComiNaviDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

To run tests, first choose a device name from `xcrun simctl list devices
available`, then use it consistently:

```sh
COMINAVI_SIMULATOR='iPhone 17 Pro Max'

xcodebuild \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -destination "platform=iOS Simulator,name=${COMINAVI_SIMULATOR},OS=latest" \
  -derivedDataPath /tmp/ComiNaviDerivedData \
  test \
  -only-testing:ComiNaviTests
```

Substitute an available simulator name; the example is not a required device.
The sign-in and initial app surfaces can run without production access.

## Schemes and signing

| Scheme | Use | Service environment | Signing and credentials |
| --- | --- | --- | --- |
| `ComiNavi` | Normal development and unit/UI tests | Production Circle.ms and ComiNavi endpoints, with debug analytics delivery disabled | None for Simulator; MikuNet development-team access for a device |
| `ComiNavi-Staging` | Staging behavior and symbol-upload checks | Circle.ms testing configuration | MikuNet team access for a device; Sentry authentication is recommended |
| `ComiNavi-TestFlight` | Release archive and App Store Connect distribution | Production | MikuNet team, App Store Connect key, Fastlane, and Sentry authentication |

All targets use automatic signing and currently name team `F25GFFJL49`. To run
on a physical device, ask a team administrator to add the developer's Apple ID
and register the device if necessary. Sign in under **Xcode > Settings >
Accounts** and verify that Xcode can download the team's development
certificate and provisioning profile.

Do not commit a personal team or replacement bundle identifier to
`project.pbxproj`. Simulator development is the supported path while team
access is pending.

## Credential setup by capability

There is deliberately no single credentials bundle for every contributor.
Request the minimum access needed for the task.

### GitHub

An SSH key with repository access is required to clone and push. The GitHub CLI
is useful for pull requests and is required by the full operations doctor:

```sh
gh auth login --hostname github.com --git-protocol ssh
gh auth status --active --hostname github.com
```

The doctor defaults to the repository owner's `GalvinGao` login. A contributor
can identify their own expected account explicitly:

```sh
COMINAVI_GITHUB_LOGIN="$(gh api user --jq .login)" \
  Scripts/cominavi-ops doctor
```

The full doctor also checks release and sibling-repository operations, so it is
expected to fail for an iOS-only contributor who has not been granted those
capabilities. It is not required for the first simulator build.

### Circle.ms and authenticated ComiNavi features

Manual testing can use the normal login UI with a Circle.ms account that has
access to the required Comiket catalog. No Circle.ms client secret belongs in
this repository: the app contains only the public client ID, while the secret
and token exchange stay on the `cominavi.net` service.

For repeatable production-session tests, install the `agent-browser` command
and keep credentials in the parent ComiNavi workspace, outside the iOS Git
checkout. With the usual `<workspace>/ios` layout, the scripts use:

- `<workspace>/credentials.yaml`
- `<workspace>/.real-env/`

Create them with private permissions:

```sh
install -d -m 700 ../.real-env
umask 077
${EDITOR:-vi} ../credentials.yaml
chmod 600 ../credentials.yaml
```

Use this YAML shape without committing or pasting the real values into logs:

```yaml
circlems:
  email: developer@example.com
  password: replace-with-the-real-password
```

Issue and validate a session:

```sh
./Scripts/issue-real-environment-session.sh
```

The first successful browser login is retained in `.real-env` with mode `0600`,
so the password is normally not reread on later runs. To install the issued
session into a dedicated simulator Keychain, follow the opt-in command in the
root `README.md`. Never install an older saved refresh token over a session the
simulator has already rotated; export its successor with
`Scripts/export-real-environment-session.sh` first.

### App Store Connect and TestFlight

Only release maintainers need this setup. Install a maintained Ruby rather than
using macOS's system Ruby 2.6, then install the Bundler version recorded in
`Gemfile.lock` and the locked gems:

```sh
brew install ruby
export PATH="$(brew --prefix ruby)/bin:${PATH}"
ruby --version
gem install bundler -v 2.7.2
bundle _2.7.2_ install
```

Persist the Homebrew Ruby `bin` directory in the shell configuration if a new
terminal still reports Ruby 2.6. Fastlane itself is pinned to 2.232.2.

Obtain the ComiNavi App Store Connect API private key from a release
administrator. The default key ID and issuer ID are checked in; the private
key is not. Install the key at the default ignored path:

```sh
install -m 600 /secure/source/AuthKey_672X4QRBR9.p8 \
  fastlane/AuthKey_672X4QRBR9.p8
```

Alternatively, copy `fastlane/.env.example` to the ignored `fastlane/.env` and
set `ASC_KEY_FILEPATH` to an absolute protected path. Verify read-only access
before attempting a release:

```sh
FASTLANE_SKIP_UPDATE_CHECK=1 bundle exec fastlane ios asc_check
```

Use `ComiNavi-TestFlight` only for release work. The complete archive,
distribution, build-number, and external-testing procedures are in
`docs/testflight.md`.

### Sentry symbols

Debug simulator builds do not deliver Sentry events and need no Sentry
credentials. Staging device builds warn when symbol upload is unavailable;
TestFlight archives fail, intentionally, rather than shipping without symbols.

Release maintainers should install and authenticate the current Sentry CLI:

```sh
brew install getsentry/tools/sentry
sentry auth login
```

Sentry stores local authentication outside the repository. Xcode Cloud uses a
secret `SENTRY_AUTH_TOKEN`; never put it in a tracked file.

### Credentials that iOS-only development does not need

Cloudflare/Wrangler access, crawler LaunchAgents, server secrets, and collector
credentials are not prerequisites for app development. They appear in the
full `Scripts/cominavi-ops doctor` report because that command is an operational
workspace preflight. Do not request or configure them unless the work crosses
into those repositories or production operations.

## The implementation and iteration loop used in this repository

Previous ComiNavi implementation sessions repeatedly converged on this loop:

1. Start with `git status --short --branch` and preserve unrelated local work.
2. Read `CONTEXT.md` for domain language. Because the repository contains a
   `.codegraph` index, use `codegraph explore "<symbols or behavior>"` before
   broad text searches when tracing an existing feature.
3. Follow the behavior end to end: SwiftUI surface, model/store, networking or
   persistence boundary, and generated API contract where relevant.
4. Make the narrowest coherent change and add a focused regression test in
   `ComiNaviTests`. Use `ComiNaviUITests` for flows that truly require the app
   process and accessibility hierarchy.
5. Complete accessibility and localization in the same change. User-facing
   strings must have reviewed Japanese, Korean, Simplified Chinese, and
   Traditional Chinese entries in `ComiNavi/Localizable.xcstrings` or the
   feature-specific string catalog. Keep separate VoiceOver context when
   visible copy is intentionally shortened.
6. Run the smallest relevant test selection first, then the full unit target
   and a clean build in proportion to the change.
7. For visual changes, launch the affected iPhone and iPad layouts and inspect
   the real result. When matching supplied artwork or screenshots, measure the
   source pixels and encode the geometry in a regression test instead of
   estimating it.
8. Run `git diff --check`, inspect the final diff, and create a focused commit.
   Repository policy expects coherent incremental commits. Do not include
   unrelated working-tree changes.
9. For a pull request with UI changes, capture the changed screens and upload
   them with `gh attach`; put the attached images at the very top of the pull
   request description.

A focused test command has this shape:

```sh
xcodebuild \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -destination "platform=iOS Simulator,name=${COMINAVI_SIMULATOR},OS=latest" \
  -derivedDataPath /tmp/ComiNaviDerivedData \
  test \
  -only-testing:ComiNaviTests/MapCameraMathTests/testCompassAdvancesFromNorthToGridAndOtherwiseReturnsNorth
```

Replace the final test identifier with the affected class or method. It is
normal to report an unrelated full-suite failure separately when the focused
suite and build prove the changed behavior; do not hide it or misattribute it
to the change.

## Repository map

| Path | Responsibility |
| --- | --- |
| `ComiNavi/ComiNaviApp.swift`, `EntryView.swift`, `ContentView.swift` | App composition and the signed-in/catalog-independent roots |
| `ComiNavi/Features/` | Feature models and feature-specific screens |
| `ComiNavi/DataSource/` | Circle.ms catalog, local plan persistence, enrichment, and synchronization |
| `ComiNavi/Networking/` | Service sessions, OAuth, and app networking adapters |
| `Packages/CominaviAPIClient/` | Checked-in OpenAPI contract, generator configuration, and generated-client wrapper |
| `ComiNaviTests/` | Unit, integration, localization, contract, and opt-in real-environment tests |
| `ComiNaviUITests/` | End-to-end UI and accessibility-driven flows |
| `Scripts/` | Data preparation, production-session, acceptance, release, and operational helpers |
| `docs/` | Feature architecture, data provenance, operations, and release runbooks |

The iOS repository is independent of its parent directory. A sibling
`../server` checkout is needed only when changing the server contract,
regenerating cross-repository fixtures, running collaboration stress tooling,
or verifying the OpenAPI files byte for byte. Normal iOS work uses the checked-in
contract and does not require the server checkout.

When an API contract does change, regenerate it in the server repository, copy
`server/openapi/cominavi-openapi.json` byte for byte to
`Packages/CominaviAPIClient/Sources/CominaviAPIClient/openapi.json`, and run:

```sh
./Scripts/verify-openapi-contract-sync.sh
```

## Common first-run failures

| Symptom | Likely cause and fix |
| --- | --- |
| Demo catalog opens as invalid data | Git LFS objects were not downloaded. Run `git lfs pull` and `git lfs fsck`. |
| `Unable to discover any Simulator runtimes` or CoreSimulator connection errors | Finish Xcode's first launch, install a runtime, confirm `xcode-select -p`, then retry from a normal user session. A sandboxed terminal may not be able to reach CoreSimulator even when Xcode can. |
| Swift package resolution fails | Confirm network and GitHub access, then use Xcode's **File > Packages > Reset Package Caches** only after retrying the checked-in resolution. Do not delete `Package.resolved`. |
| Device signing cannot find a profile | The Apple ID lacks team `F25GFFJL49` access, the device is unregistered, or Xcode has not downloaded profiles. Simulator builds remain available without signing. |
| `bundle` asks for Bundler 2.7.2 while Ruby reports 2.6 | The shell is using macOS's obsolete system Ruby. Put the maintained Homebrew or version-managed Ruby first in `PATH`, then install Bundler 2.7.2. |
| `Scripts/cominavi-ops doctor` fails on ASC, Fastlane, Wrangler, or sibling repositories | The command is checking operational/release capabilities beyond normal iOS development. Configure only the capability needed for the task. |
| Real-environment script refuses a file mode | Set `credentials.yaml` and individual session files to `0600`, and `.real-env` to `0700`. Do not relax the script's checks. |

After the first simulator build and unit target pass, the machine is ready for
ordinary ComiNavi iOS implementation. Add device, live-account, or release
credentials only when a concrete task reaches that boundary.
