# Upstream sync for a firstmate fork

This directory keeps a fork of `kunchenguid/firstmate` current with its upstream without disturbing upstream's own tree.
Everything here lives under this one new path on purpose: the upstream project does not touch `ops/upstream-sync/`, so the daily merge this tool performs has nothing to conflict over.
The script and its test stay outside `bin/` and `tests/` for the same reason.

The design is deliberately minimal: the script merges and pushes, or it does nothing and reports.
It never resolves a conflict and never calls a model.

## Layout

- [sync.sh](sync.sh) merges upstream `main` into the fork's `main`, runs the repository's own tests, and pushes only on a clean, green merge.
- [sync.test.sh](sync.test.sh) is the offline regression: fake bare `upstream` and `origin` repositories, a stubbed test entry point, and a stubbed inbox script.
- [com.seathief.firstmate-upstream-sync.plist](com.seathief.firstmate-upstream-sync.plist) is the LaunchAgent template for the daily 05:00 run.

## What a run does

1. Takes a single-run lock and creates a throwaway git worktree under `${TMPDIR:-/tmp}/fm-upstream-sync`; the primary checkout is never modified.
2. Fetches `origin/main` and `upstream/main`.
3. Stops without changes when `upstream/main` is already contained in `origin/main`.
4. Otherwise merges `upstream/main` into `origin/main`.
   - Any merge that does not finish cleanly, including a content, binary, rename, or modify/delete conflict, is aborted.
     Nothing is pushed, one note is left for firstmate through the fleet home's `bin/fm-inbox.sh`, and the run exits non-zero.
     Firstmate then handles the conflict through its ordinary flow, in an isolated copy with the full checks and a pull request.
   - A clean merge runs the repository's own test entry point, `bin/fm-test-run.sh --changed` inside the worktree.
     Tests pass: the merge is pushed to `origin/main`. Tests fail: nothing is pushed, the same note is left, the run exits non-zero.
5. Always removes the throwaway worktree and releases the lock.

The remotes are fixed: `origin` is the fork, `upstream` is `kunchenguid/firstmate`, and the branch is `main`.
There are no option flags.
The push is a plain fast-forward push and never forces; the run refuses to start when `origin` and `upstream` resolve to the same remote, so upstream can never be written to.
The script reads no credential, prints none, and never uses sudo.

## When a run stops without pushing

The full engine log stays in `$FM_HOME/state/upstream-sync/sync-<timestamp>.log`, and the same failure is left as a note for firstmate, so the captain is told without reading this directory.
Each failure writes a fresh note so firstmate is notified every time.

## Running it by hand

```fish
env FM_HOME=$HOME/fm-homes/primary ~/github/firstmate/ops/upstream-sync/sync.sh
```

`FM_HOME` is optional; without it the log goes to `$HOME/state/upstream-sync` and the inbox script falls back to its own default home.

## Installing the daily LaunchAgent

The captain installs this; firstmate workers never run `launchctl`.
Replace the placeholders in the template from `ops/upstream-sync/`, write it to `~/Library/LaunchAgents/`, and bootstrap it:

```fish
set -l repo ~/github/firstmate
set -l fm_home ~/fm-homes/primary
mkdir -p $fm_home/state/upstream-sync
mkdir -p ~/Library/LaunchAgents
sed -e "s|__REPO__|$repo|g" -e "s|__FM_HOME__|$fm_home|g" -e "s|__USER_HOME__|$HOME|g" \
    $repo/ops/upstream-sync/com.seathief.firstmate-upstream-sync.plist \
    > ~/Library/LaunchAgents/com.seathief.firstmate-upstream-sync.plist
plutil -lint ~/Library/LaunchAgents/com.seathief.firstmate-upstream-sync.plist
launchctl bootstrap gui/(id -u) ~/Library/LaunchAgents/com.seathief.firstmate-upstream-sync.plist
```

Verify or force a run now:

```fish
launchctl kickstart -p gui/(id -u)/com.seathief.firstmate-upstream-sync
```

Remove it again:

```fish
launchctl bootout gui/(id -u)/com.seathief.firstmate-upstream-sync
rm ~/Library/LaunchAgents/com.seathief.firstmate-upstream-sync.plist
```

The template runs daily at 05:00 through `StartCalendarInterval`, chosen to stay clear of the 03:30 job.
It does not run at load, and it is not kept alive, so a stopped run waits for the next day or for the captain.

## Testing

```sh
bash ops/upstream-sync/sync.test.sh
```

The test runs offline in a temp root and covers an already-current fork, a clean merge that pushes, a content conflict, a modify/delete conflict, a failing test run, and the refusal when `origin` resolves to `upstream`.
