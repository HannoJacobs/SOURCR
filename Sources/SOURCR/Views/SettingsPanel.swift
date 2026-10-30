import SwiftUI

struct SettingsPanel: View {
    @Environment(AppState.self) private var appState
    @Binding var showingSettings: Bool
    @State private var measuredBodyHeight: CGFloat = 0
    @State private var actionReference = ""
    @State private var editingActionRepoID: UUID?
    @State private var actionRepoError: String?

    @State private var selectedAccount = ""
    @State private var showingAccountForm = false
    @State private var newToken = ""
    @State private var accountError: String?
    @State private var isSavingAccount = false
    @State private var isSavingRepository = false

    private var mode: PanelMode { appState.panelMode }
    private var repos: [WatchedRepo] { appState.repos(for: mode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PressableRow(action: { showingSettings = false }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(mode.title) Settings")
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
                                        Text(mode != .diff ? repo.actionsTitle : repo.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                        if mode != .diff {
                                            Text(repo.githubAccount.map { "GitHub: \($0)" } ?? "Choose a GitHub account")
                                                .font(.caption)
                                                .foregroundStyle(repo.githubAccount == nil ? Color.orange : Color.secondary)
                                        }
                                        Text(mode != .diff ? (repo.githubRemote?.slug ?? "GitHub link needed") : repo.path)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 8)
                                    if mode != .diff {
                                        Button {
                                            editingActionRepoID = repo.id
                                            actionReference = repo.githubRemote?.webURL ?? ""
                                            selectedAccount = repo.githubAccount ?? ""
                                            actionRepoError = nil
                                        } label: {
                                            Image(systemName: "pencil")
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isSavingRepository || isSavingAccount)
                                        .help("Edit repository and GitHub account")
                                    }
                                    Button(role: .destructive) {
                                        appState.removeRepo(repo, from: mode)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red.opacity(0.85))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isSavingRepository || isSavingAccount)
                                    .help("Remove from \(mode.title)")
                                }
                            }
                        }

                        if mode != .diff {
                            TextField("GitHub URL or owner/repo", text: $actionReference)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isSavingRepository || isSavingAccount)
                                .onSubmit(saveActionRepository)
                                .accessibilityLabel("GitHub repository")
                            HStack {
                                Picker("GitHub account", selection: $selectedAccount) {
                                    Text("Choose account…").tag("")
                                    ForEach(appState.githubAccounts.logins, id: \.self) { login in
                                        Text(login).tag(login)
                                    }
                                }
                                .disabled(isSavingRepository || isSavingAccount)
                                .accessibilityLabel("GitHub account for repository")
                                Button {
                                    showingAccountForm.toggle()
                                    accountError = nil
                                } label: { Image(systemName: "plus") }
                                .help("Connect GitHub account to SOURCR")
                                .accessibilityLabel("Connect GitHub account")
                            }
                            HStack {
                                Button(editingActionRepoID == nil ? "Add Repository" : "Save Repository", action: saveActionRepository)
                                    .disabled(isSavingRepository || isSavingAccount)
                                if isSavingRepository { ProgressView().controlSize(.small) }
                                if editingActionRepoID != nil {
                                    Button("Cancel") { resetActionEditor() }.disabled(isSavingRepository)
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
                        Text(mode == .diff ? "Diff Repositories" : "GitHub Repositories")
                    } footer: {
                        Text(mode == .diff
                             ? "These repos appear only in Diff. Branches and Actions share a separate list."
                             : "Shared by Branches and Actions. Paste a repository URL or owner/repo; no local folder is needed.")
                    }

                    if mode != .diff {
                        if showingAccountForm {
                            Section("Connect GitHub Account") {
                                SecureField("Personal access token", text: $newToken)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("GitHub personal access token")
                                Text("Connect or replace a token for its GitHub account. Stored only in SOURCR’s Keychain entry.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("For a fine-grained token, select the repositories and allow read access to Actions, Contents and Pull requests. Organization approval may be required.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Link("Create a token on GitHub", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                                HStack {
                                    Button("Connect Account", action: connectAccount)
                                        .disabled(newToken.isEmpty || isSavingAccount || isSavingRepository)
                                    if isSavingAccount { ProgressView().controlSize(.small) }
                                    Button("Cancel") {
                                        showingAccountForm = false
                                        newToken = ""
                                        accountError = nil
                                    }.disabled(isSavingAccount)
                                }
                                if let accountError { Text(accountError).font(.caption).foregroundStyle(.red) }
                            }
                        }
                        Section {
                            Text("Account choices apply only to SOURCR. Existing CLI credentials are copied when selected; CLI login and Git settings stay untouched.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let error = appState.githubAccounts.discoveryError {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                                Button("Retry account discovery") {
                                    Task { await appState.githubAccounts.discoverCLIAccounts() }
                                }
                            }
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
        .task { await appState.githubAccounts.discoverCLIAccounts() }
        .onDisappear { newToken = "" }
    }

    private func connectAccount() {
        isSavingAccount = true
        accountError = nil
        let token = newToken
        newToken = ""
        Task {
            defer { isSavingAccount = false }
            do {
                let login = try await appState.githubAccounts.connectToken(token)
                appState.githubCredentialChanged(login: login)
                selectedAccount = login
                showingAccountForm = false
            } catch { accountError = error.localizedDescription }
        }
    }

    private func saveActionRepository() {
        guard !isSavingRepository, !isSavingAccount else { return }
        guard !selectedAccount.isEmpty else {
            actionRepoError = "Choose a GitHub account or connect one with +."
            return
        }
        guard GitHubActionsService.parseGitHubRemoteURL(actionReference) != nil else {
            actionRepoError = "Enter a GitHub repository URL or owner/repo."
            return
        }
        let reference = actionReference
        let repoID = editingActionRepoID
        let account = selectedAccount
        isSavingRepository = true
        actionRepoError = nil
        Task {
            defer { isSavingRepository = false }
            do {
                try await appState.githubAccounts.connectExisting(account)
                actionRepoError = appState.saveActionRepository(reference, replacing: repoID, account: account)
                if actionRepoError == nil { resetActionEditor() }
            } catch { actionRepoError = error.localizedDescription }
        }
    }

    private func resetActionEditor() {
        actionReference = ""
        selectedAccount = ""
        editingActionRepoID = nil
        actionRepoError = nil
    }
}
