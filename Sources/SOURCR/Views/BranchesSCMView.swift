import AppKit
import SwiftUI

/// Remote branches and their workflow activity in one read-only board.
struct BranchesSCMView: View {
    @Environment(AppState.self) private var appState
    @State private var measuredBodyHeight: CGFloat = 0
    @State private var isReordering = false

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
                    RepoReorderStack(repos: appState.actionsRepos, mode: .branches, isReordering: $isReordering) { repo, drag in
                        BranchesRepoAccordion(repo: repo, drag: drag)
                    } preview: { repo in
                        BranchesRepoDragPreview(title: repo.actionsTitle)
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: SCMBodyHeightKey.self, value: proxy.size.height)
                    })
                }
                .scrollDisabled(isReordering)
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

/// Floating repo header that follows the pointer while reordering.
private struct BranchesRepoDragPreview: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
            Spacer(minLength: 4)
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

private struct BranchesRepoAccordion: View {
    @Environment(AppState.self) private var appState
    let repo: WatchedRepo
    let drag: RepoDragHandle
    @State private var visibleLimit = 10

    private var snapshot: RepoActionsSnapshot { appState.actionsSnapshots[repo.id] ?? .empty }
    private var isOpen: Bool { appState.isRepoAccordionOpen(repo.id, in: .branches) }
    private var visibleBranches: [BranchInfo] {
        (snapshot.branches.isEmpty ? appState.branchActivities(for: repo, window: .all).map(\.branch) : snapshot.branches)
            .filter { !appState.isBranchHidden($0, in: repo.id) }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                if $0.lastCommitAt != $1.lastCommitAt { return $0.lastCommitAt > $1.lastCommitAt }
                return $0.name < $1.name
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                RepoDragGrip(handle: drag)
                    .padding(.leading, 2)

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
                        let activities = appState.branchActivities(for: repo, window: .all)
                            .filter { !appState.isBranchHidden($0.branch, in: repo.id) }
                        let running = activities.filter { $0.state == .running }.count
                        let failed = activities.filter { $0.state == .failed }.count
                        if running > 0 {
                            countBadge(running, color: .orange, help: "\(running) branch\(running == 1 ? "" : "es") running CI/CD")
                        }
                        if failed > 0 {
                            countBadge(failed, color: .red, help: "\(failed) branch\(failed == 1 ? "" : "es") with failed workflows")
                        }
                        if running == 0, failed == 0, !activities.isEmpty {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                                .help("No running or failed workflows")
                        }
                    }
                    .padding(.leading, 2)
                    .padding(.trailing, 4)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(drag.reorderActive)

                if let remote = repo.githubRemote, let url = URL(string: remote.branchesURL) {
                    Button {
                        NSWorkspace.shared.open(url)
                        AppDiagnostics.info(.appState, "default browser opened kind=allBranches repo=\(remote.slug)")
                    } label: {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Open \(remote.slug) · All branches on GitHub")
                    .accessibilityLabel("Open \(repo.actionsTitle) branches on GitHub")
                }
            }
            .background(Color.primary.opacity(0.06))
            .contextMenu {
                Button("Open all branches on GitHub") {
                    if let urlString = repo.githubRemote?.branchesURL, let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Remove repository", role: .destructive) {
                    appState.removeRepo(repo, from: .branches)
                }
            }

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
        .onChange(of: snapshot.runs) { _, _ in logVisibleBranches(event: "workflows-updated") }
        .onChange(of: snapshot.branches) { _, _ in logVisibleBranches(event: "updated") }
    }

    @ViewBuilder private var content: some View {
        if let error = snapshot.errorMessage {
            message(error, color: .red)
        }
        if snapshot.branchesFetchedAt == nil && snapshot.runs.isEmpty {
            message(appState.isRefreshingActions ? "Loading branches…" : "Refresh to load branches", color: .secondary)
        } else if visibleBranches.isEmpty {
            message("No watched branches", color: .secondary)
        } else {
            let divergenceScale = visibleBranches.prefix(visibleLimit)
                .filter { !$0.isDefault && $0.hasDivergence }
                .map { max($0.behind, $0.ahead) }
                .max() ?? 0
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let activities = Dictionary(uniqueKeysWithValues: appState.branchActivities(for: repo, now: context.date, window: .all).map { ($0.branch.name, $0.runs) })
                VStack(spacing: 0) {
                    ForEach(Array(visibleBranches.prefix(visibleLimit).enumerated()), id: \.element.name) { index, branch in
                        if index > 0 {
                            Divider()
                                .padding(.horizontal, 8)
                        }
                        BranchWithActionsRow(
                            branch: branch,
                            repoID: repo.id,
                            runs: activities[branch.name] ?? [],
                            hasWorkflowHistory: snapshot.runs.contains { $0.headBranch == branch.name },
                            divergenceScale: divergenceScale,
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
            "branches view event=\(event) repo=\(repo.actionsTitle) total=\(snapshot.branches.count) watched=\(visibleBranches.count) visible=\(isOpen ? min(visibleLimit, visibleBranches.count) : 0) limit=\(visibleLimit) open=\(isOpen) alternatingRows=false statusAlignment=top rowDividers=true runningBar=false divergenceGraph=true workflowPill=finishedOnly mergedActions=true runs=\(snapshot.runs.count)")
    }

    private func countBadge(_ count: Int, color: Color, help: String) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.9)))
            .help(help)
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(10)
    }
}

/// One line: branch name, then behind|ahead graph, workflow pill and PR in fixed columns.
private struct WatchedBranchRow: View {
    @Environment(AppState.self) private var appState
    let branch: BranchInfo
    let repoID: UUID
    let checkState: BranchCheckState
    let completedCount: Int
    let completedExpanded: Bool
    let onToggleCompleted: () -> Void
    let divergenceScale: Int
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 4) {
                Text(branch.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(branch.name)

                if branch.isDefault {
                    Text("default")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .fixedSize()
                }

                Spacer(minLength: 0)

                // Right-anchored, so graphs still line up; rows without one give the name the room.
                if !branch.isDefault && branch.hasDivergence {
                    DivergenceGraph(behind: branch.behind, ahead: branch.ahead, scale: divergenceScale)
                        .frame(width: DivergenceGraph.width)
                }

                WorkflowStatusPill(state: checkState, completedCount: completedCount, expanded: completedExpanded)
                    .fixedSize()
                    .frame(width: 40, alignment: .trailing)

                Group {
                    if let pr = branch.pullRequest, !appState.pullRequestExclusions.contains(pr) {
                        PullRequestPill(pullRequest: pr)
                    }
                }
                .frame(width: 60, alignment: .trailing)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovered ? Color.primary.opacity(0.05) : Color.clear))
        .onHover { hovered = $0 }
        // The whole row opens its workflow list; the PR pill keeps its own click.
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleCompleted)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Branch \(branch.name), \(checkState.helpText)")
        .contextMenu {
            Button("Open branch on GitHub") {
                appState.openBranchOnGitHub(branch, in: repoID)
            }
            Button("Hide until updated") {
                appState.hideBranch(branch, in: repoID)
            }
            .help("Hide from SOURCR until a new commit lands on this branch")
        }
    }
}

/// A branch with its running/failed runs always visible and completed runs behind the
/// workflow pill.
private struct BranchWithActionsRow: View {
    @Environment(AppState.self) private var appState
    let branch: BranchInfo
    let repoID: UUID
    let runs: [ActionRun]
    let hasWorkflowHistory: Bool
    let divergenceScale: Int
    let now: Date

    private var activity: BranchActivity { BranchActivity(repoID: repoID, branch: branch, runs: runs) }
    private var expanded: Bool { appState.isBranchExpanded(activity.id) }
    private var completedRuns: [ActionRun] { runs.filter { !$0.isRunning && !$0.isFailed } }
    private var visibleRuns: [ActionRun] { activity.attentionRuns + (expanded ? completedRuns : []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WatchedBranchRow(
                branch: branch,
                repoID: repoID,
                checkState: hasWorkflowHistory ? activity.state : (branch.checkState ?? .idle),
                completedCount: completedRuns.count,
                completedExpanded: expanded,
                onToggleCompleted: toggleCompleted,
                divergenceScale: divergenceScale
            )
            if !visibleRuns.isEmpty {
                VStack(spacing: 0) {
                    ForEach(visibleRuns) { run in
                        RunLine(run: run, now: now)
                    }
                }
                .padding(.bottom, 3)
            }
        }
        .padding(.vertical, 3)
    }

    private func toggleCompleted() {
        appState.toggleBranchExpanded(activity.id)
        AppDiagnostics.info(.appState, "completed workflows branch=\(branch.name) expanded=\(expanded) count=\(completedRuns.count)")
    }
}

/// GitHub's branch-list divergence graph: behind | ahead around a centre rule, with
/// grey bars scaled against the largest divergence in the visible list.
private struct DivergenceGraph: View {
    static let width: CGFloat = 60
    let behind: Int
    let ahead: Int
    let scale: Int

    private var halfWidth: CGFloat { Self.width / 2 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(behind, alignment: .trailing)
            Rectangle()
                .fill(Color.primary.opacity(0.22))
                .frame(width: 1, height: 19)
            side(ahead, alignment: .leading)
        }
        .help("\(behind) commit\(behind == 1 ? "" : "s") behind · \(ahead) ahead of the default branch")
    }

    private func side(_ value: Int, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(value == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 3)
            Rectangle()
                .fill(Color.primary.opacity(0.13))
                .frame(width: barWidth(value), height: 3)
        }
        .frame(width: halfWidth, alignment: Alignment(horizontal: alignment, vertical: .top))
    }

    private func barWidth(_ value: Int) -> CGFloat {
        guard value > 0, scale > 0 else { return 0 }
        return max(3, (halfWidth - 2) * CGFloat(value) / CGFloat(scale))
    }
}

/// Branch result and completed-run count in one pill: green tick or red cross.
/// Hidden while anything runs, because each running workflow already shows its own
/// spinner beneath the branch. Clicking the row reveals the runs.
private struct WorkflowStatusPill: View {
    let state: BranchCheckState
    let completedCount: Int
    let expanded: Bool

    var body: some View {
        if state == .running || (state == .idle && completedCount == 0) {
            EmptyView()
        } else {
            HStack(spacing: 3) {
                BranchStateIcon(state: state)
                    .frame(width: 11, height: 11)
                if completedCount > 0 {
                    Text("\(completedCount)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(expanded ? 0.24 : 0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .help(helpText)
        }
    }

    private var tint: Color {
        switch state {
        case .running: return .orange
        case .failed: return .red
        case .clean: return .green
        case .idle: return .secondary
        }
    }

    private var helpText: String {
        guard completedCount > 0 else { return state.helpText }
        return "\(state.helpText) · \(completedCount) completed workflow\(completedCount == 1 ? "" : "s") · click the branch to \(expanded ? "hide" : "show") them"
    }
}
