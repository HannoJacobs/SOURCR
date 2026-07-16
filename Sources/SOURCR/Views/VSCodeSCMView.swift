import AppKit
import SwiftUI

/// Reports each repo row's frame (in the list coordinate space) so drag-reorder
/// can work with variable-height accordions.
private struct RepoFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// VS Code–style multi-repo Source Control accordion (right pane).
struct VSCodeSCMView: View {
    @Environment(AppState.self) private var appState
    var onOpenSettings: () -> Void = {}

    // Drag-to-reorder state (mirrors NOTR's pin reordering).
    @State private var draggingRepoID: UUID?
    @State private var dragOriginIndex: Int?
    @State private var dragTargetSlot: Int?
    @State private var dragTranslation: CGFloat = 0
    @State private var repoFrames: [UUID: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(appState.repos.enumerated()), id: \.element.id) { index, repo in
                        RepoAccordion(
                            repo: repo,
                            index: index,
                            isDragging: draggingRepoID == repo.id,
                            reorderActive: draggingRepoID != nil,
                            onDragChanged: { idx, value in handleDragChanged(repo: repo, index: idx, value: value) },
                            onDragEnded: { handleDragEnded() }
                        )
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: RepoFrameKey.self,
                                    value: [repo.id: proxy.frame(in: .named("repoList"))]
                                )
                            }
                        )
                        .opacity(draggingRepoID == repo.id ? 0.3 : 1)
                        .zIndex(draggingRepoID == repo.id ? 10 : 0)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .coordinateSpace(name: "repoList")
                .onPreferenceChange(RepoFrameKey.self) { repoFrames = $0 }
                .overlay(alignment: .topLeading) {
                    if let lineY = insertionLineY {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .padding(.horizontal, 10)
                            .offset(y: lineY)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    dragPreview
                }
            }
            .scrollDisabled(draggingRepoID != nil)

            if let message = appState.statusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(8)
            }

            Divider()
            HStack(spacing: 6) {
                HeaderIconButton(
                    systemName: "arrow.clockwise",
                    help: "Refresh",
                    spinning: appState.isRefreshing
                ) {
                    appState.refreshAll(force: true)
                }
                HeaderIconButton(systemName: "folder.badge.plus", help: "Add Repository") {
                    appState.presentOpenPanel()
                }
                HeaderIconButton(systemName: "gearshape", help: "Settings") {
                    onOpenSettings()
                }
                Spacer()
                Button {
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Text("Quit")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    // MARK: - Drag reorder

    private func handleDragChanged(repo: WatchedRepo, index: Int, value: DragGesture.Value) {
        if draggingRepoID == nil {
            draggingRepoID = repo.id
            dragOriginIndex = index
            dragTargetSlot = index
        }
        guard draggingRepoID == repo.id else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragTranslation = value.translation.height
        }

        let pointerY = value.location.y
        let slot = insertionSlot(forPointerY: pointerY)
        if slot != dragTargetSlot {
            withTransaction(transaction) { dragTargetSlot = slot }
        }
    }

    private func handleDragEnded() {
        let origin = dragOriginIndex
        let slot = dragTargetSlot

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draggingRepoID = nil
            dragOriginIndex = nil
            dragTargetSlot = nil
            dragTranslation = 0
        }

        guard let origin, let slot else { return }
        // Convert an insertion slot (0...count) into a destination index.
        let target = slot > origin ? slot - 1 : slot
        if target != origin {
            appState.moveRepo(from: origin, to: target)
        }
    }

    /// Number of repos whose vertical center sits above the pointer.
    private func insertionSlot(forPointerY pointerY: CGFloat) -> Int {
        var slot = 0
        for (i, repo) in appState.repos.enumerated() {
            if let rect = repoFrames[repo.id], pointerY > rect.midY {
                slot = i + 1
            }
        }
        return max(0, min(appState.repos.count, slot))
    }

    /// Y offset of the insertion marker; nil when it wouldn't change the order.
    private var insertionLineY: CGFloat? {
        guard let origin = dragOriginIndex, let slot = dragTargetSlot,
              slot != origin, slot != origin + 1
        else { return nil }

        let repos = appState.repos
        if slot <= 0 {
            return (repoFrames[repos[0].id]?.minY ?? 0) - 4
        }
        if slot >= repos.count {
            return (repoFrames[repos[repos.count - 1].id]?.maxY ?? 0) + 3
        }
        let above = repoFrames[repos[slot - 1].id]?.maxY ?? 0
        let below = repoFrames[repos[slot].id]?.minY ?? above
        return (above + below) / 2
    }

    @ViewBuilder
    private var dragPreview: some View {
        if let id = draggingRepoID,
           let repo = appState.repos.first(where: { $0.id == id }),
           let rect = repoFrames[id] {
            RepoDragPreview(repo: repo, snap: appState.snapshots[id] ?? .empty)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY + dragTranslation)
                .allowsHitTesting(false)
        }
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
    let index: Int
    var isDragging: Bool = false
    var reorderActive: Bool = false
    var onDragChanged: (Int, DragGesture.Value) -> Void = { _, _ in }
    var onDragEnded: () -> Void = {}

    @State private var isOpen = true
    @State private var headerHovered = false
    @State private var gripHovered = false

    private var snap: RepoSnapshot {
        appState.snapshots[repo.id] ?? .empty
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
        .onAppear {
            isOpen = snap.totalChanges > 0 || appState.repos.count <= 2
        }
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isDragging || gripHovered ? Color.accentColor : Color.secondary)
            .frame(width: 20, height: 28)
            .contentShape(Rectangle())
            .onHover { gripHovered = $0 }
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("repoList"))
                    .onChanged { onDragChanged(index, $0) }
                    .onEnded { _ in onDragEnded() }
            )
            .help("Drag up or down to reorder")
    }

    private var header: some View {
        HStack(spacing: 4) {
            grip

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
            .disabled(reorderActive)
        }
        .background(headerHovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.06))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
            }
            Button(isOpen ? "Collapse" : "Expand") {
                isOpen.toggle()
            }
            Divider()
            Button("Remove from SOURCR", role: .destructive) {
                appState.removeRepo(repo)
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
