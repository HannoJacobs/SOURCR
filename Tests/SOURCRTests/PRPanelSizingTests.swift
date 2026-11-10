import CoreGraphics
import Testing
@testable import SOURCR

struct PRPanelSizingTests {
    @Test @MainActor func openingPRDoesNotExpandMainPanel() {
        let state = AppState()
        state.panelMode = .branches
        state.scmBodyHeight = 300
        let height = state.panelHeight
        let remote = GitHubRemote(owner: "example", name: "repo")
        state.actionsRepos = [WatchedRepo(remote: remote)]
        state.openPullRequest(BranchPullRequest(number: 1, title: "PR", url: "https://github.com/example/repo/pull/1", state: .draft))
        #expect(state.selectedPullRequest?.number == 1)
        #expect(!state.isExpanded)
        #expect(state.panelHeight == height)
        state.togglePRSize()
        #expect(state.panelHeight == height)
        state.clearActionSelection()
    }

    @Test func doubledViewFitsBothScreenEdges() {
        #expect(PRPanelSizing.fit(requested: CGSize(width: 2160, height: 1300), available: CGSize(width: 1400, height: 780)) == CGSize(width: 1400, height: 780))
        #expect(PRPanelSizing.fit(requested: CGSize(width: 1080, height: 650), available: CGSize(width: 2200, height: 1400)) == CGSize(width: 1080, height: 650))
    }

    @Test @MainActor func resizingAndCollapsePreserveWindowMode() {
        let state = AppState()
        state.panelMode = .branches
        state.isPanelDetached = true
        state.isPanelPinned = true
        state.selectedPullRequest = BranchPullRequest(number: 1, title: "PR", url: "https://github.com/example/repo/pull/1", state: .draft)
        state.isExpanded = true
        #expect(state.pullRequestSidebarWidth == 320)
        state.togglePRSize()
        #expect(state.requestedPRSize == CGSize(width: 2160, height: 1300))
        state.resizePR(to: CGSize(width: 1200, height: 720))
        #expect(!state.isPRSizeDoubled)
        #expect(state.requestedPRSize == CGSize(width: 1200, height: 720))
        state.clearActionSelection()
        #expect(!state.isExpanded)
        #expect(state.isPanelDetached && state.isPanelPinned)
        #expect(state.customPRSize == nil)
    }
}
