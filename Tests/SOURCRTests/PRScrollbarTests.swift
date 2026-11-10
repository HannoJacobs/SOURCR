import AppKit
import Testing
@testable import SOURCR

struct PRScrollbarTests {
    @Test @MainActor func permanentScrollerReservesContentSpaceForLongAndShortDocuments() {
        for height in [100, 1000] {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: height))
            PRScrollbars.configure(scroll)
            scroll.layoutSubtreeIfNeeded()
            let scroller = scroll.verticalScroller!
            #expect(!scroller.isHidden)
            #expect(scroller.frame.width > 0)
            #expect(scroll.contentView.frame.width < scroll.bounds.width)
            #expect(!scroll.contentView.frame.intersects(scroller.frame))
            #expect(!scroll.hasHorizontalScroller)
        }
    }
}
