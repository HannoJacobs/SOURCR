import Foundation

/// GitHub-style compact directory chains; identifiers always retain the full path.
enum PullRequestFileTree {
    struct Row: Identifiable, Equatable {
        var id: String
        var name: String
        var depth: Int
        var isDirectory: Bool
        var isExpanded: Bool
    }

    private final class Node {
        let name: String
        let path: String
        var children: [String: Node] = [:]
        var isFile = false
        init(name: String, path: String) { self.name = name; self.path = path }
    }

    static func rows(paths: [String], collapsed: Set<String>, filter: String) -> [Row] {
        let root = Node(name: "", path: "")
        for path in paths where filter.isEmpty || path.localizedCaseInsensitiveContains(filter) {
            var parent = root
            var components: [String] = []
            for part in path.split(separator: "/").map(String.init) {
                components.append(part)
                if parent.children[part] == nil {
                    parent.children[part] = Node(name: part, path: components.joined(separator: "/"))
                }
                parent = parent.children[part]!
            }
            parent.isFile = true
        }
        var result: [Row] = []
        func visit(_ parent: Node, depth: Int) {
            let children = parent.children.values.sorted {
                if $0.isFile != $1.isFile { return !$0.isFile }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for child in children {
                var node = child
                var label = child.name
                while !node.isFile, node.children.count == 1,
                      let next = node.children.values.first, !next.isFile {
                    label += "/" + next.name
                    node = next
                }
                let expanded = !node.isFile && !collapsed.contains(node.path)
                result.append(Row(id: node.path, name: label, depth: depth, isDirectory: !node.isFile, isExpanded: expanded))
                if expanded { visit(node, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return result
    }
}
