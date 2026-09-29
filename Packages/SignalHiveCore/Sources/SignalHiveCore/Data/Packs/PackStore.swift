import Foundation
import CryptoKit

// MARK: - PackStore
//
// Downloads, verifies and installs state packs, and reports what is installed.
//
// Install flow: manifest entry → free-space check → download → SHA-256 → LZFSE decompress →
// open and validate (schema, state) → atomic move into place → remove older snapshots.
// Any failure leaves a previously installed pack untouched and cleans up temp files.

public actor PackStore {
    private let manifestBaseURL: URL?
    private let installDirectory: URL
    private let availableBytes: @Sendable () -> Int64
    private let session: URLSession
    private var manifest: PackManifest?
    private var transient: [String: PackStatus] = [:]

    public init(
        manifestBaseURL: URL?,
        installDirectory: URL,
        availableBytes: @escaping @Sendable () -> Int64 = PackStore.systemAvailableBytes,
        session: URLSession = .shared
    ) {
        self.manifestBaseURL = manifestBaseURL
        self.installDirectory = installDirectory
        self.availableBytes = availableBytes
        self.session = session
    }

    // MARK: Manifest

    @discardableResult
    public func refreshManifest() async throws -> PackManifest {
        guard let base = manifestBaseURL else {
            throw PackStoreError.manifestUnavailable("no data server is configured")
        }
        let url = base.appendingPathComponent(PackManifest.fileName)
        let data: Data
        do {
            let (body, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw PackStoreError.manifestUnavailable("server returned HTTP \(http.statusCode)")
            }
            data = body
        } catch let error as PackStoreError {
            throw error
        } catch {
            throw PackStoreError.manifestUnavailable(error.localizedDescription)
        }
        let decoded: PackManifest
        do {
            decoded = try JSONDecoder().decode(PackManifest.self, from: data)
        } catch {
            throw PackStoreError.manifestUnavailable("the pack list is malformed")
        }
        guard decoded.schemaVersion <= packSchemaVersion else {
            throw PackStoreError.schemaTooNew(decoded.schemaVersion)
        }
        manifest = decoded
        return decoded
    }

    // MARK: Availability

    public func availability() -> [StateAvailability] {
        let installed = installedFiles()
        var newest: [String: String] = [:]
        for file in installed where file.snapshot > (newest[file.state] ?? "") { newest[file.state] = file.snapshot }

        return USStateCatalog.states.map { state in
            let status: PackStatus
            let current = transient[state.code]
            if let current, case .downloading = current {
                status = current
            } else if let current, case .verifying = current {
                status = current
            } else if let snapshot = newest[state.code] {
                status = .installed(snapshot: snapshot)
            } else if let current {
                status = current                                   // .failed for a state that is not installed
            } else if let entry = manifest?.packs.first(where: { $0.stateCode == state.code }) {
                status = .notInstalled(sizeBytes: entry.compressedBytes)
            } else {
                status = .notInstalled(sizeBytes: nil)
            }
            return StateAvailability(code: state.code, name: state.name, status: status)
        }
    }

    public func installedStates() -> [String] {
        Array(Set(installedFiles().map(\.state))).sorted()
    }

    public func databaseURL(for state: String) -> URL? {
        installedFiles().filter { $0.state == state }.max { $0.snapshot < $1.snapshot }?.url
    }

    public func remove(state: String) throws {
        for file in installedFiles() where file.state == state {
            try FileManager.default.removeItem(at: file.url)
        }
        transient[state] = nil
    }

    // MARK: Install

    public func install(state: String, progress: @escaping @Sendable (PackStatus) -> Void) async throws {
        do {
            try await performInstall(state: state, progress: progress)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            transient[state] = .failed(reason: reason)
            progress(.failed(reason: reason))
            throw error
        }
    }

    private func performInstall(state: String, progress: @escaping @Sendable (PackStatus) -> Void) async throws {
        if manifest == nil { try await refreshManifest() }
        guard let manifest, let base = manifestBaseURL else {
            throw PackStoreError.manifestUnavailable("no data server is configured")
        }
        guard manifest.schemaVersion <= packSchemaVersion else { throw PackStoreError.schemaTooNew(manifest.schemaVersion) }
        guard let entry = manifest.packs.first(where: { $0.stateCode == state }) else {
            throw PackStoreError.notInManifest(state)
        }

        let needed = entry.compressedBytes + entry.expandedBytes * 2
        let available = availableBytes()
        guard available >= needed else { throw PackStoreError.insufficientSpace(needed: needed, available: available) }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let snapshotDigits = manifest.fccSnapshotDate.replacingOccurrences(of: "-", with: "")
        let downloadURL = installDirectory.appendingPathComponent("SH-\(state).download")
        let partialURL = installDirectory.appendingPathComponent("SH-\(state).partial")
        let finalURL = installDirectory.appendingPathComponent("SH-\(state)-\(snapshotDigits).sqlite")
        defer {
            try? fileManager.removeItem(at: downloadURL)
            try? fileManager.removeItem(at: partialURL)
        }

        transient[state] = .downloading(progress: 0)
        progress(.downloading(progress: 0))
        let delegate = DownloadProgress { fraction in progress(.downloading(progress: fraction)) }
        let (temporary, response) = try await session.download(
            from: base.appendingPathComponent(entry.fileName), delegate: delegate
        )
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? fileManager.removeItem(at: temporary)
            throw PackStoreError.manifestUnavailable("download failed: server returned HTTP \(http.statusCode)")
        }
        try? fileManager.removeItem(at: downloadURL)
        try fileManager.moveItem(at: temporary, to: downloadURL)

        transient[state] = .verifying
        progress(.verifying)
        guard try Self.sha256(of: downloadURL) == entry.sha256.lowercased() else {
            throw PackStoreError.checksumMismatch
        }
        let raw: Data
        do {
            raw = try (Data(contentsOf: downloadURL, options: .mappedIfSafe) as NSData).decompressed(using: .lzfse) as Data
        } catch {
            throw PackStoreError.corrupt("it could not be decompressed")
        }
        try raw.write(to: partialURL)

        let opened = try FrequencyStore(path: partialURL.path)      // validates schema and structure
        guard opened.stateCode == state else {
            throw PackStoreError.corrupt("it is for \(opened.stateCode), not \(state)")
        }

        if fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: finalURL)
        }
        for file in installedFiles() where file.state == state && file.url != finalURL {
            try? fileManager.removeItem(at: file.url)               // older snapshots
        }
        transient[state] = nil
        progress(.installed(snapshot: manifest.fccSnapshotDate))
    }

    // MARK: Helpers

    private struct InstalledFile {
        var state: String
        var snapshot: String       // yyyy-MM-dd
        var url: URL
    }

    /// Files named `SH-<ST>-<yyyymmdd>.sqlite`.
    private func installedFiles() -> [InstalledFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: installDirectory.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("SH-"), name.hasSuffix(".sqlite") else { return nil }
            let parts = name.dropLast(".sqlite".count).split(separator: "-")
            guard parts.count == 3, parts[2].count == 8, parts[2].allSatisfy(\.isNumber) else { return nil }
            let digits = String(parts[2])
            let snapshot = "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
            return InstalledFile(state: String(parts[1]), snapshot: snapshot,
                                 url: installDirectory.appendingPathComponent(name))
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func systemAvailableBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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
