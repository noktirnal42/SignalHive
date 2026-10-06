import Foundation

public enum SatelliteStatus: String, Sendable, Codable {
    case alive, dead, future, reentered, unknown
}

/// One downlink of one satellite, as the SatNOGS database describes it.
public struct TransmitterInfo: Identifiable, Sendable, Equatable, Codable {
    public var id: String
    public var noradID: Int
    public var summary: String
    public var downlinkHz: Double
    public var mode: String?
    public var kind: SignalKind
    public var isActive: Bool
    public var service: String?
    /// Set only when the owner has received it on air (from the bundled overrides); SatNOGS data never sets it.
    public var verifiedOnAir: Date?

    public init(id: String, noradID: Int, summary: String, downlinkHz: Double, mode: String?, kind: SignalKind,
                isActive: Bool, service: String?, verifiedOnAir: Date?) {
        self.id = id
        self.noradID = noradID
        self.summary = summary
        self.downlinkHz = downlinkHz
        self.mode = mode
        self.kind = kind
        self.isActive = isActive
        self.service = service
        self.verifiedOnAir = verifiedOnAir
    }
}

public struct TransmitterLoad: Sendable {
    public var transmitters: [TransmitterInfo]
    public var satellites: [Int: SatelliteStatus]
    public var fetchedAt: Date?
    public var source: ElementLoad.Source
    public var rejected: Int

    public init(transmitters: [TransmitterInfo], satellites: [Int: SatelliteStatus], fetchedAt: Date?,
                source: ElementLoad.Source, rejected: Int) {
        self.transmitters = transmitters
        self.satellites = satellites
        self.fetchedAt = fetchedAt
        self.source = source
        self.rejected = rejected
    }
}

/// The SatNOGS DB transmitter and satellite lists (CC BY-SA 4.0): fetched at runtime and cached, never bundled, with
/// the attribution shown on screen. The lists change slowly, so they are refetched at most once a day.
public actor TransmitterStore {
    public static let attribution = "Transmitter data: SatNOGS DB (CC BY-SA 4.0), db.satnogs.org"
    static let transmittersURL = URL(string: "https://db.satnogs.org/api/transmitters/?format=json")!
    static let satellitesURL = URL(string: "https://db.satnogs.org/api/satellites/?format=json")!

    private struct CacheFile: Codable {
        var fetchedAt: Date
        var transmitters: [TransmitterInfo]
        var satellites: [String: SatelliteStatus]
        var rejected: Int
    }

    private struct Failure: Error { let message: String }

    private let directory: URL
    private let fetch: ElementStore.Fetch
    private let now: @Sendable () -> Date
    private let minimumRefetchInterval: TimeInterval

    public init(directory: URL,
                fetch: @escaping ElementStore.Fetch = { request in try await URLSession.shared.data(for: request) },
                now: @escaping @Sendable () -> Date = { Date() },
                minimumRefetchInterval: TimeInterval = 86_400) {
        self.directory = directory
        self.fetch = fetch
        self.now = now
        self.minimumRefetchInterval = minimumRefetchInterval
    }

    public func load(forceRefresh: Bool = false) async -> TransmitterLoad {
        let cached = readCache()
        let current = now()
        if let cached, (0..<minimumRefetchInterval).contains(current.timeIntervalSince(cached.fetchedAt)) {
            return load(from: cached, source: .cacheTooSoonToRefetch)
        }
        do {
            let transmittersBody = try await get(Self.transmittersURL)
            let satellitesBody = try await get(Self.satellitesURL)
            let transmitters: (transmitters: [TransmitterInfo], rejected: Int)
            let satellites: (statuses: [Int: SatelliteStatus], rejected: Int)
            do {
                transmitters = try Self.parseTransmitters(transmittersBody)
                satellites = try Self.parseSatellites(satellitesBody)
            } catch let error as ElementParser.ParseError {
                throw Failure(message: error.message)
            }
            guard !transmitters.transmitters.isEmpty else { throw Failure(message: "SatNOGS sent no usable transmitters") }
            let file = CacheFile(fetchedAt: current, transmitters: transmitters.transmitters,
                                 satellites: Dictionary(uniqueKeysWithValues: satellites.statuses.map { (String($0.key), $0.value) }),
                                 rejected: transmitters.rejected + satellites.rejected)
            writeCache(file)
            return load(from: file, source: .network)
        } catch {
            let reason = (error as? Failure)?.message ?? "Could not reach SatNOGS (\(ElementStore.readable(error)))"
            if let cached { return load(from: cached, source: .cacheAfterFailure("\(reason); showing the copy saved on this Mac")) }
            return TransmitterLoad(transmitters: [], satellites: [:], fetchedAt: nil,
                                   source: .none("\(reason), and no saved transmitter data is on this Mac."), rejected: 0)
        }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("SignalHive (macOS radio workbench; github.com/noktirnal42/SignalHive)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure(message: "SatNOGS answered HTTP \(http.statusCode)")
        }
        return data
    }

    private func load(from file: CacheFile, source: ElementLoad.Source) -> TransmitterLoad {
        TransmitterLoad(transmitters: file.transmitters,
                        satellites: Dictionary(uniqueKeysWithValues: file.satellites.compactMap { key, value in Int(key).map { ($0, value) } }),
                        fetchedAt: file.fetchedAt, source: source, rejected: file.rejected)
    }

    // MARK: Parsing (field names checked against a saved live response; read tolerantly, the schema drifts)

    /// A row without a usable downlink (a transmitter that only listens, or one SatNOGS has no frequency for) is not a
    /// downlink and is counted as rejected. Throws only when the body is not a JSON list.
    public static func parseTransmitters(_ data: Data) throws -> (transmitters: [TransmitterInfo], rejected: Int) {
        let rows = try jsonList(data)
        var kept: [TransmitterInfo] = []
        var rejected = 0
        for row in rows {
            guard let item = row as? [String: Any], let uuid = item["uuid"] as? String,
                  let noradID = integer(item["norad_cat_id"]), noradID > 0,
                  let downlink = number(item["downlink_low"]), downlink > 0 else {
                rejected += 1
                continue
            }
            let mode = (item["mode"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let status = (item["status"] as? String)?.lowercased()
            let alive = item["alive"] as? Bool
            let active = status.map { $0 == "active" } ?? (alive ?? false)
            kept.append(TransmitterInfo(
                id: uuid, noradID: noradID, summary: (item["description"] as? String) ?? "", downlinkHz: downlink, mode: mode,
                kind: SignalKind(satnogsMode: mode, baud: number(item["baud"])), isActive: active && alive != false,
                service: item["service"] as? String, verifiedOnAir: nil))
        }
        return (kept, rejected)
    }

    public static func parseSatellites(_ data: Data) throws -> (statuses: [Int: SatelliteStatus], rejected: Int) {
        let rows = try jsonList(data)
        var statuses: [Int: SatelliteStatus] = [:]
        var rejected = 0
        for row in rows {
            guard let item = row as? [String: Any], let noradID = integer(item["norad_cat_id"]), noradID > 0 else {
                rejected += 1
                continue
            }
            switch (item["status"] as? String)?.lowercased() {
            case "in orbit", "alive": statuses[noradID] = .alive
            case "dead": statuses[noradID] = .dead
            case "future": statuses[noradID] = .future
            case "re-entered", "reentered", "decayed": statuses[noradID] = .reentered
            default: statuses[noradID] = .unknown
            }
        }
        return (statuses, rejected)
    }

    private static func jsonList(_ data: Data) throws -> [Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            let snippet = String(decoding: data.prefix(80), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ElementParser.ParseError(message: snippet.hasPrefix("<")
                ? "SatNOGS returned a web page, not data: \(snippet)" : "SatNOGS sent something that is not data: \(snippet)")
        }
        guard let list = object as? [Any] else {
            throw ElementParser.ParseError(message: "SatNOGS answered with JSON that is not a list.")
        }
        return list
    }

    private static func number(_ value: Any?) -> Double? {
        // JSON true/false arrive as NSNumber too, and so does a plain 1 or 0 when asked `is Bool`: test the CF type.
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let n = number(value), n == n.rounded(), abs(n) < 1e12 else { return nil }
        return Int(n)
    }

    // MARK: Cache

    private func readCache() -> CacheFile? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("satnogs.json")) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }

    private func writeCache(_ file: CacheFile) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("satnogs.json"), options: .atomic)
    }
}
