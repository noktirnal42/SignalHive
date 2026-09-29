import Foundation

// MARK: - Shared AFSK Demodulator (configurable for AIS, NOAA SAME, etc.)

public final class AFSKDemodulator: @unchecked Sendable {
    public let sampleRate: Double
    public let baudRate: Double
    public let markFreq: Double
    public let spaceFreq: Double

    private let markFilter: GoertzelFilter
    private let spaceFilter: GoertzelFilter

    private var symbolPhase: Double = 0
    private var symbolAccumulator = 0.0
    private var samplesPerSymbol: Double

    // Timing recovery
    private var lastMarkEnergy: Float = 0
    private var lastSpaceEnergy: Float = 0
    private var symbolHistory: [Float] = []

    // Bit decoding
    private var bitBuffer: [UInt8] = []
    private var syncBuffer: [UInt8] = []
    private var byteBuffer: [UInt8] = []
    private var bitCount = 0

    // Message state
    private var inMessage = false
    private var headerComplete = false
    private var headerBuffer = ""
    private var messageBuffer = ""
    private var preambleCount = 0

    public var onBit: ((UInt8) -> Void)?
    public var onByte: ((UInt8) -> Void)?

    public init(
        sampleRate: Double = 22050,
        baudRate: Double = 520.83,
        markFreq: Double = 2083.33,
        spaceFreq: Double = 1562.5
    ) {
        self.sampleRate = sampleRate
        self.baudRate = baudRate
        self.markFreq = markFreq
        self.spaceFreq = spaceFreq
        self.samplesPerSymbol = sampleRate / baudRate
        self.markFilter = GoertzelFilter(sampleRate: sampleRate, targetFreq: markFreq)
        self.spaceFilter = GoertzelFilter(sampleRate: sampleRate, targetFreq: spaceFreq)
    }

    public func reset() {
        markFilter.reset()
        spaceFilter.reset()
        symbolPhase = 0
        symbolAccumulator = 0
        lastMarkEnergy = 0
        lastSpaceEnergy = 0
        symbolHistory.removeAll()
        bitBuffer.removeAll()
        syncBuffer.removeAll()
        byteBuffer.removeAll()
        bitCount = 0
    }

    public func process(samples: [Float]) {
        for sample in samples {
            processSample(sample)
        }
    }

    private func processSample(_ sample: Float) {
        let markEnergy = markFilter.process(sample)
        let spaceEnergy = spaceFilter.process(sample)

        symbolAccumulator += 1.0 / samplesPerSymbol
        if symbolAccumulator >= 1.0 {
            symbolAccumulator -= 1.0
            processSymbolBoundary(markEnergy: markEnergy, spaceEnergy: spaceEnergy)
        }
    }

    private func processSymbolBoundary(markEnergy: Float, spaceEnergy: Float) {
        let bit: UInt8 = markEnergy > spaceEnergy ? 1 : 0
        onBit?(bit)

        if byteBuffer.isEmpty && !syncBuffer.isEmpty && syncBuffer.count >= 16 {
            let syncBits = syncBuffer.map { String($0) }.joined()
            if syncBits.hasSuffix("10101011") { // 0xAB preamble
                // Found sync - start byte framing
            }
        }

        if byteBuffer.isEmpty {
            syncBuffer.append(bit)
            if syncBuffer.count > 16 { syncBuffer.removeFirst(syncBuffer.count - 16) }
        } else {
            bitBuffer.append(bit)
            bitCount += 1
            if bitCount == 8 {
                let byte = bitBuffer.reduce(0) { ($0 << 1) | Int($1) }
                byteBuffer.append(UInt8(byte))
                onByte?(UInt8(byte))
                bitBuffer.removeAll()
                bitCount = 0
            }
        }
    }
}