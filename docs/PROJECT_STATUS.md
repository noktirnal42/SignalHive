# SignalHive — Project Status and Handoff

Last updated: 2026-10-04 (Workshop action model and rework, satellite capture recipes, AI provider layer, RF Coach and the Air Data briefing on it, upstream SwiftRTLSDR check). This is a living document: update the "Verified status" table whenever
something is tested, and add to "Bugs found and fixed" whenever a root cause is found.

**Start here:** the current state, in one line: the data, scanner, aviation and trunking screens work; **Workshop is now a
launchpad** (every tile ends in a button that opens, starts, fixes or explains), and **AI Lab has one usable local RF Coach action**. The findings, the build spec and
the suggested order are in [`UI_AUDIT_2026-09-30.md`](UI_AUDIT_2026-09-30.md); screenshots of every screen are in
`docs/screenshots/2026-09-30/`. Working rules for any agent (Claude, Codex, cloud) are in the repo-root `CLAUDE.md`.

## 1. What SignalHive is

A native macOS/iOS **radio workshop**. The owner's stated goals (collected from the OpenCode, Claude Code and
Codex sessions):

- The data and features of radioreference.com, built as **our own implementation**. FCC ULS is the data source.
  **No RadioReference API, scraping or data** (owner decision, 2026-09-29).
- Scanner and RTL-SDR features: spectrum/waterfall, demodulators, decoders (ADS-B, UAT/978, ACARS, AIS, Morse,
  paging, P25/DMR metadata, ...), trunking, weather and satellite reception, radio programming and control.
- Support for external hardware: GPS, ESP32, Raspberry Pi, Arduino, Wi-Fi/Bluetooth/IoT, ham radios, scanners.
- **RTL-SDR is a local USB dongle on the Mac** (primary path). Network/Raspberry Pi sources come later.
- **Originalize everything** (owner, 2026-09-29): every external library, decoder, demodulator and driver is to be
  refactored into original Swift code, using the external code only as inspiration/reference. Plan, rules and
  order: `docs/superpowers/specs/2026-09-29-originalization-plan.md`.
- **All Swift where feasible.** Existing decoders/demodulators in other languages are to be re-implemented as
  original Swift code, using existing projects only as inspiration. External command-line tools (`multimon-ng`,
  `dsdccx`) are temporary adapters only.
- **The Scanner must behave like a real police/radio scanner** (owner, 2026-09-29): quickly sweep and find active
  frequencies, identify them (from FCC data: who holds the license, which county/service), cover trunked and other
  common systems with the useful decoders, hold/skip/lockout, and let users **save channels** into scan lists.
- Visually distinctive, animated instrument-style UI; no generic AI-generated look. A painted app icon.
- AI features: Core ML, Apple Foundation Models (on-device and Private Cloud Compute), MLX models from Hugging
  Face with a downloader that annotates which models will run well on this Mac.

## 2. Who did what (commit history)

| Stage | Author | What |
|---|---|---|
| Initial build | OpenCode | HAL drivers, DSP/decoders, cloning, first (non-working) browse UI |
| `2f6ecad`–`2305494` | Claude Code | Investigation, FCC data foundation: streaming pack builder, per-state packs, `PackStore`, `FrequencyStore`, `BrowseDataSource`, user database, local FCC build, specs and plans in `docs/superpowers/` |
| `8ed76ca` | Codex (GPT) | Checkpointed as-found: visual design system, app icon, Workshop screen, AI Lab screen, AI core module, reworked Browse/Scanner/Trunked, `script/build_and_run.sh`, `-mockData` flag. Its usage ran out before it wrote any notes. |
| `5437fc6` | Claude Code | Fixed the launch crash (see section 5) |
| `af98fc7` in SwiftRTLSDR | Codex (GPT) | Clarified native USB open failures in the upstream driver package and added tests. SignalHive's embedded driver copy matches this stable upstream patch. |
| SwiftRTLSDR PR #1 | Claude cloud session | Merged section 6 work: retune shortcuts, overload guard/AGC, scan loop, EEPROM serial provisioning, rtl_tcp server, and CLI/docs. SignalHive embedded copy was synced and SwiftRTLSDR tests pass locally. |
| `649a7f4` | Codex (GPT) | Synced SwiftRTLSDR PR #1 into `Packages/SwiftRTLSDR`; added `RTLSDRScan` dependency, noise-floor-aware finder bridge, scan models/activity log, Scanner UI rail with live hits, hold/skip/lockout/save, starter scan bank, decoder quick-tune queue, and a research-backed radio workshop feature map. |
| `a7f5574`, `c41bc59` | Codex (GPT) | Synced the embedded SwiftRTLSDR with upstream draft PR #2 (ADS-B / Mode S) and exposed `NativeModeSADSBDecoder`. |
| `ed1bf55` | Codex (GPT) | One large sync commit (about 18k lines) that **absorbed the whole Claude cloud-session branch `claude/vibrant-einstein-ro06r5`**: Aviation core and the Air Map / Air Data screens, the 1090 MHz and 978 MHz (UAT / FIS-B) receivers, codeplug validator / editor / CHIRP import, tolerant OpenMHz client with offline cache and category filters, `WorkshopCatalog` built from real machine facts, `GetDataSheet`, Hugging Face `ModelDownloadManager`, CI workflow, and the embedded driver's ISM / LRPT / RS41 / UAT decoders. Verified 2026-09-30: `main` contains everything on that branch plus later fixes, so **the remote branch is obsolete and can be deleted**. |
| `80cdfc6`, `939285c` | Codex (GPT) | Receiver location service and live aviation setup (the "Start demo sky" button was removed from Air Map here); icon metadata and the single-instance launch script. |
| 2026-09-30 | Claude Code (local) | UI audit (this doc's companion), Trunked crash fix, Dock icon hook, run-script race fix, invalid SF Symbol fixes, `script/check_sf_symbols.sh`, docs and screenshots for the cloud session. Finished what Codex was in the middle of (Dock icon); its "AI Lab pass" was never written, and is now specified in the audit. |
| 2026-09-30 | Codex (GPT) | Removed macOS sandbox signing from the XcodeGen project and regenerated `SignalHive.xcodeproj`; verified the running app has no sandbox entitlement. Added `SignalDescriptionContext`, a rules-based RF Coach entry point, tests, and an AI Lab panel that runs it. Confirmed embedded `Packages/SwiftRTLSDR` matches Claude's `claude/determined-davinci-n2dt0t` branch. |
| `beda3c3` | Codex (GPT) | Added Air Map map modes and Apple map controls, macOS location usage strings, and the Satellites pass planner fed by CelesTrak weather TLEs. |
| 2026-10-01 | Codex (GPT) | Added Decoder Hub as a real app panel and Workshop destination. ACARS, AIS and Morse now have manual workbench decode paths with tests; live SDR sessions for ACARS/AIS/ISM/RS41/LRPT/paging remain the next decoder integration step. |
| 2026-10-01 | Codex (GPT) | Added `DecoderSession` in `SignalHiveCore`: a tested actor that runs a `SignalDecoder` on direct or channelized IQ, retains messages, publishes an async message stream, and tracks live session statistics. |
| 2026-10-01 | Codex (GPT) | Added `DecoderDemoSignal` and Decoder Hub live-session controls for Morse and ACARS demo IQ. The app now drives `DecoderSession` from the Decoder Hub and shows blocks/samples/messages/rate plus decoded rows; real RTL-SDR capture sessions remain owner QA / next integration work. |
| 2026-10-04 | Codex (GPT) | Ran a visual walkthrough of the running macOS app with mock data. Fixed the Search screen's blank first-run state with a native empty state and example queries; tightened Decoder Hub live-session UI so unsupported decoders no longer show a misleading disabled demo-IQ button and decoder switches clear stale session output. ACARS demo IQ was visually rechecked after the patch. |
| 2026-10-04 | Claude Code (local) | Picked up Codex's uncommitted Decoder Hub demo-IQ and satellite work and verified it (431 tests green, then 449). Fixed the satellite capture recipe before anything used it: Meteor-M2 4 is on 137.1 MHz and M2 3 on 137.9 (CelesTrak spells the names differently from the old code's match), and satellites an RTL-SDR cannot receive (NOAA 20/21, Suomi NPP, GOES, Fengyun, ISS, Meteor-M2 2) now get no recipe instead of defaulting to "Meteor LRPT". Built the **Workshop action model** (`WorkshopAction` / `WorkshopFix` / `WorkshopPreset`, quick actions, home grid vs roadmap) with tests, and reworked `WorkshopView` onto it: tile buttons, fix and explanation sheets, presets handed to Scanner and Decoder Hub, real readiness gauge, fake ribbons removed. Checked upstream SwiftRTLSDR: `main` is still `a6d9e67`; draft PR #2 head `c95bc33` equals the embedded copy. Then built the **AI provider layer** (`LanguageModelProvider`, `AIRouter`, rules + on-device + Private Cloud Compute providers) test-first, rebuilt the RF Coach sheet on it with a provider picker and provenance, and verified the on-device model live. Then built the **Air Data briefing**: `AviationBriefing` (a deterministic digest of traffic, emergencies, weather and hazard products, counted from the picture) plus an `AITask.briefAviation` the router answers from it, an "Air briefing" panel with a "Brief me" button in Air Data, and a reusable `AIAnswerSheet`. Verified live with the on-device model and the demo sky. |

The Codex session (for reference): `~/.codex/sessions/2026/09/29/rollout-2026-09-29T17-17-28-01a0efac-*.jsonl`,
thread "Fix and finish SignalHive". Its last two requests ("work on AI workshop", "app icon missing from the taskbar")
were cut off before any code was written.

## 3. Architecture

```
App/                          SwiftUI apps (macOS, menu bar, iOS); XcodeGen source of truth is project.yml
  Shared/Design/              Visual system (HiveInk palette, instrument panels, meters, spectrum ribbon)
  Shared/Views/               Workshop, AILab, Browse, Search, Trunked, Scanner, AirMap, AirData, Codeplug, GetDataSheet,
                              FrequencyDetail, Settings
  Shared/Aviation/            AviationModel (receivers, picture, demo), receiver location, painted aircraft icons
  Shared/Stores/AppModel      App state: packs, browse data source, user data, local build, codeplug
  Shared/Stores/ModelLibrary  AI Lab model downloads (state, progress, resume), app-wide so they survive panel changes
  Shared/MacAppDelegate.swift Dock icon (see the bugs list)
Packages/SignalHiveCore/      All logic, UI-free
  Data/ULS, Data/Packs        FCC ULS -> per-state SQLite packs (builder, store, manifest, county/emission parsing)
  Data/Browse                 BrowseDataSource protocol, real (pack) and mock implementations
  Data/User                   UserData.sqlite (codeplugs), migration from the legacy database
  Data/OpenMHzClient          Tolerant OpenMHz client, offline cache, talkgroup categories (Models/TrunkedBrowsing)
  Data/ModelDownload          Hugging Face client and resumable, checksum-verified model installs
  HAL/                        SDR devices: native Swift RTL-SDR, HackRF, Lime, SDRplay, Airspy, Pluto, network, test
  DSP/                        FFT, demodulators, decoders (ACARS, AIS, Morse, ... behind `SignalDecoder`), classifier,
                              description engine
  Aviation/                   Aircraft state, picture, trails, radar, METAR decoder, 1090 and 978 MHz receivers, demo
  AI/                         AI workbench model: features, providers, MLX candidates, local-machine profile
  Models/WorkshopCatalog      What the Workshop lists, with statuses worked out from machine facts
  Cloning/                    Baofeng, Uniden protocol, CHIRP CSV import/export, codeplug validator and editing helpers
  Voice/, CMbelib/            P25 voice path (mbelib carries a patent notice)
  Sources/signalhive-packbuilder   CLI that builds packs from FCC archives
Packages/SwiftRTLSDR/         Embedded copy of the upstream driver (github.com/noktirnal42/SwiftRTLSDR): RTLSDRKit,
                              RTLSDRScan, RTLSDRServer, RTLSDRDecoders (Mode S, UAT, ISM, LRPT, RS41), `rtlsdr-tool`
docs/                         This file, UI_AUDIT_2026-09-30.md, screenshots/, superpowers/ (specs and plans)
```

Data flow: FCC weekly archives -> `PackBuilder` (active licenses only, streamed) -> one compressed SQLite pack per
state + `manifest.json` -> `PackStore` (download, SHA-256 verify, decompress, atomic install) ->
`PackBrowseDataSource` -> views. The app can also build packs itself ("Build from FCC on this Mac").

## 4. Verified status (2026-09-29 to 2026-10-04, macOS 27.0.1 / Xcode 27.0 / Swift 6.4)

| Area | Status | Evidence |
|---|---|---|
| Package tests | **2026-10-04: SignalHiveCore 493 tests in 75 suites pass (two opt-in live-model tests skipped)** (hardware tests skipped). SwiftRTLSDR passed on 2026-09-30 (99 kit + 31 scan + 16 server + 87 decoder tests); its source has not changed since, so it was not rerun | `swift test --skip RTLSDRHardwareTests` in `Packages/SignalHiveCore`; `swift test` in `Packages/SwiftRTLSDR` |
| Workshop and AI Lab screens | **Workshop is a working launchpad (2026-10-04)**: every ready or needs-setup tile has a button (Open, Start listening, Open decoder, Get data, Add source, Connect a dongle, How to install) and every not-connected tile has Details; quick actions (NOAA weather, aircraft guard, Track aircraft, Get state data, Open codeplug); the hero gauge is `WorkshopCatalog.readiness`; planned items sit behind a collapsed Roadmap. Driven in the running app with mock data and a real dongle attached: Get state data opened the FCC sheet, ISM Details explained itself, ACARS Open decoder landed on ACARS, Add source landed on Scanner with the rtl_tcp field open, AI Lab Open navigated. **Not exercised:** the Start listening / Track aircraft launches (they start the dongle; see the Owner QA list). **AI Lab now has one real action**: RF Coach explains a frequency/mode/RSSI context through local deterministic rules and labels the provider honestly. Workshop now links the Satellite planner and Decoder Hub, reflects embedded ISM/LRPT/RS41/rtl_tcp/EEPROM capabilities honestly, and no longer lists Meteor LRPT as missing demod/deframe work. Full audit and remaining build spec: `docs/UI_AUDIT_2026-09-30.md` | Driven in the running app; `AIWorkbenchModelsTests`; `WorkshopCatalogTests`; `WorkshopActionTests`; `DecoderWorkbenchTests`; app-bound screenshots after pressing Explain and opening Satellites; 2026-10-04 screenshots of the reworked Workshop |
| Trunked (OpenMHz browser) | **Pass 2026-09-30** after a crash fix: live systems list, a 6,488-talkgroup system opens, category chips and inline search work. Add-to-codeplug not exercised | Driven in the running app |
| Air Map / Air Data | Air Map has Apple map controls, map modes (Dark, Map, Terrain, Satellite, Hybrid, Hybrid Terrain), traffic and POI toggles, and the macOS location usage key required for Location Services. Receivers not started in this pass (need an antenna); demo sky not reachable from the UI | Driven in the running app; `script/build_and_run.sh --verify` |
| Dock icon | **Pass 2026-09-30**: painted icon in a rounded tile with the running indicator | Screenshot of the Dock |
| macOS, menu-bar and iOS targets build | Pass | `xcodebuild` for all three schemes |
| App launches without crashing | **Pass** after fix: 0 of 20 launches crashed (was 4 of 8) | `script/launch_stability_test.sh` |
| FCC data: state -> county -> licenses -> frequencies | **Pass** with the owner's real Arizona pack (6,049 licenses, 13,101 sites, 41,354 frequencies, all 15 counties) | Driven in the running app: Coconino County lists licensees; the detail pane shows call sign, service, dates and frequencies with mode/bandwidth |
| RTL-SDR detected over USB | **Native Swift path integrated.** SignalHive now depends on `Packages/SwiftRTLSDR` and uses `NativeRTLSDRDevice` over Apple's IOUSBHost API; no `dlopen(librtlsdr)` is used for RTL-SDR. The local macOS app is intentionally unsandboxed because IOUSBHost whole-device open is blocked in the App Sandbox on the tested RTL2832U/R820T dongle. | SignalHiveCore hardware tests exercised the attached dongle; 2026-09-30 rebuilt app entitlement check shows only debug `get-task-allow`, no `com.apple.security.app-sandbox` |
| Pack builder on real FCC data | Pass for LMcomm: 5.3 s, 47 MB peak, 55 packs / 3.4 MB | `docs/superpowers/specs/2026-09-29-data-foundation-spike.md`. LMpriv not measured by Claude; the owner's Arizona pack shows it works in the app |
| Scanner display: spectrum, waterfall, tuning, volume | **Fixed and verified on the real dongle (S1)**: full centre-shifted spectrum, fed high-resolution waterfall (2048x400 pixel buffer, inferno palette, 25 rows/s, selectable 125 Hz - 1 kHz detail), auto-scaling, typed/stepped/click-to-tune frequency snapped to the step grid, volume + mute. Tests: FFT tones, waterfall buffer, palette, throttle, frequency entry, volume | Running app with the RTL-SDR; 102 tests |
| Scanner activity workflow | **Partial S3 built**: live passband activity detection now uses `RTLSDRScan.PeakDetector` with a local noise floor; UI shows activity hits, tune, hold/release, skip, lockout/unlock, save-to-codeplug, starter scan bank, decoder quick-tune presets, and a repaired source rail. True multi-hop scan-list sweeping and FCC identification are still next. | `swift test --skip RTLSDRHardwareTests`; macOS app build |
| Channelizer (select one channel out of the capture) | **Built and tested (S2a)**: `ChannelDownconverter` (mix to baseband, two-stage filter, decimate to ~48 kHz), wired into `DSPPipeline` via `channelOffsetHz`; squelch measures the channel, not the band. Tests: >60 dB rejection of other signals incl. a 20 dB-stronger neighbouring channel, block-size independence, FM recovered next to a strong interferer, offset selects which of two signals is heard | 113 tests |
| Scanner audio from the RTL-SDR (end to end) | **Still needs ear/over-the-air QA**: native USB streaming and DSP tests pass, but reception quality, antenna-dependent signals, and user-facing scan-list workflows still need field verification. | hardware/unit tests; no listening QA yet |
| Search | **First-pass UI fix 2026-10-04**: Search no longer opens as a blank black page when no query is entered. It now has a native empty state with example queries. Recents, semantic search and FTS-backed ranking are still open. | Running app visual QA with mock data; screenshots in `/tmp/signalhive-visual/09-search-fixed.png` |
| Decoders | ADS-B (1090) and UAT/FIS-B (978) are wired into Air Map / Air Data through their own receivers. **Decoder Hub exists now**: ACARS text, AIS NMEA and Morse dot/dash inputs can be decoded manually in-app. **DecoderSession exists in core** for direct/channelized IQ, async output, retained messages and live stats; the Decoder Hub now has Start/Stop demo-IQ controls for Morse and ACARS that run through `DecoderSession` and display live stats/messages. Unsupported decoders now show a quiet unavailable live-session state instead of a misleading disabled start button, and switching decoders clears stale session output. Real app source pickers and RTL-SDR capture for ACARS/AIS/ISM/RS41/LRPT/paging are still pending. The embedded driver has ISM-sensor, Meteor LRPT and RS41 radiosonde decoders with `rtlsdr-tool` commands; Workshop exposes them as driver-ready but not-yet-connected app capabilities. **None has received a live over-the-air signal** (driver's own `docs/DECODERS.md`) | Unit tests with synthetic/generated messages; `DecoderWorkbenchTests`; `DecoderSessionTests`; `WorkshopCatalogTests`; `script/build_and_run.sh --verify`; `script/check_sf_symbols.sh`; running app visual QA with ACARS demo IQ |
| Satellite planning | **First native pass planner built**: the Satellites screen fetches current weather-satellite TLEs from CelesTrak, uses a manual/Air Map/device antenna location, and computes upcoming passes with peak elevation, azimuth and range. It is a scheduling foundation, not full SatDump capture yet. `SatelliteCaptureRecipe` (core, tested, **not shown in the UI yet**) turns a pass into a capture plan (padded window, downlink, sample rate) and returns nothing for satellites an RTL-SDR cannot receive. `SatelliteImageProduct.simulated` exists in the same file: it is invented data and must never be shown as a real product | Running app visual QA: 9 weather elements fetched and 39 passes calculated for a manual test observer; `SatellitePassPlannerTests` |
| AI Lab: providers, router, RF Coach | **2026-10-04: `AIRouter` built** (`AI/AIRouting.swift`, `AI/FoundationModelsProviders.swift`; `AIRouterTests`, 21 tests through fake providers). Providers: `RulesProvider` (always on, deterministic), `FoundationOnDeviceProvider`, `PrivateCloudProvider`. Automatic order is on-device then rules; **Private Cloud Compute is never in the automatic order**, only when the user picks it and presses "Ask Private Cloud Compute" (a test fails if it is added to the order). The rules answer is computed first and handed to every model as facts it must not contradict, and it is shown under the model's answer. Each answer says who answered, from which inputs, why any provider was skipped or failed, and how long it took. The RF Coach sheet (Browse detail, Scanner, Trunked, AI Lab) runs on the router with a provider picker. **Verified live on the owner's Mac:** the on-device model streamed an answer in AI Lab (3.3 s) consistent with the rules facts, Rules only answered instantly, Private Cloud showed its consent panel. **Not exercised:** an actual Private Cloud Compute request (it sends the context off the Mac), and the MLX provider (no runtime). Models are prompted with plain text and a three-line reply format, not `@Generable`, because the package cannot use the macro. Core ML classifier package does not exist; MLX model downloads work (tested; multi-GB, not exercised live in the UI), no MLX inference runtime | Driven in the running app; `AIRouterTests`; `AIWorkbenchModelsTests`; `ModelDownloadTests`; opt-in `SIGNALHIVE_LIVE_AI=1 swift test --filter FoundationModelsLiveTests` |
| App icon asset | The asset art is an opaque full-bleed square; the Dock tile is drawn onto the macOS icon grid at runtime. Redraw the asset (or use an Icon Composer `.icon`) | Screenshot of the Dock; `sips` shows no alpha |
| SF Symbol names | **Pass 2026-09-30**: 112 distinct names, 0 invalid, after fixing 5 that rendered blank | `script/check_sf_symbols.sh` |
| Radio programming (Baofeng, Uniden, CHIRP CSV) | Core code and CSV round-trip tests; not tested against hardware | |

## 5. Bugs found and fixed

1. **Browse empty (data never loaded).** In-app import was buried in Settings, so the database stayed empty;
   archive names for 5 of 7 FCC services were wrong; `LO.dat` coordinates were read one column off; the importer
   held whole tables in memory, never deleted its extraction directory, and duplicated rows on re-import.
   Fixed by the data foundation (see `docs/superpowers/`).
2. **Codeplugs never saved.** `AppDatabase.saveCodeplug` declared a local struct named `Row`, so GRDB wrote to a
   table called `row`; `AppModel` hid the failure with `try?`. Replaced by `UserDatabase`.
3. **Licensee rows but no frequencies visible** (owner-reported with the Arizona pack). The pack held the
   frequencies (verified by querying it); the Browse UI put the detail behind a link that did not navigate.
   Fixed by GPT's Browse rework (frequency detail is shown in the Browse workspace).
4. **App crashed at about half of launches** (owner-reported: "it won't launch"). Root cause:
   `RTLSDRBridge.deviceSerial` passed a **64-byte** buffer to `rtlsdr_get_device_usb_strings`, which per
   `rtl-sdr.h` writes up to **256** bytes. With a dongle attached, each scan overflowed the heap; the corruption
   then crashed the process in an unrelated later `malloc` (inside libusb or SwiftUI layout). It surfaced once the
   Workshop screen started scanning at every launch. GPT had seen the symptom ("open did not leave a process") and
   attributed it to LaunchServices. Evidence: `scan()` alone crashed a headless test; bisecting providers isolated
   the RTL-SDR one; the crash stack ran through `deviceSerial` into `libusb_init`; a plain C probe with 256-byte
   buffers was clean. Fixed with a 256-byte, always-terminated buffer and a regression test (`RTLSDRBridgeTests`).
   Also fixed: Workshop capability tiles had a fresh `UUID()` on every render.
   A code comment in `SDRDeviceManager` blames libusb's hotplug thread for "heap corruption if no device is
   connected"; that diagnosis was wrong (the overflow needs a device). The launch-time scan is safe again.

6. **Selecting a Trunked system crashed the app** (found 2026-09-30, reproduced every time). `TrunkedView` had two
   `.searchable` modifiers in one window, one per column of its `NavigationSplitView`. On macOS 27 SwiftUI asked
   `NSToolbar` for a second search item during layout and AppKit threw (`NSToolbar
   _insertNewItemWithItemIdentifier:atIndex:propertyListRepresentation:notifyFlags:`, surfaced as
   `+[NSApplication _crashOnException:]` with no app frames). Fixed: the talkgroup search is an inline field. **Rule:
   one `.searchable` per window.** Not covered by any test (no app-layer test target).
7. **Dock icon blank in the running app** (owner-reported). The plist had `CFBundleIconName` but not
   `CFBundleIconFile` (fixed in `939285c`), and LaunchServices still showed a blank tile for the rebuilt ad-hoc-signed
   bundle. `MacAppDelegate.swift` sets `NSApp.applicationIconImage` at launch, drawn as a rounded tile because the icon
   art is an opaque square.
8. **`script/build_and_run.sh` failed intermittently with LaunchServices `-600`**: `open` ran while the killed
   instance was still exiting. The script now waits for it.
9. **Blank icons**: `plus.memorychip`, `usb`, `satellite`, `shippingbox.and.arrow.down` and `turbulence` are not SF
   Symbols, and a wrong name compiles and renders nothing. Replaced; `script/check_sf_symbols.sh` catches the class.
10. **USB access regressed because the rebuilt macOS targets were still sandboxed.** The project notes said the app is
    deliberately unsandboxed, but `project.yml` still set `CODE_SIGN_ENTITLEMENTS` for both macOS targets and those
    files enabled `com.apple.security.app-sandbox`. Fixed by removing those build settings, emptying the unused
    entitlement files, regenerating the project, rebuilding, and verifying the signed app contains no sandbox
    entitlement.

11. **Satellite capture recipe guessed wrong** (found 2026-10-04 in Codex's uncommitted `SatelliteAutomation.swift`, before any UI used it). The Meteor-M2 4 frequency matched the string "N2-4", which CelesTrak's "METEOR-M2 4" does not contain, so it fell through to 137.9 MHz; and `bestGuess` defaulted every unknown satellite (Suomi NPP, GOES, NOAA 20, the ISS) to "Meteor LRPT". Now `SatelliteCaptureMode.downlink(for:)` matches on letters and digits only and returns nil for anything an RTL-SDR cannot receive; `make(for:)` returns an optional. Covered by `SatellitePassPlannerTests`.

5c. **Scanner spectrum wrong** (owner-visible): `FFTProcessor` ran a complex FFT but kept only the first N/2 bins, so
   everything below the centre frequency was invisible and the centre sat at the edge; `FrequencyFinder` (which
   assumed the correct layout) therefore reported wrong frequencies; the waterfall state was never fed. Fixed with
   tone-position tests. Also: fixed dB range replaced by a noise-floor-relative auto scale.
5b. **Dongle configured in direct-sampling mode** (bypasses the tuner, HF only): `configure()` called a method named
   `setIQBalance` that was wired to `rtlsdr_set_direct_sampling(on: 1)`. Reproduced on the real dongle (read-back
   said mode 1); fixed and covered by a hardware test (`RTLSDRHardwareTests`).

## 6. Known issues and gaps (not yet fixed)

**Owner report (2026-09-29, after using the build):** Workshop features, radio features and AI Lab features that do
not work; the Scanner is not yet a real scanner (no scan lists, sweep, hold/skip/lockout, identification, saved
channels); trunking does not work. **2026-09-30 audit result** (`docs/UI_AUDIT_2026-09-30.md`): Workshop and AI Lab
were information screens, Decoder Hub did not exist yet, and Trunked had a crash (fixed). The audit holds the
per-screen verdicts, 12 cross-cutting UI findings and the build spec. The remaining gaps, in short:

- **Workshop** now has the action model (done 2026-10-04). Remaining gaps: a **Recent** row (last tuned frequency, last
  codeplug, last system; nothing records these yet), live per-tile metrics beyond readiness, and the Air Map demo-sky
  decision (U6).
- **AI Lab has one invocable tool**: RF Coach (Explain), now routed through `AIRouter` (rules, on-device model, Private
  Cloud Compute on request). The Explain sheet is wired into Browse detail, Scanner, Trunked and AI Lab. Still open:
  Codeplug review, session log and report, an MLX provider and inference runtime, Core ML classifier assets, the
  rules-based signal ID, semantic FCC search. The **Air Data briefing is done** (2026-10-04): `AviationBriefing` plus
  `AITask.briefAviation`. `AITask` has `explainSignal` and `briefAviation`; add cases as
  those tools are built.
- **Decoder Hub is started, not finished**: ACARS text, AIS NMEA and Morse pattern decoding work manually in-app, and
  `DecoderSession` now provides the tested direct/channelized-IQ session core. The hub can start/stop Morse and ACARS
  demo-IQ sessions through `DecoderSession`; real RTL-SDR source selection/capture for ACARS, AIS, ISM, radiosondes,
  LRPT, paging and weak-signal sessions is still open. Satellites can schedule passes but cannot start an LRPT capture
  session yet.
- Air Map's demo sky has no UI entry (button removed in `80cdfc6`) while the Workshop text still promises it.
- The USB error text in the upstream driver always blames a missing sandbox entitlement for `0xe00002e2`.
- Browse shows five columns at the default window and two "Select a County" placeholders: too cramped. It needs a
  larger default window and a leaner layout.
- Power shows "0 W" for mobile-class frequencies; zero should be hidden.
- Every non-installed state says "Build locally"; no hosted pack server exists yet (the manifest URL is a
  setting: `packBaseURL`). Local build of the large public-safety file (LMpriv, ~423 MB) has not been timed.
- FCC ULS has no talkgroups, CTCSS/DCS tones or alpha tags. Trunked-system data needs its own approach
  (self-discovery by decoding control channels; optional OpenMHz was approved as an opt-in source).
- `SDRDeviceManager.scan()` runs six providers; RTL-SDR has been exercised on real hardware through the native Swift
  driver. Other source types still need hardware/provider QA.
- SwiftRTLSDR PR #1 is merged upstream; SignalHive's embedded copy also matches the published decoder branch with
  ADS-B, UAT/FIS-B, ISM, Meteor LRPT and RS41 work. Remaining integration work: wire host gain control, expose rtl_tcp
  server/client and EEPROM controls, build SignalHive's true multi-hop scan engine UI on top of `RTLSDRScan.BandScanner`,
  and add app capture sessions for ISM, radiosondes and LRPT.
- App Sandbox and direct RTL-SDR USB access are not currently compatible in this build. Do not re-enable sandboxing
  for the macOS targets until IOUSBHost access is proven on real hardware inside the sandbox, or until the driver is
  moved behind a privileged helper / DriverKit path.
- No test target exists for the app layer (views/model); only the package is unit-tested.
- Agency grouping and Census county names (planned in the data plan, Task 10) are not built.

## 7. Roadmap

Scanner sub-project (owner priority): see `docs/superpowers/specs/2026-09-29-scanner-design.md`. Order:
S1 correct spectrum/waterfall/tuning (**done**), S2 channelizer + scan engine + identification + saved channels
(core, tested), S3 scanner UI, S4 trunking/decoder hand-off.
Radio workshop feature map and research notes: `docs/superpowers/specs/2026-09-29-radio-workshop-feature-map.md`.

**Next (owner priority, 2026-09-30): make Workshop and AI Lab function.** The ordered build list, with file names,
APIs to use and acceptance criteria, is section 7 of `docs/UI_AUDIT_2026-09-30.md`:

1. ~~Workshop action model (`WorkshopAction`), catalog fixes, quick actions, real readiness gauge.~~ **Done 2026-10-04** (Recent row still open).
2. ~~AI provider layer (`LanguageModelProvider`, `AIRouter`, rules + Foundation Models)~~ **Done 2026-10-04**, and the Explain tool wired into
   Browse detail, Scanner and Trunked; the AI Lab rules-only RF Coach seed is done, the Air Data briefing is done
   (2026-10-04), then Codeplug review.
3. **Decoder Hub live sessions** (`DecoderSession` core is done; ACARS/AIS/Morse manual workbench is started; Morse
   and ACARS now have app start/stop controls for demo IQ through `DecoderSession`, next is real RTL-SDR source
   selection/capture, then AIS, ISM, radiosondes, LRPT). Satellites now has pass scheduling and should hand passes into
   LRPT capture when that session model is surfaced in the app.
4. One design language and grouped sidebar; the layout fixes in the audit (U1 to U10).
5. Session log and report; MLX inference runtime and local assistant; signal ID; semantic FCC search.

Still open from before, unchanged:

6. Verify and fix **Scanner with the local RTL-SDR** over the air (antenna, tune, spectrum, waterfall,
   AM/NFM/WFM demod audio, scan lists), and true multi-hop scanning with FCC identification.
7. Replace external adapters (`dsdccx`, `multimon-ng`) with original Swift decoders (paging first).
8. Weather/satellite capture (NOAA APT audio/images, Meteor LRPT capture/image gallery/Doppler assist/SatDump-style
   product browser), radio programming against real hardware, GPS/serial hardware.
9. Hosted packs and weekly automation (needs a repository the owner creates).

## 8. How to build, run and test

```bash
xcodegen generate                                   # project.yml is the source of truth
python3 script/register_app_sources.py              # register new App/ files in the committed .xcodeproj (CI checks)
script/build_and_run.sh --verify                    # build and launch the macOS app
script/build_and_run.sh --mock-data                 # launch with the built-in demo dataset
script/build_and_run.sh --support-directory DIR     # keep app data isolated (also: -supportDirectory DIR)
cd Packages/SignalHiveCore && swift test --skip RTLSDRHardwareTests   # 493 tests; hardware tests need the dongle free
script/check_sf_symbols.sh                          # every SF Symbol name in the code resolves (macOS)
script/launch_stability_test.sh 20                  # launch the built app N times and count crashes
```

Only one program can hold the dongle: quit the app before running `RTLSDRHardwareTests`.

Tips: builds on the external volume are slow; use `swift test --scratch-path <internal dir>` and
`xcodebuild -derivedDataPath <internal dir>`, **but check `df -h /System/Volumes/Data` first**: on 2026-10-04 the internal
disk hit 100% (about 1.8 GB of that was build caches) and builds failed with "no space left on device". That session
kept its caches on the external volume in `/Volumes/Artificial_Intelligence_Machine_Learning/claude-build-cache/`, which is
safe to delete. Crash reports land in `~/Library/Logs/DiagnosticReports/`.
Real-archive tests are opt-in via `SIGNALHIVE_REAL_ARCHIVES`.

Owner's real Arizona pack (read-only reference):
`~/Library/Containers/com.noktirnal42.SignalHive/Data/Library/Application Support/SignalHive/Packs/`.

## 9. Owner QA checklist (things only the owner's Mac can verify)

Keep this list honest: add what a change needs checked, tick it when the owner confirms.

- [ ] Scanner: Start on the RTL-SDR, hear a known NFM/AM signal, squelch, scan bank, hold/skip/lockout, save.
- [ ] Workshop launches: "Listen: NOAA weather" (162.550 NFM) and "Listen: aircraft guard" (121.500 AM) open Scanner, tune, and start on the dongle (audio plays; keep the volume down); "Track aircraft" and the ADS-B / UAT tiles start the 1090 / 978 MHz receiver on the Air Map / Air Data.
- [ ] Satellite downlinks: confirm 137.100 MHz (Meteor-M2 4), 137.900 MHz (Meteor-M2 3) and the NOAA APT frequencies against a current source before the capture recipe is shown in the UI; operators have moved them before, and NOAA 15/18 may no longer be transmitting.
- [ ] Air Map / Air Data: 1090 MHz and 978 MHz receivers with an antenna; first position fix; FIS-B radar.
- [ ] Satellites: refresh current TLEs from the owner's location, compare at least one pass time/elevation against a trusted tracker, then use a real antenna to capture a Meteor LRPT pass.
- [ ] Foundation Models and Private Cloud Compute availability match what AI Lab reports.
- [ ] Air Data "Brief me" with a real picture from the receivers (it was verified with the demo sky): the briefing's numbers match the facts underneath it.
- [ ] RF Coach "Ask Private Cloud Compute": press it once on a harmless frequency; the answer should be labelled Private Cloud Compute, or the fallback note should say why not (quota, network, entitlement). The on-device path was verified on 2026-10-04.
- [ ] MLX: download a 1B model, then (once the runtime exists) run it and check memory use on 18 GB.
- [ ] Dock icon after a fresh install (not just a rebuild).
- [ ] Trunked: add a talkgroup to a codeplug and see it in Codeplug.
- [ ] Radio programming against a real radio (Baofeng UV-5R, Uniden).
