import SwiftUI

struct SettingsPanel: View {
    @Environment(AppState.self) private var appState
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                showingSettings = false
            }

            Divider()

            Form {
                Section("Viewer") {
                    Toggle("Show unchanged files (sample)", isOn: Binding(
                        get: { appState.showUnchanged },
                        set: { appState.showUnchanged = $0 }
                    ))
                    Picker("Default diff layout", selection: Binding(
                        get: { appState.diffViewMode },
                        set: { appState.diffViewMode = $0 }
                    )) {
                        ForEach(DiffViewMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Section("Safety") {
                    Text("SOURCR is strictly read-only. It never checks out branches, stages files, commits, or pushes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: AppDiagnostics.appVersion)
                    LabeledContent("Build", value: AppDiagnostics.buildVersion)
                    LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "—")
                }
            }
            .formStyle(.grouped)
            .padding(.top, 4)

            Spacer()

            Divider()
            HStack {
                Text("Quit SOURCR")
                    .foregroundStyle(.red)
                Spacer()
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
