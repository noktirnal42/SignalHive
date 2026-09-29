import Foundation

// MARK: - FCC geo API client (no key required)
// https://geo.fcc.gov/api/census/ — lat/lon → county/state FIPS + names.

public struct GeoCountyResult: Codable, Sendable {
    public var stateCode: String
    public var stateName: String
    public var countyFIPS: String
    public var countyName: String
}

public enum GeoAPIError: Error, LocalizedError {
    case lookupFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .lookupFailed(detail): return "FCC geo lookup failed: \(detail)"
        }
    }
}

public enum GeoAPIClient {

    struct CensusResponse: Decodable {
        struct Result: Decodable {
            var stateFIPS: String?
            var stateCode: String?
            var countyFIPS: String?
            var countyName: String?

            enum CodingKeys: String, CodingKey {
                case stateFIPS = "state_fips"
                case stateCode = "state_code"
                case countyFIPS = "county_fips"
                case countyName = "county_name"
            }
        }
        var results: [Result]
    }

    /// Resolve the county/state at a coordinate.
    public static func county(atLatitude lat: Double, longitude lon: Double) async throws -> GeoCountyResult {
        var components = URLComponents(string: "https://geo.fcc.gov/api/census/area")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.6f", lat)),
            URLQueryItem(name: "lon", value: String(format: "%.6f", lon)),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GeoAPIError.lookupFailed("HTTP error")
        }
        let decoded = try JSONDecoder().decode(CensusResponse.self, from: data)
        guard let r = decoded.results.first,
              let countyFIPS = r.countyFIPS, !countyFIPS.isEmpty else {
            throw GeoAPIError.lookupFailed("No county at coordinate")
        }
        return GeoCountyResult(
            stateCode: r.stateCode ?? "",
            stateName: "",
            countyFIPS: countyFIPS,
            countyName: r.countyName ?? ""
        )
    }
}
