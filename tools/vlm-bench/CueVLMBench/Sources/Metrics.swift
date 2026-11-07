import Darwin
import Foundation
import UIKit

/// Process memory / thermal / size probes. All local, no network.
enum Metrics {
    struct Memory: Codable, Sendable {
        var footprintMB: Double
        var peakFootprintMB: Double
        var availableMB: Double
    }

    static func memory() -> Memory {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb = 1024.0 * 1024.0
        guard kr == KERN_SUCCESS else { return Memory(footprintMB: -1, peakFootprintMB: -1, availableMB: -1) }
        return Memory(footprintMB: Double(info.phys_footprint) / mb,
                      peakFootprintMB: Double(info.ledger_phys_footprint_peak) / mb,
                      availableMB: Double(os_proc_available_memory()) / mb)
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func directorySizeMB(_ url: URL) -> Double {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile == true { total += v?.totalFileAllocatedSize ?? 0 }
        }
        return Double(total) / (1024 * 1024)
    }

    static func deviceModel() -> String {
        var s = utsname()
        uname(&s)
        return withUnsafeBytes(of: &s.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}
