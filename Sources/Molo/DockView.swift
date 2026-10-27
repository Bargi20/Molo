import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Posizione del puntatore sopra il dock (coordinate della finestra), aggiornata dal controller.
@MainActor
final class DockHover: ObservableObject {
    @Published var pointerX: CGFloat?
}

/// Contenuto della finestra: spazio trasparente in alto, barra in basso al centro.
struct DockRootView: View {
    @ObservedObject var apps: AppsModel
    @ObservedObject var system: SystemMonitor
    @ObservedObject var spotify: SpotifyMonitor
    @ObservedObject var devices: DeviceBatteryMonitor
    @ObservedObject var settings: DockSettings
    @ObservedObject var hover: DockHover
    let onBarSize: (CGSize) -> Void

    var body: some View {
        DockBar(apps: apps, system: system, spotify: spotify, devices: devices, settings: settings, hover: hover)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onBarSize($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

struct DockBar: View {
    @ObservedObject var apps: AppsModel
    @ObservedObject var system: SystemMonitor
    @ObservedObject var spotify: SpotifyMonitor
    @ObservedObject var devices: DeviceBatteryMonitor
    @ObservedObject var settings: DockSettings
    @ObservedObject var hover: DockHover
    @State private var dropTargeted = false
    /// Bordo sinistro del gruppo di icone a riposo: la base per calcolare l'onda.
    @State private var groupBaseMinX: CGFloat = 0

    private var iconSize: CGFloat { settings.effectiveIconSize }
    private var iconPadding: CGFloat { iconSize * 0.03 }
    private var unit: CGFloat { iconSize + iconPadding * 2 }
    private static let separatorPadding: CGFloat = 6

    var body: some View {
        let wave = computeWave()
        HStack(alignment: .center, spacing: 8) {
            if settings.showWidgets && !settings.enabledWidgets.isEmpty {
                SystemWidgets(system: system, spotify: spotify, devices: devices,
                              enabled: settings.enabledWidgets, height: iconSize + 4)
                DockSeparator(height: iconSize)
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(apps.pinned) { item in
                    AppIconView(item: item, apps: apps, size: iconSize, padding: iconPadding,
                                scale: wave.scales[item.id] ?? 1)
                        .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
                }
                if settings.showRunningApps && !apps.running.isEmpty {
                    DockSeparator(height: iconSize, padding: Self.separatorPadding)
                        .padding(.bottom, 7)
                    ForEach(apps.running) { item in
                        AppIconView(item: item, apps: apps, size: iconSize, padding: iconPadding,
                                    scale: wave.scales[item.id] ?? 1)
                            .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
                    }
                }
                if settings.showTrash {
                    DockSeparator(height: iconSize, padding: Self.separatorPadding)
                        .padding(.bottom, 7)
                    TrashView(size: iconSize, padding: iconPadding, scale: wave.scales["trash"] ?? 1)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { minX in
                if hover.pointerX == nil { groupBaseMinX = minX }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .padding(.bottom, 3)
        .background(
            VisualEffectBackground(cornerRadius: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(dropTargeted ? 0.6 : 0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        )
        .offset(x: wave.offset)
        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.82), value: hover.pointerX)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: apps.pinned.map(\.id) + apps.running.map(\.id))
        // Trascina un'app o una cartella dal Finder sulla barra per fissarla.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { urls in urls.forEach(apps.pin(url:)) }
            return true
        }
        .contextMenu { DockMenu(settings: settings) }
    }

    private struct Wave {
        var scales: [String: CGFloat] = [:]
        var offset: CGFloat = 0
    }

    /// Ingrandimento "a onda" come il Dock di Apple: le icone vicine al puntatore crescono con una curva
    /// a coseno, e la barra si sposta così che il punto sotto il puntatore resti fermo.
    private func computeWave() -> Wave {
        let magnification = CGFloat(settings.magnification)
        guard let pointer = hover.pointerX, magnification > 1.01 else { return Wave() }

        var centers: [(String, CGFloat)] = []
        var position: CGFloat = 0
        let separatorWidth = 1 + Self.separatorPadding * 2
        for item in apps.pinned {
            centers.append((item.id, position + unit / 2)); position += unit
        }
        if settings.showRunningApps && !apps.running.isEmpty {
            position += separatorWidth
            for item in apps.running {
                centers.append((item.id, position + unit / 2)); position += unit
            }
        }
        if settings.showTrash {
            position += separatorWidth
            centers.append(("trash", position + unit / 2)); position += unit
        }

        let local = pointer - groupBaseMinX
        guard local > -unit / 2, local < position + unit / 2 else { return Wave() }

        let radius = unit * 2.6
        var wave = Wave()
        var extra: CGFloat = 0
        var extraLeft: CGFloat = 0
        for (id, center) in centers {
            let distance = abs(local - center)
            let falloff = distance < radius ? (cos(.pi * distance / radius) + 1) / 2 : 0
            let scale = 1 + (magnification - 1) * falloff
            wave.scales[id] = scale
            let grow = iconSize * (scale - 1)
            extra += grow
            extraLeft += grow * min(1, max(0, (local - (center - unit / 2)) / unit))
        }
        wave.offset = extra / 2 - extraLeft
        return wave
    }
}

struct DockMenu: View {
    @ObservedObject var settings: DockSettings

    var body: some View {
        Button("Impostazioni…") { settings.openSettings() }
        Divider()
        Toggle("Nascondi automaticamente", isOn: $settings.autoHide)
        Toggle("Mostra info di sistema", isOn: $settings.showWidgets)
        Menu("Dimensione icone") {
            ForEach([28.0, 32.0, 36.0, 40.0, 48.0, 56.0], id: \.self) { size in
                Button {
                    settings.iconSize = size
                } label: {
                    if settings.iconSize == size {
                        Label("\(Int(size)) pt", systemImage: "checkmark")
                    } else {
                        Text("\(Int(size)) pt")
                    }
                }
            }
        }
        Divider()
        if settings.appleDockHidden {
            Button("Ripristina il Dock di Apple") { settings.restoreAppleDock() }
        } else {
            Button("Nascondi il Dock di Apple") { settings.hideAppleDock() }
        }
        Button(settings.launchAtLogin ? "Non aprire al login" : "Apri al login") {
            settings.toggleLaunchAtLogin()
        }
        Divider()
        Button("Esci da Molo") { NSApp.terminate(nil) }
    }
}

struct DockSeparator: View {
    let height: CGFloat
    var padding: CGFloat = 2
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.22))
            .frame(width: 1, height: height * 0.8)
            .padding(.horizontal, padding)
    }
}

// MARK: - Icone delle app

/// Altezza della cella di un'icona a riposo: icona + pallino. Le icone ingrandite sbordano verso l'alto.
private func cellHeight(_ size: CGFloat) -> CGFloat { size + 7 }

struct AppIconView: View {
    let item: DockApp
    @ObservedObject var apps: AppsModel
    let size: CGFloat
    let padding: CGFloat
    let scale: CGFloat

    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var pressed = false

    private var isLaunching: Bool {
        item.bundleID.map(apps.launching.contains) ?? false
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size * scale, height: size * scale)
                .brightness(pressed ? -0.3 : (dropTargeted ? 0.15 : 0))
                .scaleEffect(dropTargeted ? 1.12 : 1, anchor: .bottom)
                .keyframeAnimator(initialValue: CGFloat(0), repeating: isLaunching) { content, y in
                    content.offset(y: y)
                } keyframes: { _ in
                    // Rimbalzo d'avvio: su veloce, giù con un piccolo assestamento.
                    KeyframeTrack {
                        CubicKeyframe(-size * 0.55, duration: 0.28)
                        CubicKeyframe(0, duration: 0.26)
                        SpringKeyframe(0, duration: 0.18, spring: .bouncy)
                    }
                }
            Circle()
                .fill(Color.primary.opacity(item.isRunning ? 0.75 : 0))
                .frame(width: 4, height: 4)
                .scaleEffect(item.isRunning ? 1 : 0.2)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: item.isRunning)
        }
        .frame(width: size * scale + padding * 2, height: cellHeight(size), alignment: .bottom)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if hovering {
                HoverBubble(text: item.name)
                    .offset(y: bubbleOffset(size: size, scale: scale))
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: dropTargeted)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .onHover { hovering = $0 }
        .onTapGesture {
            pressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pressed = false }
            apps.open(item)
        }
        .onDrag {
            apps.dragging = item.isPinned ? item : nil
            return NSItemProvider(object: item.id as NSString)
        }
        .onDrop(of: [.fileURL, .text], isTargeted: $dropTargeted) { providers in
            if let dragged = apps.dragging, item.isPinned {
                apps.move(dragged, before: item)
                apps.dragging = nil
                return true
            }
            if item.isFolder { return false }
            loadURLs(providers) { urls in
                if urls.allSatisfy({ $0.pathExtension == "app" }) {
                    urls.forEach(apps.pin(url:))
                } else {
                    apps.open(files: urls, with: item)
                }
            }
            return true
        }
        .contextMenu {
            if item.isPinned {
                Button("Rimuovi dal Dock") { apps.unpin(item) }
            } else {
                Button("Mantieni nel Dock") { apps.pin(item) }
            }
            Button("Mostra nel Finder") { apps.revealInFinder(item) }
            if item.isRunning {
                Divider()
                Button("Nascondi") { apps.hide(item) }
                Button("Esci") { apps.quit(item) }
                Button("Uscita forzata") { apps.forceQuit(item) }
            }
        }
    }
}

struct TrashView: View {
    let size: CGFloat
    let padding: CGFloat
    let scale: CGFloat
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var pressed = false

    private var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSImage(named: NSImage.trashEmptyName) ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: size * scale, height: size * scale)
                .brightness(pressed ? -0.3 : 0)
                .scaleEffect(dropTargeted ? 1.15 : 1, anchor: .bottom)
                .rotationEffect(.degrees(dropTargeted ? -6 : 0), anchor: .bottom)
            Color.clear.frame(width: 4, height: 4)
        }
        .frame(width: size * scale + padding * 2, height: cellHeight(size), alignment: .bottom)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if hovering {
                HoverBubble(text: "Cestino")
                    .offset(y: bubbleOffset(size: size, scale: scale))
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.45), value: dropTargeted)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .onHover { hovering = $0 }
        .onTapGesture {
            pressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pressed = false }
            NSWorkspace.shared.open(trashURL)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { urls in
                for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            }
            return true
        }
    }
}

// MARK: - Componenti comuni

/// Posizione dell'etichetta sopra un'icona, tenendo conto dell'ingrandimento attuale.
func bubbleOffset(size: CGFloat, scale: CGFloat) -> CGFloat {
    -(size * (scale - 1) + 30)
}

struct HoverBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            )
            .allowsHitTesting(false)
    }
}

/// Sfondo sfocato "dietro la finestra", come il Dock vero.
struct VisualEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Estrae gli URL dei file trascinati e li consegna sul main thread.
func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                lock.lock(); urls.append(url); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated {
            if !urls.isEmpty { completion(urls) }
        }
    }
}
