import Testing
import Foundation
@testable import SignalHiveCore

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func rated(_ index: Int, category: SatelliteCategory = .weather, grade: PassGrade = .good, elevation: Double = 40,
                   kind: SignalKind? = .lrpt) -> RatedPass {
    let aos = start.addingTimeInterval(Double(index) * 600)
    let pass = PredictedPass(id: "\(index)-1", noradID: index, satelliteName: "SAT \(index)", aos: aos, tca: aos.addingTimeInterval(300),
                             los: aos.addingTimeInterval(600), aosAzimuthDegrees: 0, tcaAzimuthDegrees: 90, losAzimuthDegrees: 180,
                             maxElevationDegrees: elevation, minRangeKM: 800, sunElevationAtTCADegrees: 0, sunlitAtTCA: true,
                             startsBeforeWindow: false, endsAfterWindow: false, elementEpoch: start, track: [])
    let record = SatelliteRecord(
        elements: OrbitalElements(name: "SAT \(index)", noradID: index, epoch: start, inclinationDegrees: 98, raanDegrees: 0, eccentricity: 0.001,
                                  argumentOfPerigeeDegrees: 0, meanAnomalyDegrees: 0, meanMotionRevsPerDay: 14.2, bstar: 1e-5),
        category: category, status: .alive, transmitters: [], strength: .unknown, note: nil)
    let transmitter = kind.map {
        TransmitterInfo(id: "t\(index)", noradID: index, summary: "", downlinkHz: 137.1e6, mode: nil, kind: $0, isActive: true, service: nil, verifiedOnAir: nil)
    }
    return RatedPass(pass: pass, record: record, transmitter: transmitter,
                     rating: PassRating(grade: grade, score: 50, reasons: [], remedy: nil), confidence: .good)
}

struct SatellitesStateTests {
    private let owner = Observer(latitudeDegrees: 35.25, longitudeDegrees: -109.44)

    @Test func noObserverIsNeedsLocation() {
        let state = SatellitesState(observer: nil)
        #expect(state.phase == .needsLocation)
        #expect(state.visible().isEmpty)
        #expect(SatellitesState(observer: owner).phase == .loading)
    }

    @Test func offlineWithCachedPassesStillListsThem() {
        var state = SatellitesState(observer: owner)
        state.all = (0..<5).map { rated($0) }
        state.phase = .offline("this Mac has no internet connection; showing the saved copy")
        #expect(state.phase == .offline("this Mac has no internet connection; showing the saved copy"))
        #expect(state.visible().count == 5)
    }

    @Test func filtersHideLowGradesAndSayHowMany() {
        var state = SatellitesState(observer: owner)
        // 30 passes: 12 good ones high enough, 18 that fail one filter or another.
        var passes: [RatedPass] = (0..<12).map { rated($0, grade: .good, elevation: 40) }
        passes += (12..<20).map { rated($0, grade: .poor, elevation: 40) }
        passes += (20..<26).map { rated($0, grade: .notReceivable, elevation: 80) }
        passes += (26..<30).map { rated($0, grade: .excellent, elevation: 6) }
        state.all = passes
        state.phase = .ready
        #expect(state.visible().count == 12)
        #expect(state.summary == "12 of 30 passes shown")
    }

    @Test func summaryWhenEverythingIsShownOrNothingExists() {
        var state = SatellitesState(observer: owner)
        #expect(state.summary == "No passes")
        state.all = (0..<3).map { rated($0) }
        #expect(state.summary == "3 of 3 passes shown")
        state.all = [rated(0)]
        #expect(state.summary == "1 of 1 pass shown")
    }

    @Test func categoryFilterRemovesOtherCategories() {
        var state = SatellitesState(observer: owner)
        state.all = [rated(1, category: .weather), rated(2, category: .stations), rated(3, category: .amateur), rated(4, category: .weather)]
        state.filters.categories = [.weather]
        #expect(state.visible().map(\.pass.noradID) == [1, 4])
        state.filters.categories = [.stations, .amateur]
        #expect(state.visible().map(\.pass.noradID) == [2, 3])
        state.filters.categories = []
        #expect(state.visible().isEmpty)
    }

    @Test func minimumElevationFilterUsesPeakElevation() {
        var state = SatellitesState(observer: owner)
        state.all = [rated(1, elevation: 9.9), rated(2, elevation: 10), rated(3, elevation: 75)]
        #expect(state.visible().map(\.pass.noradID) == [2, 3])
        state.filters.minimumElevationDegrees = 60
        #expect(state.visible().map(\.pass.noradID) == [3])
        state.filters.minimumElevationDegrees = 0
        #expect(state.visible().count == 3)
    }

    @Test func gradeFilterIsAMinimum() {
        var state = SatellitesState(observer: owner)
        state.all = [.notReceivable, .poor, .marginal, .good, .excellent].enumerated().map { rated($0.offset, grade: $0.element) }
        state.filters.minimumGrade = .good
        #expect(state.visible().map(\.rating.grade) == [.good, .excellent])
        state.filters.minimumGrade = .notReceivable
        #expect(state.visible().count == 5)
    }

    @Test func standardFiltersAreWhatTheScreenOpensWith() {
        let standard = PassFilters.standard
        #expect(standard.categories == Set(SatelliteCategory.allCases))
        #expect(standard.minimumGrade == .marginal)
        #expect(standard.minimumElevationDegrees == 10)
        #expect(standard.horizonHours == 48)
        #expect(standard.decodableOnly, "the screen opens on signals SignalHive will be able to decode")
        #expect(SatellitesState(observer: nil).filters == standard)
    }

    @Test func decodableOnlyHidesSignalsNothingWillDecode() {
        var state = SatellitesState(observer: owner)
        state.all = [rated(1, kind: .lrpt), rated(2, kind: .bpskTelemetry), rated(3, kind: .fmVoice), rated(4, kind: .other),
                     rated(5, kind: .unknown), rated(6, kind: nil)]
        #expect(state.filters.decodableOnly)
        #expect(state.visible().map(\.pass.noradID) == [1, 3])
        state.filters.decodableOnly = false
        #expect(state.visible().count == 6)
    }
}
