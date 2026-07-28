import SwiftUI

struct SettingsPanel: View {
    @Environment(AppState.self) private var appState
    @Binding var showingSettings: Bool

    private var mode: PanelMode { appState.panelMode }
    private var repos: [WatchedRepo] { appState.repos(for: mode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PressableRow(action: { showingSettings = false }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(mode == .diff ? "Diff Settings" : "Actions Settings")
                        .font(.headline)
                    Spacer()
                }
            }

            Divider()

            Form {
                Section {
                    if repos.isEmpty {
                        Text(mode == .diff
                             ? "No Diff repositories yet."
                             : "No Actions repositories yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(repos) { repo in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repo.displayName)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(repo.path)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                Button(role: .destructive) {
                                    appState.removeRepo(repo, from: mode)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                .help("Remove from \(mode.title)")
                            }
                        }
                    }

                    Button {
                        appState.presentOpenPanel(for: mode)
                    } label: {
                        Label("Add Repository…", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text(mode == .diff ? "Diff Repositories" : "Actions Repositories")
                } footer: {
                    Text(mode == .diff
                         ? "These repos appear only in Diff. Actions has its own list."
                         : "These repos appear only in Actions. Diff has its own list.")
                }

                if mode == .diff {
                    Section("Viewer") {
                        LabeledContent("Diff layout") {
                            DiffModePicker()
                        }
                        LabeledContent("Line wrap") {
                            WrapToggle()
                        }
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

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
