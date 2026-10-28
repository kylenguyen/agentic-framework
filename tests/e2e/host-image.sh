# tests/e2e/host-image.sh: sourced by run.sh, tui.sh, linux.sh and harness-paste.sh, which share the af-e2e-host
# tag. One recipe for it, so a suite never rebuilds the tag without the simulator packages (SIM_APT, lib/sim.sh
# SIM_APT_PACKAGES) another suite's install-host.sh run expects to find installed without network.
# Needs REPO, LOGIN and PASSWORD set by the caller.

host_image() {
  local sim
  # shellcheck disable=SC2016  # $1 is for the inner bash
  sim=$(bash -c '. "$1/lib/sim.sh" && echo $SIM_APT_PACKAGES' _ "$REPO")
  docker build -q -f "$REPO/tests/e2e/Dockerfile.host" --build-arg "LOGIN=$LOGIN" --build-arg "PASSWORD=$PASSWORD" \
    --build-arg "SIM_APT=$sim" -t af-e2e-host "$REPO/tests/e2e" >/dev/null || { echo "host image build failed" >&2; exit 1; }
}
