import Foundation
import ZIPFoundation

// MARK: - ULS table sources
//
// The builder reads ULS tables through this protocol so it never needs to unzip a
// whole archive to disk: `ZipTableSource` streams one entry at a time, and
// `DirectoryTableSource` reads already-extracted `.dat` files (tests, fixtures).

/// The ULS tables the pack builder consumes.
public enum ULSTable: String, Sendable, CaseIterable {
    case EN  // entity (licensee name/address)
    case HD  // license header (status, service, dates)
    case FR  // frequency
    case LO  // location
    case EM  // emission designator
}

public enum ULSTableSourceError: Error, LocalizedError, Equatable {
    case missingTable(ULSTable)
    case unreadableArchive(String)

    public var errorDescription: String? {
        switch self {
        case let .missingTable(table): return "ULS table \(table.rawValue).dat is missing"
        case let .unreadableArchive(name): return "Could not open ULS archive \(name)"
        }
    }
}

public protocol ULSTableSource: Sendable {
    func hasTable(_ table: ULSTable) -> Bool
    /// Feeds the raw bytes of `<table>.dat` to `handler` in chunks.
    /// Throws `ULSTableSourceError.missingTable` when the table is absent.
    func stream(_ table: ULSTable, handler: (Data) throws -> Void) throws
}

public struct DirectoryTableSource: ULSTableSource {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(for table: ULSTable) -> URL {
        directory.appendingPathComponent("\(table.rawValue).dat")
    }

    public func hasTable(_ table: ULSTable) -> Bool {
        FileManager.default.fileExists(atPath: url(for: table).path)
    }

    public func stream(_ table: ULSTable, handler: (Data) throws -> Void) throws {
        guard hasTable(table) else { throw ULSTableSourceError.missingTable(table) }
        let handle = try FileHandle(forReadingFrom: url(for: table))
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try handler(chunk)
        }
    }
}

public struct ZipTableSource: ULSTableSource {
    public let archiveURL: URL

    public init(archiveURL: URL) {
        self.archiveURL = archiveURL
    }

    private func openArchive() throws -> Archive {
        do {
            return try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw ULSTableSourceError.unreadableArchive(archiveURL.lastPathComponent)
        }
    }

    public func hasTable(_ table: ULSTable) -> Bool {
        guard let archive = try? openArchive() else { return false }
        return archive["\(table.rawValue).dat"] != nil
    }

    public func stream(_ table: ULSTable, handler: (Data) throws -> Void) throws {
        let archive = try openArchive()
        guard let entry = archive["\(table.rawValue).dat"] else {
            throw ULSTableSourceError.missingTable(table)
        }
        _ = try archive.extract(entry, bufferSize: 1 << 20, skipCRC32: true) { data in
            try handler(data)
        }
    }
}
