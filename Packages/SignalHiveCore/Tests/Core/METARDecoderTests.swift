import Testing
import Foundation
@testable import SignalHiveCore

struct METARDecoderTests {
    @Test func aClearDayReportDecodesFieldByField() throws {
        let metar = try #require(METARDecoder.decode("METAR KSFO 300756Z 28008KT 10SM FEW015 15/12 A3002"))
        #expect(metar.station == "KSFO")
        #expect(!metar.isSpecial)
        #expect(metar.day == 30 && metar.hour == 7 && metar.minute == 56)
        #expect(metar.windDirectionDegrees == 280 && metar.windSpeedKnots == 8 && metar.windGustKnots == nil)
        #expect(metar.visibilityMiles == 10)
        #expect(metar.sky == [SkyLayer(cover: .few, baseFeet: 1_500, cloudType: nil)])
        #expect(metar.ceilingFeet == nil)
        #expect(metar.temperatureC == 15 && metar.dewpointC == 12)
        #expect(metar.altimeterInHg == 30.02)
        #expect(metar.flightCategory == .vfr)
    }

    @Test func gustsMixedFractionsWeatherAndRemarks() throws {
        let metar = try #require(METARDecoder.decode(
            "KJFK 011651Z 18016G26KT 1 1/2SM -RA BR BKN008 OVC015 12/11 A2985 RMK AO2 SLP110"))
        #expect(metar.station == "KJFK")
        #expect(metar.windDirectionDegrees == 180 && metar.windSpeedKnots == 16 && metar.windGustKnots == 26)
        #expect(metar.visibilityMiles == 1.5)
        #expect(metar.weather == ["-RA", "BR"])
        #expect(metar.sky.count == 2)
        #expect(metar.ceilingFeet == 800)
        #expect(metar.flightCategory == .ifr)
        #expect(metar.remarks == "AO2 SLP110")
        #expect(metar.temperatureC == 12 && metar.dewpointC == 11)
    }

    @Test func fogWithVerticalVisibilityIsLowIFR() throws {
        let metar = try #require(METARDecoder.decode("METAR KXYZ 020053Z 00000KT 1/4SM FG VV002 08/08 A3001"))
        #expect(metar.visibilityMiles == 0.25)
        #expect(metar.weather == ["FG"])
        #expect(metar.sky == [SkyLayer(cover: .verticalVisibility, baseFeet: 200, cloudType: nil)])
        #expect(metar.ceilingFeet == 200)
        #expect(metar.flightCategory == .lifr)
        #expect(metar.windSummary == "Calm")
    }

    @Test func specialReportsAndVariableWind() throws {
        let metar = try #require(METARDecoder.decode("SPECI KABC 101253Z VRB03KT 4SM BR SCT020 BKN035 10/09 A3010"))
        #expect(metar.isSpecial)
        #expect(metar.windIsVariable && metar.windDirectionDegrees == nil && metar.windSpeedKnots == 3)
        #expect(metar.ceilingFeet == 3_500)
        #expect(metar.flightCategory == .mvfr)              // 4 miles visibility, though the ceiling is high
        #expect(metar.windSummary == "Variable at 3 kt")
    }

    @Test func belowFreezingAndOpenLimits() throws {
        let metar = try #require(METARDecoder.decode("METAR KDEF 151853Z 36010KT P6SM CLR M05/M08 A3025"))
        #expect(metar.visibilityMiles == 6 && metar.visibilityIsMoreThan)
        #expect(metar.sky == [SkyLayer(cover: .clear, baseFeet: nil, cloudType: nil)])
        #expect(metar.temperatureC == -5 && metar.dewpointC == -8)
        #expect(metar.altimeterInHg == 30.25)
        #expect(metar.flightCategory == .vfr)
        #expect(metar.visibilitySummary == "Over 6 SM")
    }

    @Test func aRunwayVisualRangeGroupAndTrailingEqualsSignAreHandled() throws {
        let metar = try #require(METARDecoder.decode("METAR KLOW 151853Z 09005KT M1/4SM R28L/0600FT FG OVC001 M02/M02 A2998="))
        #expect(metar.visibilityMiles == 0.25 && metar.visibilityIsLessThan)
        #expect(metar.weather == ["FG"])
        #expect(metar.sky.first?.baseFeet == 100)
        #expect(metar.temperatureC == -2 && metar.dewpointC == -2)
        #expect(metar.altimeterInHg == 29.98)
        #expect(metar.flightCategory == .lifr)
        #expect(metar.visibilitySummary == "Under 1/4 SM")
    }

    @Test func thunderstormsAndCloudTypes() throws {
        let metar = try #require(METARDecoder.decode("METAR KTST 011200Z 22015G30KT 3SM +TSRA BKN015CB 22/21 A2990"))
        #expect(metar.weather == ["+TSRA"])
        #expect(metar.sky.first?.cloudType == "CB")
        #expect(metar.hasThunderstorm)
        #expect(metar.flightCategory == .mvfr)
        #expect(metar.weatherSummary == "heavy thunderstorm with rain")
        #expect(metar.windSummary == "220° at 15 kt, gusting 30")
        #expect(metar.skySummary == "Broken 1,500 ft (cumulonimbus)")
    }

    @Test func reportsFromOutsideTheUSUseMetresAndHectopascals() throws {
        let metar = try #require(METARDecoder.decode("METAR EGLL 151850Z 24008KT 9999 SCT025 15/10 Q1013"))
        #expect(metar.station == "EGLL")
        #expect(metar.windSpeedKnots == 8)
        #expect((metar.visibilityMiles ?? 0) > 6 && metar.visibilityIsMoreThan)
        #expect(abs((metar.altimeterInHg ?? 0) - 29.91) < 0.01)
        #expect(metar.flightCategory == .vfr)
    }

    @Test func aWindVariationRangeIsSkippedNotMisread() throws {
        let metar = try #require(METARDecoder.decode("METAR KSEA 151853Z 20008KT 170V240 10SM BKN050 15/09 A3001"))
        #expect(metar.windDirectionDegrees == 200 && metar.windSpeedKnots == 8)
        #expect(metar.visibilityMiles == 10)
        #expect(metar.ceilingFeet == 5_000)
    }

    @Test func windInMetresPerSecondIsConverted() throws {
        let metar = try #require(METARDecoder.decode("METAR UUEE 151830Z 27005MPS 9999 BKN030 12/08 Q1015"))
        #expect(metar.windSpeedKnots == 10)          // 5 m/s is 9.7 kt
    }

    @Test(arguments: ["", "hello", "TAF KSFO 300520Z 3006/3112 27010KT P6SM SCT050", "METAR", "12345"])
    func textThatIsNotAnObservationIsRefused(text: String) {
        #expect(METARDecoder.decode(text) == nil)
    }

    static let categoryCases: [(Double?, Int?, FlightCategory)] = [
        (10, nil, .vfr), (6, 3_500, .vfr), (5, nil, .mvfr), (5.01, nil, .vfr), (3, nil, .mvfr), (2.9, nil, .ifr),
        (1, nil, .ifr), (0.9, nil, .lifr), (nil, 3_000, .mvfr), (nil, 3_001, .vfr), (nil, 999, .ifr), (nil, 500, .ifr),
        (nil, 499, .lifr), (10, 900, .ifr), (nil, nil, .unknown), (0.5, 5_000, .lifr), (2, 400, .lifr),
    ]

    @Test(arguments: METARDecoderTests.categoryCases)
    func flightCategoriesFollowTheFAABoundaries(visibility: Double?, ceiling: Int?, expected: FlightCategory) {
        #expect(FlightCategory.from(visibilityMiles: visibility, ceilingFeet: ceiling) == expected)
    }

    @Test func worseCategoriesCompareHigher() {
        #expect(FlightCategory.vfr < .mvfr && FlightCategory.mvfr < .ifr && FlightCategory.ifr < .lifr)
        #expect(FlightCategory.unknown < .vfr)
    }

    @Test func presentWeatherIsSpelledOut() {
        #expect(METARDecoder.describeWeather("-RA") == "light rain")
        #expect(METARDecoder.describeWeather("+SN") == "heavy snow")
        #expect(METARDecoder.describeWeather("VCSH") == "showers in the vicinity")
        #expect(METARDecoder.describeWeather("-SHRA") == "light rain showers")
        #expect(METARDecoder.describeWeather("+TSRA") == "heavy thunderstorm with rain")
        #expect(METARDecoder.describeWeather("TS") == "thunderstorm")
        #expect(METARDecoder.describeWeather("FZFG") == "freezing fog")
        #expect(METARDecoder.describeWeather("BR") == "mist")
    }
}
