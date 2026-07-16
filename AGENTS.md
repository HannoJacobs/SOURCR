# SOURCR Repo Rules

## Full Send

In this repo, a "full send" means full send. The work is not done at code changes, not done at a local build, and not done at "the release should pick it up."

A full send includes all of the following:

1. Implement the requested change in the repo.
2. Update release metadata and docs that define the shipped state when needed.
3. Commit the entire required change set to git. Do not leave required release, docs, packaging, or website-triggering changes uncommitted.
4. Push the full change set to GitHub.
5. Build the Release app artifact.
6. Package the current `SOURCR.dmg`.
7. Upload the current `SOURCR.dmg` to the live GitHub release path.
8. Make sure the GitHub-hosted release state is live and that anything expected to update from GitHub is actually triggered for release, including the website/download path when applicable.
9. Update the local DMG/build artifacts so this Mac is using the current shipped build, not a stale previous package.
10. Install the built app to `/Applications/SOURCR.app` on this Mac.
11. Launch the installed app.
12. Verify the live installed app from concrete evidence, not assumption.

Required verification evidence for a full send:

- the installed app log must show `/Applications/SOURCR.app`
- the installed app log must show the expected version/build
- the installed app log must show the requested behavior is live when that behavior can be exercised locally
- the GitHub release path used by the website/download flow must point at the newly shipped DMG when that path is part of the release flow
- any failure in build, packaging, upload, install, launch, or verification must be surfaced immediately

Do not call something a full send if it only compiles, only ships a commit, only pushes code, only uploads a DMG, or only assumes GitHub/Pages/release propagation happened without verifying the live state.

## Safety Invariant

SOURCR is a **read-only** diff viewer. Agents must never add git-mutating capabilities (commit, push, checkout, branch switch, stage, unstage, stash, reset, clean, rebase, merge). Displaying the current branch name is fine; changing it is not.

## Debug Research First

For sticky debugging issues, Swift/macOS platform behavior, codesigning, MenuBarExtra hit-testing, or anything that smells like a system/framework edge case, spend significant time searching the web for relevant context before attempting to debug.
