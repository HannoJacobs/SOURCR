import AppKit
import Darwin
import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    private static let reposKey = "sourcr.watchedRepos"
    private static let diffModeKey = "sourcr.diffViewMode"
    private static let showUnchangedKey = "sourcr.showUnchanged"
    private static let wordWrapKey = "sourcr.wordWrap"

    var repos: [WatchedRepo] = []
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
    var isExpanded = false {
        didSet {
            if isExpanded != oldValue {
                onPanelLayoutChange?()
            }
        }
    }

    @ObservationIgnored var onPanelClose: (() -> Void)?
    @ObservationIgnored var onPanelLayoutChange: (() -> Void)?

    private var refreshTimer: Timer?
    private var fsSources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var repoFDs: [UUID: Int32] = [:]
    private var fsDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshGeneration = 0

    var selectedRepo: WatchedRepo? {
        guard let selectedRepoID else { return repos.first }
        return repos.first { $0.id == selectedRepoID }
    }

    var selectedFile: GitFileEntry? {
        guard let selectedFileID, let diffRepoID, let snap = snapshots[diffRepoID] else { return nil }
        return snap.allListedFiles.first { $0.id == selectedFileID }
    }

    var diffRepo: WatchedRepo? {
        guard let diffRepoID else { return nil }
        return repos.first { $0.id == diffRepoID }
    }

    func isFileSelected(repoID: UUID, entry: GitFileEntry) -> Bool {
        selectedFileID == entry.id && diffRepoID == repoID && isExpanded
    }

    init() {
        loadPrefs()
        refreshAll(force: true)
        startAutoRefresh()
        AppDiagnostics.info(.appState, "AppState initialized repos=\(repos.count)")
    }

    func loadPrefs() {
        if let data = UserDefaults.standard.data(forKey: Self.reposKey),
           let decoded = try? JSONDecoder().decode([WatchedRepo].self, from: data) {
            repos = decoded
        }
        // Always start each launch in the preferred defaults: side-by-side + wrap.
        // (These can still be toggled during a session.)
        diffViewMode = .sideBySide
        wordWrap = true
        if selectedRepoID == nil {
            selectedRepoID = repos.first?.id
        }
    }

    func saveRepos() {
        if let data = try? JSONEncoder().encode(repos) {
            UserDefaults.standard.set(data, forKey: Self.reposKey)
        }
        rewireFileWatchers()
    }

    func addRepo(path: String) {
        Task {
            do {
                let root = try await Task.detached(priority: .userInitiated) {
                    try GitService.resolveRepoRoot(path)
                }.value
                if repos.contains(where: { $0.path == root }) {
                    statusMessage = "Already watching \(URL(fileURLWithPath: root).lastPathComponent)"
                    return
                }
                let repo = WatchedRepo(path: root)
                repos.append(repo)
                selectedRepoID = repo.id
                saveRepos()
                await refreshRepoAsync(repo, force: true)
                AppDiagnostics.info(.appState, "added repo path=\(root)")
            } catch {
                statusMessage = error.localizedDescription
                AppDiagnostics.error(.git, "addRepo failed error=\(error.localizedDescription)")
            }
        }
    }

    func removeRepo(_ repo: WatchedRepo) {
        repos.removeAll { $0.id == repo.id }
        snapshots.removeValue(forKey: repo.id)
        if selectedRepoID == repo.id {
            selectedRepoID = repos.first?.id
        }
        if diffRepoID == repo.id {
            clearSelection()
        }
        saveRepos()
    }

    func selectRepo(_ repo: WatchedRepo) {
        selectedRepoID = repo.id
    }

    func moveRepo(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex != toIndex,
              repos.indices.contains(fromIndex),
              toIndex >= 0, toIndex <= repos.count - 1
        else { return }
        var updated = repos
        let item = updated.remove(at: fromIndex)
        updated.insert(item, at: toIndex)
        repos = updated
        saveRepos()
    }

    func selectFile(_ entry: GitFileEntry, in repo: WatchedRepo) {
        selectedRepoID = repo.id

        if selectedFileID == entry.id && diffRepoID == repo.id && isExpanded {
            clearSelection()
            return
        }

        if entry.kind == .unchanged {
            clearSelection()
            return
        }

        selectedFileID = entry.id
        diffRepoID = repo.id
        isExpanded = true
        Task { await loadDiffAsync(for: entry, in: repo) }
    }

    func clearSelection() {
        selectedFileID = nil
        diffRepoID = nil
        currentDiff = nil
        cachedSideBySideRows = []
        isExpanded = false
    }

    func refreshAll(force: Bool = false) {
        Task { await refreshAllAsync(force: force) }
    }

    func presentOpenPanel() {
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
            panel.message = "Choose one or more git repositories to watch (read-only)"
            panel.prompt = "Add"

            let response = panel.runModal()

            // Always return to menu-bar accessory so we don't linger in the Dock.
            NSApp.setActivationPolicy(previousPolicy == .regular ? .regular : .accessory)
            if previousPolicy != .regular {
                NSApp.setActivationPolicy(.accessory)
            }

            guard response == .OK else { return }
            for url in panel.urls {
                self.addRepo(path: url.path)
            }
        }
    }

    // MARK: - Async git

    private func refreshAllAsync(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
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

            if diffRepoID == repo.id, let entry = selectedFile {
                // Only reload open diff when status actually changed.
                await loadDiffAsync(for: entry, in: repo)
            }
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
        }
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

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        // Slow background poll — FSEvents cover interactive edits; avoid 3s git spam.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isPanelVisible else { return }
                await self.refreshAllAsync(force: false)
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

        for repo in repos {
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
                    guard let live = self.repos.first(where: { $0.id == repoID }) else { return }
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
