import AppKit
import SwiftUI

struct SCMFileList: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let snap = appState.selectedSnapshot

        VStack(alignment: .leading, spacing: 0) {
            branchHeader(snap)

            if let error = snap.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("STAGED CHANGES", entries: snap.staged, accent: Color.green)
                        section("CHANGES", entries: snap.unstaged, accent: Color.orange)
                        section("UNTRACKED FILES", entries: snap.untracked, accent: Color.secondary)
                        if appState.showUnchanged {
                            section("UNCHANGED", entries: snap.unchangedSample, accent: Color.secondary.opacity(0.7))
                        }

                        if snap.totalChanges == 0 && (!appState.showUnchanged || snap.unchangedSample.isEmpty) {
                            Text("No local changes on \(snap.branch)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("Read-only · current branch only")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Quit")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        DispatchQueue.main.async {
                            NSApplication.shared.terminate(nil)
                        }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func branchHeader(_ snap: RepoSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(snap.branch)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            if !snap.headSHA.isEmpty {
                Text(snap.headSHA)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let repo = appState.selectedRepo {
                Text(repo.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private func section(_ title: String, entries: [GitFileEntry], accent: Color) -> some View {
        if !entries.isEmpty {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                Spacer()
                Text("\(entries.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ForEach(entries) { entry in
                fileRow(entry, accent: accent)
            }
        }
    }

    private func fileRow(_ entry: GitFileEntry, accent: Color) -> some View {
        let selected = appState.selectedFileID == entry.id

        return HStack(spacing: 8) {
            Text(entry.changeType.shortLetter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(letterColor(entry))
                .frame(width: 14, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if !entry.directoryPath.isEmpty {
                    Text(entry.directoryPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectFile(entry)
        }
    }

    private func letterColor(_ entry: GitFileEntry) -> Color {
        switch entry.changeType {
        case .added, .untracked: return .green
        case .modified, .renamed, .copied: return .orange
        case .deleted: return .red
        case .unchanged: return .secondary
        case .unknown: return .secondary
        }
    }
}
