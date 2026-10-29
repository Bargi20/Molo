import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Finestra Impostazioni: aspetto, widget, app e cartelle fissate.
struct SettingsView: View {
    @ObservedObject var settings: DockSettings
    @ObservedObject var apps: AppsModel
    /// Scheda aperta all'avvio (usata dagli screenshot del README).
    static var initialTab = 0
    @State private var tab = SettingsView.initialTab

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(settings: settings)
                .tabItem { Label("Generali", systemImage: "gearshape") }
                .tag(0)
            WidgetsTab(settings: settings)
                .tabItem { Label("Info di sistema", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(1)
            ItemsTab(settings: settings, apps: apps)
                .tabItem { Label("App e cartelle", systemImage: "square.grid.2x2") }
                .tag(2)
        }
        .frame(width: 520, height: 660)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: DockSettings

    var body: some View {
        Form {
            Section("Dimensioni") {
                LabeledContent("Dimensione icone") {
                    HStack {
                        Image(systemName: "app").imageScale(.small)
                        Slider(value: $settings.iconSize, in: 24...72, step: 2)
                        Image(systemName: "app").imageScale(.large)
                        Text("\(Int(settings.iconSize)) pt")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                if settings.fitScale < 0.99 {
                    Text("Le icone sono ridotte al \(Int(settings.fitScale * 100))% perché la barra non sta nello schermo. Togli qualche elemento per averle più grandi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Ingrandimento") {
                    HStack {
                        Text("No").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.magnification, in: 1...1.8)
                        Text("Max").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Comportamento") {
                Toggle("Nascondi e mostra automaticamente il dock", isOn: $settings.autoHide)
                Toggle("Mostra le app aperte non fissate", isOn: $settings.showRunningApps)
                Toggle("Mostra il Cestino", isOn: $settings.showTrash)
            }

            Section {
                Toggle("Anteprime delle finestre al passaggio del mouse", isOn: $settings.showWindowPreviews)
                LabeledContent("Registrazione schermo") {
                    PermissionButton(granted: CGPreflightScreenCaptureAccess(),
                                     pane: "Privacy_ScreenCapture") { CGRequestScreenCaptureAccess() }
                }
                LabeledContent("Accessibilità") {
                    PermissionButton(granted: AXIsProcessTrusted(), pane: "Privacy_Accessibility") {
                        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    }
                }
            } header: {
                Text("Anteprime")
            } footer: {
                Text("La Registrazione schermo serve per le miniature, l'Accessibilità per portare davanti solo la finestra scelta. Dopo averli attivati, riavvia Molo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sistema") {
                Toggle("Apri Molo al login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { _ in settings.toggleLaunchAtLogin() }
                ))
                LabeledContent("Dock di Apple") {
                    if settings.appleDockHidden {
                        Button("Ripristina") { settings.restoreAppleDock() }
                    } else {
                        Button("Nascondi") { settings.hideAppleDock() }
                    }
                }
                LabeledContent("Molo") {
                    Button("Esci da Molo") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Stato di un permesso di sistema: "Attivo", oppure un pulsante che lo chiede.
private struct PermissionButton: View {
    let granted: Bool
    let pane: String
    let request: () -> Bool

    var body: some View {
        if granted {
            Label("Attivo", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Button("Consenti…") {
                // La prima volta macOS mostra la richiesta; dopo bisogna attivarlo a mano nelle Impostazioni.
                if !request() {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
    }
}

private struct WidgetsTab: View {
    @ObservedObject var settings: DockSettings

    var body: some View {
        Form {
            Section {
                Toggle("Mostra le info di sistema nel dock", isOn: $settings.showWidgets)
            }
            Section("Riquadri") {
                ForEach(DockWidget.allCases) { widget in
                    Toggle(isOn: Binding(
                        get: { settings.isEnabled(widget) },
                        set: { settings.setWidget(widget, enabled: $0) }
                    )) {
                        Label(widget.title, systemImage: widget.symbol)
                    }
                }
            }
            .disabled(!settings.showWidgets)
        }
        .formStyle(.grouped)
    }
}

private struct ItemsTab: View {
    @ObservedObject var settings: DockSettings
    @ObservedObject var apps: AppsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trascina per cambiare l'ordine. Puoi anche trascinare app e cartelle dal Finder direttamente sul dock.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(apps.pinned) { item in
                    HStack(spacing: 10) {
                        Image(nsImage: item.icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                        Text(item.name)
                        if item.isFolder {
                            Text("cartella")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            apps.unpin(item)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Rimuovi dal dock")
                    }
                    .padding(.vertical, 2)
                }
                .onMove(perform: apps.movePinned)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Button {
                    choose(apps: true)
                } label: {
                    Label("Aggiungi app…", systemImage: "plus.app")
                }
                Button {
                    choose(apps: false)
                } label: {
                    Label("Aggiungi cartella…", systemImage: "folder.badge.plus")
                }
                Spacer()
                Menu("Cartelle rapide") {
                    ForEach(quickFolders, id: \.self) { url in
                        Button(FileManager.default.displayName(atPath: url.path)) { apps.pin(url: url) }
                    }
                }
                .fixedSize()
            }
        }
        .padding(20)
    }

    private var quickFolders: [URL] {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory] = [.downloadsDirectory, .documentDirectory, .desktopDirectory, .applicationDirectory]
        return dirs.compactMap { fm.urls(for: $0, in: $0 == .applicationDirectory ? .localDomainMask : .userDomainMask).first }
    }

    private func choose(apps pickApps: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if pickApps {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.prompt = "Aggiungi al dock"
        } else {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.prompt = "Aggiungi al dock"
        }
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(apps.pin(url:))
    }
}
