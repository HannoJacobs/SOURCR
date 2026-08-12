# SOURCR

Menu-bar **Source Control** viewer for macOS — a read-only, VS Code / Cursor-style SCM + diff panel.

```
Menu bar icon
    └─ Anchored panel (right edge pinned to the status item)
         ├─ Diff pane (left, expands only when a file is selected)
         └─ SCM column (right, fixed width)
              ├─ Multi-repo accordion (drag grip to reorder)
              ├─ Flat changes + untracked list
              └─ Footer: Refresh · Add · Settings · Quit
```

## What it does

- Lives in the menu bar (`LSUIElement`)
- Watch local git repositories for **Diff** and separately for **Actions** (independent lists)
- **Diff mode:** Shows combined staged + dirty changes and untracked files on the **current branch**
- Click a file to open a diff to the left (Inline or Side By Side); click again to collapse
- **Actions mode:** Lists GitHub Actions for Actions-list repos (newest run per workflow name)
- Click a workflow run to expand job/step detail to the left (same leftward expand as Diff); click again to collapse
- Mode-specific Settings manage which repos belong to Diff vs Actions
- Defaults to Side By Side + Wrap; both live in Diff Settings
- Follows system light / dark appearance
- Opening the panel (or bringing it to the foreground) immediately refreshes Diff and Actions
- While the panel is visible, Diff and Actions both refresh every ~10s (no manual Refresh needed to catch a finished CD)
- Pin (next to Refresh) keeps the panel in front while you work in other apps; unpin restores normal click-away dismiss
- Panel height follows open Diff/Actions content (up to a max) so collapsed repos don’t leave a tall empty window
- Git/`gh` child processes drain pipes while running and time out (so a huge `git status -uall` or stuck `gh` cannot freeze refreshes until quit)
- In-flight Diff/`gh` refreshes are allowed to finish after the panel hides, so a quick open/close cannot leave a stale dirty count on screen

## What it never does

- No branch switching
- No staging / unstaging
- No commit / push / pull
- No rewrite of working tree state

Read-only by design: `GitService` only allows `status`, `diff`, `show`, `rev-parse`, `ls-files`, and `remote get-url`. Actions mode uses the `gh` CLI read-only (`run list` / `run view`).

## Requirements

- macOS 14+
- Xcode (for Release `.app` / DMG packaging)
- `git` on `PATH` (`/usr/bin/git`)

## Develop

```bash
# Open in Xcode (always via Package.swift, not Recents after moves)
open Package.swift

# Or build from CLI
swift build
swift test
```

Run the `SOURCR` scheme on **My Mac**.

## Release / install (DICTATR-style full send)

In this repo, "ship a new version" and "full send" mean the same bar: commit everything required, push, package the DMG, upload it to the live GitHub release, reinstall `/Applications/SOURCR.app`, and verify from launch logs. Do not stop at a local build or a hot-swapped binary.

```bash
# 0. Bump CFBundleShortVersionString + CFBundleVersion in Sources/SOURCR/Info.plist
# 1. Expand CHANGELOG.md for that version (≥8 bullets, ≥1200 chars)
cp release.env.example release.env   # once
swift make-icon.swift                # regenerates AppIcon.icns
./create-dmg.sh                      # archive → sign (adhoc) → SOURCR.dmg
git add -A && git commit -m "release: vX.Y" && git push
./install-release.sh                 # install to /Applications + verify launch log
gh release create vX.Y SOURCR.dmg --title "SOURCR vX.Y" --notes-file - <<'EOF'
…release notes…
EOF
```

Launch evidence is written to:

`~/Library/Application Support/SOURCR/Logs/latest.log`

## Architecture

| Piece | Role |
|---|---|
| `SOURCRApp` / `SOURCRAppDelegate` | Accessory app + status-item wiring |
| `StatusPanelController` | Anchored `NSPanel`, outside-click dismiss, leftward expand |
| `AppState` | Watched repos, Diff/Actions mode, snapshots, selection, refresh, reorder |
| `GitService` | Read-only git CLI wrapper |
| `GitHubActionsService` | Read-only `gh` Actions list/detail + remote URL parse |
| `DiffParser` | Unified + side-by-side rendering model |
| `VSCodeSCMView` | Right-column multi-repo SCM + drag reorder |
| `ActionsSCMView` | Right-column Actions list (latest run per workflow) |
| `DiffPane` / `ActionsDetailPane` | Left-expand detail for file diffs or workflow steps |
| `SettingsPanel` | Viewer controls (right column overlay) |

## Notes

- Prefer pressable rows / button styles with hover feedback so clicks feel acknowledged.
- Ad-hoc signing is the default; Gatekeeper rejection is expected.
