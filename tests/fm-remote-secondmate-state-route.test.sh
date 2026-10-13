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
  # shellcheck disable=SC2016  # The child bash expands "$0" and "$1".
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

test_full_probe_falls_back_for_old_remote_root() {
  local w fakebin out
  w="$TMP_ROOT/probe-old-remote"
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
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
argv_b64=$4
cmd=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$argv_b64" \
  | tr '\0' '\n' | sed -n '2p')
printf '%s\n' "$cmd" >> "${FM_FAKE_SSH_CMD_LOG:?}"
case "$cmd" in
  state-route)
    printf 'error: unknown command: state-route\n' >&2
    exit 1
    ;;
  state) printf 'alive\n'; exit 0 ;;
  route)
    [ "${FM_FAKE_ROUTE_RC:-0}" -eq 0 ] || exit "${FM_FAKE_ROUTE_RC}"
    printf 'backend=herdr\n'
    exit 0
    ;;
esac
printf 'ok: remote second-mate readiness confirmed on this host\n'
exit 0
SH
  chmod +x "$fakebin/ssh"
  : > "$w/cmd.log"
  # shellcheck disable=SC2016  # The child bash expands "$0" and "$1".
  out=$(env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_CMD_LOG="$w/cmd.log" \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$1" rsm1 full
      printf "%s|%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
    ' "$ROOT" "$w/home/state/rsm1.meta")
  [ "$out" = 'alive|' ] || fail "an old remote root must still probe alive, got: $out"
  grep -qx 'state-route' "$w/cmd.log" \
    || fail "the probe should try state-route first: $(cat "$w/cmd.log")"
  grep -qx 'state' "$w/cmd.log" \
    || fail "the fallback should use the separate state verb: $(cat "$w/cmd.log")"
  grep -qx 'route' "$w/cmd.log" \
    || fail "the fallback should use the separate route verb: $(cat "$w/cmd.log")"

  # shellcheck disable=SC2016  # The child bash expands "$0" and "$1".
  out=$(env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_CMD_LOG="$w/cmd.log" FM_FAKE_ROUTE_RC=1 \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$1" rsm1 full
      printf "%s|%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
    ' "$ROOT" "$w/home/state/rsm1.meta")
  [ "$out" = 'skipped|alive remote endpoint route is unreadable on lab-host; inspect and migrate or retire it explicitly' ] \
    || fail "a route failure in the fallback must keep the alive diagnostic, got: $out"
  pass "full probe: an old remote root falls back to separate state and route"
}

test_parse_state_route_output
test_full_probe_uses_one_remote_transport_for_alive
test_full_probe_falls_back_for_old_remote_root

echo "# all fm-remote-secondmate-state-route tests passed"
