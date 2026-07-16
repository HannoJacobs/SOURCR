# Changelog

## 1.4

- Fixed nested-folder changes not appearing: files inside an entirely-untracked (new) directory were completely missing from the Changes list, and the directory itself rendered as a single broken “new file” diff with no content.
- Root cause: `GitService.loadSnapshot` ran `git status --porcelain=v1 -unormal`, and `-unormal` collapses a wholly-untracked directory into one `dir/` entry instead of enumerating the files within it. SOURCR then treated that directory path as an untracked “file”, so nested contents never surfaced and the synthetic addition diff had nothing to read.
- Switched the status probe to `-uall`, which lists every untracked file individually — including arbitrarily deep nested paths like `a/b/c/file.txt` — so each real file shows up as its own row with a proper untracked-addition diff.
- Git continues to honor `.gitignore` under `-uall`, so ignored trees (e.g. `node_modules`, `.build`) are not walked; the change only expands directories that are genuinely untracked and would be committed.
- Verified against a freshly created `nest_0/nest_1/…` fixture: all three nested files (`test0.txt`, `nest_0/test1.txt`, `nest_0/nest_1/test2.txt`) now enumerate correctly instead of one directory blob.
- No change to the read-only guarantee: `GitService` still only runs status/diff/show/rev-parse/ls-files and never stages, checks out, or mutates the working tree.
- This is a correctness release on top of the `1.3` icon work; the VS Code-style right-column SCM layout and left-expanding diff behavior are unchanged.
- Packaging / full-send: bump CFBundle version to `1.4`, ship `SOURCR.dmg` on GitHub release `v1.4`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.4`.

## 1.3

- Replaced the placeholder AppIcon lettermark (a bold white “S” on a flat blue squircle) with a purpose-drawn SOURCR mark that reads as Source Control instead of a generic initial.
- The new icon is a deep indigo rounded square with a white git branch fork (stem, fork curve, side branch, and hollow commit nodes), plus red/green vertical bars that echo the side-by-side diff pane.
- Tip-node halo accent calls out the current HEAD tip so the glyph still feels “live” at larger Finder sizes without adding text.
- Regenerated the full `AppIcon.icns` size ladder via `make-icon.swift` (16 through 1024) using Core Graphics / `NSBezierPath` so the mark scales cleanly instead of relying on emoji or system fonts.
- Menu-bar status item remains the template `arrow.triangle.branch` SF Symbol (correct for monochrome menu-bar chrome); the AppIcon change is the Finder / Applications / Dock-adjacent identity.
- Kept the product name firmly **SOURCR** in packaging and icon tooling paths (`AppIcon.icns`, `/tmp/SOURCR.iconset`) — no “Sorcerer” branding.
- No runtime SCM behavior changes in this release; this ships icon + `make-icon.swift` + CFBundle bump only on top of the `1.2` stale-diff fix.
- Packaging / full-send: bump CFBundle version to `1.3`, ship `SOURCR.dmg` on GitHub release `v1.3`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.3`.

## 1.2

- Fixed a stale open-diff state: if you had a file’s diff expanded on the left and then removed that change in the working tree (so the path no longer appears under Changes / Untracked), SOURCR could keep the left pane open with “Select a changed file to view its diff” and leave the owning repo highlighted as if a diff were still active.
- Root cause: after a successful status refresh, `AppState` only reloaded the open diff when `selectedFile` still resolved against the new snapshot. When the path left the porcelain list, `selectedFile` became `nil`, so neither a reload nor a clear ran — `selectedFileID`, `diffRepoID`, and `isExpanded` stayed set indefinitely.
- Added `reconcileOpenDiff(afterRefreshing:)` so every snapshot update for the repo that owns the open selection either reloads the still-listed file or calls `clearSelection()`, which collapses the left pane and drops the active-repo highlight.
- Manual Refresh (force), debounced `.git` FSEvents refreshes, and the background poll all share that reconcile path, so fixing a change outside SOURCR and waiting for auto-refresh or clicking the refresh arrow both close the empty left panel.
- On a failed refresh for the repo that currently owns the open diff, selection is cleared as well so an error snapshot cannot leave a phantom expanded layout behind.
- Kept the tool strictly read-only: reconciliation only inspects status / listed files and never stages, checks out, or mutates the working tree.
- This is a small reliability release focused on selection lifecycle correctness after working-tree changes disappear; the VS Code-style right-column SCM layout from `1.1` is unchanged.
- Packaging / full-send: bump CFBundle version to `1.2`, ship `SOURCR.dmg` on GitHub release `v1.2`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.2`.

## 1.1

- Rebuilt the menu-bar panel around a VS Code / Cursor workspace layout: Source Control lives in a fixed right-hand column, and selecting a changed file expands a diff pane only to the left so the SCM column never slides sideways under the cursor.
- Replaced the floating / disconnectable panel behavior with a status-item–anchored `NSPanel` whose right edge stays pinned to the menu-bar icon. Expanding and collapsing a diff grows and shrinks leftward only; clicking outside the panel or the status item dismisses it.
- Combined staged and unstaged modifications into one flat Changes list under each repo (plus untracked files). Removed the unused commit-message text box, the nested “Changes” section header, the top “SOURCE CONTROL” chrome, the Read-only footer label, and the Close button on the diff header — re-clicking a selected file collapses the diff.
- Moved Refresh, Add Repository, and Settings into the bottom footer next to Quit. Settings now opens only inside the right-hand column (never covering the open diff), so Inline / Side By Side and Wrap / No Wrap can be changed while the live diff updates on the left.
- Viewer defaults are Side By Side + Wrap on every launch. Settings exposes both as accent-colored segmented controls (Inline | Side By Side and No Wrap | Wrap) with clear on-state color feedback; the previous single Wrap toggle pill is gone.
- Fixed side-by-side overlap where long lines from the left column bled into the right: each pane is strictly half-width, text is constrained and clipped, wrap stays inside its column, and no-wrap truncates with an ellipsis instead of overflowing.
- Added drag-to-reorder for watched repositories using the same grip-handle / floating preview / accent insertion-line dynamics as NOTR. Order is persisted through UserDefaults via `moveRepo(from:to:)`.
- Performance and reliability: Git status/diff work runs off the main actor, `.git` watchers are debounced, refreshes pause when the panel is hidden, and the first Add Repository Finder sheet no longer greys out Favorites (temporary `.regular` activation around `NSOpenPanel`).
- Packaging / full-send: bump CFBundle version to `1.1`, keep ad-hoc DMG install evidence gated on launch logs under Application Support, and ship the complete UI + panel-controller change set (including `StatusPanelController`, `SOURCRLayout`, and `VSCodeSCMView`) as the live GitHub `v1.1` release asset.

## 1.0

- Ship the first SOURCR menu-bar Source Control viewer as a personal macOS app modeled on the DICTATR packaging and release pipeline (SPM + MenuBarExtra + ad-hoc DMG install).
- Add multi-repository watching with persistent repo list in UserDefaults, Finder reveal, and remove-from-list actions from the repository sidebar.
- Render a VS Code / Cursor-like SCM file list grouped into Staged Changes, Changes (dirty/unstaged), Untracked Files, and an optional Unchanged sample for the current branch only.
- Keep the tool strictly read-only: GitService allowlists status/diff/show/rev-parse/ls-files and never checks out branches, stages, commits, or pushes.
- Expand the menu-bar popover into a wider panel when a changed file is selected and show the diff on the right with Inline and Side By Side layouts.
- Parse unified diffs into line-oriented models with addition/deletion/context/hunk coloring that follows system light and dark appearance via semantic SwiftUI colors.
- Auto-refresh repository snapshots on a short timer and via FSEvents-style DispatchSource watches on each repo `.git` directory so the panel stays current while open.
- Provide settings for unchanged-file sampling and default diff layout, plus AppDiagnostics file logging under Application Support for install/launch verification evidence.
- Include create-dmg.sh / install-release.sh / release-common.sh with changelog verbosity gates, ad-hoc codesign verification, and launch-log proof that `/Applications/SOURCR.app` started at the expected version/build.
- Add DiffParser unit tests covering unified parsing, side-by-side edit pairing, and synthetic untracked-file additions so basic diff rendering stays covered in CI.
