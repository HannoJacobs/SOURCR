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
- Watch multiple local git repositories; drag the grip to reorder them
- Shows combined staged + dirty changes and untracked files on the **current branch**
- Click a file to open a diff to the left (Inline or Side By Side); click again to collapse
- Defaults to Side By Side + Wrap; both live in Settings (right column only)
- Follows system light / dark appearance
- Auto-refreshes while the panel is open; pauses when hidden

## What it never does

- No branch switching
- No staging / unstaging
- No commit / push / pull
- No rewrite of working tree state

Read-only by design: `GitService` only allows `status`, `diff`, `show`, `rev-parse`, and `ls-files`.

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
| `AppState` | Watched repos, snapshots, selection, refresh, reorder |
| `GitService` | Read-only git CLI wrapper |
| `DiffParser` | Unified + side-by-side rendering model |
| `VSCodeSCMView` | Right-column multi-repo SCM + drag reorder |
| `DiffPane` | Inline & side-by-side views |
| `SettingsPanel` | Viewer controls (right column overlay) |

## Notes

- Prefer pressable rows / button styles with hover feedback so clicks feel acknowledged.
- Ad-hoc signing is the default; Gatekeeper rejection is expected.
