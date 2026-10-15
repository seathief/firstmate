#!/usr/bin/env bash
# sync.sh - merge upstream main into this fork's main, daily and unattended.
#
# The layout is fixed: `origin` is the fork, `upstream` is the project the fork
# came from, and the branch is `main`. There are no option flags and no model
# call. A conflict is never resolved here; it is reported and left alone.
#
# Each run:
#   1. takes a single-run lock and creates a throwaway worktree under
#      ${TMPDIR:-/tmp}/fm-upstream-sync, never the primary checkout;
#   2. fetches origin/main and upstream/main;
#   3. exits 0 when upstream/main is already contained in origin/main;
#   4. otherwise merges upstream/main into origin/main in that worktree:
#        - any failed merge, including a binary, rename, or modify/delete
#          conflict, is aborted, nothing is pushed, one note is left for
#          firstmate through the fleet home's bin/fm-inbox.sh, and the run
#          exits 1;
#        - a clean merge runs the repository's own test entry point,
#          bin/fm-test-run.sh with its changed-file selection, and pushes
#          origin/main only when the tests pass; a failure pushes nothing,
#          leaves the same note, and exits 1;
#   5. always removes the throwaway worktree and releases the lock.
# The push is a plain fast-forward push: it never forces, and it refuses to run
# when origin and upstream resolve to the same remote.
# No credential is read, printed, or stored, and sudo is never used.
#
# Usage:
#   sync.sh [-h|--help]
#
# Environment:
#   FM_HOME   fleet home whose inbox receives failure notes, when set
#   TMPDIR    holds the run lock and the throwaway worktree
#
# Exit status: 0 when the fork is up to date, synced, or another run holds the
# lock; 1 on any failure.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  awk 'NR > 1 && /^set -/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$SELF"
}

LOG=""
die() { printf 'sync.sh: %s\n' "$*" >&2; [ -n "$LOG" ] && printf 'sync.sh: %s\n' "$*" >>"$LOG"; exit 1; }
log() { printf '%s\n' "$*"; [ -n "$LOG" ] && printf '%s\n' "$*" >>"$LOG"; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) printf 'sync.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

BRANCH=main
ORIGIN=origin
UPSTREAM=upstream
LIMIT_FETCH=600
LIMIT_MERGE=300
LIMIT_TEST=3600
LIMIT_PUSH=600
LOG_DIR="${FM_HOME:-$HOME}/state/upstream-sync"
STATE_DIR="${TMPDIR:-/tmp}/fm-upstream-sync"
WORKTREE=""
LOCK_HELD=""

REPO="$(git -C "$SELF" rev-parse --show-toplevel 2>/dev/null)" || die "$SELF is not inside a git checkout"
[ -d "$REPO" ] || die "no such directory: $REPO"
REPO="$(cd "$REPO" && pwd -P)"
# An unattended run must fail rather than block on a credential prompt.
export GIT_TERMINAL_PROMPT=0

cleanup() {
  if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
    log "removing throwaway worktree $WORKTREE"
    # The worktree is this run's own scratch checkout and the run log already
    # holds the evidence, so an unfinished merge in it is discarded.
    git -C "$REPO" worktree remove --force "$WORKTREE" >>"$LOG" 2>&1 || rm -rf "$WORKTREE"
  fi
  [ -n "$LOCK_HELD" ] && rm -rf "$STATE_DIR/lock"
  return 0
}
trap 'rc=$?; cleanup; exit $rc' EXIT

# Reduce supported SSH and HTTPS remote spellings to host/path, ignoring credentials.
normalize_url() {
  python3 -c 'import sys, urllib.parse
u = sys.argv[1]
if "://" not in u:
    user, sep, rest = u.partition("@")
    if not sep:
        print("local/" + u.removesuffix(".git").rstrip("/")); raise SystemExit
    host, sep, path = rest.partition(":")
    if not sep: raise SystemExit("unsupported remote URL")
else:
    parsed = urllib.parse.urlsplit(u)
    host, path = parsed.hostname or "", parsed.path.lstrip("/")
print((host.lower() + "/" + path.removesuffix(".git")).rstrip("/"))' "$1"
}

# Refuses to run when the remote a push would reach is upstream, before any
# fetch and again before the push.
require_origin_is_not_upstream() {
  local origin_push upstream_fetch upstream_push
  origin_push="$(git -C "$REPO" remote get-url --push "$ORIGIN" 2>/dev/null)" || die "no such remote: $ORIGIN"
  upstream_fetch="$(git -C "$REPO" remote get-url "$UPSTREAM" 2>/dev/null)" || die "no such remote: $UPSTREAM"
  upstream_push="$(git -C "$REPO" remote get-url --push "$UPSTREAM" 2>/dev/null)" || die "no such remote: $UPSTREAM"
  origin_push="$(normalize_url "$origin_push")"
  upstream_fetch="$(normalize_url "$upstream_fetch")"
  upstream_push="$(normalize_url "$upstream_push")"
  [ "$origin_push" != "$upstream_fetch" ] && [ "$origin_push" != "$upstream_push" ] \
    || die "refusing to run: a push to $ORIGIN would reach $UPSTREAM"
}

acquire_lock() {
  local holder="" holder_cmd=""
  if mkdir "$STATE_DIR/lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$STATE_DIR/lock/pid"
    LOCK_HELD=1
    return 0
  fi
  [ -r "$STATE_DIR/lock/pid" ] && holder="$(cat "$STATE_DIR/lock/pid" 2>/dev/null)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    holder_cmd="$(ps -p "$holder" -o command= 2>/dev/null)"
    case "$holder_cmd" in
      *upstream-sync/sync.sh*) log "another sync is already running (pid $holder); nothing to do"; return 1 ;;
    esac
    log "clearing a lock held by live pid $holder, which is not this script"
  else
    log "clearing a stale lock left by pid ${holder:-unknown}"
  fi
  rm -rf "$STATE_DIR/lock"
  mkdir "$STATE_DIR/lock" 2>/dev/null || die "cannot take the run lock at $STATE_DIR/lock"
  printf '%s\n' "$$" >"$STATE_DIR/lock/pid"
  LOCK_HELD=1
  return 0
}

# run_limited <seconds> <dir> <command> [args...]
# Runs the command in its own process group and appends output to the run log.
run_limited() {
  local secs=$1 dir=$2 pid="" killer="" rc=0
  shift 2
  python3 -c 'import os, sys
os.setsid()
os.chdir(sys.argv[1])
os.execvp(sys.argv[2], sys.argv[2:])' "$dir" "$@" >>"$LOG" 2>&1 &
  pid=$!
  if [ "$secs" -gt 0 ] 2>/dev/null; then
    ( sleep "$secs"; kill -TERM -- "-$pid" 2>/dev/null; sleep 5; kill -KILL -- "-$pid" 2>/dev/null ) >>"$LOG" 2>&1 &
    killer=$!
  fi
  wait "$pid"
  rc=$?
  if [ -n "$killer" ]; then
    kill "$killer" 2>/dev/null
    wait "$killer" 2>/dev/null
  fi
  if [ "$rc" -ge 128 ] 2>/dev/null && [ "$secs" -gt 0 ] 2>/dev/null; then
    log "the command exceeded its ${secs}s limit (ended with status $rc)"
  fi
  return "$rc"
}

notify() { # <body>
  local script="$REPO/bin/fm-inbox.sh" body=$1
  if [ ! -x "$script" ]; then
    log "no executable inbox script at $script; firstmate was not notified"
    return 0
  fi
  # Export FM_HOME only when it is set: an empty value would defeat the inbox
  # script's own fallback and aim the note at /state/inbox.
  if [ -n "${FM_HOME:-}" ]; then export FM_HOME; fi
  # One note per day: a repeat failure replays the original capture instead of
  # queueing a second wake for the same cause.
  if "$script" note --request-id "upstream-sync-$(date +%Y%m%d)" "$body" >>"$LOG" 2>&1; then
    log "notified firstmate through $script"
  else
    log "could not write the firstmate note; see $LOG"
  fi
}

fail_task() { # <note body>
  log "FAILED: $1"
  notify "upstream-sync in $REPO: $1 (log: $LOG)"
  exit 1
}

run_sync() {
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  mkdir -p "$LOG_DIR" || die "cannot create $LOG_DIR"
  LOG="$LOG_DIR/sync-$(date +%Y%m%d-%H%M%S)-$$.log"
  : >"$LOG" || die "cannot write $LOG"

  log "== upstream sync $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
  log "base checkout: $REPO (branch $BRANCH)"
  require_origin_is_not_upstream

  acquire_lock || return 0

  local origin_ref="refs/remotes/$ORIGIN/$BRANCH" upstream_ref="refs/remotes/$UPSTREAM/$BRANCH"
  WORKTREE="$STATE_DIR/wt-$$"
  rm -rf "$WORKTREE"
  git -C "$REPO" worktree add --detach --quiet "$WORKTREE" >>"$LOG" 2>&1 \
    || fail_task "could not create a throwaway worktree under $STATE_DIR"

  if ! run_limited "$LIMIT_FETCH" "$WORKTREE" git fetch --quiet --no-tags "$ORIGIN" "+refs/heads/$BRANCH:$origin_ref"; then
    fail_task "could not fetch $ORIGIN/$BRANCH"
  fi
  if ! run_limited "$LIMIT_FETCH" "$WORKTREE" git fetch --quiet --no-tags "$UPSTREAM" "+refs/heads/$BRANCH:$upstream_ref"; then
    fail_task "could not fetch $UPSTREAM/$BRANCH"
  fi
  git -C "$WORKTREE" checkout --quiet --detach "$origin_ref" >>"$LOG" 2>&1 \
    || fail_task "could not check out $ORIGIN/$BRANCH in the worktree"

  if git -C "$WORKTREE" merge-base --is-ancestor "$upstream_ref" "$origin_ref"; then
    log "already up to date: $UPSTREAM/$BRANCH is contained in $ORIGIN/$BRANCH"
    return 0
  fi

  if ! run_limited "$LIMIT_MERGE" "$WORKTREE" git merge --quiet -m "Merge $UPSTREAM/$BRANCH into $BRANCH" "$upstream_ref"; then
    local conflicted
    conflicted="$(git -C "$WORKTREE" diff --name-only --diff-filter=U)"
    [ -n "$conflicted" ] && log "conflicted files:
$(printf '%s\n' "$conflicted" | sed 's/^/  - /')"
    # Nothing is resolved here: drop the unfinished merge and report it.
    git -C "$WORKTREE" merge --abort >>"$LOG" 2>&1 || true
    fail_task "the merge of $UPSTREAM/$BRANCH did not finish cleanly; nothing was pushed"
  fi
  log "merged $UPSTREAM/$BRANCH cleanly"

  log "running bin/fm-test-run.sh --changed in the worktree (limit ${LIMIT_TEST}s)"
  if ! run_limited "$LIMIT_TEST" "$WORKTREE" "$WORKTREE/bin/fm-test-run.sh" --changed; then
    fail_task "tests failed after merging $UPSTREAM/$BRANCH; the merge was not pushed"
  fi
  log "tests passed"

  require_origin_is_not_upstream
  git -C "$WORKTREE" merge-base --is-ancestor "$upstream_ref" HEAD \
    || fail_task "the merge does not contain $UPSTREAM/$BRANCH; refusing to push"
  if ! run_limited "$LIMIT_PUSH" "$WORKTREE" git push "$ORIGIN" "HEAD:refs/heads/$BRANCH"; then
    fail_task "the push to $ORIGIN/$BRANCH was refused (never forced, nothing overwritten)"
  fi
  log "pushed $UPSTREAM/$BRANCH into $ORIGIN/$BRANCH"
  log "OK"
  return 0
}

run_sync
