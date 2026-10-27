import AppKit

/// Brano in riproduzione su Spotify. Lo stato arriva dalle notifiche che Spotify pubblica a ogni cambio;
/// copertina e comandi passano da AppleScript (macOS chiede il permesso la prima volta).
@MainActor
final class SpotifyMonitor: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPlaying = false
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var artwork: NSImage?
    /// macOS non ha dato a Molo il permesso di controllare Spotify (Automazione).
    @Published private(set) var needsPermission = false

    var hasTrack: Bool { isRunning && !title.isEmpty }

    private nonisolated static let bundleID = "com.spotify.client"
    private var artworkURL: String?

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { self?.apply(info) }
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.bundleID else { return }
                MainActor.assumeIsolated { self?.checkRunning() }
            }
        }
        checkRunning()
    }

    private func checkRunning() {
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if isRunning {
            refresh()
        } else {
            title = ""
            artist = ""
            artwork = nil
            isPlaying = false
        }
    }

    private func apply(_ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" {
            title = ""
            artist = ""
            isPlaying = false
            return
        }
        isRunning = true
        isPlaying = state == "Playing"
        title = info["Name"] as? String ?? title
        artist = info["Artist"] as? String ?? artist
        loadArtwork()
    }

    /// Legge lo stato attuale (all'avvio Spotify non manda notifiche).
    private func refresh() {
        let script = """
        tell application "Spotify"
            if player state is stopped then return ""
            return (player state as string) & "\n" & name of current track & "\n" & artist of current track
        end tell
        """
        run(script) { [weak self] result in
            guard let self, let result, !result.isEmpty else { return }
            let parts = result.components(separatedBy: "\n")
            guard parts.count >= 3 else { return }
            self.isPlaying = parts[0] == "playing"
            self.title = parts[1]
            self.artist = parts[2]
            self.loadArtwork()
        }
    }

    private func loadArtwork() {
        run("tell application \"Spotify\" to return artwork url of current track") { [weak self] url in
            guard let self, let url, url != self.artworkURL, let remote = URL(string: url) else { return }
            self.artworkURL = url
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: remote),
                      let image = NSImage(data: data) else { return }
                if self.artworkURL == url { self.artwork = image }
            }
        }
    }

    // MARK: Comandi

    func playPause() {
        isPlaying.toggle()
        run("tell application \"Spotify\" to playpause")
    }

    func next() { run("tell application \"Spotify\" to next track") }
    func previous() { run("tell application \"Spotify\" to previous track") }

    func activate() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.activate()
    }

    /// Esegue lo script su una coda dedicata: la prima volta macOS chiede il permesso,
    /// e la richiesta non deve bloccare il dock.
    private let scriptQueue = DispatchQueue(label: "molo.spotify.applescript")

    private func run(_ source: String, completion: (@MainActor (String?) -> Void)? = nil) {
        guard isRunning else { return }
        scriptQueue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            if let error { NSLog("Molo: AppleScript Spotify: \(error)") }
            // -1743: l'utente non ha autorizzato Molo in Privacy e sicurezza → Automazione.
            let denied = (error?[NSAppleScript.errorNumber] as? Int) == -1743
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.needsPermission != denied { self.needsPermission = denied }
                    completion?(result)
                }
            }
        }
    }

    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Debug: prova un comando e riporta risultato o errore.
    func diagnose(completion: @escaping @MainActor (String) -> Void) {
        scriptQueue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: "tell application \"Spotify\" to return player state as string")?
                .executeAndReturnError(&error).stringValue
            let report = error.map { "error: \($0)" } ?? "ok: \(result ?? "nil")"
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(report) } }
        }
    }
}
