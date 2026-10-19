import Foundation
import Testing
@testable import SOURCR

struct GitHubAccountPersistenceTests {
    @Test func repositoryAccountsSurviveJSONRoundTripIndependently() throws {
        var personal = WatchedRepo(remote: GitHubRemote(owner: "HannoJacobs", name: "SOURCR"))
        personal.githubAccount = "HannoJacobs"
        var work = WatchedRepo(remote: GitHubRemote(owner: "hb-innovation-lab", name: "PPA-Wrapper"))
        work.githubAccount = "HannoJacobsHB"

        let data = try JSONEncoder().encode([personal, work])
        let restored = try JSONDecoder().decode([WatchedRepo].self, from: data)

        #expect(restored == [personal, work])
        #expect(restored.map(\.githubAccount) == ["HannoJacobs", "HannoJacobsHB"])
        // Repository preferences contain a binding, never the credential itself.
        let encoded = try #require(String(data: data, encoding: .utf8))
        #expect(!encoded.contains("token"))
    }

    @Test func legacyRepositoryDecodesWithoutSelectingAnAccount() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id)","path":"/missing/checkout","displayName":"Old watch"}
        """.utf8)
        let restored = try JSONDecoder().decode(WatchedRepo.self, from: data)
        #expect(restored.id == id)
        #expect(restored.githubAccount == nil)
        #expect(restored.githubRemote == nil)
    }

    @Test func changingRepositoryLinkPreservesItsIdentityAndAccount() {
        var original = WatchedRepo(path: "/missing/checkout", displayName: "My CI")
        original.githubAccount = "HannoJacobsHB"
        let linked = original.linked(to: GitHubRemote(owner: "hb-innovation-lab", name: "PPA-Wrapper"))

        #expect(linked.id == original.id)
        #expect(linked.displayName == "My CI")
        #expect(linked.githubAccount == "HannoJacobsHB")
        #expect(linked.githubRemote?.slug == "hb-innovation-lab/PPA-Wrapper")
        #expect(original.path == "/missing/checkout")
    }

    @Test func migratingURLWatchPreservesSelectedAccount() throws {
        var original = WatchedRepo(path: "https://github.com/hb-innovation-lab/PPA-Wrapper")
        original.githubAccount = "HannoJacobsHB"
        let migrated = try #require(GitHubActionsService.migrateLegacyRepository(original))
        #expect(migrated.id == original.id)
        #expect(migrated.githubAccount == "HannoJacobsHB")
        #expect(migrated.githubRemote?.slug == "hb-innovation-lab/PPA-Wrapper")
    }
}

struct GitHubAccountIsolationTests {
    @Test func authenticatedEnvironmentContainsOnlyExplicitSOURCRSettings() {
        let parentBefore = ProcessInfo.processInfo.environment
        let home = "/test/SOURCR user"
        let environment = SOURCRGitHubEnvironment.authenticated(
            GitHubCredential(login: "SelectedAccount", token: "selected-test-token"), home: home
        )

        #expect(environment["GH_TOKEN"] == "selected-test-token")
        #expect(environment["GH_HOST"] == "github.com")
        #expect(environment["GH_CONFIG_DIR"] == home + "/Library/Application Support/SOURCR/GitHubCLI")
        #expect(environment["HOME"] == home)
        #expect(environment["GH_PROMPT_DISABLED"] == "1")
        #expect(Set(environment.keys) == Set([
            "HOME", "PATH", "LC_ALL", "GH_HOST", "GH_PROMPT_DISABLED",
            "GH_NO_UPDATE_NOTIFIER", "GH_PAGER", "NO_COLOR", "GH_CONFIG_DIR", "GH_TOKEN"
        ]))
        for inheritedOverride in [
            "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
            "GH_REPO", "GH_DEBUG", "GH_INSECURE_OAUTH", "GIT_CONFIG_GLOBAL", "XDG_CONFIG_HOME"
        ] {
            #expect(environment[inheritedOverride] == nil)
        }
        #expect(ProcessInfo.processInfo.environment == parentBefore)
    }

    @Test func concurrentAccountsHaveIndependentChildEnvironments() {
        let first = SOURCRGitHubEnvironment.authenticated(GitHubCredential(login: "First", token: "first-test-token"))
        let second = SOURCRGitHubEnvironment.authenticated(GitHubCredential(login: "Second", token: "second-test-token"))
        #expect(first["GH_TOKEN"] == "first-test-token")
        #expect(second["GH_TOKEN"] == "second-test-token")
    }

    @MainActor @Test func missingAccountSelectionFailsClosed() async {
        let accounts = GitHubAccounts()
        let selections: [String?] = [nil, ""]
        for login in selections {
            do {
                _ = try await accounts.credential(for: login)
                Issue.record("An unselected account must never resolve a credential")
            } catch let error as GitHubAccountError {
                #expect(error.localizedDescription.contains("Choose a GitHub account"))
            } catch {
                Issue.record("Expected account-selection error before any CLI/keychain lookup, received \(error)")
            }
        }
    }

    @MainActor @Test func unknownSelectedAccountNeverFallsBackToGlobalCLI() async {
        let accounts = GitHubAccounts()
        let missingLogin = "sourcr-test-unenrolled-\(UUID().uuidString.lowercased())"
        do {
            _ = try await accounts.credential(for: missingLogin)
            Issue.record("An unenrolled account must never fall back to another credential")
        } catch let error as GitHubAccountError {
            #expect(error.localizedDescription.contains("Reconnect \(missingLogin)"))
            #expect(error.localizedDescription.contains("will not use another account"))
        } catch {
            Issue.record("Expected missing SOURCR credential error, received \(error)")
        }
    }
}
