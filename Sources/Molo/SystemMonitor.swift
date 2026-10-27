import Foundation
import IOKit.ps
import Darwin

/// Statistiche di sistema lette ogni 2 secondi (CPU, RAM, batteria, rete, disco).
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var now = Date()
    @Published private(set) var cpu: Double = 0
    @Published private(set) var memoryUsed: Double = 0
    @Published private(set) var memoryTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var batteryCharging = false
    @Published private(set) var batteryOnAC = false
    @Published private(set) var downloadSpeed: Double = 0
    @Published private(set) var uploadSpeed: Double = 0
    @Published private(set) var diskFree: Double = 0
    @Published private(set) var diskTotal: Double = 1

    var memoryFraction: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }
    var diskUsedFraction: Double { diskTotal > 0 ? 1 - diskFree / diskTotal : 0 }

    private var timer: Timer?
    private var previousTicks: (used: UInt64, total: UInt64)?
    private var previousNet: (down: UInt64, up: UInt64, time: Date)?
    private var tickCount = 0

    init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func update() {
        now = Date()
        readCPU()
        readMemory()
        readNetwork()
        // Batteria e disco cambiano lentamente.
        if tickCount % 5 == 0 {
            readBattery()
            readDisk()
        }
        tickCount += 1
    }

    private func readCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle
        if let prev = previousTicks, total > prev.total {
            cpu = Double(used - prev.used) / Double(total - prev.total)
        }
        previousTicks = (used, total)
    }

    private func readMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        // Come "Memoria utilizzata" in Monitoraggio Attività: app + wired + compressa.
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let wired = Double(stats.wire_count)
        let compressed = Double(stats.compressor_page_count)
        memoryUsed = (app + wired + compressed) * page
    }

    private func readBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            batteryLevel = nil
            return
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            batteryLevel = Int((Double(current) / Double(max) * 100).rounded())
            batteryCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            batteryOnAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return
        }
        batteryLevel = nil
    }

    private func readNetwork() {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return }
        defer { freeifaddrs(pointer) }

        var down: UInt64 = 0, up: UInt64 = 0
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = ifa.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            down += UInt64(stats.ifi_ibytes)
            up += UInt64(stats.ifi_obytes)
        }

        let time = Date()
        if let prev = previousNet {
            let elapsed = time.timeIntervalSince(prev.time)
            // I contatori sono a 32 bit: se tornano indietro c'è stato un wrap.
            if elapsed > 0, down >= prev.down, up >= prev.up {
                downloadSpeed = Double(down - prev.down) / elapsed
                uploadSpeed = Double(up - prev.up) / elapsed
            }
        }
        previousNet = (down, up, time)
    }

    private func readDisk() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        if let free = values.volumeAvailableCapacityForImportantUsage { diskFree = Double(free) }
        if let total = values.volumeTotalCapacity { diskTotal = Double(total) }
    }
}
