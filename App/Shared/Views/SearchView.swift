import SwiftUI
import SignalHiveCore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var searching = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Call sign, licensee, or frequency (MHz)", text: $query)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                if model.installedCount == 0 {
                    Text("Install a state's data from Browse to search it.").foregroundStyle(.secondary)
                } else if searching {
                    ProgressView()
                } else if let errorText {
                    Text(errorText).foregroundStyle(.red)
                } else if !results.isEmpty {
                    Section("Results (\(results.count))") {
                        ForEach(results) { hit in
                            NavigationLink(value: hit.uid) { row(hit) }
                        }
                    }
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        emptySearchState
                    }
                    .listRowBackground(Color.clear)
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: Int64.self) { uid in FrequencyDetailView(uid: uid) }
            .task(id: query) { await runSearch() }
        }
    }

    private var emptySearchState: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search FCC packs")
                        .font(.title3.weight(.semibold))
                    Text("Use a call sign, licensee name, county, service, or frequency.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                ForEach(exampleQueries, id: \.self) { example in
                    Button(example) {
                        query = example
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exampleQueries: [String] {
        ["155.475", "NOAA", "Sheriff", "Aviation"]
    }

    private func row(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.title)
            HStack(spacing: 6) {
                Image(systemName: hit.kind == .frequency ? "waveform" : "person.text.rectangle").font(.caption2)
                Text(hit.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Debounced: `.task(id:)` cancels the previous run when the text changes.
    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            errorText = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await model.browse.search(text, scope: .all)
            guard !Task.isCancelled else { return }
            results = found
            errorText = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorText = error.localizedDescription
        }
    }
}
