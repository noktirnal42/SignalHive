import Testing
import Foundation
@testable import SignalHiveCore

/// A dongle that does nothing; only its name and serial matter here.
private final class StubDongle: SDRDevice, @unchecked Sendable {
    let id = UUID()
    let name: String
    let serial: String
    let deviceType: SDRDeviceType = .rtlsdr
    let frequencyRange: ClosedRange<Double> = 24_000_000...1_700_000_000
    let supportedSampleRates: [Double] = [1_024_000]
    let gainRange: ClosedRange<Double> = 0...50
    var currentFrequency = 0.0
    var currentSampleRate = 0.0
    var currentGain = 0.0

    init(name: String = "Generic RTL2832U", serial: String) {
        self.name = name
        self.serial = serial
    }

    func open() async throws {}
    func configure(frequency: Double, sampleRate: Double, gain: Double) async throws {}
    func startStreaming(callback: @Sendable @escaping (UnsafeBufferPointer<UInt8>, Int) -> Void) async throws {}
    func stopStreaming() async {}
    func close() async {}
}

@MainActor
struct DongleRegistryTests {
    private func registry(scannerHolds keys: Set<String> = []) -> DongleRegistry {
        DongleRegistry(outsideHolder: { keys.contains($0) ? "the Scanner" : nil })
    }

    @Test func aFreeDongleCanBeClaimedAndIsThenHeld() throws {
        let registry = registry()
        let dongle = StubDongle(serial: "A")
        #expect(registry.holder(of: dongle) == nil)
        try registry.claim(dongle, owner: "Air Map")
        #expect(registry.holder(of: dongle) == "Air Map")
        try registry.claim(dongle, owner: "Air Map")        // the holder asking again is fine
    }

    @Test func anotherOwnerIsTurnedAwayWithAReason() throws {
        let registry = registry()
        let dongle = StubDongle(serial: "A")
        try registry.claim(dongle, owner: "Air Map")
        #expect(throws: DongleRegistry.Busy(deviceName: "Generic RTL2832U", holder: "Air Map")) {
            try registry.claim(dongle, owner: "Decoder Hub")
        }
        #expect(DongleRegistry.Busy(deviceName: "X", holder: "Air Map").errorDescription?.contains("in use by Air Map") == true)
    }

    @Test func onlyTheHolderCanRelease() throws {
        let registry = registry()
        let dongle = StubDongle(serial: "A")
        try registry.claim(dongle, owner: "Air Map")
        registry.release(dongle, owner: "Decoder Hub")
        #expect(registry.holder(of: dongle) == "Air Map")
        registry.release(dongle, owner: "Air Map")
        #expect(registry.holder(of: dongle) == nil)
    }

    @Test func theScannersDongleCountsAsHeld() throws {
        let dongle = StubDongle(serial: "A")
        let registry = registry(scannerHolds: [DongleRegistry.key(for: dongle)])
        #expect(registry.holder(of: dongle) == "the Scanner")
        #expect(throws: DongleRegistry.Busy.self) { try registry.claim(dongle, owner: "Decoder Hub") }
    }

    @Test func releasingEverythingAnOwnerHoldsLeavesTheRestAlone() throws {
        let registry = registry()
        let first = StubDongle(serial: "A"), second = StubDongle(serial: "B"), third = StubDongle(serial: "C")
        try registry.claim(first, owner: "Decoder Hub")
        try registry.claim(second, owner: "Decoder Hub")
        try registry.claim(third, owner: "Air Map")
        registry.releaseAll(owner: "Decoder Hub")
        #expect(registry.holder(of: first) == nil && registry.holder(of: second) == nil)
        #expect(registry.holder(of: third) == "Air Map")
    }

    @Test func theFirstFreeDongleIsChosen() throws {
        let registry = registry()
        let first = StubDongle(serial: "A"), second = StubDongle(serial: "B")
        try registry.claim(first, owner: "Air Map")
        #expect(registry.firstFree(in: [first, second])?.serial == "B")
        #expect(registry.firstFree(in: [first, second], for: "Air Map")?.serial == "A", "a dongle the asker already holds is free to it")
        try registry.claim(second, owner: "Decoder Hub")
        #expect(registry.firstFree(in: [first, second]) == nil)
        #expect(registry.firstFree(in: []) == nil)
    }

    @Test func theExplanationNamesWhoHasThem() throws {
        let registry = registry()
        let first = StubDongle(serial: "A"), second = StubDongle(serial: "B")
        #expect(registry.busyExplanation(for: [first]) == "No dongle is available.")
        try registry.claim(first, owner: "Air Map")
        #expect(registry.busyExplanation(for: [first]) == "The dongle is in use by Air Map. Stop it there first; only one program can hold it.")
        try registry.claim(second, owner: "Decoder Hub")
        let both = registry.busyExplanation(for: [first, second])
        #expect(both.contains("Air Map and Decoder Hub") && both.contains("plug in another"))
    }

    @Test func dongleKeysIncludeNameAndSerial() {
        #expect(DongleRegistry.key(for: StubDongle(serial: "00000001")) == "Generic RTL2832U 00000001")
        #expect(DongleRegistry.key(for: StubDongle(name: "Nooelec", serial: "00000001")) != DongleRegistry.key(for: StubDongle(serial: "00000001")))
    }
}
