import AppKit
import SwiftUI

struct PullRequestDetailPane: View {
    @Environment(AppState.self) private var appState
    @State private var sidebarDragStart: CGFloat?
    @State private var sidebarDividerHovered = false
    @State private var scrollTracker = PRDiffScrollTracker()
    @State private var sidebarPosition: String?
    var resizeActions = PanelDragActions()
    private var treeRows: [PullRequestFileTree.Row] {
        PullRequestFileTree.rows(paths: appState.pullRequestFiles.map(\.filename),
                                 collapsed: appState.collapsedPullRequestFolders,
                                 filter: appState.pullRequestFileFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isLoadingPullRequest, appState.pullRequestError == nil {
                summaryBar
                Divider()
            }
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
                        PanelDragHandle(
                            onBegan: { sidebarDragStart = appState.pullRequestSidebarWidth },
                            onChanged: { delta in
                                appState.pullRequestSidebarWidth = min(
                                    max(180, (sidebarDragStart ?? AppState.defaultPRSidebarWidth) + delta.width),
                                    min(440, max(180, geometry.size.width - 280)))
                            },
                            onEnded: { sidebarDragStart = nil },
                            onDoubleClick: { appState.pullRequestSidebarWidth = AppState.defaultPRSidebarWidth },
                            cursor: .resizeLeftRight, fillsHeight: true)
                            .frame(width: 9)
                            .frame(maxHeight: .infinity)
                            .background(sidebarDividerHovered ? Color.accentColor.opacity(0.12) : .clear)
                            .overlay {
                                Rectangle()
                                    .fill(sidebarDividerHovered ? Color.accentColor : Color.primary.opacity(0.12))
                                    .frame(width: 1)
                                    .allowsHitTesting(false)
                            }
                            .onHover { sidebarDividerHovered = $0 }
                            .help("Drag to resize file sidebar · double-click to restore default width")
                            .accessibilityLabel("Resize file sidebar")
                        diffContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(SCMTheme.diffBackground)
        .onAppear {
            let state = appState
            scrollTracker.onVisibleFile = { [weak state] in state?.trackVisiblePullRequestFile($0) }
            scrollTracker.start()
        }
        .onDisappear { scrollTracker.stop() }
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

    private var summaryBar: some View {
        let summary = appState.pullRequestChangeSummary
        return HStack(spacing: 12) {
            Label("\(summary.fileCount.formatted()) \(summary.fileCount == 1 ? "file" : "files") changed", systemImage: "doc.on.doc")
                .fontWeight(.medium)
            Text("\(summary.lineChanges.formatted()) line changes")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("+\(summary.additions.formatted())").foregroundStyle(.green)
                .help("Lines added")
            Text("−\(summary.deletions.formatted())").foregroundStyle(.red)
                .help("Lines deleted")
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PR summary: \(summary.fileCount) files changed, \(summary.lineChanges) line changes, \(summary.additions) additions, \(summary.deletions) deletions")
        .help(appState.pullRequestFiles.count >= 3000
              ? "Totals for the loaded files; GitHub limits the file list to 3,000."
              : "Line changes are additions plus deletions across all files, including files without a text patch.")
        .onAppear {
            AppDiagnostics.info(.appState, "PR change summary files=\(summary.fileCount) additions=\(summary.additions) deletions=\(summary.deletions) lineChanges=\(summary.lineChanges)")
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(treeRows) { row in
                        treeRow(row)
                    }
                    if treeRows.isEmpty {
                        Text("No matching files").font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 6).padding(.bottom, 8)
                .background(PRScrollbars())
            }
            .scrollIndicators(.visible)
            .scrollPosition(id: $sidebarPosition, anchor: .center)
            .onAppear { sidebarPosition = appState.selectedPullRequestFile }
            .onChange(of: appState.selectedPullRequestFile) {
                sidebarPosition = appState.selectedPullRequestFile
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
                        ForEach(appState.pullRequestDocument, id: \.scrollTarget) { row in
                            VStack(alignment: .leading, spacing: 0) {
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
                            .background(PRDiffRowMarker(path: row.filePath, tracker: scrollTracker))
                        }
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 28)
                    .background(PRScrollbars())
                }
                .scrollIndicators(.visible)
                .modifier(PRDiffScrollObservation(tracker: scrollTracker))
                .background(PRDiffViewportMarker(tracker: scrollTracker))
                .accessibilityLabel("All PR file diffs")
                .onChange(of: appState.pullRequestScrollRequest) {
                    if let path = appState.pullRequestScrollTarget {
                        let target = PRDiffDocumentRow.ScrollTarget.file(path)
                        proxy.scrollTo(target, anchor: .top)
                        scrollTracker.scheduleUpdate()
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
