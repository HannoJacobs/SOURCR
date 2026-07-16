import SwiftUI

struct DiffPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            diffHeader
            Divider()
            if let entry = appState.selectedFile {
                if entry.kind == .unchanged {
                    unchangedPlaceholder(entry)
                } else if let diff = appState.currentDiff {
                    if diff.isEmpty {
                        centeredMessage("No textual diff for this file")
                    } else if diff.isBinary {
                        centeredMessage("Binary file differs")
                    } else {
                        switch appState.diffViewMode {
                        case .inline:
                            InlineDiffView(lines: diff.lines)
                        case .sideBySide:
                            SideBySideDiffView(rows: appState.sideBySideRows)
                        }
                    }
                } else {
                    centeredMessage("Loading diff…")
                }
            } else {
                centeredMessage("Select a changed file to view its diff")
            }
        }
        .background(SCMTheme.diffBackground)
    }

    private var diffHeader: some View {
        HStack(spacing: 8) {
            if let entry = appState.selectedFile {
                Text(entry.changeType.shortLetter)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(SCMTheme.letterColor(entry.changeType))
                Text(entry.path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                Text(entry.kind.rawValue.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
            }
            Spacer()
            Text("Close")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.clearSelection()
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func unchangedPlaceholder(_ entry: GitFileEntry) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(entry.path)
                .font(.system(size: 12, design: .monospaced))
            Text("Unchanged on the current branch — no diff to show.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centeredMessage(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InlineDiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    InlineDiffRow(line: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
    }
}

private struct InlineDiffRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(lineNumber(line.oldLineNumber))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary.opacity(0.7))
            Text(lineNumber(line.newLineNumber))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary.opacity(0.7))
                .padding(.trailing, 8)

            Text(prefix + line.text)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.leading, 4)
        .background(rowBackground)
    }

    private var prefix: String {
        switch line.kind {
        case .addition: return "+ "
        case .deletion: return "- "
        case .header, .meta: return ""
        case .context: return "  "
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .addition: return SCMTheme.additionForeground
        case .deletion: return SCMTheme.deletionForeground
        case .header: return SCMTheme.hunkForeground
        case .meta: return .secondary
        case .context: return .primary
        }
    }

    private var rowBackground: Color {
        switch line.kind {
        case .addition: return SCMTheme.additionBackground
        case .deletion: return SCMTheme.deletionBackground
        case .header: return SCMTheme.hunkBackground
        case .meta: return .clear
        case .context: return .clear
        }
    }

    private func lineNumber(_ n: Int?) -> String {
        guard let n else { return " " }
        return "\(n)"
    }
}

struct SideBySideDiffView: View {
    let rows: [SideBySideRow]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 0) {
                        sideCell(
                            number: row.leftNumber,
                            text: row.leftText,
                            kind: row.leftKind
                        )
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 1)
                        sideCell(
                            number: row.rightNumber,
                            text: row.rightText,
                            kind: row.rightKind
                        )
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func sideCell(number: Int?, text: String?, kind: DiffLineKind) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? " ")
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary.opacity(0.7))
                .padding(.trailing, 6)
            Text(text ?? " ")
                .foregroundStyle(SCMTheme.foreground(for: kind))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
        .background(SCMTheme.background(for: kind))
    }
}

enum SCMTheme {
    // Semantic colors that adapt to light/dark via opacity over system backgrounds.
    static var diffBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var additionBackground: Color {
        Color.green.opacity(0.15)
    }

    static var deletionBackground: Color {
        Color.red.opacity(0.15)
    }

    static var hunkBackground: Color {
        Color.blue.opacity(0.12)
    }

    static var additionForeground: Color { .primary }
    static var deletionForeground: Color { .primary }
    static var hunkForeground: Color { Color.blue }

    static func background(for kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: return additionBackground
        case .deletion: return deletionBackground
        case .header: return hunkBackground
        case .meta, .context: return .clear
        }
    }

    static func foreground(for kind: DiffLineKind) -> Color {
        switch kind {
        case .addition, .deletion, .context: return .primary
        case .header: return hunkForeground
        case .meta: return .secondary
        }
    }

    static func letterColor(_ type: GitChangeType) -> Color {
        switch type {
        case .added, .untracked: return .green
        case .modified, .renamed, .copied: return .orange
        case .deleted: return .red
        case .unchanged, .unknown: return .secondary
        }
    }
}
