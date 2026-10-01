import Foundation

public struct SatelliteTLE: Identifiable, Equatable, Sendable {
    public var id: Int { noradID }
    public var name: String
    public var noradID: Int
    public var epoch: Date
    public var inclinationDegrees: Double
    public var raanDegrees: Double
    public var eccentricity: Double
    public var argumentOfPerigeeDegrees: Double
    public var meanAnomalyDegrees: Double
    public var meanMotionRevsPerDay: Double
    public var line1: String
    public var line2: String

    public init(name: String, noradID: Int, epoch: Date, inclinationDegrees: Double, raanDegrees: Double,
                eccentricity: Double, argumentOfPerigeeDegrees: Double, meanAnomalyDegrees: Double,
                meanMotionRevsPerDay: Double, line1: String = "", line2: String = "") {
        self.name = name
        self.noradID = noradID
        self.epoch = epoch
        self.inclinationDegrees = inclinationDegrees
        self.raanDegrees = raanDegrees
        self.eccentricity = eccentricity
        self.argumentOfPerigeeDegrees = argumentOfPerigeeDegrees
        self.meanAnomalyDegrees = meanAnomalyDegrees
        self.meanMotionRevsPerDay = meanMotionRevsPerDay
        self.line1 = line1
        self.line2 = line2
    }
}

public enum TLEParser {
    public static func parseMany(_ text: String) -> [SatelliteTLE] {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var result: [SatelliteTLE] = []
        var index = 0
        while index + 1 < lines.count {
            let name: String
            let line1: String
            let line2: String
            if lines[index].hasPrefix("1 "), lines[index + 1].hasPrefix("2 ") {
                name = "NORAD \(lines[index].split(separator: " ")[safe: 1] ?? "")"
                line1 = lines[index]
                line2 = lines[index + 1]
                index += 2
            } else if index + 2 < lines.count, lines[index + 1].hasPrefix("1 "), lines[index + 2].hasPrefix("2 ") {
                name = lines[index]
                line1 = lines[index + 1]
                line2 = lines[index + 2]
                index += 3
            } else {
                index += 1
                continue
            }
            if let tle = parse(name: name, line1: line1, line2: line2) {
                result.append(tle)
            }
        }
        return result
    }

    public static func parse(name: String, line1: String, line2: String) -> SatelliteTLE? {
        let one = line1.split(separator: " ").map(String.init)
        let two = line2.split(separator: " ").map(String.init)
        guard one.count >= 4, two.count >= 8,
              let noradID = Int(one[1].prefix(5)),
              let epoch = parseEpoch(one[3]),
              let inclination = Double(two[2]),
              let raan = Double(two[3]),
              let eccentricity = Double("0." + two[4]),
              let argument = Double(two[5]),
              let anomaly = Double(two[6]),
              let motion = Double(two[7].prefix { $0 != " " }) else { return nil }
        return SatelliteTLE(
            name: name,
            noradID: noradID,
            epoch: epoch,
            inclinationDegrees: inclination,
            raanDegrees: raan,
            eccentricity: eccentricity,
            argumentOfPerigeeDegrees: argument,
            meanAnomalyDegrees: anomaly,
            meanMotionRevsPerDay: motion,
            line1: line1,
            line2: line2)
    }

    private static func parseEpoch(_ token: String) -> Date? {
        guard token.count >= 5,
              let year2 = Int(token.prefix(2)),
              let day = Double(token.dropFirst(2)) else { return nil }
        let year = year2 >= 57 ? 1900 + year2 : 2000 + year2
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = 1
        components.day = 1
        guard let jan1 = components.date else { return nil }
        return jan1.addingTimeInterval((day - 1) * 86_400)
    }
}

public struct SatellitePass: Identifiable, Equatable, Sendable {
    public var id: String { "\(satellite.noradID)-\(Int(start.timeIntervalSince1970))" }
    public var satellite: SatelliteTLE
    public var start: Date
    public var peak: Date
    public var end: Date
    public var maxElevationDegrees: Double
    public var peakAzimuthDegrees: Double
    public var peakRangeKM: Double
    public var peakSubsatellite: GeoCoordinate

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct SatellitePassPlanner: Sendable {
    public var minimumElevationDegrees: Double
    public var sampleInterval: TimeInterval

    public init(minimumElevationDegrees: Double = 5, sampleInterval: TimeInterval = 30) {
        self.minimumElevationDegrees = minimumElevationDegrees
        self.sampleInterval = sampleInterval
    }

    public func upcomingPasses(for satellites: [SatelliteTLE], observer: GeoCoordinate, from start: Date,
                               through end: Date) -> [SatellitePass] {
        guard observer.isValid, end > start, sampleInterval > 0 else { return [] }
        return satellites.flatMap { passes(for: $0, observer: observer, from: start, through: end) }
            .sorted { lhs, rhs in
                lhs.start == rhs.start ? lhs.maxElevationDegrees > rhs.maxElevationDegrees : lhs.start < rhs.start
            }
    }

    private func passes(for tle: SatelliteTLE, observer: GeoCoordinate, from start: Date, through end: Date) -> [SatellitePass] {
        var visible: [SatelliteLook] = []
        var passes: [SatellitePass] = []
        var time = start
        while time <= end {
            let look = lookAngle(for: tle, observer: observer, at: time)
            if look.elevationDegrees >= minimumElevationDegrees {
                visible.append(look)
            } else if !visible.isEmpty {
                appendPass(from: visible, tle: tle, to: &passes)
                visible.removeAll(keepingCapacity: true)
            }
            time = time.addingTimeInterval(sampleInterval)
        }
        if !visible.isEmpty {
            appendPass(from: visible, tle: tle, to: &passes)
        }
        return passes
    }

    private func appendPass(from looks: [SatelliteLook], tle: SatelliteTLE, to passes: inout [SatellitePass]) {
        guard let first = looks.first, let last = looks.last, let peak = looks.max(by: { $0.elevationDegrees < $1.elevationDegrees }) else { return }
        passes.append(SatellitePass(satellite: tle, start: first.time, peak: peak.time, end: last.time,
                                    maxElevationDegrees: peak.elevationDegrees, peakAzimuthDegrees: peak.azimuthDegrees,
                                    peakRangeKM: peak.rangeKM, peakSubsatellite: peak.subsatellite))
    }

    public func lookAngle(for tle: SatelliteTLE, observer: GeoCoordinate, at time: Date) -> SatelliteLook {
        let eci = Self.eciPosition(tle: tle, at: time)
        let gmst = Self.gmstRadians(at: time)
        let ecef = Vec3(
            x: cos(gmst) * eci.x + sin(gmst) * eci.y,
            y: -sin(gmst) * eci.x + cos(gmst) * eci.y,
            z: eci.z)
        let observerECEF = Self.observerECEF(observer)
        let range = ecef - observerECEF
        let lat = observer.latitude * .pi / 180
        let lon = observer.longitude * .pi / 180
        let east = -sin(lon) * range.x + cos(lon) * range.y
        let north = -sin(lat) * cos(lon) * range.x - sin(lat) * sin(lon) * range.y + cos(lat) * range.z
        let up = cos(lat) * cos(lon) * range.x + cos(lat) * sin(lon) * range.y + sin(lat) * range.z
        let horizontal = hypot(east, north)
        let elevation = atan2(up, horizontal) * 180 / .pi
        var azimuth = atan2(east, north) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        return SatelliteLook(time: time, elevationDegrees: elevation, azimuthDegrees: azimuth,
                             rangeKM: range.length, subsatellite: Self.coordinate(fromECEF: ecef))
    }

    private static func eciPosition(tle: SatelliteTLE, at time: Date) -> Vec3 {
        let mu = 398_600.4418
        let n = tle.meanMotionRevsPerDay * 2 * .pi / 86_400
        let semiMajor = pow(mu / (n * n), 1.0 / 3.0)
        let elapsed = time.timeIntervalSince(tle.epoch)
        let mean = (tle.meanAnomalyDegrees * .pi / 180 + n * elapsed).truncatingRemainder(dividingBy: 2 * .pi)
        let e = max(0, min(0.2, tle.eccentricity))
        var eccentricAnomaly = mean
        for _ in 0..<6 {
            eccentricAnomaly = mean + e * sin(eccentricAnomaly)
        }
        let xOrbit = semiMajor * (cos(eccentricAnomaly) - e)
        let yOrbit = semiMajor * sqrt(1 - e * e) * sin(eccentricAnomaly)
        let arg = tle.argumentOfPerigeeDegrees * .pi / 180
        let inc = tle.inclinationDegrees * .pi / 180
        let raan = tle.raanDegrees * .pi / 180
        let x1 = cos(arg) * xOrbit - sin(arg) * yOrbit
        let y1 = sin(arg) * xOrbit + cos(arg) * yOrbit
        return Vec3(
            x: cos(raan) * x1 - sin(raan) * cos(inc) * y1,
            y: sin(raan) * x1 + cos(raan) * cos(inc) * y1,
            z: sin(inc) * y1)
    }

    private static func observerECEF(_ coordinate: GeoCoordinate) -> Vec3 {
        let radius = 6_378.137
        let lat = coordinate.latitude * .pi / 180
        let lon = coordinate.longitude * .pi / 180
        return Vec3(x: radius * cos(lat) * cos(lon), y: radius * cos(lat) * sin(lon), z: radius * sin(lat))
    }

    private static func coordinate(fromECEF point: Vec3) -> GeoCoordinate {
        let lon = atan2(point.y, point.x) * 180 / .pi
        let lat = atan2(point.z, hypot(point.x, point.y)) * 180 / .pi
        return GeoCoordinate(latitude: lat, longitude: GeoMath.normalizedLongitude(lon))
    }

    private static func gmstRadians(at date: Date) -> Double {
        let jd = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (jd - 2_451_545.0) / 36_525
        var degrees = 280.46061837 + 360.98564736629 * (jd - 2_451_545.0) + 0.000387933 * t * t - t * t * t / 38_710_000
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return degrees * .pi / 180
    }
}

public struct SatelliteLook: Equatable, Sendable {
    public var time: Date
    public var elevationDegrees: Double
    public var azimuthDegrees: Double
    public var rangeKM: Double
    public var subsatellite: GeoCoordinate
}

private struct Vec3 {
    var x: Double
    var y: Double
    var z: Double

    static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    var length: Double { sqrt(x * x + y * y + z * z) }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
