import Foundation

// MARK: - Line splitting and record streaming

/// Splits a byte stream into lines without ever holding more than one chunk plus a
/// partial line. Safe across arbitrary chunk boundaries; strips CRLF.
public struct ULSLineSplitter {
    private var carry = Data()

    public init() {}

    /// Emits each complete line as raw bytes.
    public mutating func feedBytes(_ chunk: Data, emit: (Data) throws -> Void) rethrows {
        var cursor = chunk.startIndex
        while cursor < chunk.endIndex {
            guard let newline = chunk[cursor...].firstIndex(of: 0x0A) else {
                carry.append(chunk[cursor...])
                return
            }
            if carry.isEmpty {
                try emitLine(chunk[cursor..<newline], emit: emit)
            } else {
                carry.append(chunk[cursor..<newline])
                let line = carry
                carry.removeAll(keepingCapacity: true)
                try emitLine(line[...], emit: emit)
            }
            cursor = chunk.index(after: newline)
        }
    }

    public mutating func finishBytes(emit: (Data) throws -> Void) rethrows {
        guard !carry.isEmpty else { return }
        let line = carry
        carry.removeAll(keepingCapacity: true)
        try emitLine(line[...], emit: emit)
    }

    /// Emits each complete line decoded as text.
    public mutating func feed(_ chunk: Data, emit: (String) throws -> Void) rethrows {
        try feedBytes(chunk) { try emit(Self.decode($0)) }
    }

    public mutating func finish(emit: (String) throws -> Void) rethrows {
        try finishBytes { try emit(Self.decode($0)) }
    }

    private func emitLine(_ slice: Data.SubSequence, emit: (Data) throws -> Void) rethrows {
        var line = Data(slice)
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty else { return }
        try emit(line)
    }

    /// FCC files are usually UTF-8 but occasionally carry Windows-1252 bytes.
    static func decode(_ bytes: Data) -> String {
        if let text = String(data: bytes, encoding: .utf8) { return text }
        if let text = String(data: bytes, encoding: .windowsCP1252) { return text }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum ULSStream {

    /// Calls `body` for every pipe-delimited record in `table`.
    ///
    /// `uidFilter`, when given, is evaluated on field 1 *before* the line is decoded and
    /// split, so rows for licenses we do not want (most of the file) cost almost nothing.
    public static func forEachRecord(
        in source: any ULSTableSource,
        table: ULSTable,
        uidFilter: ((Int64) -> Bool)? = nil,
        body: (ULSRawRecord) throws -> Void
    ) throws {
        func handle(_ line: Data) throws {
            if let uidFilter {
                guard let uid = uid(inLine: line), uidFilter(uid) else { return }
            }
            let text = ULSLineSplitter.decode(line)
            let fields = text.utf8
                .split(separator: 0x7C, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            guard fields.count > 1 else { return }
            try body(ULSRawRecord(fields: fields))
        }

        var splitter = ULSLineSplitter()
        try source.stream(table) { chunk in
            try splitter.feedBytes(chunk, emit: handle)
        }
        try splitter.finishBytes(emit: handle)
    }

    /// Reads the numeric unique-system-identifier (field 1) straight from the bytes.
    static func uid(inLine line: Data) -> Int64? {
        line.withUnsafeBytes { raw -> Int64? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count, bytes[index] != 0x7C { index += 1 }   // record type
            index += 1
            var value: Int64 = 0
            var digits = 0
            while index < bytes.count, bytes[index] != 0x7C {
                let byte = bytes[index]
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int64(byte - 0x30)
                digits += 1
                index += 1
            }
            return digits > 0 ? value : nil
        }
    }
}
