# SOURCR

Menu-bar **Source Control** viewer for macOS — a read-only, VS Code / Cursor-style SCM + diff panel.

```
Menu bar icon
    └─ Popover panel
         ├─ Repositories sidebar (multi-repo)
         ├─ Staged / Changes / Untracked [/ Unchanged]
         └─ Diff pane (Inline | Side By Side) — expands when a file is selected
```

## What it does

- Lives in the menu bar (`LSUIElement`)
- Watch multiple local git repositories
- Shows **staged**, **dirty (unstaged)**, **untracked**, and optionally a sample of **unchanged** files on the **current branch**
- Click a file to open a VS Code-like diff (inline or side-by-side)
- Follows system light / dark appearance
- Auto-refreshes on a timer and when `.git` changes

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

## Release / install (DICTATR-style)

```bash
cp release.env.example release.env   # once
swift make-icon.swift                # regenerates AppIcon.icns
./create-dmg.sh                      # archive → sign (adhoc) → SOURCR.dmg
./install-release.sh                 # install to /Applications + verify launch log
```

Launch evidence is written to:

`~/Library/Application Support/SOURCR/Logs/latest.log`

## Architecture

| Piece | Role |
|---|---|
| `SOURCRApp` | `MenuBarExtra(.window)` entry |
| `AppState` | Watched repos, snapshots, selection, refresh |
| `GitService` | Read-only git CLI wrapper |
| `DiffParser` | Unified + side-by-side rendering model |
| `MenuBarView` | Compact / expanded SCM chrome |
| `DiffPane` | Inline & side-by-side views |

## Notes

- Prefer `onTapGesture` + `contentShape(Rectangle())` over `Button` inside `MenuBarExtra(.window)` (same lesson as DICTATR).
- Ad-hoc signing is the default; Gatekeeper rejection is expected.
