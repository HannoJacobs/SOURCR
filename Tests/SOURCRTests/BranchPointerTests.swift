import AppKit
import SwiftUI
import Testing
@testable import SOURCR

@MainActor
struct BranchPointerTests {
    private final class HoverWindow: NSPanel {
        override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: 20, y: 20) }
    }

    @Test func inactiveHoverWaitsOneSecondAndExitCancels() async throws {
        _ = NSApplication.shared
        let window = HoverWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 100),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let label = BranchNameTooltipView(frame: NSRect(x: 10, y: 10, width: 200, height: 30))
        label.stringValue = "feature/full-branch-name"
        label.clipsToBounds = true
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        defer { label.dismiss(); window.orderOut(nil) }
        #expect(!window.isKeyWindow)
        #expect(label.trackingAreas.contains { $0.options.contains(.activeAlways) })
        let entered = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        label.mouseEntered(with: entered)
        label.mouseExited(with: entered)
        try await Task.sleep(for: .milliseconds(1150))
        #expect(window.childWindows?.isEmpty != false)
        label.mouseEntered(with: entered)
        try await Task.sleep(for: .milliseconds(750))
        #expect(window.childWindows?.isEmpty != false)
        try await Task.sleep(for: .milliseconds(400))
        let tooltip = try #require(window.childWindows?.first)
        #expect(tooltip.isVisible)
        #expect(!tooltip.isKeyWindow)
        #expect(!window.isKeyWindow)
        #expect(tooltip.ignoresMouseEvents)
        #expect((tooltip.contentView?.subviews.first as? NSTextField)?.stringValue == label.stringValue)
        label.mouseExited(with: entered)
        #expect(window.childWindows?.isEmpty != false)
        #expect(!tooltip.isVisible)
    }

    @Test func branchNameAcceptsFirstClickAndInvokesActionOnce() throws {
        let label = BranchNameTooltipView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        var clicks = 0
        label.onClick = { clicks += 1 }
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        #expect(PanelHostingView(rootView: Text("row")).acceptsFirstMouse(for: down))
        #expect(label.acceptsFirstMouse(for: down))
        label.mouseDown(with: down)
        label.mouseUp(with: up)
        #expect(clicks == 1)
    }
}
