import SwiftUI
import SignalHiveCore

/// Everything about one pass: the rating and why, where to point, the sky plot, the ground track, elevation and
/// predicted Doppler, and the facts the prediction rests on.
struct PassInspectorView: View {
    let rated: RatedPass
    let observer: Observer
    let utc: Bool

    var body: some View {
        let pass = rated.pass
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pass.satelliteName)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Text("\(PassFormat.day(pass.aos, utc: utc))  \(PassFormat.time(pass.aos, utc: utc)) to \(PassFormat.time(pass.los, utc: utc)) (\(PassFormat.duration(pass.duration)))")
                        .font(.callout).foregroundStyle(.white.opacity(0.7))
                    if pass.startsBeforeWindow || pass.endsAfterWindow {
                        Text(pass.startsBeforeWindow ? "Already under way when the window opened: start cut off." : "Still up at the end of the window: end cut off.")
                            .font(.caption).foregroundStyle(HiveInk.amber)
                    }
                }
                Spacer()
                HiveStatusBadge(PassFormat.gradeName(rated.rating.grade), tint: PassFormat.gradeColor(rated.rating.grade))
            }

            PointingReadout(pass: pass, carrierHz: rated.transmitter?.downlinkHz)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HiveInk.graphite.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("Sky")
                    PolarSkyPlot(pass: pass, utc: utc).frame(width: 300, height: 300)
                }
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("Ground track")
                    GroundTrackMap(rated: rated, observer: observer)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("Elevation")
                    ElevationProfileView(pass: pass, utc: utc)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let transmitter = rated.transmitter {
                        sectionTitle("Predicted Doppler at \(PassFormat.megahertz(transmitter.downlinkHz))")
                        DopplerCurveView(pass: pass, carrierHz: transmitter.downlinkHz, utc: utc)
                    } else {
                        sectionTitle("Doppler")
                        Text("No known downlink, so no Doppler curve.").foregroundStyle(.white.opacity(0.6)).frame(height: 120)
                    }
                }
            }

            ratingPanel
            factsPanel
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).textCase(.uppercase)
    }

    private var ratingPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Why this rating")
                HiveStatusBadge("heuristic", tint: HiveInk.violet)
                Spacer()
                Text("score \(rated.rating.score) of 100").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            ForEach(Array(rated.rating.reasons.enumerated()), id: \.offset) { _, reason in
                Label(reason, systemImage: "circle.fill").labelStyle(BulletLabelStyle())
            }
            if let remedy = rated.rating.remedy {
                Label(remedy, systemImage: "lightbulb").foregroundStyle(HiveInk.amber).font(.callout)
            }
            Text("These rules are first guesses written down so you can check them; they will be replaced by what your own received passes show.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
        }
    }

    private var factsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("What this rests on")
            Text("Elements: \(elementAge). Orbit model: SGP4, accurate to a few kilometres at epoch and drifting after.")
            if let note = rated.record.note { Text(note).foregroundStyle(HiveInk.amber) }
            if let transmitter = rated.transmitter {
                Text("Downlink: \(PassFormat.megahertz(transmitter.downlinkHz)) \(transmitter.mode ?? "unknown mode"), \(PassFormat.decoderText(transmitter.kind.decoderStatus)). \(transmitter.summary)")
                let others = rated.record.transmitters.filter { $0.id != transmitter.id && $0.isActive }
                if others.count > 0 {
                    Text("SatNOGS lists \(others.count) other active downlink\(others.count == 1 ? "" : "s") for this satellite and cannot say which is on air; the lowest in your dongle's range is used as the default: " + others.prefix(6).map { PassFormat.megahertz($0.downlinkHz) }.joined(separator: ", "))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                Text("No active downlink inside the dongle's range is known for this satellite.")
            }
            Text("Peak \(Int(rated.pass.maxElevationDegrees.rounded()))° at \(PassFormat.time(rated.pass.tca, utc: utc)), closest \(Int(rated.pass.minRangeKM.rounded())) km, Sun \(Int(rated.pass.sunElevationAtTCADegrees.rounded()))° (\(rated.pass.sunlitAtTCA ? "satellite sunlit" : "satellite in Earth's shadow")).")
                .foregroundStyle(.white.opacity(0.6))
        }
        .font(.callout)
    }

    private var elementAge: String {
        switch rated.confidence {
        case .good: return "fresh (under 3 days old)"
        case let .aging(days): return "\(Int(days)) days old, aging"
        case let .stale(days): return "\(Int(days)) days old, stale"
        case let .unusable(days): return "\(Int(days)) days old, unusable"
        case .fromTheFuture: return "dated in the future"
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 4)).foregroundStyle(HiveInk.cyan)
            configuration.title.font(.callout)
        }
    }
}
