import AppKit
import SwiftUI

struct PullRequestDetailPane: View {
    @Environment(AppState.self) private var appState
    @State private var filter = ""

    private var selectedFile: PullRequestFile? {
        appState.pullRequestFiles.first { $0.filename == appState.selectedPullRequestFile }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack {
                Text("Files changed · \(appState.pullRequestFiles.count)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                DiffModePicker()
                WrapToggle()
            }
            .padding(8)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            if appState.isLoadingPullRequest {
                message("Loading PR files from GitHub…")
            } else if let error = appState.pullRequestError {
                VStack(spacing: 12) {
                    message(error)
                    Button("Retry") {
                        if let pr = appState.selectedPullRequest { appState.openPullRequest(pr) }
                    }
                }.padding()
            } else if appState.pullRequestFiles.isEmpty {
                message("No changed files in this pull request.")
            } else {
                HStack(spacing: 0) {
                    fileList.frame(width: 190)
                    Divider()
                    diffContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(SCMTheme.diffBackground)
        .onChange(of: appState.selectedPullRequest?.url) { filter = "" }
        .onChange(of: appState.diffViewMode) {
            AppDiagnostics.info(.appState, "PR diff layout=\(appState.diffViewMode.rawValue)")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let pr = appState.selectedPullRequest {
                Image(systemName: pr.state.symbolName).foregroundStyle(pr.state.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("#\(pr.number) · \(pr.title)")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text(pr.state.label).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HeaderIconButton(systemName: "arrow.clockwise", help: "Refresh PR files", spinning: appState.isLoadingPullRequest) {
                    appState.openPullRequest(pr)
                }
                HeaderIconButton(systemName: "safari", help: "Open on GitHub") {
                    if let url = URL(string: pr.url + "/files") { NSWorkspace.shared.open(url) }
                }
            }
            HeaderIconButton(systemName: "xmark", help: "Close PR files") { appState.clearActionSelection() }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            TextField("Filter files…", text: $filter)
                .textFieldStyle(.roundedBorder).padding(8)
                .accessibilityLabel("Filter PR files")
            if appState.pullRequestFiles.count >= 3000 {
                Text("GitHub limits this list to 3,000 files.")
                    .font(.caption2).foregroundStyle(.orange).padding(8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.pullRequestFiles.filter { filter.isEmpty || $0.filename.localizedCaseInsensitiveContains(filter) }) { file in
                        PressableRow(action: { appState.selectPullRequestFile(file.filename) }, selected: file.filename == appState.selectedPullRequestFile) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.filename).font(.system(size: 11, design: .monospaced))
                                    .lineLimit(2).truncationMode(.middle)
                                HStack(spacing: 5) {
                                    Text(file.status).foregroundStyle(.secondary)
                                    Text("+\(file.additions)").foregroundStyle(.green)
                                    Text("−\(file.deletions)").foregroundStyle(.red)
                                }.font(.system(size: 10))
                            }
                        }
                        .help(file.filename)
                    }
                }.padding(4)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var diffContent: some View {
        if let file = selectedFile {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        if let old = file.previousFilename {
                            Text("Renamed from \(old)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("+\(file.additions)").foregroundStyle(.green)
                    Text("−\(file.deletions)").foregroundStyle(.red)
                }.font(.caption).padding(8)
                Divider()
                if let note = file.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let diff = appState.pullRequestDiff, !diff.isEmpty {
                    switch appState.diffViewMode {
                    case .inline: InlineDiffView(lines: diff.lines, wordWrap: appState.wordWrap)
                    case .sideBySide: SideBySideDiffView(rows: appState.pullRequestRows, wordWrap: appState.wordWrap)
                    }
                } else {
                    Spacer()
                }
            }
        } else {
            message("Select a file to review its changes.")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
