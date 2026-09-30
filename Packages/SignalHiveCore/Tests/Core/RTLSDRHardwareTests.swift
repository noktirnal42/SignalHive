import Testing
import Foundation
@testable import SignalHiveCore

/// Hardware tests: they run against a real RTL-SDR when one is attached and cancel (not silently pass)
/// when none is. Quit any app that has the dongle open first (only one process can hold it).
struct RTLSDRHardwareTests {

    private func firstDevice() async throws -> RTLSDRDevice {
        guard let device = await RTLSDRDevice.enumerateDevices().first else {
            try Test.cancel("No RTL-SDR attached")
            throw CancellationError()
        }
        return device
    }

    @Test func configuringForVHFLeavesTheTunerInUse() async throws {
        let device = try await firstDevice()
        try await device.open()
        do {
            try await device.configure(frequency: 155_475_000, sampleRate: 2_048_000, gain: 30)
            let state = try #require(device.diagnostics())
            #expect(state.directSampling == 0,
                    "direct sampling bypasses the tuner (HF only), so VHF/UHF can not be received")
            #expect(abs(Double(state.centerFrequencyHz) - 155_475_000) < 1_000)
        } catch {
            await device.close()
            throw error
        }
        await device.close()
    }
}
