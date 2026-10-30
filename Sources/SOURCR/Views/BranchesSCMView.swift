import AppKit
import SwiftUI

/// Read-only remote branch watch list, independent of the Actions activity window.
struct BranchesSCMView: View {
    @Environment(AppState.self) private var appState
    @State private var measuredBodyHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if appState.actionsRepos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No GitHub Repositories")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Add a GitHub URL in Settings. No local folder needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .frame(height: SOURCRLayout.emptyBodyHeight)
                .onAppear { appState.reportSCMBodyHeight(SOURCRLayout.emptyBodyHeight) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.actionsRepos) { repo in
                            BranchesRepoAccordion(repo: repo)
                        }
                    }
                    .padding(6)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: SCMBodyHeightKey.self, value: proxy.size.height)
                    })
                }
                .modifier(SCMBodyHeightFrame(measured: measuredBodyHeight, fill: appState.isExpanded))
                .onPreferenceChange(SCMBodyHeightKey.self) { height in
                    measuredBodyHeight = height
                    appState.reportSCMBodyHeight(height)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: appState.isExpanded ? .infinity : nil, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

private struct BranchesRepoAccordion: View {
    @Environment(AppState.self) private var appState
    let repo: WatchedRepo
    @State private var visibleLimit = 10

    private var snapshot: RepoActionsSnapshot { appState.actionsSnapshots[repo.id] ?? .empty }
    private var isOpen: Bool { appState.isRepoAccordionOpen(repo.id, in: .branches) }
    private var visibleBranches: [BranchInfo] {
        snapshot.branches
            .filter { !appState.isBranchHidden($0, in: repo.id) }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                if $0.lastCommitAt != $1.lastCommitAt { return $0.lastCommitAt > $1.lastCommitAt }
                return $0.name < $1.name
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    appState.toggleRepoAccordion(repo.id, in: .branches)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(repo.actionsTitle)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(visibleBranches.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .background(Color.primary.opacity(0.06))

            if isOpen {
                Divider()
                content
            }
        }
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
        .onAppear { logVisibleBranches(event: "appeared") }
        .onChange(of: isOpen) { _, _ in logVisibleBranches(event: "accordion") }
        .onChange(of: snapshot.branches) { _, _ in logVisibleBranches(event: "updated") }
    }

    @ViewBuilder private var content: some View {
        if let error = snapshot.errorMessage {
            message(error, color: .red)
        }
        if snapshot.branchesFetchedAt == nil {
            message(appState.isRefreshingActions ? "Loading branches…" : "Refresh to load branches", color: .secondary)
        } else if visibleBranches.isEmpty {
            message("No watched branches", color: .secondary)
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(spacing: 2) {
                    ForEach(Array(visibleBranches.prefix(visibleLimit)), id: \.name) { branch in
                        WatchedBranchRow(
                            branch: branch,
                            repoID: repo.id,
                            checkState: branch.checkState ?? .idle,
                            now: context.date
                        )
                    }
                    if visibleBranches.count > visibleLimit {
                        Button("Show more (\(min(10, visibleBranches.count - visibleLimit)))") {
                            visibleLimit += 10
                            logVisibleBranches(event: "show-more")
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 7)
                    }
                }
                .padding(5)
            }
        }
    }

    private func logVisibleBranches(event: String) {
        AppDiagnostics.info(.appState,
            "branches view event=\(event) repo=\(repo.actionsTitle) total=\(snapshot.branches.count) watched=\(visibleBranches.count) visible=\(isOpen ? min(visibleLimit, visibleBranches.count) : 0) limit=\(visibleLimit) open=\(isOpen)")
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(10)
    }
}

private struct WatchedBranchRow: View {
    @Environment(AppState.self) private var appState
    let branch: BranchInfo
    let repoID: UUID
    let checkState: BranchCheckState
    let now: Date
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                appState.openBranchOnGitHub(branch, in: repoID)
            } label: {
                HStack(spacing: 5) {
                    Text(branch.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if branch.isDefault {
                        Text("Default")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .help("Open \(branch.name) on GitHub")
            .accessibilityLabel("Open branch \(branch.name)")

            HStack(spacing: 7) {
                Text(relativeUpdatedAt)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Last commit: \(branch.lastCommitAt.formatted())")
                Spacer(minLength: 0)
                BranchStateIcon(state: checkState)
                    .frame(width: 12, height: 12)
                    .help("Check status")
                if branch.hasDivergence {
                    DivergenceBadge(behind: branch.behind, ahead: branch.ahead)
                } else {
                    Text("↓ — ↑ —")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("Behind/ahead unavailable")
                }
                if let pr = branch.pullRequest {
                    PullRequestPill(pullRequest: pr)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovered ? Color.primary.opacity(0.06) : Color.clear))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Hide until updated") {
                appState.hideBranch(branch, in: repoID)
            }
            .help("Hide from SOURCR until a new commit lands on this branch")
        }
    }

    private var relativeUpdatedAt: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: branch.lastCommitAt, relativeTo: now)
    }
}
