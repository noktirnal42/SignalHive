import SwiftUI
import SignalHiveCore

/// The antennas the ratings are judged against. Ratings are only as honest as this list.
struct AntennaEditorSheet: View {
    let model: SatellitesModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var lowMHz = ""
    @State private var highMHz = ""
    @State private var gain: AntennaProfile.Gain = .omni
    @State private var directional = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your antennas").font(.title2.weight(.semibold))
            if model.usingPresetAntennas {
                Label("You have not saved any antennas yet, so the NooElec kit below is assumed. Saving any antenna keeps these and lets you change them.",
                      systemImage: "info.circle").font(.callout).foregroundStyle(HiveInk.amber)
            }
            List {
                ForEach(model.antennas) { antenna in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(antenna.name).font(.headline)
                            Spacer()
                            Text("\(Int(antenna.lowHz / 1e6))-\(Int(antenna.highHz / 1e6)) MHz, \(antenna.gain.rawValue)\(antenna.isDirectional ? ", directional" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(role: .destructive) { Task { await model.deleteAntenna(antenna) } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete \(antenna.name)")
                        }
                        if !antenna.notes.isEmpty { Text(antenna.notes).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if model.antennas.isEmpty { Text("No antennas: every pass will read \"None of your antennas covers ...\".").foregroundStyle(.secondary) }
            }
            .frame(minHeight: 160)

            GroupBox("Add an antenna") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name (for example, 137 MHz turnstile)", text: $name)
                    HStack {
                        TextField("Lowest MHz", text: $lowMHz).frame(width: 110)
                        TextField("Highest MHz", text: $highMHz).frame(width: 110)
                        Picker("Gain", selection: $gain) {
                            ForEach([AntennaProfile.Gain.omni, .low, .medium, .high], id: \.self) { Text($0.rawValue).tag($0) }
                        }.frame(width: 160)
                        Toggle("Directional", isOn: $directional)
                    }
                    Text("A directional antenna only counts its gain when a rotator can point it; until then it is rated as omni.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Add") { add() }.disabled(!canAdd)
                        Menu("Add a NooElec preset") {
                            ForEach(AntennaProfile.presets.filter { preset in !model.antennas.contains { $0.id == preset.id } }) { preset in
                                Button(preset.name) { Task { await model.saveAntenna(preset) } }
                            }
                        }
                    }
                }
                .padding(6)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var parsed: (Double, Double)? {
        guard let low = Double(lowMHz), let high = Double(highMHz), low > 0, high >= low else { return nil }
        return (low, high)
    }

    private var canAdd: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && parsed != nil }

    private func add() {
        guard let (low, high) = parsed else { return }
        let antenna = AntennaProfile(id: UUID(), name: name.trimmingCharacters(in: .whitespaces), lowHz: low * 1e6, highHz: high * 1e6,
                                     gain: gain, isDirectional: directional, notes: "Entered by you; not measured.")
        Task { await model.saveAntenna(antenna) }
        name = ""; lowMHz = ""; highMHz = ""; directional = false; gain = .omni
    }
}
