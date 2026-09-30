import Foundation

// MARK: - DataPlan
//
// "Get data" for several states at once. A state can come from a hosted pack (small, one file per state) or be built on
// this device from the FCC's own archives (large, but ONE download serves every state built in the same pass). The plan
// decides which route each requested state takes and what it will cost, so the person sees the whole job before it starts
// and the app never downloads the same FCC archive twice.

public enum DataSourcePreference: String, CaseIterable, Identifiable, Sendable {
    /// Hosted packs where one is published, the FCC build for the rest.
    case automatic
    /// Build every state on this device from the FCC's archives.
    case buildOnThisDevice

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return "Hosted packs, build the rest"
        case .buildOnThisDevice: return "Build from FCC data"
        }
    }
}

public struct DataPlan: Equatable, Sendable {
    public enum Route: Equatable, Sendable {
        /// A hosted pack.
        case download
        /// Built on this device from the FCC archives.
        case build
        case skip(SkipReason)
    }

    public enum SkipReason: Equatable, Sendable {
        case alreadyInstalled(snapshot: String)
        case inProgress
    }

    public struct Item: Equatable, Identifiable, Sendable {
        public var code: String
        public var name: String
        public var route: Route
        /// The hosted pack's size, when known.
        public var bytes: Int64?
        public var id: String { code }
    }

    public var items: [Item]
    /// Bytes of FCC archives one build pass fetches (0 when nothing is built).
    public var buildDownloadBytes: Int64

    public var downloads: [Item] { items.filter { $0.route == .download } }
    public var builds: [Item] { items.filter { $0.route == .build } }
    public var skipped: [Item] { items.filter { if case .skip = $0.route { return true } else { return false } } }
    public var isEmpty: Bool { downloads.isEmpty && builds.isEmpty }

    public var downloadBytes: Int64 { downloads.reduce(0) { $0 + ($1.bytes ?? 0) } }
    /// Everything that will cross the network.
    public var totalBytes: Int64 { downloadBytes + buildDownloadBytes }

    /// What the FCC archives would cost if each built state fetched them separately, and so what one pass saves.
    public var bytesSavedByOnePass: Int64 { buildDownloadBytes * Int64(max(0, builds.count - 1)) }

    /// - Parameters:
    ///   - requested: the states asked for, by code.
    ///   - states: every state and what it is now.
    ///   - hostedAvailable: whether the hosted pack list could be read.
    ///   - services: the FCC services a build includes.
    ///   - refreshInstalled: also redo states that are already installed (to update them).
    public static func make(requested: Set<String>, states: [StateAvailability], hostedAvailable: Bool,
                            preference: DataSourcePreference = .automatic, services: [ULSService],
                            refreshInstalled: Bool = false) -> DataPlan {
        var items: [Item] = []
        for state in states where requested.contains(state.code) {
            let route: Route
            var bytes: Int64?
            switch state.status {
            case let .installed(snapshot) where !refreshInstalled:
                route = .skip(.alreadyInstalled(snapshot: snapshot))
            case .downloading, .verifying:
                route = .skip(.inProgress)
            case let .notInstalled(size):
                if preference == .automatic, hostedAvailable, size != nil { route = .download; bytes = size } else { route = .build }
            case .failed, .installed:
                route = preference == .automatic && hostedAvailable ? .download : .build
            }
            items.append(Item(code: state.code, name: state.name, route: route, bytes: bytes))
        }
        let builds = items.filter { $0.route == .build }
        let archiveBytes = builds.isEmpty ? 0 : services.reduce(Int64(0)) { $0 + Int64($1.approximateSizeMB) * 1_048_576 }
        return DataPlan(items: items, buildDownloadBytes: archiveBytes)
    }

    /// One or two sentences saying what the job will do.
    public var summary: String {
        if items.isEmpty { return "Choose the states you want." }
        if isEmpty { return "Everything chosen is already installed or being installed." }
        var parts: [String] = []
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        if !downloads.isEmpty {
            let size = downloadBytes > 0 ? " (\(formatter.string(fromByteCount: downloadBytes)))" : ""
            parts.append("Download \(downloads.count) hosted pack\(downloads.count == 1 ? "" : "s")\(size).")
        }
        if !builds.isEmpty {
            let size = buildDownloadBytes > 0 ? " (\(formatter.string(fromByteCount: buildDownloadBytes)))" : ""
            var text = "Build \(builds.count) state\(builds.count == 1 ? "" : "s") from one download of the FCC archives\(size)"
            if builds.count > 1, bytesSavedByOnePass > 0 { text += ", saving \(formatter.string(fromByteCount: bytesSavedByOnePass)) over building them one by one" }
            parts.append(text + ".")
        }
        if !skipped.isEmpty { parts.append("\(skipped.count) already installed or in progress: skipped.") }
        return parts.joined(separator: " ")
    }
}
