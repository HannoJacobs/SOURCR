import Foundation

/// One ordered stream lets a single lazy scroll view cross file boundaries.
enum PRDiffDocumentRow: Identifiable {
    struct ScrollTarget: Hashable {
        let rowID: String
        let path: String

        static func file(_ path: String) -> Self {
            Self(rowID: PRDiffDocumentRow.fileID(path), path: path)
        }
    }

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

    var scrollTarget: ScrollTarget { .init(rowID: id, path: filePath) }

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
