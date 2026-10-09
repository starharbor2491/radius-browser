// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Presentation data from a resource provider. No callbacks, file paths, or executable UI.
public struct ResourceMetric: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public var detail: String
    public var fraction: Double?
    public var samples: [Double]
    public init(_ name: String, value: String, detail: String = "", fraction: Double? = nil, samples: [Double] = []) {
        self.name = name; self.value = value; self.detail = detail; self.fraction = fraction; self.samples = samples
    }
}
public struct ResourceFrame: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var metrics: [ResourceMetric]
    public init(title: String, detail: String, metrics: [ResourceMetric]) {
        self.title = title; self.detail = detail; self.metrics = metrics
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 64 * 1024 else { throw ValidationError("The resource worker returned too much data.") }
        let frame = try JSONDecoder().decode(Self.self, from: data)
        guard frame.title.count <= 100, frame.detail.count <= 1000, frame.metrics.count <= 12,
              frame.metrics.allSatisfy({ metric in
                  metric.name.count <= 100 && metric.value.count <= 100 && metric.detail.count <= 500 &&
                  (metric.fraction.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
                  metric.samples.count <= 60 && metric.samples.allSatisfy { $0.isFinite && (0...1).contains($0) }
              }) else { throw ValidationError("The resource worker returned an invalid display.") }
        return frame
    }
}
