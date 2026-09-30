import Foundation

// MARK: - OpenMHz client (open, key-less community API)
// https://api.openmhz.com: systems, talkgroups.
//
// The response shapes below are those of OpenMHz's own server (github.com/openmhz/trunk-server, backend/controllers):
//   GET /systems               -> {"success": true, "systems": [{name, shortName, systemType, city, county, state, country,
//                                  description, callAvg, clientCount, active, lastActive, status, ...}]}
//   GET /<shortName>/talkgroups -> {"talkgroups": {"<num>": {_id, num, alpha, description, tag?, group?}}}
// The parser also accepts the plainer shapes a mirror or a later version might send (a bare array, an array of
// talkgroups, other spellings of the field names), because the server is not under this project's control.

public enum OpenMHzError: Error, LocalizedError {
    case requestFailed(String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(detail): return "OpenMHz request failed: \(detail)"
        case let .unexpectedResponse(detail): return "OpenMHz sent something unexpected: \(detail)"
        }
    }
}

/// Turns OpenMHz's JSON into models. It touches no network, so it is tested with fixtures.
public enum OpenMHzParser {
    public static func systems(from data: Data) throws -> [TrunkedSystem] {
        let root = try json(data)
        let items: [[String: Any]]
        if let object = root as? [String: Any] {
            if let list = object["systems"] as? [[String: Any]] {
                items = list
            } else if let map = object["systems"] as? [String: Any] {
                items = map.values.compactMap { $0 as? [String: Any] }         // keyed by short name
            } else {
                throw OpenMHzError.unexpectedResponse("there is no list of systems in the answer")
            }
        } else if let list = root as? [[String: Any]] {
            items = list
        } else {
            throw OpenMHzError.unexpectedResponse("the answer is not a list of systems")
        }
        return items.compactMap { item in
            let shortName = string(item, ["shortName", "short_name", "id"])
            guard !shortName.isEmpty else { return nil }
            let name = string(item, ["name"])
            return TrunkedSystem(
                shortName: shortName, name: name.isEmpty ? shortName : name,
                systemType: string(item, ["systemType", "type"]), city: string(item, ["city"]), county: string(item, ["county"]),
                state: string(item, ["state"]), country: string(item, ["country"]), details: string(item, ["description"]),
                callsPerHour: number(item["callAvg"]) ?? 0, listeners: integer(item["clientCount"]) ?? 0,
                isActive: boolean(item["active"]) ?? true, lastActive: date(item["lastActive"]))
        }
    }

    public static func talkgroups(from data: Data, system: String) throws -> [TrunkedTalkgroup] {
        let root = try json(data)
        var container: Any = root
        if let object = root as? [String: Any], let inner = object["talkgroups"] { container = inner }

        var entries: [(key: String?, item: [String: Any])] = []
        if let map = container as? [String: Any] {
            for (key, value) in map {
                if let item = value as? [String: Any] { entries.append((key, item)) }
            }
        } else if let list = container as? [Any] {
            for value in list {
                if let item = value as? [String: Any] { entries.append((nil, item)) }
            }
        } else {
            throw OpenMHzError.unexpectedResponse("there is no list of talkgroups in the answer")
        }

        let parsed: [TrunkedTalkgroup] = entries.compactMap { key, item in
            guard let code = integer(item["num"]) ?? integer(item["decimal"]) ?? integer(item["id"]) ?? key.flatMap({ Int($0) }) else { return nil }
            return TrunkedTalkgroup(
                systemShortName: system, code: code, alphaTag: string(item, ["alpha", "alphaTag", "alpha_tag"]),
                descriptionText: string(item, ["description", "des", "desc"]), tag: string(item, ["tag"]),
                group: string(item, ["group"]), callCount: integer(item["callCount"]) ?? integer(item["count"]) ?? 0)
        }
        return parsed.sorted { $0.code < $1.code }
    }

    // MARK: Helpers

    private static func json(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OpenMHzError.unexpectedResponse("it is not JSON")
        }
    }

    private static func string(_ item: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let text = item[key] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let number = item[key] as? NSNumber { return number.stringValue }
        }
        return ""
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.intValue != 0 }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

public struct OpenMHzClient: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let baseURL: URL
    private let fetch: Fetch

    /// - Parameter fetch: How to perform a request; tests supply canned answers.
    public init(baseURL: URL = URL(string: "https://api.openmhz.com")!,
                fetch: @escaping Fetch = { request in try await URLSession.shared.data(for: request) }) {
        self.baseURL = baseURL
        self.fetch = fetch
    }

    public func systems() async throws -> [TrunkedSystem] {
        try OpenMHzParser.systems(from: try await get(path: "/systems"))
    }

    public func talkgroups(systemShortName: String) async throws -> [TrunkedTalkgroup] {
        // A slash inside a name must not become a path separator.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let name = systemShortName.addingPercentEncoding(withAllowedCharacters: allowed) ?? systemShortName
        return try OpenMHzParser.talkgroups(from: try await get(path: "/\(name)/talkgroups"), system: systemShortName)
    }

    // Convenience for callers that do not need to inject anything.
    public static func systems() async throws -> [TrunkedSystem] { try await OpenMHzClient().systems() }

    public static func talkgroups(systemShortName: String) async throws -> [TrunkedTalkgroup] {
        try await OpenMHzClient().talkgroups(systemShortName: systemShortName)
    }

    private func get(path: String) async throws -> Data {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw OpenMHzError.requestFailed("bad address for \(path)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            throw OpenMHzError.requestFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OpenMHzError.requestFailed("HTTP \(http.statusCode) for \(path)")
        }
        return data
    }
}

// MARK: - Cache

/// The last systems and talkgroups that loaded, kept on disk so Trunked still browses without a connection.
public struct TrunkedCache: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var standard: TrunkedCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TrunkedCache(directory: base.appendingPathComponent("SignalHive/Trunked", isDirectory: true))
    }

    private struct Snapshot<Value: Codable>: Codable {
        var savedAt: Date
        var value: Value
    }

    public func saveSystems(_ systems: [TrunkedSystem], at date: Date = Date()) throws {
        try write(Snapshot(savedAt: date, value: systems), to: "systems.json")
    }

    public func loadSystems() -> (systems: [TrunkedSystem], savedAt: Date)? {
        guard let snapshot: Snapshot<[TrunkedSystem]> = read("systems.json") else { return nil }
        return (snapshot.value, snapshot.savedAt)
    }

    public func saveTalkgroups(_ talkgroups: [TrunkedTalkgroup], system: String, at date: Date = Date()) throws {
        try write(Snapshot(savedAt: date, value: talkgroups), to: fileName(forTalkgroupsOf: system))
    }

    public func loadTalkgroups(system: String) -> (talkgroups: [TrunkedTalkgroup], savedAt: Date)? {
        guard let snapshot: Snapshot<[TrunkedTalkgroup]> = read(fileName(forTalkgroupsOf: system)) else { return nil }
        return (snapshot.value, snapshot.savedAt)
    }

    func fileName(forTalkgroupsOf system: String) -> String {
        let safe = system.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return "talkgroups-" + String(safe) + ".json"
    }

    private func write<Value: Codable>(_ snapshot: Snapshot<Value>, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Dates keep the default encoding so they come back exactly as they went in.
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func read<Value: Codable>(_ name: String) -> Snapshot<Value>? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(Snapshot<Value>.self, from: data)
    }
}

// MARK: - Repository

/// What a load returned, and whether it is fresh.
public struct TrunkedLoad<Value: Sendable>: Sendable {
    public var value: Value
    /// When the data was saved, if it came from the cache.
    public var savedAt: Date?
    public var isCached: Bool { savedAt != nil }
    /// Why the network was not used, when the cache stood in for it.
    public var networkError: String?
}

/// Loads from OpenMHz, remembers what it got, and falls back to the last copy when the network fails.
public struct TrunkedRepository: Sendable {
    private let client: OpenMHzClient
    private let cache: TrunkedCache

    public init(client: OpenMHzClient = OpenMHzClient(), cache: TrunkedCache = .standard) {
        self.client = client
        self.cache = cache
    }

    public func systems() async throws -> TrunkedLoad<[TrunkedSystem]> {
        do {
            let fresh = try await client.systems()
            try? cache.saveSystems(fresh)
            return TrunkedLoad(value: fresh, savedAt: nil, networkError: nil)
        } catch {
            if let cached = cache.loadSystems(), !cached.systems.isEmpty {
                return TrunkedLoad(value: cached.systems, savedAt: cached.savedAt, networkError: error.localizedDescription)
            }
            throw error
        }
    }

    public func talkgroups(system: String) async throws -> TrunkedLoad<[TrunkedTalkgroup]> {
        do {
            let fresh = try await client.talkgroups(systemShortName: system)
            try? cache.saveTalkgroups(fresh, system: system)
            return TrunkedLoad(value: fresh, savedAt: nil, networkError: nil)
        } catch {
            if let cached = cache.loadTalkgroups(system: system), !cached.talkgroups.isEmpty {
                return TrunkedLoad(value: cached.talkgroups, savedAt: cached.savedAt, networkError: error.localizedDescription)
            }
            throw error
        }
    }
}
