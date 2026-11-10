import AppKit
import SwiftUI

struct PullRequestDetailPane: View {
    @Environment(AppState.self) private var appState
    @State private var sidebarDragStart: CGFloat?
    var resizeActions = PanelDragActions()
    private var treeRows: [PullRequestFileTree.Row] {
        PullRequestFileTree.rows(paths: appState.pullRequestFiles.map(\.filename),
                                 collapsed: appState.collapsedPullRequestFolders,
                                 filter: appState.pullRequestFileFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.isLoadingPullRequest {
                message("Loading PR files from GitHub…")
            } else if let error = appState.pullRequestError {
                VStack(spacing: 12) {
                    message(error)
                    Button("Retry") {
                        if let pr = appState.selectedPullRequest { appState.openPullRequest(pr, reload: true) }
                    }
                }.padding()
            } else if appState.pullRequestFiles.isEmpty {
                message("No changed files in this pull request.")
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        fileList.frame(width: min(appState.pullRequestSidebarWidth, max(160, geometry.size.width - 280)))
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1)
                            .padding(.horizontal, 2)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    if sidebarDragStart == nil { sidebarDragStart = appState.pullRequestSidebarWidth }
                                    appState.pullRequestSidebarWidth = min(max(180, (sidebarDragStart ?? 320) + value.translation.width),
                                                       min(440, max(180, geometry.size.width - 280)))
                                }
                                .onEnded { _ in sidebarDragStart = nil })
                            .accessibilityLabel("Resize file sidebar")
                        diffContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(SCMTheme.diffBackground)
        .onChange(of: appState.pullRequestFileFilter) { appState.collapsedPullRequestFolders = [] }
        .overlay(alignment: appState.pullRequestOpensRight ? .bottomTrailing : .bottomLeading) {
            PanelDragHandle(onBegan: resizeActions.began, onChanged: resizeActions.changed,
                            onEnded: resizeActions.ended, onDoubleClick: { appState.togglePRSize() })
                .overlay {
                    Image(systemName: appState.pullRequestOpensRight ? "arrow.up.left.and.arrow.down.right" : "arrow.up.right.and.arrow.down.left")
                        .font(.system(size: 11)).foregroundStyle(.secondary).allowsHitTesting(false)
                }
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                .help("Drag to resize PR view · double-click for 2×")
                .accessibilityLabel("Resize PR view")
        }
    }

    private var fileList: some View {
        @Bindable var state = appState
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter changed files", text: $state.pullRequestFileFilter)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Filter PR files")
                Button(appState.isPRSizeDoubled ? "1×" : "2×") { appState.togglePRSize() }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.borderless)
                    .help(appState.isPRSizeDoubled ? "Restore default PR view size" : "Double PR view size, within the screen")
                    .accessibilityLabel(appState.isPRSizeDoubled ? "Restore PR size" : "Double PR size")
            }
            .font(.system(size: 12))
            .padding(7)
            .background(SCMTheme.diffBackground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            .padding(8)
            if appState.pullRequestFiles.count >= 3000 {
                Text("GitHub limits this list to 3,000 files.")
                    .font(.caption2).foregroundStyle(.orange).padding(8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(treeRows) { row in
                            treeRow(row)
                        }
                        if treeRows.isEmpty {
                            Text("No matching files").font(.caption).foregroundStyle(.secondary).padding(12)
                        }
                    }.padding(.horizontal, 6).padding(.bottom, 8)
                }
                .onChange(of: appState.selectedPullRequestFile) {
                    if let path = appState.selectedPullRequestFile { proxy.scrollTo(path, anchor: .center) }
                }
            }
        }
        .background(SCMTheme.diffBackground)
    }

    private func treeRow(_ row: PullRequestFileTree.Row) -> some View {
        Button {
            if row.isDirectory {
                if appState.collapsedPullRequestFolders.contains(row.id) {
                    appState.collapsedPullRequestFolders.remove(row.id)
                } else {
                    appState.collapsedPullRequestFolders.insert(row.id)
                }
            } else {
                appState.selectPullRequestFile(row.id)
            }
        } label: {
            HStack(spacing: 6) {
                if row.isDirectory {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 12)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                    .font(.system(size: 13))
                    .foregroundStyle(row.isDirectory ? Color(red: 0.30, green: 0.65, blue: 1) : .secondary)
                    .frame(width: 16)
                Text(row.name)
                    .font(.system(size: 12))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(row.depth) * 14 + 6)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(row.id == appState.selectedPullRequestFile ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(row.id)
        .accessibilityLabel(row.isDirectory ? "Folder \(row.name), \(row.isExpanded ? "expanded" : "collapsed")" : row.name)
    }

    private var diffContent: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(appState.pullRequestDocument) { row in
                            Group {
                            switch row {
                            case .file(let file):
                                fileHeader(file)
                            case .note(_, let text):
                                Text(text).font(.caption).foregroundStyle(.secondary)
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            case .line(_, let line):
                                InlineDiffRow(line: line, wordWrap: true, containerWidth: geometry.size.width)
                            }
                            }
                            .background(GeometryReader { position in
                                let frame = position.frame(in: .named("pr-document"))
                                Color.clear.preference(key: PRDiffVisibleRowsKey.self, value: [
                                    PRDiffVisibility.Location(path: row.filePath, minY: frame.minY, maxY: frame.maxY)
                                ])
                            })
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 28)
                }
                .coordinateSpace(name: "pr-document")
                .accessibilityLabel("All PR file diffs")
                .onPreferenceChange(PRDiffVisibleRowsKey.self) { locations in
                    if let path = PRDiffVisibility.fileAtTop(locations, viewportHeight: geometry.size.height) {
                        appState.trackVisiblePullRequestFile(path)
                    }
                }
                .onChange(of: appState.pullRequestScrollRequest) {
                    if let path = appState.pullRequestScrollTarget {
                        proxy.scrollTo(PRDiffDocumentRow.fileID(path), anchor: .top)
                    }
                }
            }
        }
    }

    private func fileHeader(_ file: PullRequestFile) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    if let old = file.previousFilename {
                        Text("Renamed from \(old)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
            }
            .font(.caption).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PRDiffVisibleRowsKey: PreferenceKey {
    static let defaultValue: [PRDiffVisibility.Location] = []
    static func reduce(value: inout [PRDiffVisibility.Location], nextValue: () -> [PRDiffVisibility.Location]) {
        value.append(contentsOf: nextValue())
    }
}
