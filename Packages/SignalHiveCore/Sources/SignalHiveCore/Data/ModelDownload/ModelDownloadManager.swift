import Foundation
import CryptoKit

// MARK: - Downloading and keeping model repositories
//
// A repository is downloaded file by file into a staging folder. A file is checked (its size, and its SHA-256 when the
// Hub publishes one) before it counts, and files that already arrived are not fetched again, so an interrupted or
// cancelled download resumes at the file it stopped on. Only when every file is in does the staging folder become the
// model's folder, with a small manifest saying what is in it, so a half-downloaded model is never mistaken for a
// finished one.

/// How a file is fetched. The default uses URLSession; tests supply their own.
public protocol ModelFileTransport: Sendable {
    /// Downloads `url` to a temporary file and returns it. `progress` gets the number of bytes received so far.
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

public struct URLSessionFileTransport: ModelFileTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let relay = ByteProgressRelay(handler: progress)
        let (temporary, response) = try await session.download(for: request, delegate: relay)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: temporary)
            throw ModelDownloadError.downloadFailed(file: url.lastPathComponent, reason: "HTTP \(http.statusCode)")
        }
        return temporary
    }
}

private final class ByteProgressRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let handler: @Sendable (Int64) -> Void

    init(handler: @escaping @Sendable (Int64) -> Void) {
        self.handler = handler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        handler(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public struct ModelInstallProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case listing
        case downloading
        case finishing
    }

    public var phase: Phase
    /// 1-based position of the file being fetched.
    public var fileIndex: Int
    public var fileCount: Int
    public var currentFile: String
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }

    public init(phase: Phase, fileIndex: Int = 0, fileCount: Int = 0, currentFile: String = "", bytesDone: Int64 = 0, bytesTotal: Int64 = 0) {
        self.phase = phase
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.currentFile = currentFile
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }
}

/// A finished download, as recorded in its folder.
public struct InstalledModel: Codable, Equatable, Sendable, Identifiable {
    public var repoID: String
    public var revision: String
    public var files: [HubFile]
    public var installedAt: Date
    public var id: String { repoID }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public actor ModelDownloadManager {
    public static let manifestName = "signalhive-model.json"

    private let directory: URL
    private let client: ModelHubClient
    private let transport: any ModelFileTransport
    private let availableBytes: @Sendable () -> Int64
    private let fileManager = FileManager.default

    /// - Parameter directory: where models live, one folder per repository.
    public init(directory: URL, client: ModelHubClient = ModelHubClient(), transport: any ModelFileTransport = URLSessionFileTransport(),
                availableBytes: @escaping @Sendable () -> Int64 = PackStore.systemAvailableBytes) {
        self.directory = directory
        self.client = client
        self.transport = transport
        self.availableBytes = availableBytes
    }

    /// `Application Support/SignalHive/Models`.
    public static var standardDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SignalHive/Models", isDirectory: true)
    }

    // MARK: Where things are

    public nonisolated func folder(for repo: HubRepositoryID) -> URL {
        directory.appendingPathComponent(repo.directoryName, isDirectory: true)
    }

    private func stagingFolder(for repo: HubRepositoryID) -> URL {
        directory.appendingPathComponent(".partial", isDirectory: true).appendingPathComponent(repo.directoryName, isDirectory: true)
    }

    // MARK: What is installed

    public func installedModel(_ repoID: String) -> InstalledModel? {
        guard let repo = HubRepositoryID(repoID) else { return nil }
        return readManifest(in: folder(for: repo))
    }

    public func installedModels() -> [InstalledModel] {
        let children = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { readManifest(in: $0) }
            .sorted { $0.repoID < $1.repoID }
    }

    /// Bytes already downloaded toward a repository that is not finished (what a resume will not fetch again).
    public func stagedBytes(_ repoID: String) -> Int64 {
        guard let repo = HubRepositoryID(repoID) else { return 0 }
        return Self.size(ofFilesIn: stagingFolder(for: repo))
    }

    public func remove(_ repoID: String) throws {
        guard let repo = HubRepositoryID(repoID) else { throw ModelDownloadError.invalidRepository(repoID) }
        for url in [folder(for: repo), stagingFolder(for: repo)] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: Installing

    /// Downloads every file of a repository and returns the record of it. Cancelling the task keeps what has arrived.
    @discardableResult
    public func install(_ repoID: String, revision: String = "main",
                        progress: @escaping @Sendable (ModelInstallProgress) -> Void) async throws -> InstalledModel {
        guard let repo = HubRepositoryID(repoID) else { throw ModelDownloadError.invalidRepository(repoID) }
        progress(ModelInstallProgress(phase: .listing))
        let files = try await client.listFiles(in: repo, revision: revision)
        guard !files.isEmpty else { throw ModelDownloadError.emptyRepository(repoID) }
        if let unsafe = files.first(where: { !HubListingParser.isSafe(path: $0.path) || $0.path == Self.manifestName }) {
            throw ModelDownloadError.unsafePath(unsafe.path)
        }

        // Already installed exactly as listed: nothing to do.
        if let existing = readManifest(in: folder(for: repo)), existing.files == files, existing.revision == revision {
            return existing
        }

        let staging = stagingFolder(for: repo)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let alreadyThere = files.reduce(Int64(0)) { sum, file in
            sum + (Self.size(ofFileAt: staging.appendingPathComponent(file.path)) == file.size ? file.size : 0)
        }
        let needed = total - alreadyThere + 64 * 1_048_576
        let available = availableBytes()
        guard available >= needed else { throw ModelDownloadError.insufficientSpace(needed: needed, available: available) }

        var done: Int64 = 0
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            let position = index + 1
            if Self.size(ofFileAt: destination) == file.size {
                done += file.size
                progress(ModelInstallProgress(phase: .downloading, fileIndex: position, fileCount: files.count, currentFile: file.path,
                                              bytesDone: done, bytesTotal: total))
                continue
            }
            guard let url = client.fileURL(in: repo, path: file.path, revision: revision) else { throw ModelDownloadError.unsafePath(file.path) }
            let base = done
            progress(ModelInstallProgress(phase: .downloading, fileIndex: position, fileCount: files.count, currentFile: file.path,
                                          bytesDone: base, bytesTotal: total))
            let temporary: URL
            do {
                temporary = try await transport.download(url) { received in
                    progress(ModelInstallProgress(phase: .downloading, fileIndex: position, fileCount: files.count, currentFile: file.path,
                                                  bytesDone: base + min(received, max(file.size, 0)), bytesTotal: total))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ModelDownloadError {
                throw error
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw ModelDownloadError.downloadFailed(file: file.path, reason: error.localizedDescription)
            }
            defer { try? fileManager.removeItem(at: temporary) }

            try Self.verify(temporary, against: file)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
            done += file.size
        }

        Self.prune(staging, keeping: Set(files.map(\.path)))
        progress(ModelInstallProgress(phase: .finishing, fileIndex: files.count, fileCount: files.count, bytesDone: total, bytesTotal: total))
        let record = InstalledModel(repoID: repo.description, revision: revision, files: files, installedAt: Date())
        try JSONEncoder().encode(record).write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)
        let final = folder(for: repo)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: final.path) { try fileManager.removeItem(at: final) }
        try fileManager.moveItem(at: staging, to: final)
        return record
    }

    // MARK: Checks

    static func verify(_ url: URL, against file: HubFile) throws {
        let actual = size(ofFileAt: url)
        if file.size > 0, actual != file.size {
            throw ModelDownloadError.sizeMismatch(file: file.path, expected: file.size, actual: actual)
        }
        if let expected = file.sha256, try sha256(of: url) != expected {
            throw ModelDownloadError.checksumMismatch(file: file.path)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func size(ofFileAt url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return -1 }
        return size.int64Value
    }

    private static func size(ofFilesIn folder: URL) -> Int64 {
        files(in: folder).reduce(0) { $0 + max(0, size(ofFileAt: $1.url)) }
    }

    /// Every regular file under a folder, with its path relative to the folder (built by walking, so no path arithmetic
    /// can go wrong with symbolic links such as /var and /private/var).
    private static func files(in folder: URL, prefix: String = "") -> [(relative: String, url: URL)] {
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var result: [(relative: String, url: URL)] = []
        for child in children {
            let name = child.lastPathComponent
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result += files(in: child, prefix: prefix + name + "/")
            } else {
                result.append((prefix + name, child))
            }
        }
        return result
    }

    /// Removes files a resumed download left behind that the repository no longer lists.
    private static func prune(_ folder: URL, keeping paths: Set<String>) {
        for entry in files(in: folder) where !paths.contains(entry.relative) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    private func readManifest(in folder: URL) -> InstalledModel? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.manifestName)) else { return nil }
        return try? JSONDecoder().decode(InstalledModel.self, from: data)
    }
}
