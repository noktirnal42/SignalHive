import Foundation

/// What SignalHive knows that SatNOGS does not: how strong a satellite is in practice, notes worth showing, and
/// transmitters the owner has actually received. Small and hand-kept (`transmitter-overrides.json`), and honest about
/// its sources: strength classes are reports, not measurements, until the received-pass ledger exists.
public struct TransmitterOverrides: Sendable {
    private let strengths: [Int: SignalStrengthClass]
    private let notes: [Int: String]
    private let verified: [TransmitterInfo]
    private let suppressed: [Suppressed]

    /// A downlink SatNOGS lists that is known not to be one (for example a GPS receive frequency).
    public struct Suppressed: Sendable, Decodable {
        public var noradID: Int
        public var downlinkHz: Double
        public var reason: String

        public init(noradID: Int, downlinkHz: Double, reason: String) {
            self.noradID = noradID
            self.downlinkHz = downlinkHz
            self.reason = reason
        }
    }

    public init(strengths: [Int: SignalStrengthClass], notes: [Int: String], verified: [TransmitterInfo], suppressed: [Suppressed] = []) {
        self.strengths = strengths
        self.notes = notes
        self.verified = verified
        self.suppressed = suppressed
    }

    private struct File: Decodable {
        struct Entry: Decodable {
            var noradID: Int
            var strength: SignalStrengthClass?
            var note: String?
        }
        var satellites: [Entry]
        var verifiedTransmitters: [TransmitterInfo]
        var suppressedTransmitters: [Suppressed]?
    }

    public static func bundled() throws -> TransmitterOverrides {
        guard let url = Bundle.module.url(forResource: "transmitter-overrides", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        var strengths: [Int: SignalStrengthClass] = [:]
        var notes: [Int: String] = [:]
        for entry in file.satellites {
            if let strength = entry.strength { strengths[entry.noradID] = strength }
            if let note = entry.note { notes[entry.noradID] = note }
        }
        return TransmitterOverrides(strengths: strengths, notes: notes, verified: file.verifiedTransmitters,
                                    suppressed: file.suppressedTransmitters ?? [])
    }

    public func strength(for noradID: Int) -> SignalStrengthClass { strengths[noradID] ?? .unknown }
    public func note(for noradID: Int) -> String? { notes[noradID] }
    /// Within 1 kHz, since feeds round frequencies differently.
    public func isSuppressed(noradID: Int, downlinkHz: Double) -> Bool {
        suppressed.contains { $0.noradID == noradID && abs($0.downlinkHz - downlinkHz) < 1000 }
    }
    public func transmitters(for noradID: Int) -> [TransmitterInfo] { verified.filter { $0.noradID == noradID } }
}
