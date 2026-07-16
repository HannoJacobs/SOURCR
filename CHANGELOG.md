# Changelog

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
