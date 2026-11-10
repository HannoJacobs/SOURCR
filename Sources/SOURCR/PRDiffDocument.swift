import Foundation

/// One ordered stream lets a single lazy scroll view cross file boundaries.
enum PRDiffDocumentRow: Identifiable {
    case file(PullRequestFile)
    case note(path: String, text: String)
    case line(path: String, value: DiffLine)

    static func fileID(_ path: String) -> String { "file:" + path }

    var id: String {
        switch self {
        case .file(let file): return Self.fileID(file.filename)
        case .note(let path, _): return "note:" + path
        case .line(let path, let line): return "line:" + path + "\0" + String(line.id)
        }
    }

    var filePath: String {
        switch self {
        case .file(let file): return file.filename
        case .note(let path, _), .line(let path, _): return path
        }
    }

    static func build(files: [PullRequestFile]) -> [Self] {
        var rows: [Self] = []
        for file in files {
            rows.append(.file(file))
            if let note = file.note { rows.append(.note(path: file.filename, text: note)) }
            if let patch = file.patch, !patch.isEmpty {
                let diff = DiffParser.parse(path: file.filename, unifiedDiff: patch)
                rows.append(contentsOf: diff.lines.map { .line(path: file.filename, value: $0) })
            }
        }
        return rows
    }
}

enum PRDiffVisibility {
    struct Location: Equatable {
        let path: String
        let minY: CGFloat
        let maxY: CGFloat
    }

    static func fileAtTop(_ locations: [Location], viewportHeight: CGFloat) -> String? {
        locations.filter { $0.maxY > 0 && $0.minY < viewportHeight }
            .min { $0.minY < $1.minY }?.path
    }
}
