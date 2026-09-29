import Foundation

// MARK: - LocalPackService
//
// "Build from FCC on this Mac": downloads the selected FCC archives, runs the same PackBuilder the
// hosted build uses, and writes packs plus a manifest that PackStore can install through a
// `file://` base URL. Archives are always deleted afterwards.

public enum LocalPackError: Error, LocalizedError {
    case downloadFailed(service: ULSService, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .downloadFailed(service, reason):
            return "Could not download the FCC \(service.displayName) data: \(reason)"
        }
    }
}

public actor LocalPackService {
    private let workDirectory: URL
    private let outputDirectory: URL
    private let archiveURL: @Sendable (ULSService) -> URL
    private let availableBytes: @Sendable () -> Int64
    private let session: URLSession

    public init(
        workDirectory: URL,
        outputDirectory: URL,
        archiveURL: @escaping @Sendable (ULSService) -> URL = { $0.completeZipURL },
        availableBytes: @escaping @Sendable () -> Int64 = PackStore.systemAvailableBytes,
        session: URLSession = .shared
    ) {
        self.workDirectory = workDirectory
        self.outputDirectory = outputDirectory
        self.archiveURL = archiveURL
        self.availableBytes = availableBytes
        self.session = session
    }

    public func build(
        services: [ULSService],
        states: Set<String>?,
        progress: @escaping @Sendable (PackBuildProgress) -> Void
    ) async throws -> PackManifest {
        // Archives are the bulk of the disk use; the scratch database is smaller because only active
        // licenses are kept. Require twice the archive size.
        let archiveBytes = services.reduce(Int64(0)) { $0 + Int64($1.approximateSizeMB) * 1_048_576 }
        let needed = archiveBytes * 2
        let available = availableBytes()
        guard available >= needed else { throw PackStoreError.insufficientSpace(needed: needed, available: available) }

        let fileManager = FileManager.default
        let archives = workDirectory.appendingPathComponent("archives", isDirectory: true)
        try fileManager.createDirectory(at: archives, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: archives) }

        var zips: [URL] = []
        var modified: Date?
        for (index, service) in services.enumerated() {
            let base = Double(index) / Double(max(1, services.count)) * 0.5
            let span = 0.5 / Double(max(1, services.count))
            progress(PackBuildProgress(phase: "Downloading \(service.displayName)", fraction: base))
            let delegate = ProgressRelay { fraction in
                progress(PackBuildProgress(phase: "Downloading \(service.displayName)", fraction: base + span * fraction))
            }
            do {
                let (temporary, response) = try await session.download(from: archiveURL(service), delegate: delegate)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    try? fileManager.removeItem(at: temporary)
                    throw LocalPackError.downloadFailed(service: service, reason: "server returned HTTP \(http.statusCode)")
                }
                let destination = archives.appendingPathComponent("\(service.archiveName).zip")
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: temporary, to: destination)
                zips.append(destination)
                if modified == nil, let http = response as? HTTPURLResponse {
                    modified = Self.lastModified(http)
                }
            } catch let error as LocalPackError {
                throw error
            } catch {
                throw LocalPackError.downloadFailed(service: service, reason: error.localizedDescription)
            }
        }

        let snapshot = Self.snapshotString(modified ?? Date())
        let builder = PackBuilder(workDirectory: workDirectory.appendingPathComponent("build", isDirectory: true),
                                  outputDirectory: outputDirectory)
        let sources = zips.map { ZipTableSource(archiveURL: $0) }
        return try await Task.detached(priority: .userInitiated) {
            try builder.build(sources: sources, states: states, snapshotDate: snapshot) { update in
                progress(PackBuildProgress(phase: update.phase, fraction: 0.5 + 0.5 * update.fraction))
            }
        }.value
    }

    private static func lastModified(_ response: HTTPURLResponse) -> Date? {
        guard let header = response.value(forHTTPHeaderField: "Last-Modified") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header)
    }

    private static func snapshotString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private final class ProgressRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let handler: @Sendable (Double) -> Void

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        handler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
