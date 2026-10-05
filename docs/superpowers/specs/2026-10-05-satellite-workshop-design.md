# Satellite Workshop: design

Status: **draft for owner review** (2026-10-05). Brainstormed and approved section by section in conversation; this
file is the written spec. Nothing here is built yet. The implementation plan follows once this is approved.

## 1. Intent

The owner picks passes (or satellites to follow) from a list. SignalHive then does the rest without help: it predicts the
passes precisely, takes the dongle at acquisition of signal, tunes with Doppler correction, records, decodes live, and
files the images and data in a library. A modern visualizer, a rebuilt and improved take on SatDump's decoding view,
shows what is happening and afterwards explains what happened.

Success looks like: tick a Meteor-M pass on Monday; on Tuesday the Library holds a real decoded image of it, a SigMF
recording that can be replayed, and a report card saying how good the reception was and why. When a pass could not be
received, the app says so and why, never an empty or invented result.

**Decided in conversation**

- Automation runs **while SignalHive is running** (the Mac awake). No background agent now. The engine is UI-free so a
  headless runner or agent can be added later.
- The owner has the NooElec mast kit now, may add a 137 MHz antenna, may add a dish + LNA for 1.7 GHz, and may buy
  more. So **antennas are profiles the app knows about**, and every pass is rated against them.
- The owner has **no motorized tracker** but wants the capability to drive one.
- The owner wants **transmit in a future SignalHive** (HackRF One or another TX-capable SDR). Out of scope here, but it
  constrains four decisions below (section 11).

## 2. Facts this design rests on (checked 2026-10-05)

| Fact | Consequence | Source |
|---|---|---|
| NOAA-15, -18 and -19 were all decommissioned in 2025 (June to August); no satellite transmits APT now | The existing APT recipes for them are untruthful and are removed. APT is not a target. Verify each satellite's status against SatNOGS DB at implementation time | Search results citing [NOAA-15](https://en.wikipedia.org/wiki/NOAA-15) and a [hobbyist write-up](https://vu3dxr.in/the-end-of-noaa-15-and-noaa-19-whats-next-for-weather-satellite-hobbyists/); secondary, not yet confirmed against SatNOGS |
| Meteor-M N2-3 and N2-4 transmit LRPT on 137.1 and 137.9 MHz; N2-3's antenna deployed badly, so it is weak. Sources disagree about which satellite uses which frequency | Frequencies come from data (SatNOGS) with a verified-on-air override list, not constants. N2-3 gets a "weak" strength class | [SatNOGS DB M2-3](https://db.satnogs.org/satellite/TLCE-8079-2988-7210-7028/), [M2-4](https://db.satnogs.org/satellite/VSVI-4798-5613-4587-2414/) |
| CelesTrak's 5-digit catalog numbers ran out on 2026-07-11; new objects have 6-digit numbers and **no TLE** | Use GP/OMM (JSON or CSV), not TLE. The current code requests TLEs | [CelesTrak usage policy](https://celestrak.org/usage-policy.php) |
| CelesTrak GP data may be fetched once every 2 hours | `ElementStore` enforces it and serves a cache | same |
| SatNOGS DB has an open REST API (satellites, transmitters); data is CC BY-SA | Runtime fetch with cache and on-screen attribution | [API docs](https://docs.satnogs.org/projects/satnogs-db/en/latest/api.html) |
| ISS: voice and SSTV events on 145.800 MHz, APRS on 145.825 MHz; an ARISS SSTV event in May 2026 used 437.55 MHz (Robot36) | Phase 5 targets; both inside the mast kit's range | [ARISS](https://www.ariss.org/press-releases/may-08th-2026) |
| The existing planner is a simplified two-body model, not SGP4 | Not good enough for Doppler-grade tuning; replaced | `SatellitePassPlanner.swift` |
| The embedded driver decodes Meteor LRPT end to end (72k and 80k) and exposes `status` (SNR, lock, carrier offset, symbol rate), `recentSymbols` (constellation), per-frame RS/Viterbi results, and an imager with channels and a composite | The Cockpit is built on real driver telemetry, nothing invented | `Packages/SwiftRTLSDR/Sources/RTLSDRDecoders/LRPT` |
| Hardware today: one RTL2838 dongle, no live signal decoded yet, own spurs at multiples of 4.8 MHz | Spur masking in the Cockpit; "no signal seen" is a first-class outcome; the first real pass is an Owner QA item | `docs/PROJECT_STATUS.md` |

Doppler magnitudes (first order, `f·ṙ/c`): about ±3 kHz for Meteor at 137 MHz, about ±3.4 kHz for the ISS at
145.8 MHz, about ±10 kHz at 437 MHz. All fit inside a 288 kS/s capture, so a typical pass needs no dongle retune.

## 3. Phases (each shippable and ends with something visibly working)

1. **Orbit + Catalog + Passes screen.** SGP4, OMM ingest, pass prediction, ratings, timeline, polar plot, ground track,
   Doppler curve, hand-pointing guide. Deletes the old planner and the stale recipes.
2. **Capture + recorder + replay + LRPT decoder + Cockpit v1.** First real Meteor pass (Owner QA).
3. **Scheduler automation + Library v1.**
4. **Rotator drivers + tracking planner.**
5. **ISS and amateur modes** (FM voice recording, APRS/AX.25, SSTV, CW beacons) and shared-band multi-satellite capture.
6. **Geo-referenced Meteor imagery, composites, pass poster.**
7. **L-band (GOES HRIT/LRIT, MetOp AHRPT / NOAA HRPT)** with a dish. Its own spec.

## 4. Architecture

All of it in `Packages/SignalHiveCore/Sources/SignalHiveCore/Satellite/`, UI-free, actor-based, with a clock and the
SDR device behind protocols so the scheduler and capture can be tested against a fake clock and fake dongle. Views in
`App/Shared/Views/` stay thin.

| Unit | One job | Depends on |
|---|---|---|
| **Orbit** | SGP4 (near-Earth), frames, look angles, range-rate, pass search, sun | nothing |
| **Catalog** | Elements (CelesTrak OMM) and transmitters (SatNOGS), caches, override list, signal-kind mapping | Orbit |
| **Antennas** | Declared antennas: coverage, gain class, directional or not | nothing |
| **Rating** | Pass x transmitter x dongle x antenna -> grade, reasons, remedy | Orbit, Catalog, Antennas |
| **Rotator** | `Rotator` protocol + simulated, Hamlib `rotctld`, GS-232A/B, EasyComm II; pointing planner | Orbit |
| **Scheduler** | Selections as a timeline, conflict solving, state machine, ledger, keep-awake, notifications | Rating, Capture, Rotator |
| **Capture** | Dongle lease, Doppler tracker, SigMF recorder, fan-out, replay | driver, Orbit |
| **Decode** | `PassDecoder` protocol; LRPT first | driver |
| **Library** | Files and an index of real decoded products | Decode |

**Flow.** Elements + transmitters -> pass list with ratings -> the owner ticks passes or "Follow" -> Scheduler arms each
-> at acquisition Capture takes the dongle, runs Doppler-corrected, feeds recorder, decoder and telemetry -> at loss of
signal products are finalized into the Library.

**Truthfulness rules.** `SatelliteImageProduct.simulated` is deleted. Nothing is shown as a product unless it was
decoded from a real or explicitly replayed signal, and a replay is labelled as one. Every satellite is labelled
receivable or not for the owner's setup. A dead satellite is shown as dead and never offered.

## 5. Orbit engine

- **Propagator.** Original Swift SGP4 for near-Earth orbits (period under 225 min, which is every LEO target), written
  from the published equations (Spacetrack Report #3 with the Vallado et al. 2006 corrections), AFSPC-compatible mode.
  Deep-space elements return an explicit `unsupportedDeepSpace` error; GEO relays need fixed pointing, not propagation.
  `Propagator` is a protocol so SDP4 can be added without touching callers.
- **Elements.** `OrbitalElements` from OMM JSON/CSV (6-digit catalog numbers work); TLE text is a legacy path.
  Validation: finite values, eccentricity in range, epoch present. Element age is part of every result.
- **Geometry.** WGS-84 geodetic <-> Earth-fixed, TEME -> Earth-fixed through GMST (IAU-82), azimuth / elevation / range,
  and range-rate with Earth rotation (`v_ecef = R·v_teme − ω × r`). Doppler `f_rx = f_tx·(1 − ṙ/c)`; the uplink
  pre-correction is the inverse (section 11). Documented as ignored: light-time (about 7 ms), polar motion and UT1-UTC
  (at most 0.9 s, hundreds of metres), all below the error of an element set a day old.
- **Pass search.** Coarse scan, then bisection to about 0.5 s for acquisition and loss of signal, golden-section for the
  peak. Each `Pass` carries: AOS/TCA/LOS times and azimuths, max elevation, a track sampled every 5 s, sun elevation at
  TCA (daylight means visible channels are expected), sunlit flag (cylindrical shadow), and the element age.
- **Confidence.** A pass computed from old elements says so and lowers its own confidence. Warn above 7 days for LEO;
  refuse above 30 days.
- **Performance target.** 100 satellites over 7 days in about a second on Apple silicon (initialise each satellite once).
- **Replaces** `SatellitePassPlanner` (two-body) outright. A thin compatibility shim keeps the current view and tests
  compiling during the migration, then is removed.

**Proof of correctness**

1. SGP4 states against the official verification cases and an independent implementation, to sub-metre agreement.
   The oracle is test data only; no reference source is copied (same discipline as the driver's decoders).
2. Pass times against an independent predictor for about a dozen satellite/location pairs: acquisition and loss within
   about 2 s, peak elevation within 0.1 degree.
3. Doppler against the numerical derivative of range from the same propagator and against the independent predictor.
4. Property tests: AOS < TCA < LOS; elevation at the edges equals the threshold; track samples monotonic in time.
5. Owner QA: one real pass compared with a trusted tracker.

## 6. Catalog, ratings, scheduler

**Catalog.** `ElementStore` fetches CelesTrak GP (groups such as weather, amateur, stations, plus individual NORAD
queries), caches on disk with a fetched-at stamp, never fetches within 2 hours of the last fetch, and serves the stale
cache offline with its age shown. The owner can import an element file. `TransmitterStore` fetches SatNOGS transmitters
filtered to 24 to 1766 MHz and to modes we have a decoder for, cached daily, with CC BY-SA attribution on screen. A
bundled, versioned override list wins over SatNOGS for downlinks verified on air, each with a "verified on <date>"
note. Each transmitter maps to a **signal kind** (LRPT, FM voice, SSTV, APRS, CW beacon, BPSK telemetry, unknown) and a
**decoder status** (ready, planned, none).

**Ratings.** A transparent rule set, not a fake dB figure. Inputs: peak elevation, duration, slant range, sunlit,
transmitter strength class (strong / medium / weak, curated), element age, and the antenna's coverage, gain class and
directional/tracking capability. Output: a grade (Excellent / Good / Marginal / Poor / Not receivable), the reasons, and a
remedy ("needs a peak above about 35 degrees with the mast kit"; "no declared antenna covers 1.7 GHz"; "a Yagi needs a
rotator or hand pointing"). The ledger records the SNR and lock actually achieved, so the rules can become
evidence-based ("your mast kit locked on 7 of 12 passes above 40 degrees").

**Scheduler.**
- Selection: tick single passes, or **Follow this satellite** (all its future passes above a chosen elevation and
  rating).
- Conflicts on one dongle resolve by pinned, then rating, then elevation, with a gap for retune and rotator slew.
  Every dropped pass is shown with the reason. Nothing is dropped silently.
- States, persisted in `UserData.sqlite`: planned -> armed (at T minus 5 min: dongle self-test, element freshness, disk
  space) -> capturing -> decoding -> done / partial / failed (reason) / skipped (reason).
- Keep-awake: a power assertion from T minus 10 min to loss of signal plus 1 min. If the Mac was asleep, the pass is
  logged as missed, not failed (a sleeping Mac cannot be woken by this app).
- Launching mid-pass joins it if more than 60 s remain.
- If the Scanner holds the dongle at pass time the app asks 2 minutes before, with a "satellite priority" setting.
- Notifications for upcoming passes and results.

## 7. Capture, Doppler, recording, decoding

- **Plan.** `CapturePlan`: downlink, signal kind, sample rate (LRPT 288 kS/s), bandwidth, gain strategy, ppm from the
  dongle's EEPROM calibration (driver feature), time window.
- **Session.** Lease the dongle from `DongleRegistry`, configure, stream, finalize. The registry stays the single place
  that knows who holds which device.
- **Doppler tracker.** Every 100 ms the orbit engine gives the predicted shift; a phase-continuous complex rotator
  applies it before the demodulator. The dongle LO is retuned only when drift exceeds a threshold, so a typical pass has
  no retunes and no glitches. The decoder's own carrier search absorbs the residue (crystal error, element error). The
  Cockpit plots predicted, applied and residual Doppler.
- **Recorder.** SigMF baseband (`cu8` data + JSON sidecar: sample rate, centre frequency, time, location, antenna,
  satellite, element epoch, driver version). The **raw** stream is recorded, before Doppler correction, so a replay can
  re-track with fresher elements. Retention is configurable (keep always / keep failed or best / auto-prune) with a disk
  check at arming. Budget: 288 kS/s is about 0.5 MB/s, so a 15 min pass is about 0.5 GB; a wideband capture is about 4.3 GB.
- **Fan-out.** Recorder and decoder are never starved. Visual consumers drop the oldest data under load. Telemetry
  reaches the UI at about 10 Hz as an `AsyncStream`; products are coalesced.
- **Failure is explicit.** Unplugged dongle -> partial result with what was decoded. No carrier for N seconds -> "no
  signal seen" with a spectrum snapshot. PLL unlocked -> flagged. Rotator errors warn and never abort a capture.
- **Replay.** Any recording runs through the same decoder and Cockpit, so both can be built and tested without a
  satellite. The driver's LRPT encoder tool generates a synthetic Meteor pass for CI.
- **Decoders.** `PassDecoder` protocol: `feed(iq:)`, a telemetry stream, a products stream, and a declared **stage list**
  that the pipeline strip renders. `LRPTPassDecoder` wraps the driver chain. Audio-domain decoders (FM voice, APRS via the
  existing AFSK demodulator, SSTV) are SignalHiveCore. Anything needing new RF decoding (L-band) goes upstream in the
  driver first.

## 8. Rotator and pointing

`Rotator` protocol: connect, read position, point (azimuth, elevation), stop, limits, slew rate. Implementations in order:
simulated (tests and a "virtual tracker" preview), Hamlib `rotctld` over TCP, then direct serial GS-232A/B and EasyComm II.
The app is unsandboxed, so serial and TCP both work.

The **tracking planner** pre-slews to the acquisition azimuth, checks the rotator can keep up with the pass's slew rate,
chooses the cable-wrap direction so the pass does not hit an azimuth stop, and uses an elevation-flip trajectory for
overhead passes when the rotator allows it. Pointing commands go out at a configurable rate (default 1 Hz).

**Without a rotator**, the sky plot is a hand-pointing guide: a live azimuth/elevation needle and a "point here now"
readout. A static pointing calculator for GEO satellites (GOES) serves the dish case.

## 9. Visual design

Three tabs under Satellites: **Passes**, **Cockpit** (live or replay), **Library**. HiveInk style. SwiftUI Canvas for
light drawing, Metal for the waterfall, constellation and large images (reusing the Scanner's waterfall buffer), MapKit
for the globe and ground tracks, Charts for histories. Every colour-coded state also has a text label; Reduce Motion and
VoiceOver are respected.

**Passes.** A 48 h lane timeline: one row per satellite, bars coloured by grade and sized by peak elevation, day and
night shaded, a "now" line, overlapping passes showing the loser ghosted with the reason, tick to select, "Follow". A pass
inspector: polar sky plot with horizon mask and hand-pointing needle; MapKit ground track with footprint; elevation
profile; Doppler curve with frequency readout; rating reasons, element age and antenna advice.

**Cockpit.**
1. A **pipeline strip**: Dongle -> Doppler -> Demod -> Viterbi -> Frame sync -> Reed-Solomon -> Packets -> Imager. Each
   stage is a live instrument (idle / searching / locked / degraded, key stat, sparkline) that expands on click. The
   decoder declares its stages, so SSTV and APRS reuse the strip.
2. **Waterfall** with the carrier marker and the **predicted Doppler track drawn over the actual signal**; known spurs
   masked.
3. **Density-coloured constellation** with EVM and SNR readouts.
4. **Live image** building line by line: channel tabs, live composite (321, 221, thermal LUTs), and a per-line quality
   strip at the edge marking corrected and lost lines.
5. **Frame ribbon**, **event log**, and a **geometry HUD** (azimuth, elevation, range, Doppler, time to loss of signal,
   rotator state).
6. **Beyond SatDump:** scrubbable instant replay; a post-pass **report card** that explains what happened from evidence
   ("lock dropped at 12 degrees elevation; a higher-gain antenna would add about 2 min"); a shareable pass poster.

**Library.** A thumbnail grid of real products only, with quality badges and filters. The viewer: zoom, channel and
composite switcher, enhancement (equalise, gamma, thermal LUTs), a metadata inspector, "Open recording" for replay, and
export. Product kinds are generic: image, audio clip, packet list (APRS), telemetry table. Map-reprojected imagery is
phase 6.

## 10. Testing

- Orbit: section 5.
- Scheduler: fake clock and fake dongle simulate days in milliseconds; property tests on the conflict solver (no
  overlap, pinned wins, every drop explained).
- Capture: synthetic IQ with a known Doppler profile must be corrected to within a stated residual; SigMF round trip;
  back-pressure behaviour of the fan-out.
- Decode: the driver's synthetic Meteor pass through the whole chain matches the reference image.
- Rating and rotator planner: table-driven tests; planner properties (never crosses a stop, never exceeds slew rate).
- UI: view-model tests, `script/check_sf_symbols.sh`, screenshot QA of the three tabs.
- **Owner QA additions** (to `docs/PROJECT_STATUS.md` section 9): one real pass vs a trusted tracker; a real Meteor
  capture with an outdoor antenna; a measured Doppler residual; rotator hardware when one exists.

## 11. Future: transmit

Not in this spec, and no TX code is written. HackRF One (half-duplex) or another TX-capable SDR is planned, so these four
decisions are made now to avoid a rewrite:

1. **Resource model.** The Scheduler and `DongleRegistry` treat devices as a set with **roles** (receive, transmit),
   not as one dongle. FM-repeater satellites need RX and TX at once, so a second device (RX dongle + HackRF TX) must be
   schedulable together.
2. **Doppler API is two-way.** Downlink `f_rx = f·(1 − ṙ/c)`; uplink pre-correction `f_tx = f/(1 − ṙ/c)`.
3. **`CaptureSession` is the receive leg of a general link session** that can later own a transmit leg on another device.
4. **Device capability model.** `SDRDevice.supportsTX` and `transmit` already exist (the HackRF driver sets
   `supportsTX = true`); the session asks for capabilities and never assumes receive-only.

A **separate transmit design must precede any TX code**: licensed operation only (an operator callsign profile),
region and band-plan interlock, power and duty-cycle limits, a per-session arm confirmation, and a kill switch.

## 12. Upstream coordination

`Packages/SwiftRTLSDR` is an embedded copy of the upstream driver. Driver changes go **upstream first**; this project
syncs only merged work. `script/check_upstream_driver.sh` (added in phase 1) diffs the embedded copy against upstream
`main` and lists open PRs and branches; it is run at every phase boundary. Known in flight at the time of writing:
upstream PR #3 (ACARS, VDL Mode 2) is draft and PR #4 (Swift 6.3 type-check fix) is open.

## 13. Non-goals and risks

**Non-goals:** transmit (section 11), deep-space propagation, cloud sync, a background agent, NOAA APT (no longer
transmitted).

**Risks and how they are handled**
- No live signal has been decoded on this hardware yet. Phase 2 therefore builds replay first, and the first real pass is
  an Owner QA item; the report card and "no signal seen" are designed for this.
- Meteor-M N2-3 is weak and the mast kit is marginal for LRPT; the rating says so up front and recommends a 137 MHz antenna.
- SatNOGS data can be wrong or stale: transmitters are curated by the override list, and status "dead" hides a satellite.
- SGP4 error grows with element age: confidence is part of every pass.
- macOS sleep cannot be overridden: missed passes are reported honestly.
- Share-alike: SatNOGS data is fetched at runtime with attribution and not redistributed in the app bundle.
