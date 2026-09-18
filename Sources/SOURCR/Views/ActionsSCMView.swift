import AppKit
import SwiftUI

/// Right-column GitHub Actions board. One row per *branch*, not per workflow run:
/// divergence from the default branch, the open PR, and a collapsed check state.
///
/// The noise rule: a branch where everything passed is a single tick. Only runs that
/// are still going (with a live timer) or that failed (with how long they ran before
/// dying) get a row of their own. Everything else is one click away.
///
/// Chrome (refresh/add/settings) lives above in MenuBarView.
struct ActionsSCMView: View {
    @Environment(AppState.self) private var appState
    @State private var measuredBodyHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if appState.actionsRepos.isEmpty {
                emptyState
                    .frame(height: SOURCRLayout.emptyBodyHeight)
                    .onAppear { appState.reportSCMBodyHeight(SOURCRLayout.emptyBodyHeight) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.actionsRepos) { repo in
                            ActionsRepoAccordion(repo: repo)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: SCMBodyHeightKey.self, value: proxy.size.height)
                        }
                    )
                }
                .frame(maxWidth: .infinity)
                .modifier(SCMBodyHeightFrame(measured: measuredBodyHeight, fill: appState.isExpanded))
                .onPreferenceChange(SCMBodyHeightKey.self) { height in
                    measuredBodyHeight = height
                    appState.reportSCMBodyHeight(height)
                }
            }

            if let message = appState.statusMessage, appState.panelMode == .actions {
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
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No Actions Repositories")
                .font(.system(size: 13, weight: .semibold))
            Text("Add repos in Actions Settings — this list is separate from Diff.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ActionsRepoAccordion: View {
    @Environment(AppState.self) private var appState
    let repo: WatchedRepo

    private var snap: RepoActionsSnapshot {
        appState.actionsSnapshots[repo.id] ?? .empty
    }

    private var isOpen: Bool {
        appState.isRepoAccordionOpen(repo.id, in: .actions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen {
                Divider()
                content
                    .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        )
    }

    /// Live branch rows are recomputed against a ticking clock so the activity window
    /// (and every running timer underneath) stays honest without a manual refresh.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let activities = appState.branchActivities(for: repo, now: context.date)
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    appState.toggleRepoAccordion(repo.id, in: .actions)
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

                    if let remote = snap.remote {
                        Text(remote.slug)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    Spacer(minLength: 4)

                    let running = activities.filter { $0.state == .running }.count
                    let failed = activities.filter { $0.state == .failed }.count
                    if running > 0 {
                        badge("\(running)", color: Color.orange)
                    }
                    if failed > 0 {
                        badge("\(failed)", color: Color.red.opacity(0.85))
                    }
                    if running == 0, failed == 0, !activities.isEmpty {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .background(Color.primary.opacity(0.06))
            .contextMenu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
                }
                Divider()
                Button("Remove from Actions", role: .destructive) {
                    appState.removeRepo(repo, from: .actions)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = snap.errorMessage, snap.runs.isEmpty, snap.branches.isEmpty {
            message(error, color: .red)
        } else if snap.fetchedAt == nil {
            message(
                appState.isRefreshingActions ? "Loading branches…" : "Press Refresh to load Actions",
                color: .secondary
            )
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let activities = appState.branchActivities(for: repo, now: context.date)
                if activities.isEmpty {
                    message(quietMessage, color: .secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(activities) { activity in
                            BranchRow(activity: activity, now: context.date)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var quietMessage: String {
        switch appState.branchActivityWindow {
        case .all: return "No branches on this remote"
        case .day: return "Nothing touched in the last day"
        case .threeDays: return "Nothing touched in the last 3 days"
        case .week: return "Nothing touched in the last week"
        }
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color)
            .clipShape(Capsule())
    }
}

// MARK: - Branch row

private struct BranchRow: View {
    @Environment(AppState.self) private var appState
    let activity: BranchActivity
    let now: Date

    @State private var isHovered = false

    private var branch: BranchInfo { activity.branch }
    private var isExpanded: Bool { appState.isBranchExpanded(activity.id) }

    /// Passed and cancelled runs are hidden until the row is opened — the whole point.
    private var hiddenRunCount: Int {
        activity.runs.count - activity.attentionRuns.count
    }

    private var visibleRuns: [ActionRun] {
        isExpanded ? activity.runs : activity.attentionRuns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            branchLine
            ForEach(visibleRuns) { run in
                RunLine(run: run, now: now)
            }
        }
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    private var branchLine: some View {
        HStack(spacing: 6) {
            Button {
                guard hiddenRunCount > 0 else { return }
                appState.toggleBranchExpanded(activity.id)
            } label: {
                HStack(spacing: 6) {
                    disclosure
                    BranchStateIcon(state: activity.state)
                        .frame(width: 14, height: 14)
                    Text(branch.name)
                        .font(.system(size: 12, weight: branch.isDefault ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .help(helpText)

            if branch.hasDivergence {
                DivergenceBadge(behind: branch.behind, ahead: branch.ahead)
            }

            if let pr = branch.pullRequest {
                PullRequestPill(pullRequest: pr)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var disclosure: some View {
        if hiddenRunCount > 0 {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 8)
        } else {
            Color.clear.frame(width: 8, height: 8)
        }
    }

    private var helpText: String {
        if hiddenRunCount > 0 {
            return isExpanded
                ? "Hide the \(hiddenRunCount) passing workflow\(hiddenRunCount == 1 ? "" : "s")"
                : "Show \(hiddenRunCount) more workflow\(hiddenRunCount == 1 ? "" : "s") that already passed"
        }
        return branch.name
    }
}

/// One workflow run under a branch: badge, name, and how long it ran.
private struct RunLine: View {
    @Environment(AppState.self) private var appState
    let run: ActionRun
    let now: Date

    var body: some View {
        PressableRow(action: { appState.selectActionRun(run) }, selected: appState.isActionRunSelected(run)) {
            HStack(spacing: 6) {
                ActionStatusIcon(run: run)
                    .frame(width: 12, height: 12)
                WorkflowBadge(kind: run.workflowKind)
                Text(run.workflowName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(GitHubActionsService.formatDuration(run.elapsed(at: now)))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(durationColor)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 4)
    }

    private var durationColor: Color {
        if run.isRunning { return .orange }
        if run.isFailed { return .red }
        if run.isPassed { return .green }
        return .secondary
    }
}

// MARK: - Row components

/// The collapsed answer for a whole branch.
struct BranchStateIcon: View {
    let state: BranchCheckState

    var body: some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
        case .clean:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
        case .idle:
            Image(systemName: "minus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        }
    }
}

/// Commits behind ↓ / ahead ↑ of the default branch. A zero side dims out so the
/// eye only lands on real divergence.
struct DivergenceBadge: View {
    let behind: Int
    let ahead: Int

    var body: some View {
        HStack(spacing: 5) {
            part(symbol: "arrow.down", value: behind)
            part(symbol: "arrow.up", value: ahead)
        }
        .help("\(behind) behind · \(ahead) ahead of the default branch")
    }

    private func part(symbol: String, value: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
            Text("\(value)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(value == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.secondary))
    }
}

/// Open pull request for the branch. Draft reads as an outline, ready-to-merge as solid.
struct PullRequestPill: View {
    @Environment(AppState.self) private var appState
    let pullRequest: BranchPullRequest

    @State private var isHovered = false

    var body: some View {
        Button {
            appState.openPullRequest(pullRequest)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: pullRequest.isDraft ? "arrow.triangle.pull" : "arrow.triangle.merge")
                    .font(.system(size: 8, weight: .semibold))
                Text("#\(pullRequest.number)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(foreground.opacity(isHovered ? 0.55 : 0.28), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
        .help("\(pullRequest.isDraft ? "Draft PR" : "Open PR") #\(pullRequest.number) — \(pullRequest.title)")
    }

    private var foreground: Color {
        pullRequest.isDraft ? Color.secondary : Color.green
    }

    private var background: Color {
        let base = pullRequest.isDraft ? Color.primary : Color.green
        return base.opacity(isHovered ? 0.18 : 0.10)
    }
}

struct WorkflowBadge: View {
    let kind: ActionWorkflowKind

    var body: some View {
        Text(kind.badge)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var foreground: Color {
        switch kind {
        case .cd: return Color.orange
        case .ci: return Color.blue
        case .other: return Color.secondary
        }
    }

    private var background: Color {
        switch kind {
        case .cd: return Color.orange.opacity(0.16)
        case .ci: return Color.blue.opacity(0.14)
        case .other: return Color.primary.opacity(0.08)
        }
    }
}

struct ActionStatusIcon: View {
    let run: ActionRun

    var body: some View {
        if run.isRunning {
            ProgressView()
                .controlSize(.mini)
        } else if run.isFailed {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
        } else if run.isPassed {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
        } else if run.isCancelled {
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}
