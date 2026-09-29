import Testing
import Foundation
@testable import SignalHiveCore

struct ULSStreamTests {
    @Test func linesSplitAcrossChunkBoundariesAndCRLF() {
        var splitter = ULSLineSplitter()
        var lines: [String] = []
        for chunk in ["EN|1|a", "bc\r\nEN|2|d", "ef\nEN|3|g"] {
            splitter.feed(Data(chunk.utf8)) { lines.append($0) }
        }
        splitter.finish { lines.append($0) }
        #expect(lines == ["EN|1|abc", "EN|2|def", "EN|3|g"])
    }

    @Test func latin1BytesDecodeInsteadOfBecomingReplacementCharacters() {
        var splitter = ULSLineSplitter()
        var lines: [String] = []
        // "EN|Añasco" with ñ as the single Latin-1 byte 0xF1 (invalid UTF-8)
        splitter.feed(Data([0x45, 0x4E, 0x7C, 0x41, 0xF1, 0x61, 0x73, 0x63, 0x6F, 0x0A])) { lines.append($0) }
        #expect(lines == ["EN|Añasco"])
    }

    @Test func uidFilterSkipsRowsAndShortLinesDoNotAbortTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uls-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "EN|1|x\nGARBAGE\nEN|2|y\n\nEN|3|z\n"
            .write(to: dir.appendingPathComponent("EN.dat"), atomically: true, encoding: .utf8)

        var seen: [String] = []
        try ULSStream.forEachRecord(in: DirectoryTableSource(directory: dir), table: .EN,
                                    uidFilter: { $0 != 2 }) { seen.append($0.field(2)) }
        #expect(seen == ["x", "z"])
    }

    @Test func missingTableThrowsInsteadOfSilentlyYieldingNothing() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uls-empty-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = DirectoryTableSource(directory: dir)
        #expect(!source.hasTable(.LO))
        #expect(throws: (any Error).self) {
            try ULSStream.forEachRecord(in: source, table: .LO) { _ in }
        }
    }
}
