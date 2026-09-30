import Testing
import Foundation
@testable import SignalHiveCore

private let now = Date(timeIntervalSinceReferenceDate: 3_000_000)

struct AviationMessagesTests {
    static let classificationCases: [(String, Int?, AviationMessageKind)] = [
        ("METAR KSFO 300756Z 28008KT 10SM FEW015 15/12 A3002", nil, .metar),
        ("SPECI KSFO 300756Z 28008KT 10SM FEW015 15/12 A3002", nil, .metar),
        ("TAF KSFO 300520Z 3006/3112 27010KT P6SM SCT050", nil, .taf),
        ("TAF AMD KSFO 300520Z 3006/3112 27010KT", nil, .taf),
        ("UUA /OV KSFO090025/TM 1445/FL120", nil, .pirep),
        ("PIREP UA /OV KSFO090025", nil, .pirep),
        ("SIGMET NOVEMBER 3 VALID UNTIL 302100", nil, .sigmet),
        ("CONVECTIVE SIGMET 12C VALID UNTIL 1855Z", nil, .sigmet),
        ("AIRMET SIERRA UPDT 3", nil, .airmet),
        ("CWA ZOA 300756", nil, .advisory),
        ("WINDS KSFO 6000 2720+05", nil, .windsAloft),
        ("NOTAM-TFR KSFO 3NM RADIUS", nil, .restriction),
        ("NOTAM-D KSFO RWY 10L CLSD", nil, .notam),
        ("D-ATIS KSFO INFORMATION BRAVO", nil, .atis),
        ("TWIP KSFO", nil, .twip),
        ("something unrecognised", nil, .other),
        ("something unrecognised", 5, .pirep),
        ("something unrecognised", 13, .restriction),
        ("something unrecognised", 413, .other),
    ]

    @Test(arguments: AviationMessagesTests.classificationCases)
    func reportsAreClassifiedByHowTheyStart(text: String, product: Int?, expected: AviationMessageKind) {
        #expect(AviationMessageKind.classify(reportText: text, productID: product) == expected)
    }

    @Test func aMETARBecomesADecodedMessage() throws {
        let message = AviationMessage.fisbReport(
            "KJFK 011651Z 18016G26KT 1 1/2SM -RA BR BKN008 OVC015 12/11 A2985", at: now)
        // No "METAR" keyword: it is classified by its station format only when the product says so.
        #expect(message.kind == .other)

        let metar = AviationMessage.fisbReport(
            "METAR KJFK 011651Z 18016G26KT 1 1/2SM -RA BR BKN008 OVC015 12/11 A2985", at: now)
        #expect(metar.kind == .metar)
        #expect(metar.station == "KJFK")
        #expect(metar.flightCategory == .ifr)
        #expect(metar.title == "METAR KJFK IFR")
        #expect(metar.severity == .advisory)
        #expect(metar.observation?.ceilingFeet == 800)
        #expect(metar.origin == "FIS-B 978")
    }

    @Test func clearWeatherIsJustInformation() {
        let message = AviationMessage.fisbReport("METAR KSFO 300756Z 28008KT 10SM FEW015 15/12 A3002", at: now)
        #expect(message.severity == .info)
        #expect(message.flightCategory == .vfr)
        #expect(message.title == "METAR KSFO VFR")
    }

    @Test func thunderstormsRaiseAMETARToAnAdvisory() {
        let message = AviationMessage.fisbReport("METAR KTST 011200Z 22015G30KT 10SM +TSRA BKN050CB 22/21 A2990", at: now)
        #expect(message.severity == .advisory)
    }

    @Test func severityFollowsTheKindOfReport() {
        #expect(AviationMessage.fisbReport("SIGMET NOVEMBER 3 VALID UNTIL 302100", at: now).severity == .warning)
        #expect(AviationMessage.fisbReport("NOTAM-TFR KSFO TEMPORARY FLIGHT RESTRICTIONS", at: now).severity == .warning)
        #expect(AviationMessage.fisbReport("AIRMET SIERRA UPDT 3", at: now).severity == .advisory)
        #expect(AviationMessage.fisbReport("UUA /OV KSFO090025/TM 1445/FL120/TB SEV", at: now).severity == .warning)
        #expect(AviationMessage.fisbReport("UA /OV KSFO090025/TM 1445/FL120/TB LGT", at: now).severity == .info)
        #expect(AviationMessage.fisbReport("TAF KSFO 300520Z 3006/3112 27010KT P6SM SCT050", at: now).severity == .info)
    }

    @Test func stationsAreFoundInEachKindOfReport() {
        #expect(AviationMessage.fisbReport("TAF KSFO 300520Z 3006/3112 27010KT", at: now).station == "KSFO")
        #expect(AviationMessage.fisbReport("TAF AMD KSFO 300520Z 3006/3112 27010KT", at: now).station == "KSFO")
        #expect(AviationMessage.fisbReport("WINDS KDMA 6000 2720+05", at: now).station == "KDMA")
        #expect(AviationMessage.fisbReport("D-ATIS KDMA INFORMATION BRAVO", at: now).station == "KDMA")
        #expect(AviationMessage.fisbReport("SIGMET NOVEMBER 3", at: now).station == nil)
    }

    @Test func theSameReportHasTheSameIdentityWhateverItsWhitespace() {
        let a = AviationMessage.fisbReport("METAR KSFO 300756Z 28008KT 10SM FEW015 15/12 A3002", at: now)
        let b = AviationMessage.fisbReport("  metar  ksfo 300756Z\n28008KT 10SM FEW015 15/12 A3002 ", at: now)
        let c = AviationMessage.fisbReport("METAR KSFO 300856Z 28008KT 10SM FEW015 15/12 A3002", at: now)
        #expect(a.id == b.id)
        #expect(a.id != c.id)
    }

    @Test func repeatedBroadcastsAreOneRowThatCountsThem() {
        var feed = AviationMessageFeed()
        let text = "METAR KSFO 300756Z 28008KT 10SM FEW015 15/12 A3002"
        #expect(feed.add(AviationMessage.fisbReport(text, at: now)))
        #expect(!feed.add(AviationMessage.fisbReport(text, at: now.addingTimeInterval(600))))
        #expect(!feed.add(AviationMessage.fisbReport(text, at: now.addingTimeInterval(1_200))))
        #expect(feed.messages.count == 1)
        #expect(feed.messages[0].count == 3)
        #expect(feed.messages[0].firstSeen == now)
        #expect(feed.messages[0].lastSeen == now.addingTimeInterval(1_200))
    }

    @Test func newestMessagesComeFirstAndCapacityIsEnforced() {
        var feed = AviationMessageFeed()
        feed.capacity = 3
        for index in 0..<5 {
            feed.add(AviationMessage.fisbReport("METAR KA\(index)Z 300756Z 28008KT 10SM CLR 15/12 A3002",
                                                at: now.addingTimeInterval(Double(index))))
        }
        #expect(feed.messages.count == 3)
        #expect(feed.newestFirst.first?.firstSeen == now.addingTimeInterval(4))
        #expect(feed.newestFirst.last?.firstSeen == now.addingTimeInterval(2))
    }

    private func sampleFeed() -> AviationMessageFeed {
        var feed = AviationMessageFeed()
        feed.add(AviationMessage.fisbReport("METAR KSFO 300656Z 28008KT 10SM FEW015 15/12 A3002", at: now))
        feed.add(AviationMessage.fisbReport("METAR KSFO 300756Z 28010KT 5SM BR BKN008 15/12 A3001", at: now.addingTimeInterval(3_600)))
        feed.add(AviationMessage.fisbReport("METAR KOAK 300756Z 29008KT 10SM CLR 16/11 A3003", at: now.addingTimeInterval(3_601)))
        feed.add(AviationMessage.fisbReport("TAF KSFO 300520Z 3006/3112 27010KT P6SM SCT050", at: now.addingTimeInterval(3_602)))
        feed.add(AviationMessage.fisbReport("SIGMET NOVEMBER 3 VALID UNTIL 302100 ISOL SEV TS", at: now.addingTimeInterval(3_603)))
        return feed
    }

    @Test func filteringByKindSeverityAndText() {
        let feed = sampleFeed()
        #expect(feed.filtered().count == 5)
        #expect(feed.filtered(kinds: [.metar]).count == 3)
        #expect(feed.filtered(kinds: [.metar, .taf]).count == 4)
        #expect(feed.filtered(minimumSeverity: .warning).count == 1)
        #expect(feed.filtered(minimumSeverity: .advisory).count == 2)      // the SIGMET and the IFR METAR
        #expect(feed.filtered(search: "oak").count == 1)
        #expect(feed.filtered(search: "  ksfo ").count == 3)
        #expect(feed.filtered(search: "nothing like this").isEmpty)
    }

    @Test func latestPerStationHidesSupersededReports() {
        let feed = sampleFeed()
        let latest = feed.filtered(latestPerStation: true)
        #expect(latest.count == 4)                                          // the older KSFO METAR is hidden
        #expect(latest.filter { $0.kind == .metar && $0.station == "KSFO" }.count == 1)
        #expect(latest.first(where: { $0.kind == .metar && $0.station == "KSFO" })?.body.contains("300756Z") == true)
    }

    @Test func countsGroupByKind() {
        let counts = sampleFeed().counts()
        #expect(counts[.metar] == 3 && counts[.taf] == 1 && counts[.sigmet] == 1)
        #expect(counts[.notam] == nil)
    }

    @Test func clearingEmptiesTheFeed() {
        var feed = sampleFeed()
        feed.clear()
        #expect(feed.messages.isEmpty)
    }

    @Test func severitiesCompare() {
        #expect(AviationSeverity.info < .advisory && AviationSeverity.advisory < .warning && AviationSeverity.warning < .critical)
    }
}
