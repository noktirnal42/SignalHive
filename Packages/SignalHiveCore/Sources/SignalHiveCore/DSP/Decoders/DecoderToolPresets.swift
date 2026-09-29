import Foundation

#if os(macOS)
public struct DecoderToolExecutableLocator: Sendable {
    public var environment: [String: String]
    public var fileExists: @Sendable (String) -> Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.environment = environment
        self.fileExists = fileExists
    }

    public static let live = DecoderToolExecutableLocator()

    public func resolveExecutableURL(
        basenames: [String],
        candidatePaths: [String]
    ) -> URL? {
        for path in candidatePaths where fileExists(path) {
            return URL(fileURLWithPath: path)
        }

        for basename in basenames {
            for path in pathSearchCandidates(for: basename) where fileExists(path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private func pathSearchCandidates(for basename: String) -> [String] {
        let pathValue = environment["PATH"] ?? ""
        return pathValue
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { NSString(string: $0).appendingPathComponent(basename) }
    }
}

public struct DecoderIQBridgeToolPreset: Sendable {
    public var executableBasenames: [String]
    public var candidatePaths: [String]
    public var arguments: [String]
    public var inputTransport: ProcessDecoderIQBridgeInputTransport
    public var outputCapture: ProcessDecoderIQBridgeOutputCapture
    public var workingDirectoryURL: URL?
    public var environment: [String: String]

    public init(
        executableBasenames: [String],
        candidatePaths: [String] = [],
        arguments: [String],
        inputTransport: ProcessDecoderIQBridgeInputTransport,
        outputCapture: ProcessDecoderIQBridgeOutputCapture = .standardOutputAndError,
        workingDirectoryURL: URL? = nil,
        environment: [String: String] = [:]
    ) {
        self.executableBasenames = executableBasenames
        self.candidatePaths = candidatePaths
        self.arguments = arguments
        self.inputTransport = inputTransport
        self.outputCapture = outputCapture
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
    }

    public func resolvedConfiguration(
        locator: DecoderToolExecutableLocator = .live
    ) -> ProcessDecoderIQBridgeConfiguration? {
        guard let executableURL = locator.resolveExecutableURL(
            basenames: executableBasenames,
            candidatePaths: candidatePaths
        ) else {
            return nil
        }

        return ProcessDecoderIQBridgeConfiguration(
            executableURL: executableURL,
            arguments: arguments,
            inputTransport: inputTransport,
            outputCapture: outputCapture,
            workingDirectoryURL: workingDirectoryURL,
            environment: environment
        )
    }

    public func makeBridge(
        locator: DecoderToolExecutableLocator = .live
    ) -> (any DecoderIQBridge)? {
        guard let configuration = resolvedConfiguration(locator: locator) else {
            return nil
        }
        return ProcessDecoderIQBridge(configuration: configuration)
    }
}

public enum DecoderToolPresets {
    // multimon-ng expects mono signed 16-bit raw samples for the common pager paths.
    public static let pagingImageMultimonNG = DecoderIQBridgeToolPreset(
        executableBasenames: ["multimon-ng"],
        candidatePaths: [
            "/opt/homebrew/bin/multimon-ng",
            "/usr/local/bin/multimon-ng",
            NSString(string: Bundle.main.bundlePath).appendingPathComponent("Contents/MacOS/multimon-ng")
        ],
        arguments: [
            "-v", "0",
            "-a", "POCSAG1200",
            "-a", "POCSAG2400",
            "-a", "FLEX",
            "-a", "FLEX_NEXT",
            "-t", "raw",
            "{inputFile}"
        ],
        inputTransport: .temporaryMonoRawFile
    )

    // dsdccx consumes mono S16LE at 48 kS/s and can emit protocol status lines into a file.
    public static let digitalVoiceDSDcc = DecoderIQBridgeToolPreset(
        executableBasenames: ["dsdccx"],
        candidatePaths: [
            "/opt/homebrew/bin/dsdccx",
            "/usr/local/bin/dsdccx",
            NSString(string: Bundle.main.bundlePath).appendingPathComponent("Contents/MacOS/dsdccx")
        ],
        arguments: [
            "-i", "{inputFile}",
            "-fa",
            "-m", "0.1",
            "-M", "{inputDirectory}/dsdcc-status.txt",
            "-o", "/dev/null"
        ],
        inputTransport: .temporaryMonoRawFile,
        outputCapture: .file(pathTemplate: "{inputDirectory}/dsdcc-status.txt")
    )
}
#endif
