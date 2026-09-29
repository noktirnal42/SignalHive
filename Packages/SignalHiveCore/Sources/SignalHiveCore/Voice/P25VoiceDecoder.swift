import Foundation
import CMbelib

// MARK: - P25 Phase 1 voice decoder (experimental)
//
// Full decode chain ported from the documented DSD/dsd-neo reference:
//   IQ → FM demod → decimate → symbol recovery → 4-level slicing →
//   frame sync (24-dibit P25 sync) → NID (32 dibits) → LDU voice frames:
//   9 × IMBE (72 dibits + status-symbol skips) interleaved with hex words
//   (10 dibits each, discarded in this simple path — link control only) →
//   mbelib ECC/deinterleave → mbe_processImbe4400Dataf → 8 kHz audio.
//
// Symbol mapping follows dsd-neo: dibit 1 = +3, 3 = -3, 2 = +1, 0 = -1.
// The 180° phase ambiguity is handled by checking both the sync and its
// inversion; dibits are inverted when the inverted sync matched.

public final class P25VoiceDecoder: @unchecked Sendable {

    // MARK: Interleave tables (dsd-neo p25p1_const.h)

    static let iW: [Int] = [0, 2, 4, 1, 3, 5, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6,
                            0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 5, 1, 3, 6, 0, 2, 5, 1, 3, 6,
                            0, 2, 5, 1, 3, 7, 0, 2, 5, 1, 3, 7, 0, 2, 5, 1, 4, 7, 0, 3, 5, 2, 4, 7]
    static let iX: [Int] = [22, 20, 10, 20, 18, 0, 20, 18, 8, 18, 16, 13, 18, 16, 6, 16, 14, 11, 16, 14, 4, 14, 12, 9,
                            14, 12, 2, 12, 10, 7, 12, 10, 0, 10, 8, 5, 10, 8, 13, 8, 6, 3, 8, 6, 11, 6, 4, 1,
                            6, 4, 9, 4, 2, 6, 4, 2, 7, 2, 0, 4, 2, 0, 5, 0, 13, 2, 0, 21, 3, 21, 11, 0]
    static let iY: [Int] = [1, 3, 5, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 4,
                            1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 5, 1, 3, 6, 0, 2, 5, 1, 3, 6, 0, 2, 5,
                            1, 3, 6, 0, 2, 5, 1, 3, 7, 0, 2, 5, 1, 4, 7, 0, 3, 5, 2, 4, 7, 1, 3, 5]
    static let iZ: [Int] = [21, 19, 1, 21, 19, 9, 19, 17, 14, 19, 17, 7, 17, 15, 12, 17, 15, 5, 15, 13, 10, 15, 13, 3,
                            13, 11, 8, 13, 11, 1, 11, 9, 6, 11, 9, 14, 9, 7, 4, 9, 7, 12, 7, 5, 2, 7, 5, 10,
                            5, 3, 0, 5, 3, 8, 3, 1, 5, 3, 1, 6, 1, 14, 3, 1, 22, 4, 22, 12, 1, 22, 20, 2]

    static let syncPattern = "111113113311333313133333"
    static let syncPatternInv = "333331331133111131311111"

    // MARK: State

    private let decimation = 64 // 2.048 MS/s → 32 kHz baseband (6.67 samples/symbol)
    private var decimSum: Float = 0
    private var decimCount = 0

    private var symbolPhase: Float = 0
    private let samplesPerSymbol: Float = 32_000.0 / 4800.0 // 6.667

    private var symbolWindow: [Int] = []       // last 24 sliced symbols
    private var dibitQueue: [Int] = []         // pending dibits for frame processing
    private var locked = false
    private var inverted = false
    private var statusCount = 21
    private var lduStep = 0                    // position within the LDU symbol sequence

    private var curMP = mbe_parms()
    private var prevMP = mbe_parms()
    private var prevMPEnhanced = mbe_parms()
    private var mbeInitialized = false

    public private(set) var synced = false
    public private(set) var frameErrors = 0
    public private(set) var framesDecoded = 0

    // Type for C interop with mbelib's char[8][23] arrays
    private typealias IMBEFrRow = (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)

    public init() {}

    // MARK: Public API

    /// Feed one raw IQ block (uint8 interleaved). Returns decoded audio (8 kHz mono).
    public func decode(iqBlock: [UInt8]) -> [Float] {
        var audioOut: [Float] = []
        let baseband = decimate(demodulate(iqBlock))
        for sample in baseband {
            audioOut.append(contentsOf: processSymbol(sample))
        }
        return audioOut
    }

    public func reset() {
        symbolPhase = 0
        decimSum = 0
        decimCount = 0
        symbolWindow.removeAll()
        dibitQueue.removeAll()
        locked = false
        inverted = false
        statusCount = 21
        lduStep = 0
        synced = false
        frameErrors = 0
        framesDecoded = 0
        mbeInitialized = false
    }

    // MARK: FM demod + decimate

    private func demodulate(_ iq: [UInt8]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(iq.count / 2)
        var prevI: Float = 0
        var prevQ: Float = 0
        var first = true
        var i = 0
        while i + 1 < iq.count {
            let ib = (Float(iq[i]) - 127.5) / 127.5
            let qb = (Float(iq[i + 1]) - 127.5) / 127.5
            i += 2
            if first {
                prevI = ib
                prevQ = qb
                first = false
                continue
            }
            // phase delta via conjugate product
            let real = ib * prevI + qb * prevQ
            let imag = qb * prevI - ib * prevQ
            let angle = atan2f(imag, real)
            out.append(angle * (48_000.0 / Float.pi) / 3.0) // scaled deviation
            prevI = ib
            prevQ = qb
        }
        return out
    }

    private func decimate(_ input: [Float]) -> [Float] {
        var out: [Float] = []
        for sample in input {
            decimSum += sample
            decimCount += 1
            if decimCount >= decimation {
                out.append(decimSum / Float(decimation))
                decimSum = 0
                decimCount = 0
            }
        }
        return out
    }

    // MARK: Symbol recovery + slicing

    private func processSymbol(_ s: Float) -> [Float] {
        symbolPhase += 1
        guard symbolPhase >= samplesPerSymbol else { return [] }
        symbolPhase -= samplesPerSymbol

        let dibit = slice(s)
        return consumeDibit(dibit)
    }

    private var deviationEstimate: Float = 1.0

    private func slice(_ s: Float) -> Int {
        // Running deviation estimate for normalization
        let a = abs(s)
        if a > deviationEstimate {
            deviationEstimate = min(a, deviationEstimate * 1.05 + 0.01)
        } else {
            deviationEstimate = max(0.5, deviationEstimate * 0.999)
        }
        let norm = s / deviationEstimate
        if norm > 0.5 { return 1 }        // +3
        if norm < -0.5 { return 3 }       // -3
        return norm > 0 ? 2 : 0           // ±1
    }

    // MARK: Dibit stream → frames

    private func consumeDibit(_ dibit: Int) -> [Float] {
        if locked {
            dibitQueue.append(dibit)
            return processFrameQueue()
        } else {
            // Search for sync in the sliding window
            symbolWindow.append(dibit)
            if symbolWindow.count > 24 { symbolWindow.removeFirst(symbolWindow.count - 24) }
            guard symbolWindow.count == 24 else { return [] }
            let str = String(symbolWindow.map { Character(UnicodeScalar(UInt8($0) + 48)) })
            if str == Self.syncPattern {
                locked = true
                inverted = false
                synced = true
                beginFrame()
            } else if str == Self.syncPatternInv {
                locked = true
                inverted = true
                synced = true
                beginFrame()
            }
            return []
        }
    }

    private func beginFrame() {
        symbolWindow.removeAll()
        dibitQueue.removeAll()
        // NID: 32 dibits (one status symbol inside, consumed by the cadence below)
        statusCount = 24
        readDibits(32, withStatusSkips: true)
        statusCount = 21
        lduStep = 0
        if !mbeInitialized {
            mbe_initMbeParms(&curMP, &prevMP, &prevMPEnhanced)
            mbeInitialized = true
        }
    }

    private func readDibits(_ count: Int, withStatusSkips: Bool) {
        var read = 0
        while read < count, !dibitQueue.isEmpty {
            if withStatusSkips {
                if statusCount == 35 {
                    _ = dibitQueue.removeFirst() // status symbol
                    statusCount = 1
                    continue
                }
                statusCount += 1
            }
            _ = dibitQueue.removeFirst()
            read += 1
        }
        // If the queue ran dry, the remaining dibits arrive with future IQ blocks;
        // processFrameQueue resumes when enough accumulate.
    }

    private func processFrameQueue() -> [Float] {
        // LDU symbol sequence: 9 IMBE frames, hex words (10 dibits each) after IMBE 2/3/4/5/6/7
        // We decode voice when a full IMBE frame (72 dibits + status skips) is buffered.
        // Simplification: hex-word dibits are consumed (discarded) at the documented
        // positions so the status-symbol cadence stays aligned with the stream.
        guard dibitQueue.count >= 74 else { return [] }

        let step = lduStep
        // Hex groups at steps 2,4,6,8,10,12 (after IMBE 2,3,4,5,6,7)
        if step >= 2, step <= 12, step % 2 == 0 {
            // Hex group position: 4 hex words × 10 dibits
            readDibits(40, withStatusSkips: true)
            lduStep += 1
            return []
        }

        // IMBE frame: extract 72 dibits into the interleave array
        var imbeFrFlat = [CChar](repeating: 0, count: 184)
        var consumed = 0
        for j in 0..<72 {
            if statusCount == 35 {
                _ = dibitQueue.removeFirst() // status symbol
                statusCount = 1
                consumed += 1
                continue
            }
            statusCount += 1
            consumed += 1
            guard !dibitQueue.isEmpty else { return [] }
            let raw = dibitQueue.removeFirst()
            consumed += 1
            let d = inverted ? invertDibit(raw) : raw
            let bit1 = (d >> 1) & 1
            let bit0 = d & 1
            let w = Self.iW[j], x = Self.iX[j]
            let y = Self.iY[j], z = Self.iZ[j]
            // Flat layout: row * 23 + col
            imbeFrFlat[w * 23 + x] = CChar(bit1)
            imbeFrFlat[y * 23 + z] = CChar(bit0)
        }
        _ = consumed

        lduStep += 1
        if lduStep > 14 { lduStep = 0 } // LDU complete (9 IMBE + 6 hex groups)

        // mbelib decode chain
        return imbeFrFlat.withUnsafeMutableBytes { rawBytes in
            let base = rawBytes.bindMemory(to: CChar.self).baseAddress!
            let frPtr = UnsafeMutableRawPointer(base).assumingMemoryBound(to: IMBEFrRow.self)
            var errs: CInt = 0
            var errs2: CInt = 0
            var errStr = [CChar](repeating: 0, count: 256)
            var imbeD = [CChar](repeating: 0, count: 88)

            errs = mbe_eccImbe7200x4400C0(frPtr)
            mbe_demodulateImbe7200x4400Data(frPtr)
            errs2 = mbe_eccImbe7200x4400Data(frPtr, &imbeD)

            frameErrors += Int(errs2)
            framesDecoded += 1

            var audio = [Float](repeating: 0, count: 160)
            mbe_processImbe4400Dataf(&audio, &errs, &errs2, &errStr, &imbeD, &curMP, &prevMP, &prevMPEnhanced, 1)
            return audio
        }
    }

    private func invertDibit(_ d: Int) -> Int {
        switch d {
        case 1: return 3
        case 3: return 1
        case 0: return 2
        case 2: return 0
        default: return d
        }
    }
}