#if canImport(RTLSDRDecoders)
import Foundation
import RTLSDRDecoders

// Note: SignalHiveCore has its own `UATFrame` (for the older first-pass decoder), so the driver's type is always
// written `RTLSDRDecoders.UATFrame` in this file.

/// Turns 978 MHz UAT frames into aviation updates: aircraft ADS-B, TIS-B/ADS-R traffic relayed by ground stations, and
/// the FIS-B products those stations uplink (NEXRAD radar blocks, text reports). It holds no device, so tests can feed it
/// recorded frames in dump978's text format.
final class UATPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let demodulator = UATDemodulator()
    private var pendingAircraft: [UInt32: AircraftReport] = [:]
    private var pendingOther: [AviationUpdate] = []
    private var blocksSeen = 0
    private var lastBlockAt: Date?

    /// What has been heard, by kind.
    struct Counters: Equatable {
        var frames = 0
        var downlinks = 0
        var uplinks = 0
        var repairedFrames = 0
        var radarBlocks = 0
        var textReports = 0
        /// FIS-B products that were received but are not shown (graphical AIRMETs, lightning, status ...), by name.
        var otherProducts: [String: Int] = [:]
    }

    private var counters = Counters()

    /// Demodulates one block of interleaved unsigned 8-bit I/Q at 2.083334 MS/s. Called from the device's thread.
    func process(_ block: UnsafeBufferPointer<UInt8>, now: Date = Date()) {
        let frames = demodulator.process(block)
        lock.lock()
        defer { lock.unlock() }
        blocksSeen += 1
        lastBlockAt = now
        for frame in frames { ingestLocked(frame, now: now) }
    }

    /// Takes one frame in dump978's text format (`-hex;` for aircraft, `+hex;` for ground stations, optionally `rs=N;`),
    /// from a recording or a network feed. Returns false for anything that is not a frame.
    @discardableResult
    func ingest(dump978Line line: String, now: Date) -> Bool {
        guard let frame = RTLSDRDecoders.UATFrame(dump978Line: Substring(line)) else { return false }
        lock.lock()
        defer { lock.unlock() }
        ingestLocked(frame, now: now)
        return true
    }

    func drain() -> [AviationUpdate] {
        lock.lock()
        defer { lock.unlock() }
        let aircraft = pendingAircraft.values.sorted { $0.address < $1.address }.map { AviationUpdate.aircraft($0) }
        let other = pendingOther
        pendingAircraft.removeAll(keepingCapacity: true)
        pendingOther.removeAll(keepingCapacity: true)
        return other + aircraft
    }

    var currentCounters: Counters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    var health: (blocks: Int, frames: Int, lastBlockAt: Date?) {
        lock.lock()
        defer { lock.unlock() }
        return (blocksSeen, counters.frames, lastBlockAt)
    }

    // MARK: Frames

    private func ingestLocked(_ frame: RTLSDRDecoders.UATFrame, now: Date) {
        counters.frames += 1
        if frame.correctedSymbols > 0 { counters.repairedFrames += 1 }
        switch frame.kind {
        case .downlink:
            counters.downlinks += 1
            guard frame.payload.count >= UAT.basicPayloadBytes else { return }
            let message = UATADSBMessage(payload: frame.payload)
            if let report = Self.report(for: message, now: now) {
                if var existing = pendingAircraft[report.address] {
                    existing.merge(report)
                    pendingAircraft[report.address] = existing
                } else {
                    pendingAircraft[report.address] = report
                }
            }
        case .uplink:
            counters.uplinks += 1
            guard frame.payload.count >= UAT.uplinkPayloadBytes else { return }
            ingestUplink(UATUplinkMessage(payload: frame.payload), now: now)
        }
    }

    private func ingestUplink(_ uplink: UATUplinkMessage, now: Date) {
        let position = GeoCoordinate(latitude: uplink.latitude, longitude: uplink.longitude)
        // The "position valid" flag is often clear on stations whose position is plausible anyway (dump978 notes this),
        // so a station is placed whenever its coordinates make sense.
        if position.isValid, !(position.latitude == 0 && position.longitude == 0) {
            pendingOther.append(.groundStation(GroundStation(coordinate: position, slotID: uplink.slotID, heard: now)))
        }
        for product in (uplink.informationFrames ?? []).compactMap(\.fisb) {
            let blocks = NEXRADBlock.blocks(in: product)
            if !blocks.isEmpty {
                for block in blocks {
                    pendingOther.append(.radar(Self.radarBlock(from: block), receivedAt: now))
                }
                counters.radarBlocks += blocks.count
            } else if product.productID == 413 {
                for report in product.reports {
                    pendingOther.append(.message(AviationMessage.fisbReport(report, productID: 413, at: now)))
                    counters.textReports += 1
                }
            } else {
                counters.otherProducts[product.productName, default: 0] += 1
            }
        }
    }

    // MARK: Conversions

    /// The part of an aircraft's story one UAT ADS-B message tells.
    static func report(for message: UATADSBMessage, now: Date) -> AircraftReport? {
        let source: AircraftSource
        switch message.addressQualifier {
        case .tisbICAO, .tisbTrackFile: source = .relayed
        default: source = .uat
        }
        var report = AircraftReport(address: message.address, source: source, time: now)

        if let vector = message.stateVector {
            if let latitude = vector.latitude, let longitude = vector.longitude {
                let position = GeoCoordinate(latitude: latitude, longitude: longitude)
                if position.isValid { report.coordinate = position }
            }
            // Barometric altitude is what pilots and the rest of the picture use; the geometric one is a fallback.
            if let altitude = vector.altitude {
                if altitude.type == .barometric {
                    report.altitudeFeet = altitude.feet
                } else if let secondary = message.secondaryAltitude, secondary.type == .barometric {
                    report.altitudeFeet = secondary.feet
                } else {
                    report.altitudeFeet = altitude.feet
                }
            }
            report.groundSpeedKnots = vector.speedKnots.map(Double.init)
            report.trackDegrees = vector.track.map { Double($0.degrees) }
            report.verticalRateFPM = vector.verticalRate?.feetPerMinute
            report.onGround = vector.airGround == .onGround
        }
        if let status = message.modeStatus {
            report.aircraftClass = AircraftClass.fromUAT(emitterCategory: status.emitterCategory)
            if let text = status.callsign {
                if status.callsignIsSquawk { report.squawk = text } else { report.callsign = text }
            }
            report.emergency = ADSBEmergencyState(rawValue: status.emergency)
        }
        return report
    }

    /// The driver's block, with longitudes in -180 ... 180 instead of 0 ... 360 (in arcminutes).
    static func radarBlock(from block: NEXRADBlock) -> RadarBlock {
        RadarBlock(product: block.product == .regional ? .regional : .conus,
                   hours: block.hours, minutes: block.minutes, scale: block.scaleFactor,
                   northArcminutes: block.northArcminutes,
                   westArcminutes: block.westArcminutes >= 10_800 ? block.westArcminutes - 21_600 : block.westArcminutes,
                   heightArcminutes: block.heightArcminutes, widthArcminutes: block.widthArcminutes, bins: block.bins)
    }
}

/// Receives 978 MHz UAT from an SDR that delivers unsigned 8-bit I/Q: aircraft ADS-B (general aviation), TIS-B traffic,
/// and FIS-B weather (NEXRAD radar, text reports) from ground stations. United States only.
public actor UAT978Receiver {
    private let device: any SDRDevice
    private let pipeline = UATPipeline()
    private let gainDB: Double
    private var flushTask: Task<Void, Never>?
    private var running = false

    public init(device: any SDRDevice, gainDB: Double = 49.6) {
        self.device = device
        self.gainDB = gainDB
    }

    public var isRunning: Bool { running }

    public func start(onUpdates: @escaping @Sendable ([AviationUpdate]) -> Void) async throws {
        guard !running else { return }
        try await device.open()
        do {
            try await device.configure(frequency: Double(UAT.frequency), sampleRate: Double(UAT.sampleRate), gain: gainDB)
            let pipeline = self.pipeline
            try await device.startStreaming { buffer, _ in pipeline.process(buffer) }
        } catch {
            await device.close()
            throw error
        }
        running = true
        let pipeline = self.pipeline
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let updates = pipeline.drain()
                if !updates.isEmpty { onUpdates(updates) }
            }
        }
    }

    public func stop() async {
        flushTask?.cancel()
        flushTask = nil
        guard running else { return }
        running = false
        await device.stopStreaming()
        await device.close()
    }

    public func health() -> ReceiverHealth {
        let snapshot = pipeline.health
        return ReceiverHealth(blocks: snapshot.blocks, frames: snapshot.frames,
                              secondsSinceLastBlock: snapshot.lastBlockAt.map { Date().timeIntervalSince($0) })
    }

    /// FIS-B products heard that the app does not show, by name, and how often.
    public func otherProductsHeard() -> [String: Int] {
        pipeline.currentCounters.otherProducts
    }
}
#endif
