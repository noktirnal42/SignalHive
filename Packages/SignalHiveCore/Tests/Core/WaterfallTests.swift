import Testing
@testable import SignalHiveCore

struct WaterfallTests {
    static let scale = SpectrumScale(minDB: -100, maxDB: -50)

    private func luma(_ p: WaterfallBuffer.Pixel) -> Double {
        0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)
    }

    @Test func thePaletteGetsBrighterAsSignalsGetStronger() {
        var previous = -1.0
        for step in 0...64 {
            let color = WaterfallPalette.color(Float(step) / 64)
            let brightness = 0.2126 * Double(color.r) + 0.7152 * Double(color.g) + 0.0722 * Double(color.b)
            #expect(brightness >= previous - 1.0)          // monotone, allowing 8-bit rounding
            previous = brightness
        }
        #expect(WaterfallPalette.color(1).g > 200)         // the strongest signals read as near white/yellow
        #expect(WaterfallPalette.color(0).r < 20)          // noise floor is near black
    }

    @Test func theBufferHoldsOneRGBAPixelPerCell() {
        let buffer = WaterfallBuffer(width: 8, height: 4)
        #expect(buffer.pixels.count == 8 * 4 * 4)
    }

    @Test func theNewestRowIsAtTheTopAndOlderRowsScrollDown() {
        var buffer = WaterfallBuffer(width: 8, height: 4)
        buffer.push(row: [Float](repeating: -50, count: 8), scale: Self.scale)     // strong, pushed first
        buffer.push(row: [Float](repeating: -100, count: 8), scale: Self.scale)    // quiet, newest
        #expect(luma(buffer.pixel(x: 0, y: 0)) < luma(buffer.pixel(x: 0, y: 1)))   // quiet on top, strong below it
    }

    @Test func rowsThatScrollOffTheBottomAreDropped() {
        var buffer = WaterfallBuffer(width: 2, height: 3)
        for _ in 0..<10 { buffer.push(row: [-50, -50], scale: Self.scale) }
        buffer.push(row: [-100, -100], scale: Self.scale)
        #expect(buffer.pixels.count == 2 * 3 * 4)                                   // fixed size, never grows
        #expect(luma(buffer.pixel(x: 0, y: 0)) < luma(buffer.pixel(x: 0, y: 2)))
    }

    @Test func aNarrowSignalLandsInTheColumnForItsFrequency() {
        var buffer = WaterfallBuffer(width: 16, height: 2)
        var row = [Float](repeating: -100, count: 64)
        row[40] = -50                                            // bin 40 of 64  ->  column 10 of 16
        buffer.push(row: row, scale: Self.scale)
        let hot = luma(buffer.pixel(x: 10, y: 0))
        #expect(hot > luma(buffer.pixel(x: 5, y: 0)) + 100)
        #expect(hot > luma(buffer.pixel(x: 14, y: 0)) + 100)
    }

    @Test func aHugeSpectrumIsReducedWithoutLosingAOneBinCarrier() {
        var buffer = WaterfallBuffer(width: 256, height: 2)
        var row = [Float](repeating: -100, count: 16384)
        row[9000] = -50
        buffer.push(row: row, scale: Self.scale)
        let column = 9000 * 256 / 16384
        #expect(luma(buffer.pixel(x: column, y: 0)) > 200)
    }

    @Test func aShortSpectrumIsStretchedSmoothlyAcrossTheWidth() {
        var buffer = WaterfallBuffer(width: 16, height: 1)
        buffer.push(row: [-100, -50, -100, -100], scale: Self.scale)
        let values = (0..<16).map { luma(buffer.pixel(x: $0, y: 0)) }
        let brightest = values.indices.max { values[$0] < values[$1] }!
        #expect((3...6).contains(brightest))                     // around the second of four bins
        #expect(Set(values.map { Int($0) }).count > 4)          // a gradient, not four hard blocks
    }

    @Test func emptyRowsChangeNothing() {
        var buffer = WaterfallBuffer(width: 4, height: 2)
        let before = buffer.pixels
        buffer.push(row: [], scale: Self.scale)
        #expect(buffer.pixels == before)
    }
}

struct FrameThrottleTests {
    @Test func framesArriveNoFasterThanTheMinimumInterval() {
        var throttle = FrameThrottle(minimumInterval: 0.05)
        let first = throttle.shouldEmit(at: 10.00)
        let tooSoon = throttle.shouldEmit(at: 10.01)
        let almost = throttle.shouldEmit(at: 10.049)
        let due = throttle.shouldEmit(at: 10.06)
        let tooSoonAgain = throttle.shouldEmit(at: 10.07)
        #expect(first)
        #expect(!tooSoon)
        #expect(!almost)
        #expect(due)
        #expect(!tooSoonAgain)
    }

    @Test func aClockThatJumpsBackwardsDoesNotFreezeTheDisplay() {
        var throttle = FrameThrottle(minimumInterval: 0.05)
        let first = throttle.shouldEmit(at: 100)
        let afterJump = throttle.shouldEmit(at: 5)
        #expect(first)
        #expect(afterJump)
    }
}

struct SpectrumScaleSmoothingTests {
    @Test func theScaleMovesTowardsANewRangeGradually() {
        let old = SpectrumScale(minDB: -100, maxDB: -60)
        let new = SpectrumScale(minDB: -60, maxDB: -20)
        let blended = old.blended(toward: new, alpha: 0.25)
        #expect(blended.minDB == -90)
        #expect(blended.maxDB == -50)
        #expect(old.blended(toward: new, alpha: 1) == new)
        #expect(old.blended(toward: new, alpha: 0) == old)
    }
}
