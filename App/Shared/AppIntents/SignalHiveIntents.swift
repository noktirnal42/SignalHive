import Foundation
import AppIntents
import SignalHiveCore

// MARK: - App Intents for SignalHive

struct SignalHiveAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: StartScanningIntent(),
                phrases: [
                    "Start scanning with \(.applicationName)",
                    "Begin scanning on \(.applicationName)"
                ],
                shortTitle: "Start Scanning",
                systemImageName: "play.circle.fill"
            ),
            AppShortcut(
                intent: StopScanningIntent(),
                phrases: [
                    "Stop scanning with \(.applicationName)",
                    "Stop the scanner on \(.applicationName)"
                ],
                shortTitle: "Stop Scanning",
                systemImageName: "stop.circle.fill"
            ),
            AppShortcut(
                intent: TuneToFrequencyIntent(),
                phrases: [
                    "Tune to \(.applicationName) frequency",
                    "Set \(.applicationName) to frequency"
                ],
                shortTitle: "Tune Frequency",
                systemImageName: "antenna.radiowaves.left.and.right"
            ),
            AppShortcut(
                intent: FindActiveFrequenciesIntent(),
                phrases: [
                    "Find active frequencies on \(.applicationName)",
                    "Search for signals with \(.applicationName)"
                ],
                shortTitle: "Find Active",
                systemImageName: "sparkle.magnifyingglass"
            ),
            AppShortcut(
                intent: AddToCodeplugIntent(),
                phrases: [
                    "Add frequency to codeplug in \(.applicationName)",
                    "Save to codeplug in \(.applicationName)"
                ],
                shortTitle: "Add to Codeplug",
                systemImageName: "rectangle.stack.badge.plus"
            ),
            AppShortcut(
                intent: ImportULSDataIntent(),
                phrases: [
                    "Import ULS data in \(.applicationName)",
                    "Update frequency database in \(.applicationName)"
                ],
                shortTitle: "Import ULS",
                systemImageName: "arrow.down.circle"
            )
        ]
    }
}

// MARK: - Start Scanning Intent

struct StartScanningIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Start Scanning"
    nonisolated(unsafe) static var description = IntentDescription("Start the SDR scanner")
    nonisolated(unsafe) static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        return .result(value: "Scanning started")
    }
}

// MARK: - Stop Scanning Intent

struct StopScanningIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Stop Scanning"
    nonisolated(unsafe) static var description = IntentDescription("Stop the SDR scanner")
    nonisolated(unsafe) static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        return .result(value: "Scanning stopped")
    }
}

// MARK: - Tune Frequency Intent

struct TuneToFrequencyIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Tune to Frequency"
    nonisolated(unsafe) static var description = IntentDescription("Tune the scanner to a specific frequency")

    @Parameter(title: "Frequency (MHz)", description: "Frequency in MHz")
    var frequencyMHz: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Tune to \(\.$frequencyMHz) MHz")
    }

    func perform() async throws -> some IntentResult {
        return .result(value: "Tuned to \(frequencyMHz) MHz")
    }
}

// MARK: - Find Active Frequencies Intent

struct FindActiveFrequenciesIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Find Active Frequencies"
    nonisolated(unsafe) static var description = IntentDescription("Search for active frequencies in the current spectrum")
    nonisolated(unsafe) static var openAppWhenRun: Bool = true

    @Parameter(title: "Threshold (dB)", description: "Minimum signal strength in dB", default: -55.0)
    var thresholdDB: Double

    func perform() async throws -> some IntentResult {
        return .result(value: "Searching for active frequencies above \(thresholdDB) dB")
    }
}

// MARK: - Add to Codeplug Intent

struct AddToCodeplugIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Add to Codeplug"
    nonisolated(unsafe) static var description = IntentDescription("Add the current frequency to the codeplug")

    @Parameter(title: "Frequency (MHz)", description: "Frequency in MHz")
    var frequencyMHz: Double

    @Parameter(title: "Name", description: "Channel name", default: "")
    var name: String

    @Parameter(title: "Mode", description: "Modulation mode")
    var mode: CodeplugMode

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$frequencyMHz) MHz as \(\.$name) to codeplug")
    }

    func perform() async throws -> some IntentResult {
        return .result(value: "Added \(frequencyMHz) MHz to codeplug")
    }
}

enum CodeplugMode: String, AppEnum {
    case fm = "FM"
    case nfm = "NFM"
    case am = "AM"
    case dmr = "DMR"
    case p25 = "P25"
    case dstar = "D-STAR"

    nonisolated(unsafe) static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    nonisolated(unsafe) static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .fm: "FM",
        .nfm: "NFM",
        .am: "AM",
        .dmr: "DMR",
        .p25: "P25",
        .dstar: "D-STAR"
    ]
}

// MARK: - Import ULS Data Intent

struct ImportULSDataIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Import ULS Data"
    nonisolated(unsafe) static var description = IntentDescription("Download and import the latest FCC ULS frequency database")
    nonisolated(unsafe) static var openAppWhenRun: Bool = true

    @Parameter(title: "Services", description: "Which services to import")
    var services: [ULSServiceEntity]

    static var parameterSummary: some ParameterSummary {
        Summary("Import ULS data for \(\.$services)")
    }

    func perform() async throws -> some IntentResult {
        return .result(value: "ULS import started for \(services.count) service(s)")
    }
}

enum ULSServiceEntity: String, AppEnum, CaseIterable {
    case lmPriv = "Land Mobile Private"
    case lmComm = "Land Mobile Commercial"
    case gmrs = "GMRS"
    case aircraft = "Aircraft"
    case amateur = "Amateur"
    case marine = "Marine"
    case ship = "Ship"

    nonisolated(unsafe) static var typeDisplayRepresentation: TypeDisplayRepresentation = "Service"
    nonisolated(unsafe) static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .lmPriv: "Land Mobile Private/Public Safety",
        .lmComm: "Land Mobile Commercial/Business",
        .gmrs: "GMRS",
        .aircraft: "Aircraft",
        .amateur: "Amateur Radio",
        .marine: "Marine/Coastal",
        .ship: "Ship"
    ]
}