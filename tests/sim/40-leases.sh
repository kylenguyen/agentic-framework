# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# leases"
( lib
  hold web "$T/ws/app" 3
  wait_for 'sim_held web 1' && ok "lease: first holder gets slot 1" || bad "lease: first holder gets slot 1"
  sim_lease web "$T/ws/app.wt/feat"; check "lease: second holder gets slot 2" 2 "$SIM_SLOT"
  check "lease: owner records the worktree" "$T/ws/app.wt/feat" "$(sim_owner_field web 2 root)"
  check "my slot: found by worktree" 1 "$(sim_my_slot web "$T/ws/app")"
  err=$( (sim_lease web "$T/ws/other") 2>&1 >/dev/null); rc=$?
  [ "$rc" != 0 ] && ok "lease: exhausted pool refuses" || bad "lease: exhausted pool refuses"
  has "lease: refusal names the holders" "$T/ws/app" "$err"
  wait
  wait_for '! sim_held web 1' && ok "lease: freed when the holder exits" || bad "lease: freed when the holder exits"
  sim_my_slot web "$T/ws/app" >/dev/null && bad "my slot: none after release" || ok "my slot: none after release"
)
