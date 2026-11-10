import AppKit
import Testing
@testable import SOURCR

struct PRDiffScrollTrackerTests {
    @MainActor private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    @Test @MainActor func viewportTrackingDoesNotRequireAnAppKitScrollView() {
        let root = Document(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let viewport = Document(frame: root.bounds)
        let content = Document(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        root.addSubview(viewport)
        root.addSubview(content)
        let tracker = PRDiffScrollTracker()
        tracker.viewport = viewport
        var selected: String?
        tracker.onVisibleFile = { selected = $0 }
        for (index, path) in ["first", "second"].enumerated() {
            let marker = PRDiffRowMarkerView(frame: NSRect(x: 0, y: index * 500, width: 300, height: 500))
            marker.path = path
            content.addSubview(marker)
            tracker.register(marker)
        }
        tracker.updateVisibleFile()
        #expect(selected == "first")
        content.frame.origin.y = -500
        tracker.updateVisibleFile()
        #expect(selected == "second")
        content.frame.origin.y = 0
        tracker.updateVisibleFile()
        #expect(selected == "first")
        tracker.stop()
    }

    @Test @MainActor func actualClipBoundsTrackBothDirectionsAndLayoutChanges() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        scroll.documentView = document
        let tracker = PRDiffScrollTracker()
        var selected: String?
        tracker.onVisibleFile = { selected = $0 }
        let first = PRDiffRowMarkerView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        first.path = "a/same.txt"
        let second = PRDiffRowMarkerView(frame: NSRect(x: 0, y: 500, width: 300, height: 500))
        second.path = "b/same.txt"
        for row in [first, second] { document.addSubview(row); tracker.register(row) }
        func move(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            tracker.updateVisibleFile()
        }
        move(490)
        #expect(selected == "a/same.txt")
        move(500)
        #expect(selected == "b/same.txt")
        move(850)
        #expect(selected == "b/same.txt")
        move(0)
        #expect(selected == "a/same.txt")
        first.frame.size.height = 400
        second.frame.origin.y = 400
        move(450)
        #expect(selected == "b/same.txt")
        second.removeFromSuperview()
        move(450)
        #expect(selected == "b/same.txt") // No visible rows: retain the last selection.
        tracker.stop()
    }
}
