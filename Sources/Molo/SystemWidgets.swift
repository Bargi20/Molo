import SwiftUI
import AppKit

/// Fattore di scala dei riquadri: 1 = altezza 52 pt. Così si rimpiccioliscono insieme alle icone.
private struct WidgetScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

/// Riquadri bassi e larghi, con i valori scritti grandi accanto all'anello e senza etichette
/// al passaggio del mouse: servono nelle pillole accanto al Dock di Apple, che è basso.
private struct WidgetWideKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var widgetScale: CGFloat {
        get { self[WidgetScaleKey.self] }
        set { self[WidgetScaleKey.self] = newValue }
    }
    var widgetWide: Bool {
        get { self[WidgetWideKey.self] }
        set { self[WidgetWideKey.self] = newValue }
    }
}

/// Riquadri con le info di sistema, a sinistra delle app.
struct SystemWidgets: View {
    @ObservedObject var system: SystemMonitor
    @ObservedObject var spotify: SpotifyMonitor
    @ObservedObject var devices: DeviceBatteryMonitor
    let enabled: Set<DockWidget>
    let height: CGFloat
    /// Ingrandimento di ogni riquadro (chiavi da `visibleKeys`) e callback con la sua posizione.
    var scales: [String: CGFloat] = [:]
    var onFrame: (String, CGRect) -> Void = { _, _ in }
    @Environment(\.widgetWide) private var wide
    private var k: CGFloat { height / 52 }

    /// Le chiavi dei riquadri visibili, da sinistra a destra.
    static func visibleKeys(system: SystemMonitor, spotify: SpotifyMonitor, devices: DeviceBatteryMonitor,
                            enabled: Set<DockWidget>) -> [String] {
        var keys: [String] = []
        if enabled.contains(.clock) { keys.append("w.clock") }
        if enabled.contains(.spotify) && spotify.hasTrack { keys.append("w.spotify") }
        if enabled.contains(.cpu) { keys.append("w.cpu") }
        if enabled.contains(.ram) { keys.append("w.ram") }
        if enabled.contains(.battery) && system.batteryLevel != nil { keys.append("w.battery") }
        if enabled.contains(.devices) { keys += devices.devices.map { "w.dev." + $0.id } }
        if enabled.contains(.network) { keys.append("w.network") }
        if enabled.contains(.disk) { keys.append("w.disk") }
        return keys
    }

    private func magnify(_ key: String) -> Magnify {
        Magnify(scale: scales[key] ?? 1) { onFrame(key, $0) }
    }

    var body: some View {
        HStack(spacing: 6 * k) {
            if enabled.contains(.clock) {
                WidgetTile(detail: system.now.formatted(date: .complete, time: .omitted),
                           height: height, action: { openApp("com.apple.iCal") }) {
                    if wide {
                        HStack(spacing: 7) {
                            Text(system.now, format: .dateTime.hour().minute())
                                .font(.system(size: height * 0.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            VStack(alignment: .leading, spacing: 0) {
                                Text(system.now, format: .dateTime.weekday(.abbreviated))
                                Text(system.now, format: .dateTime.day().month(.abbreviated))
                            }
                            .font(.system(size: max(10.5, height * 0.3), weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        }
                    } else {
                    VStack(spacing: 1) {
                        Text(system.now, format: .dateTime.hour().minute())
                            .font(.system(size: 17 * k, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(system.now, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                            .font(.system(size: 9.5 * k, weight: .medium))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                    .frame(minWidth: 62 * k)
                    }
                }
                .modifier(magnify("w.clock"))
            }

            if enabled.contains(.spotify) && spotify.hasTrack {
                SpotifyTile(spotify: spotify, height: height)
                    .modifier(magnify("w.spotify"))
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }

            if enabled.contains(.cpu) {
                RingTile(title: "CPU",
                         value: system.cpu,
                         detail: L("CPU in uso: %@", percent(system.cpu)),
                         color: loadColor(system.cpu),
                         height: height,
                         action: { openApp("com.apple.ActivityMonitor") })
                    .modifier(magnify("w.cpu"))
            }

            if enabled.contains(.ram) {
                RingTile(title: "RAM",
                         value: system.memoryFraction,
                         detail: L("Memoria: %@ di %@", bytes(system.memoryUsed), bytes(system.memoryTotal)),
                         color: loadColor(system.memoryFraction),
                         height: height,
                         action: { openApp("com.apple.ActivityMonitor") })
                    .modifier(magnify("w.ram"))
            }

            if enabled.contains(.battery), let level = system.batteryLevel {
                RingTile(title: system.batteryCharging ? "⚡︎ " + L("BATT") : L("BATT"),
                         value: Double(level) / 100,
                         detail: batteryDetail(level),
                         color: batteryColor(level),
                         height: height,
                         action: { openURL("x-apple.systempreferences:com.apple.Battery-Settings.extension") })
                    .modifier(magnify("w.battery"))
            }

            if enabled.contains(.devices) {
                ForEach(devices.devices) { device in
                    DeviceTile(device: device, height: height)
                        .modifier(magnify("w.dev." + device.id))
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                }
            }

            if enabled.contains(.network) {
                WidgetTile(detail: L("Rete: ↓ %@  ↑ %@", speed(system.downloadSpeed), speed(system.uploadSpeed)),
                           height: height, action: { openApp("com.apple.ActivityMonitor") }) {
                    if wide {
                        VStack(alignment: .leading, spacing: 0) {
                            Label(speed(system.downloadSpeed), systemImage: "arrow.down")
                                .foregroundStyle(.blue)
                            Label(speed(system.uploadSpeed), systemImage: "arrow.up")
                                .foregroundStyle(.pink)
                        }
                        .font(.system(size: max(11, height * 0.32), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .labelStyle(CompactLabelStyle(k: height / 40))
                        .frame(width: height * 2.6, alignment: .leading)
                    } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(speed(system.downloadSpeed), systemImage: "arrow.down")
                            .foregroundStyle(.blue)
                        Label(speed(system.uploadSpeed), systemImage: "arrow.up")
                            .foregroundStyle(.pink)
                    }
                    .font(.system(size: 10.5 * k, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .labelStyle(CompactLabelStyle(k: k))
                    .frame(width: 72 * k, alignment: .leading)
                    }
                }
                .modifier(magnify("w.network"))
            }

            if enabled.contains(.disk) {
                RingTile(title: L("DISCO"),
                         value: system.diskUsedFraction,
                         detail: L("Disco: %@ liberi di %@", bytes(system.diskFree), bytes(system.diskTotal)),
                         color: loadColor(system.diskUsedFraction),
                         height: height,
                         action: { openApp("com.apple.DiskUtility") })
                    .modifier(magnify("w.disk"))
            }
        }
        .environment(\.widgetScale, height / 52)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: spotify.hasTrack)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: devices.devices.map(\.id))
    }

    private func batteryDetail(_ level: Int) -> String {
        if system.batteryCharging { return L("Batteria %d%% · in carica", level) }
        if system.batteryOnAC { return L("Batteria %d%% · collegato all'alimentazione", level) }
        return L("Batteria %d%%", level)
    }
}

/// Ingrandisce un riquadro dal basso e gli fa spazio ai lati, come le icone nell'onda.
struct Magnify: ViewModifier {
    let scale: CGFloat
    let onFrame: (CGRect) -> Void
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                width = frame.width
                onFrame(frame)
            }
            .scaleEffect(scale, anchor: .bottom)
            .padding(.horizontal, width * (scale - 1) / 2)
    }
}

/// Riquadro base: sfondo, etichetta al passaggio del mouse, click.
struct WidgetTile<Content: View>: View {
    let detail: String
    let height: CGFloat
    let action: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.widgetScale) private var k
    @Environment(\.widgetWide) private var wide

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        content
            .padding(.horizontal, 8 * k)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 12 * k, style: .continuous)
                    // Nelle pillole niente riquadro: sembrerebbe una card dentro l'altra.
                    .fill(Color.primary.opacity(wide ? 0 : (hovering ? 0.14 : 0.07)))
            )
            .contentShape(Rectangle())
            .scaleEffect(pressed ? 0.94 : 1, anchor: .bottom)
            .overlay(alignment: .top) {
                if hovering && !wide {
                    HoverBubble(text: detail)
                        .offset(y: -(height / 2 + 14))
                        .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
            .animation(.spring(response: 0.2, dampingFraction: 0.5), value: pressed)
            .onHover { hovering = $0 }
            .onTapGesture {
                pressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
                action()
            }
    }
}

struct RingTile: View {
    let title: String
    let value: Double
    let detail: String
    let color: Color
    let height: CGFloat
    let action: () -> Void
    @Environment(\.widgetScale) private var k

    /// L'anello avanza a scatti del 5%: ogni animazione ridisegna tutto il dock,
    /// e CPU e RAM cambiano di poco a ogni lettura.
    private var ringValue: Double { (min(1, max(0, value)) * 20).rounded() / 20 }

    @Environment(\.widgetWide) private var wide

    var body: some View {
        WidgetTile(detail: detail, height: height, action: action) {
            if wide {
                WideValue(title: title, value: "\(Int((value * 100).rounded()))%", height: height) {
                    Circle()
                        .trim(from: 0, to: max(0.001, ringValue))
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: ringValue)
                }
            } else {
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.15), lineWidth: 3.5 * k)
                    Circle()
                        .trim(from: 0, to: max(0.001, ringValue))
                        .stroke(color, style: StrokeStyle(lineWidth: 3.5 * k, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: ringValue)
                    Text("\(Int((value * 100).rounded()))")
                        .font(.system(size: 10 * k, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: height * 0.58, height: height * 0.58)
                Text(title)
                    .font(.system(size: 8.5 * k, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 34 * k)
            }
        }
    }
}

/// Riquadro largo: anello piccolo a sinistra, valore grande e nome a destra.
private struct WideValue<Ring: View>: View {
    let title: String
    let value: String
    let height: CGFloat
    var symbol: String?
    @ViewBuilder let ring: Ring

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 4)
                ring
                if let symbol {
                    Image(systemName: symbol).font(.system(size: height * 0.3, weight: .semibold))
                }
            }
            .frame(width: height * 0.62, height: height * 0.62)
            VStack(alignment: .leading, spacing: -1) {
                Text(value)
                    .font(.system(size: height * 0.44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.system(size: max(9.5, height * 0.26), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

struct SpotifyTile: View {
    @ObservedObject var spotify: SpotifyMonitor
    let height: CGFloat
    @Environment(\.widgetScale) private var k
    @Environment(\.widgetWide) private var wide

    var body: some View {
        WidgetTile(detail: "\(spotify.title) — \(spotify.artist)", height: height, action: spotify.activate) {
            HStack(spacing: 8 * k) {
                Group {
                    if let artwork = spotify.artwork {
                        Image(nsImage: artwork).resizable()
                    } else {
                        ZStack {
                            Color.green.opacity(0.25)
                            Image(systemName: "music.note").foregroundStyle(.green)
                        }
                    }
                }
                .frame(width: height - (wide ? 8 : 10), height: height - (wide ? 8 : 10))
                .clipShape(RoundedRectangle(cornerRadius: 7 * k, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .scaleEffect(spotify.isPlaying ? 1 : 0.88)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: spotify.isPlaying)
                .id(spotify.title)
                .transition(.opacity)

                if wide {
                    // Pillola bassa: titolo e artista su due righe, comandi a destra.
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            Text(spotify.title)
                                .font(.system(size: max(12, height * 0.34), weight: .semibold))
                                .lineLimit(1)
                            if spotify.isPlaying { EqualizerBars().frame(width: 10, height: 10) }
                        }
                        Text(spotify.artist)
                            .font(.system(size: max(10.5, height * 0.29)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 118, alignment: .leading)
                    controls
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4 * k) {
                            Text(spotify.title)
                                .font(.system(size: 11 * k, weight: .semibold))
                                .lineLimit(1)
                            if spotify.isPlaying { EqualizerBars().frame(width: 10 * k, height: 9 * k) }
                        }
                        Text(spotify.artist)
                            .font(.system(size: 9.5 * k))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        controls.padding(.leading, -6 * k)
                    }
                    .frame(width: 104 * k, alignment: .leading)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: spotify.title)
        }
    }

    @ViewBuilder private var controls: some View {
        if spotify.needsPermission {
            Button("Consenti controllo", action: spotify.openAutomationSettings)
                .buttonStyle(.link)
                .font(.system(size: wide ? 11 : 9.5 * k, weight: .semibold))
                .help("Impostazioni di Sistema → Privacy e sicurezza → Automazione → Molo → Spotify")
        } else {
            HStack(spacing: 0) {
                MediaButton(symbol: "backward.fill", action: spotify.previous)
                MediaButton(symbol: spotify.isPlaying ? "pause.fill" : "play.fill", action: spotify.playPause)
                MediaButton(symbol: "forward.fill", action: spotify.next)
            }
        }
    }
}

/// Pulsante ⏮ ⏯ ⏭: è un Button vero, così ha la precedenza sul click del riquadro (che apre Spotify),
/// e l'area cliccabile è più grande del simbolo per non mancarlo.
private struct MediaButton: View {
    let symbol: String
    let action: () -> Void
    @Environment(\.widgetScale) private var k
    @Environment(\.widgetWide) private var wide
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: wide ? 14 : 11 * k, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: wide ? 26 : max(22, 24 * k), height: wide ? 26 : max(16, 18 * k))
                .background(
                    Capsule().fill(Color.primary.opacity(hovering && !wide ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(MediaButtonStyle(hovering: hovering, bump: wide))
        .onHover { hovering = $0 }
    }
}

private struct MediaButtonStyle: ButtonStyle {
    let hovering: Bool
    /// Nelle pillole: al passaggio del mouse il simbolo fa un piccolo salto invece di avere lo sfondo.
    var bump = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? Color.primary : Color.primary.opacity(0.7))
            .scaleEffect(configuration.isPressed ? 0.8 : (hovering ? 1.12 : 1))
            .offset(y: bump && hovering && !configuration.isPressed ? -2 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.5), value: configuration.isPressed)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
    }
}

/// Tre barrette che ballano mentre la musica suona.
private struct EqualizerBars: View {
    @Environment(\.widgetScale) private var k
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5 * k) {
                ForEach(0..<3) { i in
                    let phase = t * (5 + Double(i) * 1.7) + Double(i) * 1.3
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 2 * k, height: (2 + 7 * CGFloat((sin(phase) + 1) / 2)) * k)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

struct DeviceTile: View {
    let device: DeviceBattery
    let height: CGFloat
    @Environment(\.widgetScale) private var k
    @Environment(\.widgetWide) private var wide

    private var detail: String {
        let levels = device.levels.map { "\(L($0.label)) \($0.percent)%" }.joined(separator: " · ")
        return "\(device.name): \(levels)"
    }

    var body: some View {
        WidgetTile(detail: detail, height: height,
                   action: { openURL("x-apple.systempreferences:com.apple.BluetoothSettings") }) {
            if wide {
                WideValue(title: device.name, value: "\(device.mainPercent)%", height: height, symbol: device.symbol) {
                    Circle()
                        .trim(from: 0, to: max(0.001, Double(device.mainPercent) / 100))
                        .stroke(batteryColor(device.mainPercent), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            } else {
            VStack(spacing: 2) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 3.5 * k)
                    Circle()
                        .trim(from: 0, to: max(0.001, Double(device.mainPercent) / 100))
                        .stroke(batteryColor(device.mainPercent), style: StrokeStyle(lineWidth: 3.5 * k, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: device.mainPercent)
                    Image(systemName: device.symbol)
                        .font(.system(size: 11 * k, weight: .semibold))
                }
                .frame(width: height * 0.58, height: height * 0.58)
                Text("\(device.mainPercent)%")
                    .font(.system(size: 8.5 * k, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(minWidth: 34 * k)
            }
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    var k: CGFloat = 1
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3 * k) {
            configuration.icon.font(.system(size: 9 * k, weight: .heavy))
            configuration.title.foregroundStyle(.primary)
        }
    }
}

// MARK: - Formattazione e azioni

private func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(0)))
}

private func bytes(_ value: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
}

private func speed(_ bytesPerSecond: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.zeroPadsFractionDigits = false
    return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
}

private func loadColor(_ value: Double) -> Color {
    switch value {
    case ..<0.6: return .green
    case ..<0.85: return .orange
    default: return .red
    }
}

private func batteryColor(_ level: Int) -> Color {
    switch level {
    case ..<15: return .red
    case ..<30: return .orange
    default: return .green
    }
}

private func openApp(_ bundleID: String) {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

private func openURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
}
