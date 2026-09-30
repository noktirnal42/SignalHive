import Foundation

public enum ScanChannelSource: String, Codable, Sendable, CaseIterable {
    case fcc = "FCC"
    case manual = "Manual"
    case preset = "Preset"
    case liveHit = "Live Hit"
}

public struct ScanChannel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var frequencyHz: Double
    public var bandwidthHz: Double
    public var mode: DemodMode
    public var source: ScanChannelSource
    public var lockedOut: Bool
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        frequencyHz: Double,
        bandwidthHz: Double = 12_500,
        mode: DemodMode = .nfm,
        source: ScanChannelSource = .manual,
        lockedOut: Bool = false,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.frequencyHz = frequencyHz
        self.bandwidthHz = bandwidthHz
        self.mode = mode
        self.source = source
        self.lockedOut = lockedOut
        self.notes = notes
    }

    public var displayMHz: String {
        String(format: "%.5f MHz", frequencyHz / 1_000_000)
    }

    public func codeplugChannel() -> CodeplugChannel {
        CodeplugChannel(
            name: name.isEmpty ? displayMHz : name,
            frequencyHz: frequencyHz,
            mode: ChannelMode(demodMode: mode),
            notes: notes,
            sourceCallSign: source.rawValue
        )
    }
}

public struct ScanList: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var channels: [ScanChannel]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        channels: [ScanChannel] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.channels = channels
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var activeChannels: [ScanChannel] {
        channels.filter { !$0.lockedOut }
    }

    public mutating func upsert(_ channel: ScanChannel, mergeWindowHz: Double = 6_250) {
        if let index = channels.firstIndex(where: { abs($0.frequencyHz - channel.frequencyHz) <= mergeWindowHz }) {
            channels[index] = channel
        } else {
            channels.append(channel)
            channels.sort { $0.frequencyHz < $1.frequencyHz }
        }
        updatedAt = Date()
    }

    public mutating func setLockedOut(frequencyHz: Double, lockedOut: Bool, mergeWindowHz: Double = 6_250) {
        guard let index = channels.firstIndex(where: { abs($0.frequencyHz - frequencyHz) <= mergeWindowHz }) else { return }
        channels[index].lockedOut = lockedOut
        updatedAt = Date()
    }

    public static let starterPublicSafety = ScanList(
        name: "VHF / UHF Starter",
        channels: [
            ScanChannel(name: "NOAA Weather 1", frequencyHz: 162_400_000, bandwidthHz: 25_000, mode: .nfm, source: .preset),
            ScanChannel(name: "NOAA Weather 3", frequencyHz: 162_475_000, bandwidthHz: 25_000, mode: .nfm, source: .preset),
            ScanChannel(name: "NOAA Weather 7", frequencyHz: 162_550_000, bandwidthHz: 25_000, mode: .nfm, source: .preset),
            ScanChannel(name: "Airband Guard", frequencyHz: 121_500_000, bandwidthHz: 10_000, mode: .am, source: .preset),
            ScanChannel(name: "Marine 16", frequencyHz: 156_800_000, bandwidthHz: 25_000, mode: .nfm, source: .preset),
            ScanChannel(name: "Public Safety VHF", frequencyHz: 155_475_000, bandwidthHz: 12_500, mode: .nfm, source: .preset),
            ScanChannel(name: "GMRS 1", frequencyHz: 462_562_500, bandwidthHz: 12_500, mode: .nfm, source: .preset),
        ]
    )
}

public struct ScanActivity: Identifiable, Hashable, Sendable {
    public var id: Int
    public var frequencyHz: Double
    public var strengthDB: Float
    public var noiseFloorDB: Float?
    public var bandwidthHz: Double?
    public var firstSeen: Date
    public var lastSeen: Date
    public var hitCount: Int
    public var lockedOut: Bool
    public var label: String

    public init(
        frequencyHz: Double,
        strengthDB: Float,
        noiseFloorDB: Float? = nil,
        bandwidthHz: Double? = nil,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        hitCount: Int = 1,
        lockedOut: Bool = false,
        label: String = ""
    ) {
        self.id = ScanActivity.key(for: frequencyHz)
        self.frequencyHz = frequencyHz
        self.strengthDB = strengthDB
        self.noiseFloorDB = noiseFloorDB
        self.bandwidthHz = bandwidthHz
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.hitCount = hitCount
        self.lockedOut = lockedOut
        self.label = label
    }

    public var displayMHz: String {
        String(format: "%.5f MHz", frequencyHz / 1_000_000)
    }

    public var snrDB: Float? {
        guard let noiseFloorDB else { return nil }
        return strengthDB - noiseFloorDB
    }

    public static func key(for frequencyHz: Double, gridHz: Double = 6_250) -> Int {
        Int((frequencyHz / gridHz).rounded())
    }
}

public struct ScanActivityLog: Sendable, Equatable {
    public private(set) var hits: [ScanActivity] = []
    public var mergeWindowHz: Double
    public var capacity: Int

    public init(mergeWindowHz: Double = 6_250, capacity: Int = 60) {
        self.mergeWindowHz = mergeWindowHz
        self.capacity = capacity
    }

    public mutating func ingest(_ found: [FoundFrequency], lockedOutKeys: Set<Int> = [], now: Date = Date()) {
        for peak in found {
            let key = ScanActivity.key(for: peak.frequencyHz, gridHz: mergeWindowHz)
            if let index = hits.firstIndex(where: { $0.id == key }) {
                hits[index].frequencyHz = peak.frequencyHz
                hits[index].strengthDB = peak.strengthDB
                hits[index].noiseFloorDB = peak.noiseFloorDB
                hits[index].bandwidthHz = peak.bandwidthHz
                hits[index].lastSeen = now
                hits[index].hitCount += 1
                hits[index].lockedOut = lockedOutKeys.contains(key)
            } else {
                hits.append(ScanActivity(
                    frequencyHz: peak.frequencyHz,
                    strengthDB: peak.strengthDB,
                    noiseFloorDB: peak.noiseFloorDB,
                    bandwidthHz: peak.bandwidthHz,
                    firstSeen: now,
                    lastSeen: now,
                    lockedOut: lockedOutKeys.contains(key)
                ))
            }
        }
        hits.sort {
            if $0.lockedOut != $1.lockedOut { return !$0.lockedOut }
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return $0.strengthDB > $1.strengthDB
        }
        if hits.count > capacity { hits.removeLast(hits.count - capacity) }
    }

    public mutating func setLockedOut(frequencyHz: Double, lockedOut: Bool) {
        let key = ScanActivity.key(for: frequencyHz, gridHz: mergeWindowHz)
        guard let index = hits.firstIndex(where: { $0.id == key }) else { return }
        hits[index].lockedOut = lockedOut
    }
}

extension ChannelMode {
    public init(demodMode: DemodMode) {
        switch demodMode {
        case .am:
            self = .am
        case .nfm, .wfm:
            self = .nfm
        case .usb, .lsb, .cw, .raw:
            self = .fm
        }
    }
}
