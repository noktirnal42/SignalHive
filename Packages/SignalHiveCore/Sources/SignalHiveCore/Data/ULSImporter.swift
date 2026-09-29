import Foundation
import ZIPFoundation

// MARK: - ULS importer: download → unzip → parse → SQLite

public enum ULSImportError: Error, LocalizedError {
    case downloadFailed(String)
    case extractionFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .downloadFailed(url): return "Failed to download ULS archive: \(url)"
        case let .extractionFailed(path): return "Failed to extract ULS archive: \(path)"
        case .cancelled: return "Import cancelled"
        }
    }
}

public struct ULSImportProgress: Sendable {
    public var phase: Phase
    public var fraction: Double
    public var detail: String

    public enum Phase: String, Sendable {
        case downloading
        case extracting
        case parsing
        case writing
        case done
    }
}

public actor ULSImporter {
    private var cancelled = false
    private var progressHandler: (@Sendable (ULSImportProgress) -> Void)?

    public init() {}

    public func cancel() {
        cancelled = true
    }

    public func setProgressHandler(_ handler: @escaping @Sendable (ULSImportProgress) -> Void) {
        progressHandler = handler
    }

    private func report(_ phase: ULSImportProgress.Phase, _ fraction: Double, _ detail: String) {
        progressHandler?(ULSImportProgress(phase: phase, fraction: fraction, detail: detail))
    }

    /// Import one ULS service archive into the database.
    /// - Downloads the weekly complete ZIP.
    /// - Extracts the license-table .dat files.
    /// - Parses and writes records in batches.
    @discardableResult
    public func importService(_ service: ULSService, into database: AppDatabase) async throws -> Int {
        cancelled = false

        let archiveURL = try await download(service: service)
        guard !cancelled else { throw ULSImportError.cancelled }

        let tableURLs = try extract(archiveURL: archiveURL, service: service)
        guard !cancelled else { throw ULSImportError.cancelled }

        var total = 0
        for (index, url) in tableURLs.enumerated() {
            guard !cancelled else { throw ULSImportError.cancelled }
            report(.parsing, Double(index) / Double(max(1, tableURLs.count)), url.lastPathComponent)
            var batch = try ULSParser.parseTable(at: url)

            // Services without station-location tables (GMRS, aircraft) get
            // fallback locations derived from the licensee's entity address.
            if batch.locations.isEmpty, !batch.entities.isEmpty {
                batch.locations = batch.entities.map { entity in
                    ULSLocation(
                        uid: entity.uid,
                        locationNumber: 0,
                        city: entity.city,
                        county: entity.city,
                        state: entity.state,
                        latitude: 0,
                        longitude: 0
                    )
                }
            }

            guard !cancelled else { throw ULSImportError.cancelled }
            report(.writing, Double(index + 1) / Double(max(1, tableURLs.count)), "\(batch.count) records")
            try await database.writeBatch(batch, service: service, sourceURL: service.completeZipURL)
            total += batch.count
        }

        try? FileManager.default.removeItem(at: archiveURL)
        report(.done, 1.0, "\(total) records imported")
        return total
    }

    // MARK: Download

    private func download(service: ULSService) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let dest = tempDir.appendingPathComponent("\(service.archiveName).zip")
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }

        report(.downloading, 0, service.displayName)
        var request = URLRequest(url: service.completeZipURL)
        request.timeoutInterval = 600

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ULSImportError.downloadFailed(service.completeZipURL.absoluteString)
        }

        let expected = Double(http.expectedContentLength)
        var data = Data()
        data.reserveCapacity(max(1 << 20, Int(expected)))
        var lastReport = Date()

        for try await byte in bytes {
            if cancelled { throw ULSImportError.cancelled }
            data.append(byte)
            if Date().timeIntervalSince(lastReport) > 0.5, expected > 0 {
                lastReport = Date()
                report(.downloading, Double(data.count) / expected, "\(data.count / (1 << 20)) MB")
            }
        }

        try data.write(to: dest, options: .atomic)
        return dest
    }

    // MARK: Extract

    private func extract(archiveURL: URL, service: ULSService) throws -> [URL] {
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uls_\(service.archiveName)", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        do {
            try FileManager.default.unzipItem(at: archiveURL, to: extractDir)
        } catch {
            throw ULSImportError.extractionFailed(archiveURL.lastPathComponent)
        }

        report(.extracting, 1.0, "extracted")

        // The license tables live either at the root or in a `licenses/` folder.
        let wantedOrder = ["EN", "HD", "FR", "LO", "EM", "CO"]
        var found: [URL] = []
        for prefix in wantedOrder {
            if let url = findFile(named: "\(prefix).dat", in: extractDir) {
                found.append(url)
            }
        }
        return found
    }

    private func findFile(named name: String, in dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }
}
