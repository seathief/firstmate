#!/usr/bin/env bash
# tests/fm-remote-secondmate-state-route.test.sh - combined state+route probe verb.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-state-route)

test_parse_state_route_output() {
  local combined
  combined=$(printf '%s\n' alive '-- fm-remote-secondmate-route --' \
    'schema=fm-remote-secondmate-control.v1' 'backend=herdr' 'target=fm-remote:w1:p1')
  bash -c '
    . "$0/bin/fm-secondmate-liveness-lib.sh"
    fm_sm_live_parse_state_route "$1"
    printf "%s|%s\n" "$FM_SM_LIVE_PARSED_STATE" "$FM_SM_LIVE_PARSED_ROUTE"
  ' "$ROOT" "$combined" >"$TMP_ROOT/parsed.txt"
  assert_contains "$(sed -n '1p' "$TMP_ROOT/parsed.txt")" 'alive' "parser should capture state"
  assert_contains "$(sed -n '2p' "$TMP_ROOT/parsed.txt")" 'backend=herdr' "parser should capture route body"
  pass "state-route parser: splits combined output like separate state and route"
}

test_full_probe_uses_one_remote_transport_for_alive() {
  local w fakebin out n
  w="$TMP_ROOT/probe-one-call"
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/state" "$w/home/data"
  cat > "$w/home/state/rsm1.meta" <<'EOF'
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
home=/remote/rsm1-home
EOF
  cat > "$w/home/data/secondmates.md" <<'EOF'
- rsm1 - Mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote; projects: alpha; added 2026-01-01)
EOF
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SSH_LOG:?}"
case "$*" in
  *Zm0tcmVtb3RlLWRvY3Rvci*) printf 'ok doctor\n'; exit 0 ;;
  *yb3V0ZQ*|*state-route*)
    printf '%s\n' alive '-- fm-remote-secondmate-route --' backend=herdr
    exit 0
    ;;
  *c3RhdGU*) printf 'alive\n'; exit 0 ;;
  *route*) printf 'backend=herdr\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/ssh"
  : > "$w/ssh.log"
  out=$(env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$1" rsm1 full
      printf "%s\n" "$FM_SM_LIVE_STATUS"
    ' "$ROOT" "$w/home/state/rsm1.meta")
  n=$(grep -c 'yb3V0ZQ' "$w/ssh.log" || true)
  [ "$out" = alive ] || fail "full probe should be alive, got: $out"
  [ "$n" -eq 1 ] || fail "full probe should use one control transport for alive mate, got $n: $(cat "$w/ssh.log")"
  pass "full probe: one remote control call replaces separate state and route"
}

test_parse_state_route_output
test_full_probe_uses_one_remote_transport_for_alive

echo "# all fm-remote-secondmate-state-route tests passed"
