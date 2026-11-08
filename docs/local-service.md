# Local ComiNavi service

Debug and Staging builds can talk to a ComiNavi service other than production,
so agents and developers can experiment without writing to `cominavi.net`.
TestFlight and App Store builds cannot: the switch is compiled out, and they
always use `https://cominavi.net`.

## Choose the service origin

Pass the origin as a launch argument:

```sh
xcrun simctl launch <udid> llc.mikunet.cominavi.debug \
  -cominavi-service-origin http://127.0.0.1:4380
```

or as the environment variable `COMINAVI_SERVICE_ORIGIN` (with `simctl launch`,
export it as `SIMCTL_CHILD_COMINAVI_SERVICE_ORIGIN`). The launch argument wins
over the environment variable. With neither, the build's
`COMINAVI_SERVICE_BASE_URL` setting applies, which is `https://cominavi.net`
for every configuration today.

`Scripts/sim/cominavi-sim launch` passes its arguments through:

```sh
Scripts/sim/cominavi-sim launch -cominavi-service-origin http://127.0.0.1:4380 -cominavi-demo-data
```

The value must be a bare origin, `scheme://host[:port]`, with no path, query,
fragment or credentials. Only these are accepted:

| Host | Schemes | Port |
|---|---|---|
| `127.0.0.1`, `::1`, `localhost` | `http`, `https` | any |
| `*.test` (for example `cominavi.test`) | `https` | any |
| `staging.cominavi.net` (reserved, not deployed yet) | `https` | default |
| `cominavi.net` | `https` | default |

Anything else, or the launch argument without a value, stops the app at launch
with a fatal error, "Refusing ComiNavi service origin: …", before it sends any
request. It never falls back to production. In Debug the crash handler can
leave the app on a blank screen instead of exiting; the reason is in the
device log (`xcrun simctl spawn <udid> log show --last 2m --predicate
'process == "ComiNavi"'`).
Use `127.0.0.1` rather than `localhost`: the local server binds IPv4 only.

The rules live in `ComiNavi/Configuration/CominaviServiceOrigin.swift` and are
covered by `ComiNaviTests/CominaviServiceOriginTests.swift`.

## What follows the origin

- Every `CominaviServiceClient` request, including Shared Plan sync, which is
  built from the same base URL.
- The App Review demo catalog download
  (`/api/v2/review-demo/catalogs/c104/v2/*.sqlite.gz`).
- The Google and Apple special-entry web pages (`/auth/google`, `/auth/apple`).

Catalog artifacts must otherwise be downloaded over `https`. A plain-`http`
download is accepted only from a loopback service origin selected with the
switch, and only for URLs on exactly that origin.

These stay on production in every build, because they are public links or
provider registrations rather than service calls: invitation links
(`https://cominavi.net/join/<token>`), universal-link entitlements, and the
Circle.ms OAuth redirect (`https://cominavi.net/oauth/circlems/landing`).

## Sessions and caches are bound to the origin

The origin is part of `AppEnvironment.storageNamespace` and of the
environment-scoped Caches and Application Support directories. A non-production
origin adds a component such as `origin-http-127.0.0.1-4380`:

- Keychain: `pre-release-v2/debug/production/origin-http-127.0.0.1-4380`
- Files: `Library/Caches/environments/debug/production/origin-http-127.0.0.1-4380/…`

So the ComiNavi session, its public-user binding, logout and deletion
tombstones, pending provider flows, Shared Plan databases, the profile cache,
catalog selection and downloaded catalogs of one origin are never read or sent
while the app targets another origin. Production keeps its original namespace
(`pre-release-v2/debug/production`), so existing installs keep their sessions.
Switching back to production shows the production state exactly as it was.

## Circle.ms environment

The origin does not change the Circle.ms environment. Debug still uses
production Circle.ms and Staging the Circle.ms sandbox
(`AppEnvironment.expectedCirclemsEnvironment`). The app sends it to the service
in the JSON body as `environment: "production" | "sandbox"`; the server accepts
only those two values.

A local server cannot complete a Circle.ms sign-in: it needs the real Circle.ms
client ID and secret in `.dev.vars`, and the provider redirect is registered at
`https://cominavi.net/oauth/circlems/landing`, so the browser leg would land on
production, which does not know the local OAuth state and rejects it. Google
and Apple likewise need real provider registrations. Signed-in flows against a
local server wait for the planned test identity provider; until then, use the
signed-out and demo flows below.

## Run the server locally (verified on mbp-m5, 2026-11-09)

In a `cominavi/server` checkout:

```sh
pnpm install
pnpm exec wrangler d1 migrations apply COMINAVI_DB --local
pnpm exec wrangler d1 execute COMINAVI_DB --local --file seed/c108-realtime.sql   # about 2.5 minutes
```

The App Review demo catalog is served from the local `cominavi-catalog-downloads`
R2 bucket by the server route `GET/HEAD /api/v2/review-demo/catalogs/c104/v2/:database`.
As of 2026-11-09 that route is not on the server's `main` branch yet
("Serve public App Review demo catalog"); without it the demo download returns
404 locally. Recreate its two artifacts byte for byte from the files bundled in
this repository (`-n` keeps the gzip output deterministic, so the sizes and
digests match the app's expectations):

```sh
IOS=../ios/ComiNavi/Resources/DemoCatalogs/C104
mkdir -p .local-dev/demo
gzip -n -9 -c "$IOS/demo-c104-main.sqlite"   > .local-dev/demo/main.sqlite.gz
gzip -n -9 -c "$IOS/demo-c104-images.sqlite" > .local-dev/demo/images.sqlite.gz
for name in main images; do
  pnpm exec wrangler r2 object put \
    "cominavi-catalog-downloads/review-demo/catalogs/c104/v2/$name.sqlite.gz" \
    --local --file ".local-dev/demo/$name.sqlite.gz" --content-type application/gzip
done
```

Start the server on a fixed loopback port:

```sh
pnpm dev --host 127.0.0.1 --port 4380
```

Astro moves to the next free port without failing if the requested one is
taken (on mbp-m5, 8787 already is), so check the port it prints. The simulator
shares the Mac's network, so `http://127.0.0.1:4380` works from the app with no
forwarding, and plain `http` to a loopback address needs no App Transport
Security exception.

Then launch the app against it:

```sh
Scripts/sim/cominavi-sim launch -cominavi-service-origin http://127.0.0.1:4380 -cominavi-demo-data
```

The demo catalog downloads from the local server, and the C108 realtime feed
comes from the seed. With the server's dev-only request logger
(cominavi/server, "Log requests in local dev"), each request shows in the
`pnpm dev` output:

```text
[vite] --> GET /api/v2/review-demo/catalogs/c104/v2/main.sqlite.gz 200 5ms
[vite] --> GET /api/v2/review-demo/catalogs/c104/v2/images.sqlite.gz 200 4ms
```

### What works locally

| Endpoint | Signed out | Notes |
|---|---|---|
| `GET /api/v2/events/{n}/updates` | yes | C108 seed data |
| `GET/HEAD /api/v2/review-demo/catalogs/c104/v2/{main,images}.sqlite.gz` | yes | after the R2 step above |
| `GET /api/v2/catalogs`, `/api/v2/catalogs/{n}` | no | needs a bearer session, and no local catalog is published |
| `POST /api/v2/auth/circlems/start` | no | 500 without Circle.ms client credentials in `.dev.vars` |
| `/api/v2/me/*`, favorites, Shared Plans | no | needs a session |

## Staging

No hosted staging Worker exists yet. `staging.cominavi.net` is accepted by the
switch so a future Staging configuration only has to change its
`COMINAVI_SERVICE_BASE_URL` build setting.
