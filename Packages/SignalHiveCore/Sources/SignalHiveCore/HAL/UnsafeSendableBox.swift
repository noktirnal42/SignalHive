import Foundation

/// Wraps a non-Sendable value for explicit unsafe cross-thread transfer.
/// Used only for raw C handles whose lifetime is managed externally.
struct UnsafeSendableBox<T>: @unchecked Sendable { let value: T }
