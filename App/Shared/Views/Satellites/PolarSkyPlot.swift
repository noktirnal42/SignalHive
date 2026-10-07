import SwiftUI
import SignalHiveCore

/// The pass drawn on the sky: zenith in the centre, the horizon on the outer ring, north up. All geometry comes from
/// `PolarProjection`; the live needle comes from `PointingGuide`.
struct PolarSkyPlot: View {
    let pass: PredictedPass
    let utc: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let guide = PointingGuide(pass: pass).state(at: timeline.date)
            Canvas { context, size in
                let side = min(size.width, size.height)
                let radius = side / 2 - 22
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                func point(_ az: Double, _ el: Double) -> CGPoint {
                    let p = PolarProjection.point(azimuthDegrees: az, elevationDegrees: el, radius: radius)
                    return CGPoint(x: center.x + p.x, y: center.y - p.y)
                }
                // Rings at 0, 30 and 60 degrees of elevation, and the four compass lines.
                for el in [0.0, 30, 60] {
                    let r = radius * (90 - el) / 90
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                                   with: .color(.white.opacity(el == 0 ? 0.35 : 0.14)), lineWidth: el == 0 ? 1.2 : 0.8)
                }
                var spokes = Path()
                for az in stride(from: 0.0, to: 360, by: 90) {
                    spokes.move(to: center)
                    spokes.addLine(to: point(az, 0))
                }
                context.stroke(spokes, with: .color(.white.opacity(0.12)), lineWidth: 0.8)
                for (label, az) in [("N", 0.0), ("E", 90), ("S", 180), ("W", 270)] {
                    let p = PolarProjection.point(azimuthDegrees: az, elevationDegrees: 0, radius: radius + 12)
                    context.draw(Text(label).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.7)),
                                 at: CGPoint(x: center.x + p.x, y: center.y - p.y))
                }
                for el in [30.0, 60] {
                    context.draw(Text("\(Int(el))°").font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.4)),
                                 at: CGPoint(x: center.x + 10, y: center.y - radius * (90 - el) / 90 - 6))
                }
                // The track.
                var track = Path()
                for (index, p) in pass.track.enumerated() {
                    let at = point(p.azimuthDegrees, p.elevationDegrees)
                    if index == 0 { track.move(to: at) } else { track.addLine(to: at) }
                }
                context.stroke(track, with: .color(HiveInk.cyan), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                func mark(_ label: String, _ az: Double, _ el: Double, _ tint: Color) {
                    let at = point(az, el)
                    context.fill(Path(ellipseIn: CGRect(x: at.x - 4, y: at.y - 4, width: 8, height: 8)), with: .color(tint))
                    context.draw(Text(label).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(tint),
                                 at: CGPoint(x: at.x + 16, y: at.y - 9))
                }
                mark("AOS", pass.aosAzimuthDegrees, pass.track.first?.elevationDegrees ?? 0, HiveInk.mint)
                mark("TCA", pass.tcaAzimuthDegrees, pass.maxElevationDegrees, HiveInk.amber)
                mark("LOS", pass.losAzimuthDegrees, pass.track.last?.elevationDegrees ?? 0, HiveInk.copper)
                // Where it is right now, during the pass.
                if case .inPass = guide.phase, let az = guide.azimuthDegrees, let el = guide.elevationDegrees {
                    let at = point(az, el)
                    context.stroke(Path(ellipseIn: CGRect(x: at.x - 9, y: at.y - 9, width: 18, height: 18)), with: .color(.white), lineWidth: 2)
                    var needle = Path()
                    needle.move(to: center)
                    needle.addLine(to: at)
                    context.stroke(needle, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .accessibilityLabel("Sky plot of the pass: rises at \(Int(pass.aosAzimuthDegrees)) degrees azimuth, peaks at \(Int(pass.maxElevationDegrees)) degrees elevation, sets at \(Int(pass.losAzimuthDegrees)) degrees azimuth")
        }
    }
}

/// "Point here now": a readout driven by the same guide, for a hand-held antenna.
struct PointingReadout: View {
    let pass: PredictedPass
    let carrierHz: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let guide = PointingGuide(pass: pass).state(at: timeline.date)
            VStack(alignment: .leading, spacing: 4) {
                switch guide.phase {
                case let .beforeAOS(seconds):
                    Text("Rises in \(PassFormat.countdown(seconds))")
                        .font(.system(.headline, design: .rounded))
                    Text("Look \(guide.compass) (azimuth \(Int((guide.azimuthDegrees ?? 0).rounded()))°) at the horizon")
                        .foregroundStyle(.white.opacity(0.7))
                case let .inPass(secondsToLOS):
                    Text("Point here now: \(guide.compass) \(Int((guide.azimuthDegrees ?? 0).rounded()))°, elevation \(Int((guide.elevationDegrees ?? 0).rounded()))°")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(HiveInk.mint)
                    HStack(spacing: 12) {
                        Text("Sets in \(PassFormat.countdown(secondsToLOS))")
                        if let carrierHz, let shift = guide.dopplerHz(carrierHz: carrierHz) {
                            Text("Doppler \(shift >= 0 ? "+" : "")\(String(format: "%.2f", shift / 1000)) kHz at \(PassFormat.megahertz(carrierHz))")
                        }
                    }
                    .foregroundStyle(.white.opacity(0.7))
                case .after:
                    Text("This pass is over").font(.system(.headline, design: .rounded))
                }
            }
            .font(.callout)
        }
    }
}
