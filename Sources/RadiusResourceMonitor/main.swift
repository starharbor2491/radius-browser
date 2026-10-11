// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation
import RadiusCore
import RadiusResourcePlatform

// The parent closes stdin when its panel/worker lifetime ends; EOF also handles app crashes.
DispatchQueue.global().async { _ = FileHandle.standardInput.readDataToEndOfFile(); exit(0) }
var previous: [UInt32]?
var samples: [Double] = []
while true {
    var metrics: [ResourceMetric] = []
    if let ticks = ResourceStatistics.cpuTicks() {
        if let previous {
            let differences = zip(ticks, previous).map { Double($0.0 &- $0.1) }
            let total = differences.reduce(0, +)
            let fraction = total > 0 ? (total - differences[2]) / total : 0
            samples.append(fraction); if samples.count > 30 { samples.removeFirst() }
            metrics.append(ResourceMetric("System CPU", value: String(format: "%.1f%%", fraction * 100), samples: samples))
        } else { metrics.append(ResourceMetric("System CPU", value: "Sampling…")) }
        previous = ticks
    } else { metrics.append(ResourceMetric("System CPU", value: "Unavailable")) }
    if let memory = ResourceStatistics.memory() {
        metrics.append(ResourceMetric("System memory in use", value: ResourceStatistics.bytes(memory.used),
            detail: "of \(ResourceStatistics.bytes(memory.total)) · active, wired, and compressed pages",
            fraction: Double(memory.used) / Double(memory.total)))
    } else { metrics.append(ResourceMetric("System memory", value: "Unavailable")) }
    guard ResourceStatistics.publish(ResourceFrame(title: "Resource Monitor",
        detail: "Updates every 2 seconds. Sampling stops when this panel closes.", metrics: metrics)) else { break }
    Thread.sleep(forTimeInterval: 2)
}
