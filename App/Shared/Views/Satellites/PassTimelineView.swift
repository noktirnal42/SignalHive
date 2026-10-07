import SwiftUI
import SignalHiveCore

/// One lane per satellite over the prediction window. Bars are coloured by grade and made taller by peak elevation;
/// daylight is a pale band, "now" a line. The layout is in UTC and only the labels follow the zone toggle.
struct PassTimelineView: View {
    let passes: [RatedPass]
    let from: Date
    let through: Date
    let observer: Observer?
    let utc: Bool
    @Binding var selectedID: String?

    private let labelWidth: CGFloat = 132
    private let laneHeight: CGFloat = 30

    var body: some View {
        let layout = TimelineLayout(passes: passes, from: from, through: through, observer: observer)
        let height = CGFloat(max(1, layout.lanes.count)) * laneHeight + 26
        GeometryReader { geometry in
            let width = max(10, geometry.size.width - labelWidth)
            Canvas { context, size in
                let top: CGFloat = 20
                // Daylight and hour ticks.
                for range in layout.daylight {
                    let x0 = labelWidth + layout.x(for: range.lowerBound, width: width)
                    let x1 = labelWidth + layout.x(for: range.upperBound, width: width)
                    context.fill(Path(CGRect(x: x0, y: top, width: x1 - x0, height: size.height - top)), with: .color(HiveInk.amber.opacity(0.07)))
                }
                var tick = from.addingTimeInterval(-from.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6 * 3600) + 6 * 3600)
                while tick < through {
                    let x = labelWidth + layout.x(for: tick, width: width)
                    context.stroke(Path { $0.move(to: CGPoint(x: x, y: top)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                   with: .color(.white.opacity(0.10)), lineWidth: 0.7)
                    context.draw(Text(PassFormat.hourLabel(tick, utc: utc)).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.5)),
                                 at: CGPoint(x: x, y: 9))
                    tick.addTimeInterval(6 * 3600)
                }
                // Lanes and their passes.
                for (index, lane) in layout.lanes.enumerated() {
                    let y = top + CGFloat(index) * laneHeight
                    context.draw(Text(lane.name).font(.system(size: 11, design: .rounded)).foregroundColor(.white.opacity(0.85)),
                                 at: CGPoint(x: 6, y: y + laneHeight / 2), anchor: .leading)
                    context.stroke(Path { $0.move(to: CGPoint(x: labelWidth, y: y + laneHeight)); $0.addLine(to: CGPoint(x: size.width, y: y + laneHeight)) },
                                   with: .color(.white.opacity(0.06)), lineWidth: 0.6)
                    for rated in lane.passes {
                        let x0 = labelWidth + layout.x(for: rated.pass.aos, width: width)
                        let x1 = labelWidth + layout.x(for: rated.pass.los, width: width)
                        let barHeight = 6 + CGFloat(min(rated.pass.maxElevationDegrees, 90) / 90) * (laneHeight - 10)
                        let rect = CGRect(x: x0, y: y + laneHeight - 3 - barHeight, width: max(3, x1 - x0), height: barHeight)
                        let tint = PassFormat.gradeColor(rated.rating.grade)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(tint.opacity(rated.id == selectedID ? 1 : 0.7)))
                        if rated.id == selectedID {
                            context.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3), with: .color(.white), lineWidth: 1.5)
                        }
                    }
                }
                // Now.
                let nowX = labelWidth + layout.x(for: Date(), width: width)
                if nowX >= labelWidth, nowX <= size.width {
                    context.stroke(Path { $0.move(to: CGPoint(x: nowX, y: top - 4)); $0.addLine(to: CGPoint(x: nowX, y: size.height)) },
                                   with: .color(HiveInk.copper), lineWidth: 1.4)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                let layout = TimelineLayout(passes: passes, from: from, through: through)
                let laneIndex = Int((tap.location.y - 20) / laneHeight)
                guard layout.lanes.indices.contains(laneIndex) else { return }
                let span = through.timeIntervalSince(from)
                let tapped = from.addingTimeInterval(Double((tap.location.x - labelWidth) / width) * span)
                // The nearest pass in that lane, within a few pixels of its bar.
                let slack = Double(8 / width) * span
                let hit = layout.lanes[laneIndex].passes.min {
                    abs(midpoint($0).timeIntervalSince(tapped)) < abs(midpoint($1).timeIntervalSince(tapped))
                }
                if let hit, tapped >= hit.pass.aos.addingTimeInterval(-slack), tapped <= hit.pass.los.addingTimeInterval(slack) {
                    selectedID = hit.id
                }
            })
        }
        .frame(height: height)
        .accessibilityLabel("Timeline of \(passes.count) passes across \(layout.lanes.count) satellites")
    }

    private func midpoint(_ rated: RatedPass) -> Date { rated.pass.aos.addingTimeInterval(rated.pass.duration / 2) }
}
