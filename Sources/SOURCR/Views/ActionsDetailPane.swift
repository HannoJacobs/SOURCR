import AppKit
import SwiftUI

/// Left pane for a selected Actions run — expands leftward like DiffPane.
struct ActionsDetailPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(SCMTheme.diffBackground)
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if let run = appState.selectedActionDetail?.run ?? appState.selectedActionRun {
                    ActionStatusIcon(run: run)
                    WorkflowBadge(kind: run.workflowKind)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.workflowName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("\(run.headBranch) · \(run.event)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(GitHubActionsService.formatDuration(headerElapsed(at: context.date)))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(run.isRunning ? Color.orange : Color.secondary)
                    HeaderIconButton(systemName: "safari", help: "Open on GitHub") {
                        appState.openSelectedActionOnGitHub()
                    }
                } else {
                    Text("Select a workflow run")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func headerElapsed(at now: Date) -> TimeInterval {
        if let detail = appState.selectedActionDetail {
            return detail.elapsed(at: now)
        }
        return appState.selectedActionRun?.elapsed(at: now) ?? 0
    }

    @ViewBuilder
    private var content: some View {
        if appState.isLoadingActionDetail && appState.selectedActionDetail == nil {
            centeredMessage("Loading run…")
        } else if let detail = appState.selectedActionDetail {
            runDetail(detail)
        } else if appState.selectedActionRun != nil {
            centeredMessage("Loading run…")
        } else {
            centeredMessage("Select a workflow run to inspect steps")
        }
    }

    private func runDetail(_ detail: ActionRunDetail) -> some View {
        VStack(spacing: 0) {
            metaBar(detail)
            progressBar(detail)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(detail.run.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                    if let job = detail.primaryJob {
                        jobSection(job)
                    } else {
                        Text("No jobs reported for this run yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }

                    if detail.jobs.count > 1 {
                        ForEach(detail.jobs.dropFirst()) { job in
                            jobSection(job)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    private func metaBar(_ detail: ActionRunDetail) -> some View {
        HStack(spacing: 12) {
            labelValue("Run", "#\(detail.run.databaseId)")
            if let job = detail.primaryJob {
                labelValue("Job", job.name)
            }
            Spacer()
            Text("\(detail.completedStepCount)/\(max(detail.totalStepCount, 1)) steps")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func labelValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(1)
        }
    }

    private func progressBar(_ detail: ActionRunDetail) -> some View {
        let total = max(detail.totalStepCount, 1)
        let fraction = Double(detail.completedStepCount) / Double(total)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(detail.run.isFailed ? Color.red.opacity(0.75) : Color.orange.opacity(0.85))
                    .frame(width: max(4, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func jobSection(_ job: ActionJob) -> some View {
        let visible = condensedSteps(job.steps)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(job.name)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(job.statusLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))

            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                switch item {
                case .step(let step):
                    stepRow(step)
                case .ellipsis(let count):
                    Text("… \(count) more steps")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                }
                if index < visible.count - 1 {
                    Divider().padding(.leading, 36)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 10)
    }

    private func stepRow(_ step: ActionStep) -> some View {
        HStack(spacing: 8) {
            stepIcon(step)
                .frame(width: 14, height: 14)

            Text(step.name)
                .font(.system(size: 12))
                .foregroundStyle(step.isPending ? Color.secondary.opacity(0.55) : Color.primary)
                .lineLimit(2)

            Spacer(minLength: 8)

            if let duration = step.durationSeconds(), step.isCompleted || step.isInProgress {
                Text(GitHubActionsService.formatDuration(duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(step.isInProgress ? Color.orange : Color.secondary)
            } else if step.isPending {
                Text("—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(step.isInProgress ? Color.orange.opacity(0.08) : Color.clear)
    }

    @ViewBuilder
    private func stepIcon(_ step: ActionStep) -> some View {
        if step.isInProgress {
            ProgressView().controlSize(.mini)
        } else if step.isCompleted && step.isFailure {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
        } else if step.isCompleted && step.isSuccess {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
        } else if step.isCompleted {
            Image(systemName: "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.2)
                .frame(width: 10, height: 10)
        }
    }

    private func centeredMessage(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Keep long CD jobs readable: recent completed + current + upcoming.
    private func condensedSteps(_ steps: [ActionStep]) -> [StepListItem] {
        guard steps.count > 18 else {
            return steps.map { .step($0) }
        }

        let currentIndex = steps.firstIndex(where: \.isInProgress)
            ?? steps.lastIndex(where: \.isCompleted).map { min($0 + 1, steps.count - 1) }
            ?? 0

        let windowStart = max(0, currentIndex - 4)
        let windowEnd = min(steps.count - 1, currentIndex + 8)

        var items: [StepListItem] = []
        if windowStart > 0 {
            items.append(.ellipsis(windowStart))
        }
        for step in steps[windowStart...windowEnd] {
            items.append(.step(step))
        }
        let remaining = steps.count - windowEnd - 1
        if remaining > 0 {
            items.append(.ellipsis(remaining))
        }
        return items
    }
}

private enum StepListItem: Identifiable {
    case step(ActionStep)
    case ellipsis(Int)

    var id: String {
        switch self {
        case .step(let step): return "step-\(step.number)-\(step.name)"
        case .ellipsis(let count): return "ellipsis-\(count)"
        }
    }
}

private extension ActionJob {
    var statusLabel: String {
        if status == "in_progress" { return "in progress" }
        if let conclusion, !conclusion.isEmpty { return conclusion }
        return status
    }
}
