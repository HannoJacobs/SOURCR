import Foundation

/// Dismiss a PR revision locally; a remote update makes its badge eligible again.
struct PullRequestExclusions {
    private static let preferencesKey = "sourcr.hiddenPullRequests"
    private var revisions: [String: String]

    init(defaults: UserDefaults = .standard) {
        revisions = defaults.dictionary(forKey: Self.preferencesKey) as? [String: String] ?? [:]
    }

    func contains(_ pr: BranchPullRequest) -> Bool {
        !pr.url.isEmpty && revisions[pr.url.lowercased()] == pr.exclusionRevision
    }

    mutating func hide(_ pr: BranchPullRequest, defaults: UserDefaults = .standard) {
        guard !pr.url.isEmpty else { return }
        revisions[pr.url.lowercased()] = pr.exclusionRevision
        defaults.set(revisions, forKey: Self.preferencesKey)
    }
}
