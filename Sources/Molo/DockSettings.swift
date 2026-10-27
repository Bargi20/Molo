import AppKit
import ServiceManagement

/// I riquadri di info di sistema che si possono mostrare nel dock.
enum DockWidget: String, CaseIterable, Identifiable {
    case clock, spotify, cpu, ram, battery, devices, network, disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: return "Ora e data"
        case .spotify: return "Spotify (brano in riproduzione)"
        case .devices: return "Batterie di cuffie e dispositivi"
        case .cpu: return "CPU"
        case .ram: return "Memoria (RAM)"
        case .battery: return "Batteria"
        case .network: return "Rete"
        case .disk: return "Disco"
        }
    }

    var symbol: String {
        switch self {
        case .clock: return "clock"
        case .spotify: return "music.note"
        case .devices: return "airpods"
        case .cpu: return "cpu"
        case .ram: return "memorychip"
        case .battery: return "battery.75percent"
        case .network: return "arrow.up.arrow.down"
        case .disk: return "internaldrive"
        }
    }
}

/// Preferenze di Molo, salvate in UserDefaults.
@MainActor
final class DockSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var autoHide: Bool {
        didSet { defaults.set(autoHide, forKey: "autoHide") }
    }
    @Published var showWidgets: Bool {
        didSet { defaults.set(showWidgets, forKey: "showWidgets") }
    }
    @Published var iconSize: Double {
        didSet { defaults.set(iconSize, forKey: "iconSize") }
    }
    /// Quanto si ingrandisce un'icona sotto il mouse (1 = niente).
    @Published var magnification: Double {
        didSet { defaults.set(magnification, forKey: "magnification") }
    }
    @Published var enabledWidgets: Set<DockWidget> {
        didSet { defaults.set(enabledWidgets.map(\.rawValue), forKey: "enabledWidgets") }
    }
    @Published var showRunningApps: Bool {
        didSet { defaults.set(showRunningApps, forKey: "showRunningApps") }
    }
    @Published var showTrash: Bool {
        didSet { defaults.set(showTrash, forKey: "showTrash") }
    }
    /// Riduzione automatica quando la barra non sta nello schermo (1 = nessuna).
    @Published var fitScale: Double = 1

    var effectiveIconSize: CGFloat { CGFloat(iconSize * fitScale) }

    /// Impostato dal controller: apre la finestra Impostazioni.
    var openSettings: () -> Void = {}

    init() {
        defaults.register(defaults: [
            "autoHide": false,
            "showWidgets": true,
            "iconSize": 36.0,
            "magnification": 1.22,
            "enabledWidgets": DockWidget.allCases.map(\.rawValue),
            "showRunningApps": true,
            "showTrash": true,
        ])
        autoHide = defaults.bool(forKey: "autoHide")
        showWidgets = defaults.bool(forKey: "showWidgets")
        iconSize = defaults.double(forKey: "iconSize")
        magnification = defaults.double(forKey: "magnification")
        enabledWidgets = Set((defaults.stringArray(forKey: "enabledWidgets") ?? []).compactMap(DockWidget.init))
        showRunningApps = defaults.bool(forKey: "showRunningApps")
        showTrash = defaults.bool(forKey: "showTrash")
    }

    func isEnabled(_ widget: DockWidget) -> Bool { enabledWidgets.contains(widget) }

    func setWidget(_ widget: DockWidget, enabled: Bool) {
        if enabled { enabledWidgets.insert(widget) } else { enabledWidgets.remove(widget) }
    }

    // MARK: Avvio al login

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Molo: avvio al login non modificabile: \(error)")
        }
        objectWillChange.send()
    }

    // MARK: Dock di Apple

    var appleDockHidden: Bool {
        defaults.bool(forKey: "appleDockHidden")
    }

    /// Nasconde il Dock di Apple: autohide con un ritardo enorme, così non ricompare mai.
    func hideAppleDock() {
        guard !appleDockHidden else { return }
        let dock = UserDefaults(suiteName: "com.apple.dock")
        defaults.set(dock?.bool(forKey: "autohide") ?? false, forKey: "appleDockPreviousAutohide")
        runShell("""
        defaults write com.apple.dock autohide -bool true && \
        defaults write com.apple.dock autohide-delay -float 1000 && \
        killall Dock
        """)
        defaults.set(true, forKey: "appleDockHidden")
        objectWillChange.send()
    }

    func restoreAppleDock() {
        let previous = defaults.bool(forKey: "appleDockPreviousAutohide")
        runShell("""
        defaults delete com.apple.dock autohide-delay 2>/dev/null; \
        defaults write com.apple.dock autohide -bool \(previous) && \
        killall Dock
        """)
        defaults.set(false, forKey: "appleDockHidden")
        objectWillChange.send()
    }

    private func runShell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
        process.waitUntilExit()
    }
}
