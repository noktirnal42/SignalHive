# SignalHive: working notes for agents

A native Swift radio workshop for macOS (primary), iOS and a menu-bar app: FCC license data, a local USB RTL-SDR
scanner, decoders, aviation (ADS-B / UAT), trunking, codeplugs and on-device AI.

## Read first

1. `docs/PROJECT_STATUS.md`: state, history, verified status, known bugs, how to build and test.
2. `docs/UI_AUDIT_2026-09-30.md`: **the current task list**. Workshop and AI Lab are information screens that must
   be made to function; the build spec, the order and the acceptance criteria are there. Screenshots of every screen:
   `docs/screenshots/2026-09-30/`.
3. `docs/superpowers/specs/`: scanner design, data foundation, originalization plan, workshop feature map.

## Owner decisions that are not negotiable

- **No RadioReference data, API or scraping.** FCC ULS is the data source. OpenMHz is an approved opt-in source.
- **Original Swift.** External decoders and libraries are references or test oracles, not dependencies.
  `dsdccx` and `multimon-ng` are temporary adapters only.
- **`Packages/SwiftRTLSDR` is an embedded copy of the upstream driver** (github.com/noktirnal42/SwiftRTLSDR). Driver
  changes go upstream first; SignalHive only syncs stable upstream commits.
- **The macOS app is deliberately unsandboxed** (IOUSBHost cannot open the dongle in the App Sandbox). Do not
  re-enable the sandbox.
- **The UI must be truthful.** A badge, gauge, tile or count reflects real state. No decorative data that looks live,
  no "Available" for something nothing can call.
- RTL-SDR is a local USB dongle on the Mac; network/Raspberry Pi sources come later.

## Code rules

- Logic in `Packages/SignalHiveCore` with Swift Testing tests; views stay thin.
- **One `.searchable` per window.** A second one crashes the macOS app (NSToolbar throws).
- A wrong SF Symbol name compiles and renders nothing: run `script/check_sf_symbols.sh` after touching icons.
- New files under `App/` must be registered in the committed `SignalHive.xcodeproj`:
  `python3 script/register_app_sources.py` (CI checks this). `project.yml` is the XcodeGen source of truth.
- Match the surrounding code's style and comment density. Comments say why, not what.

## Build and test

```bash
script/build_and_run.sh --verify                                       # macOS app (needs macOS 27 SDK)
cd Packages/SignalHiveCore && swift test --skip RTLSDRHardwareTests    # 679 tests
cd Packages/SwiftRTLSDR && swift test                                  # embedded driver
```

Builds on the external volume are slow; use `--scratch-path` / `-derivedDataPath` on the internal disk. Only one
program can hold the dongle: quit the app before hardware tests.

## Cloud sessions

- The cloud environment cannot run this app (macOS 27, AppKit, USB). CI (`.github/workflows/ci.yml`) builds and tests
  on a hosted macOS runner; the `apps` and `project` jobs are `continue-on-error`, so read their logs.
- Work on a branch and open a PR to `main`. Do not commit build products or downloaded files (an earlier cloud branch
  committed pip `.whl` files to the repo root).
- Anything that needs the owner's Mac (dongle, audio, Foundation Models, MLX inference) goes on the **Owner QA
  checklist** in `docs/PROJECT_STATUS.md` section 9. Never claim it is verified.
- Update `docs/PROJECT_STATUS.md` as you go (verified status table, bugs found, who did what). Sessions can end
  before a summary is written.
