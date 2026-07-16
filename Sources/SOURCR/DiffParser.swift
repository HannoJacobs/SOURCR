import Foundation

enum DiffParser {
    static func parse(path: String, unifiedDiff: String) -> ParsedDiff {
        let trimmed = unifiedDiff.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty(path: path)
        }

        if trimmed.contains("Binary files ") || trimmed.contains("GIT binary patch") {
            return ParsedDiff(
                path: path,
                lines: [
                    DiffLine(id: 0, kind: .meta, text: "Binary file differs", oldLineNumber: nil, newLineNumber: nil)
                ],
                isBinary: true,
                isEmpty: false
            )
        }

        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var id = 0

        for raw in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("diff --git") || raw.hasPrefix("index ") || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") {
                lines.append(DiffLine(id: id, kind: .meta, text: raw, oldLineNumber: nil, newLineNumber: nil))
                id += 1
                continue
            }

            if raw.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(raw) {
                    oldLine = o
                    newLine = n
                }
                lines.append(DiffLine(id: id, kind: .header, text: raw, oldLineNumber: nil, newLineNumber: nil))
                id += 1
                continue
            }

            if raw.hasPrefix("+") {
                let text = String(raw.dropFirst())
                lines.append(DiffLine(id: id, kind: .addition, text: text, oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
                id += 1
                continue
            }

            if raw.hasPrefix("-") {
                let text = String(raw.dropFirst())
                lines.append(DiffLine(id: id, kind: .deletion, text: text, oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
                id += 1
                continue
            }

            if raw.hasPrefix("\\") {
                lines.append(DiffLine(id: id, kind: .meta, text: raw, oldLineNumber: nil, newLineNumber: nil))
                id += 1
                continue
            }

            // context (may start with space or be empty after strip)
            let text = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
            lines.append(DiffLine(id: id, kind: .context, text: text, oldLineNumber: oldLine, newLineNumber: newLine))
            oldLine += 1
            newLine += 1
            id += 1
        }

        return ParsedDiff(path: path, lines: lines, isBinary: false, isEmpty: lines.isEmpty)
    }

    static func syntheticAddition(path: String, contents: String) -> ParsedDiff {
        let contentLines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lineCount = max(contentLines.count, 1)
        var lines: [DiffLine] = [
            DiffLine(id: 0, kind: .meta, text: "diff --git a/\(path) b/\(path)", oldLineNumber: nil, newLineNumber: nil),
            DiffLine(id: 1, kind: .meta, text: "new file mode 100644", oldLineNumber: nil, newLineNumber: nil),
            DiffLine(id: 2, kind: .header, text: "@@ -0,0 +1,\(lineCount) @@", oldLineNumber: nil, newLineNumber: nil)
        ]

        var id = 3
        var newLine = 1
        if contentLines.isEmpty {
            lines.append(DiffLine(id: id, kind: .addition, text: "", oldLineNumber: nil, newLineNumber: newLine))
        } else {
            for line in contentLines {
                lines.append(DiffLine(id: id, kind: .addition, text: line, oldLineNumber: nil, newLineNumber: newLine))
                id += 1
                newLine += 1
            }
        }

        return ParsedDiff(path: path, lines: lines, isBinary: false, isEmpty: false)
    }

    static func sideBySideRows(from diff: ParsedDiff) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        var pendingDeletions: [DiffLine] = []
        var id = 0

        func flushDeletions() {
            for deletion in pendingDeletions {
                rows.append(SideBySideRow(
                    id: id,
                    leftNumber: deletion.oldLineNumber,
                    leftText: deletion.text,
                    leftKind: .deletion,
                    rightNumber: nil,
                    rightText: nil,
                    rightKind: .context
                ))
                id += 1
            }
            pendingDeletions.removeAll()
        }

        for line in diff.lines {
            switch line.kind {
            case .meta, .header:
                flushDeletions()
                rows.append(SideBySideRow(
                    id: id,
                    leftNumber: nil,
                    leftText: line.text,
                    leftKind: line.kind,
                    rightNumber: nil,
                    rightText: line.text,
                    rightKind: line.kind
                ))
                id += 1

            case .deletion:
                pendingDeletions.append(line)

            case .addition:
                if !pendingDeletions.isEmpty {
                    let deletion = pendingDeletions.removeFirst()
                    rows.append(SideBySideRow(
                        id: id,
                        leftNumber: deletion.oldLineNumber,
                        leftText: deletion.text,
                        leftKind: .deletion,
                        rightNumber: line.newLineNumber,
                        rightText: line.text,
                        rightKind: .addition
                    ))
                    id += 1
                } else {
                    rows.append(SideBySideRow(
                        id: id,
                        leftNumber: nil,
                        leftText: nil,
                        leftKind: .context,
                        rightNumber: line.newLineNumber,
                        rightText: line.text,
                        rightKind: .addition
                    ))
                    id += 1
                }

            case .context:
                flushDeletions()
                rows.append(SideBySideRow(
                    id: id,
                    leftNumber: line.oldLineNumber,
                    leftText: line.text,
                    leftKind: .context,
                    rightNumber: line.newLineNumber,
                    rightText: line.text,
                    rightKind: .context
                ))
                id += 1
            }
        }

        flushDeletions()
        return rows
    }

    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        // @@ -12,5 +14,7 @@
        let pattern = #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges >= 3,
              let oldRange = Range(match.range(at: 1), in: line),
              let newRange = Range(match.range(at: 2), in: line),
              let old = Int(line[oldRange]),
              let new = Int(line[newRange]) else {
            return nil
        }
        return (old, new)
    }
}
