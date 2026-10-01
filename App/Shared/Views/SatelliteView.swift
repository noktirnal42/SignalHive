import SwiftUI
import SignalHiveCore

struct SatelliteView: View {
    @Environment(AviationModel.self) private var aviation
    @State private var observerText = ""
    @State private var observer: GeoCoordinate?
    @State private var satellites: [SatelliteTLE] = []
    @State private var passes: [SatellitePass] = []
    @State private var status = "Set receiver location, then update weather-satellite elements."
    @State private var isLoading = false
    @State private var minimumElevation = 8.0
    @State private var horizonHours = 24.0

    private let sourceURL = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=weather&FORMAT=tle")!
    private let planner = SatellitePassPlanner()

    var body: some View {
        ZStack {
            HiveWorkbenchBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero
                    controls
                    passList
                }
                .padding(24)
                .frame(maxWidth: 1120, alignment: .leading)
            }
        }
        .navigationTitle("Satellites")
        .onAppear {
            if let receiver = aviation.receiverLocation {
                setObserver(receiver)
            }
        }
        .onChange(of: aviation.receiverLocation) { _, location in
            guard let location else { return }
            setObserver(location)
        }
    }

    private var hero: some View {
        HiveInstrumentPanel(status: satellites.isEmpty ? "needs elements" : "\(satellites.count) elements") {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        HiveStatusBadge("TLE", tint: HiveInk.cyan)
                        HiveStatusBadge("LRPT", tint: HiveInk.mint)
                        HiveStatusBadge("RS41", tint: HiveInk.amber)
                    }
                    Text("Satellite Workshop")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Plan weather-satellite passes from your antenna location, then hand the pass to Meteor LRPT and future SatDump-style capture tools.")
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HiveSignalMeter(value: min(1, (passes.first?.maxElevationDegrees ?? 0) / 90),
                                label: "PEAK", unit: passes.first.map { "\(Int($0.maxElevationDegrees.rounded())) deg" } ?? "--",
                                tint: HiveInk.mint)
                    .frame(width: 220, height: 160)
            }
        }
    }

    private var controls: some View {
        HiveInstrumentPanel(status: status) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("Receiver latitude, longitude", text: $observerText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { applyObserverText() }
                    Button("Set") { applyObserverText() }
                    Button {
                        if let location = aviation.receiverLocation { setObserver(location) }
                    } label: {
                        Label("Use antenna", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(aviation.receiverLocation == nil)
                    Button {
                        aviation.requestLocationServices()
                    } label: {
                        Label("Device location", systemImage: "location")
                    }
                }
                HStack(spacing: 16) {
                    HStack {
                        Text("Minimum elevation")
                        Slider(value: $minimumElevation, in: 0...30, step: 1)
                            .frame(width: 170)
                        Text("\(Int(minimumElevation)) deg")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("Horizon")
                        Slider(value: $horizonHours, in: 6...72, step: 6)
                            .frame(width: 140)
                        Text("\(Int(horizonHours)) h")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                    }
                    Spacer()
                    Button {
                        Task { await refreshElements() }
                    } label: {
                        Label(isLoading ? "Updating..." : "Update TLEs", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isLoading)
                    Button {
                        rebuildPasses()
                    } label: {
                        Label("Recalculate", systemImage: "calendar.badge.clock")
                    }
                    .disabled(satellites.isEmpty || observer == nil)
                }
                .font(.caption)
                if let observer {
                    Text("Observer: \(AviationFormat.coordinate(observer))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let error = aviation.locationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onChange(of: minimumElevation) { _, _ in rebuildPasses() }
        .onChange(of: horizonHours) { _, _ in rebuildPasses() }
    }

    private var passList: some View {
        HiveInstrumentPanel(status: "\(passes.count) passes") {
            if passes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No passes calculated yet", systemImage: "globe.americas")
                        .font(.title3.weight(.semibold))
                    Text("Set the antenna position and update TLEs. Meteor LRPT decode support exists in the embedded SwiftRTLSDR package; live capture, image gallery, Doppler control and SatDump-style product browsing are the next app layer.")
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(passes.prefix(48)) { pass in
                        passRow(pass)
                    }
                }
            }
        }
    }

    private func passRow(_ pass: SatellitePass) -> some View {
        HStack(spacing: 12) {
            Image(systemName: satelliteSymbol(pass.satellite.name))
                .font(.title3)
                .foregroundStyle(HiveInk.cyan)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(pass.satellite.name)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                Text("\(pass.start.formatted(date: .omitted, time: .shortened)) - \(pass.end.formatted(date: .omitted, time: .shortened))  peak \(pass.peak.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            metric("EL", "\(Int(pass.maxElevationDegrees.rounded())) deg", HiveInk.mint)
            metric("AZ", "\(Int(pass.peakAzimuthDegrees.rounded())) deg", HiveInk.amber)
            metric("RANGE", "\(Int(pass.peakRangeKM.rounded())) km", HiveInk.violet)
        }
        .padding(10)
        .background(HiveInk.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func metric(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 74, alignment: .trailing)
    }

    private func refreshElements() async {
        isLoading = true
        status = "Fetching CelesTrak weather TLEs..."
        defer { isLoading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: sourceURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                status = "CelesTrak returned HTTP \(http.statusCode)."
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                status = "CelesTrak returned data that was not UTF-8 text."
                return
            }
            satellites = TLEParser.parseMany(text).filter { supportedWeatherName($0.name) }
            status = satellites.isEmpty ? "No supported weather satellites found in the current element set." : "Updated \(satellites.count) weather-satellite elements."
            rebuildPasses()
        } catch {
            status = "Could not update TLEs: \(error.localizedDescription)"
        }
    }

    private func rebuildPasses() {
        guard let observer else {
            passes = []
            status = "Set receiver location before calculating passes."
            return
        }
        let planner = SatellitePassPlanner(minimumElevationDegrees: minimumElevation, sampleInterval: 45)
        passes = planner.upcomingPasses(for: satellites, observer: observer, from: Date(),
                                        through: Date().addingTimeInterval(horizonHours * 3600))
        if !satellites.isEmpty {
            status = passes.isEmpty ? "No passes above \(Int(minimumElevation)) deg in the next \(Int(horizonHours)) h." : "Calculated passes from \(satellites.count) current elements."
        }
    }

    private func applyObserverText() {
        if let coordinate = GeoCoordinate.parse(observerText) {
            setObserver(coordinate)
        } else {
            status = "Type latitude and longitude, like 40.1234, -100.5678."
        }
    }

    private func setObserver(_ coordinate: GeoCoordinate) {
        observer = coordinate
        observerText = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        rebuildPasses()
    }

    private func supportedWeatherName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper.contains("METEOR") || upper.contains("NOAA") || upper.contains("METOP")
    }

    private func satelliteSymbol(_ name: String) -> String {
        name.uppercased().contains("METEOR") ? "globe.europe.africa" : "globe.americas"
    }
}
