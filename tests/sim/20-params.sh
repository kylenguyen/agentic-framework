# shellcheck shell=bash
# Sourced by tests/sim-test.sh after tests/sim/harness.sh; see its header.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031,SC2154
echo "# parameters"
( lib; check "params: android slots from .env" 2 "$AGENT_SIM_ANDROID_SLOTS"; check "params: iOS login from .env" bob "$AGENT_IOS_USER" )
( AGENT_SIM_WEB_SLOTS=12; lib 2>/dev/null && bad "params: rejects a two-digit slot count" || ok "params: rejects a two-digit slot count" )
( sed -i 's/^AGENT_SIM_WEB_SLOTS=2$//' "$REPO/.env"; lib; check "params: web slots default to 3" 3 "$AGENT_SIM_WEB_SLOTS"
  printf 'AGENT_SIM_WEB_SLOTS=2\n' >> "$REPO/.env" )
( . "$REPO/lib/params.sh"; AGENT_IOS_USER="a b"; params_validate 2>/dev/null && bad "params: rejects a bad iOS login" || ok "params: rejects a bad iOS login" )
( lib; check "params: idle minutes default to 30" 30 "$AGENT_SIM_IDLE_MINUTES" )
( AGENT_SIM_IDLE_MINUTES=soon; lib 2>/dev/null && bad "params: rejects idle minutes that are not a number" || ok "params: rejects idle minutes that are not a number" )
