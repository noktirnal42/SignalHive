import Foundation

// The Workshop's list of what SignalHive can do, and how much of it works on this machine right now. The statuses are
// worked out from facts about the machine (data installed, dongles found, tools present) rather than written by hand, so
// a tile never says "Available" for something that cannot run.

/// How usable a capability is here and now.
public enum WorkshopStatus: String, CaseIterable, Sendable {
    /// Works now.
    case ready
    /// Implemented, but needs something first: a dongle, a data download, an outside tool.
    case needsSetup
    /// The code exists in the library, but the app does not use it yet, so nothing shows up in the app.
    case notConnected
    /// Not written.
    case planned

    public var label: String {
        switch self {
        case .ready: return "Ready"
        case .needsSetup: return "Needs setup"
        case .notConnected: return "Not connected yet"
        case .planned: return "Planned"
        }
    }
}

/// Where a tile leads.
public enum WorkshopDestination: String, Sendable {
    case browse, search, scanner, decoderHub, trunked, codeplug, aiLab, satellites, airMap, airData
}

/// A setup step a tile can do for the user, so "Needs setup" always comes with a way to finish the setup.
public enum WorkshopFix: Equatable, Sendable {
    /// Get a state's FCC data (the app's Get Data sheet).
    case getFCCData
    /// Add an rtl_tcp or OpenWebRX host as a source.
    case addNetworkSource
    /// Plug in a dongle; explains that only one program can hold it.
    case usbHelp
    /// Install an outside tool or library, by name ("libhackrf").
    case installTool(String)
}

/// Something to start once the destination is open.
public enum WorkshopPreset: Equatable, Sendable {
    case scannerTune(mhz: Double, mode: DemodMode)
    case listenADSB1090
    case listenUAT978
    /// A Decoder Hub tool, by `WorkshopItem.id` ("acars", "ais", "morse").
    case decoder(String)
}

/// What pressing a tile does.
public enum WorkshopAction: Equatable, Sendable {
    /// Go to a panel.
    case open(WorkshopDestination)
    /// Go to a panel and start something there.
    case launch(WorkshopDestination, WorkshopPreset)
    /// Do the setup step from the tile.
    case fix(WorkshopFix)
    /// Explain an item the app cannot run yet (shown in a sheet).
    case learn(String)

    /// The destination this action navigates to, if any.
    public var destination: WorkshopDestination? {
        switch self {
        case let .open(destination), let .launch(destination, _): return destination
        case .fix, .learn: return nil
        }
    }

    /// The button text.
    public var label: String {
        switch self {
        case .open: return "Open"
        case let .launch(_, preset):
            switch preset {
            case .scannerTune, .listenADSB1090, .listenUAT978: return "Start listening"
            case .decoder: return "Open decoder"
            }
        case let .fix(fix):
            switch fix {
            case .getFCCData: return "Get data"
            case .addNetworkSource: return "Add source"
            case .usbHelp: return "Connect a dongle"
            case .installTool: return "How to install"
            }
        case .learn: return "Details"
        }
    }
}

public enum WorkshopSection: String, CaseIterable, Sendable {
    case workflows
    case decoders
    case hardware
    case planned

    public var title: String {
        switch self {
        case .workflows: return "RF workflows"
        case .decoders: return "Protocol decoders"
        case .hardware: return "Hardware and field integrations"
        case .planned: return "Planned lab areas"
        }
    }
}

/// What is true of this machine, as the app finds it.
public struct WorkshopEnvironment: Equatable, Sendable {
    public var installedPacks = 0
    /// RTL-SDR dongles found on USB.
    public var rtlsdrDongles = 0
    public var rtlsdrSummary = ""
    /// A HackRF is present and its library loaded.
    public var hackRFPresent = false
    /// Saved network sources (rtl_tcp or OpenWebRX).
    public var networkSources = 0
    /// Outside programs found on this machine, by executable name ("dsdccx", "multimon-ng").
    public var tools: Set<String> = []
    public var codeplugChannels = 0
    /// The demodulators the scanner really has.
    public var demodModes: [String] = []
    /// Downloaded on-device language models in the AI Lab.
    public var aiModelsInstalled = 0
    public var usesDemoData = false

    public init(installedPacks: Int = 0, rtlsdrDongles: Int = 0, rtlsdrSummary: String = "", hackRFPresent: Bool = false,
                networkSources: Int = 0, tools: Set<String> = [], codeplugChannels: Int = 0, demodModes: [String] = [],
                aiModelsInstalled: Int = 0, usesDemoData: Bool = false) {
        self.installedPacks = installedPacks
        self.rtlsdrDongles = rtlsdrDongles
        self.rtlsdrSummary = rtlsdrSummary
        self.hackRFPresent = hackRFPresent
        self.networkSources = networkSources
        self.tools = tools
        self.codeplugChannels = codeplugChannels
        self.demodModes = demodModes
        self.aiModelsInstalled = aiModelsInstalled
        self.usesDemoData = usesDemoData
    }

    /// Something that can deliver I/Q samples for the scanner.
    public var hasLiveSource: Bool { rtlsdrDongles > 0 || hackRFPresent || networkSources > 0 }
}

public struct WorkshopItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var section: WorkshopSection
    public var title: String
    public var detail: String
    public var symbol: String
    public var status: WorkshopStatus
    /// For "Needs setup": what to do.
    public var setup: String?
    /// What the tile's button does. Items that are not written (`planned`) have none.
    public var action: WorkshopAction?

    public var destination: WorkshopDestination? { action?.destination }
    public var actionLabel: String? { action?.label }

    public init(_ id: String, _ section: WorkshopSection, _ title: String, _ detail: String, symbol: String,
                status: WorkshopStatus, setup: String? = nil, action: WorkshopAction? = nil) {
        self.id = id
        self.section = section
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.status = status
        self.setup = setup
        self.action = action
    }
}

/// A one-press shortcut on the Workshop. When the machine cannot do it yet, `action` is the fix and `needsSetup` is set,
/// so a shortcut never dead-ends.
public struct WorkshopQuickAction: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var symbol: String
    public var action: WorkshopAction
    public var needsSetup: Bool

    public init(_ id: String, _ title: String, _ detail: String, symbol: String, action: WorkshopAction,
                needsSetup: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.action = action
        self.needsSetup = needsSetup
    }
}

public enum WorkshopCatalog {
    public static func items(for env: WorkshopEnvironment) -> [WorkshopItem] {
        var items: [WorkshopItem] = []
        let liveSetup = "Plug in an RTL-SDR, or add a network source in Scanner."
        let live: WorkshopStatus = env.hasLiveSource ? .ready : .needsSetup
        let liveNote: String? = env.hasLiveSource ? nil : liveSetup
        let liveAction: WorkshopAction = env.hasLiveSource ? .open(.scanner) : .fix(.usbHelp)
        let dongle = env.rtlsdrDongles > 0
        let adsbAction: WorkshopAction = dongle ? .launch(.airMap, .listenADSB1090) : .fix(.usbHelp)
        let uatAction: WorkshopAction = dongle ? .launch(.airData, .listenUAT978) : .fix(.usbHelp)

        // MARK: Workflows

        items.append(WorkshopItem(
            "fcc", .workflows, "FCC license packs",
            env.installedPacks > 0
                ? "\(env.installedPacks) state pack\(env.installedPacks == 1 ? "" : "s") installed. Browse counties, licensees, frequencies, modes, power and sites; search across all of them."
                : "Browse counties, licensees, frequencies, modes, power and sites once a state pack is installed.",
            symbol: "externaldrive.fill", status: env.installedPacks > 0 ? .ready : .needsSetup,
            setup: env.installedPacks > 0 ? nil : "Open Browse and get a state's data.",
            action: env.installedPacks > 0 ? .open(.browse) : .fix(.getFCCData)))
        items.append(WorkshopItem(
            "spectrum", .workflows, "Live spectrum and waterfall",
            "Tune anywhere the source allows; see the spectrum and waterfall, click a signal to listen.",
            symbol: "waveform.path.ecg", status: live, setup: liveNote, action: liveAction))
        items.append(WorkshopItem(
            "demod", .workflows, "Demodulation",
            env.demodModes.isEmpty ? "Voice demodulators in the scanner." : "The scanner demodulates \(env.demodModes.joined(separator: ", ")).",
            symbol: "slider.horizontal.3", status: live, setup: liveNote, action: liveAction))
        items.append(WorkshopItem(
            "airmap", .workflows, "Air Map: ADS-B and FIS-B",
            "Aircraft on a map with painted icons colored by altitude, trails, and NEXRAD radar from FIS-B.",
            symbol: "airplane", status: env.rtlsdrDongles > 0 ? .ready : .needsSetup,
            setup: env.rtlsdrDongles > 0 ? nil : "Live traffic needs an RTL-SDR (1090 MHz for aircraft, 978 MHz for FIS-B).",
            action: adsbAction))
        items.append(WorkshopItem(
            "airdata", .workflows, "Air Data: weather and messages",
            "METAR, TAF, PIREP, SIGMET, AIRMET, NOTAM and TFR text from FIS-B, decoded, with an airport weather board and alerts.",
            symbol: "doc.text.magnifyingglass", status: env.rtlsdrDongles > 0 ? .ready : .needsSetup,
            setup: env.rtlsdrDongles > 0 ? nil : "FIS-B is broadcast on 978 MHz and needs an RTL-SDR.",
            action: uatAction))
        items.append(WorkshopItem(
            "satellites", .workflows, "Satellite passes",
            "Predicts passes of weather, station and amateur satellites from your antenna location (SGP4), rates each against the antennas you have, and shows where to point. It does not record or decode a pass yet.",
            symbol: "globe.americas", status: .ready, action: .open(.satellites)))
        items.append(WorkshopItem(
            "decoderhub", .workflows, "Decoder Hub",
            "Manual ACARS, AIS and Morse workbench decoding is live; the core DecoderSession is ready for SDR capture wiring.",
            symbol: "dot.radiowaves.forward", status: .ready, action: .open(.decoderHub)))
        items.append(WorkshopItem(
            "codeplug", .workflows, "Radio programming",
            env.codeplugChannels > 0
                ? "The open codeplug has \(env.codeplugChannels) channel\(env.codeplugChannels == 1 ? "" : "s"). Checked against the radio; CHIRP CSV in and out; direct write for radios that support it."
                : "Build codeplugs from Browse, Search, Scanner and Trunked; check them against the radio; CHIRP CSV in and out; direct write for radios that support it.",
            symbol: "memorychip", status: .ready, action: .open(.codeplug)))
        items.append(WorkshopItem(
            "trunked", .workflows, "Trunked system browser",
            "OpenMHz systems and talkgroups by service (law, fire, EMS ...), kept for offline use, added to a codeplug as talkgroup channels. It lists systems; it does not follow calls.",
            symbol: "antenna.radiowaves.left.and.right", status: .ready, action: .open(.trunked)))
        items.append(WorkshopItem(
            "finder", .workflows, "Signal finder",
            "Finds the active peaks in the spectrum and adds them to the codeplug.",
            symbol: "sparkle.magnifyingglass", status: live, setup: liveNote, action: liveAction))
        items.append(WorkshopItem(
            "ailab", .workflows, "AI Lab",
            env.aiModelsInstalled > 0
                ? "\(env.aiModelsInstalled) on-device model\(env.aiModelsInstalled == 1 ? "" : "s") downloaded."
                : "On-device signal descriptions and RF coaching; download local models here.",
            symbol: "brain.head.profile", status: .ready, action: .open(.aiLab)))

        // MARK: Decoders

        let oneDongle = env.rtlsdrDongles == 1 ? " One dongle runs one band at a time; two dongles run both." : ""
        items.append(WorkshopItem(
            "adsb", .decoders, "ADS-B 1090 MHz",
            "Native Mode S decoding straight from an RTL-SDR: position (CPR), altitude, speed, heading, callsign, squawk and emergencies.\(oneDongle)",
            symbol: "airplane", status: env.rtlsdrDongles > 0 ? .ready : .needsSetup,
            setup: env.rtlsdrDongles > 0 ? nil : "Needs an RTL-SDR and a 1090 MHz antenna.", action: adsbAction))
        items.append(WorkshopItem(
            "uat", .decoders, "UAT 978 MHz and FIS-B",
            "Native UAT decoding: general-aviation aircraft, TIS-B traffic, NEXRAD radar and text products from ground stations. United States only.",
            symbol: "cloud.sun.rain", status: env.rtlsdrDongles > 0 ? .ready : .needsSetup,
            setup: env.rtlsdrDongles > 0 ? nil : "Needs an RTL-SDR and a 978 MHz antenna.", action: uatAction))
        items.append(WorkshopItem(
            "ism", .decoders, "ISM sensors: rtl_433-style",
            "The embedded SwiftRTLSDR decoder library has an RTL-SDR receive chain and 11 weather-station, sensor and remote protocols. App capture UI is next.",
            symbol: "sensor", status: .notConnected,
            action: .learn("The ISM sensor decoder (an rtl_433-style receive chain for 433, 868 and 915 MHz) is in the embedded SwiftRTLSDR package and runs from the command line: rtlsdr-tool ism. It has been checked against rtl_433 on recorded captures but has not received a live signal, and the app cannot capture it yet. The Decoder Hub gets an ISM session once it has been checked over the air.")))
        items.append(WorkshopItem(
            "rs41", .decoders, "RS41 radiosondes",
            "The embedded SwiftRTLSDR decoder library has Vaisala RS41 frames, GPS position, temperature, battery and scan mode. App tracking UI is next.",
            symbol: "balloon", status: .notConnected,
            action: .learn("Vaisala RS41 radiosonde decoding is in the embedded SwiftRTLSDR package: rtlsdr-tool sonde, with a --scan mode. It has been checked against recorded audio and has not received a live signal. The app cannot capture or track radiosondes yet.")))
        items.append(WorkshopItem(
            "lrpt", .decoders, "Meteor LRPT satellite images",
            "The embedded SwiftRTLSDR decoder library has Meteor-M LRPT demodulation, deframing, MSU-MR image products and a SatDump-checked oracle path. App capture UI is next.",
            symbol: "globe.europe.africa", status: .notConnected,
            action: .learn("Meteor-M LRPT decoding (demodulation, deframing and MSU-MR images) is in the embedded SwiftRTLSDR package: rtlsdr-tool meteor. It was compared against SatDump and meteor_demod output on recorded scenes and has not received a live signal. The Satellites screen plans passes, but the app cannot capture one yet: that needs an SDR session in the Decoder Hub and Doppler correction.")))
        for (id, title, detail, symbol) in [
            ("acars", "ACARS", "Paste decoded ACARS text or frame bodies now; live 131 MHz VHF capture can be wired through DecoderSession next.", "teletype"),
            ("ais", "AIS", "Paste !AIVDM and !AIVDO NMEA sentences now; live marine-channel capture can be wired through DecoderSession next.", "ferry"),
            ("morse", "Morse and CW", "Encode text to Morse and decode dot/dash patterns immediately; live CW audio/IQ capture comes next.", "dot.circle"),
        ] {
            items.append(WorkshopItem(
                id, .decoders, title, detail,
                symbol: symbol, status: .ready, action: .launch(.decoderHub, .decoder(id))))
        }
        items.append(WorkshopItem(
            "dmr", .decoders, "P25, DMR and NXDN metadata",
            "The decoder wraps the outside program dsdccx, and the app does not attach it to the scanner yet.",
            symbol: "person.wave.2", status: .notConnected,
            setup: env.tools.contains("dsdccx") ? "dsdccx is installed." : nil,
            action: .learn("P25, DMR and NXDN metadata come from the outside program dsdccx, which SignalHive does not connect to the scanner yet. The plan is original Swift decoders; dsdccx stays a temporary adapter until then.")))
        items.append(WorkshopItem(
            "paging", .decoders, "POCSAG and FLEX paging",
            "The decoder wraps the outside program multimon-ng, and the app does not attach it to the scanner yet.",
            symbol: "message.badge.waveform", status: .notConnected,
            setup: env.tools.contains("multimon-ng") ? "multimon-ng is installed." : nil,
            action: .learn("POCSAG and FLEX paging come from the outside program multimon-ng, which SignalHive does not connect to the scanner yet. The plan is an original Swift paging decoder; multimon-ng stays a temporary adapter until then.")))
        items.append(WorkshopItem(
            "weak", .decoders, "FT8, FT4 and WSPR",
            "A message parser exists; there is no audio path that feeds it, so nothing is decoded live.",
            symbol: "sparkles", status: .notConnected,
            action: .learn("FT8, FT4 and WSPR messages can be parsed, but no audio path feeds the parser, so nothing is decoded from the air. A native Swift weak-signal decoder is not built yet.")))

        // MARK: Hardware

        items.append(WorkshopItem(
            "rtlsdr", .hardware, "RTL-SDR (USB)",
            env.rtlsdrDongles > 0 ? env.rtlsdrSummary + " Native Swift driver, no libraries to install." : (env.rtlsdrSummary.isEmpty ? "Native Swift driver, no libraries to install." : env.rtlsdrSummary),
            symbol: "cable.connector.horizontal", status: env.rtlsdrDongles > 0 ? .ready : .needsSetup,
            setup: env.rtlsdrDongles > 0 ? nil : "Plug in a dongle. Only one program can use it at a time.",
            action: dongle ? .open(.scanner) : .fix(.usbHelp)))
        items.append(WorkshopItem(
            "network", .hardware, "Network sources",
            env.networkSources > 0
                ? "\(env.networkSources) saved network source\(env.networkSources == 1 ? "" : "s"), for example a Raspberry Pi running rtl_tcp. (OpenWebRX sources are a first-pass implementation.)"
                : "rtl_tcp servers, for example a Raspberry Pi with a dongle in the field. Add one in Scanner. (OpenWebRX sources are a first-pass implementation.)",
            symbol: "network", status: env.networkSources > 0 ? .ready : .needsSetup,
            setup: env.networkSources > 0 ? nil : "Add a host in Scanner.",
            action: env.networkSources > 0 ? .open(.scanner) : .fix(.addNetworkSource)))
        items.append(WorkshopItem(
            "rtltcp", .hardware, "rtl_tcp server",
            "The embedded SwiftRTLSDR package can serve a local dongle over the rtl_tcp protocol for Raspberry Pi and field-station workflows. App controls are next.",
            symbol: "point.3.connected.trianglepath.dotted", status: .notConnected,
            action: .learn("The embedded SwiftRTLSDR package can serve a dongle over the rtl_tcp protocol (rtlsdr-tool serve), for example to a Raspberry Pi field station. The app has no server controls yet. To use someone else's rtl_tcp server as a source, add it in Scanner.")))
        items.append(WorkshopItem(
            "eeprom", .hardware, "RTL-SDR serial provisioning",
            "The embedded driver can read EEPROM and set unique serial numbers with backup and dry-run protections. App controls are next.",
            symbol: "number.square", status: .notConnected,
            action: .learn("The embedded SwiftRTLSDR driver can read the dongle's EEPROM and set a unique serial number with a backup and a dry run first (rtlsdr-tool eeprom, rtlsdr-tool set-serial). The app has no controls for it: writing stays in the command-line tool until the app can show the dry run and the backup before it writes.")))
        items.append(WorkshopItem(
            "hackrf", .hardware, "HackRF One",
            "Receive through libhackrf when it is installed.",
            symbol: "cable.connector", status: env.hackRFPresent ? .ready : .needsSetup,
            setup: env.hackRFPresent ? nil : "Needs libhackrf and a HackRF One.",
            action: env.hackRFPresent ? .open(.scanner) : .fix(.installTool("libhackrf"))))
        items.append(WorkshopItem(
            "otherSDR", .hardware, "Airspy, LimeSDR, SDRplay, PlutoSDR",
            "They are listed as sources, but the streaming code is a first-pass stub that reports itself unsupported, so they cannot be used yet.",
            symbol: "antenna.radiowaves.left.and.right.slash", status: .notConnected,
            action: .learn("Airspy, LimeSDR, SDRplay and PlutoSDR appear as sources, but their streaming code is a stub that reports itself unsupported. Use an RTL-SDR, or add a network source.")))
        items.append(WorkshopItem(
            "uniden", .hardware, "Uniden scanners",
            "Serial protocol helpers exist in the core library; the app cannot program a Uniden yet (export CHIRP CSV or use Uniden's software).",
            symbol: "radio", status: .notConnected,
            action: .learn("Uniden serial protocol helpers exist in the core library, but the app cannot program a Uniden scanner yet. Export CHIRP CSV from Codeplug, or use Uniden's own software.")))
        items.append(WorkshopItem(
            "gps", .hardware, "GPS", "Location models are used for sites; live GPS input is not connected.",
            symbol: "location", status: .planned))
        items.append(WorkshopItem(
            "boards", .hardware, "ESP32, Arduino and Raspberry Pi links",
            "Serial, TCP, BLE and MQTT adapters.", symbol: "cpu", status: .planned))

        // MARK: Planned

        for (id, title, detail, symbol) in [
            ("satdump", "SatDump-style product browser", "Needs capture sessions, Doppler assist, image gallery, calibration metadata and export around the Swift LRPT decoder (pass prediction exists; NOAA APT is off the air).", "shippingbox"),
            ("lora", "LoRa and Meshtastic", "Needs a Swift LoRa demodulator and packet decoder; no published SwiftRTLSDR branch is available yet.", "dot.radiowaves.forward"),
            ("dvb", "Satellite and terrestrial TV", "Needs hardware beyond a standard RTL-SDR.", "tv"),
            ("follow", "Trunk following", "Needs control-channel decoding, talkgroup following and audio recording.", "point.3.connected.trianglepath.dotted"),
            ("swift", "Swift-native voice and paging decoders", "Replace the outside-program wrappers.", "swift"),
            ("cat", "Radio control profiles", "Per-radio CAT and serial profiles with safety limits.", "dial.low"),
        ] {
            items.append(WorkshopItem(id, .planned, title, detail, symbol: symbol, status: .planned))
        }
        return items
    }

    /// What belongs on the Workshop's main grid: everything that exists, even if it is not usable yet.
    public static func homeItems(for env: WorkshopEnvironment) -> [WorkshopItem] {
        items(for: env).filter { $0.status != .planned }
    }

    /// What is not written: kept out of the main grid so it does not look like part of the app.
    public static func roadmapItems(for env: WorkshopEnvironment) -> [WorkshopItem] {
        items(for: env).filter { $0.status == .planned }
    }

    /// One-press shortcuts. Listening ones need any live source; ADS-B needs a dongle, because the 1090 MHz decoder
    /// reads the RTL-SDR directly.
    public static func quickActions(for env: WorkshopEnvironment) -> [WorkshopQuickAction] {
        let fix: WorkshopAction = .fix(.usbHelp)
        func listen(_ id: String, _ title: String, _ detail: String, symbol: String, mhz: Double, mode: DemodMode) -> WorkshopQuickAction {
            env.hasLiveSource
                ? WorkshopQuickAction(id, title, detail, symbol: symbol, action: .launch(.scanner, .scannerTune(mhz: mhz, mode: mode)))
                : WorkshopQuickAction(id, title, detail, symbol: symbol, action: fix, needsSetup: true)
        }
        var actions = [
            listen("noaa-weather", "Listen: NOAA weather", "162.550 MHz, narrowband FM", symbol: "cloud.sun", mhz: 162.55, mode: .nfm),
            listen("airband", "Listen: aircraft guard", "121.500 MHz, AM", symbol: "airplane.departure", mhz: 121.5, mode: .am),
        ]
        actions.append(env.rtlsdrDongles > 0
            ? WorkshopQuickAction("track-aircraft", "Track aircraft", "1090 MHz ADS-B on the Air Map", symbol: "airplane",
                                  action: .launch(.airMap, .listenADSB1090))
            : WorkshopQuickAction("track-aircraft", "Track aircraft", "1090 MHz ADS-B on the Air Map", symbol: "airplane",
                                  action: fix, needsSetup: true))
        actions.append(WorkshopQuickAction("state-data", "Get state data", "FCC licenses for a state, on this Mac",
                                           symbol: "externaldrive.badge.plus", action: .fix(.getFCCData)))
        if env.codeplugChannels > 0 {
            actions.append(WorkshopQuickAction(
                "open-codeplug", "Open codeplug (\(env.codeplugChannels))",
                "\(env.codeplugChannels) channel\(env.codeplugChannels == 1 ? "" : "s") ready to check and export",
                symbol: "memorychip", action: .open(.codeplug)))
        }
        return actions
    }

    /// Items of one section, in the order they are listed.
    public static func items(in section: WorkshopSection, for env: WorkshopEnvironment) -> [WorkshopItem] {
        items(for: env).filter { $0.section == section }
    }

    /// How many capabilities are usable now, and how many exist in all (planned ones excluded from "exist").
    public static func readiness(for env: WorkshopEnvironment) -> (ready: Int, implemented: Int) {
        let implemented = items(for: env).filter { $0.status == .ready || $0.status == .needsSetup }
        return (implemented.filter { $0.status == .ready }.count, implemented.count)
    }

    /// Decoders that decode something in the app today (the Workshop's "Decoders" count).
    public static func workingDecoders(for env: WorkshopEnvironment) -> Int {
        items(in: .decoders, for: env).filter { $0.status == .ready || $0.status == .needsSetup }.count
    }
}
