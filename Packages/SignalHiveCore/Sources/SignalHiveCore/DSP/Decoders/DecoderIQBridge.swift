import Foundation

public enum DecoderIQBridgeKind: String, Sendable, Codable, CaseIterable {
    case digitalVoice
    case pagingImage
    case weakSignal
}

public struct DecoderIQBridgeRequest: Sendable {
    public var kind: DecoderIQBridgeKind
    public var decoderIdentifier: String
    public var iqSamples: [ComplexFloat]
    public var sampleRate: Double

    public init(
        kind: DecoderIQBridgeKind,
        decoderIdentifier: String,
        iqSamples: [ComplexFloat],
        sampleRate: Double
    ) {
        self.kind = kind
        self.decoderIdentifier = decoderIdentifier
        self.iqSamples = iqSamples
        self.sampleRate = sampleRate
    }

    public var realChannelSamples: [Float] {
        iqSamples.map(\.i)
    }
}

public protocol DecoderIQBridge: Sendable {
    func decode(_ request: DecoderIQBridgeRequest) -> String?
}

public struct UnavailableDecoderIQBridge: DecoderIQBridge {
    public init() {}

    public func decode(_ request: DecoderIQBridgeRequest) -> String? {
        nil
    }
}

#if os(macOS)
public enum ProcessDecoderIQBridgeInputTransport: Sendable, Equatable {
    case none
    case standardInputRealChannelFloat32
    case temporaryRealChannelFloat32File(pathExtension: String)
    case temporaryMonoPCM16RawFile(pathExtension: String)
    case temporaryMonoPCM16WAVFile

    public static let temporaryFloat32File: Self = .temporaryRealChannelFloat32File(pathExtension: "f32")
    public static let temporaryMonoRawFile: Self = .temporaryMonoPCM16RawFile(pathExtension: "raw")
    public static let temporaryMonoWAVFile: Self = .temporaryMonoPCM16WAVFile
}

public enum ProcessDecoderIQBridgeOutputCapture: Sendable, Equatable {
    case standardOutputAndError
    case file(pathTemplate: String)
}

public struct ProcessDecoderIQBridgeConfiguration: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var inputTransport: ProcessDecoderIQBridgeInputTransport
    public var outputCapture: ProcessDecoderIQBridgeOutputCapture
    public var workingDirectoryURL: URL?
    public var environment: [String: String]

    public init(
        executableURL: URL,
        arguments: [String] = [],
        inputTransport: ProcessDecoderIQBridgeInputTransport = .standardInputRealChannelFloat32,
        outputCapture: ProcessDecoderIQBridgeOutputCapture = .standardOutputAndError,
        workingDirectoryURL: URL? = nil,
        environment: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.inputTransport = inputTransport
        self.outputCapture = outputCapture
        self.workingDirectoryURL = workingDirectoryURL
        self.environment = environment
    }
}

public final class ProcessDecoderIQBridge: DecoderIQBridge, @unchecked Sendable {
    public var configuration: ProcessDecoderIQBridgeConfiguration

    public init(configuration: ProcessDecoderIQBridgeConfiguration) {
        self.configuration = configuration
    }

    public func decode(_ request: DecoderIQBridgeRequest) -> String? {
        guard let preparedInput = try? preparedInput(for: request) else { return nil }
        defer { preparedInput.cleanup() }
        let outputCaptureURL = configuredOutputCaptureURL(
            for: request,
            inputURL: preparedInput.url,
            placeholderDirectoryURL: preparedInput.placeholderDirectoryURL
        )

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = expandedArguments(
            for: request,
            inputURL: preparedInput.url,
            placeholderDirectoryURL: preparedInput.placeholderDirectoryURL
        )
        process.currentDirectoryURL = configuration.workingDirectoryURL
        if !configuration.environment.isEmpty {
            let expandedEnvironment = configuration.environment.mapValues {
                expandPlaceholders(
                    in: $0,
                    for: request,
                    inputURL: preparedInput.url,
                    placeholderDirectoryURL: preparedInput.placeholderDirectoryURL
                )
            }
            process.environment = ProcessInfo.processInfo.environment.merging(expandedEnvironment) { _, new in new }
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        var stdin: Pipe?
        if preparedInput.stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdin = pipe
        }

        do {
            try process.run()
            if let stdin, let data = preparedInput.stdinData {
                try? stdin.fileHandleForWriting.write(contentsOf: data)
                try? stdin.fileHandleForWriting.close()
            }
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = stderr.fileHandleForReading.readDataToEndOfFile()
        let text = capturedOutputText(
            outputCaptureURL: outputCaptureURL,
            output: output,
            diagnostics: diagnostics
        )
        return text.isEmpty ? nil : text
    }

    private func expandedArguments(
        for request: DecoderIQBridgeRequest,
        inputURL: URL?,
        placeholderDirectoryURL: URL?
    ) -> [String] {
        configuration.arguments.map { argument in
            expandPlaceholders(
                in: argument,
                for: request,
                inputURL: inputURL,
                placeholderDirectoryURL: placeholderDirectoryURL
            )
        }
    }

    private func expandPlaceholders(
        in value: String,
        for request: DecoderIQBridgeRequest,
        inputURL: URL?,
        placeholderDirectoryURL: URL?
    ) -> String {
        let inputPath = inputURL?.path ?? ""
        let inputDirectory = inputURL?.deletingLastPathComponent().path
            ?? placeholderDirectoryURL?.path
            ?? ""
        let inputFilename = inputURL?.lastPathComponent ?? ""
        return value
            .replacingOccurrences(of: "{kind}", with: request.kind.rawValue)
            .replacingOccurrences(of: "{sampleRate}", with: String(Int(request.sampleRate.rounded())))
            .replacingOccurrences(of: "{decoder}", with: request.decoderIdentifier)
            .replacingOccurrences(of: "{inputFile}", with: inputPath)
            .replacingOccurrences(of: "{inputDirectory}", with: inputDirectory)
            .replacingOccurrences(of: "{inputFilename}", with: inputFilename)
    }

    private func preparedInput(for request: DecoderIQBridgeRequest) throws -> PreparedInput {
        switch configuration.inputTransport {
        case .none:
            let directoryURL = try Self.makeTemporaryInputDirectory()
            return PreparedInput(placeholderDirectoryURL: directoryURL, cleanupURL: directoryURL)
        case .standardInputRealChannelFloat32:
            let directoryURL = try Self.makeTemporaryInputDirectory()
            return PreparedInput(
                stdinData: Self.float32Data(from: request.realChannelSamples),
                placeholderDirectoryURL: directoryURL,
                cleanupURL: directoryURL
            )
        case let .temporaryRealChannelFloat32File(pathExtension):
            let directoryURL = try Self.makeTemporaryInputDirectory()
            let fileURL = directoryURL
                .appendingPathComponent("decoder-input", isDirectory: false)
                .appendingPathExtension(pathExtension)
            try Self.float32Data(from: request.realChannelSamples).write(to: fileURL, options: .atomic)
            return PreparedInput(
                url: fileURL,
                placeholderDirectoryURL: directoryURL,
                cleanupURL: directoryURL
            )
        case let .temporaryMonoPCM16RawFile(pathExtension):
            let directoryURL = try Self.makeTemporaryInputDirectory()
            let fileURL = directoryURL
                .appendingPathComponent("decoder-input", isDirectory: false)
                .appendingPathExtension(pathExtension)
            let rawData = Self.monoPCM16LEData(from: request.realChannelSamples)
            try rawData.write(to: fileURL, options: .atomic)
            return PreparedInput(
                url: fileURL,
                placeholderDirectoryURL: directoryURL,
                cleanupURL: directoryURL
            )
        case .temporaryMonoPCM16WAVFile:
            let directoryURL = try Self.makeTemporaryInputDirectory()
            let fileURL = directoryURL.appendingPathComponent("decoder-input.wav", isDirectory: false)
            let wavData = Self.monoPCM16WAVData(
                from: request.realChannelSamples,
                sampleRate: max(Int(request.sampleRate.rounded()), 1)
            )
            try wavData.write(to: fileURL, options: .atomic)
            return PreparedInput(
                url: fileURL,
                placeholderDirectoryURL: directoryURL,
                cleanupURL: directoryURL
            )
        }
    }

    private func configuredOutputCaptureURL(
        for request: DecoderIQBridgeRequest,
        inputURL: URL?,
        placeholderDirectoryURL: URL?
    ) -> URL? {
        guard case let .file(pathTemplate) = configuration.outputCapture else {
            return nil
        }
        let expandedPath = expandPlaceholders(
            in: pathTemplate,
            for: request,
            inputURL: inputURL,
            placeholderDirectoryURL: placeholderDirectoryURL
        )
        guard !expandedPath.isEmpty else { return nil }
        return URL(fileURLWithPath: expandedPath)
    }

    private func capturedOutputText(
        outputCaptureURL: URL?,
        output: Data,
        diagnostics: Data
    ) -> String {
        if let outputCaptureURL,
           let fileData = try? Data(contentsOf: outputCaptureURL),
           let fileText = String(data: fileData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fileText.isEmpty {
            return fileText
        }

        return [output, diagnostics]
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeTemporaryInputDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NeuralSDR3DecoderIQBridge", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private static func float32Data(from samples: [Float]) -> Data {
        var values = samples
        return values.withUnsafeMutableBytes { buffer in
            Data(buffer)
        }
    }

    private static func monoPCM16LEData(from samples: [Float]) -> Data {
        let clampedSamples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16((clamped * Float(Int16.max)).rounded())
        }
        var pcmValues = clampedSamples
        return pcmValues.withUnsafeMutableBytes { buffer in
            Data(buffer)
        }
    }

    private static func monoPCM16WAVData(from samples: [Float], sampleRate: Int) -> Data {
        let pcmData = monoPCM16LEData(from: samples)

        let headerSize = 44
        let riffChunkSize = UInt32(headerSize - 8 + pcmData.count)
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        let bitsPerSample = UInt16(16)
        let dataChunkSize = UInt32(pcmData.count)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(Self.littleEndianBytes(riffChunkSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(Self.littleEndianBytes(UInt32(16)))
        data.append(Self.littleEndianBytes(UInt16(1)))
        data.append(Self.littleEndianBytes(UInt16(1)))
        data.append(Self.littleEndianBytes(UInt32(sampleRate)))
        data.append(Self.littleEndianBytes(byteRate))
        data.append(Self.littleEndianBytes(blockAlign))
        data.append(Self.littleEndianBytes(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.append(Self.littleEndianBytes(dataChunkSize))
        data.append(pcmData)
        return data
    }

    private static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
}

private struct PreparedInput {
    var url: URL?
    var stdinData: Data?
    var placeholderDirectoryURL: URL?
    var cleanupURL: URL?

    init(
        url: URL? = nil,
        stdinData: Data? = nil,
        placeholderDirectoryURL: URL? = nil,
        cleanupURL: URL? = nil
    ) {
        self.url = url
        self.stdinData = stdinData
        self.placeholderDirectoryURL = placeholderDirectoryURL
        self.cleanupURL = cleanupURL
    }

    func cleanup() {
        guard let cleanupURL else { return }
        try? FileManager.default.removeItem(at: cleanupURL)
    }
}
#endif
