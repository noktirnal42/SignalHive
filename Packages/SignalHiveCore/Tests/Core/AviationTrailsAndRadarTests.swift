import Testing
import Foundation
@testable import SignalHiveCore

private let epoch = Date(timeIntervalSinceReferenceDate: 1_000_000)

private func sample(_ seconds: Double, lat: Double = 40, lon: Double = -100, alt: Int? = 10_000, ground: Bool = false) -> TrackSample {
    TrackSample(time: epoch.addingTimeInterval(seconds), coordinate: GeoCoordinate(latitude: lat, longitude: lon),
                altitudeFeet: alt, onGround: ground)
}

private func close(_ a: RGB8, _ b: RGB8, tolerance: Int = 1) -> Bool {
    abs(Int(a.red) - Int(b.red)) <= tolerance && abs(Int(a.green) - Int(b.green)) <= tolerance
        && abs(Int(a.blue) - Int(b.blue)) <= tolerance
}

struct TrackHistoryTests {
    @Test func theFirstSampleIsKeptAndCrowdingSamplesAreNot() {
        var history = TrackHistory()
        let result1 = history.append(sample(0))
        #expect(result1)
        let result2 = history.append(sample(1, lat: 40.01))
        #expect(!result2)          // closer in time than the 2 s spacing
        let result3 = history.append(sample(3))
        #expect(!result3)                      // same place and height, only 3 s later
        let result4 = history.append(sample(4, lat: 40.001))
        #expect(result4)          // 0.06 NM moved
        #expect(history.samples.count == 2)
    }

    @Test func aClimbOrTheHeartbeatKeepsASample() {
        var history = TrackHistory()
        history.append(sample(0))
        let result5 = history.append(sample(5, alt: 10_150))
        #expect(result5)          // 150 ft up
        let result6 = history.append(sample(10, alt: 10_150))
        #expect(!result6)        // nothing new
        let result7 = history.append(sample(26, alt: 10_150))
        #expect(result7)         // 21 s since the last kept one
    }

    @Test func gainingOrLosingTheAltitudeFixCountsAsAChange() {
        var history = TrackHistory()
        history.append(sample(0, alt: nil))
        let result8 = history.append(sample(5, alt: 5_000))
        #expect(result8)
    }

    @Test func impossiblePositionsAreRejected() {
        var history = TrackHistory()
        let result9 = history.append(sample(0, lat: 95))
        #expect(!result9)
        let result10 = history.append(sample(0, lon: .nan))
        #expect(!result10)
        #expect(history.samples.isEmpty)
    }

    @Test func trimmingDropsSamplesPastTheMaximumAge() {
        var history = TrackHistory()
        history.maximumAge = 60
        for (index, seconds) in [0.0, 30, 100].enumerated() {
            history.append(sample(seconds, lat: 40 + Double(index) * 0.01))
        }
        history.trim(now: epoch.addingTimeInterval(100))
        #expect(history.samples.count == 1)
        history.trim(now: epoch.addingTimeInterval(1_000))
        #expect(history.samples.isEmpty)
    }

    @Test func capacityDropsTheOldest() {
        var history = TrackHistory()
        history.maximumSamples = 5
        for index in 0..<10 {
            history.append(sample(Double(index) * 3, lat: 40 + Double(index) * 0.01))
        }
        #expect(history.samples.count == 5)
        #expect(history.samples.first?.time == epoch.addingTimeInterval(15))
    }

    @Test func altitudeRangeAndLength() {
        var history = TrackHistory()
        history.append(sample(0, lat: 40, alt: 3_000))
        history.append(sample(10, lat: 40.1, alt: 9_000))
        #expect(history.altitudeRange == 3_000...9_000)
        #expect(abs(history.lengthNM - 6.0) < 0.1)
        #expect(TrackHistory().altitudeRange == nil)
        #expect(TrackHistory().lengthNM == 0)
    }
}

struct TrailBuilderTests {
    @Test func aClimbBecomesPiecesThatChangeColor() {
        let a = sample(0, lat: 40, alt: 0)
        let b = sample(30, lat: 40.01, alt: 3_000)
        let pieces = TrailBuilder.segments(from: [a, b], now: epoch.addingTimeInterval(30), window: 600)
        #expect(pieces.count == 5)                               // 3,000 ft in steps of 600
        #expect(close(pieces[0].color, AltitudeColorScale.color(forFeet: 300)))
        #expect(close(pieces[4].color, AltitudeColorScale.color(forFeet: 2_700)))
        #expect(pieces[0].color != pieces[4].color)
        // The pieces join up end to end and cover the whole leg.
        #expect(abs(pieces[0].from.latitude - 40) < 1e-9)
        #expect(abs(pieces[4].to.latitude - 40.01) < 1e-9)
        for index in 1..<pieces.count {
            #expect(abs(pieces[index].from.latitude - pieces[index - 1].to.latitude) < 1e-9)
        }
    }

    @Test func levelFlightIsOnePiece() {
        let pieces = TrailBuilder.segments(from: [sample(0), sample(10, lat: 40.01)], now: epoch.addingTimeInterval(10), window: 600)
        #expect(pieces.count == 1)
        #expect(pieces[0].color == AltitudeColorScale.color(forFeet: 10_000))
    }

    @Test func newerPiecesAreMoreOpaque() {
        let samples = [sample(0), sample(60, lat: 40.01), sample(120, lat: 40.02)]
        let pieces = TrailBuilder.segments(from: samples, now: epoch.addingTimeInterval(120), window: 240, maximumGap: 90)
        #expect(pieces.count == 2)
        #expect(pieces[0].alpha < pieces[1].alpha)
        #expect(pieces[0].age > pieces[1].age)
        #expect(pieces.allSatisfy { $0.alpha >= 0.25 && $0.alpha <= 1 })
    }

    @Test func aGapInTheSignalBreaksTheTrail() {
        let pieces = TrailBuilder.segments(from: [sample(0), sample(120, lat: 40.05)], now: epoch.addingTimeInterval(120), window: 600)
        #expect(pieces.isEmpty)
    }

    @Test func aWildJumpIsNotJoined() {
        // 60 NM in ten seconds would be over 20,000 knots: a bad position, not a flight path.
        let pieces = TrailBuilder.segments(from: [sample(0), sample(10, lat: 41)], now: epoch.addingTimeInterval(10), window: 600)
        #expect(pieces.isEmpty)
    }

    @Test func oldPiecesFallOutOfTheWindow() {
        let samples = [sample(0), sample(10, lat: 40.005), sample(20, lat: 40.01)]
        let recent = TrailBuilder.segments(from: samples, now: epoch.addingTimeInterval(20), window: 5)
        #expect(recent.count == 1)
        let all = TrailBuilder.segments(from: samples, now: epoch.addingTimeInterval(20), window: 600)
        #expect(all.count == 2)
    }

    @Test func groundTracksUseTheGroundColor() {
        let a = sample(0, alt: 0, ground: true)
        let b = sample(10, lat: 40.0005, alt: 0, ground: true)
        let pieces = TrailBuilder.segments(from: [a, b], now: epoch.addingTimeInterval(10), window: 600)
        #expect(pieces.first?.color == AltitudeColorScale.onGroundColor)
    }

    @Test func trailsCrossTheAntimeridianTheShortWay() {
        let a = sample(0, lat: 0, lon: 179.99, alt: 0)
        let b = sample(60, lat: 0, lon: -179.99, alt: 1_500)
        let pieces = TrailBuilder.segments(from: [a, b], now: epoch.addingTimeInterval(60), window: 600)
        #expect(pieces.count == 3)
        for piece in pieces {
            #expect(abs(piece.from.longitude) > 179.9 && abs(piece.to.longitude) > 179.9)
        }
    }

    @Test func tooFewSamplesGiveNoTrail() {
        #expect(TrailBuilder.segments(from: [], now: epoch, window: 60).isEmpty)
        #expect(TrailBuilder.segments(from: [sample(0)], now: epoch, window: 60).isEmpty)
    }
}

// MARK: - Radar

private func radarBlock(scale: Int = 0, north: Int = 2_400, west: Int = -7_200, height: Int = 4, width: Int = 48,
                        product: RadarProduct = .regional, hours: Int = 12, minutes: Int = 0,
                        bins: [UInt8]) -> RadarBlock {
    RadarBlock(product: product, hours: hours, minutes: minutes, scale: scale, northArcminutes: north, westArcminutes: west,
               heightArcminutes: height, widthArcminutes: width, bins: bins)
}

private func expectedPixel(level: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    let color = RadarPalette.color(level: level)
    let alpha = Int(color.alpha)
    return (UInt8(Int(color.red) * alpha / 255), UInt8(Int(color.green) * alpha / 255), UInt8(Int(color.blue) * alpha / 255), color.alpha)
}

struct RadarRasterTests {
    @Test func oneBlockPaintsOnePixelPerBin() throws {
        var bins = [UInt8](repeating: 0, count: 128)
        for column in 0..<32 { bins[column] = 4 }                 // the top row only
        let raster = try #require(RadarRasterizer.raster(from: [radarBlock(bins: bins)]))

        #expect(raster.width == 32)
        #expect(raster.height == 4)
        #expect(abs(raster.north - 40) < 1e-9)
        #expect(abs(raster.west - -120) < 1e-9)
        #expect(abs(raster.east - -119.2) < 1e-9)
        #expect(abs(raster.south - (40 - 4.0 / 60)) < 1e-9)

        let painted = raster.pixel(x: 5, y: 0)
        let expected = expectedPixel(level: 4)
        #expect(painted.red == expected.red && painted.green == expected.green && painted.blue == expected.blue)
        #expect(painted.alpha == expected.alpha)
        #expect(raster.pixel(x: 5, y: 1).alpha == 0)
        #expect(raster.echoPixelCount == 32)
    }

    @Test func finerBlocksReplaceCoarserOnesWhereTheyOverlap() throws {
        let coarse = radarBlock(scale: 1, height: 20, width: 240, bins: [UInt8](repeating: 3, count: 128))
        let fine = radarBlock(scale: 0, bins: [UInt8](repeating: 7, count: 128))
        let raster = try #require(RadarRasterizer.raster(from: [fine, coarse]))

        #expect(raster.width == 160)                              // 240 arcminutes at 1.5 per bin
        #expect(raster.height == 20)
        #expect(raster.pixel(x: 0, y: 0).alpha == RadarPalette.color(level: 7).alpha)
        #expect(raster.pixel(x: 31, y: 3).alpha == RadarPalette.color(level: 7).alpha)
        #expect(raster.pixel(x: 40, y: 0).alpha == RadarPalette.color(level: 3).alpha)
        #expect(raster.pixel(x: 0, y: 10).alpha == RadarPalette.color(level: 3).alpha)
        #expect(raster.pixel(x: 159, y: 19).alpha == RadarPalette.color(level: 3).alpha)
    }

    @Test func weakEchoesAreTransparent() throws {
        let raster = try #require(RadarRasterizer.raster(from: [radarBlock(bins: [UInt8](repeating: 1, count: 128))]))
        #expect(raster.echoPixelCount == 0)
    }

    @Test func nothingToPaintGivesNoRaster() {
        #expect(RadarRasterizer.raster(from: []) == nil)
        #expect(RadarRasterizer.raster(from: [radarBlock(bins: [])]) == nil)
        #expect(RadarRasterizer.raster(from: [radarBlock(height: 0, bins: [UInt8](repeating: 3, count: 128))]) == nil)
    }

    @Test func hugeAreasAreScaledDown() throws {
        // 40 degrees across at the finest scale would be 1,600 pixels; ask for at most 256.
        let blocks = (0..<50).map { radarBlock(west: -7_200 + $0 * 48, bins: [UInt8](repeating: 5, count: 128)) }
        let raster = try #require(RadarRasterizer.raster(from: blocks, maxDimension: 256))
        #expect(raster.width <= 256 && raster.height <= 256)
        #expect(raster.echoPixelCount > 0)
    }

    @Test func rowsAreSpacedInMercatorNotLatitude() throws {
        // A block near 60 degrees north: its 4 rows are unequal in latitude terms only slightly, but the raster's
        // top and bottom edges must be exactly the block's own edges.
        let block = radarBlock(north: 3_600, bins: [UInt8](repeating: 4, count: 128))
        let raster = try #require(RadarRasterizer.raster(from: [block]))
        #expect(abs(raster.north - 60) < 1e-9)
        #expect(raster.echoPixelCount == raster.width * raster.height)
    }

    @Test func everyLevelHasALabelAndTheVisibleOnesHaveColor() {
        #expect(RadarPalette.levelLabels.count == 8)
        for level in RadarPalette.legendLevels { #expect(RadarPalette.color(level: level).alpha > 0) }
        #expect(RadarPalette.color(level: 0).alpha == 0)
        #expect(RadarPalette.color(level: 1).alpha == 0)
        #expect(RadarPalette.label(level: 12) == "Unknown")
    }
}

struct RadarMosaicTests {
    private func bins(_ level: UInt8) -> [UInt8] { [UInt8](repeating: level, count: 128) }

    @Test func aNewerBlockAtTheSamePlaceReplacesTheOldOne() {
        var mosaic = RadarMosaic(product: .regional)
        mosaic.add(radarBlock(bins: bins(2)), at: epoch)
        mosaic.add(radarBlock(bins: bins(5)), at: epoch.addingTimeInterval(60))
        #expect(mosaic.blockCount == 1)
        #expect(mosaic.blocks.first?.peakLevel == 5)
        #expect(mosaic.revision == 2)
    }

    @Test func blocksAtOtherPlacesAreKept() {
        var mosaic = RadarMosaic(product: .regional)
        mosaic.add(radarBlock(west: -7_200, bins: bins(2)), at: epoch)
        mosaic.add(radarBlock(west: -7_152, bins: bins(2)), at: epoch)
        mosaic.add(radarBlock(scale: 1, bins: bins(2)), at: epoch)
        #expect(mosaic.blockCount == 3)
    }

    @Test func blocksOfAnotherProductAreIgnored() {
        var mosaic = RadarMosaic(product: .regional)
        mosaic.add(radarBlock(product: .conus, bins: bins(3)), at: epoch)
        #expect(mosaic.isEmpty)
    }

    @Test func oldBlocksExpire() {
        var mosaic = RadarMosaic(product: .regional)
        mosaic.add(radarBlock(west: -7_200, bins: bins(3)), at: epoch)
        mosaic.add(radarBlock(west: -7_152, bins: bins(3)), at: epoch.addingTimeInterval(100))
        mosaic.expire(olderThan: 60, now: epoch.addingTimeInterval(120))
        #expect(mosaic.blockCount == 1)
        mosaic.expire(olderThan: 60, now: epoch.addingTimeInterval(1_000))
        #expect(mosaic.isEmpty)
    }

    @Test func boundsAndObservationTimeDescribeTheMosaic() throws {
        var mosaic = RadarMosaic(product: .regional)
        #expect(mosaic.bounds == nil)
        #expect(mosaic.latestObservationLabel == nil)
        mosaic.add(radarBlock(hours: 9, minutes: 5, bins: bins(3)), at: epoch)
        let bounds = try #require(mosaic.bounds)
        #expect(abs(bounds.north - 40) < 1e-9 && abs(bounds.west - -120) < 1e-9)
        #expect(mosaic.latestObservationLabel == "09:05Z")
        #expect(mosaic.raster() != nil)
    }
}
