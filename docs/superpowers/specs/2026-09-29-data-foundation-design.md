# SignalHive Data Foundation — Design

Date: 2026-09-29
Status: Draft for review (design approved in conversation; written spec awaiting review)
Track: A of two parallel tracks (Track B = design system and app shell, specified separately)

## 1. Purpose

Make State → County → Agency/License → Frequency browsing work on first launch, using
real FCC data, with no manual import step. Data comes directly from FCC ULS. Nothing is
sourced from RadioReference (no API, no scraping, no RadioReference-derived data). Where
RadioReference offers a feature we want parity with, we build our own implementation.

## 2. Evidence base (verified 2026-09-29, not assumed)

| Finding | How verified |
|---|---|
| The app's SQLite has 56 states and 0 rows in every data table, including `import_state`. The in-app import never wrote a batch. | Read-only `sqlite3` on the sandbox container DB |
| The core import/browse pipeline is sound. `ULSImportIntegrationTests/importLMCommAndBrowseCounties` passed in 197 s: Alabama has more than 20 counties, licenses resolve, detail resolves. | Ran the test against the real LMcomm archive |
| 5 of 7 archive URLs are wrong. `GMRS`, `Aircraft`, `Amateur`, `Marine`, `Ship` return HTTP 302. Correct names are `l_gmrs`, `l_aircr`, `l_amat`, `l_coast`, `l_ship` (lowercase), each HTTP 200. | `curl -I` against data.fcc.gov |
| `LO.dat` latitude fields are columns 19–22 and longitude 23–26. `ULSParser.parseLocation` reads 20–23 and 24–27, so all coordinates are wrong. Example: KNNF642 (Enterprise, Coffee Co., AL) is at 31°19′7.0″N 85°49′58.0″W but parses as about 19.12, 49.97. | Real `LO.dat` rows, column-numbered |
| `HD`, `EN` and `FR` column offsets used by the parser are correct. | Same real archive |
| The importer never deletes its extraction directory (observed leftovers: 794 MB for LMcomm, 212 MB for GMRS), holds an entire table in memory, downloads via per-byte `AsyncBytes`, and `frequencies`/`emissions` have no unique key (re-import duplicates rows). | Code read plus `du` on the temp dir |
| GMRS has no location table; the fallback writes `county = city` and lat/lon 0. | Code read (`ULSImporter.swift`) |
| The in-app failure itself has not been reproduced in the running app. Reproducing it is the first task of the plan. | Stated limitation |

## 3. Goals and non-goals

Goals
1. A fresh install can browse a chosen state's counties, licenses and frequencies with no Settings-window import.
2. FCC data is built by our own tooling into compact per-state packs that the app downloads on demand.
3. All ~3,200 US counties appear (with counts, including zero), matching Census names.
4. Every failure path shows the user a reason and a retry. No silent `try?`.
5. The known parser and URL bugs are fixed test-first.
6. Track B can design against realistic data before Track A finishes (the seam in section 6).

Non-goals (this track)
- Visual redesign, typography, navigation shell (Track B).
- Trunked systems, talkgroups, control-channel discovery, OpenMHz (later track; OpenMHz stays opt-in when built).
- New decoders, SDR features, radio-programming changes.
- FCC data the ULS does not contain: federal (NTIA) users, CTCSS/DCS tones, alpha tags, talkgroups.
- FCC `CO.dat` license comments (deferred; may carry tone hints later).
- FCC services beyond the seven below (paging, broadcast auxiliary, microwave, cellular, market).

## 4. Architecture

### 4.1 Pack builder (in `SignalHiveCore`, thin CLI target on top)

Lives in the Core library so the same code serves the hosted build and the on-device
fallback. A new executable target `signalhive-packbuilder` wraps it.

- Services in scope (corrected names): `l_LMpriv`, `l_LMcomm`, `l_gmrs`, `l_amat`, `l_aircr`, `l_coast`, `l_ship`.
- Streams each `.dat` file line by line from the archive. No whole-table arrays. Extracts only needed entries (`EN`, `HD`, `FR`, `LO`, `EM`) rather than unzipping everything, and always removes its working directory (success or failure).
- Keeps active licenses only (`license_status = 'A'`).
- Writes one read-only SQLite file per state. Schema version 1:
  - `meta(key, value)` — `schemaVersion`, `stateCode`, `fccSnapshotDate`, `builtAt`.
  - `counties(fips PRIMARY KEY, name, stateCode)` — Census list for that state.
  - `licenses(uid PRIMARY KEY, callSign, licenseeName, entityType, serviceCode, grantDate, expiredDate, city, zip, primaryCountyFips)`.
  - `sites(uid, locationNumber, city, countyFips, stateCode, lat, lon, PRIMARY KEY(uid, locationNumber))`.
  - `frequencies(uid, locationNumber, frequencyHz, upperBandHz, classStationCode, powerW, modeHint, bandwidthHz, UNIQUE(uid, locationNumber, frequencyHz, classStationCode))`.
  - `licenses_fts` — FTS5 over `callSign`, `licenseeName`.
  - Indexes on `sites(countyFips)`, `sites(lat, lon)`, `frequencies(frequencyHz)`.
- Mode inference (v1.1 of this track): parse each emission designator from `EM.dat` (necessary bandwidth plus modulation/information characters) into `bandwidthHz` and `modeHint` in {`analogFM`, `am`, `digitalP25`, `digitalOther`, `unknown`}. The exact rule table is part of the implementation plan and is unit-tested against designators taken from real rows.
- Agency grouping (v1.1): derive `agencies(id, name, category)` and `licenses.agencyId` from normalized licensee names and service codes (categories such as Law, Fire, EMS, Public Works, Schools, Utilities, Business). Heuristic; misclassification is expected and must be correctable by the user (Track later).
- Output per state: `SH-<STATE>-<yyyymmdd>.sqlite.lzfse` (LZFSE via Apple's `Compression` framework, available on macOS and iOS) plus `manifest.json`: for each pack the state, filename, compressed and expanded byte sizes, SHA-256, FCC snapshot date; and the top-level `schemaVersion`.

### 4.2 County normalization

- Canonical counties come from the Census Bureau county gazetteer (public domain).
- FCC county strings are matched to canonical names after normalization: case, punctuation, `ST.`/`SAINT`, `CITY`/independent cities (VA, MD, MO, NV), Louisiana parishes, Alaska boroughs and census areas, Puerto Rico municipios.
- Unmatched FCC county strings fall back to a point-in-county lookup from the site's lat/lon (the FCC Area API is used at build time only, with a cached result file, never at app runtime). Records still unmatched are kept with `countyFips = NULL` and surfaced in the builder report.
- GMRS: county derived from the licensee ZIP via the Census ZIP-to-county relationship file, replacing the `county = city` placeholder.
- Builder report lists match rates and the top unmatched strings so normalization gaps are visible, not silent.

### 4.3 App side

- `PackStore` (actor): reads the manifest from a configurable HTTPS base URL; downloads packs with `URLSession` download tasks (resumable); verifies SHA-256; decompresses; installs atomically into Application Support; checks the manifest weekly and on demand for a newer FCC snapshot.
- `FrequencyStore` (one per installed state): read-only GRDB `DatabasePool`. Nationwide search fans out across installed packs in parallel.
- `UserData.sqlite`: new, separate from FCC data; holds codeplugs and later favorites/user tags. One-time migration copies `codeplugs` from the legacy `SignalHive.sqlite` if present and leaves the legacy file untouched.
- The current `ULSImporter` is reworked to call the pack builder, and is exposed as "Advanced: build from FCC on this Mac" for users who do not want to rely on hosted packs. It uses the streaming path and cleans up after itself.
- Shared code contains no macOS-only API (`NSApp` call in `BrowseView` is removed; opening Settings goes through a platform hook).

### 4.4 Browse states (first-run, no dead ends)

State per selected US state: `notInstalled(sizeBytes)` → `downloading(progress)` → `verifying` → `ready` | `failed(reason, canRetry)`. Browse shows the choose-a-state prompt with size and a download button when `notInstalled`, live progress when downloading, and the failure reason with retry when failed. Every `try?` on the browse path is replaced by surfaced errors.

## 5. Data flow

```
data.fcc.gov weekly archives ──► pack builder (streaming, active-only, county-normalized)
        │                                      │
        │                                      ▼
        │                        SH-<STATE>-<date>.sqlite.lzfse + manifest.json
        │                                      │  (any static HTTPS host)
        ▼                                      ▼
 on-device fallback  ──────────►  PackStore ──► FrequencyStore (read-only, per state)
 (same builder code)                                   │
                                                       ▼
                                             BrowseDataSource ──► UI
```

## 6. The seam for the parallel tracks

Track A publishes this UI-agnostic interface and a `MockBrowseDataSource` with canned,
realistic data (real Alabama-style counties, licensee names, frequencies) so Track B can
build and preview against it immediately.

```swift
protocol BrowseDataSource: Sendable {
    func states() async -> [StateAvailability]                       // installed / downloadable / size / progress
    func counties(in state: StateCode) async throws -> [CountySummary]
    func licenses(in county: CountyID, filter: LicenseFilter) async throws -> [LicenseSummary]
    func detail(uid: Int64) async throws -> LicenseDetail
    func search(_ query: String, scope: SearchScope) async throws -> [SearchHit]
    func frequencies(near: Coordinate, radiusKm: Double) async throws -> [NearbyFrequency]
}
```

Ownership to avoid merge conflicts:
- Track A (`data-foundation` branch): `Packages/SignalHiveCore/Sources/SignalHiveCore/Data/**`, the pack-builder target, fixtures, data tests.
- Track B (`design-system` branch): a new `App/Shared/Design/**` (tokens, type, components) and all views under `App/Shared/Views/**`.
- Shared touch points, `BrowseView` and `AppModel`: Track A only changes them to consume `BrowseDataSource` in the smallest way that proves end-to-end; Track B owns their appearance and merges on top.
- Work happens in separate git worktrees off `main` (baseline commit `2f6ecad`).

## 7. Error handling

- Download: network failure, non-200, size or checksum mismatch → `failed` with a specific reason; partial files are discarded; retry resumes when possible.
- Pack open: schema version newer than the app supports → clear "update the app" message; corrupt file → delete and offer re-download.
- Builder: fails the build (non-zero exit) if any service archive returns non-200, if a required table is missing, or if county match rate for a state falls below a configured floor; always writes the report.
- Disk space: check available space before download and before builder extraction; refuse with a clear message rather than fail midway.

## 8. Testing

Unit (fast, offline, run in CI):
- Fixtures: a few hundred trimmed real rows each from LMcomm, LMpriv and GMRS `.dat` files, committed under `Tests/Fixtures`.
- Parser offsets: `LO` fixture row for KNNF642 must yield lat ≈ 31.3186 and lon ≈ −85.8328 (currently fails).
- Service catalog: each `ULSService` archive name equals the verified lowercase/`LM*` name list.
- County normalization: table-driven cases (Saint/St., Louisiana parishes, independent cities, Alaska, Puerto Rico).
- Pack build from fixtures → open → `counties`, `licenses`, `detail` queries return expected rows; duplicate build yields identical content (idempotent).
- `PackStore` against a local file-server stub: success, resume, checksum failure, low disk.

Integration (opt-in via environment variable, not part of default runs):
- Full-archive build for one small service (`l_coast`) and one large (`l_LMcomm`); assert Alabama has more than 20 counties and records the wall-clock and memory high-water mark.
- HEAD checks for all seven archive URLs.

Acceptance: on a clean install, choosing Alabama results in counties → licenses → detail with frequencies, with no visit to Settings and no manual import.

## 9. Sequencing inside the track

1. Reproduce the in-app empty-Browse failure in the running app; add failing tests for LO offsets and archive names; fix them.
2. Streaming builder plus a one-state spike. Measure real pack size, build time and memory. The result may change compression choice or scope; if a state pack exceeds what is reasonable to download on demand, revisit before continuing.
3. `PackStore`, `FrequencyStore`, `BrowseDataSource`, `MockBrowseDataSource`, and minimal Browse wiring.
4. Mode inference and agency grouping.
5. Hosting and weekly automation (a GitHub Actions workflow published to a repo the user creates; nothing is published without the user's go-ahead).

## 10. Open items and risks

- Pack size and build time are unmeasured until step 2 of the sequence.
- Hosting: the manifest base URL is a build setting. The default plan is GitHub Releases in a data repo the user creates.
- Agency grouping is heuristic and will be imperfect; correction UX belongs to a later track.
- FCC ULS does not cover federal users, tones, alpha tags or talkgroups; those need later tracks (self-discovery by decoding, user-contributed files, optional OpenMHz).
- The in-app failure mode is unreproduced (section 2); if reproduction shows a cause outside this design (e.g., a sandbox or entitlement issue), the plan is amended before implementation continues.
