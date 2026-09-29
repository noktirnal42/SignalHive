import Foundation
import SignalHiveCore

// signalhive-packbuilder
//
//   signalhive-packbuilder --out DIR [--snapshot YYYY-MM-DD] [--states AL,GA]
//                          [--work DIR] --archive PATH [--archive PATH ...]
//
// Builds one compressed SQLite pack per state (plus manifest.json) from FCC ULS
// weekly archives (l_LMpriv.zip, l_LMcomm.zip, l_gmrs.zip, ...).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

var outputDirectory: URL?
var workDirectory: URL?
var snapshot: String = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date())
}()
var states: Set<String>?
var archives: [URL] = []

var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    func value() -> String {
        guard let next = arguments.popFirst() else { fail("\(flag) needs a value") }
        return next
    }
    switch flag {
    case "--out": outputDirectory = URL(fileURLWithPath: value())
    case "--work": workDirectory = URL(fileURLWithPath: value())
    case "--snapshot": snapshot = value()
    case "--states": states = Set(value().uppercased().split(separator: ",").map(String.init))
    case "--archive": archives.append(URL(fileURLWithPath: value()))
    default: fail("unknown option \(flag)")
    }
}

guard let outputDirectory else { fail("--out DIR is required") }
guard !archives.isEmpty else { fail("at least one --archive PATH is required") }
for archive in archives where !FileManager.default.fileExists(atPath: archive.path) {
    fail("archive not found: \(archive.path)")
}

/// Prints each new build phase once, with elapsed time. Progress arrives on the builder's thread.
final class PhasePrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPhase = ""
    let started = Date()

    func report(_ update: PackBuildProgress) {
        lock.lock()
        defer { lock.unlock() }
        guard update.phase != lastPhase else { return }
        lastPhase = update.phase
        let elapsed = Date().timeIntervalSince(started)
        FileHandle.standardError.write(Data(String(format: "[%6.1fs] %3.0f%%  %@\n", elapsed, update.fraction * 100, update.phase).utf8))
    }
}

let work = workDirectory ?? outputDirectory.appendingPathComponent(".work")
let printer = PhasePrinter()
let started = printer.started

do {
    let manifest = try PackBuilder(workDirectory: work, outputDirectory: outputDirectory).build(
        sources: archives.map { ZipTableSource(archiveURL: $0) },
        states: states,
        snapshotDate: snapshot,
        progress: { printer.report($0) }
    )
    print("state  licenses   sites  frequencies  compressed   expanded")
    for pack in manifest.packs {
        print(String(format: "%@  %8d %7d %12d %9.2f MB %8.2f MB", pack.stateCode, pack.licenseCount, pack.siteCount,
                     pack.frequencyCount, Double(pack.compressedBytes) / 1e6, Double(pack.expandedBytes) / 1e6))
    }
    let compressed = manifest.packs.reduce(Int64(0)) { $0 + $1.compressedBytes }
    print(String(format: "\n%d packs, %.1f MB compressed total, %.1fs", manifest.packs.count, Double(compressed) / 1e6,
                 Date().timeIntervalSince(started)))
} catch {
    fail(error.localizedDescription)
}
