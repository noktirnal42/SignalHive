import Foundation

/// What a load of element sets produced and where it came from, so the screen can say so.
public struct ElementLoad: Sendable {
    public enum Source: Sendable, Equatable {
        case network
        /// The saved copy is under two hours old, so the network was not asked.
        case cacheTooSoonToRefetch
        /// The network failed (the reason is readable); the saved copy is shown.
        case cacheAfterFailure(String)
        /// Nothing saved and nothing from the network (the reason is readable).
        case none(String)
    }

    public var elements: [OrbitalElements]
    public var fetchedAt: Date?
    public var source: Source
    /// Rows the feed sent that were not usable element sets.
    public var rejectedRows: Int

    public init(elements: [OrbitalElements], fetchedAt: Date?, source: Source, rejectedRows: Int) {
        self.elements = elements
        self.fetchedAt = fetchedAt
        self.source = source
        self.rejectedRows = rejectedRows
    }
}

/// CelesTrak GP (OMM) element sets with a saved copy on disk. CelesTrak asks for at most one download of the same data
/// per update, about every two hours, so a copy younger than `minimumRefetchInterval` is never replaced by a request,
/// whoever asks (the Update button included). A bad answer never replaces a good copy.
public actor ElementStore {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct CacheFile: Codable {
        var fetchedAt: Date
        var elements: [OrbitalElements]
        var rejected: Int
    }

    private struct Failure: Error { let message: String }

    private let directory: URL
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let minimumRefetchInterval: TimeInterval

    public init(directory: URL,
                fetch: @escaping Fetch = { request in try await URLSession.shared.data(for: request) },
                now: @escaping @Sendable () -> Date = { Date() },
                minimumRefetchInterval: TimeInterval = 7200) {
        self.directory = directory
        self.fetch = fetch
        self.now = now
        self.minimumRefetchInterval = minimumRefetchInterval
    }

    public static func url(forGroup group: String) -> URL {
        var components = URLComponents(string: "https://celestrak.org/NORAD/elements/gp.php")!
        components.queryItems = [URLQueryItem(name: "GROUP", value: group), URLQueryItem(name: "FORMAT", value: "json")]
        return components.url!
    }

    /// The elements of one CelesTrak group. `forceRefresh` is an explicit request (the Update button): it fetches if the
    /// saved copy is old enough and is refused, like any other load, inside the two-hour floor.
    public func elements(group: String, forceRefresh: Bool = false) async -> ElementLoad {
        let name = "group-\(Self.safeName(group))"
        let cached = readCache(name)
        let current = now()
        if let cached, (0..<minimumRefetchInterval).contains(current.timeIntervalSince(cached.fetchedAt)) {
            return ElementLoad(elements: cached.elements, fetchedAt: cached.fetchedAt, source: .cacheTooSoonToRefetch,
                               rejectedRows: cached.rejected)
        }
        do {
            var request = URLRequest(url: Self.url(forGroup: group))
            request.timeoutInterval = 30
            request.setValue("SignalHive (macOS radio workbench; github.com/noktirnal42/SignalHive)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await fetch(request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let hint = http.statusCode == 429 ? " (too many requests)" : ""
                throw Failure(message: "CelesTrak answered HTTP \(http.statusCode)\(hint)")
            }
            let parsed: ElementParser.Result
            do {
                parsed = try ElementParser.parseOMMJSON(data)
            } catch let error as ElementParser.ParseError {
                throw Failure(message: error.message)
            }
            guard !parsed.elements.isEmpty else {
                let detail = parsed.rejected.isEmpty ? "the list was empty" : "all \(parsed.rejected.count) rows were unusable"
                throw Failure(message: "CelesTrak sent no usable element sets (\(detail))")
            }
            let file = CacheFile(fetchedAt: current, elements: parsed.elements, rejected: parsed.rejected.count)
            writeCache(file, name)
            return ElementLoad(elements: parsed.elements, fetchedAt: current, source: .network, rejectedRows: parsed.rejected.count)
        } catch {
            let reason = (error as? Failure)?.message ?? "Could not reach CelesTrak (\(Self.readable(error)))"
            if let cached {
                return ElementLoad(elements: cached.elements, fetchedAt: cached.fetchedAt,
                                   source: .cacheAfterFailure("\(reason); showing the copy saved on this Mac"), rejectedRows: cached.rejected)
            }
            return ElementLoad(elements: [], fetchedAt: nil,
                               source: .none("\(reason), and no saved elements are on this Mac. Connect and update, or import a file."),
                               rejectedRows: 0)
        }
    }

    /// Adds element sets from a file the user picked (OMM JSON, OMM CSV or TLE text) to the imported collection and
    /// returns how many usable sets it held. Nothing is stored when it held none.
    public func importElements(_ text: String, named: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: ElementParser.Result
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            result = try ElementParser.parseOMMJSON(Data(text.utf8))
        } else if trimmed.prefix(while: { !$0.isNewline }).contains("MEAN_MOTION") {
            result = ElementParser.parseOMMCSV(text)
        } else {
            result = ElementParser.parseTLE(text)
        }
        guard !result.elements.isEmpty else {
            throw ElementParser.ParseError(message: "No element sets were found in \(named). Expected OMM JSON, OMM CSV or TLE text.")
        }
        writeCache(CacheFile(fetchedAt: now(), elements: result.elements, rejected: result.rejected.count),
                   "imported-\(Self.safeName(named))")
        return result.elements.count
    }

    /// Every imported element set, the newest epoch winning where a satellite was imported more than once.
    public func importedElements() -> [OrbitalElements] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var newest: [Int: OrbitalElements] = [:]
        for file in names.sorted() where file.hasPrefix("imported-") && file.hasSuffix(".json") {
            guard let cache = readCache(String(file.dropLast(5))) else { continue }
            for element in cache.elements where newest[element.noradID].map({ element.epoch > $0.epoch }) ?? true {
                newest[element.noradID] = element
            }
        }
        return newest.values.sorted { $0.noradID < $1.noradID }
    }

    /// URLError's own text is often "The operation couldn't be completed. (NSURLErrorDomain error -1009.)" outside a
    /// GUI app, which tells a person nothing.
    static func readable(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return "this Mac has no internet connection"
        case .timedOut: return "the request timed out"
        case .cannotFindHost, .dnsLookupFailed: return "the server name could not be found"
        case .cannotConnectToHost, .networkConnectionLost: return "the connection failed or dropped"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "a secure connection could not be made"
        case .cancelled: return "the request was cancelled"
        default: return urlError.localizedDescription
        }
    }

    // MARK: Cache files

    private static func safeName(_ text: String) -> String {
        String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "_" })
    }

    private func readCache(_ name: String) -> CacheFile? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).json")) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }

    private func writeCache(_ file: CacheFile, _ name: String) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }
}
