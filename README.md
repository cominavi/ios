# ComiNavi for iOS

ComiNavi is an iPhone and iPad client for browsing Circle.ms catalog data.

## Requirements

- Xcode 16 or later
- iOS 18 or later
- An Apple development team for device builds
- Active Circle.ms authentication and Comiket production access for signed-in features

Swift Package Manager dependencies are resolved automatically from
`ComiNavi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Operations preflight

Before building, publishing, or operating the C108 crawler, run the workspace
doctor:

```sh
Scripts/cominavi-ops doctor
```

It checks repository state, Git metadata access, runtimes and dependencies,
Xcode/Simulator availability, GitHub, App Store Connect, Cloudflare, and the
latest crawler state without mutating remote services. Use `--local` to skip
remote account checks. `status` and `wait` expose a shared machine-readable
contract for crawler and TestFlight operations; see
[`docs/operations.md`](docs/operations.md).

## Run locally

1. Open `ComiNavi.xcodeproj` in Xcode.
2. Select the shared `ComiNavi` scheme.
3. Select an iOS 18-or-later simulator.
4. Build and run the app.

The sign-in screen can be built and launched without production access. Completing
authentication and loading catalog data requires the upstream services listed above.

### Real-environment session automation

`Scripts/issue-real-environment-session.sh` runs the backend-owned production
Circle.ms OAuth flow on the laptop, reuses the protected browser state when it
is still valid, and writes a real ComiNavi access/refresh session under the
repository-level `.real-env` directory. It does not enable the legacy provider
token handoff and does not add a test-session issuer to the production service.

Keep `credentials.yaml` and every `.real-env` credential file at mode `0600`.
The script normally does not need the password after the first successful
browser login. If the browser login expires, it reads `circlems.email` and
`circlems.password` from that YAML file. `COMINAVI_CIRCLEMS_EMAIL` and
`COMINAVI_CIRCLEMS_PASSWORD` are also supported for ephemeral CI environments,
but a protected file is preferred on a developer laptop so the values do not
enter shell history.

Issue and validate a session without changing a Simulator login:

```sh
./Scripts/issue-real-environment-session.sh
```

Issue the session and install it into a dedicated Simulator Keychain:

```sh
COMINAVI_E2E_INSTALL_SESSION=1 \
COMINAVI_TEST_DESTINATION='platform=iOS Simulator,name=ComiNavi App Store 6.5' \
./Scripts/issue-real-environment-session.sh
```

The access and refresh tokens are passed only to an opt-in XCTest host as a
base64-encoded environment value. That test validates the session and writes it
to the app's Keychain. The production app executable has no environment-token
login path. A second test account must use distinct values for
`COMINAVI_E2E_CREDENTIALS_FILE`, `COMINAVI_E2E_CIRCLEMS_BROWSER_STATE`,
`COMINAVI_E2E_SERVICE_SESSION_FILE`, `COMINAVI_E2E_BROWSER_SESSION`, and
`COMINAVI_E2E_BROWSER_AUTH_PROFILE` so the two identities never share browser
or refresh-token state.

For invitation-based Google authentication, the laptop can perform the iOS
OAuth authorization-code flow with PKCE and inject the resulting ComiNavi
session into the dedicated recipient Simulator:

```sh
COMINAVI_E2E_INSTALL_SESSION=1 \
./Scripts/issue-real-environment-google-session.sh
```

The first run opens a headed browser for account selection or consent. The
protected Google browser state is then retained at
`.real-env/google-browser-state.json`, with its isolated Chrome profile under
`.real-env/google-chrome-profile`. Both stay within this repository's protected
`.real-env` directory, so later runs can normally issue a new ComiNavi session
without entering the Google password again. The invitation is read from
`.real-env/shared-plan-invitation.json`, and the resulting ComiNavi access/refresh
session is stored at
`.real-env/google-recipient-service-session.json`; every file remains mode
`0600`. Google provider tokens are temporary and are never installed into the
app or committed. The production executable still has no environment-token
login path: the existing opt-in XCTest host validates and writes the ComiNavi
session to the Simulator Keychain.

When the dedicated Simulator has rotated the recipient refresh token, export
the exact successor back to the protected laptop state before another run:

```sh
./Scripts/export-real-environment-session.sh
```

Do not reinstall an older saved refresh token over the Simulator. The export
test reads the production Keychain only when explicitly enabled, validates the
same public user and token lifetime, atomically replaces the protected session
file, and removes its temporary app-container copy. For automation that is
already controlling a signed-in normal Chrome profile, the issuer also accepts
`COMINAVI_E2E_EXTERNAL_BROWSER_HANDOFF_DIR` pointing to a mode-`0700`
subdirectory of `.real-env`; authorization URLs and callbacks remain mode
`0600` and are removed after the one-time exchange.

Once distinct owner and recipient ComiNavi sessions are available, run the
complete two-member production acceptance without installing either identity
into the app Keychain:

```sh
./Scripts/verify-real-environment-two-member-sync.sh
```

The opt-in XCTest receives both protected sessions, creates two independent
clients and SQLite stores, joins a repeatable test plan, disconnects the
recipient, authors offline, reconstructs the recipient store to model a cold
launch, reconnects, and verifies convergence plus both users' inbox history.
Every refresh-token rotation is written to a protected app-container artifact
before the next network step; the script validates and atomically installs both
successor sessions back into `.real-env` even if a later assertion fails. It
never logs token values and never uses a production executable environment
backdoor.

After the active invitation acceptance has passed, prepare literal revoked and
expired capabilities while retaining a fresh active replacement:

```sh
./Scripts/verify-real-environment-invitation-lifecycle.sh
```

The preparation test writes the owner session before any network request and
after every refresh rotation. The wrapper installs that successor even when a
later assertion fails, validates the protected terminal artifacts, and replaces
`.real-env/shared-plan-invitation.json` only after a new 24-hour capability is
ready. The lifecycle runner first checks the live non-app page for plan/Comiket
context, privacy language, App Store and explicit app actions, and strict
no-store/no-referrer/no-index headers without logging the capability. It then
opens the revoked and expired URLs through separate cold and warm paths and
requires the non-joinable error surface.

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
- Install the current Sentry CLI with `brew install getsentry/tools/sentry`,
  then authenticate once with `sentry auth login`. The CLI stores its local
  authentication outside the repository; never commit Sentry credentials.
- The Staging and TestFlight Sentry symbol-upload phase intentionally disables Xcode user-script sandboxing.
  `sentry debug-files upload --include-sources` reads the generated dSYM directory and source context,
  which are not completely modeled as build-phase inputs.
- TestFlight archives fail if symbol upload fails instead of silently shipping
  unsymbolicated builds. Xcode Cloud installs the pinned CLI version from
  `ci_scripts/install_sentry_cli.sh` and requires `SENTRY_AUTH_TOKEN` to be set
  as a secret environment variable. Staging builds report upload failures as
  warnings so local development is not blocked.
- Use the shared `ComiNavi-TestFlight` scheme for App Store Connect archives.
  It is release-optimized, uses the production bundle identifier and Circle.ms
  production service, and excludes non-production SQLite fixtures. The OAuth
  client secret remains server-side in the `cominavi.net` Worker and is never
  bundled into the app. See `docs/testflight.md`.
- Developer-specific debugger and breakpoint settings belong under ignored `xcuserdata`.
  The shared scheme keeps a non-debugger launch configuration for reproducible builds.
