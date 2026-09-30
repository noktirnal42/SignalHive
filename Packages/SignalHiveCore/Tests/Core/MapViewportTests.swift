import Testing
import Foundation
@testable import SignalHiveCore

struct MapViewportTests {
    private func viewport() throws -> MapViewport {
        try #require(MapViewport(topLeft: GeoCoordinate(latitude: 41, longitude: -101),
                                 bottomRight: GeoCoordinate(latitude: 39, longitude: -99), width: 200, height: 100))
    }

    @Test func cornersMapToCorners() throws {
        let view = try viewport()
        let topLeft = view.point(for: GeoCoordinate(latitude: 41, longitude: -101))
        let bottomRight = view.point(for: GeoCoordinate(latitude: 39, longitude: -99))
        #expect(abs(topLeft.x) < 1e-9 && abs(topLeft.y) < 1e-9)
        #expect(abs(bottomRight.x - 200) < 1e-9 && abs(bottomRight.y - 100) < 1e-9)
    }

    @Test func theMiddleIsInTheMiddle() throws {
        let view = try viewport()
        let middle = view.point(for: GeoCoordinate(latitude: 40, longitude: -100))
        #expect(abs(middle.x - 100) < 1e-9)
        #expect(abs(middle.y - 50) < 0.2, "Mercator is not quite linear in latitude, so the centre is a hair off 50")
    }

    @Test func pointsAndCoordinatesConvertBothWays() throws {
        let view = try viewport()
        for (x, y) in [(0.0, 0.0), (37.5, 81.2), (200, 100), (100, 50), (150, 10)] {
            let coordinate = view.coordinate(x: x, y: y)
            let back = view.point(for: coordinate)
            #expect(abs(back.x - x) < 1e-6 && abs(back.y - y) < 1e-6)
        }
    }

    @Test func northIsUpAndEastIsRight() throws {
        let view = try viewport()
        let here = view.point(for: GeoCoordinate(latitude: 40, longitude: -100))
        let north = view.point(for: GeoCoordinate(latitude: 40.5, longitude: -100))
        let east = view.point(for: GeoCoordinate(latitude: 40, longitude: -99.5))
        #expect(north.y < here.y && abs(north.x - here.x) < 1e-9)
        #expect(east.x > here.x && abs(east.y - here.y) < 1e-9)
    }

    @Test func containsHonoursTheMargin() throws {
        let view = try viewport()
        #expect(view.contains(GeoCoordinate(latitude: 40, longitude: -100)))
        #expect(!view.contains(GeoCoordinate(latitude: 42, longitude: -100)))
        #expect(view.contains(GeoCoordinate(latitude: 41.02, longitude: -100), margin: 20))
    }

    @Test func scaleFollowsTheZoom() throws {
        let view = try viewport()
        // 2 degrees of longitude at 40 degrees north is about 92 NM, over 200 points.
        #expect(abs(view.widthNM - 92) < 1.5)
        #expect(abs(view.nauticalMilesPerPoint - view.widthNM / 200) < 1e-9)
    }

    @Test func aViewCrossingTheAntimeridianStillWorks() throws {
        let view = try #require(MapViewport(topLeft: GeoCoordinate(latitude: 10, longitude: 179),
                                            bottomRight: GeoCoordinate(latitude: -10, longitude: -179), width: 200, height: 200))
        let east = view.point(for: GeoCoordinate(latitude: 0, longitude: -179.5))
        let west = view.point(for: GeoCoordinate(latitude: 0, longitude: 179.5))
        #expect(abs(west.x - 50) < 1e-6)
        #expect(abs(east.x - 150) < 1e-6)
        let back = view.coordinate(x: 150, y: 100)
        #expect(abs(back.longitude - -179.5) < 1e-6)
    }

    @Test func nonsenseCornersAreRefused() {
        let a = GeoCoordinate(latitude: 41, longitude: -101)
        let b = GeoCoordinate(latitude: 39, longitude: -99)
        #expect(MapViewport(topLeft: b, bottomRight: a, width: 200, height: 100) == nil)          // upside down
        #expect(MapViewport(topLeft: a, bottomRight: b, width: 0, height: 100) == nil)
        #expect(MapViewport(topLeft: GeoCoordinate(latitude: 95, longitude: 0), bottomRight: b, width: 10, height: 10) == nil)
    }
}

struct AircraftProjectionTests {
    private let moment = Date(timeIntervalSinceReferenceDate: 9_000_000)

    private func aircraft(speed: Double?, track: Double?, onGround: Bool = false) -> AircraftState {
        var state = AircraftState(address: 1, firstSeen: moment)
        state.coordinate = GeoCoordinate(latitude: 40, longitude: -100)
        state.groundSpeedKnots = speed
        state.trackDegrees = track
        state.onGround = onGround
        state.lastPositionTime = moment
        return state
    }

    @Test func anAircraftIsAdvancedAlongItsTrack() throws {
        let state = aircraft(speed: 360, track: 90)
        let projected = try #require(state.projectedCoordinate(at: moment.addingTimeInterval(5)))
        #expect(abs(GeoMath.distanceNM(state.coordinate!, projected) - 0.5) < 0.01)        // 360 kt is 0.1 NM a second
        let bearing = GeoMath.bearingDegrees(from: state.coordinate!, to: projected)
        #expect(abs(bearing - 90) < 0.5)
    }

    @Test func projectionStopsAfterTheLimit() throws {
        let state = aircraft(speed: 360, track: 0)
        let capped = try #require(state.projectedCoordinate(at: moment.addingTimeInterval(60), maximumSeconds: 8))
        #expect(abs(GeoMath.distanceNM(state.coordinate!, capped) - 0.8) < 0.01)
    }

    @Test func slowOrGroundedOrUnknownAircraftStayPut() {
        #expect(aircraft(speed: 2, track: 90).projectedCoordinate(at: moment.addingTimeInterval(5)) == GeoCoordinate(latitude: 40, longitude: -100))
        #expect(aircraft(speed: 300, track: 90, onGround: true).projectedCoordinate(at: moment.addingTimeInterval(5)) == GeoCoordinate(latitude: 40, longitude: -100))
        #expect(aircraft(speed: nil, track: nil).projectedCoordinate(at: moment.addingTimeInterval(5)) == GeoCoordinate(latitude: 40, longitude: -100))
        #expect(aircraft(speed: 300, track: 90).projectedCoordinate(at: moment.addingTimeInterval(-5)) == GeoCoordinate(latitude: 40, longitude: -100))
    }

    @Test func noPositionMeansNoProjection() {
        let state = AircraftState(address: 2, firstSeen: moment)
        #expect(state.projectedCoordinate(at: moment) == nil)
    }
}

struct AviationPictureExtrasTests {
    @Test func theBoundingBoxHoldsEveryAircraftAndTheReceiver() throws {
        var picture = AviationPicture(receiver: GeoCoordinate(latitude: 39, longitude: -101))
        let now = Date(timeIntervalSinceReferenceDate: 100)
        picture.apply(AircraftReport(address: 1, source: .modeS, time: now, coordinate: GeoCoordinate(latitude: 40, longitude: -100)))
        picture.apply(AircraftReport(address: 2, source: .modeS, time: now, coordinate: GeoCoordinate(latitude: 41.5, longitude: -98)))
        let box = try #require(picture.boundingBox())
        #expect(box.south == 39 && box.north == 41.5 && box.west == -101 && box.east == -98)
        let without = try #require(picture.boundingBox(includeReceiver: false))
        #expect(without.south == 40 && without.west == -100)
        #expect(AviationPicture().boundingBox() == nil)
    }

    @Test func radarCanBeReplaced() {
        var picture = AviationPicture()
        var mosaic = RadarMosaic(product: .regional)
        mosaic.add(RadarBlock(product: .regional, hours: 1, minutes: 0, northArcminutes: 2_400, westArcminutes: -7_200,
                              heightArcminutes: 4, widthArcminutes: 48, bins: [UInt8](repeating: 3, count: 128)),
                   at: Date(timeIntervalSinceReferenceDate: 1))
        picture.setRadar([.regional: mosaic])
        #expect(picture.radar[.regional]?.blockCount == 1)
    }

    #if canImport(CoreGraphics)
    @Test func aRasterBecomesAnImage() throws {
        let block = RadarBlock(product: .regional, hours: 1, minutes: 0, northArcminutes: 2_400, westArcminutes: -7_200,
                               heightArcminutes: 4, widthArcminutes: 48, bins: [UInt8](repeating: 4, count: 128))
        let raster = try #require(RadarRasterizer.raster(from: [block]))
        let image = try #require(raster.makeCGImage())
        #expect(image.width == raster.width && image.height == raster.height)
    }
    #endif
}
