import AppKit
import SwiftUI

/// Right-column GitHub Actions list. Chrome (refresh/add/settings) lives above in MenuBarView.
struct ActionsSCMView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if appState.actionsRepos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.actionsRepos) { repo in
                            ActionsRepoAccordion(repo: repo)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
            }

            if let message = appState.statusMessage, appState.panelMode == .actions {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
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
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ActionsRepoAccordion: View {
    @Environment(AppState.self) private var appState
    let repo: WatchedRepo

    @State private var isOpen = true

    private var snap: RepoActionsSnapshot {
        appState.actionsSnapshots[repo.id] ?? .empty
    }

    /// Newest run per workflow name (running replaces prior pass/fail for that type).
    private var displayRuns: [ActionRun] { snap.latestRunsByWorkflow }

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

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                isOpen.toggle()
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
                }

                Spacer(minLength: 4)

                if snap.runningCount > 0 {
                    badge("\(snap.runningCount)", color: Color.orange)
                } else if snap.failedCount > 0 {
                    badge("\(snap.failedCount)", color: Color.red.opacity(0.85))
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

    @ViewBuilder
    private var content: some View {
        if let error = snap.errorMessage, snap.runs.isEmpty {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else if snap.fetchedAt == nil {
            Text(appState.isRefreshingActions ? "Loading Actions…" : "Press Refresh to load Actions")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else if displayRuns.isEmpty {
            Text("No workflow runs")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(displayRuns) { run in
                    ActionRunRow(run: run)
                }
            }
            .padding(.top, 4)
        }
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

private struct ActionRunRow: View {
    @Environment(AppState.self) private var appState
    let run: ActionRun

    var body: some View {
        if run.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                row(now: context.date)
            }
        } else {
            row(now: Date())
        }
    }

    private func row(now: Date) -> some View {
        let selected = appState.isActionRunSelected(run)
        return PressableRow(action: {
            appState.selectActionRun(run)
        }, selected: selected) {
            HStack(alignment: .top, spacing: 8) {
                ActionStatusIcon(run: run)
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        WorkflowBadge(kind: run.workflowKind)
                        Text(run.workflowName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    Text("\(run.headBranch) · \(run.event.isEmpty ? "workflow" : run.event) · \(shortTitle)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(timeLabel(at: now))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(timeColor)
                    .padding(.top, 1)
            }
            .padding(.leading, 4)
        }
    }

    private var shortTitle: String {
        let t = run.displayTitle
        if t.count <= 36 { return t }
        return String(t.prefix(34)) + "…"
    }

    private func timeLabel(at now: Date) -> String {
        if run.isRunning {
            return GitHubActionsService.formatDuration(run.elapsed(at: now))
        }
        if run.isFailed {
            return "fail"
        }
        if run.isPassed {
            return "pass"
        }
        if run.isCancelled {
            return "cancel"
        }
        return GitHubActionsService.formatDuration(run.elapsed(at: now))
    }

    private var timeColor: Color {
        if run.isRunning { return .orange }
        if run.isFailed { return .red }
        if run.isPassed { return .green }
        return .secondary
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
