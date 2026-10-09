// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

var products: [Product] = [.library(name: "RadiusCore", targets: ["RadiusCore"])]
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
    .target(name: "RadiusCore", dependencies: ["CSQLite"]),
    .testTarget(name: "RadiusCoreTests", dependencies: ["RadiusCore"])
]
#if os(macOS)
products.append(.executable(name: "Radius", targets: ["RadiusApp"]))
products.append(.executable(name: "RadiusResourceMonitor", targets: ["RadiusResourceMonitor"]))
products.append(.executable(name: "RadiusMemoryMonitor", targets: ["RadiusMemoryMonitor"]))
targets.append(.target(name: "RadiusResourcePlatform", dependencies: ["RadiusCore"]))
targets.append(.executableTarget(name: "RadiusResourceMonitor", dependencies: ["RadiusCore", "RadiusResourcePlatform"]))
targets.append(.executableTarget(name: "RadiusMemoryMonitor", dependencies: ["RadiusCore", "RadiusResourcePlatform"]))
targets.append(.target(name: "RadiusEngineABI", publicHeadersPath: "include",
    linkerSettings: [.linkedFramework("AppKit")]))
targets.append(.executableTarget(name: "RadiusApp", dependencies: ["RadiusCore", "RadiusEngineABI"],
    resources: [.copy("Resources")]))
targets.append(.testTarget(name: "RadiusAppTests", dependencies: ["RadiusApp"]))
#endif

let package = Package(name: "Radius", platforms: [.macOS(.v14)],
    products: products, targets: targets, swiftLanguageModes: [.v6])
