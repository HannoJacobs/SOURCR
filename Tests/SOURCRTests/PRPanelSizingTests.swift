import CoreGraphics
import Testing
@testable import SOURCR

struct PRPanelSizingTests {
    @Test func doubledViewFitsBothScreenEdges() {
        #expect(PRPanelSizing.fit(requested: CGSize(width: 2160, height: 1300), available: CGSize(width: 1400, height: 780)) == CGSize(width: 1400, height: 780))
        #expect(PRPanelSizing.fit(requested: CGSize(width: 1080, height: 650), available: CGSize(width: 2200, height: 1400)) == CGSize(width: 1080, height: 650))
    }

    @Test func onlyTheDetailAreaKeepsThePRopen() {
        let size = CGSize(width: 1080, height: 650)
        #expect(!PRPanelSizing.containsDetail(point: CGPoint(x: 100, y: 300), panelSize: size, onRight: true))
        #expect(PRPanelSizing.containsDetail(point: CGPoint(x: 600, y: 300), panelSize: size, onRight: true))
        #expect(!PRPanelSizing.containsDetail(point: CGPoint(x: 950, y: 300), panelSize: size, onRight: false))
        #expect(PRPanelSizing.containsDetail(point: CGPoint(x: 100, y: 300), panelSize: size, onRight: false))
        #expect(!PRPanelSizing.containsDetail(point: CGPoint(x: 100, y: -1), panelSize: size, onRight: false))
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
