import SwiftUI
import SignalHiveCore
import AppKit

// MenuBar App Delegate - entry point for the MenuBar target
class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var menuBarController: MenuBarController?
    var model: AppModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        
        // Create the menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "SignalHive")
            button.image?.isTemplate = true
        }
        
        // Create the menu bar controller
        menuBarController = MenuBarController(model: model, statusItem: statusItem)
        
        // Initialize the model
        Task {
            await model.bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItem = nil
        menuBarController = nil
    }
}

@MainActor
class MenuBarController: ObservableObject {
    private let model: AppModel
    private let statusItem: NSStatusItem?
    private var updateTimer: Timer?
    private var menu: NSMenu?

    init(model: AppModel, statusItem: NSStatusItem?) {
        self.model = model
        self.statusItem = statusItem
        setupMenu()
        startUpdateTimer()
    }

    private func setupMenu() {
        let menu = NSMenu()
        self.menu = menu
        
        // Header
        let headerItem = NSMenuItem(title: "SignalHive", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        let headerView = NSHostingView(rootView: MenuHeaderView(model: model))
        headerView.frame = NSRect(x: 0, y: 0, width: 250, height: 60)
        headerItem.view = headerView
        menu.addItem(headerItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Scanner status
        let statusItem = NSMenuItem(title: "Scanner: Idle", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.tag = 100
        menu.addItem(statusItem)
        
        // Frequency display
        let freqItem = NSMenuItem(title: "Frequency: —", action: nil, keyEquivalent: "")
        freqItem.isEnabled = false
        freqItem.tag = 101
        menu.addItem(freqItem)
        
        // RSSI display
        let rssiItem = NSMenuItem(title: "RSSI: —", action: nil, keyEquivalent: "")
        rssiItem.isEnabled = false
        rssiItem.tag = 102
        menu.addItem(rssiItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quick actions
        let startStopItem = NSMenuItem(title: "Start Scanning", action: #selector(toggleScanning), keyEquivalent: "s")
        startStopItem.target = self
        startStopItem.tag = 103
        menu.addItem(startStopItem)
        
        let retuneItem = NSMenuItem(title: "Retune", action: #selector(retune), keyEquivalent: "r")
        retuneItem.target = self
        retuneItem.isEnabled = false
        retuneItem.tag = 104
        menu.addItem(retuneItem)
        
        let findActiveItem = NSMenuItem(title: "Find Active", action: #selector(findActive), keyEquivalent: "f")
        findActiveItem.target = self
        findActiveItem.isEnabled = false
        menu.addItem(findActiveItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Device selection submenu
        let deviceMenu = NSMenu()
        let deviceItem = NSMenuItem(title: "SDR Source", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        deviceItem.tag = 200
        menu.addItem(deviceItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Open main app
        let openAppItem = NSMenuItem(title: "Open SignalHive", action: #selector(openMainApp), keyEquivalent: "o")
        openAppItem.target = self
        menu.addItem(openAppItem)
        
        // Settings
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit SignalHive MenuBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        
        self.statusItem?.menu = menu
    }
    
    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateMenu()
        }
    }
    
    private func updateMenu() {
        guard let menu = self.menu else { return }
        
        // Update status bar icon
        if let button = statusItem?.button {
            if model.importActive {
                button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Importing")
            } else if model.pendingScanFrequency != nil {
                button.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "Pending tune")
            } else {
                button.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "SignalHive")
            }
            button.image?.isTemplate = true
        }
        
        // Update status items
        if let statusItem = menu.item(withTag: 100) {
            statusItem.title = "Scanner: \(model.importActive ? "Importing" : "Idle")"
        }
        
        if let freqItem = menu.item(withTag: 101) {
            if let pending = model.pendingScanFrequency {
                freqItem.title = String(format: "Frequency: %.5f MHz", pending / 1_000_000)
            } else {
                freqItem.title = "Frequency: —"
            }
        }
        
        if let rssiItem = menu.item(withTag: 102) {
            rssiItem.title = "RSSI: —"
        }
        
        if let startStopItem = menu.item(withTag: 103) {
            startStopItem.title = "Start Scanning"
        }
        
        if let retuneItem = menu.item(withTag: 104) {
            retuneItem.isEnabled = model.pendingScanFrequency != nil
        }
    }
    
    @objc func toggleScanning() {
        // TODO: Connect to scanner
    }
    
    @objc func retune() {
        // TODO: Retune to pending frequency
    }
    
    @objc func findActive() {
        // TODO: Find active frequencies
    }
    
    @objc func openMainApp() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/SignalHive.app"),
                                          configuration: NSWorkspace.OpenConfiguration())
    }
    
    @objc func openSettings() {
        // Open settings window
    }
}

struct MenuHeaderView: View {
    @ObservedObject var model: AppModel
    
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.blue.gradient)
                    .symbolEffect(.pulse.byLayer, options: .repeating)
                Text("SignalHive")
                    .font(.headline.weight(.bold))
                Spacer()
            }
            
            if model.importActive, let progress = model.importProgress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(progress.phase.rawValue.capitalized)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(Int(progress.fraction * 100))%")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(1, max(0, progress.fraction)))
                        .tint(.blue)
                    Text(progress.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let summary = model.lastImportSummary {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Image(systemName: "cylinder")
                        .foregroundStyle(.blue)
                    Text("\(model.stats.licenses) licenses, \(model.stats.frequencies) frequencies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}