#if canImport(RTLSDRDecoders)
import Foundation
import RTLSDRDecoders

/// Turns 1090 MHz samples into aviation reports. It holds no device, so tests can feed it decoded frames.
///
/// `SwiftRTLSDR`'s `AircraftTracker` resolves positions (pairing even and odd CPR fixes) but drops the emitter
/// category, which the map needs to pick an icon, so each message is also turned into a partial `AircraftReport` here.
/// Reports for one aircraft heard between two `drain()` calls are merged into one.
final class ModeSPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let demodulator = ModeSDemodulator()
    private let tracker: AircraftTracker
    private var pending: [UInt32: AircraftReport] = [:]
    private var blocksSeen = 0
    private var lastBlockAt: Date?
    private var lastExpiry = 0.0

    init(receiver: GeoCoordinate?) {
        tracker = AircraftTracker(receiverLocation: receiver.map { ($0.latitude, $0.longitude) })
    }

    /// Demodulates one block of interleaved unsigned 8-bit I/Q. Called from the device's streaming thread.
    func process(_ block: UnsafeBufferPointer<UInt8>, now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        let frames = demodulator.process(block)
        lock.lock()
        defer { lock.unlock() }
        blocksSeen += 1
        lastBlockAt = now
        for frame in frames {
            ingestLocked(frame.message, signalDBFS: frame.signalDBFS, now: now, uptime: uptime)
        }
        if uptime - lastExpiry > 30 {
            lastExpiry = uptime
            tracker.expire(olderThan: 300, now: uptime)
        }
    }

    /// Takes one parity-checked message (also the entry point for tests).
    func ingest(_ message: ModeSMessage, signalDBFS: Double? = nil, now: Date, uptime: Double) {
        lock.lock()
        defer { lock.unlock() }
        ingestLocked(message, signalDBFS: signalDBFS, now: now, uptime: uptime)
    }

    /// Takes one frame given as hex (a recording, a network feed, a test). Returns false when the text is not a whole
    /// Mode S frame: 7 bytes for the short formats (DF 0 to 15), 14 for the long ones.
    @discardableResult
    func ingest(hex: String, signalDBFS: Double? = nil, now: Date, uptime: Double) -> Bool {
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count % 2 == 0, !text.isEmpty else { return false }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return false }
            bytes.append(byte)
            index = next
        }
        let expected = (bytes[0] >> 3) >= 16 ? 14 : 7
        guard bytes.count == expected else { return false }
        ingest(ModeSMessage(bytes: bytes), signalDBFS: signalDBFS, now: now, uptime: uptime)
        return true
    }

    /// The reports gathered since the last call, oldest address first.
    func drain() -> [AviationUpdate] {
        lock.lock()
        defer { lock.unlock() }
        let reports = pending.values.sorted { $0.address < $1.address }
        pending.removeAll(keepingCapacity: true)
        return reports.map { .aircraft($0) }
    }

    struct Health {
        var blocks: Int
        var frames: Int
        var lastBlockAt: Date?
    }

    var health: Health {
        lock.lock()
        defer { lock.unlock() }
        return Health(blocks: blocksSeen, frames: demodulator.framesFound, lastBlockAt: lastBlockAt)
    }

    // MARK: Messages

    private func ingestLocked(_ message: ModeSMessage, signalDBFS: Double?, now: Date, uptime: Double) {
        tracker.update(message, at: uptime)
        var resolved: GeoCoordinate?
        if case .extendedSquitter(.airbornePosition) = message.content,
           let record = tracker[message.address], record.lastPosition == uptime,
           let latitude = record.latitude, let longitude = record.longitude {
            resolved = GeoCoordinate(latitude: latitude, longitude: longitude)
        }
        let report = Self.report(for: message, signalDBFS: signalDBFS, now: now, position: resolved)
        if var existing = pending[report.address] {
            existing.merge(report)
            pending[report.address] = existing
        } else {
            pending[report.address] = report
        }
    }

    /// The part of the aircraft's story this one message tells.
    static func report(for message: ModeSMessage, signalDBFS: Double?, now: Date, position: GeoCoordinate?) -> AircraftReport {
        var report = AircraftReport(address: message.address, source: .modeS, time: now, signalDBFS: signalDBFS)
        switch message.content {
        case let .altitude(feet):
            report.altitudeFeet = feet
        case let .identity(squawk):
            report.squawk = squawk
        case .allCall, .other:
            break
        case let .extendedSquitter(squitter):
            switch squitter {
            case let .identification(identification):
                report.callsign = identification.callsign
                report.aircraftClass = AircraftClass.fromADSB(typeCode: identification.typeCode, category: identification.category)
            case let .airbornePosition(airborne):
                if let feet = airborne.altitudeFeet, !airborne.altitudeIsGNSS { report.altitudeFeet = feet }
                report.onGround = false
                report.coordinate = position
            case let .velocity(velocity):
                if case let .ground(speed, track) = velocity.kind {
                    report.groundSpeedKnots = speed
                    report.trackDegrees = track
                } else if case let .air(heading, airspeed, _) = velocity.kind {
                    report.groundSpeedKnots = airspeed.map(Double.init)
                    report.trackDegrees = heading
                }
                report.verticalRateFPM = velocity.verticalRateFPM
            case let .emergency(state, squawk):
                report.emergency = ADSBEmergencyState(rawValue: state)
                report.squawk = squawk
            case .other:
                break
            }
        }
        return report
    }
}

/// How a receiver is doing, for the status line.
public struct ReceiverHealth: Sendable, Equatable {
    /// Blocks of samples received from the dongle.
    public var blocks: Int
    /// Valid frames found in them.
    public var frames: Int
    /// Seconds since the last block; nil before the first one.
    public var secondsSinceLastBlock: TimeInterval?
}

/// Receives 1090 MHz ADS-B and Mode S from an SDR that delivers unsigned 8-bit I/Q (an RTL-SDR, or one behind
/// `rtl_tcp`), and hands the aircraft it hears to a callback twice a second.
public actor ADSB1090Receiver {
    private let device: any SDRDevice
    private let pipeline: ModeSPipeline
    private let gainDB: Double
    private var flushTask: Task<Void, Never>?
    private var running = false

    /// - Parameters:
    ///   - receiverLocation: Where the antenna is. It lets a first position report resolve without waiting for a pair,
    ///     for aircraft within about 180 NM.
    ///   - gainDB: Tuner gain. ADS-B is weak, so the default is the dongle's maximum.
    public init(device: any SDRDevice, receiverLocation: GeoCoordinate? = nil, gainDB: Double = 49.6) {
        self.device = device
        self.pipeline = ModeSPipeline(receiver: receiverLocation)
        self.gainDB = gainDB
    }

    public var isRunning: Bool { running }

    public func start(onUpdates: @escaping @Sendable ([AviationUpdate]) -> Void) async throws {
        guard !running else { return }
        try await device.open()
        do {
            try await device.configure(frequency: 1_090_000_000, sampleRate: Double(ModeSDemodulator.sampleRate), gain: gainDB)
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
}
#endif
