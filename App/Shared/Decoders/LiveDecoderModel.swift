import SwiftUI
import SignalHiveCore

/// A running Decoder Hub session: one dongle, one decoder, a table of what it has heard. It lives on the app model so the
/// numbers survive a trip to another panel, but the hub stops it when it disappears: a decoder nobody can see should not
/// keep the only dongle.
@Observable @MainActor
final class LiveDecoderModel {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var preset: DecoderLivePreset?
    private(set) var rows: [DecoderWorkbenchMessage] = []
    private(set) var snapshot: DecoderSessionSnapshot?
    private(set) var deviceName: String?
    var gainDB = 38.0

    static let owner = "Decoder Hub"
    static let rowLimit = 300

    @ObservationIgnored private var session: DecoderSession?
    @ObservationIgnored private var device: (any SDRDevice)?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?

    var isActive: Bool {
        switch state {
        case .starting, .running: return true
        case .idle, .failed: return false
        }
    }

    var failure: String? {
        if case let .failed(reason) = state { return reason }
        return nil
    }

    func start(_ preset: DecoderLivePreset) async {
        guard !isActive else { return }
        state = .starting
        self.preset = preset
        rows = []
        snapshot = nil
        #if os(macOS)
        let manager = SDRDeviceManager.shared
        if !manager.availableDevices.contains(where: { $0.deviceType == .rtlsdr }) {
            await manager.scan()
        }
        let dongles = manager.availableDevices.filter { $0.deviceType == .rtlsdr }
        guard !dongles.isEmpty else {
            state = .failed("No RTL-SDR found. Plug one in, then try again.")
            return
        }
        let registry = DongleRegistry.shared
        guard let chosen = registry.firstFree(in: dongles, for: Self.owner) else {
            state = .failed(registry.busyExplanation(for: dongles))
            return
        }
        guard preset.isTunable(by: chosen.frequencyRange) else {
            state = .failed("\(chosen.name) cannot tune \(String(format: "%.3f", preset.frequencyMHz)) MHz.")
            return
        }
        do {
            try registry.claim(chosen, owner: Self.owner)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }

        let session = DecoderSession(decoder: preset.makeDecoder(), device: chosen, config: preset.sessionConfig(gainDB: gainDB))
        let stream = await session.messageStream()
        do {
            try await session.start()
        } catch {
            registry.release(chosen, owner: Self.owner)
            state = .failed(error.localizedDescription)
            return
        }
        self.session = session
        device = chosen
        deviceName = chosen.name + " " + chosen.serial
        state = .running

        listenTask = Task { [weak self] in
            for await output in stream {
                self?.append(DecoderWorkbench.liveRow(for: output.message))
            }
        }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                if let snapshot = await self?.session?.snapshot { self?.snapshot = snapshot }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        #else
        state = .failed("Live decoding needs the Mac app (it drives the dongle over USB).")
        #endif
    }

    func stop() async {
        listenTask?.cancel()
        statsTask?.cancel()
        listenTask = nil
        statsTask = nil
        if let session {
            await session.stop()
            snapshot = await session.snapshot
        }
        session = nil
        if let device { DongleRegistry.shared.release(device, owner: Self.owner) }
        device = nil
        deviceName = nil
        if isActive || failure == nil { state = .idle }
    }

    func clear() {
        rows = []
    }

    private func append(_ row: DecoderWorkbenchMessage) {
        rows.insert(row, at: 0)
        if rows.count > Self.rowLimit { rows.removeLast(rows.count - Self.rowLimit) }
    }
}
