import AppKit
import SwiftUI

/// VS Code–style multi-repo Source Control accordion (right pane).
/// Top chrome (refresh/add/settings) lives in MenuBarView.
struct VSCodeSCMView: View {
    @Environment(AppState.self) private var appState

    @State private var isReordering = false
    @State private var measuredBodyHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if appState.diffRepos.isEmpty {
                emptyState
                    .frame(height: SOURCRLayout.emptyBodyHeight)
                    .onAppear { appState.reportSCMBodyHeight(SOURCRLayout.emptyBodyHeight) }
            } else {
                ScrollView {
                    RepoReorderStack(repos: appState.diffRepos, mode: .diff, isReordering: $isReordering) { repo, drag in
                        RepoAccordion(repo: repo, drag: drag)
                    } preview: { repo in
                        RepoDragPreview(repo: repo, snap: appState.snapshots[repo.id] ?? .empty)
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: SCMBodyHeightKey.self, value: proxy.size.height)
                        }
                    )
                }
                .scrollDisabled(isReordering)
                .frame(maxWidth: .infinity)
                .modifier(SCMBodyHeightFrame(measured: measuredBodyHeight, fill: appState.isExpanded))
                .onPreferenceChange(SCMBodyHeightKey.self) { height in
                    measuredBodyHeight = height
                    appState.reportSCMBodyHeight(height)
                }
            }

            if let message = appState.statusMessage, appState.panelMode == .diff {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: appState.isExpanded ? .infinity : nil, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No Diff Repositories")
                .font(.system(size: 13, weight: .semibold))
            Text("Add repos in Diff Settings — this list is separate from Actions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// Lightweight floating snapshot of a repo header shown while dragging.
private struct RepoDragPreview: View {
    let repo: WatchedRepo
    let snap: RepoSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(repo.displayName)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if snap.totalChanges > 0 {
                Text("\(snap.totalChanges)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.85))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct RepoAccordion: View {
    @Environment(AppState.self) private var appState
    let repo: WatchedRepo
    let drag: RepoDragHandle

    @State private var headerHovered = false

    private var snap: RepoSnapshot {
        appState.snapshots[repo.id] ?? .empty
    }

    private var isOpen: Bool {
        appState.isRepoAccordionOpen(repo.id, in: .diff)
    }

    private var isActiveDiffRepo: Bool {
        appState.diffRepoID == repo.id && appState.isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen {
                Divider()
                if let error = snap.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    changeSections
                        .padding(.bottom, 6)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActiveDiffRepo
                      ? Color.accentColor.opacity(0.10)
                      : Color(nsColor: .windowBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 4) {
            RepoDragGrip(handle: drag)

            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    appState.toggleRepoAccordion(repo.id, in: .diff)
                }
                appState.selectRepo(repo)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Text(repo.displayName)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)

                    Text("Git")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 4)

                    if snap.totalChanges > 0 {
                        Text("\(snap.totalChanges)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.85))
                            .clipShape(Capsule())
                    }

                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(snap.branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 8)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .onHover { headerHovered = $0 }
            .disabled(drag.reorderActive)
        }
        .background(headerHovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.06))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
            }
            Button(isOpen ? "Collapse" : "Expand") {
                appState.toggleRepoAccordion(repo.id, in: .diff)
            }
            Divider()
            Button("Remove from Diff", role: .destructive) {
                appState.removeRepo(repo, from: .diff)
            }
        }
    }

    @ViewBuilder
    private var changeSections: some View {
        // Flat list: staged + unstaged + untracked (everything not committed).
        let entries = snap.changes + snap.untracked
        if entries.isEmpty {
            Text("No local changes")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    fileRow(entry)
                }
            }
            .padding(.top, 4)
        }
    }

    private func fileRow(_ entry: GitFileEntry) -> some View {
        let selected = appState.isFileSelected(repoID: repo.id, entry: entry)

        return PressableRow(action: {
            appState.selectFile(entry, in: repo)
        }, selected: selected) {
            HStack(spacing: 8) {
                Text(entry.fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if !entry.directoryPath.isEmpty {
                    Text(entry.directoryPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(entry.changeType.shortLetter)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(letterColor(entry))
                    .frame(width: 14, alignment: .trailing)
            }
            .padding(.leading, 16)
        }
    }

    private func letterColor(_ entry: GitFileEntry) -> Color {
        switch entry.changeType {
        case .added, .untracked: return Color(red: 0.35, green: 0.75, blue: 0.45)
        case .modified, .renamed, .copied: return Color(red: 0.35, green: 0.65, blue: 0.95)
        case .deleted: return Color(red: 0.95, green: 0.40, blue: 0.40)
        case .unchanged, .unknown: return .secondary
        }
    }
}
