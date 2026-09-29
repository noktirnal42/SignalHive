# Data Foundation Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans (native execution chosen by the user's "go ahead"). Steps use checkbox syntax.

**Goal:** First-launch State → County → License → Frequency browsing from real FCC ULS data via prebuilt per-state packs, with an on-device "build from FCC" fallback, and the known parser/URL bugs fixed test-first.

**Architecture:** A streaming pack builder (in `SignalHiveCore`) reads FCC ULS archives table-by-table, keeps active licenses only, stages them in a scratch SQLite, and emits one read-only SQLite pack per state (LZFSE-compressed, listed in `manifest.json`). The app installs packs through `PackStore` and reads them through `BrowseDataSource`. The same builder powers the hosted build and the on-device fallback.

**Tech Stack:** Swift 6.4 (language mode 6), GRDB 7 (SQLite + FTS5), ZIPFoundation, CryptoKit, Foundation `Compression` (LZFSE), swift-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-29-data-foundation-design.md`

## Global Constraints

- Data comes only from FCC ULS (data.fcc.gov). No RadioReference API, scraping, or derived data. FCC attribution string (`DataAttribution.fccNotice`) stays visible in Settings/About.
- Deployment floors: macOS 15.0, iOS 18.0; Swift language mode 6; GRDB `from: "7.0.0"`.
- Shared code (`App/Shared`, `SignalHiveCore`) contains no macOS-only API (no `NSApp`, `AppKit`).
- No `try?` on the browse/install path: every failure becomes a user-visible reason.
- Active licenses only (`license_status == "A"`).
- Correct FCC archive names: `l_LMpriv`, `l_LMcomm`, `l_gmrs`, `l_aircr`, `l_amat`, `l_coast`, `l_ship`.
- `LO.dat` lat = columns 19–22 (deg, min, sec, dir), lon = 23–26; county = 13, state = 14, city = 12, location number = 8. `EM.dat`: location number = 5, frequency (MHz) = 7, designator = 9.

## Spec deviations decided during planning (spec updated in Task 1)

- `counties` key is `countyId TEXT` = `"<ST>:<NORMALIZED NAME>"` in v1 (FIPS mapping arrives when the Census county list is added; that needs a download the user has not yet approved).
- `frequencies.modeHint` is `modeHints TEXT` (comma-separated distinct hints) because one frequency can carry several emissions.
- `ModeHint` gains `ssb` (SSB is not AM).

## Review Focus

1. Blank or zero LO coordinates must become NULL, never (0, 0) plotted in the Gulf of Guinea. (Task 4 test)
2. EN rows list a contact (`CL`) before the licensee (`L`): the licensee must win. (Task 4 test)
3. Latin-1 bytes, CRLF endings and short/garbled lines must neither crash nor silently drop the rest of the file. (Task 2 test)
4. A license with sites in two states must appear in both packs, each with only that state's sites. (Task 4 test)
5. Corrupt, truncated, wrong-checksum or newer-schema packs, and low disk, must surface an error and leave the previously installed pack untouched. (Task 7 tests)

## File Structure

New, under `Packages/SignalHiveCore/Sources/SignalHiveCore/Data/`:
- `ULS/ULSTableSource.swift` — `ULSTable`, `ULSTableSource` protocol, `DirectoryTableSource`, `ZipTableSource`
- `ULS/ULSStream.swift` — `ULSLineSplitter` (chunk → lines, encoding fallback) and `ULSStream.forEachRecord`
- `Packs/CountyNormalizer.swift` — county key + display name
- `Packs/EmissionDesignator.swift` — `ModeHint`, `EmissionInfo`, parse
- `Packs/PackManifest.swift` — `PackManifest`, `PackedState`, schema version constant
- `Packs/PackBuilder.swift` — staging + per-state emit + compress + manifest
- `Packs/FrequencyStore.swift` — read-only queries over one pack
- `Packs/PackStore.swift` — manifest fetch, download, verify, install, registry
- `Browse/BrowseModels.swift` — DTOs shared with the UI
- `Browse/BrowseDataSource.swift` — protocol + `PackBrowseDataSource` + `MockBrowseDataSource`
- `User/UserDatabase.swift` — codeplugs in `UserData.sqlite` + legacy migration

New executable: `Sources/signalhive-packbuilder/main.swift`.

Modified: `Data/ULSParser.swift` (names, LO offsets, records via stream), `App/Shared/Stores/AppModel.swift`, `App/Shared/Views/{BrowseView,FrequencyDetailView,SearchView,SettingsView}.swift`, `Package.swift`.

Deleted at the end (Task 9): `Data/AppDatabase.swift`, `Data/ULSImporter.swift`, `Tests/Core/ULSImportIntegrationTests.swift` (superseded).

---

### Task 1: Fix archive names and LO coordinate offsets

**Files:** Modify `Data/ULSParser.swift`, `Data/ULSImporter.swift` (cache filename only), spec doc; Test `Tests/Core/ULSFixTests.swift`.

**Produces:** `ULSService.archiveName: String`; corrected `ULSParser.parseLocation`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import SignalHiveCore

struct ULSFixTests {
    @Test func archiveNamesMatchFCCFilenames() {
        let expected: [ULSService: String] = [
            .lmPriv: "l_LMpriv", .lmComm: "l_LMcomm", .gmrs: "l_gmrs",
            .aircraft: "l_aircr", .amateur: "l_amat", .marine: "l_coast", .ship: "l_ship",
        ]
        #expect(expected.count == ULSService.allCases.count)
        for service in ULSService.allCases {
            let name = expected[service]!
            #expect(service.archiveName == name)
            #expect(service.completeZipURL.absoluteString
                == "https://data.fcc.gov/download/pub/uls/complete/\(name).zip")
        }
    }

    @Test func locationCoordinatesUseColumns19Through26() throws {
        // Real LO.dat row: KNNF642, Enterprise, Coffee County, AL (31°19'7.0"N 85°49'58.0"W)
        var f = Array(repeating: "", count: 51)
        f[0] = "LO"; f[1] = "1113840"; f[4] = "KNNF642"; f[8] = "1"
        f[12] = "ENTERPRISE"; f[13] = "COFFEE"; f[14] = "AL"
        f[19] = "31"; f[20] = "19"; f[21] = "7.0"; f[22] = "N"
        f[23] = "85"; f[24] = "49"; f[25] = "58.0"; f[26] = "W"
        let loc = try #require(ULSParser.parseLocation(ULSRawRecord(fields: f)))
        #expect(abs(loc.latitude - 31.31861) < 0.0001)
        #expect(abs(loc.longitude - (-85.83278)) < 0.0001)
        #expect(loc.county == "COFFEE" && loc.state == "AL" && loc.locationNumber == 1)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cd Packages/SignalHiveCore && swift test --filter ULSFixTests`. Expected: compile error (`archiveName` missing), then after adding a stub, the coordinate test fails with lat ≈ 19.12.
- [ ] **Step 3: Implement** — add `archiveName` (`l_LMpriv`, `l_LMcomm`, `l_gmrs`, `l_aircr`, `l_amat`, `l_coast`, `l_ship`); `completeZipURL` uses it; `parseLocation` reads degrees/min/sec/dir from 19–22 and 23–26; `ULSImporter` cache/extract names use `archiveName`. Amend the spec's schema notes for the three deviations above.
- [ ] **Step 4: Run** `swift test --filter ULSFixTests` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "fix: correct FCC archive names and LO.dat coordinate columns"`

---

### Task 2: Streaming table sources and record reader

**Files:** Create `Data/ULS/ULSTableSource.swift`, `Data/ULS/ULSStream.swift`; Test `Tests/Core/ULSStreamTests.swift`.

**Produces:**
```swift
public enum ULSTable: String, Sendable { case EN, HD, FR, LO, EM }
public protocol ULSTableSource: Sendable {
    /// Feed the raw bytes of `<table>.dat` to `handler` in chunks. Throws if the table is absent.
    func stream(_ table: ULSTable, handler: (Data) throws -> Void) throws
    func hasTable(_ table: ULSTable) -> Bool
}
public struct DirectoryTableSource: ULSTableSource { public init(directory: URL) }
public struct ZipTableSource: ULSTableSource { public init(archiveURL: URL) }
public struct ULSLineSplitter {           // chunk-boundary safe
    public init()
    public mutating func feed(_ chunk: Data, emit: (String) -> Void)
    public mutating func finish(emit: (String) -> Void)
}
public enum ULSStream {
    /// Calls `body` for each pipe-delimited record. `uidFilter`, when given, is applied to
    /// field 1 *before* the line is split into fields, so skipped rows cost almost nothing.
    public static func forEachRecord(in source: ULSTableSource, table: ULSTable,
        uidFilter: ((Int64) -> Bool)? = nil, body: (ULSRawRecord) throws -> Void) throws
}
```

- [ ] **Step 1: Failing tests**

```swift
import Testing
import Foundation
@testable import SignalHiveCore

struct ULSStreamTests {
    @Test func linesSplitAcrossChunkBoundariesAndCRLF() {
        var s = ULSLineSplitter(); var lines: [String] = []
        for chunk in ["EN|1|a", "bc\r\nEN|2|d", "ef\nEN|3|g"] { s.feed(Data(chunk.utf8)) { lines.append($0) } }
        s.finish { lines.append($0) }
        #expect(lines == ["EN|1|abc", "EN|2|def", "EN|3|g"])
    }

    @Test func latin1BytesDecodeInsteadOfBecomingReplacementCharacters() {
        var s = ULSLineSplitter(); var lines: [String] = []
        s.feed(Data([0x45, 0x4E, 0x7C, 0x41, 0xF1, 0x61, 0x73, 0x63, 0x6F, 0x0A])) { lines.append($0) } // "EN|Añasco"
        #expect(lines == ["EN|Añasco"])
    }

    @Test func uidFilterSkipsRowsAndShortLinesDoNotAbortTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uls-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "EN|1|x\nGARBAGE\nEN|2|y\n\nEN|3|z\n".write(to: dir.appendingPathComponent("EN.dat"), atomically: true, encoding: .utf8)
        var seen: [String] = []
        try ULSStream.forEachRecord(in: DirectoryTableSource(directory: dir), table: .EN,
                                    uidFilter: { $0 != 2 }) { seen.append($0.field(2)) }
        #expect(seen == ["x", "z"])
    }
}
```

- [ ] **Step 2:** run `swift test --filter ULSStreamTests` — Expected: compile failure (types missing).
- [ ] **Step 3: Implement.** `ULSLineSplitter` keeps a carry `Data`; splits on `0x0A`; strips trailing `0x0D`; decodes UTF-8 and falls back to `.windowsCP1252` then lossy UTF-8. `DirectoryTableSource` reads `<TABLE>.dat` with `FileHandle.read(upToCount: 1 << 20)`. `ZipTableSource` opens `Archive(url:accessMode:.read)` and `archive.extract(entry, bufferSize: 1 << 20, skipCRC32: true) { try handler($0) }`; `hasTable` checks `archive["<TABLE>.dat"] != nil`. `forEachRecord` extracts the uid by scanning the line for the first two `|`, applies `uidFilter` when the record has a numeric field 1, then builds `ULSRawRecord(fields:)` via `split(separator: "|", omittingEmptySubsequences: false)`. Lines with fewer than 2 fields are skipped.
- [ ] **Step 4:** run — Expected: PASS. **Step 5:** commit `feat: streaming ULS table sources and record reader`.

---

### Task 3: County normalizer and emission designator parsing

**Files:** Create `Data/Packs/CountyNormalizer.swift`, `Data/Packs/EmissionDesignator.swift`; Tests `Tests/Core/CountyNormalizerTests.swift`, `Tests/Core/EmissionDesignatorTests.swift`.

**Produces:**
```swift
public enum CountyNormalizer {
    public static func key(_ raw: String) -> String                       // "ST. LOUIS COUNTY" -> "SAINT LOUIS"
    public static func displayName(key: String, stateCode: String) -> String  // "SAINT LOUIS","MO" -> "St. Louis County"
    public static func countyID(raw: String, stateCode: String) -> String?    // "MO:SAINT LOUIS"; nil for blank
}
public enum ModeHint: String, Codable, CaseIterable, Sendable { case analogFM, am, ssb, digitalP25, digitalOther, unknown }
public struct EmissionInfo: Equatable, Sendable { public var bandwidthHz: Double?; public var modeHint: ModeHint }
public enum EmissionDesignator { public static func parse(_ code: String) -> EmissionInfo }
```

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import SignalHiveCore

struct CountyNormalizerTests {
    @Test(arguments: [
        ("ST. LOUIS", "SAINT LOUIS"), ("ST LOUIS COUNTY", "SAINT LOUIS"), ("STE GENEVIEVE", "SAINTE GENEVIEVE"),
        ("DE KALB", "DEKALB"), ("O'BRIEN", "OBRIEN"), ("QUEEN ANNE'S", "QUEEN ANNES"),
        ("  east   baton rouge parish ", "EAST BATON ROUGE"), ("ALEXANDRIA (CITY)", "ALEXANDRIA CITY"),
        ("ANCHORAGE BOROUGH", "ANCHORAGE"), ("", ""),
    ]) func keys(raw: String, key: String) { #expect(CountyNormalizer.key(raw) == key) }

    @Test func displayNamesUseLocalSuffixConventions() {
        #expect(CountyNormalizer.displayName(key: "SAINT LOUIS", stateCode: "MO") == "St. Louis County")
        #expect(CountyNormalizer.displayName(key: "EAST BATON ROUGE", stateCode: "LA") == "East Baton Rouge Parish")
        #expect(CountyNormalizer.displayName(key: "ALEXANDRIA CITY", stateCode: "VA") == "Alexandria City")
        #expect(CountyNormalizer.displayName(key: "ANCHORAGE", stateCode: "AK") == "Anchorage")
        #expect(CountyNormalizer.displayName(key: "MCKEAN", stateCode: "PA") == "McKean County")
    }

    @Test func countyIDIsStateScopedAndNilForBlank() {
        #expect(CountyNormalizer.countyID(raw: "Coffee", stateCode: "AL") == "AL:COFFEE")
        #expect(CountyNormalizer.countyID(raw: "  ", stateCode: "AL") == nil)
    }
}

struct EmissionDesignatorTests {
    @Test(arguments: [
        ("20K0F3E", 20000.0, ModeHint.analogFM), ("11K2F3E", 11200.0, .analogFM), ("20K0F2D", 20000.0, .analogFM),
        ("8K10F1E", 8100.0, .digitalP25), ("8K10F1W", 8100.0, .digitalP25),
        ("16K0F1E", 16000.0, .digitalOther), ("20K0G7W", 20000.0, .digitalOther),
        ("4K00J3E", 4000.0, .ssb), ("6K00A3E", 6000.0, .am),
    ]) func parses(code: String, bw: Double, mode: ModeHint) {
        let info = EmissionDesignator.parse(code)
        #expect(info.bandwidthHz == bw); #expect(info.modeHint == mode)
    }
    @Test func garbageIsUnknownWithNoBandwidth() {
        #expect(EmissionDesignator.parse("") == EmissionInfo(bandwidthHz: nil, modeHint: .unknown))
        #expect(EmissionDesignator.parse("hello") == EmissionInfo(bandwidthHz: nil, modeHint: .unknown))
    }
}
```

- [ ] **Step 2:** run both suites — Expected: compile failure. **Step 3: Implement.** Key: uppercase; drop `.`,`'`,`,`; turn `(CITY)` into ` CITY`; tokenise; token `ST`→`SAINT`, `STE`→`SAINTE`; drop a trailing `COUNTY|PARISH|BOROUGH|MUNICIPIO|MUNICIPALITY` and the two-token `CENSUS AREA`; alias table `DE KALB→DEKALB, DE SOTO→DESOTO, DE WITT→DEWITT, DU PAGE→DUPAGE`; collapse whitespace. Display: title-case tokens, `SAINT→St.`, `SAINTE→Ste.`, `MC`+rest → `Mc`+Capitalized; suffix ` Parish` for LA, none for AK/PR or keys ending in ` CITY`, else ` County`. Designator: a 4-char bandwidth with one of `H K M G` as decimal marker in positions 1–3 (`20K0`→20.0 kHz, `8K10`→8100 Hz) then modulation/nature/info chars; `F|G` + nature `2|3` → analogFM; `F1E|F1D|F1W` with bandwidth 8000–8200 → digitalP25; other digital natures (`1`,`7`,`8`,`9`) → digitalOther; `A` → am; `H|J|R|B` → ssb; else unknown.
- [ ] **Step 4:** run — PASS. **Step 5:** commit `feat: county normalizer and emission designator parsing`.

---

### Task 4: Pack builder

**Files:** Create `Data/Packs/PackManifest.swift`, `Data/Packs/PackBuilder.swift`; Test `Tests/Core/PackBuilderTests.swift`, fixture writer in `Tests/Core/FixtureTables.swift`.

**Produces:**
```swift
public let packSchemaVersion = 1
public struct PackedState: Codable, Sendable, Equatable { stateCode, fileName, compressedBytes: Int64, expandedBytes: Int64, sha256, licenseCount, siteCount, frequencyCount }
public struct PackManifest: Codable, Sendable, Equatable { schemaVersion: Int; fccSnapshotDate: String; builtAt: String; packs: [PackedState] }
public struct PackBuildProgress: Sendable { public var phase: String; public var fraction: Double }
public struct PackBuilder: Sendable {
    public init(workDirectory: URL, outputDirectory: URL)
    public func build(sources: [any ULSTableSource], states: Set<String>?, snapshotDate: String,
                      progress: (@Sendable (PackBuildProgress) -> Void)?) throws -> PackManifest
}
```
Pack schema (v1): `meta`, `counties(countyId PK, name, stateCode, licenseCount)`, `licenses(uid PK, callSign, licenseeName, entityType, serviceCode, grantDate, expiredDate, city, zip)`, `sites(uid, locationNumber, city, countyId, stateCode, latitude, longitude, PK(uid, locationNumber))`, `frequencies(uid, locationNumber, frequencyHz, upperBandHz, classStationCode, powerW, modeHints, bandwidthHz, UNIQUE(uid, locationNumber, frequencyHz, classStationCode))`, FTS5 `licenses_fts(callSign, licenseeName)`, indexes on `sites(countyId)`, `sites(latitude, longitude)`, `frequencies(frequencyHz)`, `frequencies(uid)`.

Algorithm: (1) HD → `st_license` + in-memory `Set<Int64>` of active uids; (2) EN/LO/FR/EM streamed with `uidFilter = active.contains` into staging tables; EN prefers `L` rows (later `L` replaces earlier non-`L`); LO with blank/zero coordinates stores NULL; (3) `st_em_agg` = per (uid, loc, round(hz)) `group_concat(DISTINCT modeHint)` and `MAX(bandwidthHz)`; (4) uids with no site get a fallback site from their entity (location 0, no coordinates, no county); (5) per state: `ATTACH` staging, register SQL function `county_id(raw, state)`, fill pack tables, count, FTS, `VACUUM`; (6) LZFSE compress, SHA-256, write `manifest.json`; (7) always delete staging and temp packs.

- [ ] **Step 1: Failing tests** (fixture rows are tiny hand-built ULS tables written by `FixtureTables.write(to:)`; they include: active AL licensee KAAA111 with a `CL` contact row *before* the `L` row, two sites (one with blank coordinates), FR rows with `8K10F1E` and `20K0F3E` emissions; a cancelled license `C`; a license KBBB222 with sites in GA and AL; a GMRS-style license with EN only.)

```swift
import Testing, Foundation, GRDB
@testable import SignalHiveCore

struct PackBuilderTests {
    func build() throws -> (PackManifest, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID())")
        let tables = root.appendingPathComponent("tables"), out = root.appendingPathComponent("out")
        try FixtureTables.write(to: tables)
        let m = try PackBuilder(workDirectory: root.appendingPathComponent("work"), outputDirectory: out)
            .build(sources: [DirectoryTableSource(directory: tables)], states: nil, snapshotDate: "2026-09-25", progress: nil)
        return (m, out)
    }
    func open(_ m: PackManifest, _ out: URL, _ st: String) throws -> DatabaseQueue {
        let p = m.packs.first { $0.stateCode == st }!
        let raw = try (Data(contentsOf: out.appendingPathComponent(p.fileName)) as NSData).decompressed(using: .lzfse)
        let path = out.appendingPathComponent("\(st).sqlite"); try (raw as Data).write(to: path)
        var c = Configuration(); c.readonly = true
        return try DatabaseQueue(path: path.path, configuration: c)
    }

    @Test func onlyActiveLicensesAreKept() throws {
        let (m, out) = try build(); let db = try open(m, out, "AL")
        let calls = try db.read { try String.fetchAll($0, sql: "SELECT callSign FROM licenses ORDER BY callSign") }
        #expect(calls.contains("KAAA111") && !calls.contains("KCCC333"))   // KCCC333 is cancelled
    }
    @Test func licenseeRowWinsOverEarlierContactRow() throws {
        let (m, out) = try build(); let db = try open(m, out, "AL")
        let n = try db.read { try String.fetchOne($0, sql: "SELECT licenseeName FROM licenses WHERE callSign='KAAA111'") }
        #expect(n == "COFFEE COUNTY SHERIFF")
    }
    @Test func blankCoordinatesBecomeNullNotZero() throws {
        let (m, out) = try build(); let db = try open(m, out, "AL")
        let r = try db.read { try Row.fetchOne($0, sql: "SELECT latitude, longitude FROM sites WHERE uid=1001 AND locationNumber=2") }
        #expect(r?["latitude"] as Double? == nil && r?["longitude"] as Double? == nil)
    }
    @Test func licenseWithSitesInTwoStatesAppearsInBothWithOnlyLocalSites() throws {
        let (m, out) = try build()
        for (st, expectedLoc) in [("AL", 1), ("GA", 2)] {
            let db = try open(m, out, st)
            let locs = try db.read { try Int.fetchAll($0, sql: "SELECT locationNumber FROM sites WHERE uid=1002") }
            #expect(locs == [expectedLoc])
        }
    }
    @Test func modeHintsAndCountiesAreDerived() throws {
        let (m, out) = try build(); let db = try open(m, out, "AL")
        let hints = try db.read { try String.fetchOne($0, sql: "SELECT modeHints FROM frequencies WHERE uid=1001 AND frequencyHz=856012500") }
        #expect(hints?.contains("digitalP25") == true && hints?.contains("analogFM") == true)
        let c = try db.read { try Row.fetchOne($0, sql: "SELECT name, licenseCount FROM counties WHERE countyId='AL:COFFEE'") }
        #expect(c?["name"] as String? == "Coffee County")
    }
    @Test func licenseWithoutLocationTableGetsFallbackSiteFromEntity() throws {
        let (m, out) = try build(); let db = try open(m, out, "AL")
        let city = try db.read { try String.fetchOne($0, sql: "SELECT city FROM sites WHERE uid=1003") }
        #expect(city == "OZARK")
    }
    @Test func manifestHasChecksumsAndBuildIsRepeatable() throws {
        let (m1, _) = try build(); let (m2, _) = try build()
        #expect(m1.schemaVersion == packSchemaVersion && m1.packs.allSatisfy { $0.sha256.count == 64 })
        #expect(m1.packs.map(\.stateCode) == m2.packs.map(\.stateCode))
    }
}
```

- [ ] **Step 2:** run `swift test --filter PackBuilderTests` — Expected: compile failure (types missing).
- [ ] **Step 3: Implement** `PackManifest.swift` and `PackBuilder.swift` per the algorithm above.
- [ ] **Step 4:** run — PASS. **Step 5:** commit `feat: streaming per-state pack builder`.

---

### Task 5: Packbuilder CLI and the size/time spike

**Files:** Modify `Package.swift` (add executable target `signalhive-packbuilder`); Create `Sources/signalhive-packbuilder/main.swift`, `docs/superpowers/specs/2026-09-29-data-foundation-spike.md`.

**Produces:** `signalhive-packbuilder --out DIR --snapshot YYYY-MM-DD [--states AL,GA] --archive PATH [--archive PATH ...]` (each `--archive` becomes a `ZipTableSource`).

- [ ] **Step 1:** write `main.swift` (argument parsing by hand; prints per-phase progress and a final table of states, sizes and counts; exits non-zero on error).
- [ ] **Step 2:** `swift build -c release --product signalhive-packbuilder`.
- [ ] **Step 3:** run against the already-cached real archives (no new download): `/usr/bin/time -l .build/release/signalhive-packbuilder --out $SCRATCH/packs --snapshot 2026-09-25 --archive $TMPDIR/l_LMcomm.zip --archive $TMPDIR/l_gmrs.zip`. Record wall time, peak RSS (`maximum resident set size`), and per-state compressed/expanded sizes in the spike doc. Sanity-check: AL has more than 20 counties; a known license resolves.
- [ ] **Step 4:** if peak memory or per-state size looks unreasonable, stop and revise the spec before continuing.
- [ ] **Step 5:** commit `feat: packbuilder CLI and spike measurements`.

---

### Task 6: FrequencyStore and BrowseDataSource

**Files:** Create `Data/Packs/FrequencyStore.swift`, `Data/Browse/BrowseModels.swift`, `Data/Browse/BrowseDataSource.swift`; Test `Tests/Core/FrequencyStoreTests.swift`.

**Produces:** the protocol from spec §6 with concrete types:
```swift
public struct CountyID: Hashable, Sendable { public var stateCode: String; public var id: String }
public struct CountySummary: Identifiable, Hashable, Sendable { public var id: CountyID; public var name: String; public var licenseCount: Int }
public enum PackStatus: Hashable, Sendable { case notInstalled(sizeBytes: Int64?), downloading(progress: Double), verifying, installed(snapshot: String), failed(reason: String) }
public struct StateAvailability: Identifiable, Hashable, Sendable { public var code: String; public var name: String; public var status: PackStatus; public var id: String { code } }
public struct LicenseFilter: Sendable { public var serviceCodes: Set<String>; public var text: String?; public static let none }
public struct LicenseSummary: Identifiable, Hashable, Sendable { uid, callSign, licenseeName, serviceCode, serviceName, city, frequencyCount, modeHints: [ModeHint] }
public struct FrequencyRecord: Identifiable, Hashable, Sendable { uid, locationNumber, frequencyHz, upperBandHz, classStationCode, powerW, modeHints, bandwidthHz }
public struct SiteRecord: Identifiable, Hashable, Sendable { uid, locationNumber, city, countyName, stateCode, latitude, longitude }
public struct LicenseDetail: Sendable { public var summary: LicenseSummary; grantDate, expiredDate: String; sites: [SiteRecord]; frequencies: [FrequencyRecord] }
public enum SearchScope: Sendable { case all, callSign, licensee, frequency }
public struct SearchHit: Identifiable, Hashable, Sendable { kind, uid, title, subtitle, frequencyHz }
public struct Coordinate: Sendable { lat: Double; lon: Double }
public struct NearbyFrequency: Identifiable, Hashable, Sendable { frequency: FrequencyRecord, callSign, city, distanceKm }
public protocol BrowseDataSource: Sendable {
    func states() async -> [StateAvailability]
    func counties(in state: String) async throws -> [CountySummary]
    func licenses(in county: CountyID, filter: LicenseFilter) async throws -> [LicenseSummary]
    func detail(uid: Int64) async throws -> LicenseDetail
    func search(_ query: String, scope: SearchScope) async throws -> [SearchHit]
    func frequencies(near: Coordinate, radiusKm: Double) async throws -> [NearbyFrequency]
}
```

- [ ] **Step 1: Failing tests** — build a pack from `FixtureTables` (as in Task 4), open with `FrequencyStore(path:)`, then assert: `counties()` returns `Coffee County` with count ≥ 1; `licenses(in: "AL:COFFEE")` returns KAAA111 with `frequencyCount == 1` and hints `[.analogFM, .digitalP25]` (sorted by enum order); `detail(uid: 1001)` returns two sites and the frequency; `search("coffee", .licensee)` and `search("KAAA", .callSign)` hit; `search("856.0125", .frequency)` hits the 856.0125 MHz row; `nearby` around 31.3186, −85.8328 with 5 km returns the site with coordinates and never the NULL-coordinate site; a user search containing `"` or `*` or `AND` does not throw.
- [ ] **Step 2:** run — compile failure. **Step 3: Implement** `FrequencyStore` (read-only `DatabaseQueue`; FTS query built by quoting each token as `"tok"*`), `PackBrowseDataSource` (holds a `PackStore`, opens/caches a `FrequencyStore` per installed state, fans out search across states), and `MockBrowseDataSource` (canned Alabama data: 12 counties, ~30 licenses with sheriff/fire/EMS/utility names, realistic frequencies) for Track B previews.
- [ ] **Step 4:** run — PASS. **Step 5:** commit `feat: FrequencyStore and BrowseDataSource with mock`.

---

### Task 7: PackStore (install, verify, status)

**Files:** Create `Data/Packs/PackStore.swift`; Test `Tests/Core/PackStoreTests.swift`.

**Produces:**
```swift
public enum PackStoreError: Error, LocalizedError, Equatable { case manifestUnavailable(String), checksumMismatch, insufficientSpace(needed: Int64, available: Int64), schemaTooNew(Int), notInManifest(String), corrupt(String) }
public actor PackStore {
    public init(manifestBaseURL: URL?, installDirectory: URL, availableBytes: @escaping @Sendable () -> Int64 = PackStore.systemAvailableBytes, session: URLSession = .shared)
    public func refreshManifest() async throws -> PackManifest
    public func availability() -> [StateAvailability]
    public func install(state: String, progress: @escaping @Sendable (PackStatus) -> Void) async throws
    public func installedStates() -> [String]
    public func databaseURL(for state: String) -> URL?
    public func remove(state: String) throws
    public static func systemAvailableBytes() -> Int64
}
```
Install flow: manifest entry → space check (`available < 2 × expandedBytes` → `insufficientSpace`) → download (`URLSession.download`, works for `file://`; progress through a download delegate) → SHA-256 vs manifest (`checksumMismatch`, temp deleted) → LZFSE decompress to `.partial` → open read-only and check `meta.schemaVersion <= packSchemaVersion` (`schemaTooNew`) → atomic `replaceItemAt` into `SH-<ST>-<date>.sqlite` → delete older files for that state. Any failure leaves the previous install untouched.

- [ ] **Step 1: Failing tests** using a builder-made local pack directory served via `file://`: install succeeds and `installedStates() == ["AL"]`; flipping one byte of the `.lzfse` → `checksumMismatch` and no installed file; second install with corrupted pack does not remove the earlier good install; `availableBytes: { 1 }` → `insufficientSpace`; a manifest with `schemaVersion: 99` pack → `schemaTooNew`; unknown state → `notInManifest("ZZ")`; `manifestBaseURL == nil` → `manifestUnavailable`.
- [ ] **Step 2:** run — compile failure. **Step 3:** implement. **Step 4:** run — PASS. **Step 5:** commit `feat: PackStore install/verify with failure handling`.

---

### Task 8: UserDatabase, on-device build, and app wiring

**Files:** Create `Data/User/UserDatabase.swift`, `Data/Packs/LocalPackService.swift`; Modify `AppModel.swift`, `BrowseView.swift`, `FrequencyDetailView.swift`, `SearchView.swift`, `SettingsView.swift`, `project.yml` (regenerate project); Test `Tests/Core/UserDatabaseTests.swift`.

**Produces:**
```swift
public actor UserDatabase {
    public static func open(at path: String) async throws -> UserDatabase
    public static func defaultURL() -> URL                      // .../SignalHive/UserData.sqlite
    public func migrateCodeplugsIfNeeded(fromLegacy legacyPath: String) async throws -> Int   // rows copied
    public func saveCodeplug(_:) async throws; public func codeplugs() async throws -> [Codeplug]; public func deleteCodeplug(id: UUID) async throws
}
public actor LocalPackService {           // "Build from FCC on this Mac"
    public init(workDirectory: URL, outputDirectory: URL)
    public func build(services: [ULSService], states: Set<String>, snapshotDate: String,
                      progress: @escaping @Sendable (PackBuildProgress) -> Void) async throws
}
```
`LocalPackService` downloads each archive with `URLSession.download` (progress via delegate; disk-space pre-check; resumes an existing complete archive), runs `PackBuilder` in `Task.detached`, deletes archives afterwards, and writes packs + manifest to a local directory that `PackStore` then installs from as `file://`.

- [ ] **Step 1: Failing test** — a legacy DB with two codeplug rows migrates into a fresh `UserData.sqlite` (2 copied; a second call copies 0; legacy file untouched).
- [ ] **Step 2–4:** implement `UserDatabase` (same `codeplugs` schema as legacy). Rework `AppModel`: `browse: any BrowseDataSource`, `packs: PackStore`, `userData: UserDatabase`, `packStatuses` and surfaced `lastError`. Browse view: no `NSApp`; when the selected state is `notInstalled` show size + "Download" (or "Build from FCC on this Mac" when no manifest URL / manifest unreachable), progress while downloading, reason + retry when failed. `FrequencyDetailView`/`SearchView` consume `BrowseDataSource` types. `SettingsView` import section becomes the local-build section. Regenerate the project (`xcodegen generate`), then `xcodebuild -scheme SignalHive -destination 'platform=macOS' build`.
- [ ] **Step 5:** run `swift test` (whole package) and the macOS build; commit `feat: wire packs, user data and local build into the app`.

---

### Task 9: Remove superseded legacy code and verify end to end

**Files:** Delete `Data/AppDatabase.swift`, `Data/ULSImporter.swift`, `Tests/Core/ULSImportIntegrationTests.swift`; keep `ULSParser` record types used by the builder.

- [ ] **Step 1:** confirm nothing references the removed types (`grep`), delete, and build both the package and the macOS app.
- [ ] **Step 2:** replace the deleted integration test with an opt-in `PackBuilderRealDataTests` gated by `SIGNALHIVE_REAL_ARCHIVES=/path/to/l_LMcomm.zip`; when unset the test is skipped with an explicit reason, not silently passed.
- [ ] **Step 3:** run the full `swift test` and run the real-data test once against the cached LMcomm archive: Alabama has more than 20 counties; licenses and detail resolve.
- [ ] **Step 4:** launch the built app against a locally built Alabama pack and confirm state → counties → licenses → detail with frequencies (screenshots).
- [ ] **Step 5:** commit `chore: remove legacy on-device importer and database`.

---

### Task 10 (v1.1): Agency grouping

**Files:** Create `Data/Packs/AgencyClassifier.swift`; extend `PackBuilder` (`agencies` table, `licenses.agencyId`) and `BrowseDataSource` (`agencies(in:)`); Test `Tests/Core/AgencyClassifierTests.swift`.

- [ ] **Step 1: Failing test** — table-driven: `COFFEE COUNTY SHERIFF` → (Law, "Coffee County Sheriff"), `CITY OF ENTERPRISE FIRE DEPT` → Fire, `ENTERPRISE FIRE DEPARTMENT` and `Enterprise Fire Dept.` group to one agency, `MERCY AMBULANCE SERVICE INC` → EMS, `ALABAMA POWER COMPANY` → Utilities, `ACME PIZZA LLC` → Business, unknown → Other.
- [ ] **Step 2–5:** implement keyword/regex rules over the normalized licensee name plus service code, group by normalized name, add schema columns, expose `agencies(in:)`, commit `feat: derive agencies and categories from licensee names`.

---

## Self-review

- **Spec coverage:** pack builder (T4), counties (T3/T4), PackStore (T7), FrequencyStore/BrowseDataSource/Mock (T6), UserData + migration + on-device fallback (T8), first-run states and no `NSApp` (T8), bug fixes (T1), mode inference + agencies (T3/T10), testing/opt-in real-data (T9), spike (T5). Hosting automation is intentionally not in this plan: it needs a repository the user creates.
- **Placeholders:** none; unmeasured facts (pack size, timing) are produced by Task 5 rather than assumed.
- **Type consistency:** `CountyID`, `PackStatus`, `ModeHint`, `PackManifest`, `PackedState` are defined once (T3/T4/T6) and reused by name.
- **Review Focus:** each of the five items is pinned to a test in the task that owns the code.
