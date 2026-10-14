# Maestro on iOS: `sim maestro ios` runs flows on the slot's simulator on the Mac

Plan, 14 Oct 2026. Extends the Maestro section of `docs/simulators-plan.md` (Android only so far). Not implemented yet.

## Context

`sim maestro` (main ad36359, 14 Oct 2026) runs Maestro flows on the agent's Android slot only, inside a docker
netns because Maestro hard-codes adb 5037/5038. Agents building ezbus also need the same flows on iOS. Maestro's iOS
driver is an XCTest runner that `xcodebuild`/`simctl` install on the simulator, so it can only run on the Mac. The
iOS path is therefore Maestro on the Mac over ssh, against `agent-ios-N`. It works the same way `sim-xcodebuildmcp N`
already runs XcodeBuildMCP there. It needs no docker or adb tricks.

User decision: the platform becomes a required word, `sim maestro android|ios <args>`, like `sim metro start <P>`.
This breaks the current `sim maestro test ...` form, so the ezbus AGENTS.md section has to be pasted again.

Base: `origin/main` ad36359. The `agent/sub` worktree was fast-forwarded to it on 14 Oct 2026.

## Phase 0: checks against Maestro 2.11.0 before coding (bytecode or `--help`, on the Mac)

Not started: on 14 Oct 2026 the Mac was offline on the tailnet. M2 and M4 can be answered from the release jars on
the host (`maestro-cli-2.11.0.jar`, `maestro-ios-driver.jar`). M1, M3 and M5 need the Mac.

| # | Question | If no |
|---|---|---|
| M1 | Does iOS need anything beyond Xcode and Java 17 (no idb_companion, no admin)? | add it to the runner, or stop and report |
| M2 | Can two simulators run Maestro at once? Check for a per-device driver port option (`--driver-host-port` or similar). Then run two flows at once on agent-ios-1 and agent-ios-2 | serialise iOS runs with a host-side flock `$SIM_STATE/ios/maestro.lock`; the second run waits and says so |
| M3 | Does `maestro --device <UDID>` select the simulator by UDID? | use the option it does take |
| M4 | Does `test --debug-output <dir>` exist (and `--test-output-dir`, if 2.x split them)? | fall back to a per-slot dir found from `~/.maestro/tests` |
| M5 | Does the first iOS run (driver install) work over a non-GUI ssh session, as S2 did for XcodeBuildMCP? | document a console login as a requirement |

Record the findings in docs/simulators-plan.md §3, the same way S1–S5 were recorded.

## Design

**Host: `bin/sim` `cmd_maestro`**
- `cmd_maestro <android|ios> <args...>` dispatches. With no platform word, or an unknown one, it prints usage and exits 2.
  Move today's body unchanged into `maestro_android`.
- `maestro_ios`:
  1. `n=$(my_slot ios)`, `sim_touch ios $n`.
  2. `cmd_ios sync` (quiet). Flows are edited on the host, so every run syncs first, which is cheap after the first.
  3. `sim_ios_boot $n`, then `rm -f $SIM_STATE/ios/$n.down`. This reuses the boot and settle code from the uptime work.
  4. One run per slot: a host-side `flock -n $SIM_STATE/ios/$n.maestro.lock`, which fails with "already going on
     ios slot N". If M2 fails, also take the Mac-wide `maestro.lock` (blocking, with a message).
  5. Keep-alive loop `sim_touch ios $n` every 60 s, as on Android, killed by an EXIT trap.
  6. Rewrite every argument that starts with `$root/` to `~/sims/<tree>/…`. Quote the arguments with `printf %q`.
     Pass the `MAESTRO_*` variables as an `env K=V` prefix.
  7. Run `sim_ios_ssh` (with `-tt` when stdin and stdout are a tty, so Ctrl-C reaches Maestro):
     `cd sims/<tree>/<app> && env MAESTRO_…= sim-maestro <N> <args>`. Keep Maestro's exit code.
  8. Afterwards, rsync `~/.cache/agent-sim/maestro-N/` on the Mac back to `$SIM_CACHE/ios/maestro-N/` on the host
     (`--delete`). Print "debug output: <host path>", so screenshots of a failed step can be read locally.
- `cmd_reap` needs no change: the keep-alive touches stop the iOS slot from being reaped during a long suite.

**Mac: `install-ios-runner.sh`**
- `mise use -g java@temurin-17` beside Node and Ruby (no admin needed).
- Maestro `$SIM_MAESTRO_VERSION`: curl the release zip and check it against `SIM_MAESTRO_SHA256`. Unzip it to
  `~/.local/share/maestro/<ver>` and link `~/.local/bin/maestro`. This is idempotent: skip it when the version matches.
- Write a launcher `~/.local/bin/sim-maestro` in the same style as `sim-xcodebuildmcp`. It checks the slot is 1–9,
  resolves the `agent-ios-N` UDID with the same `simctl list` sed, and exports `MAESTRO_CLI_NO_ANALYTICS=1` and
  `MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true`. It empties `~/.cache/agent-sim/maestro-N`. It then runs
  `exec maestro --device $udid [--driver-host-port $((7000+N))] "$@"`, adding `--debug-output` for `test` (M4).
- `bin/sim` `cmd_ios bootstrap` passes `SIM_MAESTRO_VERSION` and `SIM_MAESTRO_SHA256` through. Both are already in
  `lib/sim.sh` and shared with the Docker image, so a single bump moves both platforms.
- `sim ios gc` also prunes `~/.cache/agent-sim` on the Mac.

**Docs and text**
- The `bin/sim` header usage line and the `sim enable` AGENTS.md block: `sim maestro android|ios test <flows>`. On
  iOS the app must already be installed on the simulator through the sim-ios tools, and flow paths must lie inside
  the worktree.
- docs/simulators-plan.md: the Maestro paragraph gets an iOS part (what runs where, ports, sync, debug output),
  plus the contract row and the M1–M5 findings. README section 6: the verify block and rollback lines (Mac:
  `~/.local/share/maestro`, `~/.local/bin/sim-maestro`, `~/.cache/agent-sim`).
- `lib/sim.sh`: the comment on `SIM_MAESTRO_VERSION` notes that the Mac uses it too.

## Files

- `bin/sim`: `cmd_maestro` split into a dispatcher plus `maestro_android` and `maestro_ios`; `cmd_ios bootstrap`
  and `gc`; usage text and the AGENTS.md block.
- `install-ios-runner.sh`: Java, Maestro, the `sim-maestro` launcher.
- `tests/sim-test.sh`: the existing maestro cases move to `sim maestro android ...`. New cases:
  - no platform word, or an unknown one, exits 2
  - ios without a lease says how to get one
  - ios syncs (rsync shim log), then boots (ssh shim log has `bootstatus agent-ios-1`)
  - the ssh command has `cd sims/<tree>/client` and `sim-maestro 1 test flows/`
  - a `$root/...` argument is rewritten to the Mac path
  - `MAESTRO_APP_ID` is forwarded
  - Maestro's exit code is kept (the ssh shim returns 3)
  - the debug output is pulled back (an rsync back to `$SIM_CACHE/ios/maestro-1`)
  - a second run while the slot's lock is held fails
  - the run touches `ios/1.active` and clears `ios/1.down`
  - bootstrap passes `SIM_MAESTRO_*`

  The `bash -n` list already covers `install-ios-runner.sh`.
- `docs/simulators-plan.md`, `README.md`.
- `tests/params-test.sh`: run it for the literal scan; it should need no new parameters.

## Verification

1. `bash tests/sim-test.sh`: all pass, including the new iOS cases and the renamed Android ones.
   Also `bash tests/params-test.sh`.
2. On the Mac: `sim ios bootstrap` installs Java and Maestro and writes `sim-maestro`. Rerun it and check it is
   idempotent ("ok" lines).
3. Live, with ezbus: build and install it on agent-ios-1 through the sim-ios tools in a session, then run
   `sim maestro ios test .maestro/` from its client dir. Confirm it passes and that the debug output path exists on
   the host. Make a flow fail on purpose and check the screenshot is in the pulled-back directory.
4. M2 live: hold two iOS leases in two worktrees and run both at once. Both pass, or the second waits on the lock
   with a message.
5. Regression: `sim maestro android test .maestro/` still passes on an Android slot.
6. Reaper: during a run longer than 5 minutes, `sim status` keeps showing ios N "used 0–1m ago".
7. Re-paste the AGENTS.md section into ezbus. That is a separate task in that repo; flag it to the user, don't do it here.
