// SPDX-License-Identifier: MPL-2.0
import Darwin
import SwiftUI

@MainActor
final class ResourceSampler: ObservableObject {
    @Published var cpu: Double?
    @Published var memoryUsed: UInt64 = 0
    @Published var residentMemory: UInt64 = 0
    @Published var samples: [Double] = []
    @Published var failure: String?
    let totalMemory = ProcessInfo.processInfo.physicalMemory
    private var previousTicks: [UInt64]?
    func run() async {
        previousTicks = nil
        while !Task.isCancelled {
            sample()
            do { try await Task.sleep(for: .seconds(2)) } catch { break }
        }
    }
    private func sample() {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpuInfo = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount) }
        }
        if cpuResult == KERN_SUCCESS {
            let ticks = [UInt64(cpuInfo.cpu_ticks.0), UInt64(cpuInfo.cpu_ticks.1), UInt64(cpuInfo.cpu_ticks.2), UInt64(cpuInfo.cpu_ticks.3)]
            if let previousTicks {
                // Mach counters are 32-bit and may wrap on long-running systems.
                let differences = zip(ticks, previousTicks).map { Double(UInt32(truncatingIfNeeded: $0.0) &- UInt32(truncatingIfNeeded: $0.1)) }
                let total = differences.reduce(0, +)
                let value = total > 0 ? (total - differences[2]) / total * 100 : 0
                cpu = value; samples.append(value); if samples.count > 30 { samples.removeFirst() }
            }
            previousTicks = ticks
        } else { failure = "CPU statistics are unavailable." }
        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(host, HOST_VM_INFO64, $0, &vmCount) }
        }
        if vmResult == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            if host_page_size(host, &pageSize) == KERN_SUCCESS {
                memoryUsed = min(totalMemory, (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * UInt64(pageSize))
            }
        } else { failure = "Memory statistics are unavailable." }
        var task = mach_task_basic_info_data_t()
        var taskCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let taskResult = withUnsafeMutablePointer(to: &task) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(taskCount)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &taskCount) }
        }
        if taskResult == KERN_SUCCESS { residentMemory = task.resident_size }
    }
}
struct ResourcePanel: View {
    @StateObject private var sampler = ResourceSampler()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                metric("System CPU", value: sampler.cpu.map { String(format: "%.1f%%", $0) } ?? "Sampling…")
                Sparkline(values: sampler.samples).stroke(Color.accentColor, lineWidth: 2).frame(height: 52)
                    .accessibilityLabel("CPU samples from the past minute")
                metric("System memory in use", value: bytes(sampler.memoryUsed))
                ProgressView(value: Double(sampler.memoryUsed), total: Double(sampler.totalMemory))
                Text("of \(bytes(sampler.totalMemory)) · active, wired, and compressed pages").font(.caption).foregroundStyle(.secondary)
                metric("Radius app memory", value: bytes(sampler.residentMemory))
                Text("The native app process only. WebKit manages website processes separately.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Label("Updates every 2 seconds", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                Text("Sampling stops when this panel closes or the module is disabled.").font(.caption).foregroundStyle(.secondary)
                if let failure = sampler.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            }.padding(16)
        }.task { await sampler.run() }
    }
    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 25, weight: .medium, design: .rounded)).monospacedDigit() }
    }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory) }
}
struct Sparkline: Shape {
    var values: [Double]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.width * Double(index) / Double(values.count - 1), y: rect.height * (1 - min(100, max(0, value)) / 100))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
