import SwiftUI
import SignalHiveCore

// MARK: - App model

@Observable
@MainActor
final class AppModel: ObservableObject {
    var database: AppDatabase?
    var databaseReady = false
    var databaseError: String?

    var importProgress: ULSImportProgress?
    var importActive = false
    var lastImportSummary: String?

    var stats: (licenses: Int, frequencies: Int, locations: Int) = (0, 0, 0)
    var codeplug = Codeplug()
    var codeplugs: [Codeplug] = []

    // Cross-view navigation intent
    var pendingScanFrequency: Double?

    private var importer = ULSImporter()

    init() {
        Task { await bootstrap() }
    }

    func bootstrap() async {
        do {
            let db = try await AppDatabase.open(at: AppDatabase.defaultURL().path)
            try await db.seedStatesIfNeeded()
            database = db
            databaseReady = true
            await refreshStats()
            codeplugs = (try? await db.codeplugs()) ?? []
            if let first = codeplugs.first {
                codeplug = first
            }
        } catch {
            databaseError = error.localizedDescription
        }
    }

    func refreshStats() async {
        guard let database else { return }
        stats = (try? await database.stats()) ?? (0, 0, 0)
    }

    // MARK: ULS import

    func importServices(_ services: [ULSService]) async {
        guard let database, !importActive else { return }
        importActive = true
        lastImportSummary = nil

        await importer.setProgressHandler { [weak self] progress in
            Task { @MainActor in
                self?.importProgress = progress
            }
        }

        var total = 0
        for service in services {
            do {
                total += try await importer.importService(service, into: database)
            } catch is CancellationError {
                break
            } catch {
                lastImportSummary = "Import failed: \(error.localizedDescription)"
                importActive = false
                importProgress = nil
                await refreshStats()
                return
            }
        }

        lastImportSummary = "Imported \(total) records from \(services.count) service(s)"
        importActive = false
        importProgress = nil
        await refreshStats()
    }

    func cancelImport() {
        Task { await importer.cancel() }
    }

    // MARK: Codeplug

    func addToCodeplug(channel: CodeplugChannel) {
        codeplug.add(channel: channel)
        persistCodeplug()
    }

    func removeChannel(_ channel: CodeplugChannel) {
        codeplug.remove(channelID: channel.id)
        persistCodeplug()
    }

    func persistCodeplug() {
        guard let database else { return }
        let plug = codeplug
        Task {
            try? await database.saveCodeplug(plug)
            codeplugs = (try? await database.codeplugs()) ?? codeplugs
        }
    }

    func newCodeplug(name: String, target: RadioTarget) {
        codeplug = Codeplug(name: name, target: target)
        persistCodeplug()
    }

    func tuneInScanner(frequencyHz: Double) {
        pendingScanFrequency = frequencyHz
    }
}
