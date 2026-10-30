import AppKit
import SwiftUI

/// One workflow run under a branch: badge, name, and how long it ran.
struct RunLine: View {
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
        .contextMenu {
            Button("Remove") { appState.removeActionRun(run) }
                .help("Permanently ignore this run in SOURCR and its health indicators")
        }
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

/// The branch's pull request, coloured by state the way GitHub does it:
/// green open, grey draft, purple merged, red closed. Click opens it in the browser.
struct PullRequestPill: View {
    @Environment(AppState.self) private var appState
    let pullRequest: BranchPullRequest

    @State private var isHovered = false

    var body: some View {
        Button {
            appState.openPullRequest(pullRequest)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: pullRequest.state.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                Text("#\(pullRequest.number)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(pullRequest.state.tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(pullRequest.state.tint.opacity(isHovered ? 0.22 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(pullRequest.state.tint.opacity(isHovered ? 0.6 : 0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
        .help("\(pullRequest.state.label) #\(pullRequest.number) — \(pullRequest.title)\nClick to open on GitHub")
    }
}

extension PullRequestState {
    var symbolName: String {
        switch self {
        case .open, .draft: return "arrow.triangle.pull"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .open: return .green
        case .draft: return .secondary
        case .merged: return .purple
        case .closed: return .red
        }
    }

    var label: String {
        switch self {
        case .open: return "Open PR"
        case .draft: return "Draft PR"
        case .merged: return "Merged PR"
        case .closed: return "Closed PR"
        }
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
