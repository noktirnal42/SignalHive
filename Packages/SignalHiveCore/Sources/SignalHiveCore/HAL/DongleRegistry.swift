import Foundation

/// Who holds which dongle. A dongle can be opened by one thing at a time, and the Scanner, the Air Map receivers and the
/// Decoder Hub all want one, so each claims the device it opens and the others see the claim instead of a USB error.
///
/// The Scanner predates the registry and holds its dongle through `SDRDeviceManager.activeDevices`; the registry counts
/// that as a claim by "the Scanner" so the two stay consistent.
@MainActor
public final class DongleRegistry {
    public static let shared = DongleRegistry()

    /// How the Scanner is named as a holder: it holds its dongle through `SDRDeviceManager.activeDevices`, not by claiming.
    public static let scannerOwner = "the Scanner"

    public struct Busy: Error, LocalizedError, Equatable {
        public var deviceName: String
        public var holder: String

        public init(deviceName: String, holder: String) {
            self.deviceName = deviceName
            self.holder = holder
        }

        public var errorDescription: String? {
            "\(deviceName) is in use by \(holder). Stop it there first; only one program can hold a dongle."
        }
    }

    private var claims: [String: String] = [:]
    private let outsideHolder: ((String) -> String?)?

    /// - Parameter outsideHolder: Who else holds a device (by key). The default asks the device manager about the Scanner.
    public init(outsideHolder: ((String) -> String?)? = nil) {
        self.outsideHolder = outsideHolder
    }

    /// Two dongles of the same model often share a serial, so the name is part of the key; a second identical dongle is
    /// told apart by the order it is listed in (see `firstFree`).
    public nonisolated static func key(for device: any SDRDevice) -> String {
        device.name + " " + device.serial
    }

    /// The name of whatever holds the device now, if anything.
    public func holder(of device: any SDRDevice) -> String? {
        let key = Self.key(for: device)
        if let owner = claims[key] { return owner }
        if let outsideHolder { return outsideHolder(key) }
        return SDRDeviceManager.shared.activeDevices.contains { Self.key(for: $0) == key } ? Self.scannerOwner : nil
    }

    /// Takes the device for `owner`. Claiming what you already hold is fine.
    public func claim(_ device: any SDRDevice, owner: String) throws {
        if let current = holder(of: device), current != owner {
            throw Busy(deviceName: device.name, holder: current)
        }
        claims[Self.key(for: device)] = owner
    }

    /// Gives the device back. Only the holder can release it.
    public func release(_ device: any SDRDevice, owner: String) {
        let key = Self.key(for: device)
        if claims[key] == owner { claims[key] = nil }
    }

    public func releaseAll(owner: String) {
        claims = claims.filter { $0.value != owner }
    }

    /// The first of `devices` nobody else holds (one `owner` already holds counts as free).
    public func firstFree(in devices: [any SDRDevice], for owner: String? = nil) -> (any SDRDevice)? {
        devices.first { device in
            guard let current = holder(of: device) else { return true }
            return current == owner
        }
    }

    /// A sentence saying why none of `devices` can be had, for a status line.
    public func busyExplanation(for devices: [any SDRDevice]) -> String {
        let holders = devices.compactMap { holder(of: $0) }
        guard !holders.isEmpty else { return "No dongle is available." }
        let names = Array(Set(holders)).sorted()
        let who = names.joined(separator: " and ")
        return devices.count == 1
            ? "The dongle is in use by \(who). Stop it there first; only one program can hold it."
            : "Every dongle is in use (\(who)). Stop one of them, or plug in another RTL-SDR."
    }
}
