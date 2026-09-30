import Testing
@testable import SignalHiveCore

struct RTLSDRLibraryTests {
    private let paths = ["/opt/homebrew/lib/librtlsdr.dylib", "/usr/local/lib/librtlsdr.dylib", "/App/Contents/Frameworks/librtlsdr.dylib"]

    @Test func whenNothingLoadsTheReportSaysWhatWasTriedAndWhy() {
        let result = RTLSDRLibrary.locate(paths: paths, open: { path in
            (nil, "dlopen(\(path)): library load disallowed by system policy")
        }, hasSymbols: { _ in true })
        #expect(result.handle == nil)
        guard case let .loadFailed(attempts) = result.status.state else {
            Issue.record("expected loadFailed, got \(result.status.state)")
            return
        }
        #expect(attempts.count == 3)                                   // every candidate was tried
        #expect(attempts[0].path == paths[0])
        #expect(attempts[0].reason.contains("library load disallowed"))
        #expect(result.status.summary.contains("library load disallowed"))
        #expect(!result.status.isAvailable)
    }

    @Test func aLaterCandidateIsUsedWhenEarlierOnesFail() {
        var tried: [String] = []
        let result = RTLSDRLibrary.locate(paths: paths, open: { path in
            tried.append(path)
            return path.hasSuffix("Frameworks/librtlsdr.dylib") ? (UnsafeMutableRawPointer(bitPattern: 0x1000), nil) : (nil, "not found")
        }, hasSymbols: { _ in true })
        #expect(result.handle != nil)
        #expect(result.status.state == .loaded(path: paths[2]))
        #expect(result.status.isAvailable)
        #expect(tried == paths)                                        // stopped at the first success (the last one here)
    }

    @Test func theFirstWorkingCandidateWins() {
        var tried: [String] = []
        let result = RTLSDRLibrary.locate(paths: paths, open: { path in
            tried.append(path)
            return (UnsafeMutableRawPointer(bitPattern: 0x2000), nil)
        }, hasSymbols: { _ in true })
        #expect(result.status.state == .loaded(path: paths[0]))
        #expect(tried == [paths[0]])
    }

    @Test func aLibraryMissingRequiredFunctionsIsReportedNotUsed() {
        let result = RTLSDRLibrary.locate(paths: [paths[0]], open: { _ in (UnsafeMutableRawPointer(bitPattern: 0x3000), nil) },
                                          hasSymbols: { _ in false })
        #expect(result.handle == nil)
        guard case let .loadFailed(attempts) = result.status.state else {
            Issue.record("expected loadFailed")
            return
        }
        #expect(attempts.first?.reason.contains("missing") == true)
    }

    @Test func aBundledCopyIsTriedBeforeSystemInstalls() {
        let ordered = RTLSDRLibrary.candidatePaths(bundlePath: "/Apps/SignalHive.app")
        #expect(ordered.first == "/Apps/SignalHive.app/Contents/Frameworks/librtlsdr.dylib")
        #expect(ordered.contains("/opt/homebrew/lib/librtlsdr.dylib"))
        #expect(ordered.contains("/usr/local/lib/librtlsdr.dylib"))
    }
}
