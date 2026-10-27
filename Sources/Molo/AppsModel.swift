import AppKit
import UniformTypeIdentifiers

struct DockApp: Identifiable, Equatable {
    let id: String
    let url: URL?
    let bundleID: String?
    let name: String
    let icon: NSImage
    var isPinned: Bool
    var isRunning: Bool
    var pid: pid_t?
    var isFolder = false
}

/// App fissate nel dock + app in esecuzione, tenute aggiornate dalle notifiche di NSWorkspace.
@MainActor
final class AppsModel: ObservableObject {
    @Published private(set) var pinned: [DockApp] = []
    @Published private(set) var running: [DockApp] = []
    @Published private(set) var frontmostPID: pid_t?
    @Published private(set) var launching: Set<String> = []
    /// Icona fissata che si sta trascinando per riordinarla.
    var dragging: DockApp?

    private let defaults = UserDefaults.standard
    private var pinnedPaths: [String]
    private var iconCache: [String: NSImage] = [:]
    private var bundleIDCache: [String: String] = [:]

    private static let finderPath = "/System/Library/CoreServices/Finder.app"

    init() {
        if let saved = defaults.stringArray(forKey: "pinnedApps") {
            pinnedPaths = saved
        } else {
            pinnedPaths = Self.importAppleDock()
            defaults.set(pinnedPaths, forKey: "pinnedApps")
        }
        if !pinnedPaths.contains(Self.finderPath) {
            pinnedPaths.insert(Self.finderPath, at: 0)
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didLaunchApplicationNotification, let id = app?.bundleIdentifier {
                        self?.launching.remove(id)
                    }
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    /// Legge le app fissate nel Dock di Apple (solo al primo avvio).
    private static func importAppleDock() -> [String] {
        guard let tiles = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] else {
            return []
        }
        return tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String else { return nil }
            if let url = URL(string: string), url.isFileURL { return url.path }
            return string.hasPrefix("/") ? string : nil
        }
    }

    func refresh() {
        let fm = FileManager.default
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var matched = Set<pid_t>()
        pinned = pinnedPaths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            let url = URL(fileURLWithPath: path)
            if isDirectory.boolValue && url.pathExtension != "app" {
                return DockApp(id: "pin:" + path, url: url, bundleID: nil,
                               name: fm.displayName(atPath: path), icon: icon(for: path),
                               isPinned: true, isRunning: false, pid: nil, isFolder: true)
            }
            let bundleID = bundleID(for: path)
            let app = regular.first { r in
                if let bundleID, r.bundleIdentifier == bundleID { return true }
                return r.bundleURL?.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
            }
            if let app { matched.insert(app.processIdentifier) }
            return DockApp(id: "pin:" + path,
                           url: url,
                           bundleID: bundleID,
                           name: fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                           icon: icon(for: path),
                           isPinned: true,
                           isRunning: app != nil,
                           pid: app?.processIdentifier)
        }

        running = regular
            .filter { !matched.contains($0.processIdentifier) }
            .map { app in
                DockApp(id: "pid:\(app.processIdentifier)",
                        url: app.bundleURL,
                        bundleID: app.bundleIdentifier,
                        name: app.localizedName ?? "App",
                        icon: app.icon ?? NSWorkspace.shared.icon(for: .application),
                        isPinned: false,
                        isRunning: true,
                        pid: app.processIdentifier)
            }
    }

    private func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    private func bundleID(for path: String) -> String? {
        if let cached = bundleIDCache[path] { return cached }
        let id = Bundle(path: path)?.bundleIdentifier
        bundleIDCache[path] = id
        return id
    }

    private func runningApp(_ item: DockApp) -> NSRunningApplication? {
        item.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    // MARK: Azioni

    /// Come il Dock: apre l'app, oppure la porta davanti (e riapre una finestra se non ne ha).
    func open(_ item: DockApp) {
        if item.isFolder, let url = item.url {
            NSWorkspace.shared.open(url)
        } else if let url = item.url {
            if !item.isRunning, let id = item.bundleID { launching.insert(id) }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
                guard error != nil, let id = item.bundleID else { return }
                DispatchQueue.main.async { self?.launching.remove(id) }
            }
        } else {
            runningApp(item)?.activate()
        }
    }

    func open(files: [URL], with item: DockApp) {
        guard let url = item.url else { return }
        NSWorkspace.shared.open(files, withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func pin(_ item: DockApp) {
        guard let path = item.url?.path, !pinnedPaths.contains(path) else { return }
        pinnedPaths.append(path)
        savePinned()
    }

    /// Fissa un'app o una cartella.
    func pin(url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              url.pathExtension == "app" || isDirectory.boolValue,
              !pinnedPaths.contains(url.path) else { return }
        pinnedPaths.append(url.path)
        savePinned()
    }

    func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        // `pinned` salta i percorsi che non esistono più: si lavora sui percorsi visibili.
        var visible = pinned.compactMap { $0.url?.path }
        visible.move(fromOffsets: source, toOffset: destination)
        pinnedPaths = visible
        savePinned()
    }

    func unpin(_ item: DockApp) {
        guard let path = item.url?.path else { return }
        pinnedPaths.removeAll { $0 == path }
        savePinned()
    }

    func move(_ item: DockApp, before target: DockApp) {
        guard let from = item.url?.path, let to = target.url?.path, from != to,
              let src = pinnedPaths.firstIndex(of: from) else { return }
        pinnedPaths.remove(at: src)
        let dst = pinnedPaths.firstIndex(of: to) ?? pinnedPaths.endIndex
        pinnedPaths.insert(from, at: dst)
        savePinned()
    }

    func revealInFinder(_ item: DockApp) {
        guard let url = item.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func hide(_ item: DockApp) { runningApp(item)?.hide() }
    func quit(_ item: DockApp) { runningApp(item)?.terminate() }
    func forceQuit(_ item: DockApp) { runningApp(item)?.forceTerminate() }

    private func savePinned() {
        defaults.set(pinnedPaths, forKey: "pinnedApps")
        refresh()
    }
}
