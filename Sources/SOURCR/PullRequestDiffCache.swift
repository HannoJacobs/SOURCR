import Foundation

struct PullRequestDiffRevision: Hashable, Codable, Sendable {
    let head: String
    let base: String
    let baseName: String
}

struct PullRequestDiffSnapshot {
    let revision: PullRequestDiffRevision
    let files: [PullRequestFile]
    let document: [PRDiffDocumentRow]
}

/// View cancellation only abandons a waiter. The cache owns the shared load.
@MainActor
final class PullRequestDiffCache {
    struct Key: Hashable {
        let account: String
        let repository: String
        let number: Int
    }
    private struct Request: Hashable {
        let key: Key
        let hint: PullRequestDiffRevision
    }
    private struct Entry {
        let hint: PullRequestDiffRevision
        let snapshot: PullRequestDiffSnapshot
    }
    private var entries: [Key: Entry] = [:]
    private var loads: [Request: Task<PullRequestDiffSnapshot, Error>] = [:]
    private var generations: [Key: Int] = [:]

    func cached(key: Key, hint: PullRequestDiffRevision) -> PullRequestDiffSnapshot? {
        guard let entry = entries[key], entry.hint == hint || entry.snapshot.revision == hint else { return nil }
        return entry.snapshot
    }

    func load(key: Key, hint: PullRequestDiffRevision, force: Bool = false,
              loader: @escaping @MainActor () async throws -> PullRequestDiffSnapshot) async throws -> PullRequestDiffSnapshot {
        if !force, let snapshot = cached(key: key, hint: hint) { return snapshot }
        let request = Request(key: key, hint: hint)
        if let load = loads[request] { return try await load.value }
        let generation = (generations[key] ?? 0) + 1
        generations[key] = generation
        let load = Task { @MainActor in
            defer { self.loads[request] = nil }
            let snapshot = try await loader()
            if self.generations[key] == generation {
                self.entries[key] = Entry(hint: hint, snapshot: snapshot)
                AppDiagnostics.info(.appState, "PR diff cached repo=\(key.repository) number=\(key.number) files=\(snapshot.files.count) head=\(snapshot.revision.head) base=\(snapshot.revision.base)")
            }
            return snapshot
        }
        loads[request] = load
        return try await load.value
    }
}

extension PullRequestFilesService {
    static func loadRevision(remote: GitHubRemote, number: Int, credential: GitHubCredential) async throws -> PullRequestDiffRevision {
        struct Response: Decodable {
            struct Ref: Decodable { let sha: String; let ref: String }
            let head: Ref
            let base: Ref
        }
        let json = try await GitHubActionsService.runGH([
            "api", "--method", "GET", "repos/\(remote.slug)/pulls/\(number)"
        ], credential: credential)
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        return .init(head: response.head.sha, base: response.base.sha, baseName: response.base.ref)
    }

    /// Never cache a paginated response spanning two different PR revisions.
    static func loadSnapshot(remote: GitHubRemote, number: Int, hint: PullRequestDiffRevision,
                             credential: GitHubCredential) async throws -> PullRequestDiffSnapshot {
        try await loadSnapshot(hint: hint,
            readRevision: { try await loadRevision(remote: remote, number: number, credential: credential) },
            readFiles: { try await load(remote: remote, number: number, credential: credential) })
    }

    static func loadSnapshot(hint: PullRequestDiffRevision,
                             readRevision: () async throws -> PullRequestDiffRevision,
                             readFiles: () async throws -> [PullRequestFile]) async throws -> PullRequestDiffSnapshot {
        var revision = hint
        if revision.head.isEmpty || revision.base.isEmpty || revision.baseName.isEmpty {
            revision = try await readRevision()
        }
        for _ in 0..<3 {
            let files = try await readFiles()
            let after = try await readRevision()
            if after == revision {
                let document = await Task.detached(priority: .userInitiated) {
                    PRDiffDocumentRow.build(files: files)
                }.value
                return .init(revision: after, files: files, document: document)
            }
            revision = after
        }
        throw GitHubActionsError.invalidJSON("The PR changed repeatedly while loading its files. Retry once commits settle.")
    }
}
