# SOURCR

Menu-bar **Source Control** viewer for macOS — a read-only, VS Code / Cursor-style SCM + diff panel.

```
Menu bar icon
    └─ Anchored panel (list column pinned under the status item)
         ├─ Detail pane (diff or workflow steps; opens towards the side with more room)
         └─ SCM column (fixed width)
              ├─ Header: Branches | Diff (icons) · Pin · Detach · Refresh · Add · Settings
              ├─ Multi-repo accordion (drag grip to reorder, in Branches and Diff)
              └─ Flat changes + untracked list (no footer; Quit lives in Settings)
```

## What it does

- Lives in the menu bar (`LSUIElement`)
- Clicking the menu icon recovers a hidden or fully obscured panel; a visible panel on the active Space toggles closed. Showing the panel unhides and activates SOURCR before bringing it forward.
- Watch local git repositories for **Diff** and GitHub repositories for **Branches**, including workflow activity (separate GitHub list from Diff)
- **Branches mode:** Pins the default branch first, then shows remote branches newest-commit first, ten per repository; **Show more** adds ten. Each row shows the branch name (truncated at the end) with a workflow pill and PR badge in fixed columns, and a GitHub-style behind | ahead graph against the default branch beneath them. Rows are separated by dividers. The link icon at the right of each repository header opens its All branches page on GitHub. Right-click a branch to open it on GitHub or **Hide until updated** to hide that commit locally; a changed branch head brings it back, including after relaunch. Branches whose PR is merged (purple) are hidden automatically; pushing a new commit to one brings it back.
- **Workflow pill:** once every workflow on a branch has finished, one pill shows a green tick or red cross with the number of completed workflows. While anything is running the pill is hidden; each running workflow shows its own orange spinner beneath the branch. Repository headers show orange running / red failed counts or a green tick.
- **PR files:** Click a PR badge to open a separate native popover beside SOURCR, with a pointer at that PR's row. The main branch panel keeps its normal width and content height; it never grows to contain PR review. The popover opens up to 50% taller by default (975 points, capped at the display). The right-hand side is one continuous scroll through every file, with full-path headers and wrapped inline diffs, in the same folders-first order as the file tree; clicking a file in the tree jumps to its section, including when clicking the same file again after scrolling. The tree highlight follows the native scroll position at the top of the diff viewport and keeps that row visible, including after file jumps and resizing. PR files and parsed diffs are cached for the running app session, so reopening the same comparison is immediate and closing during a load lets it finish in the background. Existing branch refresh invalidates the cache when the PR head/base comparison changes; comments and checks do not trigger a diff reload. A compact top bar shows the changed-file count, total changed lines and separate additions/deletions for the whole loaded PR. Both PR scrollbars remain visible in reserved gutters beside the content. The collapsible file tree defaults to about 213 points wide, with end ellipses and full-path search. Drag the tree divider to resize the sidebar or the outer bottom corner to resize the popover. **2×** doubles the requested width and height within the available screen space; **1×** restores the default. Native click-away dismissal closes PR review while pinning, detaching and anchoring of the main panel retain their behavior. Right-click the badge to open GitHub. Binary, unavailable and partial patches are labelled; GitHub limits the list to 3,000 files.
- Right-click a PR badge and choose **Hide until updated** to dismiss that observed PR revision locally. The badge returns when the PR changes; GitHub is never modified.
- The mode selector uses icons in **Branches → Diff** order, with tooltips and accessible labels.
- **Diff mode:** Shows combined staged + dirty changes and untracked files on the **current branch**
- Click a file to open an adjoining diff (Inline or Side By Side); click again to collapse
- **Workflow activity:** Running and failed workflows appear below their branch. Click anywhere on a branch row to show or hide its completed workflow results. A small light-grey PR reference such as `(#123)` appears immediately before its CI/CD/other badge when GitHub provides a confirmed run or exact-commit association. Timers update live, and selecting a workflow opens its job and step detail.
- Add a GitHub repository with its GitHub URL, SSH origin, or `owner/repo` in Branches Settings; the header’s Add button opens that form
- Existing Actions folder watches convert to saved GitHub links once; if a folder was already removed, use its pencil button in Branches Settings to set the link
- Click a workflow run to expand job/step detail beside the list; click again to collapse
- The detail pane (Diff, PR files or workflow steps) opens towards whichever side of the display has more room, so the list you clicked stays in place
- Right-click any workflow run and choose **Remove** to permanently ignore that run in SOURCR. It disappears from the board and branch/repository health indicators, including after refresh or relaunch. GitHub history stays intact; new runs of that workflow still appear. Exclusions apply to the GitHub repository and run ID (including reruns of that ID), and survive removing and re-adding the repository. If every result is excluded, the branch is idle rather than reported as passing.
- Repository headings use the GitHub repository name; right-click a heading to open GitHub’s **All branches** page or remove the watch
- Settings manage local Diff repositories separately from the Branches GitHub list
- Defaults to Side By Side + Wrap; both live in Diff Settings
- Follows system light / dark appearance
- Opening the panel (or bringing it to the foreground) immediately refreshes Diff and Actions
- While the panel is visible, Diff and Actions both refresh every ~10s (no manual Refresh needed to catch a finished CD)
- Pin (next to Refresh) keeps the panel in front while you work in other apps; unpin restores normal click-away dismiss
- Panel height follows open Diff/Branches content, growing down to the bottom of the screen before the list scrolls, so collapsed repos don’t leave a tall empty window
- Git/`gh` child processes drain pipes while running and time out (so a huge `git status -uall` or stuck `gh` cannot freeze refreshes until quit)
- In-flight Diff/`gh` refreshes are allowed to finish after the panel hides, so a quick open/close cannot leave a stale dirty count on screen
- Panel stays on the status-item’s display across Diff ↔ Branches resizes (does not follow `NSScreen.main` / focus to another monitor)
- A detached panel is always placed on a connected display: unplugging the monitor it sat on (or relaunching with a saved position from one) moves it onto the nearest remaining display

## Agent endpoint

While SOURCR runs, any agent on this Mac can read everything the app knows, whenever it likes and whether or not the panel is open:

```bash
curl -s http://127.0.0.1:47615/state                 # plain text
curl -s http://127.0.0.1:47615/state.md              # Markdown
curl -s http://127.0.0.1:47615/state.json            # JSON, every field
curl -s http://127.0.0.1:47615/help                  # usage, for the agent itself
ssh mac curl -s http://127.0.0.1:47615/state         # from devbox
```

The report opens with a summary of what needs attention, then covers each watched Diff repository (branch, head, changed and untracked files, full diffs and untracked file contents), each watched GitHub repository (every branch with divergence, PR, check state and workflow runs, with jobs and steps for running and failed runs) and the panel's own state, including the selected PR review and its loaded file patches. Branches the panel hides stay listed, marked merged or hidden until updated. Unlike the panel, the report does not page branches ten at a time; like the panel, its runs come from each repository's newest 50.

| Option | Effect |
|---|---|
| `view=all\|diff\|branches` | Only part of the report |
| `repo=TEXT` | Only repositories whose name, path or owner/repo contains TEXT |
| `diffs=0` | File lists without diffs or contents |
| `refresh=live\|cached\|force` | `live` (default): GitHub data at most 10s old, branch metadata at most 45s. `cached`: never contact GitHub. `force`: fetch everything now |
| `full=1` | Lift the size limits (200 KB per file; 2 MB, 300 files and 30s of git per repository; 25 run details) and add jobs for every run |
| `format=text\|md\|json` | Alternative to the path suffix |

Local git state is always read live. A truncated or omitted file says so in a `Note:` line, and failures appear in the report rather than failing the request. A narrowed report states its scope, and its summary covers only that scope. HTTP 503 means four requests are already running; 504 means one took over three minutes.

It is GET and HEAD only and cannot change anything. The port binds to loopback, so other machines cannot reach it directly; requests from web pages are refused by checking `Host`, `Origin` and `Sec-Fetch-Site`, so a browser tab cannot read your source. Git runs with your global ignore rules and without taking `.git/index.lock`, so ignored secrets stay out and polling cannot fail a concurrent commit. There is no token: any process running on this Mac can read uncommitted changes in your Diff repositories, including a secrets file that no ignore rule covers. Settings shows the URL, and a red message if another process holds the port.

## What it never does

- No branch switching
- No staging / unstaging
- No commit / push / pull
- No rewrite of working tree state

Read-only by design: `GitService` only allows `status`, `diff`, `show`, `rev-parse`, `ls-files`, and `remote get-url`. Workflow monitoring uses the `gh` CLI read-only (`api` / `run view`); PR files use GET requests to GitHub’s files endpoint with the repository’s configured account. The agent endpoint serves GET and HEAD only.

## Requirements

- macOS 14+
- Xcode (for Release `.app` / DMG packaging)
- `git` on `PATH` (`/usr/bin/git`)
- GitHub CLI (`gh`) installed for Actions. Choose a GitHub account per repository in Branches Settings. SOURCR reads that exact account's token read-only with `gh auth token --user` and keeps it in memory, so rebuilds and releases do not trigger Keychain prompts; a token pasted with + is kept in SOURCR's own Keychain item as the fallback.

## Develop

```bash
# Open in Xcode (always via Package.swift, not Recents after moves)
open Package.swift

# Or build from CLI
swift build
swift test
```

Run the `SOURCR` scheme on **My Mac**.

For quick UI iteration without a release, `./run-dev.sh` builds the working tree, signs it with the local `SOURCR Local Signing` identity (ad-hoc if absent), installs it over `/Applications/SOURCR.app`, relaunches it and opens the panel. Keeping one installed copy means Spotlight always opens the latest build. Nothing is committed, pushed, or packaged; the next full send replaces it with the Release build.

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
| `StatusPanelController` | Anchored `NSPanel`, outside-click dismiss, side-aware detail expand |
| `AppState` | Watched repos, Diff/Branches mode, snapshots, selection, refresh, reorder |
| `ExternalProcess` | Shared temp-file + watchdog CLI runner for `git` / `gh` |
| `GitService` | Read-only git CLI wrapper |
| `GitHubActionsService` | Read-only `gh` Actions list/detail + remote URL parse |
| `DiffParser` | Unified + side-by-side rendering model |
| `VSCodeSCMView` | Right-column multi-repo SCM + drag reorder |
| `BranchesSCMView` | Remote branch overview with default-browser GitHub links |
| `DiffPane` / `ActionsDetailPane` / `PullRequestDetailPane` | Side-aware detail for local diffs, workflow steps and PR files |
| `PullRequestFilesService` | Paginated read-only PR patches from GitHub |
| `SettingsPanel` | Viewer controls (right column overlay) |
| `AgentEndpointServer` | Loopback HTTP server and request guards |
| `AgentEndpoint` | Routes `/state`, `/health` and `/help` |
| `AgentReportBuilder` | Collects live git and AppState data into one report |
| `AgentReport` | The report model and its text, Markdown and JSON renderers |

## Notes

- Prefer pressable rows / button styles with hover feedback so clicks feel acknowledged.
- Ad-hoc signing is the default; Gatekeeper rejection is expected.

Release app bundles and archives are kept in `build-release.noindex` so they do not appear as extra apps in Spotlight. DMG staging is removed on exit; `install-release.sh` uses the retained signed app from that directory.

### GitHub accounts in SOURCR

Branches Settings has a **GitHub account** picker beside the repository editor.
Choose an account when adding a repository, or use the pencil beside an existing
watch to change its account. Watches created before 1.18 require an explicit
selection. The binding persists in SOURCR preferences across relaunches and reboots.

Existing CLI account names appear in the picker. Saving a selection reads that
specific account's credential once, verifies its identity, and copies it into
SOURCR's own Keychain service (`com.hannojacobs.SOURCR.github`). The **+** button
connects a new account, or replaces an expired token, using a secure personal
access token field. For fine-grained tokens, select the required repositories
and grant read access to Actions, Contents and Pull requests; organization
approval or SSO authorization may also be needed. Tokens are never saved in
preferences, command-line arguments, logs or source control.

Every Actions request uses the selected SOURCR credential in an isolated child
process environment. SOURCR never runs `gh auth login`, `gh auth switch`,
`gh auth setup-git` or configuration writes. Adding an account does not register
it with the CLI. Missing or rejected credentials produce an error and never fall
back to another account. External GitHub links still use the browser's own login.

Branch and pull-request links open in the Mac’s default browser, using its existing GitHub website session.
