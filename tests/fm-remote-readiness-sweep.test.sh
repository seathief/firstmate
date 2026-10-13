#!/usr/bin/env bash
# tests/fm-remote-readiness-sweep.test.sh - host-level readiness dedup during the
# session-start secondmate liveness sweep (FM_REMOTE_READINESS_SWEEP_CACHE).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-readiness-sweep)

make_shared_host_world() {
  local name=$1 w fakebin
  w="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/state" "$w/home/data" "$w/cache" "$w/home/state/parent-route"
  cat > "$w/home/state/rsm1.meta" <<'EOF'
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
home=/remote/rsm1-home
EOF
  cat > "$w/home/state/rsm2.meta" <<'EOF'
window=remote:rsm2
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w2:p2
home=/remote/rsm2-home
EOF
  cat > "$w/home/data/secondmates.md" <<'EOF'
- rsm1 - Mate one (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote; projects: alpha; added 2026-01-01)
- rsm2 - Mate two (host: lab-host; root: /remote/root; home: /remote/rsm2-home; scope: remote; projects: alpha; added 2026-01-01)
EOF
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SSH_LOG:?}"
joined="$*"
case "$joined" in
  *Zm0tcmVtb3RlLWRvY3Rvci*|*fm-remote-doctor.sh*)
    printf '%s\n' "${FM_FAKE_DOCTOR_REPLY:-ok: remote second-mate readiness confirmed on this host}"
    exit "${FM_FAKE_DOCTOR_RC:-0}"
    ;;
  *yb3V0ZQ*|*state-route*)
    printf '%s\n' alive '-- fm-remote-secondmate-route --' \
      'schema=fm-remote-secondmate-control.v1' 'backend=herdr' \
      'target=fm-remote:w1:p1' 'herdr_session=fm-remote' 'harness=claude' 'model=-' 'effort=-'
    exit 0
    ;;
  *c3RhdGU*)
    printf '%s\n' "${FM_FAKE_REMOTE_REPLY:-alive}"
    exit 0
    ;;
esac
printf '%s\n' "${FM_FAKE_REMOTE_REPLY:-alive}"
exit "${FM_FAKE_REMOTE_RC:-0}"
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$w"
}

count_doctor_calls() {
  local n
  # fm-on encodes argv; the doctor basename is stable in that base64 blob.
  n=$(grep -c 'Zm0tcmVtb3RlLWRvY3Rvci' "$1" 2>/dev/null) || n=0
  printf '%s' "$n"
}

probe_full() {
  local w=$1 id=$2
  shift 2
  mkdir -p "$w/cache"
  env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_REMOTE_READINESS_SWEEP_CACHE="$w/cache" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh-$id.log" \
    "$@" bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$1" "$2" full
      printf "%s|%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
    ' "$ROOT" "$w/home/state/$id.meta" "$id"
}

test_readiness_runs_once_per_host_for_two_mates() {
  local w out1 out2 n1 n2
  w=$(make_shared_host_world dedup-ok)
  : > "$w/ssh-rsm1.log"
  : > "$w/ssh-rsm2.log"

  out1=$(probe_full "$w" rsm1)
  n1=$(count_doctor_calls "$w/ssh-rsm1.log")
  out2=$(probe_full "$w" rsm2)
  n2=$(count_doctor_calls "$w/ssh-rsm2.log")

  [ "$n1" -eq 1 ] || fail "first mate should run doctor once, got $n1: $(cat "$w/ssh-rsm1.log")"
  [ "$n2" -eq 0 ] || fail "second mate should reuse cached readiness, got $n2: $(cat "$w/ssh-rsm2.log")"
  [ "$out1" = 'alive|' ] || fail "first mate should be alive, got: $out1"
  [ "$out2" = 'alive|' ] || fail "second mate should be alive, got: $out2"
  pass "sweep cache: readiness runs once for two mates on one host"
}

test_failed_host_readiness_blocks_all_mates() {
  local w out1 out2 n2
  w=$(make_shared_host_world dedup-fail)
  : > "$w/ssh-rsm1.log"

  out1=$(probe_full "$w" rsm1 FM_FAKE_DOCTOR_RC=1 FM_FAKE_DOCTOR_REPLY='check worker=fixable: start the worker')
  : > "$w/ssh-rsm2.log"
  n2=$(count_doctor_calls "$w/ssh-rsm2.log")
  out2=$(probe_full "$w" rsm2)

  [ "$out1" = 'skipped|remote readiness failed on lab-host: check worker=fixable: start the worker' ] \
    || fail "first mate should skip on readiness failure, got: $out1"
  [ "$n2" -eq 0 ] || fail "second mate must not rerun doctor after cached failure, got $n2"
  printf '%s' "$out2" | grep -q '^skipped|remote readiness failed on lab-host:' \
    || fail "second mate should inherit the cached readiness failure, got: $out2"
  pass "sweep cache: a failed host readiness blocks every mate on that host"
}

test_sweep_key_uses_sha256sum_when_shasum_absent() {
  local w key expected
  w="$TMP_ROOT/sweep-key-sha256"
  mkdir -p "$w/bin" "$w/home/data"
  ln -sf "$(command -v sha256sum)" "$w/bin/sha256sum"
  ln -sf "$(command -v awk)" "$w/bin/awk"
  ln -sf "$(command -v dirname)" "$w/bin/dirname"
  cat > "$w/home/data/secondmates.md" <<'EOF'
- rsm1 - Mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote; projects: alpha; added 2026-01-01)
EOF
  expected=$(printf '%s|%s\n' lab-host /remote/root | sha256sum | awk '{print $1}')
  key=$(env -i PATH="$w/bin" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    "$BASH" -c '. "$0/bin/fm-remote-readiness-lib.sh"; fm_remote_readiness_sweep_key rsm1' "$ROOT")
  [ "$key" = "$expected" ] \
    || fail "sweep key should hash host|root with sha256sum when shasum is absent, got: $key"
  pass "sweep cache: key falls back to sha256sum when shasum is absent"
}

test_sweep_key_fails_closed_without_digest_tool() {
  local w rc
  w="$TMP_ROOT/sweep-key-nohash"
  mkdir -p "$w/bin" "$w/home/data"
  ln -sf "$(command -v awk)" "$w/bin/awk"
  ln -sf "$(command -v dirname)" "$w/bin/dirname"
  cat > "$w/home/data/secondmates.md" <<'EOF'
- rsm1 - Mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote; projects: alpha; added 2026-01-01)
EOF
  rc=0
  env -i PATH="$w/bin" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    "$BASH" -c '. "$0/bin/fm-remote-readiness-lib.sh"; fm_remote_readiness_sweep_key rsm1' "$ROOT" >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "sweep key must fail closed when no digest tool is available"
  pass "sweep cache: key fails closed when no digest tool is available"
}

test_readiness_runs_once_per_host_for_two_mates
test_failed_host_readiness_blocks_all_mates
if command -v sha256sum >/dev/null 2>&1; then
  test_sweep_key_uses_sha256sum_when_shasum_absent
fi
test_sweep_key_fails_closed_without_digest_tool

echo "# all fm-remote-readiness-sweep tests passed"
