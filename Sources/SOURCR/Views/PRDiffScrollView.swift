import AppKit
import SwiftUI

struct PRDiffScrollView: NSViewRepresentable {
    let rows: [PRDiffDocumentRow]
    let documentVersion: Int
    let scrollRequest: Int
    let scrollTarget: String?
    let onVisibleFile: (String) -> Void

    func makeNSView(context: Context) -> PRDiffTableScrollView { PRDiffTableScrollView() }

    func updateNSView(_ view: PRDiffTableScrollView, context: Context) {
        view.onVisibleFile = onVisibleFile
        view.update(rows: rows, version: documentVersion, request: scrollRequest, target: scrollTarget)
    }
}

/// All row heights are measured at the actual gutter-adjusted width before the
/// table is scrolled. Only visible cells are created; scrolling never changes
/// the document's geometry or estimates the position of an offscreen file.
final class PRDiffTableScrollView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let table: NSTableView = PRDiffMeasuredTableView()
    private(set) var rows: [PRDiffDocumentRow] = []
    private var layouts: [PRDiffRowLayout] = []
    private var fileRows: [String: Int] = [:]
    private var documentVersion: Int?
    private var lastRequest: Int?
    private var requestedTarget: String?
    private var measuredWidth: CGFloat = -1
    private var measuredViewportHeight: CGFloat = -1
    private var layingOutRows = false
    private var trackingPending = false
    private var lastVisibleFile: String?
    var onVisibleFile: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        PRScrollbars.configure(self)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = .textBackgroundColor
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        let column = NSTableColumn(identifier: .init("diff"))
        column.minWidth = 0
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("All PR file diffs")
        documentView = table
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(rows: [PRDiffDocumentRow], version: Int, request: Int, target: String?) {
        if documentVersion != version {
            self.rows = rows
            documentVersion = version
            fileRows = [:]
            for (index, row) in rows.enumerated() {
                if case .file(let file) = row { fileRows[file.filename] = index }
            }
            lastVisibleFile = nil
            measureRows(preservingPosition: false)
        }
        if lastRequest != request {
            lastRequest = request
            requestedTarget = target
            if let target { scrollToFile(target) }
        }
        scheduleTracking()
    }

    override func tile() {
        super.tile()
        if (measuredWidth != contentView.bounds.width || measuredViewportHeight != contentView.bounds.height), !layingOutRows {
            measureRows(preservingPosition: true)
        }
    }

    private func measureRows(preservingPosition: Bool) {
        guard !layingOutRows, contentView.bounds.width > 104 else { return }
        layingOutRows = true
        defer { layingOutRows = false }
        let origin = contentView.bounds.minY
        let anchor = table.row(at: NSPoint(x: 0, y: origin))
        let offset = anchor >= 0 ? origin - table.rect(ofRow: anchor).minY : 0
        measuredWidth = max(contentView.bounds.width, 1)
        measuredViewportHeight = contentView.bounds.height
        layouts = rows.map { PRDiffRowLayout(row: $0, width: measuredWidth) }
        table.tableColumns.first?.width = measuredWidth
        table.setFrameSize(NSSize(width: measuredWidth, height: table.frame.height))
        table.reloadData()
        AppDiagnostics.info(.appState, "PR diff native layout rows=\(rows.count) height=\(table.bounds.height) width=\(measuredWidth) geometry=measured")
        if preservingPosition, rows.indices.contains(anchor) {
            let rect = table.rect(ofRow: anchor)
            scroll(toY: rect.minY + min(offset, max(0, rect.height - 1)))
        } else if let requestedTarget {
            scrollToFile(requestedTarget)
        }
        scheduleTracking()
    }

    func scrollToFile(_ path: String) {
        guard let row = fileRows[path] else { return }
        scroll(toY: table.rect(ofRow: row).minY)
        scheduleTracking()
    }

    private func scroll(toY y: CGFloat) {
        let maxY = max(0, table.bounds.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        reflectScrolledClipView(contentView)
    }

    var visibleFile: String? {
        let row = table.row(at: NSPoint(x: 0, y: contentView.bounds.minY))
        return rows.indices.contains(row) ? rows[row].filePath : nil
    }

    @objc private func scrolled(_ notification: Notification) { scheduleTracking() }

    private func scheduleTracking() {
        guard !trackingPending else { return }
        trackingPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.trackingPending = false
            guard let path = self.visibleFile, path != self.lastVisibleFile else { return }
            self.lastVisibleFile = path
            self.onVisibleFile?(path)
        }
    }

    // A viewport of trailing space lets even the last small file reach the top,
    // so a file click and the viewport highlight agree at the end of a PR.
    func numberOfRows(in tableView: NSTableView) -> Int { layouts.isEmpty ? 0 : layouts.count + 1 }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row == layouts.count ? max(1, measuredViewportHeight - 1) : layouts[row].height
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < layouts.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("diff-row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? PRDiffTableCell ?? PRDiffTableCell()
        cell.identifier = identifier
        cell.configure(layouts[row])
        return cell
    }
}

private final class PRDiffMeasuredTableView: NSTableView {
    // AppKit's macOS 13 release notes specify that overriding this method opts
    // this table out of row-height estimation. Keep exact geometry for the diff
    // without changing the application's other tables or global preferences.
    override func rect(ofRow row: Int) -> NSRect { super.rect(ofRow: row) }
}

private struct PRDiffRowLayout {
    let text: NSAttributedString
    let oldNumber: NSAttributedString?
    let newNumber: NSAttributedString?
    let counts: NSAttributedString?
    let inset: NSPoint
    let textWidth: CGFloat
    let height: CGFloat
    let background: NSColor
    let isHeader: Bool

    init(row: PRDiffDocumentRow, width: CGFloat) {
        var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var foreground = NSColor.labelColor
        var background = NSColor.textBackgroundColor
        var oldNumber: Int?
        var newNumber: Int?
        var counts: NSAttributedString?
        let value: String
        let inset: NSPoint
        let textWidth: CGFloat
        let isHeader: Bool
        switch row {
        case .file(let file):
            value = file.filename + (file.previousFilename.map { "\nRenamed from " + $0 } ?? "")
            inset = NSPoint(x: 10, y: 10)
            let totals = NSMutableAttributedString(string: "+\(file.additions)", attributes: [.font: font, .foregroundColor: NSColor.systemGreen])
            totals.append(NSAttributedString(string: "  −\(file.deletions)", attributes: [.font: font, .foregroundColor: NSColor.systemRed]))
            counts = totals
            textWidth = max(1, width - 30 - totals.size().width)
            background = .windowBackgroundColor
            isHeader = true
        case .note(_, let note):
            value = note
            font = .systemFont(ofSize: 11)
            foreground = .secondaryLabelColor
            inset = NSPoint(x: 12, y: 12)
            textWidth = max(1, width - 24)
            isHeader = false
        case .line(_, let line):
            let prefix: String
            switch line.kind {
            case .addition: prefix = "+ "; background = .systemGreen.withAlphaComponent(0.15)
            case .deletion: prefix = "- "; background = .systemRed.withAlphaComponent(0.15)
            case .header: prefix = ""; foreground = .systemBlue; background = .systemBlue.withAlphaComponent(0.12)
            case .meta: prefix = ""; foreground = .secondaryLabelColor
            case .context: prefix = "  "
            }
            value = prefix + line.text
            oldNumber = line.oldLineNumber
            newNumber = line.newLineNumber
            inset = NSPoint(x: 100, y: 1)
            textWidth = max(1, width - 104)
            isHeader = false
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: value.isEmpty ? " " : value,
                                      attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph])
        let textHeight = ceil(text.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        self.text = text
        self.oldNumber = oldNumber.map { NSAttributedString(string: String($0), attributes: numberAttributes) }
        self.newNumber = newNumber.map { NSAttributedString(string: String($0), attributes: numberAttributes) }
        self.counts = counts
        self.inset = inset
        self.textWidth = textWidth
        self.height = max(14, textHeight) + inset.y * 2
        self.background = background
        self.isHeader = isHeader
    }
}

private final class PRDiffTableCell: NSView {
    private var row: PRDiffRowLayout?
    private let header = NSTextField(wrappingLabelWithString: "")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.isSelectable = true
        header.drawsBackground = false
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: PRDiffRowLayout) {
        self.row = row
        header.isHidden = !row.isHeader
        if row.isHeader {
            header.attributedStringValue = row.text
            header.frame = NSRect(x: row.inset.x - 2, y: row.inset.y, width: row.textWidth + 4,
                                  height: row.height - row.inset.y * 2)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(row.text.string)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        row.background.setFill()
        bounds.fill()
        if !row.isHeader {
            row.text.draw(with: NSRect(x: row.inset.x, y: row.inset.y, width: row.textWidth,
                                  height: row.height - row.inset.y * 2),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        if let number = row.oldNumber { number.draw(at: NSPoint(x: 48 - number.size().width, y: 1)) }
        if let number = row.newNumber { number.draw(at: NSPoint(x: 92 - number.size().width, y: 1)) }
        if let counts = row.counts { counts.draw(at: NSPoint(x: bounds.width - 10 - counts.size().width, y: 10)) }
        if row.isHeader {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
}
