import AppKit

/// Testo tradotto. Le chiavi sono le frasi in italiano; le traduzioni stanno in `Resources/<lingua>.lproj`.
/// Le scritte SwiftUI (`Text("…")`, `Button("…")`…) si traducono da sole: questo serve per le `String`.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Come `L`, con valori al posto di `%@`, `%d`…
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// Lingua dell'interfaccia di Molo, scelta nelle Impostazioni.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, it, en

    var id: String { rawValue }

    /// Ogni lingua scritta nella propria lingua, così si riconosce anche se non si capisce quella attuale.
    var title: String {
        switch self {
        case .system: return L("Come il sistema")
        case .it: return "Italiano"
        case .en: return "English"
        }
    }

    static var current: AppLanguage {
        guard let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = saved.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    /// Salva la scelta e riavvia Molo: macOS legge la lingua solo all'avvio.
    func apply() {
        guard self != Self.current else { return }
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return }
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.6; open \"$0\"", path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
