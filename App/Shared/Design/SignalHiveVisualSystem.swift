import SwiftUI

enum HiveInk {
    static let graphite = Color(red: 0.055, green: 0.065, blue: 0.075)
    static let panel = Color(red: 0.095, green: 0.105, blue: 0.118)
    static let panelTop = Color(red: 0.145, green: 0.155, blue: 0.168)
    static let copper = Color(red: 0.94, green: 0.49, blue: 0.16)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.20)
    static let cyan = Color(red: 0.10, green: 0.82, blue: 0.92)
    static let blue = Color(red: 0.12, green: 0.32, blue: 0.76)
    static let violet = Color(red: 0.52, green: 0.30, blue: 0.85)
    static let mint = Color(red: 0.35, green: 0.95, blue: 0.72)
}

struct HiveWorkbenchBackground: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [HiveInk.graphite, Color(red: 0.025, green: 0.035, blue: 0.045)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                ))

                let time = timeline.date.timeIntervalSinceReferenceDate
                drawGrid(in: &context, size: size, phase: time)
                drawSweep(in: &context, size: size, phase: time)
            }
            .ignoresSafeArea()
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize, phase: TimeInterval) {
        let spacing: CGFloat = 36
        var path = Path()
        let offset = CGFloat(phase.truncatingRemainder(dividingBy: 6)) * 2

        var x = -spacing + offset
        while x < size.width + spacing {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += spacing
        }

        var y = -spacing + offset
        while y < size.height + spacing {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += spacing
        }

        context.stroke(path, with: .color(HiveInk.cyan.opacity(0.07)), lineWidth: 0.6)
    }

    private func drawSweep(in context: inout GraphicsContext, size: CGSize, phase: TimeInterval) {
        let center = CGPoint(x: size.width * 0.68, y: size.height * 0.18)
        let radius = max(size.width, size.height) * 0.58
        let start = Angle.degrees(-145 + phase.truncatingRemainder(dividingBy: 8) * 14)
        let end = Angle.degrees(start.degrees + 86)
        var arc = Path()
        arc.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.stroke(arc, with: .linearGradient(
            Gradient(colors: [HiveInk.cyan.opacity(0.0), HiveInk.cyan.opacity(0.25), HiveInk.amber.opacity(0.16)]),
            startPoint: CGPoint(x: center.x - radius, y: center.y),
            endPoint: CGPoint(x: center.x + radius, y: center.y)
        ), lineWidth: 2)
    }
}

struct HiveInstrumentPanel<Content: View>: View {
    var title: String?
    var status: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, status: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.status = status
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || status != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    Spacer(minLength: 12)
                    if let status {
                        HiveStatusBadge(status)
                    }
                }
            }
            content
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.linearGradient(
                    colors: [HiveInk.panelTop.opacity(0.96), HiveInk.panel.opacity(0.98)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.linearGradient(
                            colors: [HiveInk.cyan.opacity(0.34), HiveInk.copper.opacity(0.26), .white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
    }
}

struct HiveStatusBadge: View {
    var text: String
    var tint: Color

    init(_ text: String, tint: Color = HiveInk.cyan) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().stroke(tint.opacity(0.26), lineWidth: 1)
            }
    }
}

struct HiveSignalMeter: View {
    var value: Double
    var label: String
    var unit: String
    var tint: Color = HiveInk.amber

    var body: some View {
        TimelineView(.animation) { timeline in
            let pulse = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 2.4)
            Canvas { context, size in
                let clamped = min(1, max(0, value))
                let center = CGPoint(x: size.width / 2, y: size.height * 0.84)
                let radius = min(size.width * 0.45, size.height * 0.78)
                let start = Angle.degrees(205)
                let end = Angle.degrees(335)

                var base = Path()
                base.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                context.stroke(base, with: .color(.white.opacity(0.13)), lineWidth: 10)

                var active = Path()
                active.addArc(
                    center: center,
                    radius: radius,
                    startAngle: start,
                    endAngle: Angle.degrees(start.degrees + (end.degrees - start.degrees) * clamped),
                    clockwise: false
                )
                context.stroke(active, with: .linearGradient(
                    Gradient(colors: [HiveInk.cyan, tint, HiveInk.copper]),
                    startPoint: CGPoint(x: center.x - radius, y: center.y),
                    endPoint: CGPoint(x: center.x + radius, y: center.y)
                ), lineWidth: 10)

                for tick in 0...12 {
                    let t = Double(tick) / 12.0
                    let angle = Angle.degrees(start.degrees + (end.degrees - start.degrees) * t).radians
                    let inner = CGPoint(x: center.x + cos(angle) * (radius - 18), y: center.y + sin(angle) * (radius - 18))
                    let outer = CGPoint(x: center.x + cos(angle) * (radius + 2), y: center.y + sin(angle) * (radius + 2))
                    var tickPath = Path()
                    tickPath.move(to: inner)
                    tickPath.addLine(to: outer)
                    context.stroke(tickPath, with: .color(.white.opacity(tick % 3 == 0 ? 0.34 : 0.18)), lineWidth: tick % 3 == 0 ? 1.4 : 0.8)
                }

                let needleAngle = Angle.degrees(start.degrees + (end.degrees - start.degrees) * clamped).radians
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: CGPoint(x: center.x + cos(needleAngle) * (radius - 22), y: center.y + sin(needleAngle) * (radius - 22)))
                context.stroke(needle, with: .color(tint.opacity(0.82 + pulse * 0.18)), lineWidth: 3)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(.white.opacity(0.75)))
            }
            .overlay(alignment: .center) {
                VStack(spacing: 2) {
                    Text(label)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(unit)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.94))
                }
                .offset(y: 18)
            }
        }
    }
}

struct HiveSpectrumRibbon: View {
    var samples: [Double]
    var tint: Color = HiveInk.cyan

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                let values = samples.isEmpty ? Self.defaultSamples : samples
                let step = size.width / CGFloat(max(values.count - 1, 1))

                var fill = Path()
                fill.move(to: CGPoint(x: 0, y: size.height))
                var line = Path()

                for index in values.indices {
                    let x = CGFloat(index) * step
                    let shimmer = 0.08 * sin(phase * 2.2 + Double(index) * 0.37)
                    let y = size.height * (0.82 - CGFloat(min(1, max(0, values[index] + shimmer))) * 0.66)
                    let point = CGPoint(x: x, y: y)
                    if index == values.startIndex {
                        line.move(to: point)
                    } else {
                        line.addLine(to: point)
                    }
                    fill.addLine(to: point)
                }

                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.34), HiveInk.blue.opacity(0.08), .clear]),
                    startPoint: CGPoint(x: size.width / 2, y: 0),
                    endPoint: CGPoint(x: size.width / 2, y: size.height)
                ))
                context.stroke(line, with: .color(tint.opacity(0.9)), lineWidth: 2)
            }
        }
    }

    private static let defaultSamples: [Double] = [
        0.14, 0.18, 0.16, 0.20, 0.31, 0.19, 0.17, 0.48, 0.22, 0.18,
        0.15, 0.68, 0.33, 0.22, 0.18, 0.25, 0.86, 0.39, 0.24, 0.21,
        0.17, 0.30, 0.52, 0.20, 0.16, 0.18, 0.41, 0.24, 0.18, 0.15
    ]
}
