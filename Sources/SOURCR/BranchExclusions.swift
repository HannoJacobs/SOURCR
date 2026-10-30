import Foundation

/// Hide one observed head, never a branch forever. Identity survives watch recreation.
struct BranchExclusions {
    private static let preferencesKey = "sourcr.hiddenBranchHeads"
    private var heads: [String: String]

    init(defaults: UserDefaults = .standard) {
        heads = defaults.dictionary(forKey: Self.preferencesKey) as? [String: String] ?? [:]
    }

    func contains(_ branch: BranchInfo, remote: GitHubRemote) -> Bool {
        !branch.headOID.isEmpty && heads[key(branch, remote: remote)] == branch.headOID
    }

    mutating func hide(_ branch: BranchInfo, remote: GitHubRemote, defaults: UserDefaults = .standard) {
        guard !branch.headOID.isEmpty else { return }
        heads[key(branch, remote: remote)] = branch.headOID
        defaults.set(heads, forKey: Self.preferencesKey)
    }

    private func key(_ branch: BranchInfo, remote: GitHubRemote) -> String {
        // Length prefix makes the boundary unambiguous for every legal branch name.
        "\(remote.identity.count):\(remote.identity)\(branch.name)"
    }
}
