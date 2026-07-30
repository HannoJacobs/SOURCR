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
        HStack(spacing: 0) {
            if appState.isExpanded {
                leftDetailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
            }
            rightColumn
                .frame(width: SOURCRLayout.scmWidth)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var leftDetailPane: some View {
        switch appState.panelMode {
        case .diff:
            DiffPane()
        case .actions:
            ActionsDetailPane()
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        if showingSettings {
            SettingsPanel(showingSettings: $showingSettings)
        } else {
            VStack(spacing: 0) {
                headerBar
                Divider()
                switch appState.panelMode {
                case .diff:
                    VSCodeSCMView()
                case .actions:
                    ActionsSCMView()
                }
                footerQuit
            }
        }
    }

    /// One compact header: Diff/Actions on the left, mode tools on the right.
    private var headerBar: some View {
        HStack(spacing: 8) {
            PanelModeToggle()
            Spacer(minLength: 6)
            pinToggleButton
            switch appState.panelMode {
            case .diff:
                HeaderIconButton(
                    systemName: "arrow.clockwise",
                    help: "Refresh Diff",
                    spinning: appState.isRefreshing
                ) {
                    appState.refreshAll(force: true)
                }
                HeaderIconButton(systemName: "folder.badge.plus", help: "Add Diff Repository") {
                    appState.presentOpenPanel(for: .diff)
                }
                HeaderIconButton(systemName: "gearshape", help: "Diff Settings") {
                    showingSettings = true
                }
            case .actions:
                HeaderIconButton(
                    systemName: "arrow.clockwise",
                    help: "Refresh Actions",
                    spinning: appState.isRefreshingActions
                ) {
                    appState.refreshActions()
                }
                HeaderIconButton(systemName: "folder.badge.plus", help: "Add Actions Repository") {
                    appState.presentOpenPanel(for: .actions)
                }
                HeaderIconButton(systemName: "gearshape", help: "Actions Settings") {
                    showingSettings = true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var pinToggleButton: some View {
        HeaderIconButton(
            systemName: appState.isPanelPinned ? "pin.fill" : "pin",
            help: appState.isPanelPinned
                ? "Unpin panel (auto-closes when you click away)"
                : "Pin panel (stay open while working elsewhere)",
            isActive: appState.isPanelPinned
        ) {
            appState.togglePanelPinned()
        }
    }

    private var footerQuit: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
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
                        .contentShape(Rectangle())
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
    /// Accent-tinted “on” state (e.g. panel pin).
    var isActive: Bool = false
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
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundFill)
            )
            // Clear backgrounds are not hittable on macOS unless shaped.
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
        .onHover { isHovered = $0 }
    }

    private var iconColor: Color {
        if isActive { return Color.accentColor }
        return isHovered ? Color.primary : Color.secondary
    }

    private var backgroundFill: Color {
        if isActive { return Color.accentColor.opacity(0.16) }
        return isHovered ? Color.primary.opacity(0.12) : Color.clear
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Ensure padded / clear regions of the label remain clickable.
            .contentShape(Rectangle())
            // Avoid shrinking the hit target under the cursor on press.
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

struct PanelModeToggle: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PanelMode.allCases) { mode in
                Button {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        appState.setPanelMode(mode)
                    }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(appState.panelMode == mode ? Color.accentColor.opacity(0.25) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7))
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
                        .frame(maxHeight: .infinity)
                        .background(appState.diffViewMode == mode ? Color.accentColor.opacity(0.25) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
