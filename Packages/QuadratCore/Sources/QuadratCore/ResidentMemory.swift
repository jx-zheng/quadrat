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
}
