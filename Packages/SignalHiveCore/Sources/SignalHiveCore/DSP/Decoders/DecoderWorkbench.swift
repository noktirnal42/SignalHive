import Foundation

public enum DecoderWorkbenchStatus: String, Sendable, Equatable {
    case decoded
    case rejected
}

public struct DecoderWorkbenchMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let decoder: String
    public let title: String
    public let summary: String
    public let details: [String]
    public let raw: String
    public let status: DecoderWorkbenchStatus

    public init(id: String = UUID().uuidString, decoder: String, title: String, summary: String,
                details: [String] = [], raw: String, status: DecoderWorkbenchStatus = .decoded) {
        self.id = id
        self.decoder = decoder
        self.title = title
        self.summary = summary
        self.details = details
        self.raw = raw
        self.status = status
    }
}

public enum DecoderWorkbench {
    public static func decodeMorsePatterns(_ text: String) -> DecoderWorkbenchMessage {
        let tokens = text
            .uppercased()
            .replacingOccurrences(of: "\n", with: " / ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        var output = ""
        var decoded = 0
        var unknown = 0
        var previousWasBreak = true

        for token in tokens {
            if token == "/" || token == "|" {
                if !output.isEmpty, !previousWasBreak {
                    output.append(" ")
                }
                previousWasBreak = true
                continue
            }

            let normalized = token.map { $0 == "_" ? "-" : $0 }.filter { $0 == "." || $0 == "-" }
            guard !normalized.isEmpty else { continue }
            let pattern = String(normalized)
            if let character = MorseCodec.patternToCharacter[pattern] {
                output.append(character)
                decoded += 1
                previousWasBreak = false
            } else {
                output.append("?")
                unknown += 1
                previousWasBreak = false
            }
        }

        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = clean.isEmpty ? "No Morse symbols were decoded." : clean
        let confidence = decoded + unknown == 0 ? 0 : Double(decoded) / Double(decoded + unknown)
        return DecoderWorkbenchMessage(
            decoder: "Morse",
            title: clean.isEmpty ? "No CW text" : "CW text",
            summary: summary,
            details: [
                "\(decoded) known symbol\(decoded == 1 ? "" : "s")",
                "\(unknown) unknown symbol\(unknown == 1 ? "" : "s")",
                "\(Int((confidence * 100).rounded()))% pattern confidence"
            ],
            raw: text,
            status: clean.isEmpty ? .rejected : .decoded
        )
    }

    public static func encodeMorseText(_ text: String) -> String {
        MorseCodec.encodeToPatterns(text).joined(separator: " / ")
    }

    public static func decodeAISNMEA(_ text: String, timestamp: @Sendable @escaping () -> Date = { .now }) -> [DecoderWorkbenchMessage] {
        let decoder = AISDecoder()
        decoder.timestampProvider = timestamp
        let lines = nonEmptyLines(in: text)
        guard !lines.isEmpty else {
            return [emptyMessage(decoder: "AIS", raw: text, summary: "Paste one or more !AIVDM or !AIVDO NMEA sentences.")]
        }

        return lines.enumerated().map { index, line in
            guard let message = decoder.parseNMEA(line) else {
                return DecoderWorkbenchMessage(
                    id: "ais-\(index)-rejected",
                    decoder: "AIS",
                    title: "Rejected NMEA",
                    summary: "Could not parse AIS line \(index + 1). Check the sentence prefix, payload and checksum.",
                    details: [],
                    raw: line,
                    status: .rejected
                )
            }
            return aisSummary(message, raw: line, index: index)
        }
    }

    public static func decodeACARSText(_ text: String, timestamp: Date = .now) -> [DecoderWorkbenchMessage] {
        let lines = nonEmptyLines(in: text)
        guard !lines.isEmpty else {
            return [emptyMessage(decoder: "ACARS", raw: text, summary: "Paste a decoded ACARS text line or frame body.")]
        }

        return lines.enumerated().map { index, line in
            let label = acarsLabel(from: line)
            let registration = acarsRegistration(in: line)
            let flight = acarsFlightID(in: line, label: label, registration: registration)
            let kind = acarsKind(label: label, text: line)
            var details = ["Label \(label)", kind.displayName]
            if let registration { details.append("Registration \(registration)") }
            if let flight { details.append("Flight \(flight)") }
            details.append(timestamp.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)))

            return DecoderWorkbenchMessage(
                id: "acars-\(index)-decoded",
                decoder: "ACARS",
                title: flight ?? registration ?? kind.displayName,
                summary: line,
                details: details,
                raw: line
            )
        }
    }

    static func aisSummary(_ message: AISMessage, raw: String, index: Int) -> DecoderWorkbenchMessage {
        var details = ["MMSI \(message.mmsi)", "Type \(message.messageType)"]
        let title: String
        let summary: String

        switch message.payload {
        case .positionReportA(let report):
            title = "Vessel \(message.mmsi)"
            summary = String(format: "%.5f, %.5f at %.1f kt, course %.1f deg",
                             report.latitude, report.longitude, report.speedOverGround, report.courseOverGround)
            details.append("Heading \(report.trueHeading == 511 ? "NA" : "\(report.trueHeading) deg")")
            details.append("Nav status \(report.navigationStatus)")
        case .positionReportB(let report):
            title = "Class B \(message.mmsi)"
            summary = String(format: "%.5f, %.5f at %.1f kt, course %.1f deg",
                             report.latitude, report.longitude, report.speedOverGround, report.courseOverGround)
            details.append("Heading \(report.trueHeading == 511 ? "NA" : "\(report.trueHeading) deg")")
        case .staticVoyage(let voyage):
            title = voyage.name.isEmpty ? "Vessel \(message.mmsi)" : voyage.name
            summary = voyage.destination.isEmpty ? "Static voyage report" : "Destination \(voyage.destination)"
            if !voyage.callsign.isEmpty { details.append("Callsign \(voyage.callsign)") }
            details.append("Ship type \(voyage.shipType)")
            details.append(String(format: "Draught %.1f m", voyage.draught))
        case .baseStation(let station):
            title = "AIS base station"
            summary = String(format: "%.5f, %.5f at %04d-%02d-%02d %02d:%02d:%02d UTC",
                             station.latitude, station.longitude, station.utcYear, station.utcMonth, station.utcDay,
                             station.utcHour, station.utcMinute, station.utcSecond)
        case .staticDataReport(let report):
            title = report.name.isEmpty ? "Static data \(message.mmsi)" : report.name
            summary = report.callsign.isEmpty ? "Static data report" : "Callsign \(report.callsign)"
            details.append("Part \(report.partNumber)")
            details.append("Ship type \(report.shipType)")
        case .safetyMessage(let text):
            title = "Safety message"
            summary = text.isEmpty ? "Empty safety message" : text
        case .unknown:
            title = "AIS type \(message.messageType)"
            summary = "Valid AIS sentence; SignalHive does not summarize this payload type yet."
        }

        return DecoderWorkbenchMessage(
            id: "ais-\(index)-decoded-\(message.mmsi)-\(message.messageType)",
            decoder: "AIS",
            title: title,
            summary: summary,
            details: details,
            raw: raw
        )
    }

    private static func emptyMessage(decoder: String, raw: String, summary: String) -> DecoderWorkbenchMessage {
        DecoderWorkbenchMessage(
            decoder: decoder,
            title: "Waiting for input",
            summary: summary,
            raw: raw,
            status: .rejected
        )
    }

    private static func nonEmptyLines(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func acarsLabel(from text: String) -> String {
        let compact = text.filter { $0.isLetter || $0.isNumber }
        guard compact.count >= 2 else { return "--" }
        return String(compact.prefix(2)).uppercased()
    }

    private static func acarsFlightID(in text: String, label: String, registration: String?) -> String? {
        let candidates = acarsTokens(in: text).filter { $0 != label && $0 != registration }
        if let flight = candidates.first(where: isFlightIdentifier) { return flight }
        return registration ?? candidates.first { (2...8).contains($0.count) && $0.contains { $0.isNumber } }
    }

    private static func acarsRegistration(in text: String) -> String? {
        acarsTokens(in: text).first(where: isRegistration)
    }

    private static func acarsKind(label: String, text: String) -> ACARSMessageKind {
        let upper = text.uppercased()
        if upper.contains("METAR") || upper.contains("TAF") || upper.contains("SIGMET") || upper.contains("WX") {
            return .weather
        }
        if upper.contains("CLEARANCE") || upper.contains(" ATC ") || upper.contains(" CLR ") {
            return .clearance
        }
        if upper.contains("MAINT") || upper.contains("FAULT") || upper.contains("MEL") || upper.contains("ENG") {
            return .maintenance
        }
        if upper.contains(" OUT ") || upper.hasSuffix(" OUT") || upper.contains(" OFF ") {
            return .departure
        }
        if upper.contains(" ON ") || upper.contains(" IN ") || upper.hasSuffix(" IN") {
            return .arrival
        }
        if label.hasPrefix("Q") || upper.contains("POS ") || upper.contains("POSITION") {
            return .position
        }
        return .freeText
    }

    private static func acarsTokens(in text: String) -> [String] {
        text.uppercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "-") }
            .map(String.init)
    }

    private static func isFlightIdentifier(_ token: String) -> Bool {
        guard (3...8).contains(token.count) else { return false }
        let scalars = Array(token.unicodeScalars)
        let letterPrefixCount = scalars.prefix { CharacterSet.uppercaseLetters.contains($0) }.count
        let digitCount = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let suffixCount = scalars.count - letterPrefixCount - digitCount
        guard (2...3).contains(letterPrefixCount), digitCount >= 1 else { return false }
        return suffixCount == 0 || (suffixCount == 1 && CharacterSet.uppercaseLetters.contains(scalars.last!))
    }

    private static func isRegistration(_ token: String) -> Bool {
        if token.first == "N" {
            let suffix = token.dropFirst()
            let digitCount = suffix.prefix { $0.isNumber }.count
            let letterCount = suffix.reversed().prefix { $0.isLetter }.count
            return (1...5).contains(digitCount) && letterCount <= 2 && digitCount + letterCount == suffix.count
        }

        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let prefix = parts[0]
        let suffix = parts[1]
        return (1...2).contains(prefix.count)
            && (3...5).contains(suffix.count)
            && prefix.allSatisfy(\.isLetter)
            && suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
