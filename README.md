# ComiNavi for iOS

ComiNavi is an iPhone and iPad client for browsing Circle.ms catalog data.

## Requirements

- Xcode 16 or later
- iOS 18 or later
- An Apple development team for device builds
- Active Circle.ms authentication and Comiket production access for signed-in features

Swift Package Manager dependencies are resolved automatically from
`ComiNavi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Run locally

1. Open `ComiNavi.xcodeproj` in Xcode.
2. Select the shared `ComiNavi` scheme.
3. Select an iOS 18-or-later simulator.
4. Build and run the app.

The sign-in screen can be built and launched without production access. Completing
authentication and loading catalog data requires the upstream services listed above.

For a command-line simulator build:

```sh
xcodebuild \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Configuration notes

- The app and UI-test targets use automatic signing.
- Debug builds disable Sentry and PostHog event delivery.
- `.sentryclirc` is local-only and must not be committed.
- The Staging and TestFlight Sentry symbol-upload phase intentionally disables Xcode user-script sandboxing.
  `sentry-cli --include-sources` reads the generated dSYM directory and source context,
  which are not completely modeled as build-phase inputs.
- Use the shared `ComiNavi-TestFlight` scheme for App Store Connect archives.
  It is release-optimized, uses the production bundle identifier with the
  currently available Circle.ms sandbox credentials, and excludes non-production
  SQLite fixtures. See `docs/testflight.md`.
- Developer-specific debugger and breakpoint settings belong under ignored `xcuserdata`.
  The shared scheme keeps a non-debugger launch configuration for reproducible builds.
