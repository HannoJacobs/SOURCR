import Foundation

/// What a caller asked `/state` for. Every option has a default, so a bare call returns everything.
struct AgentReportOptions: Equatable, Sendable {
    enum View: String, Sendable { case all, diff, branches }
    enum Refresh: String, Sendable {
        /// GitHub data at most ten seconds old; branch metadata at most 45.
        case live
        /// Never contact GitHub: the fastest call, and free of API quota.
        case cached
        /// Fetch everything from GitHub now.
        case force
    }

    var format: AgentReportFormat = .text
    var view: View = .all
    var repoFilter: String?
    var includeDiffs = true
    var refresh: Refresh = .live
    /// Lifts the size caps, and adds job detail for every run rather than only running/failed.
    var full = false

    var maxFileBytes: Int { full ? .max : 200_000 }
    var maxRepoBytes: Int { full ? .max : 2_000_000 }
    var maxFilesPerRepo: Int { full ? .max : 300 }
    var maxRunDetails: Int { full ? .max : 25 }
    /// One git call can take its full timeout; a repository must not take that per file.
    var repoTimeBudget: TimeInterval { full ? 120 : 30 }

    /// How this report is narrowed, or nil when it is the whole app.
    var scope: String? {
        var parts: [String] = []
        if view != .all { parts.append("view=\(view.rawValue)") }
        if let repoFilter { parts.append("repo=\(repoFilter)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Returns a message rather than guessing when a value is misspelled.
    static func parse(query: [String: String], formatFromPath: AgentReportFormat? = nil) -> Result<AgentReportOptions, AgentReportOptionError> {
        var options = AgentReportOptions()
        if let format = formatFromPath { options.format = format }
        if let raw = query["format"] {
            guard let format = AgentReportFormat(rawValue: raw == "markdown" ? "md" : raw) else {
                return .failure(.init(message: "format must be text, md or json"))
            }
            options.format = format
        }
        if let raw = query["view"] {
            guard let view = View(rawValue: raw) else {
                return .failure(.init(message: "view must be all, diff or branches"))
            }
            options.view = view
        }
        if let raw = query["refresh"] {
            guard let refresh = Refresh(rawValue: raw) else {
                return .failure(.init(message: "refresh must be live, cached or force"))
            }
            options.refresh = refresh
        }
        if let raw = query["repo"], !raw.isEmpty { options.repoFilter = raw }
        if let raw = query["diffs"] {
            guard let value = flag(raw) else { return .failure(.init(message: "diffs must be 1 or 0")) }
            options.includeDiffs = value
        }
        if let raw = query["full"] {
            guard let value = flag(raw) else { return .failure(.init(message: "full must be 1 or 0")) }
            options.full = value
        }
        return .success(options)
    }

    private static func flag(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    func matches(_ fields: String?...) -> Bool {
        guard let repoFilter else { return true }
        return fields.contains { $0?.range(of: repoFilter, options: .caseInsensitive) != nil }
    }
}

struct AgentReportOptionError: Error {
    let message: String
}

/// Assembles an `AgentReport`. Local git is always read live; GitHub goes through
/// AppState's refresh so agents and the panel share one set of snapshots and one API budget.
@MainActor
final class AgentReportBuilder {
    private static let runDetailConcurrency = 6

    private let appState: AppState
    /// A finished run attempt never changes, so its jobs need fetching only once.
    private var finishedRunDetails: [String: ActionRunDetail] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    func build(_ options: AgentReportOptions) async -> AgentReport {
        let wantsDiff = options.view != .branches
        let wantsBranches = options.view != .diff

        if wantsBranches, options.refresh != .cached {
            await appState.refreshActionsForAgents(force: options.refresh == .force)
        }

        let diffRepos = wantsDiff ? await loadDiffRepos(options) : nil
        let githubRepos = wantsBranches ? await loadGitHubRepos(options) : nil

        return AgentReport(
            generatedAt: Self.timestamp(Date()) ?? "",
            githubData: options.refresh == .cached ? "cached" : "live",
            scope: options.scope,
            app: .init(
                version: AppDiagnostics.appVersion,
                build: AppDiagnostics.buildVersion,
                bundlePath: Bundle.main.bundleURL.path,
                pid: ProcessInfo.processInfo.processIdentifier,
                logFile: AppDiagnostics.logFilePath
            ),
            interface: interface(options),
            summary: Self.summary(diffRepos: diffRepos ?? [], githubRepos: githubRepos ?? []),
            diffRepos: diffRepos,
            githubRepos: githubRepos
        )
    }

    private func interface(_ options: AgentReportOptions) -> AgentReport.Interface {
        AgentReport.Interface(
            mode: appState.panelMode.rawValue,
            panelVisible: appState.isPanelVisible,
            pinned: appState.isPanelPinned,
            detached: appState.isPanelDetached,
            detailPaneOpen: appState.isExpanded,
            selectedFile: appState.selectedFile?.path,
            selectedRunID: appState.selectedActionRun?.databaseId,
            diffLayout: appState.diffViewMode.rawValue,
            lineWrap: appState.wordWrap,
            statusMessage: appState.statusMessage,
            githubAccounts: appState.githubAccounts.logins,
            pullRequestReview: appState.selectedPullRequest.map {
                .init(url: $0.url, number: $0.number, title: $0.title,
                      loading: appState.isLoadingPullRequest, error: appState.pullRequestError,
                      selectedFile: appState.selectedPullRequestFile,
                      fileLimitReached: appState.pullRequestFiles.count >= 3000,
                      files: reviewFiles(options),
                      collapsedFolders: appState.collapsedPullRequestFolders.sorted(),
                      fileFilter: appState.pullRequestFileFilter)
            }
        )
    }

    private func reviewFiles(_ options: AgentReportOptions) -> [AgentReport.ReviewFile] {
        var budget = options.maxRepoBytes
        return appState.pullRequestFiles.map { file in
            var patch: String?
            var note = file.note
            if options.includeDiffs, let raw = file.patch {
                let limit = min(options.maxFileBytes, budget)
                let bytes = Data(raw.utf8)
                let capped = bytes.count > limit ? Data(bytes.prefix(limit)).upToLastNewline : bytes
                patch = String(decoding: capped, as: UTF8.self)
                budget -= capped.count
                if capped.count < bytes.count {
                    note = [note, "Report patch truncated by size limit; use full=1."].compactMap { $0 }.joined(separator: " ")
                }
            }
            return .init(filename: file.filename, previousFilename: file.previousFilename,
                         status: file.status, additions: file.additions, deletions: file.deletions,
                         patch: patch, note: note)
        }
    }

    // MARK: - Diff

    private func loadDiffRepos(_ options: AgentReportOptions) async -> [AgentReport.DiffRepo] {
        let repos = appState.diffRepos.filter { options.matches($0.displayName, $0.path) }
        let collapsed = appState.diffCollapsedRepoIDs
        return await withTaskGroup(of: (Int, AgentReport.DiffRepo).self) { group in
            for (index, repo) in repos.enumerated() {
                let isCollapsed = collapsed.contains(repo.id)
                group.addTask(priority: .utility) {
                    (index, Self.loadDiffRepo(repo, collapsed: isCollapsed, options: options))
                }
            }
            var loaded: [(Int, AgentReport.DiffRepo)] = []
            for await item in group { loaded.append(item) }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    nonisolated static func loadDiffRepo(_ repo: WatchedRepo, collapsed: Bool, options: AgentReportOptions) -> AgentReport.DiffRepo {
        var result = AgentReport.DiffRepo(
            name: repo.displayName, path: repo.path, branch: nil, head: nil, error: nil,
            collapsedInPanel: collapsed, changes: [], untracked: []
        )
        let snapshot: RepoSnapshot
        do {
            snapshot = try GitService.loadSnapshot(repoPath: repo.path)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        result.branch = snapshot.branch
        result.head = snapshot.headSHA.isEmpty ? nil : snapshot.headSHA

        var budget = ReportBudget(bytes: options.maxRepoBytes, files: options.maxFilesPerRepo,
                                  deadline: Date().addingTimeInterval(options.repoTimeBudget))
        result.changes = snapshot.changes.map { loadFile($0, repoPath: repo.path, options: options, budget: &budget) }
        result.untracked = snapshot.untracked.map { loadFile($0, repoPath: repo.path, options: options, budget: &budget) }
        return result
    }

    private struct ReportBudget {
        var bytes: Int
        var files: Int
        let deadline: Date
    }

    private nonisolated static let fullHint = "add full=1 to lift the limit"

    private nonisolated static func loadFile(_ entry: GitFileEntry, repoPath: String, options: AgentReportOptions, budget: inout ReportBudget) -> AgentReport.File {
        var file = AgentReport.File(path: entry.path, oldPath: entry.oldPath, status: entry.changeType.rawValue)
        guard options.includeDiffs else { return file }
        guard budget.files > 0, budget.bytes > 0, Date() < budget.deadline, !Task.isCancelled else {
            file.note = "Source omitted: this repository's report limit was reached; \(fullHint)."
            return file
        }
        budget.files -= 1
        let limit = min(options.maxFileBytes, budget.bytes)

        if entry.kind == .untracked {
            let (content, note) = readUntracked(repoPath: repoPath, path: entry.path, maxBytes: limit)
            file.content = content
            file.note = note
            budget.bytes -= content?.utf8.count ?? 0
        } else {
            do {
                let output = try GitService.rawDiff(repoPath: repoPath, entry: entry, maxBytes: limit)
                if output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !output.isTruncated {
                    file.note = "No text diff: binary or mode-only change."
                } else {
                    file.diff = output.text
                    if output.isTruncated {
                        file.note = "Diff truncated to \(output.text.utf8.count) of \(output.totalBytes) bytes; \(fullHint)."
                    }
                    budget.bytes -= output.text.utf8.count
                }
            } catch {
                file.note = "Diff unavailable: \(error.localizedDescription)"
            }
        }
        return file
    }

    /// Reads at most `maxBytes`, so a huge untracked artifact never loads into memory,
    /// and only regular files, so an untracked FIFO cannot block the request forever.
    nonisolated static func readUntracked(repoPath: String, path: String, maxBytes: Int) -> (content: String?, note: String?) {
        let fullPath = (repoPath as NSString).appendingPathComponent(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int else {
            return (nil, "Not a readable regular file.")
        }
        guard size > 0 else { return ("", nil) }
        guard let handle = FileHandle(forReadingAtPath: fullPath) else {
            return (nil, "Could not open the file.")
        }
        defer { try? handle.close() }
        let wanted = maxBytes == .max ? size : min(maxBytes, size)
        guard let data = try? handle.read(upToCount: wanted) else {
            return (nil, "Could not read the file.")
        }
        guard !data.contains(0) else { return (nil, "Binary file, \(size) bytes.") }

        guard data.count < size else {
            guard let text = String(data: data, encoding: .utf8) else {
                return (nil, "Not UTF-8 text, \(size) bytes.")
            }
            return (text, nil)
        }
        let cut = data.upToLastNewline
        return (String(decoding: cut, as: UTF8.self), "Content truncated to \(cut.count) of \(size) bytes; \(fullHint).")
    }

    // MARK: - Branches

    private func loadGitHubRepos(_ options: AgentReportOptions) async -> [AgentReport.GitHubRepo] {
        var repos: [AgentReport.GitHubRepo] = []
        var runDetailRequests: [RunDetailRequest] = []
        let now = Date()

        for repo in appState.actionsRepos where options.matches(repo.actionsTitle, repo.displayName, repo.githubRemote?.slug) {
            let snapshot = appState.actionsSnapshots[repo.id] ?? .empty
            let runs = Dictionary(uniqueKeysWithValues: appState.branchActivities(for: repo, now: now, window: .all).map { ($0.branch.name, $0.runs) })
            let report = Self.makeGitHubRepo(
                repo: repo,
                snapshot: snapshot,
                branches: appState.boardBranchSource(for: repo),
                runsByBranch: runs,
                removedRunIDs: appState.excludedRunIDs(for: repo).sorted(),
                hiddenByUser: { self.appState.isBranchHidden($0, in: repo.id) },
                prBadgeHidden: { self.appState.pullRequestExclusions.contains($0) },
                collapsed: appState.branchesCollapsedRepoIDs.contains(repo.id),
                now: now
            )
            for (branchIndex, branch) in report.branches.enumerated() where branch.hiddenReason == nil {
                let branchRuns = runs[branch.name] ?? []
                for (runIndex, run) in branch.runs.enumerated() where options.full || run.state == "running" || run.state == "failed" {
                    guard let source = branchRuns.first(where: { $0.databaseId == run.id }) else { continue }
                    runDetailRequests.append(RunDetailRequest(
                        repoIndex: repos.count, branchIndex: branchIndex, runIndex: runIndex,
                        repo: repo, run: source
                    ))
                }
            }
            repos.append(report)
        }

        // Running work first, then newest: those are the runs an agent is asking about.
        runDetailRequests.sort {
            if $0.run.isRunning != $1.run.isRunning { return $0.run.isRunning }
            return $0.run.isNewerThan($1.run)
        }
        let selected = Array(runDetailRequests.prefix(options.maxRunDetails))
        for request in runDetailRequests.dropFirst(options.maxRunDetails) {
            repos[request.repoIndex].branches[request.branchIndex].runs[request.runIndex].detailNote =
                "Omitted: past the limit of \(options.maxRunDetails) runs; \(Self.fullHint)."
        }
        let cachedOnly = options.refresh == .cached
        for start in stride(from: 0, to: selected.count, by: Self.runDetailConcurrency) {
            let batch = selected[start..<min(start + Self.runDetailConcurrency, selected.count)]
            let results = await withTaskGroup(of: (RunDetailRequest, (jobs: [AgentReport.Job]?, note: String?)).self) { group in
                for request in batch {
                    group.addTask { @MainActor in (request, await self.runDetail(request, cachedOnly: cachedOnly)) }
                }
                var collected: [(RunDetailRequest, (jobs: [AgentReport.Job]?, note: String?))] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (request, result) in results {
                repos[request.repoIndex].branches[request.branchIndex].runs[request.runIndex].jobs = result.jobs
                repos[request.repoIndex].branches[request.branchIndex].runs[request.runIndex].detailNote = result.note
            }
        }
        return repos
    }

    private struct RunDetailRequest {
        let repoIndex: Int
        let branchIndex: Int
        let runIndex: Int
        let repo: WatchedRepo
        let run: ActionRun
    }

    private func runDetail(_ request: RunDetailRequest, cachedOnly: Bool) async -> (jobs: [AgentReport.Job]?, note: String?) {
        let key = "\(request.run.id)#\(request.run.attempt)"
        if let cached = finishedRunDetails[key] { return (Self.makeJobs(cached, now: Date()), nil) }
        guard !cachedOnly else { return (nil, "Not fetched yet, and refresh=cached does not contact GitHub.") }
        guard let remote = request.repo.githubRemote else { return (nil, "No GitHub link for this repository.") }
        do {
            let credential = try await appState.githubAccounts.credential(for: request.repo.githubAccount)
            let detail = try await GitHubActionsService.loadRunDetail(remote: remote, run: request.run, credential: credential)
            if !detail.run.isRunning { finishedRunDetails[key] = detail }
            return (Self.makeJobs(detail, now: Date()), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// Pure mapping from AppState's board to the report, matching what the panel shows.
    nonisolated static func makeGitHubRepo(
        repo: WatchedRepo,
        snapshot: RepoActionsSnapshot,
        branches: [BranchInfo],
        runsByBranch: [String: [ActionRun]],
        removedRunIDs: [Int],
        hiddenByUser: (BranchInfo) -> Bool,
        prBadgeHidden: (BranchPullRequest) -> Bool,
        collapsed: Bool,
        now: Date
    ) -> AgentReport.GitHubRepo {
        let remote = repo.githubRemote ?? snapshot.remote
        return AgentReport.GitHubRepo(
            name: repo.actionsTitle,
            slug: remote?.slug,
            url: remote?.webURL,
            account: repo.githubAccount,
            defaultBranch: snapshot.defaultBranch,
            error: snapshot.errorMessage,
            runsFetchedAt: snapshot.fetchedAt.flatMap(timestamp),
            branchesFetchedAt: snapshot.branchesFetchedAt.flatMap(timestamp),
            collapsedInPanel: collapsed,
            removedRunIDs: removedRunIDs,
            branches: branches.map { branch in
                let runs = runsByBranch[branch.name] ?? []
                let hasHistory = snapshot.runs.contains { $0.headBranch == branch.name }
                let activity = BranchActivity(repoID: repo.id, branch: branch, runs: runs)
                let state = hasHistory ? activity.state : (branch.checkState ?? .idle)
                return AgentReport.Branch(
                    name: branch.name,
                    isDefault: branch.isDefault,
                    url: remote.map { "\($0.webURL)/tree/\(branch.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch.name)" },
                    head: branch.headOID.isEmpty ? nil : branch.headOID,
                    lastCommitAt: timestamp(branch.lastCommitAt),
                    ahead: branch.hasDivergence && !branch.isDefault ? branch.ahead : nil,
                    behind: branch.hasDivergence && !branch.isDefault ? branch.behind : nil,
                    checks: name(state),
                    hiddenReason: branch.isMergedAtHead ? "merged" : (hiddenByUser(branch) ? "hidden_until_updated" : nil),
                    pullRequest: branch.pullRequest.map { pr in
                        AgentReport.PullRequest(
                            number: pr.number, title: pr.title, url: pr.url, state: name(pr.state),
                            head: pr.headOID, updatedAt: pr.updatedAt, badgeHidden: prBadgeHidden(pr)
                        )
                    },
                    runs: runs.sorted(by: runOrder).map { makeRun($0, now: now) }
                )
            }
        )
    }

    /// Same order as the panel: running, then failed, then everything else; newest first in each.
    private nonisolated static func runOrder(_ a: ActionRun, _ b: ActionRun) -> Bool {
        func rank(_ run: ActionRun) -> Int { run.isRunning ? 0 : (run.isFailed ? 1 : 2) }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.isNewerThan(b)
    }

    private nonisolated static func makeRun(_ run: ActionRun, now: Date) -> AgentReport.Run {
        let state = run.isRunning ? "running" : run.isFailed ? "failed" : run.isPassed ? "passed" : run.isCancelled ? "cancelled" : "other"
        return AgentReport.Run(
            id: run.databaseId, workflow: run.workflowName, kind: run.workflowKind.rawValue,
            title: run.displayTitle, event: run.event, state: state, status: run.status,
            conclusion: run.conclusion, attempt: run.attempt,
            startedAt: run.timingStart.flatMap(timestamp),
            elapsedSeconds: Int(run.elapsed(at: now).rounded()), url: run.url, jobs: nil, detailNote: nil
        )
    }

    nonisolated static func makeJobs(_ detail: ActionRunDetail, now: Date) -> [AgentReport.Job] {
        func seconds(_ start: Date?, _ end: Date?) -> Int? {
            guard let start, ActionTiming.isPlausible(start) else { return nil }
            let finish = end.flatMap { ActionTiming.isPlausible($0) ? $0 : nil } ?? now
            return Int(max(0, finish.timeIntervalSince(start)).rounded())
        }
        return detail.jobs.map { job in
            AgentReport.Job(
                name: job.name, status: job.status, conclusion: job.conclusion,
                elapsedSeconds: seconds(job.startedAt, job.completedAt), url: job.url,
                steps: job.steps.map { step in
                    AgentReport.Step(
                        number: step.number, name: step.name, status: step.status, conclusion: step.conclusion,
                        elapsedSeconds: step.durationSeconds(at: now).map { Int($0.rounded()) }
                    )
                }
            )
        }
    }

    nonisolated static func summary(diffRepos: [AgentReport.DiffRepo], githubRepos: [AgentReport.GitHubRepo]) -> AgentReport.Summary {
        var attention: [String] = []
        for repo in diffRepos {
            if let error = repo.error {
                attention.append("\(repo.name): git error: \(error)")
            } else if !repo.changes.isEmpty || !repo.untracked.isEmpty {
                attention.append("\(repo.name): \(repo.changes.count) changed, \(repo.untracked.count) untracked on \(repo.branch ?? "unknown")")
            }
        }
        var running = 0
        var failed = 0
        for repo in githubRepos {
            let label = repo.slug ?? repo.name
            if let error = repo.error { attention.append("\(label): GitHub error: \(error)") }
            for branch in repo.branches where branch.hiddenReason == nil {
                if branch.checks == "running" { running += 1 }
                if branch.checks == "failed" { failed += 1 }
                for run in branch.runs where run.state == "running" || run.state == "failed" {
                    attention.append("\(label) \(branch.name): \(run.workflow) \(run.state) \(run.url)")
                }
                // GitHub's rollup for this head can know more than the newest 50 runs do.
                if ["running", "failed"].contains(branch.checks), !branch.runs.contains(where: { $0.state == branch.checks }) {
                    attention.append("\(label) \(branch.name): checks \(branch.checks) on this head, with no matching run in the newest 50")
                }
            }
        }
        return AgentReport.Summary(
            dirtyRepos: diffRepos.filter { !$0.changes.isEmpty || !$0.untracked.isEmpty }.count,
            changedFiles: diffRepos.reduce(0) { $0 + $1.changes.count },
            untrackedFiles: diffRepos.reduce(0) { $0 + $1.untracked.count },
            runningBranches: running,
            failedBranches: failed,
            attention: attention
        )
    }

    private nonisolated static func name(_ state: BranchCheckState) -> String {
        switch state {
        case .running: return "running"
        case .failed: return "failed"
        case .clean: return "passed"
        case .idle: return "idle"
        }
    }

    private nonisolated static func name(_ state: PullRequestState) -> String {
        switch state {
        case .open: return "open"
        case .draft: return "draft"
        case .merged: return "merged"
        case .closed: return "closed"
        }
    }

    nonisolated static func timestamp(_ date: Date) -> String? {
        guard ActionTiming.isPlausible(date) else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }
}
