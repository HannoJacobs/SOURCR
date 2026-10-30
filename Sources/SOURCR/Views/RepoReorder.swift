import SwiftUI

/// Reports each repo row's frame (in the list coordinate space) so drag-reorder
/// can work with variable-height accordions.
private struct RepoFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// What a repo row needs to host the reorder grip.
struct RepoDragHandle {
    let isDragging: Bool
    /// True while any repo in the list is being dragged.
    let reorderActive: Bool
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: () -> Void
}

/// Three-line grip at the start of a repo header; drag it up or down to reorder.
struct RepoDragGrip: View {
    let handle: RepoDragHandle
    @State private var hovered = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(handle.isDragging || hovered ? Color.accentColor : Color.secondary)
            .frame(width: 20, height: 28)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named(RepoReorderStack<EmptyView, EmptyView>.coordinateSpaceName))
                    .onChanged(handle.onChanged)
                    .onEnded { _ in handle.onEnded() }
            )
            .help("Drag up or down to reorder")
    }
}

/// Vertical stack of repo accordions with drag-to-reorder (mirrors NOTR's pin
/// reordering): a floating preview follows the pointer, an accent line marks the
/// drop slot, and the new order is saved for `mode` on release.
struct RepoReorderStack<Row: View, Preview: View>: View {
    static var coordinateSpaceName: String { "repoList" }

    @Environment(AppState.self) private var appState
    let repos: [WatchedRepo]
    let mode: PanelMode
    /// Lets the enclosing ScrollView stop scrolling while a repo is dragged.
    @Binding var isReordering: Bool
    @ViewBuilder var row: (WatchedRepo, RepoDragHandle) -> Row
    @ViewBuilder var preview: (WatchedRepo) -> Preview

    @State private var draggingRepoID: UUID?
    @State private var dragOriginIndex: Int?
    @State private var dragTargetSlot: Int?
    @State private var dragTranslation: CGFloat = 0
    @State private var repoFrames: [UUID: CGRect] = [:]

    var body: some View {
        // Eager VStack so body height measures the full accordion stack
        // (LazyVStack only lays out visible rows and under-reports).
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(repos.enumerated()), id: \.element.id) { index, repo in
                row(repo, RepoDragHandle(
                    isDragging: draggingRepoID == repo.id,
                    reorderActive: draggingRepoID != nil,
                    onChanged: { handleDragChanged(repo: repo, index: index, value: $0) },
                    onEnded: handleDragEnded
                ))
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: RepoFrameKey.self,
                            value: [repo.id: proxy.frame(in: .named(Self.coordinateSpaceName))]
                        )
                    }
                )
                .opacity(draggingRepoID == repo.id ? 0.3 : 1)
                .zIndex(draggingRepoID == repo.id ? 10 : 0)
            }
        }
        .padding(6)
        .coordinateSpace(name: Self.coordinateSpaceName)
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
            if let id = draggingRepoID,
               let repo = repos.first(where: { $0.id == id }),
               let rect = repoFrames[id] {
                preview(repo)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY + dragTranslation)
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleDragChanged(repo: WatchedRepo, index: Int, value: DragGesture.Value) {
        if draggingRepoID == nil {
            draggingRepoID = repo.id
            dragOriginIndex = index
            dragTargetSlot = index
            isReordering = true
        }
        guard draggingRepoID == repo.id else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragTranslation = value.translation.height
        }

        let slot = insertionSlot(forPointerY: value.location.y)
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
        isReordering = false

        guard let origin, let slot else { return }
        let target = slot > origin ? slot - 1 : slot
        if target != origin {
            appState.moveRepo(from: origin, to: target, in: mode)
        }
    }

    private func insertionSlot(forPointerY pointerY: CGFloat) -> Int {
        var slot = 0
        for (i, repo) in repos.enumerated() {
            if let rect = repoFrames[repo.id], pointerY > rect.midY {
                slot = i + 1
            }
        }
        return max(0, min(repos.count, slot))
    }

    private var insertionLineY: CGFloat? {
        guard let origin = dragOriginIndex, let slot = dragTargetSlot,
              slot != origin, slot != origin + 1, !repos.isEmpty
        else { return nil }

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
}
