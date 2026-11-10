import Testing
@testable import SOURCR

@MainActor
struct PullRequestDiffCacheTests {
    private let key = PullRequestDiffCache.Key(account: "account", repository: "owner/repo", number: 1)
    private let a = PullRequestDiffRevision(head: "head-a", base: "base-a", baseName: "main")

    private func snapshot(_ revision: PullRequestDiffRevision, path: String = "file.txt") -> PullRequestDiffSnapshot {
        let files = [PullRequestFile(filename: path, previousFilename: nil, status: "added", additions: 1,
                                     deletions: 0, patch: "@@ -0,0 +1 @@\n+line")]
        return .init(revision: revision, files: files, document: PRDiffDocumentRow.build(files: files))
    }

    @Test func repeatedOpenReusesFilesAndParsedDocumentButComparisonChangesReload() async throws {
        let cache = PullRequestDiffCache()
        var loads = 0
        let first = try await cache.load(key: key, hint: a) { loads += 1; return snapshot(a) }
        let second = try await cache.load(key: key, hint: a) { Issue.record("Cache hit invoked loader"); return snapshot(a) }
        #expect(loads == 1)
        #expect(first.document.map(\.id) == second.document.map(\.id))
        for revision in [
            PullRequestDiffRevision(head: "head-b", base: "base-a", baseName: "main"),
            PullRequestDiffRevision(head: "head-b", base: "base-b", baseName: "main"),
            PullRequestDiffRevision(head: "head-b", base: "base-b", baseName: "release")
        ] {
            _ = try await cache.load(key: key, hint: revision) { loads += 1; return snapshot(revision) }
        }
        #expect(loads == 4)
        let otherAccount = PullRequestDiffCache.Key(account: "another", repository: key.repository, number: key.number)
        #expect(cache.cached(key: otherAccount, hint: a) == nil)
    }

    @Test func titleCommentsAndLifecycleMetadataDoNotChangeComparison() {
        let one = BranchPullRequest(number: 1, title: "old", url: "url", state: .draft,
                                    updatedAt: "old", headOID: a.head, baseOID: a.base, baseRefName: a.baseName)
        let two = BranchPullRequest(number: 1, title: "new", url: "url", state: .open,
                                    updatedAt: "new", headOID: a.head, baseOID: a.base, baseRefName: a.baseName)
        #expect(one.diffRevision == two.diffRevision)
    }

    @Test func closingAWaiterKeepsTheSharedLoadAliveForReopening() async throws {
        let cache = PullRequestDiffCache()
        let gate = Gate()
        var loads = 0
        let first = Task {
            try await cache.load(key: key, hint: a) {
                loads += 1
                await gate.pause()
                #expect(!Task.isCancelled)
                return snapshot(a)
            }
        }
        await gate.waitUntilPaused()
        first.cancel()
        let reopened = Task {
            try await cache.load(key: key, hint: a) { loads += 1; return snapshot(a) }
        }
        await Task.yield()
        gate.resume()
        let result = try await reopened.value
        _ = try await first.value
        #expect(result.revision == a)
        #expect(loads == 1)
        #expect(cache.cached(key: key, hint: a) != nil)
    }

    @Test func lateOldLoadCannotReplaceNewerComparison() async throws {
        let cache = PullRequestDiffCache()
        let gate = Gate()
        let b = PullRequestDiffRevision(head: "head-b", base: a.base, baseName: a.baseName)
        let old = Task { try await cache.load(key: key, hint: a) { await gate.pause(); return snapshot(a) } }
        await gate.waitUntilPaused()
        _ = try await cache.load(key: key, hint: b) { snapshot(b, path: "new.txt") }
        gate.resume()
        _ = try await old.value
        #expect(cache.cached(key: key, hint: b)?.files.first?.filename == "new.txt")
        #expect(cache.cached(key: key, hint: a) == nil)
    }

    @Test func failedLoadsCanRetryAndStaleBoardHintsReuseValidatedRevision() async throws {
        enum Failure: Error { case failed }
        let cache = PullRequestDiffCache()
        do {
            _ = try await cache.load(key: key, hint: a) { throw Failure.failed }
            Issue.record("Expected failure")
        } catch {}
        #expect(cache.cached(key: key, hint: a) == nil)
        let b = PullRequestDiffRevision(head: "new", base: a.base, baseName: a.baseName)
        _ = try await cache.load(key: key, hint: a) { snapshot(b) }
        #expect(cache.cached(key: key, hint: a)?.revision == b)
        #expect(cache.cached(key: key, hint: b)?.revision == b)
    }

    @Test func changingCommitsDuringPaginationRequiresAnotherConsistentDownload() async throws {
        let b = PullRequestDiffRevision(head: "new", base: a.base, baseName: a.baseName)
        var downloads = 0
        let result = try await PullRequestFilesService.loadSnapshot(hint: a, readRevision: { b }, readFiles: {
            downloads += 1
            return snapshot(downloads == 1 ? a : b, path: downloads == 1 ? "old.txt" : "new.txt").files
        })
        #expect(downloads == 2)
        #expect(result.revision == b)
        #expect(result.files.first?.filename == "new.txt")
        #expect(result.document.allSatisfy { $0.filePath == "new.txt" })
    }

    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
        }
        func waitUntilPaused() async {
            if continuation != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func resume() { continuation?.resume(); continuation = nil }
    }
}
