# Changelog

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
