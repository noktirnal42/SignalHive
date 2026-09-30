import Testing
import Foundation
@testable import SignalHiveCore

struct FFTProcessorTests {
    static let sampleRate = 2_048_000.0
    static let size = 4096                       // bin width = 2_048_000 / 4096 = 500 Hz

    /// A complex tone `offsetHz` away from the tuner centre.
    static func tone(_ offsetHz: Double, amplitude: Float = 0.5) -> [ComplexFloat] {
        (0..<size).map { n in
            let phase = 2 * Double.pi * offsetHz * Double(n) / sampleRate
            return ComplexFloat(i: Float(cos(phase)) * amplitude, q: Float(sin(phase)) * amplitude)
        }
    }

    static func peakIndex(_ spectrum: [Float]) -> Int {
        spectrum.indices.max { spectrum[$0] < spectrum[$1] }!
    }

    @Test func aComplexSignalGivesTheWholeBandNotJustTheUpperHalf() {
        let output = FFTProcessor(fftSize: Self.size).process(samples: Self.tone(0))
        #expect(output.averaged.count == Self.size)
        #expect(output.peakHold.count == Self.size)
    }

    @Test(arguments: [
        (0.0, 2048), (250_000.0, 2548), (-250_000.0, 1548), (900_000.0, 3848), (-900_000.0, 248),
    ])
    func aToneLandsInTheBinForItsOffsetFromTheCentre(offsetHz: Double, expectedBin: Int) {
        // Centre-shifted layout: bin n/2 is the tuner centre, bin 0 is -fs/2, the last bin is +fs/2.
        let spectrum = FFTProcessor(fftSize: Self.size).process(samples: Self.tone(offsetHz)).averaged
        #expect(abs(Self.peakIndex(spectrum) - expectedBin) <= 1)
    }

    @Test func signalsBelowTheCentreAreAsVisibleAsSignalsAbove() {
        let above = FFTProcessor(fftSize: Self.size).process(samples: Self.tone(250_000)).averaged
        let below = FFTProcessor(fftSize: Self.size).process(samples: Self.tone(-250_000)).averaged
        #expect(abs(above.max()! - below.max()!) < 0.5)
        #expect(below.max()! > below.sorted()[below.count / 2] + 60)    // far above the median (noise) level
    }

    @Test func frequencyFinderReportsTheRightFrequenciesForSignalsOnBothSidesOfTheCentre() {
        let centre = 155_000_000.0
        let mixed = zip(Self.tone(300_000), Self.tone(-400_000)).map { ComplexFloat(i: $0.i + $1.i, q: $0.q + $1.q) }
        let spectrum = FFTProcessor(fftSize: Self.size).process(samples: mixed).averaged
        let found = FrequencyFinder.find(magnitudes: spectrum, centerFrequencyHz: centre, sampleRateHz: Self.sampleRate)
        let frequencies = found.map(\.frequencyHz).sorted()
        #expect(frequencies.count == 2)
        guard frequencies.count == 2 else { return }
        #expect(abs(frequencies[0] - 154_600_000) < 1_000)
        #expect(abs(frequencies[1] - 155_300_000) < 1_000)
    }

    @Test func binToFrequencyMatchesTheCentreShiftedLayout() {
        let processor = FFTProcessor(fftSize: Self.size)
        let centre = 155_000_000.0
        func frequency(_ bin: Int) -> Double {
            processor.binToFrequency(bin: bin, sampleRate: Self.sampleRate, centerFrequency: centre)
        }
        #expect(frequency(2048) == centre)                        // middle bin is the tuner centre
        #expect(frequency(2548) == centre + 250_000)
        #expect(frequency(1548) == centre - 250_000)
        #expect(frequency(0) == centre - Self.sampleRate / 2)     // lowest edge of the band
    }
}
