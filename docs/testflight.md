# TestFlight build

Use the shared `ComiNavi-TestFlight` scheme for internal distribution.

This configuration is release-optimized and uses the MikuNet-owned production
bundle identifier, `llc.mikunet.cominavi`. The legacy identifier
`net.cominavi.ComiNavi` is registered to another Apple Developer team and
cannot be used for this deployment. It connects to the Circle.ms production
OAuth and API services. The app contains only the public OAuth client ID; the
client secret is stored in the `cominavi.net` Worker and used there for code and
refresh-token exchange. The debug-only demo catalog mode is not compiled into
this build, and its bundled SQLite fixtures are excluded from the app. The
optional C108 crawl enrichment remains available to the live Circle.ms catalog;
there is no standalone crawl catalog mode.

## Fastlane

Fastlane is configured for App Store Connect API-key authentication, automatic
signing, local IPA builds, and internal or external TestFlight distribution.
Fastlane and its transitive dependencies are pinned by `Gemfile.lock`. The
checked-in configuration contains only the key ID and issuer ID. The private
`.p8` key is ignored by Git and must remain local.

Install the locked Ruby dependencies before running a lane:

```sh
bundle install
```

The checked-in lockfile uses Fastlane 2.232.2 and Bundler 2.7.2. The existing
Home Manager Fastlane package provides the same Fastlane version on this Mac.

The default key location is `fastlane/AuthKey_672X4QRBR9.p8`. Keep it readable
only by your account:

```sh
install -m 600 /path/to/AuthKey_672X4QRBR9.p8 fastlane/AuthKey_672X4QRBR9.p8
```

Verify that the credentials can access the ComiNavi app without changing App
Store Connect state:

```sh
FASTLANE_SKIP_UPDATE_CHECK=1 bundle exec fastlane ios asc_check
```

Build a signed archive and IPA without uploading it:

```sh
FASTLANE_SKIP_UPDATE_CHECK=1 bundle exec fastlane ios build_testflight
```

This lane uses `Configuration/FastlaneExportOptions.plist`, whose destination is
`export`. Its `app-store` method spelling is Fastlane 2.232 compatible; the
existing `Configuration/TestFlightExportOptions.plist` retains Xcode's newer
`app-store-connect` spelling and its `upload` destination for the manual
`xcodebuild -exportArchive` workflow below.

Build and upload the current version to internal TestFlight testing:

```sh
FASTLANE_SKIP_UPDATE_CHECK=1 bundle exec fastlane ios beta
```

To upload an existing IPA instead, set `IPA_PATH` and run `bundle exec fastlane
ios upload_ipa`. Set `CHANGELOG` to populate TestFlight's **What to Test** text.

Before external distribution, update both localized release-note files:

- `fastlane/testflight/what_to_test/ja.txt`
- `fastlane/testflight/what_to_test/en-US.txt`

Build the committed `main` snapshot in an isolated worktree, upload it, submit
it to the `External Beta` group, notify testers, and verify the resulting App
Store Connect state with the one-command publisher:

```sh
Scripts/publish-external-testflight.sh
```

Uncommitted files in the primary checkout are deliberately excluded. The
signed archive, IPA, and dSYM remain under `build/fastlane`. Set
`COMINAVI_ALLOW_NON_MAIN_RELEASE=1` only when intentionally releasing a
different branch. Lane options such as `group:"Another Group"` can be passed
after the script name.

The underlying Fastlane lane remains available directly as
`bundle exec fastlane ios external_beta`.

Submit an existing IPA with the same external workflow:

```sh
IPA_PATH=/absolute/path/to/ComiNavi.ipa \
  FASTLANE_SKIP_UPDATE_CHECK=1 \
  bundle exec fastlane ios upload_external_ipa
```

If the build is already uploaded, submit it without uploading another binary:

```sh
FASTLANE_SKIP_UPDATE_CHECK=1 bundle exec fastlane ios submit_external \
  app_version:1.0 \
  build_number:2026081202
```

Check an external build without modifying App Store Connect:

```sh
FASTLANE_SKIP_UPDATE_CHECK=1 bundle exec fastlane ios check_external \
  app_version:1.0 \
  build_number:2026081202
```

`TESTFLIGHT_EXTERNAL_GROUP`, `CHANGELOG_JA`, and `CHANGELOG_EN_US` can override
the checked-in defaults. External lanes wait for Apple to finish processing,
submit the build for Beta App Review, enable automatic tester notification, and
fail unless the build is assigned to the requested group in an expected review
or testing state.

The defaults can be overridden with `ASC_KEY_ID`, `ASC_ISSUER_ID`, and
`ASC_KEY_FILEPATH`; see `fastlane/.env.example`. Increase
`CURRENT_PROJECT_VERSION` before each upload because App Store Connect does not
accept a build number twice.

## Prepare an archive

1. Sign in to an Apple Developer account in Xcode that has access to team
   `F25GFFJL49`.
2. Confirm an App Store Connect app exists for `llc.mikunet.cominavi`.
3. Select a generic iOS device and the `ComiNavi-TestFlight` scheme.
4. Choose **Product > Archive**.
5. In Organizer, choose **Distribute App > App Store Connect > Upload**.

For command-line archiving:

```sh
xcodebuild \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi-TestFlight \
  -configuration TestFlight \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/ComiNavi-TestFlight.xcarchive \
  -allowProvisioningUpdates \
  archive
```

To upload the archived build to App Store Connect after the archive succeeds:

```sh
xcodebuild \
  -exportArchive \
  -archivePath /tmp/ComiNavi-TestFlight.xcarchive \
  -exportPath /tmp/ComiNavi-TestFlight-export \
  -exportOptionsPlist Configuration/TestFlightExportOptions.plist \
  -allowProvisioningUpdates
```

The export keeps the dSYM in the `.xcarchive` but temporarily skips copying it
into the App Store upload. Xcode 26.6 can otherwise fail its packaging step with
`Copy failed` when a non-Apple `rsync` appears before `/usr/bin/rsync` in
`PATH`. Xcode Cloud's post-clone script also unlinks an incompatible Homebrew
`rsync` from its ephemeral worker before the archive starts. Keep the archive so
the matching dSYM remains available for crash symbolication.

The TestFlight archive uploads its dSYM and source context to Sentry before the
archive is accepted. Install and authenticate the current CLI locally:

```sh
brew install getsentry/tools/sentry
sentry auth login
```

Xcode Cloud installs the pinned CLI version automatically. Configure
`SENTRY_AUTH_TOKEN` as a secret Xcode Cloud environment variable; a TestFlight
archive fails with an actionable build error if the CLI is missing,
unauthenticated, or cannot finish processing the debug symbols.

Build `1.0 (2026081602)` is the current prepared TestFlight build. Increase
`CURRENT_PROJECT_VERSION` for every subsequent upload.
