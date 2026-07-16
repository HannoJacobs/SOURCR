import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @State private var showingSettings = false
    var onClose: (() -> Void)?

    var body: some View {
        mainPanel
            // The SwiftUI root always fills the window exactly; the window width
            // (driven by StatusPanelController) is the single source of truth.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            if appState.repos.isEmpty {
                if showingSettings {
                    SettingsPanel(showingSettings: $showingSettings)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // [Diff (fills remaining) | right column (fixed scmWidth)].
                // The right column hosts either the SCM list or Settings — the diff
                // pane on the left stays put and live-updates.
                HStack(spacing: 0) {
                    if appState.isExpanded {
                        DiffPane()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                    }
                    rightColumn
                        .frame(width: SOURCRLayout.scmWidth)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        if showingSettings {
            SettingsPanel(showingSettings: $showingSettings)
        } else {
            VSCodeSCMView(onOpenSettings: { showingSettings = true })
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
            Text("Add git repos to inspect staged and dirty files — read-only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            PressableRow(action: { appState.presentOpenPanel() }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").frame(width: 20)
                    Text("Add Repository…")
                    Spacer()
                }
            }
            .padding(.horizontal, 40)
            Spacer()
            footerQuit
        }
    }

    private var footerQuit: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                HeaderIconButton(
                    systemName: "arrow.clockwise",
                    help: "Refresh",
                    spinning: appState.isRefreshing
                ) {
                    appState.refreshAll(force: true)
                }
                HeaderIconButton(systemName: "folder.badge.plus", help: "Add Repository") {
                    appState.presentOpenPanel()
                }
                HeaderIconButton(systemName: "gearshape", help: "Settings") {
                    showingSettings = true
                }
                Spacer()
                Button {
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Text("Quit")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

/// Toolbar icon with hover + pressed highlight (and optional refresh spinner).
struct HeaderIconButton: View {
    let systemName: String
    let help: String
    var spinning: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if spinning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .onHover { isHovered = $0 }
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .overlay {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.22))
                }
            }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Full-width tappable row with hover + pressed highlight.
struct PressableRow<Content: View>: View {
    let action: () -> Void
    var cornerRadius: CGFloat = 6
    var selected: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(backgroundFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
    }

    private var backgroundFill: Color {
        if selected {
            return Color.accentColor.opacity(0.22)
        }
        if isHovered {
            return Color.primary.opacity(0.08)
        }
        return Color.clear
    }
}

struct DiffModePicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DiffViewMode.allCases) { mode in
                Button {
                    appState.diffViewMode = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(appState.diffViewMode == mode ? Color.accentColor.opacity(0.25) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// No Wrap / Wrap segmented control (matches DiffModePicker styling).
struct WrapToggle: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            segment(title: "No Wrap", isOn: !appState.wordWrap) {
                appState.wordWrap = false
            }
            segment(title: "Wrap", isOn: appState.wordWrap) {
                appState.wordWrap = true
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func segment(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isOn ? Color.accentColor.opacity(0.25) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(PressableButtonStyle())
    }
}
