import AppKit
import SwiftUI

/// Da che parte del Dock di Apple sta una pillola di widget.
enum DockSide {
    case left, right

    /// Ora e Spotify a sinistra, le info di sistema a destra.
    var widgets: Set<DockWidget> {
        switch self {
        case .left: return [.clock, .spotify]
        case .right: return [.cpu, .ram, .battery, .devices, .network, .disk]
        }
    }
}

/// Altezza dei riquadri, presa dal Dock di Apple: le pillole hanno la sua stessa altezza.
@MainActor
final class BesideLayout: ObservableObject {
    @Published var dockHeight: CGFloat = 48
}

/// Contenuto di una pillola: i widget del suo lato, appoggiati in basso verso il bordo dello schermo.
struct BesideWidgetsView: View {
    @ObservedObject var system: SystemMonitor
    @ObservedObject var spotify: SpotifyMonitor
    @ObservedObject var devices: DeviceBatteryMonitor
    @ObservedObject var settings: DockSettings
    @ObservedObject var layout: BesideLayout
    let side: DockSide
    let onSize: (CGSize) -> Void

    private var enabled: Set<DockWidget> { settings.enabledWidgets.intersection(side.widgets) }

    var body: some View {
        Group {
            if settings.showWidgets && !enabled.isEmpty {
                SystemWidgets(system: system, spotify: spotify, devices: devices,
                              enabled: enabled, height: max(24, layout.dockHeight - 6))
                    .environment(\.widgetWide, true)
                    .padding(.horizontal, 3)
                    .frame(height: layout.dockHeight)
                    .modifier(DockGlass(cornerRadius: 13))
                    .contextMenu { DockMenu(settings: settings) }
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: side == .left ? .bottomLeading : .bottomTrailing)
    }
}

/// Lo stesso vetro del Dock di Apple (Liquid Glass da macOS 26), o lo sfondo sfocato prima.
private struct DockGlass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            // Come il Dock: vetro trasparente (non smerigliato) con un filo di luce sul bordo.
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .glassEffect(.clear.tint(Color.black.opacity(0.08)), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
        } else {
            content.background(
                VisualEffectBackground(cornerRadius: cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
        }
    }
}

/// Modalità "accanto al Dock di Apple": due pillole di widget ai bordi dello schermo,
/// alla stessa altezza del Dock di sistema.
@MainActor
final class BesideDockController {
    private let panels: [DockSide: DockPanel] = [.left: DockPanel(), .right: DockPanel()]
    private var sizes: [DockSide: CGSize] = [:]
    private let layout = BesideLayout()
    private var dockFrame: CGRect?
    private var timer: Timer?
    private(set) var isActive = false

    /// Spazio trasparente sopra la pillola: senza, il bordo in alto viene tagliato dalla finestra.
    private static let headroom: CGFloat = 4
    private static let sideRoom: CGFloat = 0

    /// Lo sfondo visibile del Dock di Apple sta qualche punto più in basso del riquadro
    /// che dà l'Accessibilità (misurato su macOS 26 e successivi).
    private static let visibleDockDrop: CGFloat = 5

    /// Impostato dal controller: l'app davanti è a schermo intero.
    var isFullScreen: () -> Bool = { false }

    func install(system: SystemMonitor, spotify: SpotifyMonitor, devices: DeviceBatteryMonitor, settings: DockSettings) {
        for (side, panel) in panels {
            let view = BesideWidgetsView(system: system, spotify: spotify, devices: devices,
                                         settings: settings, layout: layout, side: side) { [weak self] size in
                self?.sizes[side] = size
                self?.update()
            }
            let hosting = NSHostingView(rootView: view)
            hosting.sizingOptions = []
            panel.contentView = hosting
            panel.ignoresMouseEvents = true
        }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        timer?.invalidate()
        timer = nil
        if active {
            // Il Dock cambia larghezza quando si aprono o chiudono app: si ricontrolla due volte al secondo.
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            update()
        } else {
            panels.values.forEach { $0.orderOut(nil) }
        }
    }

    /// Le pillole ricevono i click solo quando il mouse è sopra di loro.
    func mouseMoved(_ mouse: NSPoint) {
        for (side, panel) in panels where panel.isVisible {
            let over = pillRect(side).insetBy(dx: -2, dy: -2).contains(mouse)
            if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        }
    }

    /// Le pillole sono visibili e il mouse è vicino: serve il poll veloce.
    func isNear(_ mouse: NSPoint) -> Bool {
        panels.contains { side, panel in panel.isVisible && pillRect(side).insetBy(dx: -40, dy: -40).contains(mouse) }
    }

    private func pillRect(_ side: DockSide) -> CGRect {
        let frame = panels[side]!.frame
        let size = sizes[side] ?? .zero
        let x = side == .left ? frame.minX : frame.maxX - size.width
        return CGRect(x: x, y: frame.minY, width: size.width, height: size.height)
    }

    private func update() {
        guard isActive else { return }
        dockFrame = Self.appleDockFrame()
        guard let dock = dockFrame, !isFullScreen() else {
            panels.values.forEach { $0.orderOut(nil) }
            return
        }
        if abs(layout.dockHeight - dock.height) > 0.5 { layout.dockHeight = dock.height }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: dock.midX, y: dock.midY)) })
        else { return }
        let visibleMinY = dock.minY - Self.visibleDockDrop
        // Dal bordo laterale la stessa distanza che il Dock ha dal bordo in basso.
        let margin = max(4, visibleMinY - screen.frame.minY)

        for (side, panel) in panels {
            guard let size = sizes[side], size.width > 0 else {
                panel.orderOut(nil)
                continue
            }
            let width = size.width + Self.sideRoom
            let height = size.height + Self.headroom
            // Stessa base e stessa altezza del Dock di Apple; lo spazio per le etichette è verso il centro.
            let y = visibleMinY
            let x = side == .left ? screen.frame.minX + margin : screen.frame.maxX - margin - width
            let frame = NSRect(x: x, y: y, width: width, height: height).integral
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    /// Riquadro del Dock di Apple in coordinate Cocoa, o nil se è nascosto o non a lato del bordo inferiore.
    static func appleDockFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success else { return nil }
        for child in (children as? [AXUIElement]) ?? [] {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXListRole as String else { continue }
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &size) == .success else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            // Da coordinate con origine in alto (Accessibilità) a coordinate Cocoa.
            let frame = CGRect(x: p.x, y: mainHeight - p.y - s.height, width: s.width, height: s.height)
            // Solo il Dock in basso e visibile: quando si nasconde finisce fuori da tutti gli schermi.
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
            guard let screen, s.width > s.height, frame.minY < screen.frame.minY + 40 else { return nil }
            return frame
        }
        return nil
    }
}
