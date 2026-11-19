import Darwin
import Foundation

#if os(iOS)
    import os
#endif

/// Measures this process's memory at runtime (no device tables).
public enum MemoryProbe {

    /// Physical memory, current footprint and (on iOS) the remaining allowance.
    public static func current() -> MemorySnapshot {
        MemorySnapshot(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            footprintBytes: footprintBytes(),
            availableBytes: availableBytes())
    }

    /// `task_vm_info.phys_footprint`, the number jetsam uses.
    public static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// `os_proc_available_memory()` on iOS; `nil` elsewhere or when it reports 0.
    public static func availableBytes() -> UInt64? {
        #if os(iOS)
            let available = os_proc_available_memory()
            return available > 0 ? UInt64(available) : nil
        #else
            return nil
        #endif
    }
}

/// Byte formatting shared by the core (localized by Foundation).
public enum ByteFormatting {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func string(_ bytes: UInt64) -> String {
        string(Int64(clamping: bytes))
    }
}
