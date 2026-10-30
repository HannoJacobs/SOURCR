import Foundation
import Observation
import Security

struct GitHubAccount: Codable, Identifiable, Hashable {
    var login: String
    var id: String { login.lowercased() }
}

struct GitHubCredential: Sendable {
    let login: String
    let token: String
}

enum GitHubAccountError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// Only this service's Keychain items are ever written. No gh login/switch/config writes.
enum SOURCRKeychain {
    static let service = "com.hannojacobs.SOURCR.github"

    private static func query(_ login: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: login.lowercased()]
    }

    static func save(_ credential: GitHubCredential) throws {
        let key = query(credential.login)
        let value = [kSecValueData as String: Data(credential.token.utf8)]
        let status = SecItemUpdate(key as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = key.merging(value) { _, new in new }
            item[kSecAttrLabel as String] = "SOURCR GitHub · \(credential.login)"
            item[kSecAttrSynchronizable as String] = false
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }

    static func load(_ login: String) throws -> GitHubCredential {
        var key = query(login)
        key[kSecReturnData as String] = true
        key[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(key as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw GitHubAccountError.message("Reconnect \(login) in Actions Settings (+). SOURCR will not use another account.")
        }
        try check(status)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw GitHubAccountError.message("Reconnect \(login) in Actions Settings (+).")
        }
        return GitHubCredential(login: login, token: token)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw GitHubAccountError.message("SOURCR could not access its GitHub Keychain item (\(status)). Unlock your login Keychain and try again.")
        }
    }
}

/// A clean child-process environment; never inherit another tool's token, host or debug flags.
enum SOURCRGitHubEnvironment {
    static func base(home: String = NSHomeDirectory()) -> [String: String] {
        ["HOME": home, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
         "LC_ALL": "C", "GH_HOST": "github.com", "GH_PROMPT_DISABLED": "1",
         "GH_NO_UPDATE_NOTIFIER": "1", "GH_PAGER": "cat", "NO_COLOR": "1"]
    }

    static func authenticated(_ credential: GitHubCredential, home: String = NSHomeDirectory()) -> [String: String] {
        var environment = base(home: home)
        environment["GH_CONFIG_DIR"] = home + "/Library/Application Support/SOURCR/GitHubCLI"
        environment["GH_TOKEN"] = credential.token
        return environment
    }

    static var executable: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

@MainActor @Observable
final class GitHubAccounts {
    private static let defaultsKey = "sourcr.githubAccounts"
    private(set) var accounts: [GitHubAccount]
    private(set) var cliLogins: [String] = []
    var discoveryError: String?
    /// Tokens resolved this launch, so each refresh does not hit the CLI or Keychain again.
    private var resolvedCredentials: [String: GitHubCredential] = [:]

    var logins: [String] {
        Array(Set(accounts.map(\.login) + cliLogins)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    init() {
        accounts = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([GitHubAccount].self, from: $0) } ?? []
    }

    func discoverCLIAccounts() async {
        do {
            let logins = try await Task.detached {
                guard let executable = SOURCRGitHubEnvironment.executable else { throw GitHubActionsError.ghNotFound }
                // Status is read-only; only login names are returned, never tokens.
                let output = try ExternalProcess.run(executable: executable,
                    arguments: ["auth", "status", "--hostname", "github.com", "--json", "hosts", "--jq", "[.hosts[][] | .login // empty]"],
                    environment: SOURCRGitHubEnvironment.base(), timeout: 25)
                return try JSONDecoder().decode([String].self, from: Data(output.utf8))
            }.value
            cliLogins = logins
            discoveryError = nil
        } catch {
            discoveryError = "Could not list CLI accounts. You can still connect an account with +."
        }
    }

    func credential(for login: String?) async throws -> GitHubCredential {
        guard let login, !login.isEmpty else {
            throw GitHubAccountError.message("Choose a GitHub account for this repository in Actions Settings.")
        }
        if let cached = resolvedCredentials[login.lowercased()] { return cached }
        // Prefer the gh CLI's own login for this exact account: gh is a stable, already-trusted
        // Keychain client, so SOURCR rebuilds and releases no longer trigger Keychain prompts.
        // Tokens pasted with + live only in SOURCR's Keychain item and remain the fallback.
        let credential = try await Task.detached {
            try (try? Self.cliCredential(for: login)) ?? SOURCRKeychain.load(login)
        }.value
        resolvedCredentials[login.lowercased()] = credential
        return credential
    }

    /// Explicitly selected CLI account. Its token stays in gh; SOURCR only records the login.
    func connectExisting(_ login: String) async throws {
        if accounts.contains(where: { $0.id == login.lowercased() }) {
            _ = try await credential(for: login)
            return
        }
        let credential = try await Task.detached { try Self.cliCredential(for: login) }.value
        let verified = try await Self.validate(token: credential.token)
        guard verified.login.caseInsensitiveCompare(login) == .orderedSame else {
            throw GitHubAccountError.message("The credential does not belong to \(login). Connect the intended account with +.")
        }
        resolvedCredentials[login.lowercased()] = verified
        rememberAccount(login)
    }

    /// Read-only `gh auth token --user`: names the account explicitly, never switches it.
    private nonisolated static func cliCredential(for login: String) throws -> GitHubCredential {
        guard let executable = SOURCRGitHubEnvironment.executable else { throw GitHubActionsError.ghNotFound }
        // Unlike the shared runner, this small secret stays in a pipe in memory,
        // never in process arguments, logs, or a temporary stdout file.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "token", "--hostname", "github.com", "--user", login]
        process.environment = SOURCRGitHubEnvironment.base()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdog.schedule(deadline: .now() + 25)
        watchdog.setEventHandler {
            if process.isRunning { process.terminate() }
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw GitHubAccountError.message("Could not read \(login)'s CLI credential. Connect it with + instead.")
        }
        return GitHubCredential(login: login, token: token)
    }

    func connectToken(_ token: String) async throws -> String {
        let verified = try await Self.validate(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        try await store(verified)
        return verified.login
    }

    private func store(_ credential: GitHubCredential) async throws {
        try await Task.detached { try SOURCRKeychain.save(credential) }.value
        resolvedCredentials[credential.login.lowercased()] = credential
        rememberAccount(credential.login)
    }

    private func rememberAccount(_ login: String) {
        accounts.removeAll { $0.id == login.lowercased() }
        accounts.append(GitHubAccount(login: login))
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private nonisolated static func validate(token: String) async throws -> GitHubCredential {
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else {
            throw GitHubAccountError.message("Enter a GitHub personal access token.")
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SOURCR", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GitHubAccountError.message("GitHub did not accept this token. Check its expiry and account access, then retry.")
        }
        struct User: Decodable { let login: String }
        let user = try JSONDecoder().decode(User.self, from: data)
        return GitHubCredential(login: user.login, token: token)
    }
}
