import Foundation

enum GitCommandError: LocalizedError {
    case notAGitRepo(String)
    case gitFailed(command: [String], status: Int32, stderr: String)
    case timedOut(command: [String], timeout: TimeInterval)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .notAGitRepo(let path):
            return "Not a git repository: \(path)"
        case .gitFailed(let command, let status, let stderr):
            return "git \(command.joined(separator: " ")) failed (\(status)): \(stderr)"
        case .timedOut(let command, let timeout):
            return "git \(command.joined(separator: " ")) timed out after \(Int(timeout))s"
        case .invalidOutput(let detail):
            return detail
        }
    }
}

/// Strictly read-only git access. Never runs mutating commands.
enum GitService {
    private static let allowedSubcommands: Set<String> = [
        "status", "diff", "show", "rev-parse", "ls-files", "remote", "--version"
    ]

    /// Hard ceiling so a wedged `git status` cannot pin a thread forever.
    static let commandTimeout: TimeInterval = 20

    static func isGitRepository(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return (try? run(in: path, ["rev-parse", "--is-inside-work-tree"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func resolveRepoRoot(_ path: String) throws -> String {
        let root = try run(in: path, ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw GitCommandError.notAGitRepo(path) }
        return root
    }

    /// Read-only remote URL lookup (used to resolve GitHub Actions remotes).
    static func remoteURL(repoPath: String, name: String = "origin") throws -> String {
        try run(in: repoPath, ["remote", "get-url", name])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fast snapshot: one `git status -b` call (branch + porcelain).
    static func loadSnapshot(repoPath: String, includeUnchangedSample: Bool = false) throws -> RepoSnapshot {
        // `-uall` lists every untracked file individually, including those inside
        // entirely-untracked (nested) directories. `-unormal` collapses such a dir
        // into a single `dir/` entry, which then can't produce a real file diff.
        // Git still honors .gitignore, so ignored trees aren't walked.
        let status = try run(
            in: repoPath,
            // -z: raw paths, because the default C-quotes any with a space or non-ASCII byte.
            ["status", "--porcelain=v1", "-z", "-b", "-uall", "--ignore-submodules=dirty"]
        )
        let fingerprint = String(status.hashValue)
        let (branch, changes, untracked) = parseStatusWithBranch(status)

        var unchanged: [GitFileEntry] = []
        if includeUnchangedSample {
            let changedPaths = Set(changes.map(\.path) + untracked.map(\.path))
            unchanged = try loadUnchangedSample(repoPath: repoPath, changedPaths: changedPaths)
        }

        let headSHA = (try? run(in: repoPath, ["rev-parse", "--short", "HEAD"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return RepoSnapshot(
            branch: branch.isEmpty ? "HEAD" : branch,
            headSHA: headSHA,
            changes: changes.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending },
            untracked: untracked.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending },
            unchangedSample: unchanged,
            errorMessage: nil,
            statusFingerprint: fingerprint
        )
    }

    static func loadDiff(repoPath: String, entry: GitFileEntry) throws -> ParsedDiff {
        switch entry.kind {
        case .changed, .staged, .unstaged:
            // Combined working tree vs HEAD (staged + unstaged in one diff).
            let text = try run(in: repoPath, diffArguments(entry))
            return DiffParser.parse(path: entry.path, unifiedDiff: text)
        case .untracked:
            let fullPath = (repoPath as NSString).appendingPathComponent(entry.path)
            let contents = (try? String(contentsOfFile: fullPath, encoding: .utf8)) ?? ""
            return DiffParser.syntheticAddition(path: entry.path, contents: contents)
        case .unchanged:
            return .empty(path: entry.path)
        }
    }

    /// Git's own unified diff against HEAD, before parsing it into rows for the panel.
    static func rawDiff(repoPath: String, entry: GitFileEntry, maxBytes: Int) throws -> CappedOutput {
        try translatingErrors(diffArguments(entry), timeout: commandTimeout) {
            try ExternalProcess.runCapped(executable: gitPath, arguments: diffArguments(entry), currentDirectory: repoPath,
                                          environment: environment, timeout: commandTimeout, maxBytes: maxBytes)
        }
    }

    /// A rename names both paths, so git shows the rename instead of a whole-file addition.
    private static func diffArguments(_ entry: GitFileEntry) -> [String] {
        ["diff", "HEAD", "--no-color", "--no-ext-diff", "--"] + [entry.oldPath, entry.path].compactMap { $0 }
    }

    // MARK: - Private

    private static func loadUnchangedSample(repoPath: String, changedPaths: Set<String>) throws -> [GitFileEntry] {
        let listed = try run(in: repoPath, ["ls-files", "--cached"])
        let paths = listed
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !changedPaths.contains($0) }
            .prefix(40)

        return paths.map {
            GitFileEntry(path: $0, kind: .unchanged, changeType: .unchanged, oldPath: nil)
        }
    }

    private static func parseStatusWithBranch(_ output: String) -> (String, [GitFileEntry], [GitFileEntry]) {
        var branch = "HEAD"
        var byPath: [String: GitFileEntry] = [:]
        var untracked: [GitFileEntry] = []

        var records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let line = records.popFirst() {
            if line.hasPrefix("## ") {
                // ## main...origin/main [ahead 1]
                let rest = String(line.dropFirst(3))
                let head = rest.split(separator: "...", maxSplits: 1, omittingEmptySubsequences: true).first
                    ?? rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
                if let head {
                    branch = String(head)
                }
                continue
            }

            guard line.count >= 3 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            let path = String(line.dropFirst(3))

            if x == "?" && y == "?" {
                untracked.append(GitFileEntry(path: path, kind: .untracked, changeType: .untracked, oldPath: nil))
                continue
            }

            // With -z a rename or copy is two records: new path, then the old one.
            let isRename = "RC".contains(x) || "RC".contains(y)
            let oldPath = isRename ? records.popFirst() : nil
            let code = (y != " " && y != "?") ? y : x
            let type = changeType(for: code)

            // One row per path — staged and/or dirty collapsed together.
            if byPath[path] == nil {
                byPath[path] = GitFileEntry(
                    path: path,
                    kind: .changed,
                    changeType: type == .unknown ? .modified : type,
                    oldPath: oldPath
                )
            } else if type == .deleted || type == .added {
                // Prefer more specific markers if we see them later.
                byPath[path] = GitFileEntry(
                    path: path,
                    kind: .changed,
                    changeType: type,
                    oldPath: oldPath
                )
            }
        }

        return (branch, Array(byPath.values), untracked)
    }

    private static func changeType(for code: Character) -> GitChangeType {
        switch code {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "U": return .unknown
        default: return .unknown
        }
    }

    @discardableResult
    private static func run(
        in workingDirectory: String,
        _ arguments: [String],
        timeout: TimeInterval = commandTimeout
    ) throws -> String {
        guard let head = arguments.first else {
            throw GitCommandError.invalidOutput("Empty git command")
        }

        if !allowedSubcommands.contains(head) {
            throw GitCommandError.invalidOutput("Blocked non-readonly git subcommand: \(head)")
        }

        return try translatingErrors(arguments, timeout: timeout) {
            try ExternalProcess.run(
                executable: gitPath,
                arguments: arguments,
                currentDirectory: workingDirectory,
                environment: environment,
                timeout: timeout
            )
        }
    }

    private static let gitPath = "/usr/bin/git"

    private static let environment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        // Without HOME git skips the global ignore file and lists ignored secrets as untracked.
        "HOME": NSHomeDirectory(),
        // Keep status from taking .git/index.lock, which fails a concurrent commit.
        "GIT_OPTIONAL_LOCKS": "0",
        // A file really named `[x].txt` must not be read as a glob.
        "GIT_LITERAL_PATHSPECS": "1",
        "GIT_PAGER": "cat",
        "GIT_TERMINAL_PROMPT": "0",
        "LC_ALL": "C"
    ]

    private static func translatingErrors<Output>(_ arguments: [String], timeout: TimeInterval, _ body: () throws -> Output) throws -> Output {
        do {
            return try body()
        } catch ExternalProcessError.timedOut(let seconds) {
            throw GitCommandError.timedOut(command: arguments, timeout: seconds)
        } catch ExternalProcessError.failed(let status, let stderr) {
            throw GitCommandError.gitFailed(command: arguments, status: status, stderr: stderr)
        }
    }
}
