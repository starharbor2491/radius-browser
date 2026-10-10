// SPDX-License-Identifier: MPL-2.0
import AppKit
import Darwin
import RadiusCore
import RadiusDistribution

/// A separately signed helper waits until the old app exits before replacing its
/// sealed bundle. It never alters App Support, removes quarantine, or disables
/// Gatekeeper. Every copied candidate is verified again on its destination volume.
@main
struct RadiusUpdater {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 7, let parent = Int32(args[1]), parent > 1,
              let epoch = Int(args[5]), epoch >= 0 else { return }
        let source = URL(fileURLWithPath: args[2]).standardizedFileURL
        let destination = URL(fileURLWithPath: args[3]).standardizedFileURL
        let journal = URL(fileURLWithPath: args[4]).standardizedFileURL
        let currentApp = URL(fileURLWithPath: args[6]).standardizedFileURL
        let helper = URL(fileURLWithPath: args[0]).standardizedFileURL
        defer {
            if helper.deletingLastPathComponent() == journal.deletingLastPathComponent(), helper.lastPathComponent.hasPrefix("RadiusUpdater-") {
                try? FileManager.default.removeItem(at: helper)
            }
        }
        do {
            let team = try ReleaseTrust.publisherTeam(of: currentApp)
            try ReleaseTrust.verifySignature(URL(fileURLWithPath: args[0]), team: team, identifier: "org.radius.updater", notarized: false)
            let current = try ReleaseTrust.metadata(of: currentApp)
            let architecture: String
            #if arch(arm64)
            architecture = "arm64"
            #else
            architecture = "x86_64"
            #endif
            let verify: (URL) throws -> Void = { app in
                try ReleaseTrust.verifyBundleTree(app)
                try ReleaseTrust.verifySignature(app, team: team, identifier: "org.radius.browser", notarized: true)
                try ReleaseTrust.metadata(of: app).validate(current: current, minimumEpoch: epoch, architecture: architecture)
            }
            try verify(source)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(120))
            while kill(parent, 0) == 0 {
                guard clock.now < deadline else { throw ValidationError("Radius did not finish quitting. The update was left staged.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard errno == ESRCH else { throw ValidationError("Could not confirm that Radius has quit. The update was left staged.") }
            try AppReplacementTransaction.recover(journalURL: journal, expectedDestination: destination, verify: verify)
            try AppReplacementTransaction.install(source: source, destination: destination, journalURL: journal, verify: verify)
            // Keep the security floor beside browser data. Removing Chromium must
            // not enable a subsequent older Chromium installation.
            let floor = journal.deletingLastPathComponent().appendingPathComponent("security-floor.json")
            let release = try ReleaseTrust.metadata(of: destination)
            let accepted = max(epoch, release.securityEpoch)
            try JSONEncoder().encode(accepted).write(to: floor, options: [.atomic])
            try? FileManager.default.removeItem(at: source)
            if (try? FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path).isEmpty) == true {
                try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            }
            try? FileManager.default.removeItem(at: journal.deletingLastPathComponent().appendingPathComponent("pending-install.json"))
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
        } catch {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Radius could not finish the installation"
            alert.informativeText = error.localizedDescription + " Your browser data is kept. Open your previous Radius app or import the installer again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
