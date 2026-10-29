import AppKit
import SwiftUI
import Combine

/// Finestra del dock: senza bordi, trasparente, al livello del Dock, su tutti gli Spazi.
/// `.transient`: Mission Control la nasconde, come fa con il Dock di Apple.
final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum DockMetrics {
    /// Spazio trasparente sopra la barra per etichette e ingrandimento delle icone.
    static func headroom(iconSize: CGFloat, magnification: Double) -> CGFloat {
        max(48, iconSize * CGFloat(magnification - 1) + 40)
    }
    /// Margine minimo ai lati della barra.
    static let sideMargin: CGFloat = 24
    /// Distanza della barra dal bordo inferiore dello schermo.
    static let bottomGap: CGFloat = 6
}

@MainActor
final class DockController {
    let settings = DockSettings()
    let apps = AppsModel()
    let system = SystemMonitor()
    let spotify = SpotifyMonitor()
    let devices = DeviceBatteryMonitor()
    let hover = DockHover()
    let previews = WindowPreviewController()
    let beside = BesideDockController()

    private let panel = DockPanel()
    private var barSize = CGSize(width: 600, height: 70)
    private var isHidden = false
    private var hideDeadline: Date?
    /// L'app davanti è a schermo intero: il dock si nasconde e riappare dal bordo in basso.
    private var fullScreen = false
    private var menuOpen = false
    private var mouseTimer: Timer?
    private var fastTracking = true
    private var fitWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        let root = DockRootView(apps: apps, system: system, spotify: spotify, devices: devices,
                                settings: settings, hover: hover) { [weak self] size in
            self?.barSizeChanged(size)
        }
        hover.previews = previews
        hover.screenX = { [weak self] x in (self?.panel.frame.minX ?? 0) + x }
        previews.isEnabled = { [weak self] in self?.settings.showWindowPreviews ?? false }
        previews.panelBottomY = { [weak self] in
            guard let self else { return 0 }
            // Sopra l'icona ingrandita e la sua etichetta.
            let magnified = self.settings.effectiveIconSize * CGFloat(self.settings.magnification - 1)
            return self.barRect.maxY + magnified + 18
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.ignoresMouseEvents = true

        layout(animated: false)
        beside.install(system: system, spotify: spotify, devices: devices, settings: settings)
        beside.isFullScreen = { [weak self] in self?.fullScreen ?? false }
        applyMode()
        settings.$besideAppleDock
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] beside in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Il Dock di Apple serve visibile solo nella modalità accanto.
                    if beside { self.settings.restoreAppleDock() } else { self.settings.hideAppleDock() }
                    self.applyMode()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fitToScreen()
                self?.layout(animated: false)
            }
        }
        settings.$magnification
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.layout(animated: false) } }
            .store(in: &cancellables)

        settings.openSettings = { [weak self] in self?.showSettings() }

        // Se l'utente cambia dimensione, si riparte da capo con l'adattamento.
        settings.$iconSize
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.settings.fitScale = 1 } }
            .store(in: &cancellables)

        // Debug: `Molo --spotify-test file.txt` prova a comandare Spotify, scrive l'esito ed esce.
        if let i = CommandLine.arguments.firstIndex(of: "--spotify-test"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            spotify.diagnose { report in
                try? report.write(toFile: path, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }

        // Debug: `Molo --preview-snapshot file.png [NomeApp]` apre l'anteprima di un'app aperta, la salva ed esce.
        if let i = CommandLine.arguments.firstIndex(of: "--preview-snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let name = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let item = (self.apps.pinned + self.apps.running)
                        .first { $0.isRunning && (name == nil || $0.name == name) }
                    self.previews.hover(item, x: self.panel.frame.midX)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                MainActor.assumeIsolated {
                    self?.previews.snapshot(to: path)
                    NSApp.terminate(nil)
                }
            }
        }

        // Debug: `Molo --snapshot file.png` salva un'immagine della finestra ed esce.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            if let t = CommandLine.arguments.firstIndex(of: "--settings"), t + 1 < CommandLine.arguments.count {
                SettingsView.initialTab = Int(CommandLine.arguments[t + 1]) ?? 0
                showSettings()
            }
            // `--pointer X` simula il mouse sopra la barra, per vedere l'ingrandimento.
            if let p = CommandLine.arguments.firstIndex(of: "--pointer"), p + 1 < CommandLine.arguments.count,
               let x = Double(CommandLine.arguments[p + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.mouseTimer?.invalidate()
                        self?.hover.pointerX = x
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                MainActor.assumeIsolated {
                    self?.saveSnapshot(to: path)
                    NSApp.terminate(nil)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = false }
        }

        settings.$autoHide
            .dropFirst()
            .sink { [weak self] autoHide in
                guard let self, !autoHide, !self.fullScreen, self.isHidden else { return }
                self.setHidden(false)
            }
            .store(in: &cancellables)

        // Schermo intero: si ricontrolla quando cambia lo Spazio o l'app davanti
        // (l'animazione di macOS dura circa mezzo secondo, quindi si guarda anche dopo).
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateFullScreen()
                    for delay in [0.4, 1.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            MainActor.assumeIsolated { self?.updateFullScreen() }
                        }
                    }
                }
            }
        }

        // Poll del mouse: decide se la finestra deve ricevere click e gestisce l'auto-nascondi.
        scheduleMouseTimer(fast: true)

        // Debug: `Molo --record cartella` salva i fotogrammi del puntatore che scorre sulla barra.
        if let i = CommandLine.arguments.firstIndex(of: "--record"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            mouseTimer?.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.recordSweep(to: dir) }
            }
        }
    }

    /// Fa scorrere un puntatore finto da un capo all'altro della barra e salva un PNG per fotogramma.
    private func recordSweep(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let left = (panel.frame.width - barSize.width) / 2
        let positions: [CGFloat?] = [nil, nil, nil, nil, nil, nil]
            + (0..<150).map { step in left - 10 + (barSize.width + 20) * CGFloat(step) / 149 }
            + Array(repeating: nil, count: 12)
        var index = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if index > 0 {
                    self.saveSnapshot(to: dir + String(format: "/frame-%03d.png", index - 1))
                }
                guard index < positions.count else {
                    timer.invalidate()
                    NSApp.terminate(nil)
                    return
                }
                self.hover.pointerX = positions[index]
                index += 1
            }
        }
    }

    private var screen: NSScreen? { NSScreen.screens.first }

    private var settingsWindow: NSWindow?

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = L("Impostazioni di Molo")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, apps: apps))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func saveSnapshot(to path: String) {
        // Con la finestra Impostazioni aperta, fotografa quella al posto del dock.
        guard let view = settingsWindow?.contentView ?? panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func barSizeChanged(_ size: CGSize) {
        // Durante l'ingrandimento la barra si allarga: conta solo la misura a riposo.
        guard hover.pointerX == nil, size != barSize, size.width > 0 else { return }
        barSize = size
        fitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fitToScreen() }
        }
        fitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Larghezza in più che l'onda di ingrandimento può aggiungere alla barra.
    private var magnificationExtra: CGFloat {
        settings.effectiveIconSize * CGFloat(settings.magnification - 1) * 1.7
    }

    /// Rimpicciolisce le icone se la barra è più larga dello schermo, e le ingrandisce di nuovo quando c'è spazio.
    private func fitToScreen() {
        guard let screen else { return }
        let available = screen.frame.width - DockMetrics.sideMargin * 2 - magnificationExtra
        var scale = settings.fitScale
        if barSize.width > available {
            scale *= available / barSize.width
        } else if scale < 1, barSize.width < available * 0.9 {
            scale = min(1, scale * available * 0.97 / barSize.width)
        }
        scale = max(0.5, scale)
        if abs(scale - settings.fitScale) > 0.005 {
            settings.fitScale = scale
        }
    }

    private func targetFrame(hidden: Bool) -> NSRect {
        guard let screen else { return panel.frame }
        // La finestra occupa tutta la larghezza: così la barra può allargarsi senza ridimensionarla.
        let width = screen.frame.width
        let height = barSize.height + DockMetrics.headroom(iconSize: settings.effectiveIconSize,
                                                           magnification: settings.magnification)
        let x = screen.frame.minX
        let y = hidden
            ? screen.frame.minY - barSize.height - DockMetrics.bottomGap
            : screen.frame.minY + DockMetrics.bottomGap
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func layout(animated: Bool) {
        let frame = targetFrame(hidden: isHidden)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        if hidden { previews.dismiss() }
        isHidden = hidden
        layout(animated: true)
    }

    /// Mostra il dock di Molo oppure le pillole accanto al Dock di Apple.
    private func applyMode() {
        let besideMode = settings.besideAppleDock
        if besideMode {
            previews.dismiss()
            hover.pointerX = nil
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
        beside.setActive(besideMode)
    }

    private func updateFullScreen() {
        guard let screen else { return }
        let now = Self.hasFullScreenWindow(on: screen)
        guard now != fullScreen else { return }
        fullScreen = now
        hideDeadline = nil
        if now {
            setHidden(true)
        } else if !settings.autoHide {
            setHidden(false)
        }
    }

    /// C'è una finestra normale di un'altra app che copre lo schermo intero, barra dei menu compresa.
    private static func hasFullScreenWindow(on screen: NSScreen) -> Bool {
        guard let mainHeight = NSScreen.screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        // Coordinate di CGWindowList: origine in alto a sinistra dello schermo principale.
        let f = screen.frame
        let target = CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
        let me = ProcessInfo.processInfo.processIdentifier
        return list.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return abs(bounds.minX - target.minX) < 1 && abs(bounds.minY - target.minY) < 1
                && abs(bounds.width - target.width) < 1 && abs(bounds.height - target.height) < 1
        }
    }

    /// Rettangolo della barra visibile, in coordinate schermo.
    private var barRect: NSRect {
        let frame = targetFrame(hidden: false)
        return NSRect(x: frame.midX - barSize.width / 2, y: frame.minY,
                      width: barSize.width, height: barSize.height)
    }

    /// 60 volte al secondo vicino al dock, 10 quando il puntatore è lontano: consuma meno batteria.
    private func scheduleMouseTimer(fast: Bool) {
        mouseTimer?.invalidate()
        let timer = Timer(timeInterval: fast ? 1.0 / 60 : 1.0 / 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trackMouse()
                let fast = self.needsFastTracking
                if fast != self.fastTracking { self.scheduleMouseTimer(fast: fast) }
            }
        }
        timer.tolerance = fast ? 0 : 0.02
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
        fastTracking = fast
    }

    /// Il puntatore è nella fascia in basso dello schermo, o c'è un'animazione del dock in corso.
    private var needsFastTracking: Bool {
        if beside.isActive { return beside.isNear(NSEvent.mouseLocation) }
        if hover.pointerX != nil || hideDeadline != nil { return true }
        guard let screen else { return true }
        return NSEvent.mouseLocation.y <= max(barRect.maxY, screen.frame.minY) + 150
    }

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        if beside.isActive {
            beside.mouseMoved(mouse)
            return
        }
        var area = barRect.insetBy(dx: -2, dy: -2)
        if hover.pointerX != nil {
            // Mentre le icone sono ingrandite, l'area attiva cresce con loro.
            area = area.insetBy(dx: -magnificationExtra / 2, dy: 0)
            area.size.height += settings.effectiveIconSize * CGFloat(settings.magnification - 1)
        }
        let overBar = !isHidden && area.contains(mouse)
        if panel.ignoresMouseEvents == overBar {
            panel.ignoresMouseEvents = !overBar
        }
        previews.mouseMoved(mouse, overDock: overBar)

        let pointer = overBar ? mouse.x - panel.frame.minX : nil
        if pointer == nil || hover.pointerX == nil || abs(pointer! - hover.pointerX!) >= 0.5 {
            if pointer != hover.pointerX { hover.pointerX = pointer }
        }

        guard settings.autoHide || fullScreen, let screen else { return }
        if isHidden {
            let atBottomEdge = mouse.y <= screen.frame.minY + 1
                && mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
            if atBottomEdge { setHidden(false) }
        } else {
            let near = barRect.insetBy(dx: -20, dy: -30).contains(mouse)
            if near || menuOpen || previews.isVisible || NSEvent.pressedMouseButtons != 0 {
                hideDeadline = nil
            } else if let deadline = hideDeadline {
                if Date() >= deadline {
                    hideDeadline = nil
                    setHidden(true)
                }
            } else {
                hideDeadline = Date().addingTimeInterval(0.6)
            }
        }
    }
}
