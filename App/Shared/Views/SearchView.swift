import SwiftUI
import SignalHiveCore

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [AppDatabase.SearchResult] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Call sign, licensee, or frequency (MHz)", text: $query)
                            .textFieldStyle(.plain)
                            .onSubmit { runSearch() }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }

                if searching {
                    ProgressView()
                } else if !results.isEmpty {
                    Section("Results (\(results.count))") {
                        ForEach(results) { result in
                            resultRow(result)
                        }
                    }
                } else if !query.isEmpty {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Search")
        }
    }

    @ViewBuilder
    private func resultRow(_ result: AppDatabase.SearchResult) -> some View {
        if result.kind == "license", let uid = result.uid {
            NavigationLink(value: uid) {
                rowContent(result)
            }
        } else {
            Button {
                if let hz = result.frequencyHz {
                    model.tuneInScanner(frequencyHz: hz)
                }
                if let uid = result.uid {
                    openLicense(uid: uid)
                }
            } label: {
                rowContent(result)
            }
            .buttonStyle(.plain)
        }
    }

    private func rowContent(_ result: AppDatabase.SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.title)
                .font(.body)
            HStack(spacing: 6) {
                Image(systemName: result.kind == "frequency" ? "waveform" : "person.text.rectangle")
                    .font(.caption2)
                Text(result.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @State private var openedUID: Int64?

    private func openLicense(uid: Int64) {
        openedUID = uid
    }

    private func runSearch() {
        searchTask?.cancel()
        guard let database = model.database else { return }
        searching = true
        let q = query
        searchTask = Task {
            let found = (try? await database.search(query: q, service: nil, state: nil)) ?? []
            await MainActor.run {
                results = found
                searching = false
            }
        }
    }
}
