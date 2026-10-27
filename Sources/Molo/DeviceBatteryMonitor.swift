import Foundation

struct DeviceBattery: Identifiable, Equatable {
    struct Level: Equatable {
        let label: String
        let percent: Int
    }

    let id: String
    let name: String
    let symbol: String
    let levels: [Level]

    /// Il livello da mostrare nell'anello: il più basso tra auricolari (la custodia conta solo se è l'unico).
    var mainPercent: Int {
        let buds = levels.filter { $0.label != "Custodia" }
        return (buds.isEmpty ? levels : buds).map(\.percent).min() ?? 0
    }
}

/// Batterie dei dispositivi collegati: Bluetooth (AirPods, cuffie, mouse, tastiere…)
/// e iPhone/iPad se è installato libimobiledevice (`brew install libimobiledevice`).
@MainActor
final class DeviceBatteryMonitor: ObservableObject {
    @Published private(set) var devices: [DeviceBattery] = []

    private var timer: Timer?

    init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        Task.detached(priority: .utility) {
            let found = Self.bluetoothDevices() + Self.iOSDevices()
            await MainActor.run { [weak self] in
                if self?.devices != found { self?.devices = found }
            }
        }
    }

    // MARK: Bluetooth

    private nonisolated static func bluetoothDevices() -> [DeviceBattery] {
        guard let output = shell("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = root["device_connected"] as? [[String: Any]] else { return [] }

        let keys: [(String, String)] = [
            ("device_batteryLevelLeft", "Sinistra"),
            ("device_batteryLevelRight", "Destra"),
            ("device_batteryLevelCase", "Custodia"),
            ("device_batteryLevelMain", "Batteria"),
            ("device_batteryLevel", "Batteria"),
        ]

        return connected.flatMap { entry in
            entry.compactMap { name, value -> DeviceBattery? in
                guard let info = value as? [String: Any] else { return nil }
                let levels = keys.compactMap { key, label -> DeviceBattery.Level? in
                    guard let raw = info[key] as? String,
                          let percent = Int(raw.replacingOccurrences(of: "%", with: "")) else { return nil }
                    return .init(label: label, percent: percent)
                }
                guard !levels.isEmpty else { return nil }
                let kind = info["device_minorType"] as? String ?? ""
                return DeviceBattery(id: "bt:" + name, name: name,
                                     symbol: symbol(name: name, kind: kind), levels: levels)
            }
        }
    }

    private nonisolated static func symbol(name: String, kind: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        switch kind {
        case "Headphones", "Headset": return "headphones"
        case "Mouse": return "magicmouse"
        case "Keyboard": return "keyboard"
        case "Gamepad": return "gamecontroller"
        case "Speaker": return "hifispeaker"
        default: return "battery.75percent"
        }
    }

    // MARK: iPhone / iPad (opzionale)

    private nonisolated static func iOSDevices() -> [DeviceBattery] {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        guard let dir = dirs.first(where: { FileManager.default.fileExists(atPath: $0 + "/ideviceinfo") }) else {
            return []
        }
        var result: [DeviceBattery] = []
        // -l: collegati via USB, -n: in rete (Wi-Fi, dopo averli abbinati una volta via USB).
        for (flag, network) in [("-l", false), ("-n", true)] {
            let ids = shell(dir + "/idevice_id", [flag])?
                .split(separator: "\n").map { String($0.split(separator: " ").first ?? "") } ?? []
            for udid in ids where !udid.isEmpty && !result.contains(where: { $0.id == "ios:" + udid }) {
                var base = ["-u", udid]
                if network { base.append("-n") }
                guard let level = shell(dir + "/ideviceinfo", base + ["-q", "com.apple.mobile.battery", "-k", "BatteryCurrentCapacity"])
                        .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else { continue }
                let name = shell(dir + "/ideviceinfo", base + ["-k", "DeviceName"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "iPhone"
                let symbol = name.lowercased().contains("ipad") ? "ipad" : "iphone"
                result.append(DeviceBattery(id: "ios:" + udid, name: name, symbol: symbol,
                                            levels: [.init(label: "Batteria", percent: level)]))
            }
        }
        return result
    }

    private nonisolated static func shell(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
