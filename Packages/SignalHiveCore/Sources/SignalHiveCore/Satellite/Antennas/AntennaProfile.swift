import Foundation

/// An antenna the owner has, described by what it covers. Ratings use only these declared facts.
public struct AntennaProfile: Identifiable, Codable, Sendable, Equatable {
    public enum Gain: String, Codable, Sendable { case omni, low, medium, high }

    public var id: UUID
    public var name: String
    public var lowHz: Double
    public var highHz: Double
    public var gain: Gain
    /// A directional antenna only earns its gain when something points it (a rotator, or a hand on a pass).
    public var isDirectional: Bool
    public var notes: String

    public init(id: UUID, name: String, lowHz: Double, highHz: Double, gain: Gain, isDirectional: Bool, notes: String) {
        self.id = id
        self.name = name
        self.lowHz = lowHz
        self.highHz = highHz
        self.gain = gain
        self.isDirectional = isDirectional
        self.notes = notes
    }

    public func covers(_ hz: Double) -> Bool {
        hz.isFinite && hz >= lowHz && hz <= highHz
    }

    /// The masts in the owner's NooElec kit, with the bands NooElec describes for them. Fixed ids, so a saved choice
    /// survives relaunch. Per the maker's description, not measured.
    public static let presets: [AntennaProfile] = [
        AntennaProfile(id: UUID(uuidString: "5A7E1C00-0000-4000-8000-000000000001")!, name: "NooElec telescopic mast",
                       lowHz: 100e6, highHz: 800e6, gain: .omni, isDirectional: false,
                       notes: "About 100 to 800 MHz depending on the length it is set to, per NooElec's description; not measured."),
        AntennaProfile(id: UUID(uuidString: "5A7E1C00-0000-4000-8000-000000000002")!, name: "NooElec DVB-T/T2 mast (blue bands)",
                       lowHz: 700e6, highHz: 1200e6, gain: .omni, isDirectional: false,
                       notes: "700 to 1200 MHz, per NooElec's description; not measured."),
        AntennaProfile(id: UUID(uuidString: "5A7E1C00-0000-4000-8000-000000000003")!, name: "NooElec helical mast",
                       lowHz: 1100e6, highHz: 1800e6, gain: .low, isDirectional: true,
                       notes: "1100 to 1800 MHz, per NooElec's description; counted as directional (it needs pointing to help); not measured."),
    ]
}
