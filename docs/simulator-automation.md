# Simulator automation with AXe

Verified on 2026-11-09 on `mbp-m5`: Xcode 27.2 (27B52), AXe 1.8.0
(`/opt/homebrew/bin/axe`), branch `ux/overhaul` at `845c774`.

`Scripts/sim/cominavi-sim` wraps `xcodebuild`, `simctl`, and AXe for the
Debug app. It defaults to the iOS 27.1 iPhone Duo
`20F70A8B-0A22-4DC4-BA74-7004FF713400`; set `COMINAVI_SIM_UDID` for another
simulator. Screenshots go to `build/sim-shots/` (ignored by Git).

## Build

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

(`Scripts/sim/cominavi-sim build` runs the same command.) It needs no source
changes for Xcode 27.2. A clean build takes about two minutes on the M5. Without
`-skipPackagePluginValidation`, a non-interactive build fails at "Validate
plug-in OpenAPIGenerator", because nobody is there to approve the
swift-openapi-generator build plugin.

## Playbook

```sh
S=Scripts/sim/cominavi-sim
$S boot                                   # boot + wait until AXe can attach
$S install                                # install build/SimDerivedData/.../ComiNavi.app
$S launch -cominavi-demo-data             # relaunch on the offline C104 demo catalog
$S wait 'id=global-event-day-banner' 30   # poll the AX tree until the shell is up
$S ui                                     # flattened AX tree: type, label, value, id, frame, center
$S tap-label Explore RadioButton          # tap by accessibility label (+ optional element type)
$S tap-id map-search-button               # tap by accessibility identifier
$S tap 201 138                            # tap at point coordinates
$S type 'touhou'                          # US-keyboard text only (AXe limitation)
axe key 40 --udid "$COMINAVI_SIM_UDID"    # Return (HID usage 40)
$S swipe 201 650 201 250 0.4              # scroll content up
$S shot explore-search                    # build/sim-shots/explore-search.png
$S appearance dark
```

`ui` prints one line per labelled or interactive element, with `center=(x,y)`
ready to pass to `tap`. Coordinates are points on the rendering display.
Prefer `tap-id` or `tap-label` over raw coordinates.

Launch arguments reach screens without any input (see `ComiNavi/EntryView.swift`
and the `-cominavi-ui-testing-*` flags):

```sh
$S launch -cominavi-demo-data -cominavi-ui-testing-initial-tab explore   # map|explore|plans|profile
$S launch -cominavi-ui-testing-show-sign-in
```

## Findings

### Xcode 27 drops AXe's default tap style

AXe's default `--tap-style automatic` uses the `simulator` (`tapAt`) path for
most elements. On Xcode 27.2 it reports success, but the app never receives
the tap. `--tap-style physical` and `axe touch --down --up` both work, so the
script always passes `--tap-style physical`. `type`, `swipe`, and `key`
work as-is.

A plain `axe tap` therefore looks like it passes. Confirm every step with
`wait` on the expected AX state instead of a fixed sleep.

### iPhone Duo: inspection works, input does not

The Duo simulator enumerates five screens (`simctl io <udid> enumerate`). Two
matter:

| Screen | Name | Pixels | Points @3x | State |
|---|---|---|---|---|
| 1 | `LCD` (primary) | 1398 × 2034 | 466 × 678 | Renders the UI. The tab bar is a vertical bar on the right edge. |
| 3 | `LCD-1` (primary-1) | 2007 × 2853 | 669 × 951 | Always black. No posture or hinge control reaches it from the CLI. |

- **Accessibility:** `axe describe-ui` works. App frames are in screen-1
  points (466 × 678), so `ui` coordinates match screen 1. On the home screen,
  SpringBoard reports elements for both screens mixed together.
- **Screenshots:** `axe screenshot` captures screen 3, which is black. Use
  `xcrun simctl io <udid> screenshot --display=1` instead, as `cominavi-sim shot`
  does. Set `COMINAVI_SIM_DISPLAY` to change the display.
- **Input:** no AXe input reaches the app on the Duo. That includes tap by label
  or coordinates, either tap style, `touch`, and coordinates scaled to screen
  3. AXe sends digitizer events without a display target, and on the Duo they
  never reach screen 1. The same commands work on an iPhone 18 Pro running the
  same build. The iOS 27.2 Duo runtime (`iOS-27-2-iPhone19-4`, device
  `10193FC3-…`) behaves the same way.
- **Posture:** neither AXe nor `simctl` can fold the device or change the
  hinge. `simctl io … screenConfig power on|off` does not switch the active
  display. It also leaves SpringBoard spinning on a black screen until you
  run `simctl shutdown` and boot again. Do not use it.

Current upstream idb (`facebook/idb` main, Nov 2026) supports Duo
displays: display-targeted digitizer input (`DisplaySelection`, the
`digitizerTarget` of a display) and `idb hinge <degrees>`, sent as a vendor HID
report to `dtuhidd`. AXe 1.8.0 is the latest AXe release and has neither
feature. Driving the Duo's screens and posture therefore needs idb built from
source, or an AXe that adds display selection.

Until then, on the Duo:

1. Reach screens with launch arguments (`-cominavi-ui-testing-initial-tab`,
   `-cominavi-ui-testing-open-*`).
2. Inspect them with `cominavi-sim ui` and capture them with `cominavi-sim shot`.
3. Use XCUITest for interactions (`ComiNaviUITests`). The 2026-09 Duo audit ran
   its UI tests on this device, as described in `docs/audits/iphone-duo/README.md`.
4. Run AXe interaction flows on a standard iPhone simulator, such as the iPhone 18 Pro
   `2D183F50-1555-4F7B-9EDE-13C98A360CBB`.
