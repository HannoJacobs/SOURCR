import AppKit
import Darwin
import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    private static let legacyReposKey = "sourcr.watchedRepos"
    private static let diffReposKey = "sourcr.diffRepos"
    private static let actionsReposKey = "sourcr.actionsRepos"
    private static let diffModeKey = "sourcr.diffViewMode"
    private static let showUnchangedKey = "sourcr.showUnchanged"
    private static let wordWrapKey = "sourcr.wordWrap"
    private static let panelModeKey = "sourcr.panelMode"
    private static let panelPinnedKey = "sourcr.panelPinned"
    private static let diffCollapsedKey = "sourcr.diffCollapsedRepos"
    private static let actionsCollapsedKey = "sourcr.actionsCollapsedRepos"

    /// Local SCM / Diff watch list.
    var diffRepos: [WatchedRepo] = []
    /// GitHub Actions watch list (independent of Diff).
    var actionsRepos: [WatchedRepo] = []

    var selectedRepoID: UUID?
    var selectedFileID: String?
    var snapshots: [UUID: RepoSnapshot] = [:]
    var currentDiff: ParsedDiff?
    var cachedSideBySideRows: [SideBySideRow] = []
    var diffViewMode: DiffViewMode = .sideBySide {
        didSet { UserDefaults.standard.set(diffViewMode.rawValue, forKey: Self.diffModeKey) }
    }
    var wordWrap: Bool = true {
        didSet { UserDefaults.standard.set(wordWrap, forKey: Self.wordWrapKey) }
    }
    var diffRepoID: UUID?
    /// Kept off — unchanged-file sampling was removed from the UI.
    private let showUnchanged = false
    var isRefreshing = false
    var statusMessage: String?
    var isPanelVisible = false
    /// When true, the panel stays open while working in other apps (no auto-dismiss).
    var isPanelPinned = false {
        didSet {
            guard isPanelPinned != oldValue else { return }
            UserDefaults.standard.set(isPanelPinned, forKey: Self.panelPinnedKey)
            AppDiagnostics.info(.appState, "panel pin \(isPanelPinned ? "on" : "off")")
            onPanelPinnedChanged?(isPanelPinned)
        }
    }
    var isExpanded = false {
        didSet {
            if isExpanded != oldValue {
                onPanelLayoutChange?()
            }
        }
    }

    /// Ideal height of the scrollable right-column body (repo list / settings).
    /// Drives panel height so collapsed repos don't leave a tall empty panel.
    var scmBodyHeight: CGFloat = 0 {
        didSet {
            guard abs(scmBodyHeight - oldValue) > 0.5 else { return }
            onPanelLayoutChange?()
        }
    }

    /// Window height for the anchored panel (content-fit, capped; taller when detail open).
    var panelHeight: CGFloat {
        let body: CGFloat = scmBodyHeight > 1
            ? min(scmBodyHeight, SOURCRLayout.maxBodyHeight)
            : SOURCRLayout.emptyBodyHeight
        let fitted = SOURCRLayout.chromeHeight + body
        let clamped = min(SOURCRLayout.maxPanelHeight, max(SOURCRLayout.minPanelHeight, fitted))
        if isExpanded {
            return max(clamped, SOURCRLayout.minExpandedPanelHeight)
        }
        return clamped
    }

    func reportSCMBodyHeight(_ height: CGFloat) {
        let next = max(0, height)
        guard abs(next - scmBodyHeight) > 0.5 else { return }
        scmBodyHeight = next
    }

    /// Repo accordion IDs the user has collapsed (default is open).
    var diffCollapsedRepoIDs: Set<UUID> = [] {
        didSet { persistCollapsedRepos(diffCollapsedRepoIDs, key: Self.diffCollapsedKey) }
    }
    var actionsCollapsedRepoIDs: Set<UUID> = [] {
        didSet { persistCollapsedRepos(actionsCollapsedRepoIDs, key: Self.actionsCollapsedKey) }
    }

    func isRepoAccordionOpen(_ repoID: UUID, in mode: PanelMode) -> Bool {
        switch mode {
        case .diff: return !diffCollapsedRepoIDs.contains(repoID)
        case .actions: return !actionsCollapsedRepoIDs.contains(repoID)
        }
    }

    func setRepoAccordionOpen(_ repoID: UUID, in mode: PanelMode, open: Bool) {
        switch mode {
        case .diff:
            if open { diffCollapsedRepoIDs.remove(repoID) }
            else { diffCollapsedRepoIDs.insert(repoID) }
        case .actions:
            if open { actionsCollapsedRepoIDs.remove(repoID) }
            else { actionsCollapsedRepoIDs.insert(repoID) }
        }
    }

    func toggleRepoAccordion(_ repoID: UUID, in mode: PanelMode) {
        setRepoAccordionOpen(repoID, in: mode, open: !isRepoAccordionOpen(repoID, in: mode))
    }

    /// Repos for the currently visible mode.
    var activeRepos: [WatchedRepo] {
        switch panelMode {
        case .diff: return diffRepos
        case .actions: return actionsRepos
        }
    }

    /// Unique repos across both modes (shared identity when the same path is in both).
    var allUniqueRepos: [WatchedRepo] {
        var seen = Set<UUID>()
        return (diffRepos + actionsRepos).filter { seen.insert($0.id).inserted }
    }

    // MARK: Actions mode

    var panelMode: PanelMode = .diff {
        didSet {
            guard panelMode != oldValue else { return }
            UserDefaults.standard.set(panelMode.rawValue, forKey: Self.panelModeKey)
            // Pure UI flip — keep any in-flight Actions list poll (pinned Diff can
            // still watch a long CD). Drop only the detail payload for the other mode.
            collapseDetailIfNeeded()
            clearDiffPayload()
            clearActionPayload()
            actionDetailTask?.cancel()
            actionDetailTask = nil
            actionDetailGeneration += 1
        }
    }

    var actionsSnapshots: [UUID: RepoActionsSnapshot] = [:]
    var selectedActionRunID: String?
    var selectedActionDetail: ActionRunDetail?
    var isLoadingActionDetail = false
    var isRefreshingActions = false

    @ObservationIgnored var onPanelClose: (() -> Void)?
    @ObservationIgnored var onPanelLayoutChange: (() -> Void)?
    /// Hook for StatusPanelController when pin toggles (e.g. unpin while inactive → hide).
    @ObservationIgnored var onPanelPinnedChanged: ((Bool) -> Void)?

    private var refreshTimer: Timer?
    private var fsSources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var repoFDs: [UUID: Int32] = [:]
    private var fsDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var actionDetailGeneration = 0
    private var actionsRefreshGeneration = 0
    @ObservationIgnored private var actionsRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var actionDetailTask: Task<Void, Never>?

    var selectedRepo: WatchedRepo? {
        guard let selectedRepoID else { return activeRepos.first }
        return activeRepos.first { $0.id == selectedRepoID } ?? allUniqueRepos.first { $0.id == selectedRepoID }
    }

    var selectedFile: GitFileEntry? {
        guard let selectedFileID, let diffRepoID, let snap = snapshots[diffRepoID] else { return nil }
        return snap.allListedFiles.first { $0.id == selectedFileID }
    }

    var diffRepo: WatchedRepo? {
        guard let diffRepoID else { return nil }
        return diffRepos.first { $0.id == diffRepoID }
    }

    var selectedActionRun: ActionRun? {
        guard let selectedActionRunID else { return nil }
        for snap in actionsSnapshots.values {
            if let run = snap.runs.first(where: { $0.id == selectedActionRunID }) {
                return run
            }
        }
        return selectedActionDetail?.run
    }

    func repos(for mode: PanelMode) -> [WatchedRepo] {
        switch mode {
        case .diff: return diffRepos
        case .actions: return actionsRepos
        }
    }

    private func setRepos(_ repos: [WatchedRepo], for mode: PanelMode) {
        switch mode {
        case .diff: diffRepos = repos
        case .actions: actionsRepos = repos
        }
    }

    func isFileSelected(repoID: UUID, entry: GitFileEntry) -> Bool {
        panelMode == .diff && selectedFileID == entry.id && diffRepoID == repoID && isExpanded
    }

    func isActionRunSelected(_ run: ActionRun) -> Bool {
        panelMode == .actions && selectedActionRunID == run.id && isExpanded
    }

    init() {
        loadPrefs()
        refreshAll(force: true)
        startAutoRefresh()
        AppDiagnostics.info(
            .appState,
            "AppState initialized diffRepos=\(diffRepos.count) actionsRepos=\(actionsRepos.count)"
        )
    }

    func loadPrefs() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.diffReposKey),
           let decoded = try? JSONDecoder().decode([WatchedRepo].self, from: data) {
            diffRepos = decoded
        }
        if let data = defaults.data(forKey: Self.actionsReposKey),
           let decoded = try? JSONDecoder().decode([WatchedRepo].self, from: data) {
            actionsRepos = decoded
        }

        // Migrate pre-split single list once.
        if diffRepos.isEmpty && actionsRepos.isEmpty,
           let data = defaults.data(forKey: Self.legacyReposKey),
           let decoded = try? JSONDecoder().decode([WatchedRepo].self, from: data) {
            // Diff gets the legacy list; Actions starts empty so repos without
            // workflows aren't force-watched until the user opts in.
            diffRepos = decoded
            saveRepos()
            AppDiagnostics.info(.appState, "migrated \(decoded.count) legacy repos into Diff list")
        }

        // Always start each launch in the preferred defaults: side-by-side + wrap.
        diffViewMode = .sideBySide
        wordWrap = true
        if let raw = defaults.string(forKey: Self.panelModeKey),
           let mode = PanelMode(rawValue: raw) {
            panelMode = mode
        }
        isPanelPinned = defaults.bool(forKey: Self.panelPinnedKey)
        diffCollapsedRepoIDs = loadCollapsedRepos(key: Self.diffCollapsedKey)
        actionsCollapsedRepoIDs = loadCollapsedRepos(key: Self.actionsCollapsedKey)
        pruneCollapsedRepos()
        if selectedRepoID == nil {
            selectedRepoID = activeRepos.first?.id
        }
    }

    func togglePanelPinned() {
        isPanelPinned.toggle()
    }

    private func loadCollapsedRepos(key: String) -> Set<UUID> {
        guard let raw = UserDefaults.standard.stringArray(forKey: key) else { return [] }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func persistCollapsedRepos(_ ids: Set<UUID>, key: String) {
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: key)
    }

    private func pruneCollapsedRepos() {
        let diffIDs = Set(diffRepos.map(\.id))
        let actionsIDs = Set(actionsRepos.map(\.id))
        let nextDiff = diffCollapsedRepoIDs.intersection(diffIDs)
        let nextActions = actionsCollapsedRepoIDs.intersection(actionsIDs)
        if nextDiff != diffCollapsedRepoIDs { diffCollapsedRepoIDs = nextDiff }
        if nextActions != actionsCollapsedRepoIDs { actionsCollapsedRepoIDs = nextActions }
    }

    func saveRepos() {
        if let data = try? JSONEncoder().encode(diffRepos) {
            UserDefaults.standard.set(data, forKey: Self.diffReposKey)
        }
        if let data = try? JSONEncoder().encode(actionsRepos) {
            UserDefaults.standard.set(data, forKey: Self.actionsReposKey)
        }
        rewireFileWatchers()
    }

    func addRepo(path: String, to mode: PanelMode? = nil) {
        let target = mode ?? panelMode
        Task {
            do {
                let root = try await Task.detached(priority: .userInitiated) {
                    try GitService.resolveRepoRoot(path)
                }.value
                var list = repos(for: target)
                if list.contains(where: { $0.path == root }) {
                    statusMessage = "Already in \(target.title): \(URL(fileURLWithPath: root).lastPathComponent)"
                    return
                }
                // Reuse the same identity if the other mode already watches this path.
                let other = target == .diff ? actionsRepos : diffRepos
                let repo = other.first(where: { $0.path == root }) ?? WatchedRepo(path: root)
                list.append(repo)
                setRepos(list, for: target)
                selectedRepoID = repo.id
                saveRepos()
                if target == .diff {
                    await refreshRepoAsync(repo, force: true)
                }
                AppDiagnostics.info(.appState, "added repo mode=\(target.rawValue) path=\(root)")
            } catch {
                statusMessage = error.localizedDescription
                AppDiagnostics.error(.git, "addRepo failed error=\(error.localizedDescription)")
            }
        }
    }

    func removeRepo(_ repo: WatchedRepo, from mode: PanelMode? = nil) {
        let target = mode ?? panelMode
        var list = repos(for: target)
        list.removeAll { $0.id == repo.id }
        setRepos(list, for: target)

        let stillWatched = allUniqueRepos.contains { $0.id == repo.id }
        if !stillWatched {
            snapshots.removeValue(forKey: repo.id)
            actionsSnapshots.removeValue(forKey: repo.id)
        }
        if selectedRepoID == repo.id {
            selectedRepoID = repos(for: target).first?.id
        }
        if target == .diff, diffRepoID == repo.id {
            clearDiffSelection()
        }
        if target == .actions, selectedActionRun?.repoID == repo.id {
            clearActionSelection()
        }
        pruneCollapsedRepos()
        saveRepos()
    }

    func selectRepo(_ repo: WatchedRepo) {
        selectedRepoID = repo.id
    }

    /// Single guarded entry point for swapping the Diff ↔ Actions view tree.
    func setPanelMode(_ mode: PanelMode) {
        guard mode != panelMode else { return }
        panelMode = mode
        if let selectedRepoID,
           !activeRepos.contains(where: { $0.id == selectedRepoID }) {
            self.selectedRepoID = activeRepos.first?.id
        }
    }

    func moveRepo(from fromIndex: Int, to toIndex: Int, in mode: PanelMode? = nil) {
        let target = mode ?? panelMode
        var list = repos(for: target)
        guard fromIndex != toIndex,
              list.indices.contains(fromIndex),
              toIndex >= 0, toIndex <= list.count - 1
        else { return }
        let item = list.remove(at: fromIndex)
        list.insert(item, at: toIndex)
        setRepos(list, for: target)
        saveRepos()
    }

    func selectFile(_ entry: GitFileEntry, in repo: WatchedRepo) {
        guard panelMode == .diff else { return }
        selectedRepoID = repo.id

        if selectedFileID == entry.id && diffRepoID == repo.id && isExpanded {
            clearDiffSelection()
            return
        }

        if entry.kind == .unchanged {
            clearDiffSelection()
            return
        }

        selectedFileID = entry.id
        diffRepoID = repo.id
        isExpanded = true
        Task { await loadDiffAsync(for: entry, in: repo) }
    }

    func selectActionRun(_ run: ActionRun) {
        guard panelMode == .actions else { return }
        selectedRepoID = run.repoID

        if selectedActionRunID == run.id && isExpanded {
            clearActionSelection()
            return
        }

        selectedActionRunID = run.id
        isExpanded = true
        selectedActionDetail = nil
        actionDetailTask?.cancel()
        actionDetailTask = Task { @MainActor in
            await loadActionDetailAsync(for: run)
        }
    }

    func clearSelection() {
        clearDiffSelection()
        clearActionSelection()
    }

    func clearDiffSelection() {
        clearDiffPayload()
        if panelMode == .diff {
            collapseDetailIfNeeded()
        }
    }

    func clearActionSelection() {
        actionDetailTask?.cancel()
        actionDetailTask = nil
        clearActionPayload()
        actionDetailGeneration += 1
        if panelMode == .actions {
            collapseDetailIfNeeded()
        }
    }

    func openSelectedActionOnGitHub() {
        guard let urlString = selectedActionDetail?.run.url ?? selectedActionRun?.url,
              let url = URL(string: urlString), !urlString.isEmpty
        else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshAll(force: Bool = false) {
        // Diff / git only. Actions use `refreshActions()`.
        Task { @MainActor in
            await refreshAllAsync(force: force)
        }
    }

    /// Refresh Diff + Actions together (panel open / foreground).
    func refreshVisibleSurfaces(forceDiff: Bool = true) {
        refreshAll(force: forceDiff)
        refreshActions()
    }

    /// Actions list refresh (manual button, on-show, or auto-poll).
    func refreshActions() {
        guard !actionsRepos.isEmpty else { return }
        // Coalesce: if a refresh is already in flight, let it finish rather than
        // cancelling mid-`gh` and restarting every poll tick.
        if actionsRefreshTask != nil, isRefreshingActions {
            return
        }
        actionsRefreshTask?.cancel()
        actionsRefreshGeneration += 1
        let generation = actionsRefreshGeneration
        actionsRefreshTask = Task { @MainActor in
            await refreshActionsAllAsync(generation: generation)
            if generation == self.actionsRefreshGeneration {
                self.actionsRefreshTask = nil
            }
        }
    }

    /// True when any cached Actions snapshot still has an in-progress run.
    var hasRunningActions: Bool {
        actionsSnapshots.values.contains { snap in
            snap.runs.contains(where: \.isRunning)
        }
    }

    /// Whether the 10s timer should hit GitHub Actions (`gh`).
    private var shouldPollActions: Bool {
        guard isPanelVisible, !actionsRepos.isEmpty else { return false }
        return panelMode == .actions || hasRunningActions
    }

    private func cancelActionsWork() {
        actionsRefreshTask?.cancel()
        actionsRefreshTask = nil
        actionDetailTask?.cancel()
        actionDetailTask = nil
        actionsRefreshGeneration += 1
        actionDetailGeneration += 1
        if isRefreshingActions {
            isRefreshingActions = false
        }
        if isLoadingActionDetail {
            isLoadingActionDetail = false
        }
    }

    private func collapseDetailIfNeeded() {
        if isExpanded {
            isExpanded = false
        }
    }

    private func clearDiffPayload() {
        if selectedFileID != nil {
            selectedFileID = nil
        }
        if diffRepoID != nil {
            diffRepoID = nil
        }
        if currentDiff != nil {
            currentDiff = nil
        }
        if !cachedSideBySideRows.isEmpty {
            cachedSideBySideRows = []
        }
    }

    private func clearActionPayload() {
        if selectedActionRunID != nil {
            selectedActionRunID = nil
        }
        if selectedActionDetail != nil {
            selectedActionDetail = nil
        }
        if isLoadingActionDetail {
            isLoadingActionDetail = false
        }
    }

    func presentOpenPanel(for mode: PanelMode? = nil) {
        let target = mode ?? panelMode
        // LSUIElement / popover context: first NSOpenPanel is often half-dead
        // (grayed Favorites sidebar) unless we dismiss the popover, briefly become
        // a regular app, activate, then restore accessory policy afterward.
        onPanelClose?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.canCreateDirectories = false
            panel.treatsFilePackagesAsDirectories = true
            switch target {
            case .diff:
                panel.message = "Choose git repositories for Diff (read-only)"
            case .actions:
                panel.message = "Choose git repositories for Actions (GitHub origin)"
            }
            panel.prompt = "Add"

            let response = panel.runModal()

            // Always return to menu-bar accessory so we don't linger in the Dock.
            NSApp.setActivationPolicy(previousPolicy == .regular ? .regular : .accessory)
            if previousPolicy != .regular {
                NSApp.setActivationPolicy(.accessory)
            }

            guard response == .OK else { return }
            for url in panel.urls {
                self.addRepo(path: url.path, to: target)
            }
        }
    }

    // MARK: - Async git

    private func refreshAllAsync(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for repo in diffRepos {
                group.addTask { await self.refreshRepoAsync(repo, force: force) }
            }
        }
        rewireFileWatchers()
    }

    private func refreshRepoAsync(_ repo: WatchedRepo, force: Bool) async {
        let path = repo.path
        let includeUnchanged = showUnchanged
        let previous = snapshots[repo.id]?.statusFingerprint

        do {
            let snapshot = try await Task.detached(priority: .utility) {
                try GitService.loadSnapshot(repoPath: path, includeUnchangedSample: includeUnchanged)
            }.value

            if !force, snapshot.statusFingerprint == previous {
                return
            }

            snapshots[repo.id] = snapshot
            AppDiagnostics.debug(
                .git,
                "snapshot repo=\(repo.displayName) branch=\(snapshot.branch) changes=\(snapshot.changes.count) untracked=\(snapshot.untracked.count)"
            )

            await reconcileOpenDiff(afterRefreshing: repo)
        } catch {
            snapshots[repo.id] = RepoSnapshot(
                branch: "—",
                headSHA: "",
                changes: [],
                untracked: [],
                unchangedSample: [],
                errorMessage: error.localizedDescription,
                statusFingerprint: UUID().uuidString
            )
            AppDiagnostics.error(.git, "refresh failed repo=\(repo.path) error=\(error.localizedDescription)")
            if diffRepoID == repo.id {
                clearDiffSelection()
            }
        }
    }

    /// Collapse the left pane when the open file is no longer dirty / listed.
    private func reconcileOpenDiff(afterRefreshing repo: WatchedRepo) async {
        guard panelMode == .diff, diffRepoID == repo.id, selectedFileID != nil else { return }

        // `selectedFile` resolves against the snapshot we just wrote — nil means
        // the path left staged/unstaged/untracked (e.g. user reverted the change).
        guard let entry = selectedFile else {
            AppDiagnostics.info(.appState, "clearing stale diff selection after refresh repo=\(repo.displayName)")
            clearDiffSelection()
            return
        }

        await loadDiffAsync(for: entry, in: repo)
    }

    private func loadDiffAsync(for entry: GitFileEntry, in repo: WatchedRepo) async {
        if entry.kind == .unchanged {
            currentDiff = .empty(path: entry.path)
            cachedSideBySideRows = []
            return
        }

        let path = repo.path
        do {
            let diff = try await Task.detached(priority: .userInitiated) {
                try GitService.loadDiff(repoPath: path, entry: entry)
            }.value
            let rows = await Task.detached(priority: .userInitiated) {
                DiffParser.sideBySideRows(from: diff)
            }.value

            // Drop stale results if selection changed mid-flight.
            guard selectedFileID == entry.id, diffRepoID == repo.id else { return }
            currentDiff = diff
            cachedSideBySideRows = rows
            AppDiagnostics.debug(.git, "diff loaded path=\(entry.path) lines=\(diff.lines.count)")
        } catch {
            guard selectedFileID == entry.id, diffRepoID == repo.id else { return }
            currentDiff = ParsedDiff(
                path: entry.path,
                lines: [
                    DiffLine(id: 0, kind: .meta, text: error.localizedDescription, oldLineNumber: nil, newLineNumber: nil)
                ],
                isBinary: false,
                isEmpty: false
            )
            cachedSideBySideRows = []
            AppDiagnostics.error(.git, "diff failed path=\(entry.path) error=\(error.localizedDescription)")
        }
    }

    // MARK: - Async Actions

    private func refreshActionsAllAsync(generation: Int) async {
        guard generation == actionsRefreshGeneration else { return }
        isRefreshingActions = true
        defer {
            if generation == actionsRefreshGeneration {
                isRefreshingActions = false
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for repo in actionsRepos {
                group.addTask { @MainActor in
                    await self.refreshActionsRepoAsync(repo, generation: generation)
                }
            }
        }

        guard !Task.isCancelled, generation == actionsRefreshGeneration else { return }

        // Detail only when Actions is the visible mode and a run is selected.
        guard panelMode == .actions, let selected = selectedActionRun else { return }
        await loadActionDetailAsync(for: selected)
    }

    private func refreshActionsRepoAsync(_ repo: WatchedRepo, generation: Int) async {
        let path = repo.path
        let repoID = repo.id
        let previous = actionsSnapshots[repoID] ?? .empty

        do {
            let remote = try await Task.detached(priority: .utility) {
                try GitHubActionsService.resolveGitHubRemote(repoPath: path)
            }.value

            try Task.checkCancellation()
            guard generation == actionsRefreshGeneration else { return }

            let runs = try await GitHubActionsService.listRuns(remote: remote, repoID: repoID, limit: 20)

            guard !Task.isCancelled, generation == actionsRefreshGeneration else { return }

            actionsSnapshots[repoID] = RepoActionsSnapshot(
                remote: remote,
                runs: runs,
                errorMessage: nil,
                fetchedAt: Date()
            )
            AppDiagnostics.debug(
                .appState,
                "actions repo=\(repo.displayName) remote=\(remote.slug) runs=\(runs.count) running=\(runs.filter(\.isRunning).count)"
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == actionsRefreshGeneration else { return }
            actionsSnapshots[repoID] = RepoActionsSnapshot(
                remote: previous.remote,
                runs: previous.runs,
                errorMessage: error.localizedDescription,
                fetchedAt: Date()
            )
            AppDiagnostics.error(.appState, "actions refresh failed repo=\(repo.path) error=\(error.localizedDescription)")
        }
    }

    private func loadActionDetailAsync(for run: ActionRun) async {
        guard let repo = actionsRepos.first(where: { $0.id == run.repoID }) else { return }
        let path = repo.path
        actionDetailGeneration += 1
        let generation = actionDetailGeneration
        isLoadingActionDetail = selectedActionDetail == nil
        defer {
            if generation == actionDetailGeneration {
                isLoadingActionDetail = false
            }
        }

        do {
            let remote = try await Task.detached(priority: .utility) {
                try GitHubActionsService.resolveGitHubRemote(repoPath: path)
            }.value

            try Task.checkCancellation()
            guard generation == actionDetailGeneration, selectedActionRunID == run.id else { return }

            let detail = try await GitHubActionsService.loadRunDetail(remote: remote, run: run)

            guard generation == actionDetailGeneration, selectedActionRunID == run.id else { return }
            selectedActionDetail = detail

            // Keep list row in sync with live status/conclusion.
            if var snap = actionsSnapshots[run.repoID] {
                if let idx = snap.runs.firstIndex(where: { $0.id == run.id }) {
                    snap.runs[idx] = detail.run
                    actionsSnapshots[run.repoID] = snap
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == actionDetailGeneration, selectedActionRunID == run.id else { return }
            AppDiagnostics.error(.appState, "action detail failed run=\(run.databaseId) error=\(error.localizedDescription)")
            statusMessage = error.localizedDescription
        }
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        // While the panel is visible: keep Diff fresh, and keep Actions ≤ ~10s
        // stale when watching runs or sitting on the Actions tab (incl. pinned).
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isPanelVisible else { return }
                await self.refreshAllAsync(force: false)
                if self.shouldPollActions {
                    self.refreshActions()
                }
            }
        }
    }

    private func rewireFileWatchers() {
        for (_, source) in fsSources {
            source.cancel()
        }
        fsSources.removeAll()
        repoFDs.removeAll()
        for task in fsDebounceTasks.values {
            task.cancel()
        }
        fsDebounceTasks.removeAll()

        for repo in diffRepos {
            let gitDir = (repo.path as NSString).appendingPathComponent(".git")
            let fd = open(gitDir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib, .extend],
                queue: .main
            )
            let repoID = repo.id
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.fsDebounceTasks[repoID]?.cancel()
                self.fsDebounceTasks[repoID] = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    guard let live = self.diffRepos.first(where: { $0.id == repoID }) else { return }
                    await self.refreshRepoAsync(live, force: false)
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            fsSources[repo.id] = source
            repoFDs[repo.id] = fd
        }
    }
}
