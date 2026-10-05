# SignalHive — Project Status and Handoff

Last updated: 2026-09-30 (later). This is a living document: update the "Verified status" table whenever something is
tested, and add to "Bugs found and fixed" whenever a root cause is found.

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
| current | Codex (GPT) | Synced SwiftRTLSDR PR #1 into `Packages/SwiftRTLSDR`; added `RTLSDRScan` dependency, noise-floor-aware finder bridge, scan models/activity log, Scanner UI rail with live hits, hold/skip/lockout/save, starter scan bank, decoder quick-tune queue, and a research-backed radio workshop feature map. |

| Claude cloud session, branch `claude/vibrant-einstein-ro06r5` (PR #1) | Claude Code (cloud) | **Air Map + Air Data** (ADS-B/UAT/FIS-B, see `docs/AVIATION.md`), embedded SwiftRTLSDR synced to upstream draft PR #2, codeplug editor/validator/CHIRP, Trunked browser (tolerant OpenMHz client, offline cache, talkgroup categories), Workshop computed from real facts, one-pass "Get FCC data" flow, real Hugging Face model downloader, CI on a macOS runner. **This sandbox has no Swift toolchain: nothing was compiled or run locally. Every "passes" below comes from GitHub Actions runs (macos-26).** |

The Codex session (for reference): `~/.codex/sessions/2026/09/29/rollout-2026-09-29T17-17-28-01a0efac-*.jsonl`,
thread "Fix and finish SignalHive".

## 3. Architecture

```
App/                          SwiftUI apps (macOS, menu bar, iOS); XcodeGen source of truth is project.yml
  Shared/Design/              Visual system (HiveInk palette, instrument panels, meters, spectrum ribbon)
  Shared/Views/               Workshop, AILab, Browse, Search, Trunked, Scanner, Codeplug, FrequencyDetail, Settings
  Shared/Stores/AppModel      App state: packs, browse data source, user data, local build, get-data job, codeplug
  Shared/Stores/ModelLibrary  Downloaded AI models and downloads in flight (outlives the AI Lab screen)
  Shared/Aviation/            AviationModel (sources, receivers) and the icon renderer for the map
Packages/SignalHiveCore/      All logic, UI-free
  Data/ULS, Data/Packs        FCC ULS -> per-state SQLite packs (builder, store, manifest, county/emission parsing)
  Data/Browse                 BrowseDataSource protocol, real (pack) and mock implementations
  Data/Packs/DataPlan         Which states come from hosted packs and which are built, in one FCC download pass
  Data/ModelDownload          Hugging Face listing, verified resumable model downloads (AI Lab)
  Data/OpenMHzClient          OpenMHz parser/client, on-disk cache, repository with offline fallback
  Aviation/                   ADS-B/UAT/FIS-B model: aircraft, trails, radar, messages, METAR, receivers, demo scenario
  Models/                     Codeplug + radio capabilities, trunked systems/talkgroups + browsing, WorkshopCatalog
  Data/User                   UserData.sqlite (codeplugs), migration from the legacy database
  HAL/                        SDR devices: native Swift RTL-SDR, HackRF, Lime, SDRplay, Airspy, Pluto, network, test
  DSP/                        FFT, demodulators, decoders, classifier, description engine
  AI/                         AI workbench model: features, providers, MLX candidates, local-machine profile
  Cloning/                    Baofeng, Uniden protocol, CHIRP CSV
  Voice/, CMbelib/            P25 voice path (mbelib carries a patent notice)
  Sources/signalhive-packbuilder   CLI that builds packs from FCC archives
```

Data flow: FCC weekly archives -> `PackBuilder` (active licenses only, streamed) -> one compressed SQLite pack per
state + `manifest.json` -> `PackStore` (download, SHA-256 verify, decompress, atomic install) ->
`PackBrowseDataSource` -> views. The app can also build packs itself ("Build from FCC on this Mac").

## 4. Verified status (2026-09-29, macOS 27 / Xcode 27.0 / Swift 6.4)

| Area | Status | Evidence |
|---|---|---|
| Package tests | Pass: SignalHiveCore 140 non-hardware tests / 31 suites; SwiftRTLSDR 99 kit tests + 31 scan tests + 14 server tests | `swift test --skip RTLSDRHardwareTests` in SignalHiveCore while the running app held the dongle; `swift test` in SwiftRTLSDR |
| macOS, menu-bar and iOS targets build | Pass | `xcodebuild` for all three schemes |
| App launches without crashing | **Pass** after fix: 0 of 20 launches crashed (was 4 of 8) | `script/launch_stability_test.sh` |
| FCC data: state -> county -> licenses -> frequencies | **Pass** with the owner's real Arizona pack (6,049 licenses, 13,101 sites, 41,354 frequencies, all 15 counties) | Driven in the running app: Coconino County lists licensees; the detail pane shows call sign, service, dates and frequencies with mode/bandwidth |
| RTL-SDR detected over USB | **Native Swift path integrated.** SignalHive now depends on `Packages/SwiftRTLSDR` and uses `NativeRTLSDRDevice` over Apple's IOUSBHost API; no `dlopen(librtlsdr)` is used for RTL-SDR. The local macOS app is intentionally unsandboxed because IOUSBHost whole-device open is blocked in the App Sandbox on the tested RTL2832U/R820T dongle. | SignalHiveCore hardware tests exercised the attached dongle; sandboxed self-test failed before unsandboxing with `IOKit 0xe00002e2` / `0xe00002c9` |
| Pack builder on real FCC data | Pass for LMcomm: 5.3 s, 47 MB peak, 55 packs / 3.4 MB | `docs/superpowers/specs/2026-09-29-data-foundation-spike.md`. LMpriv not measured by Claude; the owner's Arizona pack shows it works in the app |
| Scanner display: spectrum, waterfall, tuning, volume | **Fixed and verified on the real dongle (S1)**: full centre-shifted spectrum, fed high-resolution waterfall (2048x400 pixel buffer, inferno palette, 25 rows/s, selectable 125 Hz - 1 kHz detail), auto-scaling, typed/stepped/click-to-tune frequency snapped to the step grid, volume + mute. Tests: FFT tones, waterfall buffer, palette, throttle, frequency entry, volume | Running app with the RTL-SDR; 102 tests |
| Scanner activity workflow | **Partial S3 built**: live passband activity detection now uses `RTLSDRScan.PeakDetector` with a local noise floor; UI shows activity hits, tune, hold/release, skip, lockout/unlock, save-to-codeplug, starter scan bank, decoder quick-tune presets, and a repaired source rail. True multi-hop scan-list sweeping and FCC identification are still next. | `swift test --skip RTLSDRHardwareTests`; macOS app build |
| Channelizer (select one channel out of the capture) | **Built and tested (S2a)**: `ChannelDownconverter` (mix to baseband, two-stage filter, decimate to ~48 kHz), wired into `DSPPipeline` via `channelOffsetHz`; squelch measures the channel, not the band. Tests: >60 dB rejection of other signals incl. a 20 dB-stronger neighbouring channel, block-size independence, FM recovered next to a strong interferer, offset selects which of two signals is heard | 113 tests |
| Scanner audio from the RTL-SDR (end to end) | **Still needs ear/over-the-air QA**: native USB streaming and DSP tests pass, but reception quality, antenna-dependent signals, and user-facing scan-list workflows still need field verification. | hardware/unit tests; no listening QA yet |
| Air Map / Air Data (ADS-B, UAT, FIS-B) | **Builds and core logic tested in CI; never run over the air.** 1090 MHz and 978 MHz pipelines decode published test frames to the expected values; map, trails, radar raster, message feed and METAR decoding have unit tests. The UI compiles for macOS and iOS but has not been looked at by a person. | GitHub Actions run of commit `19e5ed9`: core 363 tests, macOS + iOS app builds, committed-project build |
| Decoders (ACARS, AIS, Morse, paging, P25/DMR metadata, FT8) | **Library only.** The decoder classes exist in core, but the Scanner never attaches any of them to the pipeline or shows decoded messages, so the app decodes none of these. Workshop now says so ("Not connected yet"). ADS-B and UAT are the only decoders wired into the app (through Air Map). | code reading: `DSPPipeline.attachDecoder` has no caller in `App/` |
| Trunked (OpenMHz browser) | Parser, cache, repository fallback, categories and filters unit-tested against fixtures written from OpenMHz's own server code; **not run against the live service** (the sandbox cannot reach it). It lists systems and talkgroups; it does not follow calls. | CI core tests |
| Codeplug | Validator, editing helpers, CHIRP CSV import/export, tone catalogs unit-tested; editor UI builds. Direct serial write exists only for the radios `supportsDirectWrite` allows and has not been tried on hardware. | CI core tests + app build |
| Workshop | Tile statuses computed from facts about the machine (`WorkshopCatalog`, unit-tested); tiles navigate. | CI |
| Get FCC data (Browse) | `DataPlan` (which states download, which build, one shared FCC pass) unit-tested; `GetDataSheet` and the job runner in `AppModel` compile but have not been run. | CI |
| AI Lab (Foundation Models / PCC probes, MLX catalog) | Builds; catalog/compat logic unit-tested. **Model downloader now real** (list files, download, verify size + SHA-256, resume at file granularity, refuse unsafe paths), tested with a fake transport; **not exercised against Hugging Face** (unreachable from the sandbox). No inference runtime uses downloaded models. | CI core tests |
| App icon | Built into the asset catalog; not visually reviewed by Claude | |
| Radio programming (Baofeng, Uniden serial) | Not tested against hardware. Uniden serial helpers have no UI. | |

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
channels); trunking does not work. A full feature audit (every screen driven in the running app, plus code review)
is the next task after the channelizer; results go into a table below.

- Browse shows five columns at the default 900x450 window (app sidebar, states, counties, licenses, detail):
  too cramped. It needs a larger default window and a leaner layout.
- Power shows "0 W" for mobile-class frequencies; zero should be hidden.
- Every non-installed state says "Build locally"; no hosted pack server exists yet (the manifest URL is a
  setting: `packBaseURL`). Local build of the large public-safety file (LMpriv, ~423 MB) has not been timed.
- FCC ULS has no talkgroups, CTCSS/DCS tones or alpha tags. Trunked-system data needs its own approach
  (self-discovery by decoding control channels; optional OpenMHz was approved as an opt-in source).
- `SDRDeviceManager.scan()` runs six providers; RTL-SDR has been exercised on real hardware through the native Swift
  driver. Other source types still need hardware/provider QA.
- SwiftRTLSDR PR #1 is merged and embedded. Remaining integration work: wire host gain control, expose rtl_tcp
  server/client controls, and build SignalHive's true multi-hop scan engine UI on top of `RTLSDRScan.BandScanner`.
  Claude's follow-on dump1090 and dump978 work should be handled the same way: upstream first, then embedded-copy sync
  and SignalHive integration.
- App Sandbox and direct RTL-SDR USB access are not currently compatible in this build. Do not re-enable sandboxing
  for the macOS targets until IOUSBHost access is proven on real hardware inside the sandbox, or until the driver is
  moved behind a privileged helper / DriverKit path.
- No test target exists for the app layer (views/model); only the package is unit-tested. Everything in
  `App/Shared/Views` from the aviation/trunking/codeplug/get-data/model-download work is compile-checked only.
- **Dongle exclusivity.** Scanner and Air Map/Air Data each open an RTL-SDR; only one may hold a given dongle. There is no
  arbiter yet: start one and stop the other by hand. Two dongles are needed to receive 1090 and 978 MHz together.
- **Embedded SwiftRTLSDR is synced to a draft.** `Packages/SwiftRTLSDR` matches upstream PR #2's head (`6bf6398`), not
  `main`. Re-sync when that PR changes or merges; the two driver timing tests that fail in CI (job is informational) are
  upstream's.
- METAR flags on the Air Map need an airport-coordinate dataset; Air Data lists the reports without positions.
- Airspy, LimeSDR, SDRplay and PlutoSDR appear as sources, but their `startStreaming` throws "not yet product-proven".
  OpenWebRX is a first-pass implementation. HackRF needs libhackrf. The Workshop states this.
- ACARS/AIS/Morse/paging/P25-DMR-metadata/FT8 decoders are not connected to the Scanner (see status table).
- Downloaded MLX models sit in Application Support; nothing runs them. Gated Hugging Face repositories are refused
  (no sign-in). A partly downloaded file restarts (resume is per file, not per byte).
- "Streamline browser downloads" was read as the Browse FCC data flow (plus the AI Lab model queue). If it meant
  something else, say so.
- Agency grouping and Census county names (planned in the data plan, Task 10) are not built.

## 7. Roadmap

Scanner sub-project (owner priority): see `docs/superpowers/specs/2026-09-29-scanner-design.md`. Order:
S1 correct spectrum/waterfall/tuning (**done**), S2 channelizer + scan engine + identification + saved channels
(core, tested), S3 scanner UI, S4 trunking/decoder hand-off.
Radio workshop feature map and research notes: `docs/superpowers/specs/2026-09-29-radio-workshop-feature-map.md`.

1. Verify and fix **Scanner with the local RTL-SDR** over the air (antenna, tune, spectrum, waterfall,
   AM/NFM/WFM demod audio, scan lists).
2. A **Decoder Hub** that puts the remaining decoders behind a UI (ADS-B/UAT map is done; Morse, ACARS, AIS, paging next:
   attach them to the pipeline and show `DecodedMessage`s).
3. Browse layout and detail polish; window sizing; mode/power display.
4. Replace external adapters with original Swift decoders (paging first).
5. Weather/satellite (NOAA APT, Meteor LRPT), radio programming against real hardware, GPS/serial hardware.
6. AI: Foundation Models features; an MLX inference adapter for the downloaded models.
7. Hosted packs and weekly automation (needs a repository the owner creates).

## 8. How to build, run and test

```bash
xcodegen generate                                   # project.yml is the source of truth
script/build_and_run.sh --verify                    # build and launch the macOS app
script/build_and_run.sh --mock-data                 # launch with the built-in demo dataset
script/build_and_run.sh --support-directory DIR     # keep app data isolated (also: -supportDirectory DIR)
cd Packages/SignalHiveCore && swift test            # package tests (68)
script/launch_stability_test.sh 20                  # launch the built app N times and count crashes
```

Tips: builds on the external volume are slow; use `swift test --scratch-path <internal dir>` and
`xcodebuild -derivedDataPath <internal dir>`. Crash reports land in `~/Library/Logs/DiagnosticReports/`.
Real-archive tests are opt-in via `SIGNALHIVE_REAL_ARCHIVES`.

Owner's real Arizona pack (read-only reference):
`~/Library/Containers/com.noktirnal42.SignalHive/Data/Library/Application Support/SignalHive/Packs/`.
