import Testing
import Foundation
import CryptoKit
@testable import SignalHiveCore

// MARK: - Helpers

private func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("signalhive-models-\(UUID().uuidString)", isDirectory: true)
}

/// A model file: its bytes, and whether the Hub stores it with Git LFS (and so publishes a SHA-256).
private struct Blob {
    var path: String
    var data: Data
    var lfs: Bool

    init(_ path: String, _ text: String, lfs: Bool = false) {
        self.path = path
        self.data = Data(text.utf8)
        self.lfs = lfs
    }

    var listingEntry: String {
        if lfs {
            return #"{"type": "file", "path": "\#(path)", "size": \#(data.count), "oid": "deadbeef", "lfs": {"oid": "\#(hex(data))", "size": \#(data.count), "pointerSize": 134}}"#
        }
        return #"{"type": "file", "path": "\#(path)", "size": \#(data.count), "oid": "cafe"}"#
    }
}

private func listingJSON(_ blobs: [Blob], extra: String = #"{"type": "directory", "path": "onnx", "oid": "1"}"#) -> String {
    "[" + ([extra] + blobs.map(\.listingEntry)).joined(separator: ", ") + "]"
}

private let repoID = "mlx-community/Tiny-Test-4bit"
private let hub = URL(string: "https://hub.test")!

private func response(_ url: URL, status: Int = 200, headers: [String: String] = [:]) -> URLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
}

/// A hub that lists the given blobs for `repoID`.
private func client(listing json: String, status: Int = 200) -> ModelHubClient {
    ModelHubClient(baseURL: hub) { request in
        (Data(json.utf8), response(request.url!, status: status))
    }
}

private final class FakeTransport: ModelFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var served: [String: Data] = [:]
    private var requestedURLs: [String] = []
    private var failing: Set<String> = []
    private var cancelling: Set<String> = []

    init(_ blobs: [Blob]) {
        for blob in blobs { served["\(hub.absoluteString)/\(repoID)/resolve/main/\(blob.path)"] = blob.data }
    }

    /// Serves different bytes for a file, as a damaged download would.
    func corrupt(_ blob: Blob, with bytes: Data) {
        lock.lock(); served["\(hub.absoluteString)/\(repoID)/resolve/main/\(blob.path)"] = bytes; lock.unlock()
    }

    func serve(_ blob: Blob) {
        lock.lock(); served["\(hub.absoluteString)/\(repoID)/resolve/main/\(blob.path)"] = blob.data; lock.unlock()
    }

    func cancel(_ path: String) { lock.lock(); cancelling.insert(path); lock.unlock() }
    func stopCancelling() { lock.lock(); cancelling.removeAll(); lock.unlock() }
    func fail(_ path: String) { lock.lock(); failing.insert(path); lock.unlock() }

    var requested: [String] { lock.lock(); defer { lock.unlock() }; return requestedURLs }

    /// Notes the request and says how it should be answered. Synchronous, because NSLock cannot be used across an await.
    private func plan(for key: String) -> (data: Data?, mustCancel: Bool, mustFail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        requestedURLs.append(key)
        return (served[key],
                cancelling.contains { key.hasSuffix("/" + $0) },
                failing.contains { key.hasSuffix("/" + $0) })
    }

    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let key = url.absoluteString
        let (data, mustCancel, mustFail) = plan(for: key)
        if mustCancel { throw URLError(.cancelled) }
        if mustFail { throw URLError(.networkConnectionLost) }
        guard let data else { throw ModelDownloadError.downloadFailed(file: url.lastPathComponent, reason: "HTTP 404") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temporary)
        progress(Int64(data.count / 2))
        progress(Int64(data.count))
        return temporary
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ModelInstallProgress] = []
    func add(_ update: ModelInstallProgress) { lock.lock(); stored.append(update); lock.unlock() }
    var updates: [ModelInstallProgress] { lock.lock(); defer { lock.unlock() }; return stored }
}

private let config = Blob("config.json", #"{"model_type": "llama"}"#)
private let tokenizer = Blob("tokenizer/tokenizer.json", String(repeating: "t", count: 300))
private let weights = Blob("model.safetensors", String(repeating: "w", count: 5_000), lfs: true)

private func makeManager(_ directory: URL, blobs: [Blob], transport: FakeTransport, space: Int64 = .max) -> ModelDownloadManager {
    ModelDownloadManager(directory: directory, client: client(listing: listingJSON(blobs)), transport: transport, availableBytes: { space })
}

// MARK: - Names, listings and links

struct HubListingTests {
    static let goodNames = ["mlx-community/Llama-3.2-1B-Instruct-4bit", "a/b", "Org_1/model.v2-final"]
    static let badNames = ["", "noslash", "a/b/c", "../x", "a/..", "own er/x", "a/b c", "/a/b", "a/", "é/x"]

    @Test(arguments: HubListingTests.goodNames)
    func repositoryNamesAreAccepted(name: String) throws {
        let repo = try #require(HubRepositoryID(name))
        #expect(repo.description == name)
        #expect(!repo.directoryName.contains("/"))
    }

    @Test(arguments: HubListingTests.badNames)
    func otherNamesAreRefused(name: String) {
        #expect(HubRepositoryID(name) == nil)
    }

    @Test func aListingKeepsFilesAndTheirChecksums() throws {
        let json = listingJSON([config, weights, tokenizer])
        let files = try HubListingParser.files(from: Data(json.utf8))
        #expect(files.map(\.path) == ["config.json", "model.safetensors", "tokenizer/tokenizer.json"], "directories are skipped, files sorted")
        #expect(files[0].sha256 == nil, "a small file has only a size")
        #expect(files[1].sha256 == hex(weights.data))
        #expect(files[1].size == 5_000)
    }

    @Test func aBadChecksumIsNotTrusted() throws {
        let json = #"[{"type": "file", "path": "w.bin", "size": 10, "lfs": {"oid": "not-a-digest", "size": 10}}]"#
        let files = try HubListingParser.files(from: Data(json.utf8))
        #expect(files.count == 1 && files[0].sha256 == nil && files[0].size == 10)
    }

    @Test func somethingThatIsNotAListIsAnError() {
        #expect(throws: ModelDownloadError.self) { try HubListingParser.files(from: Data(#"{"error": "nope"}"#.utf8)) }
        #expect(throws: ModelDownloadError.self) { try HubListingParser.files(from: Data("not json".utf8)) }
    }

    @Test func theNextPageComesFromTheLinkHeader() {
        let header = #"<https://hub.test/api/models/o/m/tree/main?recursive=true&cursor=abc>; rel="next", <https://hub.test/x>; rel="prev""#
        #expect(HubListingParser.nextPage(inLinkHeader: header)?.absoluteString == "https://hub.test/api/models/o/m/tree/main?recursive=true&cursor=abc")
        #expect(HubListingParser.nextPage(inLinkHeader: #"<https://hub.test/x>; rel="prev""#) == nil)
        #expect(HubListingParser.nextPage(inLinkHeader: nil) == nil)
        #expect(HubListingParser.nextPage(inLinkHeader: "garbage") == nil)
    }

    @Test func onlyPathsInsideTheModelFolderAreSafe() {
        for path in ["model.safetensors", "sub/dir/file.json", "a.b/c"] { #expect(HubListingParser.isSafe(path: path), "\(path)") }
        for path in ["", "../x", "/abs", "a/../b", "a//b", "./a", "a\\b", "a/"] { #expect(!HubListingParser.isSafe(path: path), "\(path)") }
    }
}

struct ModelHubClientTests {
    @Test func aListingContinuesThroughPages() async throws {
        let calls = CallLog()
        let client = ModelHubClient(baseURL: hub) { request in
            calls.add(request.url!.absoluteString)
            let url = request.url!
            if url.query?.contains("cursor=2") == true {
                return (Data(listingJSON([weights], extra: "{}").utf8), response(url))
            }
            return (Data(listingJSON([config], extra: "{}").utf8),
                    response(url, headers: ["Link": #"<https://hub.test/api/models/mlx-community/Tiny-Test-4bit/tree/main?recursive=true&cursor=2>; rel="next""#]))
        }
        let repo = try #require(HubRepositoryID(repoID))
        let files = try await client.listFiles(in: repo)
        #expect(files.map(\.path) == ["config.json", "model.safetensors"])
        #expect(calls.urls.count == 2)
        #expect(calls.urls[0] == "https://hub.test/api/models/mlx-community/Tiny-Test-4bit/tree/main?recursive=true")
    }

    @Test func statusCodesBecomeUsefulErrors() async throws {
        let repo = try #require(HubRepositoryID(repoID))
        await #expect(throws: ModelDownloadError.notFound(repoID)) { try await client(listing: "{}", status: 404).listFiles(in: repo) }
        await #expect(throws: ModelDownloadError.accessDenied(repoID)) { try await client(listing: "{}", status: 401).listFiles(in: repo) }
        await #expect(throws: ModelDownloadError.accessDenied(repoID)) { try await client(listing: "{}", status: 403).listFiles(in: repo) }
        await #expect(throws: ModelDownloadError.listingFailed("HTTP 503")) { try await client(listing: "{}", status: 503).listFiles(in: repo) }
    }

    @Test func aDeadNetworkIsAListingFailure() async throws {
        let repo = try #require(HubRepositoryID(repoID))
        let offline = ModelHubClient(baseURL: hub) { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: ModelDownloadError.self) { try await offline.listFiles(in: repo) }
    }

    @Test func fileAddressesEscapeEachPathPiece() throws {
        let repo = try #require(HubRepositoryID(repoID))
        let url = ModelHubClient(baseURL: hub).fileURL(in: repo, path: "sub dir/a b.json")
        #expect(url?.absoluteString == "https://hub.test/mlx-community/Tiny-Test-4bit/resolve/main/sub%20dir/a%20b.json")
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ url: String) { lock.lock(); stored.append(url); lock.unlock() }
    var urls: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

// MARK: - Installing

struct ModelDownloadManagerTests {
    @Test func aModelDownloadsVerifiesAndBecomesInstalled() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = [config, tokenizer, weights]
        let transport = FakeTransport(blobs)
        let manager = makeManager(directory, blobs: blobs, transport: transport)
        let log = ProgressLog()

        let record = try await manager.install(repoID) { log.add($0) }
        #expect(record.repoID == repoID)
        #expect(record.files.count == 3)
        #expect(record.totalBytes == Int64(config.data.count + tokenizer.data.count + weights.data.count))

        let folder = manager.folder(for: try #require(HubRepositoryID(repoID)))
        #expect(try Data(contentsOf: folder.appendingPathComponent("model.safetensors")) == weights.data)
        #expect(try Data(contentsOf: folder.appendingPathComponent("tokenizer/tokenizer.json")) == tokenizer.data, "sub-folders are kept")
        #expect(await manager.installedModel(repoID)?.files == record.files)
        #expect(await manager.installedModels().map(\.repoID) == [repoID])
        #expect(await manager.stagedBytes(repoID) == 0, "the staging folder became the model folder")

        let updates = log.updates
        #expect(updates.first?.phase == .listing)
        #expect(updates.last?.phase == .finishing)
        #expect(updates.last?.fraction == 1)
        let downloading = updates.filter { $0.phase == .downloading }
        #expect(downloading.map(\.bytesDone) == downloading.map(\.bytesDone).sorted(), "progress never goes backwards")
        #expect(downloading.contains { $0.currentFile == "model.safetensors" })
    }

    @Test func aModelAlreadyInstalledIsNotFetchedAgain() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = [config, weights]
        let transport = FakeTransport(blobs)
        let manager = makeManager(directory, blobs: blobs, transport: transport)
        try await manager.install(repoID) { _ in }
        let first = transport.requested.count
        try await manager.install(repoID) { _ in }
        #expect(transport.requested.count == first)
    }

    @Test func aDamagedFileIsRejectedAndTheGoodOnesAreKeptForTheRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = [config, weights]
        let transport = FakeTransport(blobs)
        transport.corrupt(weights, with: Data(String(repeating: "x", count: 5_000).utf8))        // right size, wrong bytes
        let manager = makeManager(directory, blobs: blobs, transport: transport)

        await #expect(throws: ModelDownloadError.checksumMismatch(file: "model.safetensors")) { try await manager.install(repoID) { _ in } }
        #expect(await manager.installedModel(repoID) == nil, "a failed download is never reported as installed")
        #expect(await manager.stagedBytes(repoID) == Int64(config.data.count), "the good file stays in staging")

        transport.serve(weights)
        let before = transport.requested.count
        try await manager.install(repoID) { _ in }
        let fetched = Array(transport.requested.dropFirst(before))
        #expect(fetched.count == 1 && fetched[0].hasSuffix("model.safetensors"), "only the missing file is fetched again")
        #expect(await manager.installedModel(repoID) != nil)
    }

    @Test func aShortFileIsRejectedBySize() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FakeTransport([config])
        transport.corrupt(config, with: Data("{".utf8))
        let manager = makeManager(directory, blobs: [config], transport: transport)
        await #expect(throws: ModelDownloadError.sizeMismatch(file: "config.json", expected: Int64(config.data.count), actual: 1)) {
            try await manager.install(repoID) { _ in }
        }
    }

    @Test func aNetworkFailureNamesTheFileAndKeepsTheRest() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = [config, tokenizer, weights]
        let transport = FakeTransport(blobs)
        transport.fail("model.safetensors")
        let manager = makeManager(directory, blobs: blobs, transport: transport)
        do {
            try await manager.install(repoID) { _ in }
            Issue.record("the download should have failed")
        } catch let error as ModelDownloadError {
            guard case let .downloadFailed(file, _) = error else { Issue.record("wrong error \(error)"); return }
            #expect(file == "model.safetensors")
        }
        #expect(await manager.stagedBytes(repoID) == Int64(config.data.count + tokenizer.data.count))
    }

    @Test func cancellingStopsAndResumingContinues() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = [config, weights]
        let transport = FakeTransport(blobs)
        transport.cancel("model.safetensors")
        let manager = makeManager(directory, blobs: blobs, transport: transport)
        await #expect(throws: CancellationError.self) { try await manager.install(repoID) { _ in } }
        #expect(await manager.installedModel(repoID) == nil)

        transport.stopCancelling()
        let before = transport.requested.count
        try await manager.install(repoID) { _ in }
        #expect(transport.requested.dropFirst(before).count == 1, "config.json was already there")
    }

    @Test func notEnoughSpaceIsReportedBeforeDownloading() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FakeTransport([config, weights])
        let manager = makeManager(directory, blobs: [config, weights], transport: transport, space: 1_000)
        do {
            try await manager.install(repoID) { _ in }
            Issue.record("expected insufficient space")
        } catch let error as ModelDownloadError {
            guard case let .insufficientSpace(needed, available) = error else { Issue.record("wrong error \(error)"); return }
            #expect(available == 1_000 && needed > 5_000)
        }
        #expect(transport.requested.isEmpty)
    }

    @Test func aListingThatEscapesTheFolderIsRefused() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let evil = Blob("../../outside.txt", "nope")
        let transport = FakeTransport([evil])
        let manager = makeManager(directory, blobs: [config, evil], transport: transport)
        await #expect(throws: ModelDownloadError.unsafePath("../../outside.txt")) { try await manager.install(repoID) { _ in } }
        #expect(transport.requested.isEmpty)
    }

    @Test func aFileCannotReplaceTheManifest() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sneaky = Blob(ModelDownloadManager.manifestName, "{}")
        let manager = makeManager(directory, blobs: [sneaky], transport: FakeTransport([sneaky]))
        await #expect(throws: ModelDownloadError.self) { try await manager.install(repoID) { _ in } }
    }

    @Test func aBadRepositoryNameAndAnEmptyRepositoryAreErrors() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = makeManager(directory, blobs: [], transport: FakeTransport([]))
        await #expect(throws: ModelDownloadError.invalidRepository("../etc")) { try await manager.install("../etc") { _ in } }
        await #expect(throws: ModelDownloadError.emptyRepository(repoID)) { try await manager.install(repoID) { _ in } }
    }

    @Test func removingDeletesTheModelAndAnyLeftovers() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = [config, weights]
        let transport = FakeTransport(blobs)
        let manager = makeManager(directory, blobs: blobs, transport: transport)
        try await manager.install(repoID) { _ in }
        try await manager.remove(repoID)
        #expect(await manager.installedModel(repoID) == nil)
        #expect(await manager.installedModels().isEmpty)
        try await manager.remove(repoID)        // removing what is not there is fine
    }

    @Test func staleFilesFromAnOlderAttemptAreNotKept() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blobs = [config, weights]
        let transport = FakeTransport(blobs)
        let manager = makeManager(directory, blobs: blobs, transport: transport)
        let repo = try #require(HubRepositoryID(repoID))
        let staging = directory.appendingPathComponent(".partial/\(repo.directoryName)/old", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: staging.appendingPathComponent("leftover.bin"))

        try await manager.install(repoID) { _ in }
        let folder = manager.folder(for: repo)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("old/leftover.bin").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path))
    }

    @Test func installedModelsAreListedByName() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = FakeTransport([config])
        let first = ModelDownloadManager(directory: directory, client: client(listing: listingJSON([config])), transport: transport,
                                         availableBytes: { .max })
        try await first.install(repoID) { _ in }
        // A second instance over the same folder sees the same models (it reads the manifests, it does not remember them).
        let second = ModelDownloadManager(directory: directory, availableBytes: { .max })
        #expect(await second.installedModels().map(\.repoID) == [repoID])
        #expect(await second.installedModel("nope/none") == nil)
        #expect(await second.installedModel("../bad") == nil)
    }
}
