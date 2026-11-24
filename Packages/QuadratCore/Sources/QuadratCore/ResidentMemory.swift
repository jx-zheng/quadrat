import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ResidentMemory {
    /// Current physical footprint of this process, in bytes.
    public static func currentBytes() -> UInt64 {
        #if os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return UInt64(info.resident_size)
        }
        return 0
        #else
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return 0 }
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.count >= 2, let residentPages = UInt64(fields[1]) else { return 0 }
        return residentPages * 4096
        #endif
    }

    /// Bytes still allocated in every malloc zone, not just the default one.
    public static func heapInUse() -> UInt64 {
        #if os(macOS)
        var total: UInt64 = 0
        forEachZone { _, stats in
            total += UInt64(stats.size_in_use)
        }
        return total
        #else
        return 0
        #endif
    }

    public static func zoneSummary() -> String {
        #if os(macOS)
        var parts: [String] = []
        forEachZone { zone, stats in
            let name = zone.pointee.zone_name.map { String(cString: $0) } ?? "?"
            parts.append("\(name)=\(stats.size_in_use)")
        }
        return parts.joined(separator: ",")
        #else
        return ""
        #endif
    }

    /// Ask every zone to return freed pages. `nil` on the default call was not enough.
    public static func relieve() {
        #if os(macOS)
        forEachZone { zone, _ in
            _ = malloc_zone_pressure_relief(zone, 0)
        }
        #endif
    }

    #if os(macOS)
    private static func forEachZone(_ body: (UnsafeMutablePointer<malloc_zone_t>, malloc_statistics_t) -> Void) {
        var addresses: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        let rc = malloc_get_all_zones(mach_task_self_, nil, &addresses, &count)
        guard rc == KERN_SUCCESS, let addresses else { return }
        for index in 0..<Int(count) {
            guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(addresses[index])) else { continue }
            var stats = malloc_statistics_t()
            malloc_zone_statistics(zone, &stats)
            body(zone, stats)
        }
    }
    #endif
}
