#!/usr/bin/env bash
# sync.test.sh - offline regression for ops/upstream-sync/sync.sh.
#
# Builds fake bare `upstream` and `origin` repositories plus a primary clone in
# a temp root, then drives the real script against them with a stubbed
# bin/fm-test-run.sh and a stubbed bin/fm-inbox.sh.
# Runs offline with no credentials and no model call.
#
# Cases:
#   1. already up to date   -> exits 0, runs no test, pushes nothing, no note
#   2. clean merge          -> merges and pushes without running tests
#   3. content conflict     -> aborts, pushes nothing, leaves a firstmate note
#   4. modify/delete conflict -> same refusal path
#   5. origin resolves to upstream -> refuses before doing any work
#   6. origin's push URL is an equivalent spelling of upstream -> refuses
# Cases 1-5 also prove the throwaway worktree is gone afterwards.
#
# Run: bash ops/upstream-sync/sync.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SYNC="$HERE/sync.sh"

# Fixture Git isolation: no host global/system config, no inherited repository
# location. Identity comes from the exported variables below.
# shellcheck source=tests/git-config-helpers.sh
. "$HERE/../../tests/git-config-helpers.sh"
export GIT_AUTHOR_NAME=fm-sync-test GIT_AUTHOR_EMAIL=fm-sync-test@example.invalid
export GIT_COMMITTER_NAME=fm-sync-test GIT_COMMITTER_EMAIL=fm-sync-test@example.invalid

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { failures=$((failures + 1)); printf 'not ok - %s\n' "$1"; }
check() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_contains() { # <desc> <needle> <haystack>
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1 (missing '$2' in: $3)" ;;
  esac
}
check_absent() { # <desc> <path>
  if [ -e "$2" ]; then fail "$1 ($2 exists)"; else pass "$1"; fi
}

if [ ! -f "$SYNC" ]; then
  printf 'not ok - sync.sh is missing at %s\n' "$SYNC"
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fm-sync-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# make_world <name>: builds $W with upstream.git, origin.git, primary/, work/.
make_world() {
  W="$TMP/$1"
  mkdir -p "$W"
  git -c init.defaultBranch=main init -q "$W/work"
  mkdir -p "$W/work/bin" "$W/work/docs"
  printf 'base\n' >"$W/work/docs/note.md"
  printf 'keep\n' >"$W/work/docs/other.md"
  printf 'delete me\n' >"$W/work/docs/delete-me.md"
  cat >"$W/work/bin/fm-test-run.sh" <<'EOF'
#!/bin/sh
[ -n "${FM_FAKE_TEST_LOG:-}" ] && printf '%s\n' "$*" >>"$FM_FAKE_TEST_LOG"
exit "${FM_FAKE_TEST_EXIT:-0}"
EOF
  cat >"$W/work/bin/fm-inbox.sh" <<'EOF'
#!/bin/sh
[ -n "${FM_FAKE_INBOX_LOG:-}" ] && printf '%s\n' "$*" >>"$FM_FAKE_INBOX_LOG"
exit 0
EOF
  chmod +x "$W/work/bin/fm-test-run.sh" "$W/work/bin/fm-inbox.sh"
  git -C "$W/work" add -A
  git -C "$W/work" commit -q -m 'base'
  git -c init.defaultBranch=main init -q --bare "$W/upstream.git"
  git -C "$W/work" push -q "$W/upstream.git" main
  git clone -q --bare "$W/upstream.git" "$W/origin.git"
  git clone -q "$W/origin.git" "$W/primary"
  git -C "$W/primary" remote add upstream "$W/upstream.git"
  # The script resolves its checkout from its own location, so the fixture
  # checkout holds its own copy at the same relative path.
  mkdir -p "$W/primary/ops/upstream-sync"
  cp "$SYNC" "$W/primary/ops/upstream-sync/sync.sh"
  chmod +x "$W/primary/ops/upstream-sync/sync.sh"
  rm -f "$W/tests.log" "$W/inbox.log"
}

upstream_commit() { # <path> <content> <message>
  printf '%s\n' "$2" >"$W/work/$1"
  git -C "$W/work" add -A
  git -C "$W/work" commit -q -m "$3"
  git -C "$W/work" push -q "$W/upstream.git" main
}

upstream_remove() { # <path> <message>
  git -C "$W/work" rm -q "$1"
  git -C "$W/work" commit -q -m "$2"
  git -C "$W/work" push -q "$W/upstream.git" main
}

fork_commit() { # <path> <content> <message>
  printf '%s\n' "$2" >"$W/primary/$1"
  git -C "$W/primary" add -A
  git -C "$W/primary" commit -q -m "$3"
  git -C "$W/primary" push -q origin main
}

# run_sync: runs the real script with its own temp state root and stubs in
# place. Prints everything the script writes.
run_sync() {
  (
    FM_HOME="$W/home" \
    TMPDIR="$W/tmp" \
    FM_FAKE_TEST_LOG="$W/tests.log" \
    FM_FAKE_INBOX_LOG="$W/inbox.log" \
    "$W/primary/ops/upstream-sync/sync.sh" 2>&1
  )
}

origin_head() { git -C "$W/origin.git" rev-parse main; }

check_worktree_cleanup() { # <desc>
  local leftovers
  leftovers="$(find "$W/tmp/fm-upstream-sync" -maxdepth 1 -name 'wt-*' 2>/dev/null | wc -l | tr -d ' ')"
  check "$1: no throwaway worktree left behind" 0 "${leftovers:-0}"
  check "$1: base checkout registers one worktree" 1 "$(git -C "$W/primary" worktree list | wc -l | tr -d ' ')"
}

### 1. already up to date
make_world uptodate
before="$(origin_head)"
out="$(run_sync)"
rc=$?
check "up to date: exit 0" 0 "$rc"
check_contains "up to date: reports no change" "already up to date" "$out"
check "up to date: origin unchanged" "$before" "$(origin_head)"
check_absent "up to date: no test run" "$W/tests.log"
check_absent "up to date: no note" "$W/inbox.log"
check_worktree_cleanup "up to date"

### 2. clean merge
make_world clean
before="$(origin_head)"
fork_commit docs/fork-only.md "fork-only change" "fork: own commit"
upstream_commit docs/other.md "upstream change" "upstream: touch other"
out="$(run_sync)"
rc=$?
after="$(origin_head)"
check "clean merge: exit 0" 0 "$rc"
if [ "$before" != "$after" ]; then pass "clean merge: origin advanced"; else fail "clean merge: origin did not advance"; fi
if git -C "$W/origin.git" merge-base --is-ancestor "$(git -C "$W/upstream.git" rev-parse main)" "$after"; then
  pass "clean merge: upstream is contained after the push"
else
  fail "clean merge: upstream is not contained after the push"
fi
check_absent "clean merge: no test run" "$W/tests.log"
check_contains "clean merge: upstream content landed" "upstream change" "$(git -C "$W/origin.git" show main:docs/other.md)"
check "clean merge: fork content kept" "fork-only change" "$(git -C "$W/origin.git" show main:docs/fork-only.md)"
check_absent "clean merge: no note" "$W/inbox.log"
check_worktree_cleanup "clean merge"

### 3. content conflict: abort, no push, one note
make_world conflict
upstream_commit docs/note.md "upstream side" "upstream: edit note"
fork_commit docs/note.md "fork side" "fork: edit note"
before="$(origin_head)"
out="$(run_sync)"
rc=$?
if [ "$rc" != 0 ]; then pass "conflict: non-zero exit"; else fail "conflict: exited 0"; fi
check "conflict: origin unchanged" "$before" "$(origin_head)"
check_contains "conflict: note names the merge" "did not finish cleanly" "$(cat "$W/inbox.log" 2>/dev/null)"
case "$(cat "$W/inbox.log" 2>/dev/null)" in
  *--request-id*) fail "conflict: request-id dedup remains" ;;
  *) pass "conflict: no request-id dedup" ;;
esac
out="$(run_sync)"
rc=$?
if [ "$rc" != 0 ]; then pass "conflict retry: non-zero exit"; else fail "conflict retry: exited 0"; fi
check "conflict retry: sends another note" 2 "$(wc -l <"$W/inbox.log" | tr -d ' ')"
check_absent "conflict: no test run" "$W/tests.log"
check_worktree_cleanup "conflict"

### 4. modify/delete conflict takes the same refusal path
make_world deleteconflict
fork_commit docs/delete-me.md "fork keeps it" "fork: keep delete-me"
upstream_remove docs/delete-me.md "upstream: drop delete-me"
before="$(origin_head)"
out="$(run_sync)"
rc=$?
if [ "$rc" != 0 ]; then pass "modify/delete: non-zero exit"; else fail "modify/delete: exited 0"; fi
check "modify/delete: origin unchanged" "$before" "$(origin_head)"
check_contains "modify/delete: note left for firstmate" "did not finish cleanly" "$(cat "$W/inbox.log" 2>/dev/null)"
check_absent "modify/delete: no test run" "$W/tests.log"
check_worktree_cleanup "modify/delete"

### 5. a push that would reach upstream refuses to run
make_world sameremote
git -C "$W/primary" remote set-url upstream "$W/origin.git"
before="$(origin_head)"
out="$(run_sync)"
rc=$?
if [ "$rc" != 0 ]; then pass "same remote: non-zero exit"; else fail "same remote: exited 0"; fi
check_contains "same remote: names the refusal" "would reach" "$out"
check "same remote: origin unchanged" "$before" "$(origin_head)"
check_absent "same remote: no test run" "$W/tests.log"

### 6. GitHub-equivalent push URLs are also refused
make_world equivalenturls
git -C "$W/primary" remote set-url upstream https://github.com/kunchenguid/firstmate.git
for url in \
  'https://github.com/kunchenguid//firstmate.git/' \
  'https://github.com/kunchenguid/./firstmate.git' \
  'https://www.github.com/kunchenguid/firstmate.git' \
  'git@github.com:kunchenguid/FirstMate.git'; do
  git -C "$W/primary" remote set-url --push origin "$url"
  out="$(run_sync)"
  rc=$?
  if [ "$rc" != 0 ]; then pass "equivalent URL refused: $url"; else fail "equivalent URL allowed: $url"; fi
  check_contains "equivalent URL refusal is explicit" "would reach upstream" "$out"
done

if [ "$failures" -eq 0 ]; then
  printf 'sync.test.sh: all cases passed\n'
  exit 0
fi
printf 'sync.test.sh: %s check(s) failed\n' "$failures"
exit 1
