import Testing
import Foundation
@testable import SignalHiveCore

/// Hardware tests: they run against a real RTL-SDR when one is attached and cancel (not silently pass)
/// when none is. Quit any app that has the dongle open first (only one process can hold it).
/// Serialized: the tests share one dongle, and only one handle can be open at a time.
@Suite(.serialized)
struct RTLSDRHardwareTests {

    private func firstDevice() async throws -> NativeRTLSDRDevice {
        guard let device = await NativeRTLSDRDevice.enumerateDevices().first else {
            try Test.cancel("No RTL-SDR attached")
            throw CancellationError()
        }
        return device
    }

    @Test func aDongleIsDescribedByItsRealNameAndSerial() async throws {
        let device = try await firstDevice()
        #expect(!device.name.isEmpty && !device.serial.isEmpty)
        #expect(RTLSDRAvailability.make(dongles: NativeRTLSDRDevice.connectedDongleDescriptions()).isAvailable)
    }

    @Test func tuningVHFLocksTheOscillator() async throws {
        let device = try await firstDevice()
        try await device.open()
        do {
            try await device.configure(frequency: 155_475_000, sampleRate: 2_048_000, gain: 30)
            #expect(device.tunerLocked, "the tuner's PLL must lock at a VHF scanner frequency")
            #expect(device.currentFrequency == 155_475_000)
            #expect(abs(device.currentSampleRate - 2_048_000) < 1)
        } catch {
            await device.close()
            throw error
        }
        await device.close()
    }

    @Test func streamingDeliversRoughlyTheNominalByteRate() async throws {
        let device = try await firstDevice()
        try await device.open()
        let counter = ByteCounter()
        do {
            try await device.configure(frequency: 100_000_000, sampleRate: 2_400_000, gain: 30)
            try await device.startStreaming { buffer, samples in
                counter.add(bytes: buffer.count, samples: samples)
            }
            try await Task.sleep(for: .seconds(2))
            await device.stopStreaming()
        } catch {
            await device.close()
            throw error
        }
        await device.close()
        let bytes = counter.bytes
        // 2.4 MS/s of 8-bit I/Q is 4.8 MB/s: two seconds should land near 9.6 MB (allow start-up and timer slack).
        #expect(bytes > 7_500_000 && bytes < 10_500_000, "received \(bytes) bytes in about 2 s")
        #expect(counter.samples * 2 == bytes, "the sample count is bytes / 2 for every block")
        #expect(device.streamError == nil)
    }

    @Test func aDeviceCanBeUsedAgainAfterClosing() async throws {
        let device = try await firstDevice()
        for _ in 0..<2 {
            try await device.open()
            try await device.configure(frequency: 100_000_000, sampleRate: 1_024_000, gain: 0)
            await device.close()
        }
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var totalBytes = 0, totalSamples = 0
    func add(bytes: Int, samples: Int) { lock.lock(); totalBytes += bytes; totalSamples += samples; lock.unlock() }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return totalBytes }
    var samples: Int { lock.lock(); defer { lock.unlock() }; return totalSamples }
}
