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
    case browse, search, scanner, trunked, codeplug, aiLab, satellites, airMap, airData
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
    public var destination: WorkshopDestination?

    public init(_ id: String, _ section: WorkshopSection, _ title: String, _ detail: String, symbol: String,
                status: WorkshopStatus, setup: String? = nil, destination: WorkshopDestination? = nil) {
        self.id = id
        self.section = section
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.status = status
        self.setup = setup
        self.destination = destination
    }
}

public enum WorkshopCatalog {
    public static func items(for env: WorkshopEnvironment) -> [WorkshopItem] {
        var items: [WorkshopItem] = []
        let liveSetup = "Plug in an RTL-SDR, or add a network source in Scanner."
        let live: WorkshopStatus = env.hasLiveSource ? .ready : .needsSetup
        let liveNote: String? = env.hasLiveSource ? nil : liveSetup

        // MARK: Workflows

        items.append(WorkshopItem(
            "fcc", .workflows, "FCC license packs",
            env.installedPacks > 0
                ? "\(env.installedPacks) state pack\(env.installedPacks == 1 ? "" : "s") installed. Browse counties, licensees, frequencies, modes, power and sites; search across all of them."
                : "Browse counties, licensees, frequencies, modes, power and sites once a state pack is installed.",
            symbol: "externaldrive.fill", status: env.installedPacks > 0 ? .ready : .needsSetup,
            setup: env.installedPacks > 0 ? nil : "Open Browse and get a state's data.", destination: .browse))
        items.append(WorkshopItem(
            "spectrum", .workflows, "Live spectrum and waterfall",
            "Tune anywhere the source allows; see the spectrum and waterfall, click a signal to listen.",
            symbol: "waveform.path.ecg", status: live, setup: liveNote, destination: .scanner))
        items.append(WorkshopItem(
            "demod", .workflows, "Demodulation",
            env.demodModes.isEmpty ? "Voice demodulators in the scanner." : "The scanner demodulates \(env.demodModes.joined(separator: ", ")).",
            symbol: "slider.horizontal.3", status: live, setup: liveNote, destination: .scanner))
        items.append(WorkshopItem(
            "airmap", .workflows, "Air Map: ADS-B and FIS-B",
            "Aircraft on a map with painted icons colored by altitude, trails, and NEXRAD radar from FIS-B.",
            symbol: "airplane", status: env.rtlsdrDongles > 0 ? .ready : .needsSetup,
            setup: env.rtlsdrDongles > 0 ? nil : "Live traffic needs an RTL-SDR (1090 MHz for aircraft, 978 MHz for FIS-B).",
            destination: .airMap))
        items.append(WorkshopItem(
            "airdata", .workflows, "Air Data: weather and messages",
            "METAR, TAF, PIREP, SIGMET, AIRMET, NOTAM and TFR text from FIS-B, decoded, with an airport weather board and alerts.",
            symbol: "doc.text.magnifyingglass", status: env.rtlsdrDongles > 0 ? .ready : .needsSetup,
            setup: env.rtlsdrDongles > 0 ? nil : "FIS-B is broadcast on 978 MHz and needs an RTL-SDR.",
            destination: .airData))
        items.append(WorkshopItem(
            "satellites", .workflows, "Satellite pass planner",
            "Fetches current weather-satellite elements, uses the antenna location, and schedules upcoming NOAA, Meteor and MetOp passes for RTL-SDR capture.",
            symbol: "globe.americas", status: .ready, destination: .satellites))
        items.append(WorkshopItem(
            "codeplug", .workflows, "Radio programming",
            env.codeplugChannels > 0
                ? "The open codeplug has \(env.codeplugChannels) channel\(env.codeplugChannels == 1 ? "" : "s"). Checked against the radio; CHIRP CSV in and out; direct write for radios that support it."
                : "Build codeplugs from Browse, Search, Scanner and Trunked; check them against the radio; CHIRP CSV in and out; direct write for radios that support it.",
            symbol: "memorychip", status: .ready, destination: .codeplug))
        items.append(WorkshopItem(
            "trunked", .workflows, "Trunked system browser",
            "OpenMHz systems and talkgroups by service (law, fire, EMS ...), kept for offline use, added to a codeplug as talkgroup channels. It lists systems; it does not follow calls.",
            symbol: "antenna.radiowaves.left.and.right", status: .ready, destination: .trunked))
        items.append(WorkshopItem(
            "finder", .workflows, "Signal finder",
            "Finds the active peaks in the spectrum and adds them to the codeplug.",
            symbol: "sparkle.magnifyingglass", status: live, setup: liveNote, destination: .scanner))
        items.append(WorkshopItem(
            "ailab", .workflows, "AI Lab",
            env.aiModelsInstalled > 0
                ? "\(env.aiModelsInstalled) on-device model\(env.aiModelsInstalled == 1 ? "" : "s") downloaded."
                : "On-device signal descriptions and RF coaching; download local models here.",
            symbol: "brain.head.profile", status: .ready, destination: .aiLab))

        // MARK: Decoders

        let oneDongle = env.rtlsdrDongles == 1 ? " One dongle runs one band at a time; two dongles run both." : ""
        items.append(WorkshopItem(
            "adsb", .decoders, "ADS-B 1090 MHz",
            "Native Mode S decoding straight from an RTL-SDR: position (CPR), altitude, speed, heading, callsign, squawk and emergencies.\(oneDongle)",
            symbol: "airplane", status: env.rtlsdrDongles > 0 ? .ready : .needsSetup,
            setup: env.rtlsdrDongles > 0 ? nil : "Needs an RTL-SDR and a 1090 MHz antenna.", destination: .airMap))
        items.append(WorkshopItem(
            "uat", .decoders, "UAT 978 MHz and FIS-B",
            "Native UAT decoding: general-aviation aircraft, TIS-B traffic, NEXRAD radar and text products from ground stations. United States only.",
            symbol: "cloud.sun.rain", status: env.rtlsdrDongles > 0 ? .ready : .needsSetup,
            setup: env.rtlsdrDongles > 0 ? nil : "Needs an RTL-SDR and a 978 MHz antenna.", destination: .airData))
        items.append(WorkshopItem(
            "ism", .decoders, "ISM sensors: rtl_433-style",
            "The embedded SwiftRTLSDR decoder library has an RTL-SDR receive chain and 11 weather-station, sensor and remote protocols. App capture UI is next.",
            symbol: "sensor", status: .notConnected, destination: .scanner))
        items.append(WorkshopItem(
            "rs41", .decoders, "RS41 radiosondes",
            "The embedded SwiftRTLSDR decoder library has Vaisala RS41 frames, GPS position, temperature, battery and scan mode. App tracking UI is next.",
            symbol: "balloon", status: .notConnected, destination: .satellites))
        items.append(WorkshopItem(
            "lrpt", .decoders, "Meteor LRPT satellite images",
            "The embedded SwiftRTLSDR decoder library has Meteor-M LRPT demodulation, deframing, MSU-MR image products and a SatDump-checked oracle path. App capture UI is next.",
            symbol: "globe.europe.africa", status: .notConnected, destination: .satellites))
        for (id, title, detail, symbol) in [
            ("acars", "ACARS", "VHF aircraft text messages.", "teletype"),
            ("ais", "AIS", "Ship positions and voyage data.", "ferry"),
            ("morse", "Morse and CW", "Code decoding.", "dot.circle"),
        ] {
            items.append(WorkshopItem(
                id, .decoders, title, detail + " The decoder is in the core library but the scanner does not use it yet, so the app decodes nothing here.",
                symbol: symbol, status: .notConnected, destination: .scanner))
        }
        items.append(WorkshopItem(
            "dmr", .decoders, "P25, DMR and NXDN metadata",
            "The decoder wraps the outside program dsdccx, and the app does not attach it to the scanner yet.",
            symbol: "person.wave.2", status: .notConnected,
            setup: env.tools.contains("dsdccx") ? "dsdccx is installed." : nil))
        items.append(WorkshopItem(
            "paging", .decoders, "POCSAG and FLEX paging",
            "The decoder wraps the outside program multimon-ng, and the app does not attach it to the scanner yet.",
            symbol: "message.badge.waveform", status: .notConnected,
            setup: env.tools.contains("multimon-ng") ? "multimon-ng is installed." : nil))
        items.append(WorkshopItem(
            "weak", .decoders, "FT8, FT4 and WSPR",
            "A message parser exists; there is no audio path that feeds it, so nothing is decoded live.",
            symbol: "sparkles", status: .notConnected))

        // MARK: Hardware

        items.append(WorkshopItem(
            "rtlsdr", .hardware, "RTL-SDR (USB)",
            env.rtlsdrDongles > 0 ? env.rtlsdrSummary + " Native Swift driver, no libraries to install." : (env.rtlsdrSummary.isEmpty ? "Native Swift driver, no libraries to install." : env.rtlsdrSummary),
            symbol: "cable.connector.horizontal", status: env.rtlsdrDongles > 0 ? .ready : .needsSetup,
            setup: env.rtlsdrDongles > 0 ? nil : "Plug in a dongle. Only one program can use it at a time."))
        items.append(WorkshopItem(
            "network", .hardware, "Network sources",
            env.networkSources > 0
                ? "\(env.networkSources) saved network source\(env.networkSources == 1 ? "" : "s"), for example a Raspberry Pi running rtl_tcp. (OpenWebRX sources are a first-pass implementation.)"
                : "rtl_tcp servers, for example a Raspberry Pi with a dongle in the field. Add one in Scanner. (OpenWebRX sources are a first-pass implementation.)",
            symbol: "network", status: env.networkSources > 0 ? .ready : .needsSetup,
            setup: env.networkSources > 0 ? nil : "Add a host in Scanner.", destination: .scanner))
        items.append(WorkshopItem(
            "rtltcp", .hardware, "rtl_tcp server",
            "The embedded SwiftRTLSDR package can serve a local dongle over the rtl_tcp protocol for Raspberry Pi and field-station workflows. App controls are next.",
            symbol: "point.3.connected.trianglepath.dotted", status: .notConnected, destination: .scanner))
        items.append(WorkshopItem(
            "eeprom", .hardware, "RTL-SDR serial provisioning",
            "The embedded driver can read EEPROM and set unique serial numbers with backup and dry-run protections. App controls are next.",
            symbol: "number.square", status: .notConnected))
        items.append(WorkshopItem(
            "hackrf", .hardware, "HackRF One",
            "Receive through libhackrf when it is installed.",
            symbol: "cable.connector", status: env.hackRFPresent ? .ready : .needsSetup,
            setup: env.hackRFPresent ? nil : "Needs libhackrf and a HackRF One."))
        items.append(WorkshopItem(
            "otherSDR", .hardware, "Airspy, LimeSDR, SDRplay, PlutoSDR",
            "They are listed as sources, but the streaming code is a first-pass stub that reports itself unsupported, so they cannot be used yet.",
            symbol: "antenna.radiowaves.left.and.right.slash", status: .notConnected))
        items.append(WorkshopItem(
            "uniden", .hardware, "Uniden scanners",
            "Serial protocol helpers exist in the core library; the app cannot program a Uniden yet (export CHIRP CSV or use Uniden's software).",
            symbol: "radio", status: .notConnected))
        items.append(WorkshopItem(
            "gps", .hardware, "GPS", "Location models are used for sites; live GPS input is not connected.",
            symbol: "location", status: .planned))
        items.append(WorkshopItem(
            "boards", .hardware, "ESP32, Arduino and Raspberry Pi links",
            "Serial, TCP, BLE and MQTT adapters.", symbol: "cpu", status: .planned))

        // MARK: Planned

        for (id, title, detail, symbol) in [
            ("apt", "NOAA APT weather satellite images", "Needs an audio capture chain and an image renderer; pass scheduling now has a Swift foundation.", "dot.radiowaves.up.forward"),
            ("satdump", "SatDump-style product browser", "Needs capture sessions, Doppler assist, image gallery, calibration metadata and export around the Swift LRPT decoder.", "shippingbox"),
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
