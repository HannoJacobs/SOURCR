import SwiftUI

struct SettingsPanel: View {
    @Environment(AppState.self) private var appState
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PressableRow(action: { showingSettings = false }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Settings")
                        .font(.headline)
                    Spacer()
                }
            }

            Divider()

            Form {
                Section("Viewer") {
                    LabeledContent("Diff layout") {
                        DiffModePicker()
                    }
                    LabeledContent("Line wrap") {
                        WrapToggle()
                    }
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
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
