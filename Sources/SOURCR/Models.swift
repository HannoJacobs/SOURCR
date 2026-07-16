import Foundation

enum GitFileKind: String, Codable, Hashable {
    case staged
    case unstaged
    case untracked
    case unchanged
}

enum GitChangeType: String, Codable, Hashable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case untracked
    case unchanged
    case unknown

    var shortLetter: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "U"
        case .unchanged: return " "
        case .unknown: return "?"
        }
    }
}

struct WatchedRepo: Identifiable, Codable, Hashable {
    var id: UUID
    var path: String
    var displayName: String

    init(id: UUID = UUID(), path: String, displayName: String? = nil) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
    }
}

struct GitFileEntry: Identifiable, Hashable {
    var id: String { "\(kind.rawValue):\(path)" }
    let path: String
    let kind: GitFileKind
    let changeType: GitChangeType
    let oldPath: String?

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var directoryPath: String {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return dir == "." ? "" : dir
    }
}

struct RepoSnapshot: Hashable {
    var branch: String
    var headSHA: String
    var staged: [GitFileEntry]
    var unstaged: [GitFileEntry]
    var untracked: [GitFileEntry]
    var unchangedSample: [GitFileEntry]
    var errorMessage: String?

    static let empty = RepoSnapshot(
        branch: "—",
        headSHA: "",
        staged: [],
        unstaged: [],
        untracked: [],
        unchangedSample: [],
        errorMessage: nil
    )

    var totalChanges: Int {
        staged.count + unstaged.count + untracked.count
    }
}

enum DiffViewMode: String, CaseIterable, Identifiable {
    case inline
    case sideBySide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inline: return "Inline"
        case .sideBySide: return "Side By Side"
        }
    }
}

enum DiffLineKind: Hashable {
    case context
    case addition
    case deletion
    case header
    case meta
}

struct DiffLine: Identifiable, Hashable {
    let id: Int
    let kind: DiffLineKind
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

struct ParsedDiff: Hashable {
    var path: String
    var lines: [DiffLine]
    var isBinary: Bool
    var isEmpty: Bool

    static func empty(path: String) -> ParsedDiff {
        ParsedDiff(path: path, lines: [], isBinary: false, isEmpty: true)
    }
}

struct SideBySideRow: Identifiable, Hashable {
    let id: Int
    let leftNumber: Int?
    let leftText: String?
    let leftKind: DiffLineKind
    let rightNumber: Int?
    let rightText: String?
    let rightKind: DiffLineKind
}
