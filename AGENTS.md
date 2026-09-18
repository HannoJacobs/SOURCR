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
7. Upload the current `SOURCR.dmg` to the live GitHub release path (see **GitHub Identity** — this resolves automatically).
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

## GitHub Identity

This repo belongs to the **personal** account `HannoJacobs`, never the Healthbridge
account `HannoJacobsHB`. This is handled for you — `gh` resolves to the right account
automatically anywhere under `~/Documents/Code/`, including from a non-interactive
shell. You do not need to do anything.

How it works, so you do not undo it:

- `~/Documents/Code/.envrc` exports `GH_TOKEN` for `HannoJacobs`, read live from gh's
  keychain. Nothing sensitive is stored in the file.
- direnv only hooks the interactive shell *prompt*, so `zsh -c` / `bash -c` — every
  coding agent, script and MCP server — never loaded it and silently fell through to
  whatever account was globally active.
- `~/.local/bin/gh` is a shim, ahead of Homebrew's gh on `PATH`. It applies whatever
  `.envrc` governs the current directory, then execs the real gh. It holds no account
  name and no path list: the `.envrc` files are the single source of truth, so a new
  personal directory needs a new `.envrc`, not a shim edit.

Confirm with `gh api user --jq .login` → `HannoJacobs` before any release step.

To undo the whole mechanism and return every directory to plain Homebrew `gh` on the
global account, delete the shim — nothing else depends on it:

```bash
rm ~/.local/bin/gh
```

Editing an `.envrc` revokes its direnv approval and the directory silently reverts to
the global account until `direnv allow <dir>` is run again.

**Never run `gh auth switch` to fix an identity problem here.** It mutates the global
account for every other repo on this machine, including Hanno's Healthbridge work. If
gh reports the wrong account, the shim or the `.envrc` is broken — say so rather than
reaching for global state. An explicit `GH_TOKEN` in the environment always wins over
the shim, so a caller that deliberately chose an identity is left alone.

## Safety Invariant

SOURCR is a **read-only** diff viewer. Agents must never add git-mutating capabilities (commit, push, checkout, branch switch, stage, unstage, stash, reset, clean, rebase, merge). Displaying the current branch name is fine; changing it is not.

## Debug Research First

For sticky debugging issues, Swift/macOS platform behavior, codesigning, MenuBarExtra hit-testing, or anything that smells like a system/framework edge case, spend significant time searching the web for relevant context before attempting to debug.
