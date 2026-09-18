# Changelog

## 1.12

- Actions is now a **branch board**, not a workflow-run list: one row per branch showing how far it has diverged from the default branch (behind ↓ / ahead ↑), its open pull request, and a single collapsed check state — the glance that previously required keeping GitHub's Branches page open in a browser tab.
- Applied the noise rule throughout: workflows that already passed no longer get a row. A branch where everything is green collapses to one tick. Only runs that are **still going** (with a live ticking timer) or that **failed** (with how long they ran before dying) earn a line of their own; the passing runs stay one disclosure click away, and the repo header shows a running/failed count or a single tick.
- Branches with no commit and no workflow run inside the activity window are hidden entirely — the board stays about work actually in flight. The window defaults to 1 day and is settable to 1d / 3d / 7d / All under Actions Settings → Board.
- Branch metadata comes from one paginated GraphQL round trip per repo (heads + last commit + open PR), followed by one aliased `compare` query for the 30 most recently committed branches. Pagination matters: a watched repo here carries 129 branches, and GitHub's `TAG_COMMIT_DATE` ref ordering does **not** actually order branch heads by commit date, so a single unpaginated page could silently drop a branch worked on minutes ago.
- Divergence is resolved from the default branch outward, so `aheadBy`/`behindBy` read exactly as GitHub's Branches page labels them; branches outside the divergence window report divergence as *unknown* rather than drawing a misleading `0`. If the branch query fails outright (SAML, scopes, network), the board still renders rows derived from workflow runs instead of going blank.
- Runs are now deduplicated per **(branch, workflow)** rather than per workflow name — CI on `develop` and CI on a feature branch are different rows — and the run list window grew from 20 to 50 so a busy repo cannot starve quieter branches of their status.
- Branch metadata polls on its own 45s cadence rather than the 10s run poll: divergence and PR state change on a push, not second-to-second, and each repo costs a GraphQL round trip. Manual refresh and opening the panel always force a fresh branch fetch.
- New third window mode: **drag the panel off the menu bar to detach it.** The empty space in the header is now a title bar — drag it to move the window, drag more than 8pt while anchored to tear it off, or double-click to toggle. A detached panel floats above every other app, never auto-dismisses, and remembers its position across hide/show and across launches.
- Detach is implemented with an AppKit drag surface behind the SwiftUI header controls (not a `DragGesture`): the panel is a `.nonactivatingPanel`, so dragging must work without the app ever becoming active, and the window tracks the cursor 1:1 in screen coordinates. Detached windows also drop `.transient` from their collection behaviour so they no longer vanish in Mission Control.
- Both window modes share one geometry rule — fixed right edge, fixed top, detail pane expanding leftward — so detaching, reattaching and expanding never make the content jump sideways. The pin control hides while detached rather than sitting there inert.
- Fixed the header segmented pickers rendering one character per line: the new drag strip claimed `maxWidth: .infinity` as a sibling of the `Diff | Actions` toggle in a 320pt header and starved it to zero width. The toggle now takes its natural width (`fixedSize` + `layoutPriority(1)`) and the drag strip yields the remainder (`layoutPriority(-1)`, `minWidth: 0`); every segmented label also carries `lineLimit(1).fixedSize()` so no picker can wrap per-character under width pressure again.
- Fixed the header swallowing the window's spare height: `PanelDragHandle` is an `NSViewRepresentable`, and one without an `intrinsicContentSize` is greedy in *both* axes. Opening a detail pane made the window taller and every spare point went into the header row instead of the list, leaving the toggle vertically centred in a blank band with the board stranded below it. The handle now declares `noIntrinsicMetric` width by fixed height, the strip takes a definite height rather than a `minHeight` floor, and the header is `fixedSize(vertical:)` so a taller window can only ever feed the list, never the chrome.
- Expansion now caps the panel height instead of sliding the whole window up when it will not fit below its top edge. Growth is downward from a fixed top in both window modes; previously `applyFrame` clamped `origin.y` upward, which moved the top. Only reachable when detached low on a display — anchored under the menu bar there is always room.
- Packaging / full-send: bump CFBundle version to `1.12`, ship `SOURCR.dmg` on GitHub release `v1.12`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.12`.

## 1.11

- Fixed a multi-monitor jump: with two (or more) displays attached, switching Diff ↔ Actions (or any panel height resize) could move the menu-bar panel onto the other screen.
- Root cause: `StatusPanelController.applyFrame` clamped the panel to `statusItem.button.window.screen ?? NSScreen.main`. Apple’s `NSScreen.main` is the **keyboard-focus** display, not the menu-bar display — after clicking inside the panel, clamp math could use the wrong `visibleFrame` and yank `origin.x` across screens.
- On `show()`, SOURCR now captures a sticky open-session anchor: right-edge X, top Y, and the status-item screen’s `visibleFrame` (from the button window’s screen, else the screen intersecting the icon, else `NSScreen.screens.first` — never `NSScreen.main`).
- Diff ↔ Actions / expand / body-height `syncPanelSize` resizes reuse that captured geometry only; they do not re-resolve the screen from focus.
- Hide clears the anchor so the next open re-reads the live status-item position (menu bar moved, display arrangement changed, etc.).
- Fallback when the status item has no window yet uses `NSScreen.screens.first` (menu-bar screen) rather than `NSScreen.main`.
- No change to read-only git/`gh` behavior, refresh cadence, or Diff/Actions data paths — panel positioning only.
- Packaging / full-send: bump CFBundle version to `1.11`, ship `SOURCR.dmg` on GitHub release `v1.11`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.11`.

## 1.10

- Unified `git` and `gh` onto one `ExternalProcess` runner (temp-file stdout/stderr + caller-thread `waitUntilExit` + private watchdog timeout) so Actions no longer keeps the older Pipe/`DispatchQueue.global` drain path that 1.8/1.9 already rejected for git.
- Removed the duplicate `gh` process stack (`ResumeOnce`, `DataBox`, pipe readers, nested timeout `TaskGroup`) — less concurrent machinery, one failure model (`ExternalProcessError` mapped to git/`gh` errors).
- Keeps 1.9 product behavior: in-flight Diff/`gh` refreshes may finish after panel hide; FSEvents Diff probes still pause while hidden; per-repo Diff coalesce and read-only guarantees unchanged.
- Still read-only: shared runner only executes the existing allow-listed `git` subcommands and read-only `gh run list` / `gh run view`.
- Docs/README note the single process runner; regression tests for large `-uall` and concurrent status still cover the shared path via `GitService`.
- Packaging / full-send: bump CFBundle version to `1.10`, ship `SOURCR.dmg` on GitHub release `v1.10`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.10`.
- No intentional UI changes in this release — reliability/architecture only on top of 1.9.
- Closes the half-migrated state called out after 1.9: both CLIs now share the same process IO strategy instead of drifting.

## 1.9

- Fixed a 1.8 regression that could show stale Diff counts (e.g. AGENTIC “4 changes” while Cursor/git were clean): under concurrent refresh, `GitService` waited on a `DispatchQueue.global` exit callback from another global-queue thread, so the pool could self-deadlock and every `git` call false-timed-out after 20s — cancelling mid-flight then left the last good snapshot on screen.
- Live evidence from 1.8 logs: stretches of panel-open with **no** Diff snapshot lines, plus repeated `git remote get-url origin timed out after 20s` on repos where the same command finishes in ~10ms from a shell.
- `GitService.run` now captures stdout/stderr via temp files (not Pipes) and waits on the caller thread with a private-queue watchdog for terminate — avoids both the large-output pipe-buffer deadlock and the 1.8 GCD “wait for another pool thread to signal exit” false-timeout.
- Softened panel-hide cancellation: hiding the panel still cancels debounced FSEvents probes (no background Diff spam), but in-flight Diff/`gh` refreshes are allowed to finish and update the cache so a quick glance cannot freeze yesterday’s dirty count until the next lucky poll.
- Repo-remove still cancels that repo’s in-flight Diff refresh; Actions coalesce + `gh` timeouts from 1.8 remain.
- Still read-only: only process-wait / panel-hide scheduling changed around existing read-only git and `gh` probes.
- Added a regression test that runs 24 concurrent `loadSnapshot` calls and asserts they finish well under the timeout (guards the false-timeout / pool-deadlock class).
- Kept the 1.8 large-`-uall` pipe-drain test; both deadlock classes are now covered.
- Packaging / full-send: bump CFBundle version to `1.9`, ship `SOURCR.dmg` on GitHub release `v1.9`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.9`.

## 1.8

- Fixed a production deadlock that made SOURCR need repeated quits while watching Actions/CD: `GitService` called `waitUntilExit()` **before** draining stdout/stderr, so a large `git status -uall` (pipe output ≳64KB) blocked git on write and SOURCR on wait forever.
- Live evidence from 1.7 sessions: multiple hung `git status --porcelain=v1 -b -uall` children in `/Users/…/phd` stuck in `wt_shortstatus_other → fprintf → __sflush`, with Actions polling dying once those `waitUntilExit` threads exhausted the pool — quit was the only recovery.
- `GitService.run` now reads stdout/stderr concurrently on utility queues while the process runs, then joins; large untracked trees complete instead of wedging the app.
- Added a 20s git command timeout that `terminate`s (then `SIGKILL`s) a stuck child so a single bad repo cannot pin threads indefinitely.
- Diff refresh is now one in-flight task per repo: a newer FSEvents/poll cancels the prior status for that repo instead of stacking N parallel `git status` processes against the same tree.
- FSEvents-driven Diff refreshes are gated on panel visibility (same rule as the 10s timer), and hiding the panel cancels in-flight Diff debounce/repo refresh work plus Actions `gh` work so a background wedge cannot outlive the UI.
- Removing a Diff repo cancels that repo’s in-flight status immediately (no orphaned children after “Remove from Diff”).
- Hardened Actions the same way: `gh` runs drain pipes while running, and each `gh` call has a 25s timeout so the Actions coalesce latch (`isRefreshingActions`) cannot stick true forever after a hung network/CLI call.
- Still read-only: hardening only changes process IO/lifetime around existing `status`/`diff`/`show`/`rev-parse`/`ls-files`/`remote get-url` and read-only `gh run list` / `gh run view`.
- Added a regression test that builds a temp repo with 2000 untracked files and asserts `loadSnapshot` finishes well under the timeout (guards the pipe-deadlock class of failure).
- Packaging / full-send: bump CFBundle version to `1.8`, ship `SOURCR.dmg` on GitHub release `v1.8`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.8`.

## 1.7

- Simplified visible-panel polling: while the menu-bar panel is open and visible, SOURCR now always refreshes **both** Diff and Actions every 10 seconds — not only when a run is in progress or the Actions tab is selected.
- Removed the `shouldPollActions` / `hasRunningActions` gate so a pinned watch (or any open panel) cannot sit on a stale completed/failed/success status for longer than one poll interval, regardless of mode or whether anything looked “running” in the last snapshot.
- The 10s timer still calls the same `refreshVisibleSurfaces` path used on open/foreground, so Diff git status and Actions `gh run list` (+ selected run detail) stay on one cadence and share the existing in-flight coalesce behavior.
- Hidden panel still means no poll traffic: closing the panel stops the network/`gh` work immediately; reopening still does an immediate refresh, then resumes the unconditional 10s loop.
- Docs/README updated to match the simpler rule (“visible → always 10s for Diff + Actions”).
- No change to the read-only guarantee: auto-refresh still only re-runs local git probes and read-only `gh run list` / `gh run view`.
- Manual Refresh buttons remain as a force pull on top of the timer.
- Packaging / full-send: bump CFBundle version to `1.7`, ship `SOURCR.dmg` on GitHub release `v1.7`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.7`.

## 1.6

- Auto-refresh on open: every time the menu-bar panel is shown (status-item click or Dock reopen), SOURCR immediately refreshes both Diff (local git) and Actions (`gh run list` / selected run detail) so the first glance is never a stale snapshot from the previous open.
- Foreground refresh: when the app becomes active while the panel is already visible (typical for a pinned watch), Diff + Actions refresh again immediately so focusing the panel also clears staleness without hunting for the Refresh button.
- While the panel stays visible, a single 10-second timer keeps Diff current and also polls Actions whenever any cached run is still in progress **or** the Actions tab is selected — so a long CD cannot sit “running” for minutes after it finished, and browsing Actions is never more than ~10s behind GitHub.
- Polling is gated on panel visibility: when the panel is hidden there is no Actions network traffic; when it is pinned and watching a live run, the 10s cadence alone is enough to flip status/conclusion and stop the live elapsed timer shortly after completion.
- Mode switches no longer cancel an in-flight Actions list refresh, so you can flip to Diff while a pinned CD continues to be polled in the background and still land on an up-to-date Actions list when you return.
- Overlapping Actions refreshes coalesce (a poll tick during an in-flight `gh` does not cancel and restart the request), which keeps the Refresh spinner honest and avoids stampedes when open + timer + focus all fire close together.
- Manual Refresh buttons remain; they force the same paths the timer uses, so muscle memory still works when you want an immediate pull.
- Still read-only: auto-refresh only re-runs `gh run list` / `gh run view` and local `git status`/`diff` — never re-run, cancel, or approve workflows.
- Packaging / full-send: bump CFBundle version to `1.6`, ship `SOURCR.dmg` on GitHub release `v1.6`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.6`.

## 1.5

- Added an Actions mode alongside Diff: a Diff / Actions segmented control sits at the top of the right column so you can flip between local SCM changes and GitHub Actions without leaving the menu-bar panel.
- Diff and Actions keep **separate** watched-repo lists (legacy `sourcr.watchedRepos` migrates into Diff only). Mode-specific Settings add/remove repos for the active mode.
- For each Actions repo SOURCR resolves `origin` to a GitHub `owner/repo` (including SSH host aliases like `git@github.com-hb:…`) and lists workflow runs via the read-only `gh` CLI — no Azure remotes, no mutating Actions APIs.
- The Actions list shows only the **latest run per workflow name** (running first). A new in-progress run replaces the prior pass/fail for that workflow, so history does not pile up and status filters are unnecessary.
- Actions loads only on manual Refresh (no polling / no fetch-on-toggle). Clicking a run expands a detail pane to the left using the same anchored-panel gesture as Diff; re-clicking collapses it.
- The left Actions pane shows workflow name, branch, event, live elapsed time (ticking while in progress), a step progress bar, and a condensed step list (current window ± neighbors with ellipsis) so 90-step deploy jobs stay readable.
- Status chrome matches GitHub’s mental model: spinner for in-progress, check for success, x for failure, plus CI/CD/misc badges derived from the workflow name. “Open on GitHub” jumps to the run URL when you need the full log.
- Still strictly read-only: SOURCR never cancels, re-runs, approves, or otherwise mutates workflows. `GitService` only gained a read-only `remote get-url` helper for origin resolution; Actions traffic goes through `gh run list` / `gh run view`.
- Pin toggle (next to Refresh in Diff and Actions) keeps the panel floating above other apps and skips outside-click dismiss; unpin restores normal menu-bar auto-close. Pin state persists in UserDefaults.
- Panel height now fits the open Diff/Actions content (capped at the prior 560pt max): collapsing repos shrinks the window so a pinned single-repo Actions watch doesn’t waste screen space; opening the detail pane still enforces a readable minimum height.
- Repo accordion open/collapse state is remembered per mode (Diff and Actions separately) across mode switches and relaunches.
- Actions elapsed time uses the latest attempt’s `startedAt` (not original `createdAt`), so a re-run after failure shows time since that re-run instead of including the prior attempt and idle gap.
- Actions timing is hardened for missing/`0001-` timestamps, mild clock skew, inverted start/end values, and completed runs where job completion is preferred over a later `updatedAt` bump.
- Packaging / local ship: bump CFBundle version to `1.5`, rebuild `SOURCR.dmg`, and reinstall `/Applications/SOURCR.app` with launch-log proof for version/build `1.5`.

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
