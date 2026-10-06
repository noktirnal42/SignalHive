# Satellite Workshop, Phase 1: Orbit, Catalog, Passes: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two-body pass planner with a verified SGP4 orbit engine, a truthful element and transmitter catalog, antenna-aware pass ratings, and a new Satellites "Passes" screen (timeline, sky plot, ground track, Doppler curve, hand-pointing guide).

**Architecture:** UI-free logic in `SignalHiveCore/Satellite/{Orbit,Catalog,Antennas,Rating}` with injected network fetch and clock (same pattern as `OpenMHzClient`), tested against independent oracle data. Thin SwiftUI views in `App/Shared/Views/Satellites/` read a `PassBoard` result. The old planner, recipes and the invented `SatelliteImageProduct.simulated` are deleted, not kept alongside.

**Tech Stack:** Swift 6 language mode, swift-testing, GRDB (antenna persistence), SwiftUI Canvas, MapKit, Charts. Test oracle: python `sgp4` 2.25 (already installed), data only.

**Spec:** `docs/superpowers/specs/2026-10-05-satellite-workshop-design.md` (sections 4 to 6, 9 and 12 are this phase; sections 7, 8, 11 are later phases).

**Reuse review (2026-10-05, owner invited reuse from projects in `/Volumes/Artificial_Intelligence_Machine_Learning/dev`):** NeuralSDR's `OrbitPropagator` is a stub ("Mocked SGP4 output"); NeuralSDR3's `PassPredictor` falls back to simplified Keplerian; SpaceSim has a J2 integrator for spacecraft state vectors, not element-set propagation. **Nothing there is usable for this phase.** For later phases: NeuralSDR3 `DopplerCorrector` and `LinkBudgetCalculator`, NeuralSDR `IQRecorder` (phase 2), NeuralSDR3 `PassScheduler` state names (phase 3). Read them then; none was copied.

## Global Constraints

- Swift 6 language mode; logic lives in `Packages/SignalHiveCore` with Swift Testing tests; views stay thin. SignalHiveCore deployment: macOS 15 / iOS 18.
- **SGP4 is original Swift, written from the published equations** (Spacetrack Report #3 with the Vallado et al. 2006 corrections), AFSPC-compatible mode, WGS-72 constants. Reference output is test data only; **do not open or copy any reference source** (the `sgp4` package's `.py`/`.cpp` files are not to be read while writing `SGP4.swift`).
- Element format is **OMM (JSON/CSV)** primary, TLE legacy. CelesTrak GP may be fetched **at most once every 2 hours** (7200 s), enforced in code.
- SatNOGS DB data is CC BY-SA: fetched at runtime, never bundled; attribution shown on screen.
- **Truthful UI:** nothing simulated is shown; dead satellites are never offered; `SatelliteImageProduct.simulated` and the NOAA 15/18/19 APT recipes are deleted (APT is off the air).
- No scheduling UI in this phase (no "Follow", no tick-to-select): it is phase 3 and must not be promised by the screen.
- One `.searchable` per window. After touching icons run `script/check_sf_symbols.sh`. New files under `App/` are registered with `python3 script/register_app_sources.py`.
- `Packages/SwiftRTLSDR` is read-only here (upstream first).
- **Build scratch goes on the external volume**: the internal disk is at 98%. `SCRATCH=/Volumes/Artificial_Intelligence_Machine_Learning/claude-build-cache/satellite`. Test command: `cd Packages/SignalHiveCore && swift test --scratch-path "$SCRATCH/core" --skip RTLSDRHardwareTests --filter <Suite>`.
- Work on branch `claude/satellite-workshop`. Commit per task. Do not push.

## Review Focus

Inputs the spec implies that no task would otherwise exercise, most likely first. Each has a test in the task named.

1. **A pass already in progress at the start of the window, or still up at its end** (the first thing a user sees when opening the screen mid-pass). Expect `startsBeforeWindow` / `endsAfterWindow` true and times clamped to the window. Task 7.
2. **Garbage or hostile feed data and an offline first launch:** OMM rows with missing fields, NaN, 6-digit catalog numbers, duplicates; SatNOGS transmitters with a null frequency or unknown mode; HTTP 429/500; no cache and no network. Expect valid rows kept, bad rows counted and reported, a readable state, never a crash or an empty screen with no explanation. Tasks 3, 8, 9.
3. **Extreme geometry:** an observer at a pole or on longitude ±180, and a ground track that crosses the antimeridian (a naive polyline draws a line across the whole map). Expect valid passes and a track split into segments. Tasks 7, 11.
4. **A satellite that decays, errors, or has absurd elements mid-window; elements from the future or over 30 days old.** Expect the satellite reported as a named problem, the other satellites unaffected, old elements flagged or refused per the spec. Tasks 4, 7, 8.
5. **Time zones and DST:** a window crossing local midnight or a DST change must lay out correctly (layout in UTC, display in local with a UTC toggle). Task 11.

## File structure

```
Packages/SignalHiveCore/Sources/SignalHiveCore/Satellite/
  Orbit/    Vector3.swift  TimeScales.swift  Geodesy.swift  OrbitalElements.swift  ElementParser.swift
            SGP4.swift  Topocentric.swift  SunPosition.swift  PassPredictor.swift
  Catalog/  ElementStore.swift  ElementAge.swift  SignalKind.swift  TransmitterStore.swift
            TransmitterOverrides.swift  SatelliteDirectory.swift  Resources/transmitter-overrides.json
  Antennas/ AntennaProfile.swift  (persistence: Data/User/UserDatabase.swift migration "v2")
  Rating/   PassRating.swift
  PassBoard.swift  PassViewModels.swift   (TimelineLayout, PolarProjection, GroundTrack, PointingGuide)
  SatellitesState.swift                   (filters, phase, visible passes and the "12 of 30 shown" summary)
Packages/SignalHiveCore/Tests/Core/   one *Tests.swift per source file above; Fixtures/ (oracle + feed samples)
App/Shared/Views/Satellites/          SatellitesView.swift  SatellitesModel.swift  PassTimelineView.swift
                                      PassInspectorView.swift  PolarSkyPlot.swift  GroundTrackMap.swift
                                      DopplerCurveView.swift  ElevationProfileView.swift  AntennaEditorSheet.swift
script/gen_sgp4_oracle.py   script/check_upstream_driver.sh
```

Naming rule while the old code still exists (until Task 12): new types never reuse `SatelliteTLE`, `SatellitePass`, `SatellitePassPlanner`, `SatelliteLook`, `TLEParser`, or the old file's private `Vec3` (the new vector type is `Vector3`). The new pass type is `PredictedPass`.

---

### Task 1: Oracle generator and fixture plumbing

**Files:**
- Create: `script/gen_sgp4_oracle.py`, `Packages/SignalHiveCore/Tests/Core/Fixtures/sgp4-oracle.json`
- Create: `Packages/SignalHiveCore/Tests/Core/FixtureSupport.swift`, `Packages/SignalHiveCore/Tests/Core/OracleFixtureTests.swift`
- Modify: `Packages/SignalHiveCore/Package.swift` (the `SignalHiveCoreTests` target gains `resources: [.copy("Fixtures")]`)

**Interfaces:**
- Produces `enum Fixtures { static func data(_ name: String) throws -> Data; static func json(_ name: String) throws -> Any }` (loads `Fixtures/<name>` from `Bundle.module`).
- Produces the oracle schema every later orbit test reads:
  `{"generator": "python-sgp4 2.25, WGS-72, opsmode a", "cases": [{"name", "noradID", "omm": {CelesTrak OMM keys: OBJECT_NAME, NORAD_CAT_ID, EPOCH, MEAN_MOTION, ECCENTRICITY, INCLINATION, RA_OF_ASC_NODE, ARG_OF_PERICENTER, MEAN_ANOMALY, BSTAR, MEAN_MOTION_DOT, MEAN_MOTION_DDOT}, "tle": [l1, l2], "periodMinutes", "samples": [{"minutes": Double, "r": [x,y,z], "v": [vx,vy,vz]}], "error": null or Int}]}` (km, km/s, TEME; `error` is the sgp4 error code at the first failing sample).

- [ ] **Step 1: Write the failing test** `OracleFixtureTests`: `oracleFileHasTheVerificationSet` asserts `cases.count >= 30`; at least 10 cases have `periodMinutes < 225` and ≥ 6 samples; at least one case has non-null `error`; every sample's `r` has finite components.
- [ ] **Step 2: Run** `swift test ... --filter OracleFixtureTests`. Expected: FAIL (compile error: `Fixtures` undefined / resource missing).
- [ ] **Step 3: Write `script/gen_sgp4_oracle.py`.** Uses python `sgp4` only to *produce data*. Cases: every element set in the package's bundled `SGP4-VER.TLE` (33), plus the ISS 2025-09-30 elements from `SatellitePassPlannerTests`, plus two current sun-synchronous sets (fetch METEOR-M2 4 and one more from `https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=json`). Samples per case: the start/stop/step minutes appended to line 2 of the verification file, thinned to at most 12 evenly spaced samples including first and last; for the others, minutes in `[-1440, -360, 0, 360, 1440, 4320]`. Record the OMM dict, the TLE, the period, and the first error code. Create `Fixtures/` and `FixtureSupport.swift`, add the Package.swift resource line.
- [ ] **Step 4: Run** `python3 script/gen_sgp4_oracle.py > .../Fixtures/sgp4-oracle.json`, then the test. Expected: PASS.
- [ ] **Step 5: Commit** `git add script/gen_sgp4_oracle.py Packages/SignalHiveCore && git commit -m "test: SGP4 oracle fixtures from the official verification set"`

### Task 2: Vectors, time scales, geodesy

**Files:** Create `Orbit/Vector3.swift`, `Orbit/TimeScales.swift`, `Orbit/Geodesy.swift`; Test `Tests/Core/OrbitMathTests.swift`

**Interfaces:**
- Produces `public struct Vector3: Sendable, Equatable { x, y, z: Double; init(_:_:_:); +, -, *(Double); dot(_:); cross(_:); length; }`
- Produces `public enum TimeScales { static func julianDate(_ date: Date) -> Double; static func gmstRadians(_ date: Date) -> Double }` (UTC treated as UT1; GMST by the IAU-82 expression; result in [0, 2π)).
- Produces `public struct Observer: Sendable, Equatable { latitudeDegrees, longitudeDegrees, altitudeMeters: Double; init(latitudeDegrees:longitudeDegrees:altitudeMeters: Double = 0); init(_ c: GeoCoordinate, altitudeMeters: Double = 0); var isValid: Bool }`
- Produces `public enum WGS84 { static let equatorialRadiusKM = 6378.137; static let flattening = 1/298.257223563; static let earthRotationRadPerSec = 7.292115146706979e-5 }` and `public enum Geodesy { static func ecef(of: Observer) -> Vector3 /*km*/; static func geodetic(fromECEF: Vector3) -> (latitudeDegrees: Double, longitudeDegrees: Double, altitudeKM: Double) }`.

- [ ] **Step 1: Write the failing tests** in `OrbitMathTests`: `julianDateOfJ2000` (`2000-01-01T12:00:00Z` -> `2451545.0` exactly); `gmstAtJ2000` (`2000-01-01T12:00:00Z` -> 4.894961212823756 rad ± 1e-9, the standard 280.46061837°); `gmstIsInZeroToTwoPi` over 1000 dates; `ecefOfEquatorObserverAtSeaLevel` (lat 0, lon 0 -> `(6378.137, 0, 0)` ± 1e-9); `ecefOfPole` (lat 90 -> z = 6356.752314245 ± 1e-6); `geodeticRoundTrip` for 200 random observers incl. lat ±89.9999 and lon ±180 (error < 1e-9 deg, 1e-9 km); `observerValidity` (lat 91, NaN, lon 181 invalid).
- [ ] **Step 2: Run** `--filter OrbitMathTests`. Expected: FAIL (types undefined).
- [ ] **Step 3: Implement** the three files per the signatures; `geodetic(fromECEF:)` by iteration (converges to 1e-12 in under 10 passes, including near the poles).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(satellite): vectors, GMST and WGS-84 geodesy`

### Task 3: Orbital elements and parsers (OMM JSON, OMM CSV, TLE)

**Files:** Create `Orbit/OrbitalElements.swift`, `Orbit/ElementParser.swift`, `Tests/Core/Fixtures/celestrak-weather-sample.json` (a trimmed real response, 3 entries including METEOR-M2 4, fetched with curl), `Tests/Core/Fixtures/celestrak-sample.csv`; Test `Tests/Core/OrbitalElementsTests.swift`

**Interfaces:**
- Produces `public struct OrbitalElements: Sendable, Equatable, Identifiable { name, noradID: Int (id), epoch: Date, inclinationDegrees, raanDegrees, eccentricity, argumentOfPerigeeDegrees, meanAnomalyDegrees, meanMotionRevsPerDay, bstar, meanMotionDot, meanMotionDDot: Double; var periodMinutes: Double; var isDeepSpace: Bool /* period >= 225 */ }`
- Produces `public enum ElementParser { struct Rejection: Sendable, Equatable { let position: Int; let reason: String }; struct Result: Sendable { var elements: [OrbitalElements]; var rejected: [Rejection] }; static func parseOMMJSON(_ data: Data) throws -> Result /* throws only when the body is not a JSON array */; static func parseOMMCSV(_ text: String) -> Result; static func parseTLE(_ text: String) -> Result }`

- [ ] **Step 1: Write the failing tests** in `OrbitalElementsTests`: `ommJSONRowsParseWithEpochAndUnits` (the Meteor sample: `noradID == 59051` is checked against the fixture, epoch equals the fixture's `EPOCH` as UTC to the microsecond); `sixDigitCatalogNumbersParse` (a row with `NORAD_CAT_ID` 100001 parses, id 100001); `badRowsAreRejectedNotFatal` (an array of 5 rows where rows 2 and 4 lack `MEAN_MOTION` / have `ECCENTRICITY` NaN returns 3 elements and 2 `Rejection`s naming the position); `duplicateNoradIDsKeepTheNewestEpoch`; `eccentricityOutsideZeroToOneIsRejected`; `emptyAndHtmlBodiesAreRejectedWithAReason` (an HTML error page throws, an empty array returns empty); `csvParsesTheSameRowsAsJSON` (same three satellites, same numbers); `tleFixedColumnsParseIncludingNegativeBstar` (the ISS TLE from `SatellitePassPlannerTests`: inclination 51.6311, eccentricity 0.0004254, bstar 0.00025353 negative exponent form `25353-3`); `tleWithBadChecksumIsRejected`; `periodAndDeepSpaceFlag` (ISS period ≈ 92.9 min not deep space; a 1.0027 rev/day set is deep space).
- [ ] **Step 2: Run** `--filter OrbitalElementsTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** TLE parsing is **fixed-column** with mod-10 checksum verification (the old `TLEParser` split on spaces and is not a model). Epoch from OMM `EPOCH` (ISO-8601 without zone = UTC, fractional seconds kept). Reject non-finite numbers and eccentricity outside [0, 1).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(satellite): orbital elements and OMM/CSV/TLE parsers`

### Task 4: SGP4 propagator (near-Earth)

**Files:** Create `Orbit/SGP4.swift`; Test `Tests/Core/SGP4Tests.swift`

**Interfaces:**
- Consumes: `OrbitalElements` (Task 3), `Vector3` (Task 2), the oracle fixture (Task 1).
- Produces `public struct StateVector: Sendable, Equatable { var position: Vector3 /*km TEME*/; var velocity: Vector3 /*km/s TEME*/ }`
- Produces `public enum SGP4Error: Error, Equatable { case unsupportedDeepSpace(periodMinutes: Double), meanElementsOutOfRange, perturbedElementsOutOfRange, semiLatusRectumNegative, decayed, nonFiniteInput }`
- Produces `public struct SGP4Propagator: Sendable { init(_ elements: OrbitalElements) throws; let epoch: Date; func state(minutesSinceEpoch: Double) throws -> StateVector; func state(at date: Date) throws -> StateVector }`

- [ ] **Step 1: Write the failing tests** in `SGP4Tests` (all against `sgp4-oracle.json`): `nearEarthCasesMatchTheOracle` (every case with `periodMinutes < 225` and `error == nil`: for every sample `|Δr| < 1e-6 km` per component and `|Δv| < 1e-9 km/s`; failures print case name and minutes); `deepSpaceCasesAreRefusedExplicitly` (cases with `periodMinutes >= 225` throw `.unsupportedDeepSpace`); `decayedCaseThrowsAtTheOracleMinute` (the case with an `error` code: samples before the failing minute match, the failing minute throws `.decayed`); `issAltitudeIsPlausible` (ISS position length 6730 to 6830 km at epoch); `nonFiniteElementsThrow`; `propagationIsDeterministicAndReentrant` (the same state from 8 concurrent tasks).
- [ ] **Step 2: Run** `--filter SGP4Tests`. Expected: FAIL (types undefined).
- [ ] **Step 3: Implement `SGP4Propagator`** from the published equations: initialisation (un-Kozai mean motion, secular rates for J2/J4, drag terms from bstar, the low-perigee `isimp` simplification), then propagation (secular update, Kepler solve, short-period periodics, unit vectors, TEME state). WGS-72: `mu = 398600.8`, `radiusEarthKM = 6378.135`, `j2 = 0.001082616`, `j3 = -0.00000253881`, `j4 = -0.00000165597`, `xke = 60/sqrt(RE³/mu)`. AFSPC mode (not the improved mode). **Do not loosen the tolerances**: a case that exceeds them is a port bug.
- [ ] **Step 4: Run.** Expected: PASS (this is the largest task; budget for debugging against the oracle case by case).
- [ ] **Step 5: Commit** `feat(satellite): SGP4 propagator verified against the official verification set`

### Task 5: Topocentric geometry and Doppler

**Files:** Create `Orbit/Topocentric.swift`; extend the oracle script (and regenerate and commit `sgp4-oracle.json`; earlier tests must still pass) to also emit observer-frame samples (`"look": {"observer": [lat, lon, altM], "samples": [{"minutes", "az", "el", "rangeKM", "rangeRateKMS"}]}` computed by python independently of Swift) for the ISS and Meteor cases; Test `Tests/Core/TopocentricTests.swift`

**Interfaces:**
- Consumes: `StateVector`, `Observer`, `TimeScales`, `Geodesy`, `WGS84`.
- Produces `public struct LookAngle: Sendable, Equatable { time: Date; azimuthDegrees, elevationDegrees, rangeKM, rangeRateKMPerSec: Double }` (azimuth 0..<360 from north through east; range-rate positive when receding).
- Produces `public enum Topocentric { static func look(_ state: StateVector, at date: Date, from observer: Observer) -> LookAngle; static func dopplerShiftHz(carrierHz: Double, rangeRateKMPerSec: Double) -> Double /* f·(−ṙ/c), first order */; static func receivedFrequencyHz(carrierHz: Double, rangeRateKMPerSec: Double) -> Double }`

- [ ] **Step 1: Write the failing tests** in `TopocentricTests`: `matchesTheIndependentOracle` (azimuth within 0.01 deg, elevation within 0.01 deg, range within 0.01 km, range-rate within 1e-5 km/s for every oracle look sample); `rangeRateIsTheDerivativeOfRange` (central difference over ±0.5 s of `rangeKM` against `rangeRateKMPerSec`, tolerance 1e-4 km/s, on 20 random ISS times); `zenithPassHasElevation90AndDefinedAzimuth`; `dopplerSignAndMagnitude` (receding at 7 km/s on 137.9 MHz gives ≈ −3.22 kHz; approaching gives +; at ṙ = 0 gives 0); `azimuthIsAlwaysInZeroTo360`; `observerAtThePoleDoesNotProduceNaN`.
- [ ] **Step 2: Run** `--filter TopocentricTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** TEME to Earth-fixed through GMST; relative velocity `v_ecef = R·v_teme − ω × r`; topocentric east/north/up on the WGS-84 ellipsoid; range-rate is the range-direction component of the relative velocity. Documented as ignored: light-time, polar motion, UT1-UTC.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(satellite): look angles, range-rate and Doppler`

### Task 6: Sun position and shadow

**Files:** Create `Orbit/SunPosition.swift`; Test `Tests/Core/SunPositionTests.swift`

**Interfaces:**
- Produces `public enum SunPosition { static func vector(at: Date) -> Vector3 /* km, equatorial of date */; static func elevationDegrees(from: Observer, at: Date) -> Double; static func isSunlit(satellite: Vector3, sun: Vector3) -> Bool /* cylindrical Earth shadow */ }`

- [ ] **Step 1: Write the failing tests:** `meeusExample25a` (1992-10-13 00:00 TD: apparent right ascension 198.38083°, declination −7.78507°, distance 0.99766 AU, tolerance 0.02°, 0.0005 AU, the textbook worked example); `sunIsHighAtNoonOnTheSummerSolsticeAtTheTropic` (lat 23.44, lon 0, 2026-06-21 12:00 UTC -> elevation within 1° of 90); `sunIsBelowTheHorizonAtLocalMidnight`; `satelliteBehindTheEarthIsInShadow` (satellite at (−7000,0,0) km, sun at +x: false; at (+7000,0,0): true; at (0,7000,0): true).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the low-precision solar ephemeris (mean anomaly, equation of centre, ecliptic longitude, obliquity), accuracy about 0.01°.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(satellite): sun position, daylight and eclipse`

### Task 7: Pass predictor

**Files:** Create `Orbit/PassPredictor.swift`; extend the oracle script (regenerate and commit the JSON) with expected passes (`"passes": [{"observer", "from", "through", "minElevation", "list": [{"aos","tca","los","maxEl"}]}]`, ISO times) from python using a 1 s brute-force search with an independent geodesy implementation (and `skyfield` if `pip install` into a throwaway venv succeeds; note which was used in the file's `generator` field); Test `Tests/Core/PassPredictorTests.swift`

**Interfaces:**
- Consumes: `SGP4Propagator`, `Topocentric`, `SunPosition`, `Observer`.
- Produces `public struct PassPoint: Sendable, Equatable { time: Date; azimuthDegrees, elevationDegrees, rangeKM, rangeRateKMPerSec: Double }`
- Produces `public struct PredictedPass: Identifiable, Sendable, Equatable { id: String /* "<norad>-<aos epoch seconds>" */; noradID: Int; satelliteName: String; aos, tca, los: Date; aosAzimuthDegrees, tcaAzimuthDegrees, losAzimuthDegrees, maxElevationDegrees, minRangeKM, sunElevationAtTCADegrees: Double; sunlitAtTCA: Bool; startsBeforeWindow: Bool; endsAfterWindow: Bool; elementEpoch: Date; track: [PassPoint] /* every 5 s, aos...los inclusive */; var duration: TimeInterval }`
- Produces `public struct PassSearchResult: Sendable { var passes: [PredictedPass]; var problem: SGP4Error? }`
- Produces `public struct PassPredictor: Sendable { var minimumElevationDegrees: Double; init(minimumElevationDegrees: Double = 5); func passes(for: OrbitalElements, observer: Observer, from: Date, through: Date) -> PassSearchResult }`

- [ ] **Step 1: Write the failing tests** in `PassPredictorTests`: `matchesTheIndependentPredictor` (for each oracle pass list: same number of passes; AOS/LOS within 2 s, TCA within 5 s, max elevation within 0.1°); `edgesSitAtTheThreshold` (elevation at `aos` and `los` equals `minimumElevationDegrees` within 0.02°); `passOrderingProperties` (aos < tca < los, `track` times strictly increasing every 5 s, elevations at the track ends ≥ threshold − 0.05); **`passInProgressAtWindowStartIsTruncated`** (a window opened at an oracle pass's TCA returns it with `startsBeforeWindow == true` and `aos == from`); **`passStillUpAtWindowEndIsTruncated`**; **`polarObserverStillWorks`** (lat 89.99 and lat −89.99, a 3-day window: no NaN, passes sorted); **`antimeridianObserverWorks`** (lon 180 and −180 give identical pass times); `satelliteThatNeverRisesReturnsNoPassesAndNoProblem`; **`satelliteThatDecaysMidWindowKeepsEarlierPassesAndReportsTheProblem`** (use the oracle's decay case; `problem == .decayed`, passes before the failure present); `deepSpaceElementsReportUnsupportedDeepSpace`; `emptyOrReversedWindowReturnsNothing`; `performance` (100 near-earth element sets x 7 days completes in under 5 s on this machine; the assertion is a generous bound, the printed time is the evidence).
- [ ] **Step 2: Run** `--filter PassPredictorTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Coarse scan every 30 s on elevation, then bisection to 0.5 s for both edges, golden-section for the peak, 5 s track, sun elevation and shadow at TCA. Initialise the propagator once per satellite. Truncate at window edges and set the flags.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(satellite): pass predictor verified against an independent predictor`

### Task 8: Element store, age and confidence

**Files:** Create `Catalog/ElementStore.swift`, `Catalog/ElementAge.swift`; Test `Tests/Core/ElementStoreTests.swift`

**Interfaces:**
- Consumes: `ElementParser`, `OrbitalElements`.
- Produces `public enum ElementConfidence: Sendable, Equatable { case good, aging(days: Double), stale(days: Double), unusable(days: Double), fromTheFuture }` and `public enum ElementAge { static func confidence(epoch: Date, now: Date) -> ElementConfidence }` (good under 3 days, aging 3 to 7, stale 7 to 30, unusable at 30 or more, future if epoch is more than 1 hour ahead of `now`).
- Produces `public struct ElementLoad: Sendable { var elements: [OrbitalElements]; var fetchedAt: Date?; var source: Source; var rejectedRows: Int; enum Source: Sendable, Equatable { case network, cacheTooSoonToRefetch, cacheAfterFailure(String), none(String) } }`
- Produces `public actor ElementStore { typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse); init(directory: URL, fetch: Fetch = <URLSession>, now: @escaping @Sendable () -> Date = { Date() }, minimumRefetchInterval: TimeInterval = 7200); func elements(group: String, forceRefresh: Bool = false) async -> ElementLoad; func importElements(_ text: String, named: String) throws -> Int; static func url(forGroup: String) -> URL /* https://celestrak.org/NORAD/elements/gp.php?GROUP=<group>&FORMAT=json */ }`

- [ ] **Step 1: Write the failing tests** in `ElementStoreTests` (fake `fetch` and clock): `firstLoadFetchesAndCaches`; `secondLoadWithin2HoursNeverTouchesTheNetwork` (fetch count stays 1, source `.cacheTooSoonToRefetch`, even with `forceRefresh: true` inside the window); `loadAfter2HoursRefetches`; **`offlineFirstLaunchReturnsNoneWithAReadableReason`** (fetch throws, no cache: elements empty, `source == .none(...)` with a non-empty message); **`httpFailureFallsBackToCache`** for 429 and 500 (source `.cacheAfterFailure`, elements from cache); **`malformedBodyKeepsTheOldCacheAndCountsRejects`**; `cacheSurvivesAProcessRestart` (a second store on the same directory sees it); `importAddsElementsFromTLEAndOMMText`; `urlUsesJSONFormatAndTheGroup`; `ageBoundaries` (2.9 d good, 3.0 aging, 7.0 stale, 30.0 unusable, +2 h future).
- [ ] **Step 2: Run** `--filter ElementStoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Cache file per group in `directory` (the parsed result as JSON plus `fetchedAt`); a fetch outside `minimumRefetchInterval` replaces the cache only if the parse produced at least one element.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(satellite): CelesTrak element store with 2-hour policy and offline cache`

### Task 9: Transmitters, signal kinds and the directory

**Files:** Create `Catalog/SignalKind.swift`, `Catalog/TransmitterStore.swift`, `Catalog/TransmitterOverrides.swift`, `Catalog/SatelliteDirectory.swift`, `Catalog/Resources/transmitter-overrides.json`, `Tests/Core/Fixtures/satnogs-transmitters-sample.json`, `Tests/Core/Fixtures/satnogs-satellites-sample.json`; modify `Package.swift` (`.process("Satellite/Catalog/Resources")` on the core target); Test `Tests/Core/TransmitterStoreTests.swift`, `Tests/Core/SatelliteDirectoryTests.swift`

**Interfaces:**
- Produces `public enum SignalKind: String, Sendable, Codable { case lrpt, fmVoice, sstv, aprs, cwBeacon, bpskTelemetry, other, unknown; init(satnogsMode: String?, baud: Double?); var decoderStatus: DecoderStatus }` and `public enum DecoderStatus: Sendable, Equatable { case ready, planned, none }`. **In this phase `ready` is never returned** (decoders are phase 2+): LRPT, FM voice, APRS, SSTV and CW map to `.planned`, the rest to `.none`.
- Produces `public enum SignalStrengthClass: String, Sendable, Codable { case strong, medium, weak, unknown }`
- Produces `public struct TransmitterInfo: Identifiable, Sendable, Equatable, Codable { id: String; noradID: Int; summary: String; downlinkHz: Double; mode: String?; kind: SignalKind; isActive: Bool; service: String?; verifiedOnAir: Date? }`
- Produces `public enum SatelliteStatus: String, Sendable, Codable { case alive, dead, future, reentered, unknown }`
- Produces `public struct TransmitterOverrides: Sendable { static func bundled() throws -> TransmitterOverrides; func strength(for noradID: Int) -> SignalStrengthClass; func note(for noradID: Int) -> String?; func transmitters(for noradID: Int) -> [TransmitterInfo] /* verified-on-air entries; empty in this phase */ }`
- Produces `public actor TransmitterStore { init(directory: URL, fetch: ElementStore.Fetch = <URLSession>, now: @escaping @Sendable () -> Date = { Date() }, minimumRefetchInterval: TimeInterval = 86_400); func load(forceRefresh: Bool = false) async -> TransmitterLoad }` where `TransmitterLoad { transmitters: [TransmitterInfo]; satellites: [Int: SatelliteStatus]; fetchedAt: Date?; source: ElementLoad.Source; rejected: Int }`; URLs `https://db.satnogs.org/api/transmitters/?format=json` and `https://db.satnogs.org/api/satellites/?format=json`.
- Produces `public enum SatelliteCategory: String, CaseIterable, Sendable { case weather, stations, amateur; var celestrakGroup: String /* "weather", "stations", "amateur" */; var title: String }`
- Produces `public struct SatelliteRecord: Identifiable, Sendable { elements: OrbitalElements; category: SatelliteCategory; status: SatelliteStatus; transmitters: [TransmitterInfo]; strength: SignalStrengthClass; note: String?; var primaryTransmitter: TransmitterInfo? /* the active one inside 24...1766 MHz with the best decoder status */ }` and `public enum SatelliteDirectory { static func build(groups: [SatelliteCategory: [OrbitalElements]], satellites: [Int: SatelliteStatus], transmitters: [TransmitterInfo], overrides: TransmitterOverrides) -> [SatelliteRecord] }` (a satellite present in several groups appears once, in the first of weather, stations, amateur; dead, reentered and future satellites are **excluded**).

- [ ] **Step 1: Write the failing tests:** in `TransmitterStoreTests`: `parsesSavedLiveResponses` (fixtures are trimmed real responses fetched once with curl, about 20 entries, each field optional on decode); **`nullFrequencyAndUnknownModeAreTolerated`** (a transmitter with `downlink_low: null` is skipped and counted in `rejected`, an unknown `mode` becomes `.unknown`, neither throws); `inactiveTransmittersAreMarkedInactive`; `respectsTheOneDayRefetchInterval`; **`offlineFirstLaunchHasAReadableReason`**; `modeMapping` (table: "LRPT" -> `.lrpt`; "FM"/"FMN" -> `.fmVoice`; "SSTV" -> `.sstv`; "AFSK" with baud 1200 -> `.aprs`; "CW" -> `.cwBeacon`; "BPSK" -> `.bpskTelemetry`; nil -> `.unknown`); `noModeIsReadyYet` (every `SignalKind.decoderStatus != .ready`). In `SatelliteDirectoryTests`: `deadAndReenteredSatellitesAreExcluded`; `satelliteWithoutAnActiveTransmitterInRangeHasNoPrimary`; `transmitterOutside24To1766MHzIsNotPrimary`; `overridesSetStrengthAndNote` (the bundled file marks Meteor-M2 3 weak with an "antenna not fully deployed" note and Meteor-M2 4 medium; **confirm the NORAD ids 57166 and 59051 against the live CelesTrak weather group before committing the file**); `sixDigitIdsFlowThrough`; `categoryComesFromTheGroupAndWeatherWinsOnDuplicates`.
- [ ] **Step 2: Run** `--filter "TransmitterStoreTests|SatelliteDirectoryTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** Verify every SatNOGS field name against the saved fixture (the schema can drift); decode tolerantly. Attribution constant `TransmitterStore.attribution = "Transmitter data: SatNOGS DB (CC BY-SA 4.0), db.satnogs.org"` for the UI.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(satellite): SatNOGS transmitters, signal kinds, directory and verified overrides`

### Task 10: Antenna profiles, persistence and pass rating

**Files:** Create `Antennas/AntennaProfile.swift`, `Rating/PassRating.swift`; modify `Data/User/UserDatabase.swift` (migration `"v2"`: table `antennas(id TEXT PRIMARY KEY, json TEXT NOT NULL, updatedAt DATETIME NOT NULL)`; `saveAntenna`, `antennas()`, `deleteAntenna(id:)` mirroring the codeplug methods); Test `Tests/Core/AntennaProfileTests.swift`, `Tests/Core/PassRatingTests.swift`, `Tests/Core/UserDatabaseTests.swift` (add cases)

**Interfaces:**
- Produces `public struct AntennaProfile: Identifiable, Codable, Sendable, Equatable { id: UUID; name: String; lowHz, highHz: Double; gain: Gain; isDirectional: Bool; notes: String; enum Gain: String, Codable, Sendable { case omni, low, medium, high }; func covers(_ hz: Double) -> Bool; static let presets: [AntennaProfile] }` with presets taken from NooElec's own descriptions as recorded in `docs/PROJECT_STATUS.md` (telescopic mast 100 to 800 MHz omni; DVB-T/T2 mast 700 to 1200 MHz omni; helical 1100 to 1800 MHz low-gain directional), each noted "per the maker's description, not measured".
- Produces `public struct ReceiverCapability: Sendable { var tuningRangeHz: ClosedRange<Double>; static let rtlSDR }` (24e6...1_766e6).
- Produces `public enum PassGrade: Int, Comparable, Sendable { case notReceivable, poor, marginal, good, excellent }` and `public struct PassRating: Sendable, Equatable { grade: PassGrade; score: Int; reasons: [String]; remedy: String? }`
- Produces `public enum PassRater { static func rate(pass: PredictedPass, transmitter: TransmitterInfo?, strength: SignalStrengthClass, antennas: [AntennaProfile], receiver: ReceiverCapability, confidence: ElementConfidence, trackingAvailable: Bool = false) -> PassRating }`

**Rating rules (initial heuristics, labelled as such on screen; to be replaced by ledger evidence later).** Evaluated in order; the first three produce `.notReceivable` and stop: (1) no transmitter -> "No known active downlink"; (2) downlink outside `receiver.tuningRangeHz` -> names the range; (3) no antenna covers the downlink -> "None of your antennas covers N MHz", remedy "Add or buy an antenna covering N MHz". Otherwise `score = min(maxEl,60)/60*40 + min(duration,600)/600*10 + strength(strong 30, medium 20, weak 8, unknown 12) + antenna(best covering antenna: omni 6, low 10, medium 16, high 20; a directional antenna earns its gain only when `trackingAvailable`, otherwise it counts as omni and a reason says it needs hand pointing or a rotator)`; `aging` subtracts 5, `stale` subtracts 15 and caps the grade at marginal, `unusable`/`fromTheFuture` return `.notReceivable`. Grade: 70+ excellent, 55+ good, 40+ marginal, else poor. **Minimum useful peak elevation** (below it the grade is capped at poor with the reason stating the number): strong omni 10 / low 5 / medium 0 / high 0; medium 35 / 25 / 10 / 0; weak 55 / 45 / 30 / 10; unknown 40 / 30 / 15 / 5.

- [ ] **Step 1: Write the failing tests:** `PassRatingTests`: `noTransmitterIsNotReceivableWithAReason`; `outOfDongleRangeNamesTheRange` (a 1.7 GHz downlink with `.rtlSDR` is in range but with only the mast kit antenna gives "None of your antennas covers 1701.3 MHz"); `weakSatelliteWithMastKitNeedsAHighPass` (weak, omni: 50° peak -> poor with the "55°" reason, 60° peak -> not capped); `strongSatelliteLowPassIsStillFine` (ISS-class strong, 12° peak, omni -> not capped); `directionalAntennaWithoutTrackingGetsNoGainAndSaysSo`; `directionalAntennaWithTrackingScoresHigher`; `elementConfidenceAdjustments` (aging -5, stale caps at marginal, unusable and future are not receivable); `gradeThresholdsAreBoundaryExact` (scores 39/40, 54/55, 69/70). `AntennaProfileTests`: `coversIsInclusiveAtBothEdges`; `codableRoundTrip`; `presetsHaveTheMakersBands`. `UserDatabaseTests`: `antennasPersistAndReload`, `migrationV2KeepsExistingCodeplugs` (open a v1 database file with a codeplug, reopen, codeplug intact, antennas table present).
- [ ] **Step 2: Run** `--filter "PassRatingTests|AntennaProfileTests|UserDatabaseTests"`. Expected: FAIL.
- [ ] **Step 3: Implement** the types, the rater (a pure function) and the migration.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(satellite): antenna profiles and transparent pass ratings`

### Task 11: PassBoard and the view-model helpers

**Files:** Create `PassBoard.swift`, `PassViewModels.swift`; Test `Tests/Core/PassBoardTests.swift`, `Tests/Core/PassViewModelTests.swift`

**Interfaces:**
- Consumes: `PassPredictor`, `SatelliteDirectory`, `PassRater`, `ElementAge`.
- Produces `public struct RatedPass: Identifiable, Sendable { pass: PredictedPass; record: SatelliteRecord; transmitter: TransmitterInfo?; rating: PassRating; confidence: ElementConfidence; var id: String }` and `public struct SatelliteProblem: Sendable, Equatable { noradID: Int; name: String; message: String }`
- Produces `public enum PassBoard { static func compute(records: [SatelliteRecord], observer: Observer, antennas: [AntennaProfile], from: Date, horizon: TimeInterval, minimumElevationDegrees: Double, now: Date) -> (passes: [RatedPass], problems: [SatelliteProblem]) }` (sorted by `aos`; satellites with unusable elements or predictor problems become `SatelliteProblem`s and never break the others).
- Produces `public struct TimelineLayout: Sendable { init(passes: [RatedPass], from: Date, through: Date); var lanes: [Lane]; func x(for: Date, width: Double) -> Double; var daylight: [ClosedRange<Date>] /* from sun elevation at the observer, step 5 min */ }` (lane = one satellite, passes as bars; the layout works in UTC seconds, display zones are the view's job).
- Produces `public enum PolarProjection { static func point(azimuthDegrees: Double, elevationDegrees: Double, radius: Double) -> (x: Double, y: Double) /* zenith centre, north up, east right */ }`
- Produces `public enum GroundTrack { static func segments(_ points: [GeoCoordinate]) -> [[GeoCoordinate]] /* split where longitude jumps more than 180° */ }`
- Produces `public struct PointingGuide: Sendable { init(pass: PredictedPass); func state(at: Date) -> State }` with `State { phase: Phase /* .beforeAOS(seconds), .inPass(secondsToLOS), .after }; azimuthDegrees, elevationDegrees: Double?; compass: String /* "NNE" */; dopplerHz(carrierHz:) -> Double? }`

- [ ] **Step 1: Write the failing tests:** `PassBoardTests`: `ratesAndSortsPasses`; **`oneBadSatelliteDoesNotBreakTheRest`** (a decayed element set yields a `SatelliteProblem` and the other satellites' passes are present); `unusableElementsBecomeAProblemNotAPass`; `emptyRecordsGiveEmptyResult`. `PassViewModelTests`: `polarProjectionKeyPoints` (zenith -> (0,0); az 0 el 0 -> (0, +radius) north up; az 90 el 0 -> (+radius, 0)); **`groundTrackSplitsAtTheAntimeridian`** (points at lon 179, -179 split into two segments; a pure westward run does not); `groundTrackWithNoJumpIsOneSegment`; **`timelineLayoutAcrossLocalMidnightAndDSTIsMonotonicInUTC`** (a 48 h window spanning the 2026-11-01 US DST change in `America/Phoenix` and `America/Los_Angeles`: x positions strictly increasing, 48 h wide); `timelineLanesGroupBySatellite`; `daylightRangesFollowTheSun`; `pointingGuideBeforeDuringAfter` (seconds to AOS, az/el interpolated from the track, `after` when past LOS); `compassPoints` (0 N, 45 NE, 350 N, 100 E).
- [ ] **Step 2: Run** `--filter "PassBoardTests|PassViewModelTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(satellite): pass board and view-model helpers`

### Task 12: The Passes screen; delete the old planner

**Files:** Create `Satellite/SatellitesState.swift` and `Tests/Core/SatellitesStateTests.swift`; create everything under `App/Shared/Views/Satellites/`; modify `App/Shared/ContentView.swift` (route `.satellites` -> `SatellitesView()`); **Delete** `App/Shared/Views/SatelliteView.swift`, `Satellite/SatellitePassPlanner.swift`, `Satellite/SatelliteAutomation.swift`, `Tests/Core/SatellitePassPlannerTests.swift`; modify any text claiming APT is receivable (`grep -rn "APT" App Packages/SignalHiveCore/Sources`).

**Interfaces:**
- Consumes: `PassBoard`, `RatedPass`, `TimelineLayout`, `PolarProjection`, `GroundTrack`, `PointingGuide`, `ElementStore`, `TransmitterStore`, `UserDatabase` antenna methods, `AviationModel.receiverLocation` (the existing receiver location, as the old view used).
- Produces `public struct PassFilters: Sendable, Equatable { categories: Set<SatelliteCategory>; minimumGrade: PassGrade; minimumElevationDegrees: Double; horizonHours: Int /* 24, 48 or 72 */; static let standard }` (standard: all categories, `.marginal`, 10°, 48).
- Produces `public struct SatellitesState: Sendable { enum Phase: Sendable, Equatable { case needsLocation, loading, ready, offline(String) }; var phase: Phase; var observer: Observer?; var all: [RatedPass]; var filters: PassFilters; func visible() -> [RatedPass]; var summary: String /* "12 of 30 passes shown" */ }`
- `@Observable @MainActor final class SatellitesModel` (app target, no logic of its own beyond I/O): owns a `SatellitesState`, `antennas`, `problems`, the two store loads; `refresh()` runs `PassBoard.compute` off the main actor and updates the state.

**Screen contents (spec section 9, Passes only):** header with source freshness ("Elements fetched 14:02, 3 satellites aging") and the SatNOGS attribution; the 48 h lane timeline (bars coloured by `PassGrade` and sized by peak elevation, day/night shading, "now" line, UTC/local toggle, the loser-ghosting is phase 3); tapping a pass opens the **inspector**: `PolarSkyPlot` (Canvas, horizon rings 0/30/60, track, AOS/TCA/LOS labels, live hand-pointing needle from `PointingGuide` with a "point here now" readout), `GroundTrackMap` (MapKit polyline segments from `GroundTrack`, footprint circle at TCA), `ElevationProfileView` and `DopplerCurveView` (Charts; carrier is the primary transmitter's downlink; the title says "predicted"), rating grade with `reasons` and `remedy`, element age and confidence, transmitter facts with decoder status ("decoder: planned"). `AntennaEditorSheet` lists the presets plus custom entries. The header has Set location, Update elements and an "Import elements…" file picker calling `ElementStore.importElements`. Empty states say what to do (set location / update elements / add an antenna). The ratings panel is labelled "heuristic".

- [ ] **Step 1: Write the failing tests** `SatellitesStateTests`: `noObserverIsNeedsLocation`; `offlineWithCachedPassesStillListsThem` (phase `.offline(msg)` and `visible()` non-empty); `filtersHideLowGradesAndSayHowMany` (30 passes, 12 pass the filters: `summary == "12 of 30 passes shown"`); `categoryFilterRemovesOtherCategories`; `minimumElevationFilterUsesPeakElevation`; `standardFiltersAreWhatTheScreenOpensWith`.
- [ ] **Step 2: Run** `--filter SatellitesStateTests`. Expected: FAIL.
- [ ] **Step 3: Implement `PassFilters`/`SatellitesState` (core), then the model and views** per the contents above, keeping drawing code free of logic (everything computed in Task 11 types). Delete the old files and fix compile errors; replace stale APT claims with truthful text.
- [ ] **Step 4: Verify the build and the checks.** `python3 script/register_app_sources.py` then `python3 script/register_app_sources.py --check` (expected exit 0); `script/check_sf_symbols.sh` (expected: 0 invalid); `script/build_and_run.sh --verify` (expected: builds and launches); full core suite `swift test --scratch-path "$SCRATCH/core" --skip RTLSDRHardwareTests` (expected: all pass; the test count falls by the deleted suite and rises by the new ones).
- [ ] **Step 5: Drive the app** (computer-use access will be requested at execution time): set a manual location, update elements and transmitters over the real network, open Satellites, open a Meteor pass and an ISS pass in the inspector. Capture screenshots to `docs/screenshots/2026-10-05/satellites-*.png` (timeline, inspector). Expected: real passes appear with ratings and reasons, Meteor-M2 3 rated lower than M2-4 for equal geometry, no NOAA satellite offered, the attribution visible, no crash.
- [ ] **Step 6: Commit** `feat(satellite): Passes screen; remove the two-body planner, stale APT recipes and simulated products`

### Task 13: Upstream-watch script

**Files:** Create `script/check_upstream_driver.sh`

**Interfaces:** `script/check_upstream_driver.sh` prints (1) the upstream `main` commit and whether `Packages/SwiftRTLSDR` equals it (shallow clone to a temp dir, `diff -rq` excluding `.git`/`.build`; lists differing files), (2) open PRs (`gh pr list -R noktirnal42/SwiftRTLSDR`) with draft flags, (3) branches other than `main`. Always exits 0; the last line is either `UP TO DATE` or `UPSTREAM HAS NEW WORK`.

- [ ] **Step 1: Write the script** (bash, `set -u`, requires `gh` and `git`; a clear message and exit 0 when `gh` is missing).
- [ ] **Step 2: Run** `script/check_upstream_driver.sh`. Expected: the three sections and a final verdict. At the time of writing PR #3 (ACARS/VDL2, draft) and PR #4 (a Swift 6.3 fix) are open upstream, and the embedded copy carries one local `Meshtastic.swift` patch (`docs/PROJECT_STATUS.md` section 6), so a difference is expected; paste the real output into the commit message.
- [ ] **Step 3: Commit** `chore: script to check the upstream driver for new work`

### Task 14: Documentation, status and QA

**Files:** Modify `docs/PROJECT_STATUS.md`

- [ ] **Step 1: Update `docs/PROJECT_STATUS.md`:** the "Who did what" table (this phase), the "Verified status" table (replace the Satellite planning row: SGP4 verified against the official set and an independent predictor, with counts; ratings are heuristic; no scheduling or capture yet), "Known issues" (NOAA APT off air; the old recipes removed; element-format change), roadmap item 8, and `CLAUDE.md`'s Build and test test count.
- [ ] **Step 2: Add Owner QA items to section 9:** compare one real pass (AOS, TCA, LOS, max elevation) against a trusted tracker for the owner's location; hand-point at an ISS pass using the guide; confirm the declared antennas and bands.
- [ ] **Step 3: Run everything once more:** SignalHiveCore suite, `Packages/SwiftRTLSDR` suite (`swift test --scratch-path "$SCRATCH/driver"`), `script/build_and_run.sh --verify`, `script/check_sf_symbols.sh`. Expected: all green; record the counts in the status doc.
- [ ] **Step 4: Commit** `docs: satellite phase 1 status, known issues and owner QA`
