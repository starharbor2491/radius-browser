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
        var activated = false
        defer {
            if helper.deletingLastPathComponent() == journal.deletingLastPathComponent(), helper.lastPathComponent.hasPrefix("RadiusUpdater-") {
                try? FileManager.default.removeItem(at: helper)
                try? FileManager.default.removeItem(at: helper.appendingPathExtension("ready"))
            }
        }
        do {
            let team = try ReleaseTrust.publisherTeam(of: currentApp)
            try ReleaseTrust.verifySignature(URL(fileURLWithPath: args[0]), team: team, identifier: "org.radius.updater", notarized: false)
            let current = try ReleaseTrust.metadata(of: currentApp, requireCompatibleArchitecture: false)
            let architecture: String
            #if arch(arm64)
            architecture = "arm64"
            #else
            architecture = "x86_64"
            #endif
            let sourceRelease = try ReleaseTrust.metadata(of: source)
            let verify: (URL) throws -> Void = { app in
                try ReleaseTrust.verifyBundleTree(app)
                try ReleaseTrust.verifySignature(app, team: team, identifier: "org.radius.browser", notarized: true)
                let release = try ReleaseTrust.metadata(of: app)
                guard release == sourceRelease else { throw ValidationError("The staged application changed after approval.") }
                try release.validate(current: current, minimumEpoch: epoch, architecture: architecture)
            }
            let verifyExisting: (URL) throws -> Void = { app in
                // Restoring the original app after a failed rename is not
                // activating an older candidate. It remains unlaunched; all new
                // candidates must meet the current build/security floor above.
                try ReleaseTrust.verifyBundleTree(app)
                try ReleaseTrust.verifySignature(app, team: team, identifier: "org.radius.browser", notarized: true)
            }
            try verify(source)
            let verifyInstalledForUpdate: (URL) throws -> Void = { app in
                try verifyExisting(app)
                let installed = try ReleaseTrust.metadata(of: app, requireCompatibleArchitecture: false)
                try sourceRelease.validate(current: installed, minimumEpoch: epoch, architecture: architecture)
            }
            if FileManager.default.fileExists(atPath: destination.path) { try verifyInstalledForUpdate(destination) }
            let ready = helper.appendingPathExtension("ready")
            guard helper.deletingLastPathComponent() == journal.deletingLastPathComponent(),
                  helper.lastPathComponent.hasPrefix("RadiusUpdater-"),
                  UUID(uuidString: String(helper.lastPathComponent.dropFirst(14))) != nil else {
                throw ValidationError("The updater must be launched from its private staging directory.")
            }
            try Data("READY".utf8).write(to: ready, options: [.atomic])
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(120))
            while kill(parent, 0) == 0 {
                guard clock.now < deadline else { throw ValidationError("Radius did not finish quitting. The update was left staged.") }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard errno == ESRCH else { throw ValidationError("Could not confirm that Radius has quit. The update was left staged.") }
            try AppReplacementTransaction.recover(journalURL: journal, expectedDestination: destination, verify: verify, verifyExisting: verifyExisting)
            try AppReplacementTransaction.install(source: source, destination: destination, journalURL: journal, verify: verify, verifyExisting: verifyInstalledForUpdate)
            activated = true
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
            alert.messageText = activated ? "Radius was installed but could not finish restarting" : "Radius could not finish the installation"
            alert.informativeText = error.localizedDescription + (activated
                ? " Your browser data is kept. Open the installed Radius app to retry any unfinished setup."
                : " Your browser data is kept. Open your previous Radius app or import the installer again.")
            alert.addButton(withTitle: activated ? "Open Radius" : "OK")
            if activated { alert.addButton(withTitle: "Later") }
            if alert.runModal() == .alertFirstButtonReturn, activated {
                do {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
                } catch {
                    let launchAlert = NSAlert()
                    launchAlert.messageText = "Open Radius from your installation folder"
                    launchAlert.informativeText = error.localizedDescription
                    launchAlert.runModal()
                }
            }
        }
    }
}
