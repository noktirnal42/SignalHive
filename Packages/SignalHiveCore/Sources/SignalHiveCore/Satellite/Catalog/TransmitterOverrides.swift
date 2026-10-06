import Foundation

/// What SignalHive knows that SatNOGS does not: how strong a satellite is in practice, notes worth showing, and
/// transmitters the owner has actually received. Small and hand-kept (`transmitter-overrides.json`), and honest about
/// its sources: strength classes are reports, not measurements, until the received-pass ledger exists.
public struct TransmitterOverrides: Sendable {
    private let strengths: [Int: SignalStrengthClass]
    private let notes: [Int: String]
    private let verified: [TransmitterInfo]

    public init(strengths: [Int: SignalStrengthClass], notes: [Int: String], verified: [TransmitterInfo]) {
        self.strengths = strengths
        self.notes = notes
        self.verified = verified
    }

    private struct File: Decodable {
        struct Entry: Decodable {
            var noradID: Int
            var strength: SignalStrengthClass?
            var note: String?
        }
        var satellites: [Entry]
        var verifiedTransmitters: [TransmitterInfo]
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
        return TransmitterOverrides(strengths: strengths, notes: notes, verified: file.verifiedTransmitters)
    }

    public func strength(for noradID: Int) -> SignalStrengthClass { strengths[noradID] ?? .unknown }
    public func note(for noradID: Int) -> String? { notes[noradID] }
    public func transmitters(for noradID: Int) -> [TransmitterInfo] { verified.filter { $0.noradID == noradID } }
}
