import SwiftUI
import SignalHiveCore

struct DecoderHubView: View {
    @State private var selectedDecoder: DecoderTool = .ais
    @State private var inputText = DecoderTool.ais.sampleInput
    @State private var results: [DecoderWorkbenchMessage] = DecoderWorkbench.decodeAISNMEA(DecoderTool.ais.sampleInput)

    var body: some View {
        ZStack {
            HiveWorkbenchBackground()
            HStack(spacing: 0) {
                decoderRail
                    .frame(width: 290)
                Divider().opacity(0.35)
                workbench
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Decoder Hub")
        .onChange(of: selectedDecoder) { _, decoder in
            inputText = decoder.sampleInput
            decode()
        }
    }

    private var decoderRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Decoder Hub")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Text("Manual decode tools now, live SDR sessions next.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(DecoderTool.allCases) { decoder in
                    Button {
                        selectedDecoder = decoder
                    } label: {
                        decoderRow(decoder)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(decoder.title) decoder")
                }

                HiveInstrumentPanel("Live session path", status: "next") {
                    VStack(alignment: .leading, spacing: 10) {
                        decoderStatus("ADS-B / UAT", state: "Live in Air Map", tint: HiveInk.mint)
                        decoderStatus("ISM sensors", state: "SwiftRTLSDR ready", tint: HiveInk.amber)
                        decoderStatus("RS41 radiosondes", state: "SwiftRTLSDR ready", tint: HiveInk.amber)
                        decoderStatus("Meteor LRPT", state: "SatDump-grade UI pending", tint: HiveInk.amber)
                        decoderStatus("Paging / weak signal", state: "Adapter path only", tint: .secondary)
                    }
                }
            }
            .padding(18)
        }
        .background(HiveInk.graphite.opacity(0.82))
    }

    private func decoderRow(_ decoder: DecoderTool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: decoder.symbol)
                .foregroundStyle(selectedDecoder == decoder ? HiveInk.cyan : .white.opacity(0.58))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(decoder.title)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.94))
                Text(decoder.status)
                    .font(.caption)
                    .foregroundStyle(decoder.tint)
                Text(decoder.summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedDecoder == decoder ? HiveInk.cyan.opacity(0.14) : Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedDecoder == decoder ? HiveInk.cyan.opacity(0.45) : .white.opacity(0.07), lineWidth: 1)
        }
    }

    private func decoderStatus(_ title: String, state: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
            Spacer(minLength: 0)
            Text(state)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.52))
        }
    }

    private var workbench: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                inputPanel
                resultsPanel
            }
            .padding(24)
            .frame(maxWidth: 1080, alignment: .leading)
        }
    }

    private var hero: some View {
        HiveInstrumentPanel(status: selectedDecoder.status.lowercased()) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        HiveStatusBadge(selectedDecoder.badge, tint: selectedDecoder.tint)
                        HiveStatusBadge("Swift", tint: HiveInk.cyan)
                    }
                    Text(selectedDecoder.title)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(selectedDecoder.longDescription)
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.white.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    Image(systemName: selectedDecoder.symbol)
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(selectedDecoder.tint)
                    Text(selectedDecoder.frequencyHint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
        }
    }

    private var inputPanel: some View {
        HiveInstrumentPanel("Input", status: selectedDecoder.inputLabel) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $inputText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(.white)
                    .frame(minHeight: 148)
                    .padding(8)
                    .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }

                HStack(spacing: 10) {
                    Button {
                        decode()
                    } label: {
                        Label("Decode", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HiveInk.cyan)

                    Button {
                        inputText = selectedDecoder.sampleInput
                        decode()
                    } label: {
                        Label("Sample", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .tint(HiveInk.amber)

                    if selectedDecoder == .morse {
                        Button {
                            inputText = DecoderWorkbench.encodeMorseText(inputText)
                            decode()
                        } label: {
                            Label("Encode text", systemImage: "textformat.abc")
                        }
                        .buttonStyle(.bordered)
                        .tint(HiveInk.mint)
                    }

                    Spacer()
                    Text(selectedDecoder.inputHelp)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.52))
                }
            }
        }
    }

    private var resultsPanel: some View {
        HiveInstrumentPanel("Messages", status: "\(results.filter { $0.status == .decoded }.count) decoded") {
            VStack(alignment: .leading, spacing: 12) {
                if results.isEmpty {
                    emptyState
                } else {
                    ForEach(results) { message in
                        messageCard(message)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.forward")
                .font(.system(size: 36))
                .foregroundStyle(HiveInk.cyan.opacity(0.72))
            Text("No messages yet")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.82))
            Text("Paste input and press Decode.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func messageCard(_ message: DecoderWorkbenchMessage) -> some View {
        let tint = message.status == .decoded ? HiveInk.mint : HiveInk.amber
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(message.decoder)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(tint)
                Text(message.title)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(message.status == .decoded ? "decoded" : "check input")
                    .font(.caption)
                    .foregroundStyle(tint)
            }
            Text(message.summary)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .textSelection(.enabled)
            if !message.details.isEmpty {
                HStack {
                    ForEach(message.details, id: \.self) { detail in
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.68))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.06), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
            Text(message.raw)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(HiveInk.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
    }

    private func decode() {
        switch selectedDecoder {
        case .ais:
            results = DecoderWorkbench.decodeAISNMEA(inputText)
        case .morse:
            results = [DecoderWorkbench.decodeMorsePatterns(inputText)]
        case .acars:
            results = DecoderWorkbench.decodeACARSText(inputText)
        case .adsb, .uat, .ism, .radiosonde, .lrpt, .paging, .weakSignal:
            results = [
                DecoderWorkbenchMessage(
                    decoder: selectedDecoder.title,
                    title: "Live session not wired yet",
                    summary: selectedDecoder.pendingSummary,
                    details: [selectedDecoder.frequencyHint, selectedDecoder.status],
                    raw: inputText,
                    status: .rejected
                )
            ]
        }
    }
}

private enum DecoderTool: String, CaseIterable, Identifiable {
    case ais
    case morse
    case acars
    case adsb
    case uat
    case ism
    case radiosonde
    case lrpt
    case paging
    case weakSignal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ais: return "AIS NMEA"
        case .morse: return "Morse / CW"
        case .acars: return "ACARS text"
        case .adsb: return "ADS-B 1090"
        case .uat: return "UAT / FIS-B 978"
        case .ism: return "ISM sensors"
        case .radiosonde: return "RS41 radiosonde"
        case .lrpt: return "Meteor LRPT"
        case .paging: return "POCSAG / FLEX"
        case .weakSignal: return "FT8 / WSPR"
        }
    }

    var symbol: String {
        switch self {
        case .ais: return "ferry"
        case .morse: return "dot.circle"
        case .acars: return "teletype"
        case .adsb: return "airplane"
        case .uat: return "cloud.sun.rain"
        case .ism: return "sensor"
        case .radiosonde: return "balloon"
        case .lrpt: return "globe.europe.africa"
        case .paging: return "message.badge.waveform"
        case .weakSignal: return "sparkles"
        }
    }

    var status: String {
        switch self {
        case .ais, .morse, .acars: return "Manual decode"
        case .adsb, .uat: return "Live elsewhere"
        case .ism, .radiosonde, .lrpt: return "Driver ready"
        case .paging, .weakSignal: return "Adapter pending"
        }
    }

    var badge: String {
        switch self {
        case .ais, .morse, .acars: return "manual"
        case .adsb, .uat: return "air"
        case .ism, .radiosonde, .lrpt: return "driver"
        case .paging, .weakSignal: return "adapter"
        }
    }

    var tint: Color {
        switch self {
        case .ais, .morse, .acars: return HiveInk.mint
        case .adsb, .uat: return HiveInk.cyan
        case .ism, .radiosonde, .lrpt: return HiveInk.amber
        case .paging, .weakSignal: return .secondary
        }
    }

    var summary: String {
        switch self {
        case .ais: return "Paste !AIVDM or !AIVDO sentences."
        case .morse: return "Decode dot/dash groups or encode text."
        case .acars: return "Summarize decoded VHF aircraft text."
        case .adsb: return "Use Air Map for live aircraft."
        case .uat: return "Use Air Data for weather products."
        case .ism: return "SwiftRTLSDR decoder awaits capture UI."
        case .radiosonde: return "RS41 frames await tracking UI."
        case .lrpt: return "LRPT awaits capture and image products."
        case .paging: return "External adapter is not attached."
        case .weakSignal: return "Text parser has no audio path."
        }
    }

    var longDescription: String {
        switch self {
        case .ais:
            return "Decode marine AIS NMEA sentences into MMSI, position, speed, course and static vessel fields."
        case .morse:
            return "Decode pasted dot/dash groups, or encode plain text into Morse patterns for CW practice and decoder checks."
        case .acars:
            return "Summarize decoded ACARS text by label, flight, registration and likely message kind while the SDR frame session is being built."
        case .adsb:
            return "The live 1090 MHz receiver is already wired into Air Map and Air Data; this hub links the decoder family together."
        case .uat:
            return "The live 978 MHz receiver is already wired into Air Map and Air Data for UAT traffic, FIS-B weather and text products."
        case .ism:
            return "SwiftRTLSDR contains rtl_433-style protocol decoders. SignalHive still needs the live capture session and message table."
        case .radiosonde:
            return "SwiftRTLSDR contains Vaisala RS41 frame decoding. SignalHive still needs scan, track and map tools."
        case .lrpt:
            return "SwiftRTLSDR contains Meteor LRPT demodulation and product parsing. SignalHive still needs pass-to-capture, Doppler assist and an image browser."
        case .paging:
            return "Paging currently depends on adapter output. The planned work is an original Swift path and a live message view."
        case .weakSignal:
            return "Weak-signal text parsers exist, but SignalHive still needs an audio/IQ feed and timing recovery."
        }
    }

    var frequencyHint: String {
        switch self {
        case .ais: return "161.975 / 162.025 MHz"
        case .morse: return "CW narrowband"
        case .acars: return "VHF ACARS channels"
        case .adsb: return "1090 MHz"
        case .uat: return "978 MHz"
        case .ism: return "433.92 MHz and peers"
        case .radiosonde: return "400-406 MHz"
        case .lrpt: return "137 MHz weather sats"
        case .paging: return "VHF / UHF paging"
        case .weakSignal: return "audio passband"
        }
    }

    var inputLabel: String {
        switch self {
        case .ais: return "NMEA"
        case .morse: return "patterns or text"
        case .acars: return "text frames"
        default: return "live source"
        }
    }

    var inputHelp: String {
        switch self {
        case .ais: return "One NMEA sentence per line"
        case .morse: return "Use / between words"
        case .acars: return "One decoded message per line"
        default: return "Live RTL-SDR session wiring comes next"
        }
    }

    var sampleInput: String {
        switch self {
        case .ais:
            return "!AIVDM,1,1,,A,15M:Ih001sG@0Q8K;P8:V`MD0000,0*75"
        case .morse:
            return "... --- ... / -.-. --.- / - . ... -"
        case .acars:
            return "Q0 N123AB DAL123 POS 37.62 -122.38"
        default:
            return pendingSummary
        }
    }

    var pendingSummary: String {
        switch self {
        case .adsb:
            return "Start 1090 MHz ADS-B from Air Map. Decoder Hub will gain a shared live session table after DecoderSession lands."
        case .uat:
            return "Start 978 MHz UAT/FIS-B from Air Data or Air Map. Decoder Hub will gain a shared live session table after DecoderSession lands."
        case .ism:
            return "SwiftRTLSDR has the ISM decoder family; SignalHive still needs source selection, gain, protocol filters and export."
        case .radiosonde:
            return "SwiftRTLSDR has RS41 decoding; SignalHive still needs scan presets, map tracks and launch-site summaries."
        case .lrpt:
            return "SwiftRTLSDR has Meteor LRPT pieces; SignalHive still needs pass scheduling handoff, Doppler assist, capture and image gallery."
        case .paging:
            return "SignalHive currently parses adapter output only. Original Swift paging demodulation remains planned."
        case .weakSignal:
            return "Weak-signal message parsing exists, but there is no live audio/IQ timing path into it yet."
        default:
            return sampleInput
        }
    }
}
