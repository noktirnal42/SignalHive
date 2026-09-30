import Testing
import Foundation
import RTLSDRKit
@testable import SignalHiveCore

/// A dongle that records what the adapter asks of it, so the adapter's own logic can be tested without hardware.
final class FakeRTLSDRBackend: RTLSDRBackend, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    private(set) var closeCount = 0
    var reportedRate: Double?                      // what the "hardware" says it produces (defaults to the request)
    var rateError: Error?
    var frequencyError: Error?
    var lockState = true
    private var handler: (@Sendable (UnsafeBufferPointer<UInt8>) -> Void)?
    private var errorHandler: (@Sendable (Error) -> Void)?
    private(set) var sampleRate: Double = 0

    var pllLocked: Bool { lockState }
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    private func record(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }

    func setSampleRate(_ rate: Int) throws -> Double {
        record("rate \(rate)")
        if let rateError { throw rateError }
        sampleRate = reportedRate ?? Double(rate)
        return sampleRate
    }
    func setCenterFrequency(_ hertz: Int) throws {
        record("frequency \(hertz)")
        if let frequencyError { throw frequencyError }
    }
    func setAutomaticGain() throws { record("gain auto") }
    func setTunerGain(tenthsDB: Int) throws { record("gain \(tenthsDB)") }
    func startStreaming(onError: @escaping @Sendable (Error) -> Void, handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void) throws {
        record("start")
        self.handler = handler
        self.errorHandler = onError
    }
    func stopStreaming() { record("stop"); handler = nil }
    func close() { lock.lock(); closeCount += 1; lock.unlock() }

    func deliver(_ bytes: [UInt8]) { bytes.withUnsafeBufferPointer { handler?($0) } }
    func die(_ error: Error) { errorHandler?(error) }
}

struct NativeRTLSDRDeviceTests {
    private func makeDevice(_ backend: FakeRTLSDRBackend = FakeRTLSDRBackend()) -> (NativeRTLSDRDevice, FakeRTLSDRBackend) {
        (NativeRTLSDRDevice(name: "Test dongle", serial: "TEST0001") { backend }, backend)
    }

    @Test func identifiesItselfAsAnRTLSDRWithTheRangesTheDriverAccepts() {
        let (device, _) = makeDevice()
        #expect(device.deviceType == .rtlsdr && device.serial == "TEST0001" && device.name == "Test dongle")
        #expect(device.frequencyRange == RTLSDRKit.RTLSDRDevice.tunableRange.lowerBound.asDouble...RTLSDRKit.RTLSDRDevice.tunableRange.upperBound.asDouble)
        #expect(device.gainRange.lowerBound == 0 && device.gainRange.upperBound == 49.6)
        #expect(device.supportedSampleRates.contains(2_048_000) && device.supportedSampleRates.contains(3_200_000))
        #expect(!device.supportsTX)
    }

    @Test func configuringBeforeOpeningIsAnError() async {
        let (device, backend) = makeDevice()
        await #expect(throws: SDRError.self) { try await device.configure(frequency: 100e6, sampleRate: 2_048_000, gain: 30) }
        #expect(backend.recorded.isEmpty)
    }

    @Test func aFailedOpenBecomesAnOpenErrorThatSaysWhy() async {
        let device = NativeRTLSDRDevice(name: "Busy", serial: "X") { throw RTLSDRError.openFailed("resource busy") }
        do {
            try await device.open()
            Issue.record("open should have failed")
        } catch let SDRError.openFailed(message) {
            #expect(message.contains("resource busy"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func configureSetsRateThenFrequencyThenManualGain() async throws {
        let (device, backend) = makeDevice()
        try await device.open()
        try await device.configure(frequency: 155_475_000, sampleRate: 2_048_000, gain: 30)
        #expect(backend.recorded == ["rate 2048000", "frequency 155475000", "gain 300"])
        #expect(device.currentFrequency == 155_475_000 && device.currentSampleRate == 2_048_000 && device.currentGain == 30)
    }

    @Test func zeroGainMeansAutomatic() async throws {
        let (device, backend) = makeDevice()
        try await device.open()
        try await device.configure(frequency: 100e6, sampleRate: 2_048_000, gain: 0)
        #expect(backend.recorded.last == "gain auto")
    }

    @Test func fractionalRequestsAreRoundedNotTruncated() async throws {
        let (device, backend) = makeDevice()
        try await device.open()
        try await device.configure(frequency: 99_999_999.6, sampleRate: 2_047_999.7, gain: 29.75)
        #expect(backend.recorded == ["rate 2048000", "frequency 100000000", "gain 298"])
    }

    @Test func theRateTheHardwareReallyProducesIsWhatIsReported() async throws {
        let backend = FakeRTLSDRBackend()
        backend.reportedRate = 999_998.4
        let (device, _) = makeDevice(backend)
        try await device.open()
        try await device.configure(frequency: 100e6, sampleRate: 1_000_000, gain: 20)
        #expect(device.currentSampleRate == 999_998.4)
    }

    @Test(arguments: [10_000_000.0, 23_999_999.0, 1_766_000_001.0, 2_400_000_000.0, -5.0])
    func frequenciesOutsideTheRangeAreRefusedBeforeTouchingTheHardware(frequency: Double) async throws {
        let (device, backend) = makeDevice()
        try await device.open()
        await #expect(throws: SDRError.self) { try await device.configure(frequency: frequency, sampleRate: 2_048_000, gain: 30) }
        #expect(backend.recorded.isEmpty)
        #expect(device.currentFrequency == 100_000_000, "state is unchanged after a refused request")
    }

    @Test func gainOutsideTheRangeIsRefused() async throws {
        let (device, backend) = makeDevice()
        try await device.open()
        await #expect(throws: SDRError.self) { try await device.configure(frequency: 100e6, sampleRate: 2_048_000, gain: 60) }
        await #expect(throws: SDRError.self) { try await device.configure(frequency: 100e6, sampleRate: 2_048_000, gain: -1) }
        #expect(backend.recorded.isEmpty)
    }

    @Test func aRateTheDriverRejectsBecomesAConfigurationErrorAndChangesNothing() async throws {
        let backend = FakeRTLSDRBackend()
        backend.rateError = RTLSDRError.invalidSampleRate(500_000)
        let (device, _) = makeDevice(backend)
        try await device.open()
        do {
            try await device.configure(frequency: 100e6, sampleRate: 500_000, gain: 30)
            Issue.record("should have failed")
        } catch let SDRError.configurationFailed(message) {
            #expect(message.contains("500000") || message.contains("500,000"))
        }
        #expect(device.currentSampleRate == 2_048_000 && device.currentFrequency == 100_000_000)
    }

    @Test func tunerLockIsReportedAndAnUnlockedTuneStillSucceeds() async throws {
        let backend = FakeRTLSDRBackend()
        backend.lockState = false
        let (device, _) = makeDevice(backend)
        #expect(device.tunerLocked == false, "not open yet")
        try await device.open()
        try await device.configure(frequency: 100e6, sampleRate: 2_048_000, gain: 30)
        #expect(device.tunerLocked == false)
        backend.lockState = true
        #expect(device.tunerLocked)
    }

    @Test func streamedBytesReachTheCallbackWithASampleCount() async throws {
        let (device, backend) = makeDevice()
        try await device.open()
        let seen = Seen()
        try await device.startStreaming { buffer, samples in seen.add(Array(buffer), samples) }
        backend.deliver([1, 2, 3, 4, 5, 6])
        backend.deliver([7, 8])
        #expect(seen.blocks == [[1, 2, 3, 4, 5, 6], [7, 8]])
        #expect(seen.sampleCounts == [3, 1], "one complex sample is two bytes")
    }

    @Test func streamingBeforeOpeningIsAnError() async {
        let (device, _) = makeDevice()
        await #expect(throws: SDRError.self) { try await device.startStreaming { _, _ in } }
    }

    @Test func aStreamThatDiesLeavesAReasonToShow() async throws {
        let (device, backend) = makeDevice()
        try await device.open()
        try await device.startStreaming { _, _ in }
        #expect(device.streamError == nil)
        backend.die(RTLSDRError.usb("device unplugged"))
        #expect(device.streamError?.contains("device unplugged") == true)
    }

    @Test func closingStopsTheStreamReleasesTheDongleAndIsSafeToRepeat() async throws {
        let (device, backend) = makeDevice()
        try await device.open()
        try await device.startStreaming { _, _ in }
        await device.close()
        await device.close()
        #expect(backend.recorded.contains("stop"))
        #expect(backend.closeCount == 1)
        await #expect(throws: SDRError.self) { try await device.configure(frequency: 100e6, sampleRate: 2_048_000, gain: 30) }
    }

    @Test func aDeviceCanBeReopenedAfterClosing() async throws {
        let (device, backend) = makeDevice()
        try await device.open()
        await device.close()
        try await device.open()
        try await device.configure(frequency: 100e6, sampleRate: 2_048_000, gain: 30)
        #expect(backend.recorded.contains("rate 2048000"))
    }

    @Test func stoppingWithoutStreamingIsHarmless() async throws {
        let (device, _) = makeDevice()
        await device.stopStreaming()
        try await device.open()
        await device.stopStreaming()
    }
}

struct RTLSDRAvailabilityTests {
    @Test func noDongleSaysSoInsteadOfBlamingALibrary() {
        let status = RTLSDRAvailability.make(dongles: [])
        #expect(!status.isAvailable)
        #expect(status.summary.localizedCaseInsensitiveContains("no rtl-sdr"))
        #expect(!status.summary.localizedCaseInsensitiveContains("library"))
    }

    @Test func aFoundDongleIsNamed() {
        let status = RTLSDRAvailability.make(dongles: ["Generic RTL2832U OEM (serial 00000001)"])
        #expect(status.isAvailable)
        #expect(status.summary.contains("Generic RTL2832U OEM"))
    }

    @Test func severalDonglesAreAllCounted() {
        let status = RTLSDRAvailability.make(dongles: ["A", "B"])
        #expect(status.isAvailable && status.summary.contains("2"))
    }

    @Test func platformsWithoutUSBSupportExplainThat() {
        let status = RTLSDRAvailability.make(dongles: nil)
        #expect(!status.isAvailable)
        #expect(status.summary.localizedCaseInsensitiveContains("not available on this platform"))
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBlocks: [[UInt8]] = []
    private var storedCounts: [Int] = []
    func add(_ block: [UInt8], _ samples: Int) { lock.lock(); storedBlocks.append(block); storedCounts.append(samples); lock.unlock() }
    var blocks: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return storedBlocks }
    var sampleCounts: [Int] { lock.lock(); defer { lock.unlock() }; return storedCounts }
}

private extension Int { var asDouble: Double { Double(self) } }
