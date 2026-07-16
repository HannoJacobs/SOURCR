import AppKit
import SwiftUI

// BUTTON STYLE NOTES — why onTapGesture instead of Button:
//   .borderless buttons: tiny hit target
//   .plain buttons: can dismiss the MenuBarExtra window before the action fires
//   Solution: HStack rows + .contentShape(Rectangle()) + .onTapGesture

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @State private var showingSettings = false

    private var panelWidth: CGFloat {
        appState.isExpanded ? 980 : 360
    }

    private var panelHeight: CGFloat {
        appState.isExpanded ? 620 : 480
    }

    var body: some View {
        Group {
            if showingSettings {
                SettingsPanel(showingSettings: $showingSettings)
            } else {
                mainPanel
            }
        }
        .frame(width: panelWidth, height: panelHeight)
        .animation(.easeInOut(duration: 0.18), value: appState.isExpanded)
        .animation(.easeInOut(duration: 0.15), value: showingSettings)
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if appState.repos.isEmpty {
                emptyState
            } else if appState.isExpanded {
                expandedBody
            } else {
                compactBody
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            Text("SOURCE CONTROL")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            Spacer()

            if appState.isExpanded {
                DiffModePicker()
            }

            headerIconButton("arrow.clockwise", help: "Refresh") {
                appState.refreshAll()
            }
            headerIconButton("folder.badge.plus", help: "Add Repository") {
                appState.presentOpenPanel()
            }
            headerIconButton("gearshape", help: "Settings") {
                showingSettings = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var compactBody: some View {
        HStack(spacing: 0) {
            RepoSidebar()
                .frame(width: 120)
            Divider()
            SCMFileList()
                .frame(maxWidth: .infinity)
        }
    }

    private var expandedBody: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                RepoSidebar()
                    .frame(height: 120)
                Divider()
                SCMFileList()
            }
            .frame(width: 280)
            Divider()
            DiffPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No Repositories")
                .font(.headline)
            Text("Add git repos to inspect staged, dirty, and unchanged files — read-only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            menuRow("Add Repository…", icon: "folder.badge.plus") {
                appState.presentOpenPanel()
            }
            .padding(.horizontal, 40)
            Spacer()
            footerQuit
        }
    }

    private var footerQuit: some View {
        VStack(spacing: 0) {
            Divider()
            menuRow("Quit SOURCR", icon: "power") {
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func headerIconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help(help)
            .onTapGesture(perform: action)
    }

    private func menuRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 20)
            Text(title)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

private struct DiffModePicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DiffViewMode.allCases) { mode in
                Text(mode.title)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(appState.diffViewMode == mode ? Color.accentColor.opacity(0.25) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.diffViewMode = mode
                    }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
