import SwiftUI
import SignalHiveCore

/// The AI Lab's downloaded models and the downloads in flight. It lives on the app model, not on the AI Lab screen, so a
/// download carries on when another panel is showing.
@Observable @MainActor
final class ModelLibrary {
    enum State: Equatable {
        case notDownloaded
        case downloading(ModelInstallProgress)
        case installed(InstalledModel)
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    /// Bytes of an unfinished download already on disk, so "Resume" can say so.
    private(set) var partialBytes: [String: Int64] = [:]

    @ObservationIgnored private let manager: ModelDownloadManager
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(manager: ModelDownloadManager = ModelDownloadManager(directory: ModelDownloadManager.standardDirectory)) {
        self.manager = manager
    }

    func state(for repoID: String) -> State { states[repoID] ?? .notDownloaded }

    var installedCount: Int {
        states.values.filter { if case .installed = $0 { return true } else { return false } }.count
    }

    /// Reads what is on disk. Call when the AI Lab opens.
    func refresh(candidates: [String]) async {
        let installed = await manager.installedModels()
        let byID = Dictionary(installed.map { ($0.repoID, $0) }, uniquingKeysWith: { first, _ in first })
        for repoID in Set(candidates).union(byID.keys) where tasks[repoID] == nil {
            if let record = byID[repoID] {
                states[repoID] = .installed(record)
            } else if case .installed = state(for: repoID) {
                states[repoID] = nil                    // it was deleted outside the app
            }
            partialBytes[repoID] = await manager.stagedBytes(repoID)
        }
    }

    func download(_ repoID: String) {
        guard tasks[repoID] == nil else { return }
        states[repoID] = .downloading(ModelInstallProgress(phase: .listing))
        let manager = self.manager
        let throttle = Throttle()
        tasks[repoID] = Task { [weak self] in
            do {
                let record = try await manager.install(repoID) { update in
                    guard throttle.shouldPass(force: update.phase != .downloading) else { return }
                    Task { @MainActor in self?.apply(update, to: repoID) }
                }
                self?.finish(repoID, .installed(record))
            } catch is CancellationError {
                self?.finish(repoID, .notDownloaded)
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.finish(repoID, .failed(reason))
            }
            if let self { self.partialBytes[repoID] = await manager.stagedBytes(repoID) }
        }
    }

    func cancel(_ repoID: String) {
        tasks[repoID]?.cancel()
    }

    func remove(_ repoID: String) async {
        tasks[repoID]?.cancel()
        do {
            try await manager.remove(repoID)
            states[repoID] = nil
            partialBytes[repoID] = 0
        } catch {
            states[repoID] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func apply(_ update: ModelInstallProgress, to repoID: String) {
        // A late progress report must not undo a finished download.
        guard case .downloading = state(for: repoID) else { return }
        states[repoID] = .downloading(update)
    }

    private func finish(_ repoID: String, _ result: State) {
        tasks[repoID] = nil
        if case .notDownloaded = result { states[repoID] = nil } else { states[repoID] = result }
    }
}

/// Lets a burst of progress callbacks through a few times a second.
private final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldPass(force: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if force || now.timeIntervalSince(last) >= 0.25 {
            last = now
            return true
        }
        return false
    }
}
