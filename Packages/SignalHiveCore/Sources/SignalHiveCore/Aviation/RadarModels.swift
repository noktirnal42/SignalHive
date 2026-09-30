import Foundation

// FIS-B broadcasts precipitation radar (NEXRAD) as "blocks": a patch of the globe 32 bins wide and 4 bins tall, each
// bin holding an intensity level 0 ... 7. These types hold that data independently of any decoder; an adapter
// converts the decoder's own block type (see `UATFeedAdapter`), and the demo scenario makes them too.

public enum RadarProduct: String, CaseIterable, Sendable, Codable {
    /// FIS-B product 63: the area around the ground station, finest detail.
    case regional
    /// FIS-B product 64: the whole contiguous United States, coarser.
    case conus

    public var displayName: String {
        switch self {
        case .regional: return "Regional NEXRAD"
        case .conus: return "CONUS NEXRAD"
        }
    }
}

/// Identifies where a block sits, so a newer block at the same place replaces the older one.
public struct RadarBlockKey: Sendable, Hashable, Codable {
    public var scale: Int
    public var northArcminutes: Int
    public var westArcminutes: Int
}

/// One block of a radar mosaic.
public struct RadarBlock: Sendable, Hashable, Codable {
    public static let columns = 32
    public static let rows = 4

    public var product: RadarProduct
    /// Observation time, UTC (FIS-B gives only hours and minutes).
    public var hours: Int
    public var minutes: Int
    /// 0 is the finest resolution; 1 and 2 make each bin 5 or 9 times larger in both directions.
    public var scale: Int
    /// North edge, in arcminutes of latitude (negative south of the equator).
    public var northArcminutes: Int
    /// West edge, in arcminutes of longitude east of Greenwich, -10800 ..< 10800.
    public var westArcminutes: Int
    public var heightArcminutes: Int
    public var widthArcminutes: Int
    /// Intensity levels 0 ... 7, west to east then north to south (32 per row); normally 128 of them.
    public var bins: [UInt8]

    public init(product: RadarProduct, hours: Int, minutes: Int, scale: Int = 0, northArcminutes: Int, westArcminutes: Int,
                heightArcminutes: Int, widthArcminutes: Int, bins: [UInt8]) {
        self.product = product
        self.hours = hours
        self.minutes = minutes
        self.scale = scale
        self.northArcminutes = northArcminutes
        self.westArcminutes = westArcminutes
        self.heightArcminutes = heightArcminutes
        self.widthArcminutes = widthArcminutes
        self.bins = bins
    }

    public var key: RadarBlockKey {
        RadarBlockKey(scale: scale, northArcminutes: northArcminutes, westArcminutes: westArcminutes)
    }

    /// The strongest intensity in the block.
    public var peakLevel: UInt8 { bins.max() ?? 0 }
}

/// Every radar block heard for one product, one per position, plus when each arrived.
///
/// Ground stations repeat their blocks every few minutes and several stations can cover the same area, so a block at
/// a position already held simply replaces the old one. Blocks not refreshed for a while are dropped, because old
/// radar is worse than none.
public struct RadarMosaic: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var block: RadarBlock
        public var receivedAt: Date
    }

    public let product: RadarProduct
    public private(set) var entries: [RadarBlockKey: Entry] = [:]
    public private(set) var lastUpdated: Date?
    /// Increases whenever the mosaic changes, so a view can tell when its picture is out of date.
    public private(set) var revision = 0

    public init(product: RadarProduct) {
        self.product = product
    }

    public var blockCount: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// The blocks in a stable order (coarse first, then north to south, west to east).
    public var blocks: [RadarBlock] {
        entries.values.map(\.block).sorted {
            if $0.scale != $1.scale { return $0.scale > $1.scale }
            if $0.northArcminutes != $1.northArcminutes { return $0.northArcminutes > $1.northArcminutes }
            return $0.westArcminutes < $1.westArcminutes
        }
    }

    public mutating func add(_ block: RadarBlock, at date: Date) {
        guard block.product == product else { return }
        entries[block.key] = Entry(block: block, receivedAt: date)
        lastUpdated = date
        revision += 1
    }

    /// Drops blocks received more than `age` seconds before `now`.
    public mutating func expire(olderThan age: TimeInterval, now: Date) {
        let cutoff = now.addingTimeInterval(-age)
        let kept = entries.filter { $0.value.receivedAt >= cutoff }
        if kept.count != entries.count {
            entries = kept
            revision += 1
        }
    }

    /// The observation time of the most recently received block, as "HH:MMZ".
    public var latestObservationLabel: String? {
        guard let newest = entries.values.max(by: { $0.receivedAt < $1.receivedAt }) else { return nil }
        return String(format: "%02d:%02dZ", newest.block.hours, newest.block.minutes)
    }

    /// The area covered, in degrees (west/east in -180 ... 180).
    public var bounds: (north: Double, south: Double, west: Double, east: Double)? {
        let blocks = entries.values.map(\.block)
        guard let north = blocks.map(\.northArcminutes).max(),
              let south = blocks.map({ $0.northArcminutes - $0.heightArcminutes }).min(),
              let west = blocks.map(\.westArcminutes).min(),
              let east = blocks.map({ $0.westArcminutes + $0.widthArcminutes }).max() else { return nil }
        return (Double(north) / 60, Double(south) / 60, Double(west) / 60, Double(east) / 60)
    }

    public func raster(maxDimension: Int = 2048) -> RadarRaster? {
        RadarRasterizer.raster(from: blocks, maxDimension: maxDimension)
    }
}

// MARK: - Palette

public enum RadarPalette {
    public struct RGBA: Sendable, Equatable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8
        public var alpha: UInt8
    }

    /// Intensity levels as FIS-B publishes them for its 8-level NEXRAD products. The dBZ bands are those of the
    /// product description and are approximate.
    public static let levelLabels: [String] = [
        "No echo (below 5 dBZ)",
        "Trace (5 to 20 dBZ)",
        "Light (20 to 30 dBZ)",
        "Moderate (30 to 40 dBZ)",
        "Heavy (40 to 45 dBZ)",
        "Very heavy (45 to 50 dBZ)",
        "Intense (50 to 55 dBZ)",
        "Extreme (55 dBZ and up)",
    ]

    /// Level 0 and 1 are transparent so the map shows through; rain and storms go from green to magenta.
    public static func color(level: Int) -> RGBA {
        switch level {
        case 2: return RGBA(red: 60, green: 200, blue: 110, alpha: 150)
        case 3: return RGBA(red: 250, green: 225, blue: 60, alpha: 165)
        case 4: return RGBA(red: 255, green: 150, blue: 40, alpha: 180)
        case 5: return RGBA(red: 240, green: 60, blue: 50, alpha: 190)
        case 6: return RGBA(red: 200, green: 30, blue: 140, alpha: 200)
        case 7: return RGBA(red: 245, green: 130, blue: 255, alpha: 215)
        default: return RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        }
    }

    public static func label(level: Int) -> String {
        levelLabels.indices.contains(level) ? levelLabels[level] : "Unknown"
    }

    /// The levels worth showing on a legend (the visible ones).
    public static let legendLevels = [2, 3, 4, 5, 6, 7]
}

// MARK: - Raster

/// A radar picture ready to lay over a Web Mercator map: premultiplied RGBA, top row north.
///
/// Rows are spaced evenly in Mercator "y", not in latitude, so the picture lines up with map tiles when stretched
/// between its corner coordinates.
public struct RadarRaster: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public let north: Double
    public let south: Double
    public let west: Double
    public let east: Double

    public func pixel(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    /// The number of pixels that show any echo.
    public var echoPixelCount: Int {
        var count = 0
        var index = 3
        while index < pixels.count {
            if pixels[index] != 0 { count += 1 }
            index += 4
        }
        return count
    }
}

public enum RadarRasterizer {
    /// Paints `blocks` into one picture at the finest resolution present, coarse blocks first so finer ones replace
    /// them where they overlap. Uncovered pixels stay transparent. Returns nil when there is nothing to paint.
    public static func raster(from blocks: [RadarBlock], maxDimension: Int = 2048) -> RadarRaster? {
        let usable = blocks.filter { $0.widthArcminutes > 0 && $0.heightArcminutes > 0 && !$0.bins.isEmpty }
        guard !usable.isEmpty,
              let northArc = usable.map(\.northArcminutes).max(),
              let southArc = usable.map({ $0.northArcminutes - $0.heightArcminutes }).min(),
              let westArc = usable.map(\.westArcminutes).min(),
              let eastArc = usable.map({ $0.westArcminutes + $0.widthArcminutes }).max(),
              let finestWidth = usable.map({ Double($0.widthArcminutes) / Double(RadarBlock.columns) }).min(),
              let finestHeight = usable.map({ Double($0.heightArcminutes) / Double(RadarBlock.rows) }).min() else { return nil }

        let north = Double(northArc) / 60
        let south = Double(southArc) / 60
        let west = Double(westArc) / 60
        let east = Double(eastArc) / 60
        let longitudeSpan = east - west
        guard longitudeSpan > 0, north > south else { return nil }

        let yTop = GeoMath.mercatorY(latitude: north)
        let yBottom = GeoMath.mercatorY(latitude: south)
        let ySpan = yTop - yBottom
        guard ySpan > 0 else { return nil }

        // One pixel per finest bin: horizontally in longitude, vertically in Mercator units at the middle latitude.
        let middle = (north + south) / 2
        let halfBin = finestHeight / 120
        let binMercator = GeoMath.mercatorY(latitude: middle + halfBin) - GeoMath.mercatorY(latitude: middle - halfBin)
        var width = max(1, Int((longitudeSpan / (finestWidth / 60)).rounded()))
        var height = max(1, Int((ySpan / max(binMercator, 1e-9)).rounded()))
        let limit = max(16, maxDimension)
        if width > limit || height > limit {
            let shrink = min(Double(limit) / Double(width), Double(limit) / Double(height))
            width = max(1, Int(Double(width) * shrink))
            height = max(1, Int(Double(height) * shrink))
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for block in usable.sorted(by: { $0.scale > $1.scale }) {
            paint(block, into: &pixels, width: width, height: height, west: west, longitudeSpan: longitudeSpan,
                  yTop: yTop, ySpan: ySpan)
        }
        return RadarRaster(width: width, height: height, pixels: pixels, north: north, south: south, west: west, east: east)
    }

    private static func paint(_ block: RadarBlock, into pixels: inout [UInt8], width: Int, height: Int, west: Double,
                              longitudeSpan: Double, yTop: Double, ySpan: Double) {
        let binWidth = Double(block.widthArcminutes) / Double(RadarBlock.columns)     // arcminutes
        let binHeight = Double(block.heightArcminutes) / Double(RadarBlock.rows)
        for (index, level) in block.bins.prefix(RadarBlock.columns * RadarBlock.rows).enumerated() {
            let column = index % RadarBlock.columns
            let row = index / RadarBlock.columns
            let binWest = (Double(block.westArcminutes) + Double(column) * binWidth) / 60
            let binEast = binWest + binWidth / 60
            let binNorth = (Double(block.northArcminutes) - Double(row) * binHeight) / 60
            let binSouth = binNorth - binHeight / 60

            // A pixel belongs to the bin that contains its centre, so bins partition the picture with no gaps or overlaps
            // even though Mercator rows are not exactly uniform in latitude.
            let color = RadarPalette.color(level: Int(level))
            let xFrom = (binWest - west) / longitudeSpan * Double(width)
            let xTo = (binEast - west) / longitudeSpan * Double(width)
            let yFrom = (yTop - GeoMath.mercatorY(latitude: binNorth)) / ySpan * Double(height)
            let yTo = (yTop - GeoMath.mercatorY(latitude: binSouth)) / ySpan * Double(height)
            guard let columns = pixelRange(xFrom, xTo, limit: width, paintsNothing: color.alpha == 0),
                  let rows = pixelRange(yFrom, yTo, limit: height, paintsNothing: color.alpha == 0) else { continue }
            let x0 = columns.lowerBound, x1 = columns.upperBound
            let y0 = rows.lowerBound, y1 = rows.upperBound

            // Premultiplied, because that is what CoreGraphics wants for a translucent picture.
            let alpha = Int(color.alpha)
            let r = UInt8(Int(color.red) * alpha / 255)
            let g = UInt8(Int(color.green) * alpha / 255)
            let b = UInt8(Int(color.blue) * alpha / 255)
            for y in y0..<y1 {
                var offset = (y * width + x0) * 4
                for _ in x0..<x1 {
                    pixels[offset] = r
                    pixels[offset + 1] = g
                    pixels[offset + 2] = b
                    pixels[offset + 3] = color.alpha
                    offset += 4
                }
            }
        }
    }

    /// The pixels whose centres lie in [from, to). A bin smaller than a pixel gets the pixel it falls in, unless it is
    /// transparent (a transparent sliver must not erase a neighbour's echo).
    private static func pixelRange(_ from: Double, _ to: Double, limit: Int, paintsNothing: Bool) -> Range<Int>? {
        var low = Int((from - 0.5).rounded(.up))
        var high = Int((to - 0.5).rounded(.up))
        if high <= low {
            if paintsNothing { return nil }
            low = Int(((from + to) / 2).rounded(.down))
            high = low + 1
        }
        low = max(0, low)
        high = min(limit, high)
        return low < high ? low..<high : nil
    }
}
