import Foundation

// MARK: - Goertzel Filter

public final class GoertzelFilter: @unchecked Sendable {
    private let sampleRate: Double
    private let targetFreq: Double
    private let coeff: Float
    private var q1: Float = 0
    private var q2: Float = 0

    public init(sampleRate: Double, targetFreq: Double) {
        self.sampleRate = sampleRate
        self.targetFreq = targetFreq
        let omega = 2.0 * Double.pi * targetFreq / sampleRate
        self.coeff = Float(2.0 * cos(omega))
        self.q1 = 0
        self.q2 = 0
    }

    public func reset() { q1 = 0; q2 = 0 }

    @discardableResult
    public func process(_ sample: Float) -> Float {
        let q0 = coeff * q1 - q2 + sample
        q2 = q1; q1 = q0
        return q1*q1 + q2*q2 - coeff*q1*q2
    }

    public func magnitude() -> Float {
        return sqrt(q1*q1 + q2*q2 - coeff*q1*q2)
    }
}