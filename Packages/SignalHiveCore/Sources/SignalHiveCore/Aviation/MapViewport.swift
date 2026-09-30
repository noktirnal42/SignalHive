import Foundation

/// What part of the world a map view shows, and how it maps to points on the screen.
///
/// The map is north-up and flat, so screen x is linear in longitude and screen y is linear in Web Mercator "y". Two
/// opposite corners are enough to convert any coordinate with plain arithmetic. The overlay that draws aircraft, trails
/// and radar asks the map for its corners once per frame instead of converting every point through the map itself.
public struct MapViewport: Sendable, Equatable {
    public let west: Double
    public let east: Double
    public let north: Double
    public let south: Double
    /// The size of the view, in points.
    public let width: Double
    public let height: Double

    private let mercatorNorth: Double
    private let mercatorSouth: Double

    /// Nil when the corners do not describe a view: no area, or a size of zero.
    public init?(topLeft: GeoCoordinate, bottomRight: GeoCoordinate, width: Double, height: Double) {
        guard topLeft.isValid, bottomRight.isValid, width > 0, height > 0, topLeft.latitude > bottomRight.latitude else { return nil }
        var eastEdge = bottomRight.longitude
        if eastEdge <= topLeft.longitude { eastEdge += 360 }               // the view crosses the antimeridian
        guard eastEdge - topLeft.longitude > 0 else { return nil }
        west = topLeft.longitude
        east = eastEdge
        north = topLeft.latitude
        south = bottomRight.latitude
        self.width = width
        self.height = height
        mercatorNorth = GeoMath.mercatorY(latitude: topLeft.latitude)
        mercatorSouth = GeoMath.mercatorY(latitude: bottomRight.latitude)
    }

    /// The point on screen where `coordinate` is drawn (it can lie outside the view).
    public func point(for coordinate: GeoCoordinate) -> (x: Double, y: Double) {
        var deltaLongitude = coordinate.longitude - west
        while deltaLongitude < -180 { deltaLongitude += 360 }
        while deltaLongitude > 540 { deltaLongitude -= 360 }
        if deltaLongitude < 0 && east - west > 180 { deltaLongitude += 360 }
        let x = deltaLongitude / (east - west) * width
        let y = (mercatorNorth - GeoMath.mercatorY(latitude: coordinate.latitude)) / (mercatorNorth - mercatorSouth) * height
        return (x, y)
    }

    /// The coordinate under a point of the view.
    public func coordinate(x: Double, y: Double) -> GeoCoordinate {
        let longitude = GeoMath.normalizedLongitude(west + x / width * (east - west))
        let mercator = mercatorNorth - y / height * (mercatorNorth - mercatorSouth)
        return GeoCoordinate(latitude: GeoMath.latitude(mercatorY: mercator), longitude: longitude)
    }

    /// Whether a coordinate is inside the view, allowing `margin` points beyond its edges.
    public func contains(_ coordinate: GeoCoordinate, margin: Double = 0) -> Bool {
        let p = point(for: coordinate)
        return p.x >= -margin && p.x <= width + margin && p.y >= -margin && p.y <= height + margin
    }

    /// Nautical miles per screen point at the middle of the view (for the scale bar and for sizing icons).
    public var nauticalMilesPerPoint: Double {
        let middleLatitude = GeoMath.latitude(mercatorY: (mercatorNorth + mercatorSouth) / 2)
        return (east - west) / width * 60 * cos(middleLatitude * Double.pi / 180)
    }

    /// The width of the view in nautical miles.
    public var widthNM: Double { nauticalMilesPerPoint * width }
}

extension AircraftState {
    /// Where the aircraft probably is now: its last position advanced along its track at its ground speed, for up to
    /// `maximumSeconds`. Between two position reports this keeps the icon moving smoothly instead of jumping.
    public func projectedCoordinate(at now: Date, maximumSeconds: TimeInterval = 8) -> GeoCoordinate? {
        guard let coordinate else { return nil }
        guard !onGround, let speed = groundSpeedKnots, speed > 5, let track = trackDegrees,
              let reported = lastPositionTime else { return coordinate }
        let elapsed = min(maximumSeconds, max(0, now.timeIntervalSince(reported)))
        guard elapsed > 0 else { return coordinate }
        return GeoMath.destination(from: coordinate, bearingDegrees: track, distanceNM: speed * elapsed / 3_600)
    }
}

extension AviationPicture {
    /// The smallest box holding every positioned aircraft (and the receiver), for a "fit to traffic" button.
    public func boundingBox(includeReceiver: Bool = true) -> (south: Double, north: Double, west: Double, east: Double)? {
        var points = positionedAircraft.compactMap(\.coordinate)
        if includeReceiver, let receiver { points.append(receiver) }
        guard let first = points.first else { return nil }
        var box = (south: first.latitude, north: first.latitude, west: first.longitude, east: first.longitude)
        for point in points {
            box.south = min(box.south, point.latitude)
            box.north = max(box.north, point.latitude)
            box.west = min(box.west, point.longitude)
            box.east = max(box.east, point.longitude)
        }
        return box
    }

    /// Replaces the radar mosaics wholesale (the demo keeps its own between snapshots).
    public mutating func setRadar(_ mosaics: [RadarProduct: RadarMosaic]) {
        radar = mosaics
        revision += 1
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

extension RadarRaster {
    /// The picture as a CoreGraphics image (premultiplied RGBA), ready to draw over a map.
    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
#endif
