# Issue: `sim maestro` and leases, from the first full ezbus iOS run

Filed 15 Oct 2026, from an ezbus session (`~/workspace/ezbus.wt/sub`, commit ae31b5b on its `agent/sub`). That
session ran ezbus's 17 Maestro flows on iOS with `sim maestro ios` until they passed 17/17 on agent-ios-1. It also ran
them twice on Android with `sim maestro android`. Each item below says what happened, then a suggestion. Most come
from the run itself. Items 4, 5 and 6 also rest on reading `bin/sim` and `lib/sim.sh`, and they say so. Nothing here
has been changed in this repo.

## iOS

### 1. A report written with `--output` stays on the Mac

`sim maestro ios test --format junit --output e2e/artifacts/native/ios/report.xml …` writes the report inside the
synced copy on the Mac (`~/sims/<tree>/…`). Only `~/.cache/agent-sim/maestro-N` is rsynced back, so the caller has to
`scp` the report home. ezbus's `e2e/run-native.sh` does this, and it has to know the Mac path and the ssh user to do
it.

Suggestion: after the run, copy back the target of any `--output` or `--test-output-dir` argument that lies inside the
worktree, to the same path on the host. Or say in the usage text that only the debug folder comes back.

### 2. Every run deletes the previous run's debug output

`sim-maestro` runs `rm -rf "$out"` before each run, and the host rsync runs with `--delete`. When an agent fixes
flows one run at a time, the screenshots and hierarchy dumps of the last failure are gone by the time they are
needed for comparison.

Suggestion: keep the last few runs in timestamped folders (`maestro-N/<run>/`), with a `latest` link.

### 3. Flows on the Mac cannot reach services on the host

On Android the flows reach the host through the docker bridge gateway. On iOS the app, Maestro and its `runScript`
HTTP calls all run on the Mac, so a test stack on the agent host (API, harness, stub) is out of reach. ezbus opens its
own tunnel:

```sh
ssh -N -o ExitOnForwardFailure=yes -R 8440:127.0.0.1:8440 -R 9441:127.0.0.1:9441 -R 9440:127.0.0.1:9440 <mac>
```

Two traps showed up along the way. The forward has to target `127.0.0.1`, because `localhost` tries `::1` first and
fails. And remote ports are shared by every slot on the Mac.

Suggestion: `sim maestro ios --forward <port>[,<port>…]`, or a separate `sim tunnel ios <ports>`. Either should hold
the forwards for the length of the run and fail clearly when the Mac already has the port bound.

### 4. `sim metro start ios` passes no environment

`cmd_metro` runs `npx expo start --port <port>` over ssh with no caller environment. In ezbus the dev manifest that
Metro serves reads `EZBUS_API_BASE`. Without it the debug app points at production, so ezbus starts Metro on the Mac
itself. (From reading `cmd_metro`; the workaround came first, so `sim metro start ios` was not tried.)

Suggestion: pass a prefix of variables through, as `sim maestro ios` already does for `MAESTRO_*` (for example
`EXPO_PUBLIC_*` plus a list in `.env`), or take `--env KEY=VALUE`. A wait for `/status`, like the Android path, would
also help.

## Leases and slots

### 5. Without an MCP server there is no way to hold a slot

A lease lives exactly as long as the `sim-mcp` process. When the Mac dropped off the tailnet, the session's sim-ios
server disconnected and the slot was freed. After the Mac came back, the server did not reconnect in that session, so
`sim maestro ios` refused with "no ios slot is leased". The only way to get a lease from the CLI was:

```sh
sleep 86400 | sim-mcp ios     # from the worktree, in the background
```

Suggestion: `sim lease <platform> [--hold]` and `sim release <platform>`, for CI-like and CLI-only runs. The lease
should keep the same flock semantics and show up in `sim status`.

### 6. A worktree does not get its old slot back

Before the disconnect the ezbus worktree held ios slot 2. Afterwards it got slot 1. The debug build bakes in the
Metro port (`RCT_METRO_PORT`), which is 8081 + 10(N−1), so the port changed from 8091 to 8081 and the app needed a
full rebuild.

Suggestion: when a worktree's previous slot (from the last `.active` owner) is free, lease that one first.

### 7. No per-slot ports for test stacks

Every repo's e2e scripts choose their own ports. Two ezbus worktrees chose overlapping ones. One session's smoke test
then hit the other worktree's live Android harness, and that changed its emulator's screen size and clock before
anyone noticed.

Suggestion: `sim ports <platform> [count]` hands out a block of ports per slot (as Metro's port already is), so test
stacks in different worktrees never collide.

## Health and status

### 8. A Mac outage looks like an MCP failure

When the Mac went offline, the MCP server reported only "Connection closed" in the middle of `build_sim`. `sim status`
showed `down`, which is the same word it uses for a simulator that `sim reap` shut down on purpose.

Suggestion: `sim status` checks whether the Mac answers (one short ssh probe) and says `mac unreachable`.
`sim maestro ios` and `sim metro start ios` should fail fast with the same message.

### 9. Android driver deaths, with nothing to diagnose them

Two full Android runs on emulator-5602 (ezbus slot 2) failed 13 and 15 of 17. Almost all of them failed with
`DeviceServerDiedException: Device server died during 'viewHierarchy'`. The mobilecli `DeviceServer` was not running.
Host memory was fine (14 GB available, load 1.5 on 16 cores), and logcat showed no crash or low-memory kill. The cause
is still unknown. The same flows passed 17/17 on emulator-5600 earlier that day.

Suggestion: a `sim doctor android [N]` that reports emulator uptime, adb round-trip time, any other UiAutomation client
and recent driver deaths. Also add a `sim android restart N`, or a `--fresh` option on `sim maestro android` that cold
boots the emulator first.

## What worked well

- `sim maestro ios` passes Maestro's exit code through (rc 1 on a failed flow), so callers can rely on it.
- Rewriting flow paths to the synced copy worked with no setup.
- `sim ios prepare` printing the `.xcworkspace` path made the sim-ios MCP `session_set_defaults` and `build_sim` easy to
  set up.
- Maestro 2.11.0 itself needed nothing else on the Mac. The first run installed its driver over ssh.
