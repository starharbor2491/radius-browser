// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation
import RadiusCore

public struct MemoryStatistics {
    public let total: UInt64
    public let active: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let inactive: UInt64
    public let free: UInt64
    public var used: UInt64 { min(total, active + wired + compressed) }
}

/// Linked into the optional executables only, never the Radius application.
public enum ResourceStatistics {
    public static func cpuTicks() -> [UInt32]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        return result == KERN_SUCCESS ? [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3] : nil
    }
    public static func memory() -> MemoryStatistics? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let size = UInt64(pageSize)
        return MemoryStatistics(total: ProcessInfo.processInfo.physicalMemory,
            active: UInt64(info.active_count) * size, wired: UInt64(info.wire_count) * size,
            compressed: UInt64(info.compressor_page_count) * size, inactive: UInt64(info.inactive_count) * size,
            free: UInt64(info.free_count) * size)
    }
    public static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
    public static func publish(_ frame: ResourceFrame) -> Bool {
        do {
            var data = try JSONEncoder().encode(frame); data.append(0x0a)
            try FileHandle.standardOutput.write(contentsOf: data)
            return true
        } catch { return false }
    }
}
