import Foundation

public enum PackStoreError: Error, LocalizedError, Equatable {
    case manifestUnavailable(String)
    case checksumMismatch
    case insufficientSpace(needed: Int64, available: Int64)
    case schemaTooNew(Int)
    case notInManifest(String)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case let .manifestUnavailable(reason):
            return "The data pack list is unavailable: \(reason)"
        case .checksumMismatch:
            return "The downloaded data pack was damaged in transit (checksum mismatch). Try again."
        case let .insufficientSpace(needed, available):
            let formatter = ByteCountFormatter()
            return "Not enough free space: \(formatter.string(fromByteCount: needed)) needed, \(formatter.string(fromByteCount: available)) available."
        case let .schemaTooNew(version):
            return "This data pack (format \(version)) needs a newer version of SignalHive. Update the app."
        case let .notInManifest(state):
            return "No data pack is published for \(state)."
        case let .corrupt(reason):
            return "The data pack is damaged: \(reason)"
        }
    }
}
