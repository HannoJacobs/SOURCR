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

    var repos: [WatchedRepo] = []
    var selectedRepoID: UUID?
    var selectedFileID: String?
    var snapshots: [UUID: RepoSnapshot] = [:]
    var currentDiff: ParsedDiff?
    var diffViewMode: DiffViewMode = .inline {
        didSet { UserDefaults.standard.set(diffViewMode.rawValue, forKey: Self.diffModeKey) }
    }
    var showUnchanged: Bool = false {
        didSet {
            UserDefaults.standard.set(showUnchanged, forKey: Self.showUnchangedKey)
            refreshSelectedRepo()
        }
    }
    var isRefreshing = false
    var statusMessage: String?
    var isExpanded = false

    private var refreshTimer: Timer?
    private var fsSources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var repoFDs: [UUID: Int32] = [:]

    var menuBarIcon: String {
        let total = repos.compactMap { snapshots[$0.id]?.totalChanges }.reduce(0, +)
        if total > 0 {
            return "arrow.triangle.branch"
        }
        return "arrow.triangle.branch"
    }

    var selectedRepo: WatchedRepo? {
        guard let selectedRepoID else { return repos.first }
        return repos.first { $0.id == selectedRepoID }
    }

    var selectedSnapshot: RepoSnapshot {
        guard let id = selectedRepo?.id else { return .empty }
        return snapshots[id] ?? .empty
    }

    var selectedFile: GitFileEntry? {
        guard let selectedFileID else { return nil }
        let snap = selectedSnapshot
        return (snap.staged + snap.unstaged + snap.untracked + snap.unchangedSample)
            .first { $0.id == selectedFileID }
    }

    var sideBySideRows: [SideBySideRow] {
        guard let currentDiff else { return [] }
        return DiffParser.sideBySideRows(from: currentDiff)
    }

    init() {
        loadPrefs()
        refreshAll()
        startAutoRefresh()
        AppDiagnostics.info(.appState, "AppState initialized repos=\(repos.count)")
    }

    func loadPrefs() {
        if let data = UserDefaults.standard.data(forKey: Self.reposKey),
           let decoded = try? JSONDecoder().decode([WatchedRepo].self, from: data) {
            repos = decoded
        }
        if let mode = UserDefaults.standard.string(forKey: Self.diffModeKey),
           let parsed = DiffViewMode(rawValue: mode) {
            diffViewMode = parsed
        }
        showUnchanged = UserDefaults.standard.bool(forKey: Self.showUnchangedKey)
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
        do {
            let root = try GitService.resolveRepoRoot(path)
            if repos.contains(where: { $0.path == root }) {
                statusMessage = "Already watching \(URL(fileURLWithPath: root).lastPathComponent)"
                return
            }
            let repo = WatchedRepo(path: root)
            repos.append(repo)
            selectedRepoID = repo.id
            saveRepos()
            refreshRepo(repo)
            AppDiagnostics.info(.appState, "added repo path=\(root)")
        } catch {
            statusMessage = error.localizedDescription
            AppDiagnostics.error(.git, "addRepo failed error=\(error.localizedDescription)")
        }
    }

    func removeRepo(_ repo: WatchedRepo) {
        repos.removeAll { $0.id == repo.id }
        snapshots.removeValue(forKey: repo.id)
        if selectedRepoID == repo.id {
            selectedRepoID = repos.first?.id
            selectedFileID = nil
            currentDiff = nil
            isExpanded = false
        }
        saveRepos()
        refreshSelectedRepo()
    }

    func selectRepo(_ repo: WatchedRepo) {
        selectedRepoID = repo.id
        selectedFileID = nil
        currentDiff = nil
        isExpanded = false
        refreshRepo(repo)
    }

    func selectFile(_ entry: GitFileEntry) {
        selectedFileID = entry.id
        isExpanded = entry.kind != .unchanged
        loadDiff(for: entry)
    }

    func clearSelection() {
        selectedFileID = nil
        currentDiff = nil
        isExpanded = false
    }

    func refreshAll() {
        isRefreshing = true
        for repo in repos {
            refreshRepo(repo)
        }
        isRefreshing = false
        rewireFileWatchers()
    }

    func refreshSelectedRepo() {
        guard let repo = selectedRepo else { return }
        refreshRepo(repo)
        if let entry = selectedFile {
            loadDiff(for: entry)
        }
    }

    func refreshRepo(_ repo: WatchedRepo) {
        do {
            let snapshot = try GitService.loadSnapshot(
                repoPath: repo.path,
                includeUnchangedSample: showUnchanged
            )
            snapshots[repo.id] = snapshot
            AppDiagnostics.debug(
                .git,
                "snapshot repo=\(repo.displayName) branch=\(snapshot.branch) staged=\(snapshot.staged.count) unstaged=\(snapshot.unstaged.count) untracked=\(snapshot.untracked.count)"
            )
        } catch {
            snapshots[repo.id] = RepoSnapshot(
                branch: "—",
                headSHA: "",
                staged: [],
                unstaged: [],
                untracked: [],
                unchangedSample: [],
                errorMessage: error.localizedDescription
            )
            AppDiagnostics.error(.git, "refresh failed repo=\(repo.path) error=\(error.localizedDescription)")
        }
    }

    func loadDiff(for entry: GitFileEntry) {
        guard let repo = selectedRepo else { return }
        if entry.kind == .unchanged {
            currentDiff = .empty(path: entry.path)
            return
        }
        do {
            currentDiff = try GitService.loadDiff(repoPath: repo.path, entry: entry)
            AppDiagnostics.debug(.git, "diff loaded path=\(entry.path) kind=\(entry.kind.rawValue) lines=\(currentDiff?.lines.count ?? 0)")
        } catch {
            currentDiff = ParsedDiff(
                path: entry.path,
                lines: [
                    DiffLine(id: 0, kind: .meta, text: error.localizedDescription, oldLineNumber: nil, newLineNumber: nil)
                ],
                isBinary: false,
                isEmpty: false
            )
            AppDiagnostics.error(.git, "diff failed path=\(entry.path) error=\(error.localizedDescription)")
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more git repositories to watch (read-only)"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addRepo(path: url.path)
        }
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshAllQuietly()
            }
        }
    }

    private func refreshAllQuietly() {
        for repo in repos {
            refreshRepo(repo)
        }
        if let entry = selectedFile {
            loadDiff(for: entry)
        }
    }

    private func rewireFileWatchers() {
        for (_, source) in fsSources {
            source.cancel()
        }
        fsSources.removeAll()
        repoFDs.removeAll()

        for repo in repos {
            let gitDir = (repo.path as NSString).appendingPathComponent(".git")
            let fd = open(gitDir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib, .extend],
                queue: DispatchQueue.main
            )
            let repoID = repo.id
            let repoPath = repo.path
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if let live = self.repos.first(where: { $0.id == repoID }) {
                        self.refreshRepo(live)
                        if self.selectedRepoID == repoID, let entry = self.selectedFile {
                            self.loadDiff(for: entry)
                        }
                    } else {
                        _ = repoPath
                    }
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
