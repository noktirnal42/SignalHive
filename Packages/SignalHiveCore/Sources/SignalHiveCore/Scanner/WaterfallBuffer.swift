import Foundation

/// Colour map for the waterfall: black at the noise floor through purple, red and orange to pale yellow at the
/// strongest signals. Brightness rises monotonically, so "stronger" always reads as "brighter" (unlike a rainbow).
public enum WaterfallPalette {
    private static let stops: [(t: Float, r: Float, g: Float, b: Float)] = [
        (0.00, 0, 0, 4), (0.14, 31, 12, 72), (0.29, 85, 15, 109), (0.43, 136, 34, 106), (0.57, 186, 54, 85),
        (0.71, 227, 89, 51), (0.86, 249, 140, 10), (0.93, 249, 201, 50), (1.00, 252, 255, 164),
    ]

    /// 256-entry lookup table, built once.
    private static let table: [(r: UInt8, g: UInt8, b: UInt8)] = (0..<256).map { index in
        let t = Float(index) / 255
        let upper = stops.firstIndex { $0.t >= t } ?? stops.count - 1
        let lower = max(0, upper - 1)
        let a = stops[lower], b = stops[upper]
        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        func mix(_ x: Float, _ y: Float) -> UInt8 { UInt8(max(0, min(255, (x + (y - x) * f).rounded()))) }
        return (mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))
    }

    /// `t` is 0...1 (see `SpectrumScale.normalized`).
    public static func color(_ t: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        table[Int(max(0, min(1, t)) * 255)]
    }
}

/// A scrolling waterfall as a pixel buffer (RGBA, row 0 = newest). Each new spectrum is resampled to `width`
/// columns and inserted at the top; older rows move down with one `memmove`, so a frame costs one row of colour
/// lookups however large the image is.
public struct WaterfallBuffer: Sendable {
    public struct Pixel: Equatable, Sendable {
        public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    }

    public let width: Int
    public let height: Int
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        let floor = WaterfallPalette.color(0)
        var buffer = [UInt8](repeating: 255, count: self.width * self.height * 4)
        for index in stride(from: 0, to: buffer.count, by: 4) {
            buffer[index] = floor.r
            buffer[index + 1] = floor.g
            buffer[index + 2] = floor.b
        }
        pixels = buffer
    }

    public func pixel(x: Int, y: Int) -> Pixel {
        let index = (y * width + x) * 4
        return Pixel(r: pixels[index], g: pixels[index + 1], b: pixels[index + 2], a: pixels[index + 3])
    }

    public mutating func push(row: [Float], scale: SpectrumScale) {
        guard !row.isEmpty else { return }
        let rowBytes = width * 4
        if height > 1 {
            pixels.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                memmove(base + rowBytes, base, rowBytes * (height - 1))
            }
        }
        for x in 0..<width {
            let color = WaterfallPalette.color(scale.normalized(Self.value(in: row, column: x, of: width)))
            let index = x * 4
            pixels[index] = color.r
            pixels[index + 1] = color.g
            pixels[index + 2] = color.b
            pixels[index + 3] = 255
        }
    }

    /// More bins than columns: the strongest bin under the column (so a one-bin carrier survives).
    /// Fewer bins than columns: linear interpolation (a smooth gradient instead of hard blocks).
    private static func value(in row: [Float], column x: Int, of width: Int) -> Float {
        let n = row.count
        if n >= width {
            let low = x * n / width
            let high = min(n, max(low + 1, (x + 1) * n / width))
            return row[low..<high].max() ?? row[low]
        }
        let position = (Double(x) + 0.5) * Double(n) / Double(width) - 0.5
        let base = max(0, min(n - 1, Int(position.rounded(.down))))
        let next = min(n - 1, base + 1)
        let fraction = Float(max(0, min(1, position - Double(base))))
        return row[base] * (1 - fraction) + row[next] * fraction
    }
}

/// Lets through at most one frame per `minimumInterval`. The FFT delivers ~125 frames a second, far more than a
/// waterfall row or a SwiftUI redraw needs.
public struct FrameThrottle: Sendable {
    public let minimumInterval: TimeInterval
    private var last: TimeInterval?

    public init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    public mutating func shouldEmit(at now: TimeInterval) -> Bool {
        if let last, now >= last, now - last < minimumInterval { return false }
        last = now                                   // a clock that went backwards simply restarts the interval
        return true
    }
}

extension SpectrumScale {
    /// Moves a fraction `alpha` of the way to `target`, so the display range follows the signal without flicker.
    public func blended(toward target: SpectrumScale, alpha: Float) -> SpectrumScale {
        SpectrumScale(minDB: minDB + (target.minDB - minDB) * alpha,
                      maxDB: maxDB + (target.maxDB - maxDB) * alpha)
    }
}
