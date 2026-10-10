// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import RadiusCore

struct DistributionSettingsView: View {
    let dataDirectory: URL
    @ObservedObject private var distribution = DistributionManager.shared
    var body: some View {
        GroupBox("Installation and updates") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Install Chromium, remove it, or update Radius with a verified complete application. Installation happens after you quit. Your Radius profiles, saved records, modules, and layout are kept.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let current = distribution.current {
                    LabeledContent("Installed", value: "Radius \(current.version) · \(current.chromium ? "WebKit + Chromium" : "WebKit")")
                }
                if !distribution.publisherAvailable {
                    Label("This development build is not signed by a Developer ID publisher. Consumer installation is available in official signed releases.", systemImage: "signature")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Check for updates") { distribution.checkForUpdates(dataDirectory: dataDirectory) }
                    Button("Import offline installer…") { distribution.importInstaller(dataDirectory: dataDirectory) }
                }.disabled(distribution.busy || distribution.pending != nil || distribution.pendingRecordInvalid || !distribution.publisherAvailable)
                ForEach(Array(distribution.available.enumerated()), id: \.offset) { _, asset in
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Radius \(asset.release.version) · \(asset.release.chromium ? "with Chromium" : "WebKit only")").font(.headline)
                            Text("Official publisher · \(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file)) · restart required")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(asset.release.chromium ? "Install Chromium…" : "Use WebKit only…") {
                            confirmInstall(asset)
                        }.disabled(distribution.busy || distribution.pending != nil || distribution.pendingRecordInvalid)
                    }
                }
                if distribution.busy {
                    HStack {
                        if let progress = distribution.progress { ProgressView(value: progress).frame(maxWidth: 240) }
                        else { ProgressView().controlSize(.small) }
                        if distribution.canCancel { Button("Cancel") { distribution.cancel() } }
                    }
                }
                if let message = distribution.message {
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if distribution.pendingRecordInvalid {
                    Button("Discard unfinished installer") { distribution.discardPending() }.disabled(distribution.busy)
                }
                if distribution.pending != nil {
                    HStack {
                        Button("Restart and install") { distribution.requestRestart() }.buttonStyle(.borderedProminent)
                        Button("Discard installer") { distribution.discardPending() }
                    }.disabled(distribution.busy)
                }
            }.padding(8)
        }.onAppear { distribution.configure(dataDirectory: dataDirectory) }
    }
    private func confirmInstall(_ asset: DistributionAsset) {
        let alert = NSAlert()
        let removingChromium = distribution.current?.chromium == true && !asset.release.chromium
        alert.messageText = removingChromium ? "Remove Chromium and restart Radius?" : "Install Radius and restart?"
        alert.informativeText = "The complete Radius app is staged and verified before replacement. " + (removingChromium
            ? DistributionManager.chromiumRemovalNotice
            : "Your Radius profiles, saved records, installed modules, and layout are kept.\(asset.release.chromium ? " Choose Chromium for future tabs or reopen a tab explicitly to change its engine." : "")")
        alert.addButton(withTitle: "Download installer"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        distribution.install(asset, dataDirectory: dataDirectory)
    }
}
