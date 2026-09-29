import Foundation

// MARK: - OpenMHz client (open, key-less community API)
// https://api.openmhz.com — systems, talkgroups, calls.

public enum OpenMHzError: Error, LocalizedError {
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .requestFailed(detail): return "OpenMHz request failed: \(detail)"
        }
    }
}

public enum OpenMHzClient {

    private static let base = URL(string: "https://api.openmhz.com")!

    struct SystemResponse: Decodable {
        var shortName: String?
        var name: String?
        var talkgroups: Int?
        var calls: Int?
        var lat: Double?
        var lon: Double?
    }

    struct TalkgroupResponse: Decodable {
        struct Item: Decodable {
            var num: Int?
            var des: String?
            var alphaTag: String?
            var callCount: Int?

            enum CodingKeys: String, CodingKey {
                case num
                case des
                case alphaTag = "alphaTag"
                case callCount = "callCount"
            }
        }
        var talkgroups: [Item]
    }

    public static func systems() async throws -> [TrunkedSystem] {
        let (data, _) = try await get(path: "/systems")
        let decoded = try JSONDecoder().decode([SystemResponse].self, from: data)
        return decoded.compactMap { s in
            guard let shortName = s.shortName else { return nil }
            return TrunkedSystem(
                shortName: shortName,
                name: s.name ?? shortName,
                talkgroupCount: s.talkgroups ?? 0,
                callCount: s.calls ?? 0,
                lat: s.lat,
                lon: s.lon
            )
        }
    }

    public static func talkgroups(systemShortName: String) async throws -> [TrunkedTalkgroup] {
        let (data, _) = try await get(path: "/\(systemShortName)/talkgroups")
        let decoded = try JSONDecoder().decode(TalkgroupResponse.self, from: data)
        return decoded.talkgroups.compactMap { t in
            guard let code = t.num else { return nil }
            return TrunkedTalkgroup(
                systemShortName: systemShortName,
                code: code,
                alphaTag: t.alphaTag ?? "",
                descriptionText: t.des ?? "",
                callCount: t.callCount ?? 0
            )
        }
    }

    private static func get(path: String) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenMHzError.requestFailed("HTTP error for \(path)")
        }
        return (data, http)
    }
}
