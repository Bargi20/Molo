import AppKit
import SwiftUI
import ScreenCaptureKit

/// Una finestra mostrata nell'anteprima, con la sua miniatura.
struct PreviewWindow: Identifiable {
    let id: CGWindowID
    let title: String
    /// Coordinate globali con l'origine in alto a sinistra, come quelle di Accessibilità.
    let frame: CGRect
    var image: CGImage?
    /// Falso per le finestre nella striscia di Stage Manager: lì sono rimpicciolite e non si catturano.
    var onStage = true
}

/// Contenuto del pannello anteprime.
@MainActor
final class WindowPreviewModel: ObservableObject {
    @Published var app: DockApp?
    @Published var windows: [PreviewWindow] = []
    @Published var needsPermission = false
}

/// Pannello sopra il dock: non ruba il focus e sta sopra la barra.
final class PreviewPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Anteprime delle finestre al passaggio del mouse su un'app aperta, come il Dock Preview di altre app.
/// Le miniature richiedono il permesso di Registrazione schermo; portare davanti una singola finestra
/// richiede Accessibilità (senza, si porta davanti l'app intera).
@MainActor
final class WindowPreviewController {
    let model = WindowPreviewModel()
    private let panel = PreviewPanel()
    private let hosting: NSHostingView<WindowPreviewView>
    /// Fornito dal controller del dock: anteprime attive e posizione verticale del pannello.
    var isEnabled: () -> Bool = { true }
    var panelBottomY: () -> CGFloat = { 0 }

    private var anchorX: CGFloat = 0
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var loadID = 0
    private var mouseInPanel = false
    /// Ultima miniatura a grandezza piena di ogni finestra, riusata quando Stage Manager la sposta di lato.
    private var thumbnails: [CGWindowID: CGImage] = [:]
    private var thumbnailOrder: [CGWindowID] = []
    private var cacheTimer: Timer?
    /// Le miniature si fanno al massimo per queste finestre, le più in alto nella pila.
    private static let maxWindows = 6

    var isVisible: Bool { panel.isVisible }

    init() {
        hosting = NSHostingView(rootView: WindowPreviewView(model: model, onSelect: { _ in }, onHover: { _ in },
                                                            onPermission: {}))
        hosting.rootView = WindowPreviewView(
            model: model,
            onSelect: { [weak self] window in self?.select(window) },
            onHover: { [weak self] inside in self?.panelHover(inside) },
            onPermission: { [weak self] in self?.requestPermission() })
        // La finestra la ridimensiona `place()`: con le dimensioni automatiche crescerebbe verso il basso.
        hosting.sizingOptions = []
        panel.contentView = hosting

        // Fotografa le finestre mentre sono al centro: con Stage Manager, appena si cambia app
        // finiscono nella striscia laterale e non si possono più catturare per intero.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated { if let pid { self?.cacheWindows(of: pid) } }
            }
        }
        cacheTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { self?.cacheWindows(of: pid) }
            }
        }
        cacheTimer?.tolerance = 5
    }

    // MARK: Hover

    /// Il puntatore è entrato su un'icona (`item`) o ne è uscito (`nil`). `x` è il centro dell'icona sullo schermo.
    func hover(_ item: DockApp?, x: CGFloat) {
        showWork?.cancel()
        guard let item, item.isRunning, !item.isFolder, item.pid != nil, isEnabled() else {
            scheduleHide()
            return
        }
        hideWork?.cancel()
        anchorX = x
        if panel.isVisible {
            // Da un'icona all'altra con il pannello aperto: si cambia subito, come nel Dock.
            show(item)
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.show(item) }
            }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    /// Chiamato dal poll del mouse: chiude il pannello se il puntatore non è né sul dock né sul pannello.
    func mouseMoved(_ mouse: NSPoint, overDock: Bool) {
        guard panel.isVisible, !overDock, !mouseInPanel else { return }
        // Corridoio tra l'icona e il pannello, per poterci arrivare con il mouse.
        let corridor = NSRect(x: panel.frame.minX, y: panel.frame.minY - 80,
                              width: panel.frame.width, height: panel.frame.height + 80)
        if !corridor.insetBy(dx: -8, dy: -8).contains(mouse) { scheduleHide(after: 0.1) }
    }

    /// Chiude subito, per esempio quando si clicca un'icona o il dock si nasconde.
    func dismiss() {
        showWork?.cancel()
        hideWork?.cancel()
        loadID += 1
        mouseInPanel = false
        panel.orderOut(nil)
        model.app = nil
        model.windows = []
    }

    private func panelHover(_ inside: Bool) {
        mouseInPanel = inside
        if inside { hideWork?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide(after delay: TimeInterval = 0.3) {
        guard panel.isVisible || showWork != nil else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.mouseInPanel else { return }
                self.dismiss()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Contenuto

    private func show(_ item: DockApp) {
        guard let pid = item.pid else { return }
        loadID += 1
        let id = loadID
        model.needsPermission = !CGPreflightScreenCaptureAccess()
        if model.needsPermission {
            model.app = item
            model.windows = []
            place()
            return
        }
        Task { [weak self] in
            let windows = await Self.windows(of: pid)
            guard let self, id == self.loadID else { return }
            // Senza finestre visibili non c'è niente da mostrare.
            guard !windows.isEmpty else { return self.dismiss() }
            self.model.app = item
            self.model.windows = windows.map { window in
                PreviewWindow(id: window.windowID, title: window.title ?? "", frame: window.frame,
                              image: self.thumbnails[window.windowID], onStage: Self.isOnStage(window.frame))
            }
            self.place()
            for window in windows where Self.isOnStage(window.frame) {
                guard let image = await Self.capture(window) else { continue }
                guard id == self.loadID else { return }
                self.store(image, for: window.windowID)
                if let index = self.model.windows.firstIndex(where: { $0.id == window.windowID }) {
                    self.model.windows[index].image = image
                }
            }
        }
    }

    /// Ridimensiona il pannello sul contenuto e lo centra sopra l'icona, dentro lo schermo.
    private func place() {
        guard let screen = NSScreen.screens.first else { return }
        // Si misura una copia fuori dalla finestra: la vista nel pannello non calcola la sua misura.
        let size = NSHostingView(rootView: hosting.rootView).fittingSize
        var x = anchorX - size.width / 2
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: panelBottomY(), width: size.width, height: size.height), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Aggiorna in silenzio le miniature delle finestre al centro dello schermo.
    private func cacheWindows(of pid: pid_t) {
        guard isEnabled(), CGPreflightScreenCaptureAccess(), pid != getpid() else { return }
        Task { [weak self] in
            for window in await Self.windows(of: pid) where Self.isOnStage(window.frame) {
                guard let image = await Self.capture(window) else { continue }
                self?.store(image, for: window.windowID)
            }
        }
    }

    private func store(_ image: CGImage, for id: CGWindowID) {
        if thumbnails.updateValue(image, forKey: id) == nil { thumbnailOrder.append(id) }
        // Basta tenere le ultime finestre viste.
        while thumbnailOrder.count > 80 {
            thumbnails[thumbnailOrder.removeFirst()] = nil
        }
    }

    /// Una finestra è "al centro" se almeno metà sta dentro uno schermo. Quelle nella striscia di
    /// Stage Manager risultano rimpicciolite (circa 170×150) e spesso fuori dallo schermo; sugli schermi
    /// esterni però la striscia sta dentro lo schermo, quindi conta anche la dimensione.
    private static func isOnStage(_ frame: CGRect) -> Bool {
        guard let mainHeight = NSScreen.screens.first?.frame.height, frame.width * frame.height > 0 else { return false }
        let stageManager = UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
        if stageManager && frame.width <= 300 && frame.height <= 300 { return false }
        let visible = NSScreen.screens.reduce(CGFloat(0)) { total, screen in
            // Coordinate dello schermo con l'origine in alto a sinistra, come quelle di ScreenCaptureKit.
            let rect = CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY,
                              width: screen.frame.width, height: screen.frame.height)
            let overlap = rect.intersection(frame)
            return total + (overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        return visible >= frame.width * frame.height * 0.5
    }

    /// Finestre normali e visibili dell'app, nell'ordine in cui sono impilate.
    private static func windows(of pid: pid_t) async -> [SCWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return [] }
        let windows = content.windows.filter { window in
            window.owningApplication?.processID == pid && window.windowLayer == 0
                && window.frame.width >= 80 && window.frame.height >= 60
        }
        return Array(windows.prefix(maxWindows))
    }

    private static func capture(_ window: SCWindow) async -> CGImage? {
        let config = SCStreamConfiguration()
        // Miniatura al doppio della dimensione mostrata, per gli schermi Retina.
        let fit = min(2 * WindowPreviewView.thumbWidth / window.frame.width,
                      2 * WindowPreviewView.thumbHeight / window.frame.height, 2)
        config.width = max(1, Int(window.frame.width * fit))
        config.height = max(1, Int(window.frame.height * fit))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Debug: salva un'immagine del pannello.
    func snapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: Azioni

    private func select(_ window: PreviewWindow) {
        guard let app = model.app, let pid = app.pid else { return }
        raise(window, pid: pid)
        // Porta davanti l'app: con la finestra appena alzata, è quella che compare in primo piano.
        if let url = app.url ?? NSRunningApplication(processIdentifier: pid)?.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        dismiss()
    }

    /// Alza la singola finestra con Accessibilità. La prima volta chiede il permesso.
    private func raise(_ target: PreviewWindow, pid: pid_t) {
        let defaults = UserDefaults.standard
        if !AXIsProcessTrusted() {
            if !defaults.bool(forKey: "askedAccessibility") {
                defaults.set(true, forKey: "askedAccessibility")
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return
        }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        // Si cerca la finestra con la stessa posizione e dimensione (e, a parità, lo stesso titolo).
        var match = windows.min { a, b in
            Self.distance(a, to: target) < Self.distance(b, to: target)
        }
        if let found = match, Self.distance(found, to: target) >= 40 {
            // Con Stage Manager la posizione di una finestra di lato non corrisponde: si usa il titolo.
            let byTitle = windows.filter { Self.title(of: $0) == target.title }
            match = byTitle.count == 1 ? byTitle.first : nil
        }
        guard let match else { return }
        AXUIElementSetAttributeValue(match, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func title(of element: AXUIElement) -> String? {
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    private static func distance(_ element: AXUIElement, to target: PreviewWindow) -> CGFloat {
        guard let frame = axFrame(element) else { return .infinity }
        var d = abs(frame.minX - target.frame.minX) + abs(frame.minY - target.frame.minY)
            + abs(frame.width - target.frame.width) + abs(frame.height - target.frame.height)
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
           (title as? String) != target.title {
            d += 20
        }
        return d
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private func requestPermission() {
        // La prima volta macOS mostra la richiesta; dopo bisogna attivarlo a mano nelle Impostazioni.
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        dismiss()
    }
}

// MARK: - Vista

struct WindowPreviewView: View {
    @ObservedObject var model: WindowPreviewModel
    let onSelect: (PreviewWindow) -> Void
    let onHover: (Bool) -> Void
    let onPermission: () -> Void

    static let thumbWidth: CGFloat = 190
    static let thumbHeight: CGFloat = 120

    var body: some View {
        Group {
            if model.needsPermission {
                VStack(spacing: 8) {
                    Text("Anteprime delle finestre")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Per vederle, consenti a Molo la Registrazione schermo.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 210)
                    Button("Consenti…", action: onPermission)
                        .controlSize(.small)
                }
                .padding(14)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(model.windows) { window in
                        PreviewThumbnail(window: window, appName: model.app?.name ?? "", appIcon: model.app?.icon)
                            .onTapGesture { onSelect(window) }
                    }
                }
                .padding(10)
            }
        }
        .background(
            VisualEffectBackground(cornerRadius: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
        )
        .padding(12)
        .onHover(perform: onHover)
        .fixedSize()
    }
}

private struct PreviewThumbnail: View {
    let window: PreviewWindow
    let appName: String
    let appIcon: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if let image = window.image {
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .overlay {
                            if window.onStage {
                                ProgressView().controlSize(.small)
                            } else if let appIcon {
                                // Mai vista al centro: niente miniatura, solo l'icona dell'app.
                                Image(nsImage: appIcon).resizable().frame(width: 56, height: 56)
                            }
                        }
                }
            }
            .frame(width: WindowPreviewView.thumbWidth, height: WindowPreviewView.thumbHeight)
            Text(window.title.isEmpty ? appName : window.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: WindowPreviewView.thumbWidth)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
