import Foundation

enum GitCommandError: LocalizedError {
    case notAGitRepo(String)
    case gitFailed(command: [String], status: Int32, stderr: String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .notAGitRepo(let path):
            return "Not a git repository: \(path)"
        case .gitFailed(let command, let status, let stderr):
            return "git \(command.joined(separator: " ")) failed (\(status)): \(stderr)"
        case .invalidOutput(let detail):
            return detail
        }
    }
}

/// Strictly read-only git access. Never runs mutating commands.
enum GitService {
    private static let allowedSubcommands: Set<String> = [
        "status", "diff", "show", "rev-parse", "ls-files", "--version"
    ]

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

    /// Fast snapshot: one `git status -b` call (branch + porcelain).
    static func loadSnapshot(repoPath: String, includeUnchangedSample: Bool = false) throws -> RepoSnapshot {
        // `-unormal` avoids walking every file inside untracked dirs (much faster than `-uall`).
        let status = try run(
            in: repoPath,
            ["status", "--porcelain=v1", "-b", "-unormal", "--ignore-submodules=dirty"]
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
            let text = try run(in: repoPath, ["diff", "HEAD", "--no-color", "--", entry.path])
            return DiffParser.parse(path: entry.path, unifiedDiff: text)
        case .untracked:
            let fullPath = (repoPath as NSString).appendingPathComponent(entry.path)
            let contents = (try? String(contentsOfFile: fullPath, encoding: .utf8)) ?? ""
            return DiffParser.syntheticAddition(path: entry.path, contents: contents)
        case .unchanged:
            return .empty(path: entry.path)
        }
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

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
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
            let rest = String(line.dropFirst(3))

            if x == "?" && y == "?" {
                untracked.append(GitFileEntry(path: rest, kind: .untracked, changeType: .untracked, oldPath: nil))
                continue
            }

            let (path, oldPath) = parsePath(rest)
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

    private static func parsePath(_ rest: String) -> (String, String?) {
        if rest.contains(" -> ") {
            let parts = rest.components(separatedBy: " -> ")
            if parts.count == 2 {
                return (parts[1], parts[0])
            }
        }
        return (rest, nil)
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
    private static func run(in workingDirectory: String, _ arguments: [String]) throws -> String {
        guard let head = arguments.first else {
            throw GitCommandError.invalidOutput("Empty git command")
        }

        if !allowedSubcommands.contains(head) {
            throw GitCommandError.invalidOutput("Blocked non-readonly git subcommand: \(head)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "GIT_PAGER": "cat",
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw GitCommandError.gitFailed(
                command: arguments,
                status: process.terminationStatus,
                stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return out
    }
}
