// SPDX-License-Identifier: MPL-2.0
import AppKit
import RadiusCore
import Testing
@testable import RadiusApp

@Suite(.serialized)
@MainActor
struct DownloadsTests {
    @Test func cancellationBeforeChoosingADestinationHasABoundedWait() async throws {
        let center = DownloadCenter()
        let item = DownloadItem(chromiumID: "no-control-yet", sourceURL: nil, cancel: {})
        center.items = [item]

        do {
            try await center.cancelChromiumAndWait(ids: ["no-control-yet"], timeout: .milliseconds(20))
            Issue.record("A missing cancellation control must be reported to the caller")
        } catch is ValidationError {}

        #expect(center.hasActive)
        #expect(item.staging == nil)
        #expect(!item.transferEnded)
    }

    @Test func missingCancellationAcknowledgementPreservesFileAndAllowsRetry() async throws {
        let (center, item, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = try #require(item.staging)
        var cancelRequests = 0
        item.cancelChromium = { cancelRequests += 1 }

        do {
            try await center.cancelAllAndWait(timeout: .zero)
            Issue.record("Cancellation without an acknowledgement must time out")
        } catch is ValidationError {}

        #expect(cancelRequests == 1)
        #expect(center.hasActive)
        #expect(item.active)
        #expect(!item.transferEnded)
        #expect(FileManager.default.fileExists(atPath: staging.path))

        item.cancelChromium = {
            cancelRequests += 1
            center.updateChromium(id: "download", fraction: 0, complete: false, cancelled: true, interrupted: false)
        }
        try await center.cancelAllAndWait(timeout: .seconds(1))
        #expect(cancelRequests == 2)
        #expect(!center.hasActive)
        #expect(item.status == "Cancelled")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func lateAcknowledgementAfterTimeoutStillCleansUp() async throws {
        let (center, item, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = try #require(item.staging)
        do {
            try await center.cancelChromiumAndWait(ids: ["download"], timeout: .milliseconds(20))
            Issue.record("Missing terminal update must not be reported as successful cancellation")
        } catch is ValidationError {}
        #expect(FileManager.default.fileExists(atPath: staging.path))

        center.updateChromium(id: "download", fraction: 0, complete: false, cancelled: true, interrupted: false)
        #expect(!center.hasActive)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(item.staging == nil)
    }

    @Test func closedDownloadOwnerPreservesFileWithoutClaimingTheWriterStopped() async throws {
        let (center, item, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = try #require(item.staging)
        var cancelRequests = 0
        item.cancelChromium = { cancelRequests += 1 }

        center.chromiumOwnerClosed(ids: ["download"])
        center.chromiumOwnerClosed(ids: ["download"])

        #expect(cancelRequests == 1)
        #expect(item.cancellationRequested)
        #expect(item.acknowledgementUnavailable)
        #expect(!item.transferEnded)
        #expect(!item.active)
        #expect(!center.hasActive)
        #expect(item.staging == staging)
        #expect(try String(contentsOf: staging, encoding: .utf8) == "downloaded file")
        #expect(item.status.contains("before cancellation was confirmed"))
        #expect(item.status.contains("temporary file is retained"))

        // Neither retrying nor shutdown may wait for an impossible callback,
        // delete the file, or turn an unconfirmed close into "Finished".
        center.cancel(item)
        try await center.cancelAllAndWait(timeout: .zero)
        try await center.cancelChromiumAndWait(ids: ["download"], timeout: .zero)
        #expect(cancelRequests == 1)
        #expect(!item.transferEnded)
        #expect(FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func ownerClosingWhileCancellationWaitsReleasesTheWaitAndKeepsStaging() async throws {
        let (center, item, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = try #require(item.staging)
        let closeOwner = Task { @MainActor in
            await Task.yield()
            center.chromiumOwnerClosed(ids: ["download"])
        }

        try await center.cancelChromiumAndWait(ids: ["download"], timeout: .seconds(1))
        await closeOwner.value

        #expect(item.acknowledgementUnavailable)
        #expect(!item.transferEnded)
        #expect(!center.hasActive)
        #expect(FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func lateCompletionAfterOwnerClosedNeverReplacesTheDestination() throws {
        let (center, item, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = try #require(item.staging)
        let destination = try #require(item.destination)
        try Data("existing file".utf8).write(to: destination)
        item.approvedReplacement = true

        center.chromiumOwnerClosed(ids: ["download"])
        center.updateChromium(id: "download", fraction: 0.8, complete: false, cancelled: false, interrupted: false)
        #expect(FileManager.default.fileExists(atPath: staging.path))
        #expect(!item.transferEnded)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "existing file")

        // A real late terminal event confirms that cleanup is safe. The close
        // already requested cancellation, so completion must not install a file.
        center.updateChromium(id: "download", fraction: 1, complete: true, cancelled: false, interrupted: false)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "existing file")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(item.transferEnded)
        #expect(!item.acknowledgementUnavailable)
        #expect(item.status == "Cancelled")
    }

    @Test func closedOwnerDoesNotAbandonDownloadsFromOtherTabs() async throws {
        let (center, item, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = DownloadItem(chromiumID: "other-tab", sourceURL: nil, cancel: {
            Issue.record("An unrelated source tab still owns this download")
        })
        center.items.append(other)

        center.chromiumOwnerClosed(ids: ["download"])
        try await center.cancelChromiumAndWait(ids: ["download"], timeout: .zero)

        #expect(item.acknowledgementUnavailable)
        #expect(other.active)
        #expect(!other.acknowledgementUnavailable)
        #expect(!other.cancellationRequested)
        #expect(center.hasActive)
    }

    @Test func tabCancellationWaitsForAcknowledgementAndLeavesOtherTabsAlone() async throws {
        let (center, item, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = DownloadItem(chromiumID: "other-tab", sourceURL: nil, cancel: {
            Issue.record("Closing one tab must not cancel another tab's download")
        })
        center.items.append(other)
        item.cancelChromium = {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(10))
                center.updateChromium(id: "download", fraction: 0, complete: false, cancelled: true, interrupted: false)
            }
        }

        try await center.cancelChromiumAndWait(ids: ["download"], timeout: .seconds(1))
        #expect(item.transferEnded)
        #expect(item.status == "Cancelled")
        #expect(other.active)
        #expect(!other.cancellationRequested)
        #expect(center.hasActive)
    }

    @Test func completionAfterCancellationNeverReplacesTheDestination() throws {
        let (center, item, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = try #require(item.staging)
        let destination = try #require(item.destination)
        try Data("existing file".utf8).write(to: destination)
        item.approvedReplacement = true

        center.cancel(item)
        #expect(center.hasActive)
        #expect(FileManager.default.fileExists(atPath: staging.path))
        center.updateChromium(id: "download", fraction: 1, complete: true, cancelled: false, interrupted: false)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "existing file")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(item.status == "Cancelled")
        #expect(!center.hasActive)
    }

    @Test func duplicateTerminalUpdatesDoNotTouchNewFilesAtTheOldStagingPath() throws {
        let (center, item, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = try #require(item.staging)
        center.updateChromium(id: "download", fraction: 0, complete: false, cancelled: false, interrupted: true)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        try Data("new file".utf8).write(to: staging)

        center.updateChromium(id: "download", fraction: 1, complete: true, cancelled: false, interrupted: false)
        #expect(try String(contentsOf: staging, encoding: .utf8) == "new file")
        #expect(item.status == "Failed: Download interrupted")
    }

    @Test func completedReplacementKeepsDownloadContentsAndQuarantine() throws {
        let (center, item, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try #require(item.destination)
        try Data("existing file".utf8).write(to: destination)
        item.approvedReplacement = true

        center.updateChromium(id: "download", fraction: 1, complete: true, cancelled: false, interrupted: false)

        #expect(item.status == "Finished")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "downloaded file")
        #expect(item.staging == nil)
        #expect(!center.hasActive)
        let metadata = try (destination as NSURL).resourceValues(forKeys: [.quarantinePropertiesKey])
        #expect(metadata[.quarantinePropertiesKey] != nil)
    }

    private func fixture() throws -> (DownloadCenter, DownloadItem, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let center = DownloadCenter()
        let item = DownloadItem(chromiumID: "download", sourceURL: URL(string: "https://example.com/file"), cancel: {})
        item.destination = directory.appendingPathComponent("download.txt")
        let staging = directory.appendingPathComponent(".radius-download-test.part")
        item.staging = staging
        try Data("downloaded file".utf8).write(to: staging)
        center.items = [item]
        return (center, item, directory)
    }
}
