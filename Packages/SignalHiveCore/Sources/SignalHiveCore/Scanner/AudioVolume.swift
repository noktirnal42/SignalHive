import Foundation

/// Listening volume: a slider position plus a mute switch that remembers the position.
public struct AudioVolume: Equatable, Sendable, Codable {
    /// Slider position, 0...1.
    public var level: Float
    public var isMuted: Bool

    public init(level: Float = 0.6, isMuted: Bool = false) {
        self.level = level
        self.isMuted = isMuted
    }

    /// Linear amplitude gain. Ears hear loudness roughly logarithmically, so the slider is squared: it feels
    /// even across its travel instead of getting loud too quickly. Muted is silent.
    public var gain: Float {
        guard !isMuted else { return 0 }
        let clamped = max(0, min(1, level))
        return clamped * clamped
    }
}
