// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation
import RadiusCore
import RadiusResourcePlatform

DispatchQueue.global().async { _ = FileHandle.standardInput.readDataToEndOfFile(); exit(0) }
while true {
    var metrics: [ResourceMetric] = []
    if let memory = ResourceStatistics.memory() {
        for (name, value, detail) in [
            ("Active", memory.active, "Recently used physical pages."),
            ("Wired", memory.wired, "Pages that must remain in physical memory."),
            ("Compressed", memory.compressed, "Physical memory occupied by the compressor."),
            ("Inactive", memory.inactive, "Pages available for reuse when needed."),
            ("Free", memory.free, "Unallocated physical pages.")
        ] {
            metrics.append(ResourceMetric(name, value: ResourceStatistics.bytes(value), detail: detail,
                fraction: min(1, Double(value) / Double(memory.total))))
        }
    } else { metrics.append(ResourceMetric("System memory", value: "Unavailable")) }
    guard ResourceStatistics.publish(ResourceFrame(title: "Memory Breakdown",
        detail: "Updates every 2 seconds. Each bar is a fraction of total physical memory; these categories are not a complete accounting.", metrics: metrics)) else { break }
    Thread.sleep(forTimeInterval: 2)
}
