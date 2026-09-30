import SwiftUI
import SignalHiveCore

extension Color {
    init(_ rgb: RGB8, opacity: Double = 1) {
        self.init(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255, opacity: opacity)
    }
}

/// Paints the generated aircraft icons (`AircraftIconData`) into a SwiftUI canvas: a soft shadow, a dark outline shared by
/// all the parts, the parts in shades of the altitude color, cockpit glass, a sheen, translucent rotor discs, and lines.
/// The layer order is the same one `script/generate_aircraft_icons.py` uses for the preview sheet.
enum AircraftIconRenderer {
    /// The icon geometry as ready-made paths, built once per kind.
    private final class PathCache: @unchecked Sendable {
        struct Prepared {
            var paint: AircraftIconPart.Paint
            var path: Path
            var lineWidth: CGFloat
            var isLine: Bool
        }

        private let lock = NSLock()
        private var storage: [AircraftIconKind: [Prepared]] = [:]

        func parts(for kind: AircraftIconKind) -> [Prepared] {
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[kind] { return cached }
            let built = kind.parts.compactMap(Self.prepare)
            storage[kind] = built
            return built
        }

        private static func prepare(_ part: AircraftIconPart) -> Prepared? {
            switch part.shape {
            case let .polygon(xy):
                guard xy.count >= 6 else { return nil }
                var path = Path()
                path.move(to: CGPoint(x: xy[0], y: xy[1]))
                var index = 2
                while index + 1 < xy.count {
                    path.addLine(to: CGPoint(x: xy[index], y: xy[index + 1]))
                    index += 2
                }
                path.closeSubpath()
                return Prepared(paint: part.paint, path: path, lineWidth: 0, isLine: false)
            case let .ellipse(cx, cy, rx, ry):
                return Prepared(paint: part.paint, path: Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry)),
                                lineWidth: 0, isLine: false)
            case let .line(x1, y1, x2, y2, width):
                var path = Path()
                path.move(to: CGPoint(x: x1, y: y1))
                path.addLine(to: CGPoint(x: x2, y: y2))
                return Prepared(paint: part.paint, path: path, lineWidth: CGFloat(width), isLine: true)
            }
        }
    }

    private static let cache = PathCache()

    /// Draws one icon.
    /// - Parameters:
    ///   - center: Where the middle of the icon goes.
    ///   - headingDegrees: Clockwise from north; the icon's nose points this way.
    ///   - radius: Half the icon's size in points.
    ///   - color: The main color (from the altitude).
    ///   - opacity: Fades aircraft that have gone quiet.
    static func draw(_ kind: AircraftIconKind, in context: inout GraphicsContext, at center: CGPoint, headingDegrees: Double,
                     radius: CGFloat, color: RGB8, opacity: Double = 1) {
        let parts = cache.parts(for: kind)
        guard !parts.isEmpty, radius > 0.5 else { return }
        let detailed = radius >= 8

        // The shadow keeps a fixed direction on screen, so it is offset before the icon is turned.
        var shadow = context
        shadow.opacity = opacity * 0.35
        shadow.translateBy(x: center.x + radius * 0.06, y: center.y + radius * 0.08)
        shadow.rotate(by: .degrees(headingDegrees))
        shadow.scaleBy(x: radius, y: radius)
        for part in parts where !part.isLine && Self.isFill(part.paint) {
            shadow.fill(part.path, with: .color(.black))
        }

        var icon = context
        icon.opacity = opacity
        icon.translateBy(x: center.x, y: center.y)
        icon.rotate(by: .degrees(headingDegrees))
        icon.scaleBy(x: radius, y: radius)

        let outline = Color(red: 0.03, green: 0.05, blue: 0.07).opacity(0.92)
        let outlineWidth: CGFloat = detailed ? 0.11 : 0.2
        let base = Color(color)
        let dark = Color(color.toned(0.68))
        let light = Color(color.toned(1.22))

        // The outline first, around every filled part, so overlapping parts share one edge.
        for part in parts where !part.isLine && Self.isFill(part.paint) {
            icon.stroke(part.path, with: .color(outline), style: StrokeStyle(lineWidth: outlineWidth, lineJoin: .round))
        }
        for part in parts where part.isLine && part.paint == .line {
            icon.stroke(part.path, with: .color(outline),
                        style: StrokeStyle(lineWidth: part.lineWidth + outlineWidth * 0.8, lineCap: .round))
        }

        for part in parts where !part.isLine {
            switch part.paint {
            case .body: icon.fill(part.path, with: .color(base))
            case .dark: icon.fill(part.path, with: .color(dark))
            case .light: icon.fill(part.path, with: .color(light))
            default: break
            }
        }
        guard detailed else {
            for part in parts where part.isLine && part.paint == .line {
                icon.stroke(part.path, with: .color(base), style: StrokeStyle(lineWidth: part.lineWidth, lineCap: .round))
            }
            return
        }
        let glass = Color(red: 0.055, green: 0.10, blue: 0.16).opacity(0.8)
        for part in parts where part.paint == .glass {
            if part.isLine {
                icon.stroke(part.path, with: .color(glass), style: StrokeStyle(lineWidth: part.lineWidth, lineCap: .round))
            } else {
                icon.fill(part.path, with: .color(glass))
            }
        }
        for part in parts where part.paint == .highlight {
            icon.fill(part.path, with: .color(.white.opacity(0.28)))
        }
        for part in parts where part.paint == .disc {
            icon.fill(part.path, with: .color(base.opacity(0.16)))
            icon.stroke(part.path, with: .color(base.opacity(0.6)), style: StrokeStyle(lineWidth: 0.02))
        }
        for part in parts where part.isLine && part.paint == .line {
            icon.stroke(part.path, with: .color(base), style: StrokeStyle(lineWidth: part.lineWidth, lineCap: .round))
        }
    }

    private static func isFill(_ paint: AircraftIconPart.Paint) -> Bool {
        paint == .body || paint == .dark || paint == .light
    }
}

/// One icon as a view, for lists and legends.
struct AircraftIconView: View {
    var kind: AircraftIconKind
    var color: RGB8
    var size: CGFloat = 28
    var heading: Double = 0

    var body: some View {
        Canvas { context, canvasSize in
            AircraftIconRenderer.draw(kind, in: &context, at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
                                      headingDegrees: heading, radius: min(canvasSize.width, canvasSize.height) / 2 * 0.92, color: color)
        }
        .frame(width: size, height: size)
    }
}
