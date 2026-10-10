// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import RadiusCore

struct ModuleSettingsView: View {
    @EnvironmentObject private var app: AppState
    let manifest: ModuleManifest
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(manifest.name).font(.headline)
            Text("Module preferences stay on this Mac and are retained when you disable the package.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(manifest.settings ?? []) { schema in setting(schema) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
            }.frame(height: min(420, max(70, CGFloat((manifest.settings ?? []).count * 76))))
        }.padding(20).frame(width: 360)
    }
    @ViewBuilder private func setting(_ schema: ModuleSetting) -> some View {
        switch schema.kind {
        case .toggle: Toggle(schema.title, isOn: Binding(get: { app.moduleSetting(schema, moduleID: manifest.id).bool ?? false }, set: { app.setModuleSetting(schema, value: .bool($0), moduleID: manifest.id) }))
        case .choice:
            Picker(schema.title, selection: stringBinding(schema)) {
                ForEach(schema.choices ?? [], id: \.self) { Text($0).tag($0) }
            }
        case .text:
            VStack(alignment: .leading, spacing: 5) {
                Text(schema.title).font(.callout)
                TextField(schema.title, text: stringBinding(schema)).textFieldStyle(.roundedBorder)
            }
        case .integer:
            Stepper(schema.title + ": \(app.moduleSetting(schema, moduleID: manifest.id).integer ?? 0)", value: Binding(get: { app.moduleSetting(schema, moduleID: manifest.id).integer ?? 0 }, set: { app.setModuleSetting(schema, value: .integer($0), moduleID: manifest.id) }), in: 0...200_000)
        }
    }
    private func stringBinding(_ schema: ModuleSetting) -> Binding<String> {
        Binding(get: { app.moduleSetting(schema, moduleID: manifest.id).string ?? "" }, set: { app.setModuleSetting(schema, value: .string($0), moduleID: manifest.id) })
    }
}
