import Foundation

struct PullRequestChangeSummary: Codable, Sendable {
    let fileCount: Int
    let additions: Int
    let deletions: Int
    let lineChanges: Int

    init(files: [PullRequestFile]) {
        fileCount = files.count
        additions = files.reduce(0) { $0 + $1.additions }
        deletions = files.reduce(0) { $0 + $1.deletions }
        lineChanges = additions + deletions
    }
}

struct PullRequestFile: Codable, Identifiable, Sendable {
    var id: String { filename }
    let filename: String
    let previousFilename: String?
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String?

    enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, patch
        case previousFilename = "previous_filename"
    }

    var note: String? {
        guard let patch, !patch.isEmpty else {
            return "GitHub supplied no text patch (binary, renamed-only, or too large). Open on GitHub for the full file."
        }
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.filter({ $0.hasPrefix("+") }).count < additions ||
            lines.filter({ $0.hasPrefix("-") }).count < deletions {
            return "GitHub supplied a partial patch. Open on GitHub for the remaining changes."
        }
        return nil
    }
}

enum PullRequestFilesService {
    /// GitHub caps this endpoint at 3,000 files. Keep that limit visible to callers.
    static func load(remote: GitHubRemote, number: Int, credential: GitHubCredential) async throws -> [PullRequestFile] {
        var files: [PullRequestFile] = []
        for page in 1...30 {
            try Task.checkCancellation()
            let json = try await GitHubActionsService.runGH([
                "api", "--method", "GET",
                "repos/\(remote.slug)/pulls/\(number)/files?per_page=100&page=\(page)"
            ], credential: credential)
            let batch = try JSONDecoder().decode([PullRequestFile].self, from: Data(json.utf8))
            files.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return files
    }
}
