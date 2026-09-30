import Foundation

/// A short end-to-end check of an RTL-SDR: open it, tune a VHF frequency, stream for a moment, and say in plain
/// words whether it worked. Used for headless verification of the sandboxed app and for support ("it shows nothing").
public struct RTLSDRSelfTestReport: Equatable, Sendable {
    public var passed: Bool
    public var lines: [String]
}

public enum RTLSDRSelfTest {
    static let frequency = 155_475_000.0
    static let sampleRate = 2_400_000.0
    static let gain = 30.0

    /// Pure pass/fail logic, so it can be tested without hardware.
    static func evaluate(bytes: Int, seconds: Double, nominalSampleRate: Double, tunerLocked: Bool) -> RTLSDRSelfTestReport {
        var lines: [String] = []
        var passed = true
        guard bytes > 0, seconds > 0 else {
            return RTLSDRSelfTestReport(passed: false, lines: ["No samples arrived from the dongle."])
        }
        let achieved = Double(bytes) / 2 / seconds
        let percent = 100 * achieved / nominalSampleRate
        lines.append(String(format: "Received %d bytes in %.2f s: %.2f MS/s (%.0f%% of the requested %.2f MS/s).",
                            bytes, seconds, achieved / 1e6, percent, nominalSampleRate / 1e6))
        if percent < 90 {
            passed = false
            lines.append("The sample rate is well below what was asked for: samples are being lost.")
        }
        if tunerLocked {
            lines.append("Tuner oscillator locked.")
        } else {
            passed = false
            lines.append("The tuner's oscillator did not lock, so the samples are not at the requested frequency.")
        }
        return RTLSDRSelfTestReport(passed: passed, lines: lines)
    }

    /// Opens `device`, streams for `duration` seconds, closes it (always), and reports.
    public static func run(_ device: NativeRTLSDRDevice, duration: TimeInterval = 1.0) async -> RTLSDRSelfTestReport {
        var lines = ["Device: \(device.name) (serial \(device.serial))"]
        do {
            try await device.open()
        } catch {
            lines.append("Could not open it: \(error.localizedDescription)")
            return RTLSDRSelfTestReport(passed: false, lines: lines)
        }
        lines.append("Opened.")

        let counter = ByteTally()
        var report: RTLSDRSelfTestReport
        do {
            try await device.configure(frequency: frequency, sampleRate: sampleRate, gain: gain)
            lines.append(String(format: "Tuned %.3f MHz at %.2f MS/s, gain %.0f dB.", frequency / 1e6, device.currentSampleRate / 1e6, gain))
            let started = Date()
            try await device.startStreaming { buffer, _ in counter.add(buffer.count) }
            try await Task.sleep(for: .seconds(duration))
            await device.stopStreaming()
            let elapsed = Date().timeIntervalSince(started)
            let verdict = evaluate(bytes: counter.total, seconds: elapsed, nominalSampleRate: device.currentSampleRate, tunerLocked: device.tunerLocked)
            lines += verdict.lines
            if let streamError = device.streamError { lines.append("Stream error: \(streamError)") }
            report = RTLSDRSelfTestReport(passed: verdict.passed && device.streamError == nil, lines: lines)
        } catch {
            lines.append("Failed: \(error.localizedDescription)")
            report = RTLSDRSelfTestReport(passed: false, lines: lines)
        }
        await device.close()
        return report
    }
}

private final class ByteTally: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func add(_ count: Int) { lock.withLock { bytes += count } }
    var total: Int { lock.withLock { bytes } }
}
