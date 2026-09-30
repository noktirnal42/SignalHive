import Foundation

// MARK: - Hugging Face Hub: which files make up a model repository
//
// The Hub lists a repository's files at  GET /api/models/<owner>/<name>/tree/<revision>?recursive=true  as a JSON array:
//   [{"type": "file", "path": "model.safetensors", "size": 4529, "oid": "<git blob sha1>",
//     "lfs": {"oid": "<sha256 of the content>", "size": 4529, "pointerSize": 134}},
//    {"type": "directory", "path": "onnx", ...}, ...]
// Large files (the weights) are stored with Git LFS and carry a SHA-256, so they can be verified after the download; small
// files have only a size. A file's bytes come from  GET /<owner>/<name>/resolve/<revision>/<path>  (which redirects to a
// CDN). Long listings continue in a `Link: <...>; rel="next"` header.

/// "owner/name", validated so it can be used in URLs and as a directory name.
public struct HubRepositoryID: Hashable, Sendable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, Self.isValid(parts[0]), Self.isValid(parts[1]) else { return nil }
        owner = parts[0]
        name = parts[1]
    }

    private static func isValid(_ part: String) -> Bool {
        guard !part.isEmpty, part.count <= 96, part != ".", part != ".." else { return false }
        return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    public var description: String { "\(owner)/\(name)" }
    /// A single directory name for this repository.
    public var directoryName: String { "\(owner)__\(name)" }
}

/// One file of a repository.
public struct HubFile: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int64
    /// SHA-256 of the content (lowercase hex) when the Hub publishes one.
    public var sha256: String?

    public init(path: String, size: Int64, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

public enum ModelDownloadError: Error, LocalizedError, Equatable {
    case invalidRepository(String)
    case accessDenied(String)
    case notFound(String)
    case listingFailed(String)
    case unsafePath(String)
    case emptyRepository(String)
    case downloadFailed(file: String, reason: String)
    case sizeMismatch(file: String, expected: Int64, actual: Int64)
    case checksumMismatch(file: String)
    case insufficientSpace(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case let .invalidRepository(text):
            return "\"\(text)\" is not a Hugging Face repository name (owner/name)."
        case let .accessDenied(repo):
            return "\(repo) is private or gated. Accept its license on huggingface.co first; signed-in downloads are not supported yet."
        case let .notFound(repo):
            return "\(repo) was not found on Hugging Face."
        case let .listingFailed(reason):
            return "Could not list the model's files: \(reason)"
        case let .unsafePath(path):
            return "The repository lists a file path that is not allowed (\(path)); nothing was downloaded."
        case let .emptyRepository(repo):
            return "\(repo) has no files."
        case let .downloadFailed(file, reason):
            return "Could not download \(file): \(reason)"
        case let .sizeMismatch(file, expected, actual):
            return "\(file) arrived damaged (expected \(expected) bytes, got \(actual)). Try again."
        case let .checksumMismatch(file):
            return "\(file) failed its checksum. Try again."
        case let .insufficientSpace(needed, available):
            let formatter = ByteCountFormatter()
            return "Not enough free space: \(formatter.string(fromByteCount: needed)) needed, \(formatter.string(fromByteCount: available)) available."
        }
    }
}

/// Turns the Hub's JSON into files. It touches no network, so it is tested with fixtures.
public enum HubListingParser {
    public static func files(from data: Data) throws -> [HubFile] {
        guard let root = try? JSONSerialization.jsonObject(with: data), let entries = root as? [[String: Any]] else {
            throw ModelDownloadError.listingFailed("the answer is not a list of files")
        }
        var files: [HubFile] = []
        for entry in entries where (entry["type"] as? String) == "file" {
            guard let path = entry["path"] as? String else { continue }
            let lfs = entry["lfs"] as? [String: Any]
            let size = int64(lfs?["size"]) ?? int64(entry["size"]) ?? 0
            var digest: String?
            if let oid = (lfs?["oid"] as? String)?.lowercased(), oid.count == 64, oid.allSatisfy(\.isHexDigit) { digest = oid }
            files.append(HubFile(path: path, size: size, sha256: digest))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The URL of the next page of a listing, from a `Link` header.
    public static func nextPage(inLinkHeader header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == "rel=\"next\"" }),
                  pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">") else { continue }
            return URL(string: String(pieces[0].dropFirst().dropLast()))
        }
        return nil
    }

    /// A path from a listing is used to build a file location, so anything that could leave the model's directory is refused.
    public static func isSafe(path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != ".." && $0 != "." && !$0.isEmpty }
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }
}

public struct ModelHubClient: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL
    private let fetch: Fetch
    /// A safety stop for a listing that never ends.
    private static let maximumPages = 50

    public init(baseURL: URL = URL(string: "https://huggingface.co")!,
                fetch: @escaping Fetch = { request in try await URLSession.shared.data(for: request) }) {
        self.baseURL = baseURL
        self.fetch = fetch
    }

    public func listFiles(in repo: HubRepositoryID, revision: String = "main") async throws -> [HubFile] {
        var next: URL? = URL(string: baseURL.absoluteString + "/api/models/\(repo.owner)/\(repo.name)/tree/\(Self.encode(revision))?recursive=true")
        var files: [HubFile] = []
        var pages = 0
        while let url = next, pages < Self.maximumPages {
            pages += 1
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await fetch(request)
            } catch {
                if error is CancellationError { throw error }
                throw ModelDownloadError.listingFailed(error.localizedDescription)
            }
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 200 {
            case 200: break
            case 401, 403: throw ModelDownloadError.accessDenied(repo.description)
            case 404: throw ModelDownloadError.notFound(repo.description)
            case let status: throw ModelDownloadError.listingFailed("HTTP \(status)")
            }
            files += try HubListingParser.files(from: data)
            next = HubListingParser.nextPage(inLinkHeader: http?.value(forHTTPHeaderField: "Link"))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Where a file's bytes are.
    public func fileURL(in repo: HubRepositoryID, path: String, revision: String = "main") -> URL? {
        let encodedPath = path.split(separator: "/", omittingEmptySubsequences: false).map { Self.encode(String($0)) }.joined(separator: "/")
        return URL(string: baseURL.absoluteString + "/\(repo.owner)/\(repo.name)/resolve/\(Self.encode(revision))/\(encodedPath)")
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
