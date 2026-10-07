import SwiftUI
import MapKit
import SignalHiveCore

/// The satellite's path over the ground for the pass (bright) and 20 minutes either side (faint), the observer, and the
/// footprint at closest approach. The antimeridian split is `GroundTrack.segments`, so no line crosses the world.
struct GroundTrackMap: View {
    let rated: RatedPass
    let observer: Observer

    var body: some View {
        let pass = rated.pass
        let margin: TimeInterval = 20 * 60
        let wide = GroundTrack.segments(GroundTrack.points(elements: rated.record.elements, from: pass.aos.addingTimeInterval(-margin),
                                                           through: pass.los.addingTimeInterval(margin), step: 15))
        let during = GroundTrack.segments(GroundTrack.points(elements: rated.record.elements, from: pass.aos, through: pass.los, step: 5))
        let footprint = footprint()
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            ForEach(Array(wide.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(HiveInk.cyan.opacity(0.35), lineWidth: 2)
            }
            ForEach(Array(during.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(HiveInk.mint, lineWidth: 4)
            }
            if let footprint {
                MapCircle(center: footprint.center, radius: footprint.radiusMeters)
                    .foregroundStyle(HiveInk.amber.opacity(0.10))
                    .stroke(HiveInk.amber.opacity(0.7), lineWidth: 1.5)
            }
            Marker("Your antenna", systemImage: "antenna.radiowaves.left.and.right",
                   coordinate: CLLocationCoordinate2D(latitude: observer.latitudeDegrees, longitude: observer.longitudeDegrees))
                .tint(.white)
        }
        .mapStyle(.imagery(elevation: .flat))
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Ground track of the pass over the Earth, with the area the satellite can see at closest approach")
    }

    private func footprint() -> (center: CLLocationCoordinate2D, radiusMeters: Double)? {
        guard let propagator = try? SGP4Propagator(rated.record.elements),
              let state = try? propagator.state(at: rated.pass.tca) else { return nil }
        let under = GroundTrack.subpoint(of: state, at: rated.pass.tca)
        return (CLLocationCoordinate2D(latitude: under.coordinate.latitude, longitude: under.coordinate.longitude),
                GroundTrack.footprintRadiusKM(altitudeKM: under.altitudeKM) * 1000)
    }
}
