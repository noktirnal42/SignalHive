import Foundation

/// Mean orbital elements for SGP4, in the units the element sets publish them (degrees, revolutions per day).
/// Codable so the element store can keep the parsed result on disk.
public struct OrbitalElements: Sendable, Equatable, Identifiable, Codable {
    public var name: String
    public var noradID: Int
    public var epoch: Date
    public var inclinationDegrees: Double
    public var raanDegrees: Double
    public var eccentricity: Double
    public var argumentOfPerigeeDegrees: Double
    public var meanAnomalyDegrees: Double
    public var meanMotionRevsPerDay: Double
    public var bstar: Double
    public var meanMotionDot: Double
    public var meanMotionDDot: Double

    public var id: Int { noradID }

    public init(name: String, noradID: Int, epoch: Date, inclinationDegrees: Double, raanDegrees: Double,
                eccentricity: Double, argumentOfPerigeeDegrees: Double, meanAnomalyDegrees: Double,
                meanMotionRevsPerDay: Double, bstar: Double, meanMotionDot: Double = 0, meanMotionDDot: Double = 0) {
        self.name = name
        self.noradID = noradID
        self.epoch = epoch
        self.inclinationDegrees = inclinationDegrees
        self.raanDegrees = raanDegrees
        self.eccentricity = eccentricity
        self.argumentOfPerigeeDegrees = argumentOfPerigeeDegrees
        self.meanAnomalyDegrees = meanAnomalyDegrees
        self.meanMotionRevsPerDay = meanMotionRevsPerDay
        self.bstar = bstar
        self.meanMotionDot = meanMotionDot
        self.meanMotionDDot = meanMotionDDot
    }

    public var periodMinutes: Double { 1440 / meanMotionRevsPerDay }

    /// SGP4 needs the deep-space (SDP4) model from a 225-minute period up; this phase refuses those satellites.
    public var isDeepSpace: Bool { periodMinutes >= 225 }
}
