import Testing
import Foundation
import RTLSDRKit
@testable import SignalHiveCore

struct RTLSDRSelfTestTests {
    @Test func aLockedTunerAtTheNominalRatePasses() {
        let verdict = RTLSDRSelfTest.evaluate(bytes: 4_800_000, seconds: 1.0, nominalSampleRate: 2_400_000, tunerLocked: true)
        #expect(verdict.passed)
        #expect(verdict.lines.joined().contains("2.40"))
    }

    @Test func noSamplesFails() {
        let verdict = RTLSDRSelfTest.evaluate(bytes: 0, seconds: 1.0, nominalSampleRate: 2_400_000, tunerLocked: true)
        #expect(!verdict.passed)
        #expect(verdict.lines.joined().localizedCaseInsensitiveContains("no samples"))
    }

    @Test func aRateFarBelowNominalFailsAndSaysSamplesWereLost() {
        let verdict = RTLSDRSelfTest.evaluate(bytes: 2_000_000, seconds: 1.0, nominalSampleRate: 2_400_000, tunerLocked: true)
        #expect(!verdict.passed)
        #expect(verdict.lines.joined().localizedCaseInsensitiveContains("below"))
    }

    @Test func anUnlockedTunerFailsEvenWithSamples() {
        let verdict = RTLSDRSelfTest.evaluate(bytes: 4_800_000, seconds: 1.0, nominalSampleRate: 2_400_000, tunerLocked: false)
        #expect(!verdict.passed)
        #expect(verdict.lines.joined().localizedCaseInsensitiveContains("lock"))
    }

    @Test func aDeviceThatCannotBeOpenedReportsTheReason() async {
        let device = NativeRTLSDRDevice(name: "Busy", serial: "X") { throw RTLSDRError.openFailed("resource busy") }
        let report = await RTLSDRSelfTest.run(device, duration: 0.05)
        #expect(!report.passed)
        #expect(report.lines.joined().contains("resource busy"))
    }

    @Test func aDongleThatStreamsNothingFailsTheRun() async {
        let backend = FakeRTLSDRBackend()
        let device = NativeRTLSDRDevice(name: "Silent", serial: "X") { backend }
        let report = await RTLSDRSelfTest.run(device, duration: 0.05)
        #expect(!report.passed)
        #expect(report.lines.joined().localizedCaseInsensitiveContains("no samples"))
        #expect(backend.closeCount == 1, "the dongle must be released even when the test fails")
    }
}
