// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import RadiusCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Test func boundedImportsReadCompleteFilesAtTheLimitAndRejectOversizedFilesWithoutChangingThem() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-import-bound-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("setup.json")
    let accepted = Data(repeating: 0x61, count: 64 * 1024)
    try accepted.write(to: file)
    #expect(try BoundedImportFile.read(file, maximumBytes: accepted.count, kind: .setup) == accepted)
    let oversized = accepted + Data([0x62])
    try oversized.write(to: file)
    #expect(throws: ValidationError("The setup JSON file must contain at most 64 KB.")) {
        try BoundedImportFile.read(file, maximumBytes: accepted.count, kind: .setup)
    }
    #expect(try Data(contentsOf: file) == oversized)

    let html = directory.appendingPathComponent("bookmarks.html")
    let bookmarkData = Data("<DL><DT><A HREF=\"https://import.fixture.invalid/\">Imported</A></DL>".utf8)
    try bookmarkData.write(to: html)
    let read = try BoundedImportFile.read(html, maximumBytes: 10 * 1024 * 1024, kind: .bookmarks)
    #expect(try BookmarkExchange.parse(read, profileID: UUID()).map(\.title) == ["Imported"])
}

@Test func boundedImportsRejectSymlinksDirectoriesAndPipesWithoutWaitingForAWriter() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radius-import-type-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("original.json")
    let bytes = Data("{}".utf8)
    try bytes.write(to: target)
    #expect(try BoundedImportFile.read(target, maximumBytes: 64 * 1024, kind: .module) == bytes)
    let link = directory.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let pipe = directory.appendingPathComponent("stream.json")
    let created = pipe.withUnsafeFileSystemRepresentation { path in path.map { mkfifo($0, mode_t(0o600)) } ?? -1 }
    try #require(created == 0)
    for url in [link, directory, pipe] {
        #expect(throws: (any Error).self) { try BoundedImportFile.read(url, maximumBytes: 64 * 1024, kind: .setup) }
    }
    #expect(try Data(contentsOf: target) == bytes)
    #expect(throws: (any Error).self) {
        try BoundedImportFile.read(try #require(URL(string: "https://import.fixture.invalid/setup.json")), maximumBytes: 64 * 1024, kind: .setup)
    }
}
