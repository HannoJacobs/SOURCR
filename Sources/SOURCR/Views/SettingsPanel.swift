import SwiftUI

struct SettingsPanel: View {
    @Environment(AppState.self) private var appState
    @Binding var showingSettings: Bool
    @State private var measuredBodyHeight: CGFloat = 0
    @State private var actionReference = ""
    @State private var editingActionRepoID: UUID?
    @State private var actionRepoError: String?

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

            ScrollView {
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
                                        Text(mode == .actions ? repo.actionsTitle : repo.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                        Text(mode == .actions ? (repo.githubRemote?.slug ?? "GitHub link needed") : repo.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 8)
                                    if mode == .actions {
                                        Button {
                                            editingActionRepoID = repo.id
                                            actionReference = repo.githubRemote?.webURL ?? ""
                                            actionRepoError = nil
                                        } label: {
                                            Image(systemName: "pencil")
                                        }
                                        .buttonStyle(.plain)
                                        .help("Set GitHub repository link")
                                    }
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

                        if mode == .actions {
                            TextField("GitHub URL or owner/repo", text: $actionReference)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(saveActionRepository)
                                .accessibilityLabel("GitHub repository")
                            HStack {
                                Button(editingActionRepoID == nil ? "Add Repository" : "Save Link", action: saveActionRepository)
                                if editingActionRepoID != nil {
                                    Button("Cancel") { resetActionEditor() }
                                }
                            }
                            if let error = actionRepoError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        } else {
                            Button {
                                appState.presentOpenPanel()
                            } label: {
                                Label("Add Repository…", systemImage: "folder.badge.plus")
                            }
                        }
                    } header: {
                        Text(mode == .diff ? "Diff Repositories" : "Actions Repositories")
                    } footer: {
                        Text(mode == .diff
                             ? "These repos appear only in Diff. Actions has its own list."
                             : "Watch GitHub directly. Paste a repository URL or owner/repo; no local folder is needed.")
                    }

                    if mode == .actions {
                        Section {
                            LabeledContent("Show branches") {
                                BranchWindowPicker()
                            }
                        } header: {
                            Text("Board")
                        } footer: {
                            Text("Branches with no commits or runs inside this window are hidden — the board stays about what you are actually working on.")
                        }
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

                    Section {
                        Button(role: .destructive) {
                            DispatchQueue.main.async {
                                NSApplication.shared.terminate(nil)
                            }
                        } label: {
                            Label("Quit SOURCR", systemImage: "power")
                        }
                    }
                }
                .formStyle(.grouped)
                .padding(.top, 4)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: SCMBodyHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .modifier(SCMBodyHeightFrame(measured: measuredBodyHeight, fill: false))
            .onPreferenceChange(SCMBodyHeightKey.self) { height in
                measuredBodyHeight = height
                // Settings has its own back-row chrome (~44pt), not the Diff/Actions
                // header. Report an adjusted body so panelHeight ≈ back + form.
                appState.reportSCMBodyHeight(height + 44 - SOURCRLayout.chromeHeight)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func saveActionRepository() {
        actionRepoError = appState.saveActionRepository(actionReference, replacing: editingActionRepoID)
        if actionRepoError == nil { resetActionEditor() }
    }

    private func resetActionEditor() {
        actionReference = ""
        editingActionRepoID = nil
        actionRepoError = nil
    }
}
