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

Build `1.0 (2026081201)` is the current prepared TestFlight build. Increase
`CURRENT_PROJECT_VERSION` for every subsequent upload.
