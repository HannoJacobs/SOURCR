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

/// Strictly read-only git access. Never runs mutating commands
/// (no checkout, commit, push, add, reset, stash, branch, etc.).
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
        return (try? run(in: path, ["rev-parse", "--is-inside-work-tree"]))?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func resolveRepoRoot(_ path: String) throws -> String {
        let root = try run(in: path, ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { throw GitCommandError.notAGitRepo(path) }
        return root
    }

    static func loadSnapshot(repoPath: String, includeUnchangedSample: Bool = true) throws -> RepoSnapshot {
        let root = try resolveRepoRoot(repoPath)
        let branch = try run(in: root, ["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headSHA = (try? run(in: root, ["rev-parse", "--short", "HEAD"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let porcelain = try run(in: root, ["status", "--porcelain=v1", "-uall", "--ignore-submodules=dirty"])
        let (staged, unstaged, untracked) = parsePorcelain(porcelain)

        var unchanged: [GitFileEntry] = []
        if includeUnchangedSample {
            unchanged = try loadUnchangedSample(repoPath: root, changedPaths: Set(
                staged.map(\.path) + unstaged.map(\.path) + untracked.map(\.path)
            ))
        }

        return RepoSnapshot(
            branch: branch.isEmpty ? "HEAD" : branch,
            headSHA: headSHA,
            staged: staged.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending },
            unstaged: unstaged.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending },
            untracked: untracked.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending },
            unchangedSample: unchanged,
            errorMessage: nil
        )
    }

    static func loadDiff(repoPath: String, entry: GitFileEntry) throws -> ParsedDiff {
        let root = try resolveRepoRoot(repoPath)

        switch entry.kind {
        case .staged:
            let text = try run(in: root, ["diff", "--cached", "--no-color", "--", entry.path])
            return DiffParser.parse(path: entry.path, unifiedDiff: text)
        case .unstaged:
            let text = try run(in: root, ["diff", "--no-color", "--", entry.path])
            return DiffParser.parse(path: entry.path, unifiedDiff: text)
        case .untracked:
            let contents = (try? String(contentsOfFile: (root as NSString).appendingPathComponent(entry.path), encoding: .utf8)) ?? ""
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

    private static func parsePorcelain(_ output: String) -> ([GitFileEntry], [GitFileEntry], [GitFileEntry]) {
        var staged: [GitFileEntry] = []
        var unstaged: [GitFileEntry] = []
        var untracked: [GitFileEntry] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.count >= 3 else { continue }

            let xy = line.prefix(2)
            let x = xy.first!
            let y = xy.dropFirst().first!
            let rest = String(line.dropFirst(3))

            if x == "?" && y == "?" {
                untracked.append(GitFileEntry(path: rest, kind: .untracked, changeType: .untracked, oldPath: nil))
                continue
            }

            let (path, oldPath) = parsePath(rest)

            if x != " " && x != "?" {
                staged.append(GitFileEntry(
                    path: path,
                    kind: .staged,
                    changeType: changeType(for: x),
                    oldPath: oldPath
                ))
            }

            if y != " " && y != "?" {
                unstaged.append(GitFileEntry(
                    path: path,
                    kind: .unstaged,
                    changeType: changeType(for: y),
                    oldPath: oldPath
                ))
            }
        }

        return (staged, unstaged, untracked)
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

        // Defense in depth: only allow known read-only subcommands.
        let sub = head.hasPrefix("-") ? head : head
        if !allowedSubcommands.contains(sub) && !["status", "diff", "show", "rev-parse", "ls-files"].contains(sub) {
            throw GitCommandError.invalidOutput("Blocked non-readonly git subcommand: \(sub)")
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
