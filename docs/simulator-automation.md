# Simulator automation with AXe and idb

Verified on 2026-11-09 on `mbp-m5` with Xcode 27.2 (27B52), AXe 1.8.0
(`/opt/homebrew/bin/axe`) and idb built from `facebook/idb` main at `291575b`.
The app was branch `ux/overhaul` at `845c774`.

`Scripts/sim/cominavi-sim` wraps `xcodebuild`, `simctl`, AXe and idb for the
Debug app. It defaults to the iOS 27.1 iPhone Duo
`20F70A8B-0A22-4DC4-BA74-7004FF713400`. Set `COMINAVI_SIM_UDID` for another
simulator. Screenshots go to `build/sim-shots/` (ignored by Git).

The two tools split the work:

| Job | iPhone Duo | Other iPhones and iPads |
|---|---|---|
| Accessibility tree (`ui`, `wait`) | AXe | AXe |
| Input (`tap*`, `type`, `swipe`, `home`) | idb | AXe |
| Hinge and posture (`hinge`) | idb | n/a |
| Screenshots (`shot`) | idb (follows the active display) | `simctl` |

The script picks idb automatically for an iPhone Duo device type. Set
`COMINAVI_SIM_INPUT=axe` or `COMINAVI_SIM_INPUT=idb` to override.
`cominavi-sim backend` prints the choice.

## Build the app

```sh
xcodebuild \
  -project ComiNavi.xcodeproj \
  -scheme ComiNavi \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=20F70A8B-0A22-4DC4-BA74-7004FF713400' \
  -derivedDataPath build/SimDerivedData \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGN_IDENTITY=- \
  build
```

`Scripts/sim/cominavi-sim build` runs the same command. Xcode 27.2 needs no
source changes. A clean build takes about two minutes on the M5. Without
`-skipPackagePluginValidation`, a non-interactive build fails at "Validate
plug-in OpenAPIGenerator", because nobody is there to approve the
swift-openapi-generator build plugin.

## Install idb (needed for the Duo)

The Homebrew idb release does not have the Duo display and hinge support yet,
so build idb from source. Its prerequisites are `brew install xcodegen protobuf`
and Python 3.10 or later.

```sh
git clone https://github.com/facebook/idb.git ~/src/idb
cd ~/src/idb && ./build.sh build            # writes Build/Distribution/idb_companion
python3 -m venv ~/src/idb-venv
FB_IDB_VERSION="0.0.0.dev0+$(git rev-parse --short HEAD)" ~/src/idb-venv/bin/pip install .
```

The script expects `~/src/idb-venv/bin/idb` and
`~/src/idb/Build/Distribution/idb_companion`. Override them with `IDB` and
`IDB_COMPANION`. It passes `--companion-path`, so the client starts and reuses a
local companion by itself. You do not need to run `idb connect`.

## Playbook

```sh
S=Scripts/sim/cominavi-sim
$S boot                                   # boot + wait until AXe can attach
$S install                                # install build/SimDerivedData/.../ComiNavi.app
$S launch -cominavi-demo-data             # relaunch on the offline C104 demo catalog
$S wait 'id=global-event-day-banner' 30   # poll the AX tree until the shell is up
$S ui                                     # flattened AX tree: type, label, value, id, frame, center
$S tap-label Explore                      # tap by accessibility label
$S wait 'RadioButton "Explore" value=1'   # confirm the tap landed
$S tap-id map-search-button               # tap by accessibility identifier
$S tap 201 104                            # tap at point coordinates (from `ui` centers)
$S type 'touhou'                          # type into the focused field (US keyboard)
$S swipe 190 550 190 200 0.4              # scroll content up
$S hinge                                  # Duo: read the hinge angle
$S hinge 180                              # Duo: unfold (inner display, landscape)
$S hinge 0                                # Duo: fold (cover display)
$S shot explore-search                    # build/sim-shots/explore-search.png
$S appearance dark
```

`ui` prints one line per labelled or interactive element, with a
`center=(x,y)` you can pass to `tap`. Coordinates are points on the active
display. Prefer `tap-id` or `tap-label` over raw coordinates, and confirm every
step with `wait` instead of a fixed sleep.

Launch arguments reach screens without any input. See
`ComiNavi/EntryView.swift` and the `-cominavi-ui-testing-*` flags:

```sh
$S launch -cominavi-demo-data -cominavi-ui-testing-initial-tab explore   # map|explore|plans|profile
$S launch -cominavi-ui-testing-show-sign-in
```

The selected tab persists between launches, so pass `initial-tab` when a flow
depends on the starting tab.

## Findings

### Xcode 27 drops AXe's default tap style

AXe's default `--tap-style automatic` uses its `simulator` (`tapAt`) path for
most elements. On Xcode 27.2 that path reports success, but the app never
receives the tap. `--tap-style physical` and `axe touch --down --up` both work,
so the script always passes `--tap-style physical` to AXe. `type`, `swipe` and
`key` work as they are.

### iPhone Duo

The Duo simulator lists five screens in `simctl io <udid> enumerate`. Two of
them matter:

| Hinge | Active screen | Points | App layout |
|---|---|---|---|
| 0° (folded, the boot state) | 1, `LCD` | 466 × 678 | Portrait, with a vertical tab bar on the right edge |
| 90° and 180° | 3, `LCD-1` | 669 × 951 screen, 951 × 669 app | Landscape, with a vertical tab bar on the right edge |

- **Input:** idb taps, accessibility presses (`tap-label`, `tap-id`), text,
  swipes and buttons all reach the app in both postures. AXe input does not
  reach the Duo in either posture. That covers both tap styles, `touch`, and
  scaled coordinates. AXe 1.8.0 sends digitizer events without a display target,
  while idb routes them to the active display. The iOS 27.2 Duo runtime
  (`iOS-27-2-iPhone19-4`) behaves the same way as iOS 27.1.
- **Accessibility tree:** `axe describe-ui` works in both postures. Its frames
  are in the active display's points, so they match idb's coordinates. On the
  home screen, SpringBoard reports elements for both screens mixed together.
- **Screenshots:** `idb screenshot` captures the active display, so the script
  uses it on the Duo. `axe screenshot` always captures screen 3, which is black
  while folded. Once unfolded, `simctl io … screenshot --display=N` returned
  black frames for both screens. Set `COMINAVI_SIM_DISPLAY` only to force a
  particular `simctl` display.
- **Posture:** `idb hinge <0–180>` sends the hinge slider report. Do not use
  `simctl io … screenConfig power on|off` to switch displays. It does not change
  the active display, and it leaves SpringBoard spinning on a black screen until
  the simulator is shut down and booted again.
- **App accessibility:** on the Duo's cover display, the Explore search field
  has no accessibility label. It exposes only its placeholder as a value. The
  same field on the iPhone 18 Pro is labelled "Search circles, creators, tags".

XCUITest also drives the Duo. The 2026-09 audit ran its UI tests there; see
`docs/audits/iphone-duo/README.md`.
