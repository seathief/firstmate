#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id>
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# When FM_REMOTE_READINESS_SWEEP_CACHE names a directory, the startup liveness
# sweep sets that variable so readiness runs at most once per distinct configured
# host+root for the whole sweep; every secondmate on that host reuses the cached
# verdict and output, including a failed readiness or a --fix repair path.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

FM_REMOTE_READINESS_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

fm_remote_readiness_require_locks() {
  command -v fm_lock_acquire_wait_bounded >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_REMOTE_READINESS_LIB_DIR/fm-wake-lib.sh"
}

fm_remote_readiness_sweep_key() { # <secondmate-id>
  local id=$1 reg data digest
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$FM_REMOTE_READINESS_LIB_DIR/fm-secondmate-registry-lib.sh"
  data="${FM_DATA_OVERRIDE:-${FM_HOME:?}/data}"
  reg="$data/secondmates.md"
  secondmate_registry_line_for_id "$reg" "$id" || return 1
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s|%s\n' "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_ROOT" | shasum -a 256 | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s|%s\n' "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_ROOT" | sha256sum | awk '{print $1}') || return 1
  else
    return 1
  fi
  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
}

fm_remote_readiness_ensure_uncached() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 out rc

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh --fix < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 cache key lockdir result rc out
  cache=${FM_REMOTE_READINESS_SWEEP_CACHE:-}
  if [ -z "$cache" ]; then
    fm_remote_readiness_ensure_uncached "$bin_dir" "$id"
    return $?
  fi

  key=$(fm_remote_readiness_sweep_key "$id") || return 1
  lockdir="$cache/$key.lock"
  result="$cache/$key.result"
  fm_remote_readiness_require_locks || return 1
  if ! fm_lock_acquire_wait_bounded "$lockdir" 600; then
    FM_REMOTE_READINESS_OUT='error: timed out waiting for sweep readiness cache lock'
    return 1
  fi
  if [ -f "$result" ]; then
    rc=1
    IFS= read -r rc <"$result" || rc=1
    FM_REMOTE_READINESS_OUT=$(sed -n '2,$p' "$result")
    fm_lock_release "$lockdir" || true
    return "$rc"
  fi
  rc=0
  fm_remote_readiness_ensure_uncached "$bin_dir" "$id" || rc=$?
  {
    printf '%s\n' "$rc"
    printf '%s\n' "$FM_REMOTE_READINESS_OUT"
  } >"$result"
  fm_lock_release "$lockdir" || true
  return "$rc"
}
