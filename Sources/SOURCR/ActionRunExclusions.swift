import Foundation

/// Local exclusions use GitHub identity, independent of a saved watch's UUID.
struct ActionRunExclusions {
    private static let preferencesKey = "sourcr.excludedActionRuns"
    private var keys: Set<String>

    init(defaults: UserDefaults = .standard) {
        keys = Set(defaults.stringArray(forKey: Self.preferencesKey) ?? [])
    }

    func contains(_ run: ActionRun, remote: GitHubRemote) -> Bool {
        keys.contains(Self.key(run, remote: remote))
    }

    mutating func remove(_ run: ActionRun, remote: GitHubRemote, defaults: UserDefaults = .standard) {
        keys.insert(Self.key(run, remote: remote))
        defaults.set(keys.sorted(), forKey: Self.preferencesKey)
    }

    private static func key(_ run: ActionRun, remote: GitHubRemote) -> String {
        "\(remote.identity):\(run.databaseId)"
    }
}
