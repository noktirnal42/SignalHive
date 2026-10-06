import Foundation

public struct PassPoint: Sendable, Equatable {
    public var time: Date
    public var azimuthDegrees: Double
    public var elevationDegrees: Double
    public var rangeKM: Double
    public var rangeRateKMPerSec: Double

    public init(time: Date, azimuthDegrees: Double, elevationDegrees: Double, rangeKM: Double, rangeRateKMPerSec: Double) {
        self.time = time
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.rangeKM = rangeKM
        self.rangeRateKMPerSec = rangeRateKMPerSec
    }
}

/// One visible pass of one satellite. A pass that was already under way when the window opened (or is still up when it
/// closes) is cut at the window edge and says so, rather than being dropped or given a made-up start.
public struct PredictedPass: Identifiable, Sendable, Equatable {
    public var id: String
    public var noradID: Int
    public var satelliteName: String
    public var aos: Date
    public var tca: Date
    public var los: Date
    public var aosAzimuthDegrees: Double
    public var tcaAzimuthDegrees: Double
    public var losAzimuthDegrees: Double
    public var maxElevationDegrees: Double
    public var minRangeKM: Double
    public var sunElevationAtTCADegrees: Double
    public var sunlitAtTCA: Bool
    public var startsBeforeWindow: Bool
    public var endsAfterWindow: Bool
    public var elementEpoch: Date
    /// Every 5 seconds from `aos` to `los`, both ends included.
    public var track: [PassPoint]

    public var duration: TimeInterval { los.timeIntervalSince(aos) }
}

/// What a search found. A satellite whose elements fail partway through the window (decay, absurd values) still returns
/// the passes that finished before the failure, plus the reason; a pass under way at the failure is dropped because its
/// end cannot be stated.
public struct PassSearchResult: Sendable {
    public var passes: [PredictedPass]
    public var problem: SGP4Error?

    public init(passes: [PredictedPass], problem: SGP4Error?) {
        self.passes = passes
        self.problem = problem
    }
}

public struct PassPredictor: Sendable {
    public var minimumElevationDegrees: Double

    public init(minimumElevationDegrees: Double = 5) {
        self.minimumElevationDegrees = minimumElevationDegrees
    }

    private static let coarseStep = 30.0
    private static let longestSkip = 240.0
    /// A pass whose peak is within this many degrees of the threshold is looked at closely, since the coarse samples
    /// can straddle a peak that just clears it.
    private static let candidateMargin = 4.0
    private static let edgeResolution = 0.005
    private static let trackStep = 5.0

    public func passes(for elements: OrbitalElements, observer: Observer, from: Date, through: Date) -> PassSearchResult {
        guard observer.isValid, from.timeIntervalSince1970.isFinite, through.timeIntervalSince1970.isFinite,
              through > from else { return PassSearchResult(passes: [], problem: nil) }
        let propagator: SGP4Propagator
        do {
            propagator = try SGP4Propagator(elements)
        } catch {
            return PassSearchResult(passes: [], problem: error as? SGP4Error ?? .nonFiniteInput)
        }
        let search = Search(propagator: propagator, elements: elements, observer: observer, from: from, through: through,
                            minimum: minimumElevationDegrees)
        return search.run()
    }

    private struct Search {
        let propagator: SGP4Propagator
        let elements: OrbitalElements
        let observer: Observer
        let from: Date
        let through: Date
        let minimum: Double
        let span: Double
        let site: Vector3
        let sinLat, cosLat, sinLon, cosLon: Double
        /// Upper bound on how fast the elevation can change, degrees per second.
        let maxRate: Double

        init(propagator: SGP4Propagator, elements: OrbitalElements, observer: Observer, from: Date, through: Date, minimum: Double) {
            self.propagator = propagator
            self.elements = elements
            self.observer = observer
            self.from = from
            self.through = through
            self.minimum = minimum
            span = through.timeIntervalSince(from)
            site = Geodesy.ecef(of: observer)
            let lat = observer.latitudeDegrees * .pi / 180, lon = observer.longitudeDegrees * .pi / 180
            sinLat = sin(lat); cosLat = cos(lat); sinLon = sin(lon); cosLon = cos(lon)

            // The line of sight cannot turn faster than the satellite's speed relative to the ground over its closest
            // possible range (perigee). Used only to skip ahead while the satellite is far below the horizon.
            let mu = 398_600.8
            let n = elements.meanMotionRevsPerDay * 2 * .pi / 86_400
            let a = pow(mu / (n * n), 1.0 / 3.0)
            let perigeeRadius = a * (1 - elements.eccentricity)
            let perigeeSpeed = (mu * (2 / perigeeRadius - 1 / a)).squareRoot()
            let closest = max(perigeeRadius - site.length, 100)
            let radiansPerSecond = (perigeeSpeed + WGS84.earthRotationRadPerSec * site.length) / closest
            maxRate = radiansPerSecond * 180 / .pi * 1.5
        }

        func date(_ offset: Double) -> Date { from.addingTimeInterval(offset) }

        /// Elevation only (the coarse scan needs nothing else), or nil where SGP4 fails.
        func elevation(at offset: Double) -> Double? {
            let moment = date(offset)
            guard let state = try? propagator.state(at: moment) else { return nil }
            let gmst = TimeScales.gmstRadians(moment)
            let c = cos(gmst), s = sin(gmst)
            let p = state.position
            let rho = Vector3(c * p.x + s * p.y - site.x, -s * p.x + c * p.y - site.y, p.z - site.z)
            let range = rho.length
            guard range > 0 else { return 90 }
            let up = cosLat * cosLon * rho.x + cosLat * sinLon * rho.y + sinLat * rho.z
            return asin(max(-1, min(1, up / range))) * 180 / .pi
        }

        func look(at offset: Double) -> PassPoint? {
            let moment = date(offset)
            guard let state = try? propagator.state(at: moment) else { return nil }
            let l = Topocentric.look(state, at: moment, from: observer)
            return PassPoint(time: moment, azimuthDegrees: l.azimuthDegrees, elevationDegrees: l.elevationDegrees,
                             rangeKM: l.rangeKM, rangeRateKMPerSec: l.rangeRateKMPerSec)
        }

        func run() -> PassSearchResult {
            // Coarse scan. While the satellite is far below the horizon the step grows, bounded so that it cannot
            // reach (threshold - margin) inside one step: nothing above that level is ever stepped over.
            var offsets: [Double] = []
            var values: [Double] = []
            var problem: SGP4Error?
            var t = 0.0
            while true {
                guard let el = elevation(at: t) else {
                    problem = (try? propagator.state(at: date(t))) == nil ? failure(at: t) : .nonFiniteInput
                    break
                }
                offsets.append(t)
                values.append(el)
                if t >= span { break }
                let below = minimum - PassPredictor.candidateMargin - el
                let step = below > 0 ? min(PassPredictor.longestSkip, max(PassPredictor.coarseStep, below / maxRate))
                                     : PassPredictor.coarseStep
                t = min(span, t + step)
            }
            let count = offsets.count
            guard count > 0 else { return PassSearchResult(passes: [], problem: problem) }

            var found: [(aos: Double, tca: Double, los: Double, startsBefore: Bool, endsAfter: Bool)] = []
            for k in 0..<count where values[k] >= minimum - PassPredictor.candidateMargin {
                let risingOrFlat = k == 0 || values[k] > values[k - 1]
                let notFalling = k == count - 1 || values[k] >= values[k + 1]
                guard risingOrFlat, notFalling else { continue }
                if let pass = refine(candidate: k, offsets: offsets, values: values, problem: problem) { found.append(pass) }
            }
            found.sort { $0.aos < $1.aos }
            var unique: [(aos: Double, tca: Double, los: Double, startsBefore: Bool, endsAfter: Bool)] = []
            for pass in found where unique.last.map({ abs($0.aos - pass.aos) > 1 }) ?? true { unique.append(pass) }
            return PassSearchResult(passes: unique.compactMap(build), problem: problem)
        }

        /// The reason for a failure at an offset, found by asking the propagator again.
        func failure(at offset: Double) -> SGP4Error {
            do {
                _ = try propagator.state(at: date(offset))
                return .nonFiniteInput
            } catch {
                return error as? SGP4Error ?? .nonFiniteInput
            }
        }

        func refine(candidate k: Int, offsets: [Double], values: [Double], problem: SGP4Error?)
            -> (aos: Double, tca: Double, los: Double, startsBefore: Bool, endsAfter: Bool)? {
            let count = offsets.count
            // Peak: golden-section between the neighbouring samples.
            var lo = offsets[max(k - 1, 0)], hi = offsets[min(k + 1, count - 1)]
            let ratio = (5.0.squareRoot() - 1) / 2
            var x1 = hi - ratio * (hi - lo), x2 = lo + ratio * (hi - lo)
            var f1 = elevation(at: x1) ?? -.infinity, f2 = elevation(at: x2) ?? -.infinity
            while hi - lo > 0.05 {
                if f1 < f2 {
                    lo = x1; x1 = x2; f1 = f2
                    x2 = lo + ratio * (hi - lo); f2 = elevation(at: x2) ?? -.infinity
                } else {
                    hi = x2; x2 = x1; f2 = f1
                    x1 = hi - ratio * (hi - lo); f1 = elevation(at: x1) ?? -.infinity
                }
            }
            let peak = (lo + hi) / 2
            guard let peakElevation = elevation(at: peak), peakElevation >= minimum else { return nil }

            // Where the peak sits among the coarse samples.
            var index = k
            while index + 1 < count, offsets[index + 1] <= peak { index += 1 }
            while index > 0, offsets[index] > peak { index -= 1 }

            // Start: back to the last sample below the threshold.
            var startsBefore = false
            var aos = 0.0
            var j = index
            while j >= 0, values[j] >= minimum { j -= 1 }
            if j < 0 {
                startsBefore = true
            } else {
                let upper = j == index ? peak : offsets[j + 1]
                aos = crossing(below: offsets[j], above: upper)
            }

            // End: forward to the first sample below the threshold.
            var endsAfter = false
            var los = span
            j = index + 1
            while j < count, values[j] >= minimum { j += 1 }
            if j == count {
                if problem != nil { return nil } // still up when SGP4 failed: the end is unknown
                endsAfter = true
            } else {
                let lowerAbove = j == index + 1 ? peak : offsets[j - 1]
                los = crossing(below: offsets[j], above: lowerAbove)
            }
            // A truncated pass keeps AOS < TCA < LOS by never letting the peak sit exactly on an edge.
            let tca = min(max(peak, aos + 0.001), los - 0.001)
            return (aos, tca, los, startsBefore, endsAfter)
        }

        /// The offset between one point below the threshold and one at or above it where the elevation crosses it.
        func crossing(below: Double, above: Double) -> Double {
            var low = below, high = above
            while abs(high - low) > PassPredictor.edgeResolution {
                let mid = (low + high) / 2
                if let el = elevation(at: mid), el >= minimum { high = mid } else { low = mid }
            }
            return (low + high) / 2
        }

        func build(_ raw: (aos: Double, tca: Double, los: Double, startsBefore: Bool, endsAfter: Bool)) -> PredictedPass? {
            var track: [PassPoint] = []
            var offset = raw.aos
            while offset < raw.los {
                if let point = look(at: offset) { track.append(point) }
                offset += PassPredictor.trackStep
            }
            if let last = look(at: raw.los) { track.append(last) }
            guard let first = track.first, let last = track.last, let peak = look(at: raw.tca) else { return nil }
            // The edge points are exactly at the threshold up to the search resolution; keep them honest at the window edge.
            let aosDate = date(raw.aos), losDate = date(raw.los), tcaDate = date(raw.tca)
            var sunlit = true
            if let state = try? propagator.state(at: tcaDate) {
                sunlit = SunPosition.isSunlit(satellite: state.position, sun: SunPosition.vector(at: tcaDate))
            }
            return PredictedPass(
                id: "\(elements.noradID)-\(Int(aosDate.timeIntervalSince1970))",
                noradID: elements.noradID, satelliteName: elements.name,
                aos: aosDate, tca: tcaDate, los: losDate,
                aosAzimuthDegrees: first.azimuthDegrees, tcaAzimuthDegrees: peak.azimuthDegrees,
                losAzimuthDegrees: last.azimuthDegrees,
                maxElevationDegrees: peak.elevationDegrees,
                minRangeKM: min(peak.rangeKM, track.map(\.rangeKM).min() ?? peak.rangeKM),
                sunElevationAtTCADegrees: SunPosition.elevationDegrees(from: observer, at: tcaDate),
                sunlitAtTCA: sunlit,
                startsBeforeWindow: raw.startsBefore, endsAfterWindow: raw.endsAfter,
                elementEpoch: elements.epoch, track: track)
        }
    }
}
