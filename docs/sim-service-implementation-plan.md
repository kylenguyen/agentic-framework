# Plan: make sim a general emulator service for agent hosts

This plan runs as 14 tasks, each done by a separate agent and landing as one commit. A final end-to-end check
covers them all. Source items: `docs/sim-maestro-feedback.md` #1-#9, plus the stability gaps found in the code.
Scope: Expo stays the only stack, with a seam where other stacks can plug in. One Mac (`AGENT_IOS_HOST`). Physical
devices and Mac pools are out of scope. No edits to ezbus.

---

## 0. Shared context for every task agent

### The current system (HEAD a078c50)

| File | Role |
|---|---|
| `lib/sim.sh` (303 lines) | Sourced library. Model comment (:4-27), pinned versions (:32-49), paths `SIM_PREFIX/SIM_STATE/SIM_CACHE` (:70-72), `sim_load_params` (:78), port maths (:99-105), `sim_root`, `sim_app_rel`, `sim_tree_name` (:108-129), `sim_lease` (:135-154, flock `-w 0.2` on `$SIM_STATE/<p>/<N>.lock`, writes `<N>.owner` with `pid=`, `root=`, `since=`), `sim_held`, `sim_owner_field`, `sim_holders`, `sim_my_slot` (:156-186), `sim_android_env` (:189), `sim_touch`, `sim_idle_secs` (:202-208), `sim_android_wait` (:213), `sim_ios_boot`, `sim_ios_shutdown` (:221-231), `SIM_SSH_OPTS` + `sim_ios_ssh` (:235-242), rsync rules (:247-255), harness config writers (:260-303). |
| `bin/sim` (383 lines) | CLI. `die` (:26), `my_slot` (:30), `cmd_status` (:34), `cmd_reap` (:55), `cmd_enable` with the AGENTS.md heredoc (:79-119), `wait`/`env`/`run` (:121-138), Metro pidfile helpers (:140-147), `cmd_build` (:152, `sleep 5`), `maestro_android` (:169-204), `maestro_ios` (:211-246), `cmd_metro` (:257-297), `slots_of` (:299), `cmd_android` (:305), `cmd_ios` (:329-367), dispatch (:369-383). |
| `bin/sim-mcp` (106 lines) | Takes the lease, picks the server (:26-50), has a bash `wake` (:55-78) and a bash line relay (:80-86) through a fifo, and forwards signals (:96-102). |
| `install-ios-runner.sh` (116 lines) | Mac side, bash 3.2, no sudo. Writes the launchers `~/.local/bin/sim-xcodebuildmcp` (:80-94, unquoted heredoc) and `~/.local/bin/sim-maestro` (:98-114, quoted heredoc, runs `rm -rf` on its output directory). |
| `config/sim/Dockerfile.maestro`, `config/sim/maestro-entry.sh` | Maestro container for Android. |
| `config/systemd/agent-sim-android@.service`, `agent-sim-reap.{service,timer}` | Emulator unit and the 5-minute reaper. |
| `lib/params.sh` | `.env` loader and validation for `AGENT_IOS_*` and `AGENT_SIM_*`. |
| `tests/sim-test.sh` (347 lines) | The unit suite: a repo copy in `$T` with shims for ssh, rsync, mise, systemctl, adb, emulator, npx, docker and node. Helpers `ok/bad/check/has/lacks`, `hold`, `wait_for`. |
| `tests/mcp-probe.mjs` | A stdio MCP client for live checks. |
| `tests/e2e/run.sh` | The pattern to copy for docker e2e: a private network, containers, the `ok/bad/check/has` helpers and `KEEP=1`. |

Ports per slot N:

| Platform | Ports |
|---|---|
| android | console 5598+2N, adb server 5037+N, Metro 8100+N |
| web | 8200+N |
| ios | Metro on the Mac 8081+10(N-1) |

State lives in `$SIM_STATE/<p>/`:

| File | Purpose |
|---|---|
| `N.lock`, `N.owner` | Lease and its holder |
| `N.active` | Last use, read by its mtime |
| `N.down` | iOS simulator shut down by sim |
| `N.metro`, `N.metro.log` | Metro pidfile and log |
| `N.in` | Relay fifo |
| `N.mobilecli/` | mobilecli daemon home |
| `N.maestro*` | Maestro lock and relay socket |

### Rules for every task

- **Code style.** Bash 5 with GNU tools on the host. bash 3.2 in anything that runs on the Mac. Messages start
  with `sim:`. Match the comment density and naming of the code around the change. shellcheck must stay clean.
- **Exit codes.** 0 = done, 1 = failed, 2 = usage. Task T3 adds 3 = device or Mac unavailable, retry later. Use 3
  wherever the cause is reachability or capacity.
- **House rules.** Never read or modify `~/.ssh` or `~/.config/agents`. No sudo. Do not edit ezbus or any other
  repo. Use your own worktree only.
- **Live services.** The live host runs real sim slots that other agents use. Task-level verification uses only the
  unit suite (shims) and the docker e2e (T2). The only live commands allowed are read-only ones, such as
  `sim status` and `sim version`. Live device checks happen in the final end-to-end check (section 3).
- **New unit tests** go in a new file `tests/sim/<NN>-<topic>.sh`, using the number assigned to the task below. Edit
  an existing section file only where an existing expectation has to change.

### Branches, commits, parallel work

- The integration branch is `agent/sim-service`, cut from `main`.
- Each task runs in a worktree `~/workspace/agentic-framework.wt/sim-<slug>` on branch `agent/sim-<slug>`, cut from
  the integration tip that has all of the task's dependencies.
- **One commit per task.** Imperative subject under 72 characters, a short "why" body, and a test-results line
  (`sim-test: N passed, 0 failed`, plus e2e if run). End it with the Co-Authored-By trailer.
- **Landing a task** (done by the orchestrator, or by the task agent if it is the only one landing):
  1. `git fetch`, then rebase the task branch onto the current tip of `agent/sim-service`. Never merge, never
     force-push shared branches.
  2. Resolve conflicts. Keep both sides' additions and re-read the merged function as a whole.
  3. Run `bash tests/sim-test.sh`. Also run `bash tests/e2e/sim-mac.sh` if the task or a conflicting task touched
     iOS, ssh or the relay. Run shellcheck too (section 3, A).
  4. Squash to one commit. Fast-forward `agent/sim-service`.
- **Where conflicts are likely:**
  - the dispatch `case` and the usage header in `bin/sim`
  - `cmd_status`, `cmd_ios`, `maestro_ios`
  - `sim_lease`, `SIM_SSH_OPTS`
  - the `sim-test` harness shims

  Dispatch and usage lines are additive, so keep all of them. When two tasks change one function, the second one
  to land re-runs the first one's test file as well.

### Dependencies and waves

```
W1: T1 test-split        T2 fake-mac e2e
W2: T3 mac-health   T4 remote-paths   T5 relay   T6 leases   T7 ports        (all need T1; T3 and T4 also need T2)
W3: T8 ios-reconnect (T2,T3,T5,T6)   T9 maestro-runs (T2,T4)   T10 tunnels (T2,T3,T7)   T11 metro (T3,T4)
W4: T12 doctor (T3,T9)   T13 repo-config (T7,T9,T10,T11)
W5: T14 json/version/check (T6,T12,T13)
Then: section 3, the final end-to-end check.
```

---

## 1. Tasks

### T1 Split the sim unit suite into section files (`agent/sim-test-split`)

**Outcome.** `tests/sim-test.sh` becomes a runner. The setup moves to `tests/sim/harness.sh`, and each `echo "# …"`
section moves to its own file. Behaviour does not change, and the set of passing cases is identical. Later tasks add
files without editing the same lines.

**Spec.**
- `tests/sim/harness.sh`: the current lines 8-74 (setup, shims, helpers, `lib`, `hold`, `wait_for`), unchanged.
- Section files, sourced in order into the same shell so `$T/results` is shared:

  | File | Section |
  |---|---|
  | `10-syntax.sh` | syntax |
  | `20-params.sh` | parameters |
  | `30-ports.sh` | ports and names |
  | `40-leases.sh` | leases |
  | `50-enable.sh` | sim enable |
  | `60-mcp.sh` | sim-mcp |
  | `70-commands.sh` | sim commands |
  | `80-maestro.sh` | sim maestro |
  | `90-reap.sh` | reap |

- The syntax check uses a glob (`tests/sim/*.sh`, `bin/sim*`, `lib/sim.sh`, `install-ios-runner.sh`,
  `config/sim/*.sh`), so new files are covered automatically.
- `bash tests/sim-test.sh [pattern]` runs only the files whose names match the pattern. The summary line and exit
  code stay the same.
- Numbers reserved for later tasks:

  | Task | File |
  |---|---|
  | T3 | `31-mac-health` |
  | T4 | `32-remote-paths` |
  | T5 | `61-relay` |
  | T6 | `41-lease-cli` |
  | T7 | `42-ports` |
  | T8 | `62-ios-reconnect` |
  | T9 | `81-maestro-runs` |
  | T10 | `43-tunnel` |
  | T11 | `71-metro` |
  | T12 | `91-doctor` |
  | T13 | `51-repo-config` |
  | T14 | `52-json-check` |

**Verify.**
1. Before the change: `bash tests/sim-test.sh | grep -E '^(ok|FAIL)' | sort > /tmp/before`. Note the summary line.
2. After the change, do the same into `/tmp/after`. `diff /tmp/before /tmp/after` is empty and the summary line is
   identical.
3. `bash tests/sim-test.sh maestro` runs only `80-maestro` (plus the harness) and passes.
4. `shellcheck -x tests/sim-test.sh tests/sim/*.sh` is clean.

**Commit:** `Split the sim unit suite into section files`

---

### T2 Fake-Mac docker e2e for the iOS path (`agent/sim-e2e-mac`)

**Outcome.** `tests/e2e/sim-mac.sh` exercises the real ssh, rsync and ssh-drop behaviour between a "host" container
and a "mac" container. No Mac and no KVM are needed. Later tasks add cases to it.

**Spec.**
- **Network.** Containers `af-sim-host` and `af-sim-mac` on network `af-sim`.
  - Host image: Debian, bash 5, util-linux (flock), rsync, openssh-client, jq, git, curl, nodejs, python3. The repo
    is mounted read-only and copied into a test worktree layout (`/w/app`, `/w/app.wt/feat/client`).
  - Mac image: Debian, openssh-server, rsync, bash, curl, python3, with a user `runner`.
- **Keys.** Generated in a temp dir. The host's `~/.ssh/config` inside the container points at `mac`. Nothing from
  the real `~/.ssh` is touched.
- **Mac shims** in `tests/e2e/shims/simmac/`, installed into `~runner/.local/bin`:
  - `xcrun`: `simctl list devices`, `bootstatus <name> -b`, `shutdown`, `list runtimes`. Booted state is kept in
    `~/simstate/<name>`.
  - `maestro`: logs its args to `~/maestro.log`, creates files under any `--debug-output`, `--test-output-dir` or
    `--output` path, and exits with `$(cat ~/maestro.rc || echo 0)`.
  - `sim-xcodebuildmcp`: a python3 stdio MCP stub. It answers `initialize`, `tools/list` (tools `screenshot` and
    `session_set_defaults`) and `tools/call` (echoes the name and arguments, plus a per-process call counter and
    its pid).
  - `npx`: for `expo start --port P`, starts `python3 -m http.server`-like code that serves `/status` →
    `packager-status:running` on P.
- **The real `sim-maestro` launcher** is pulled out of `install-ios-runner.sh` with
  `sed -n "/^cat > \"\$HOME\/.local\/bin\/sim-maestro\" <<'EOF'$/,/^EOF$/p"`, minus the first and last line. That
  way the real launcher is what gets tested.
- **Host `.env`.** `AGENT_IOS_HOST=mac`, `AGENT_IOS_USER=runner`, `AGENT_SIM_IOS_SLOTS=2`. `SIM_STATE` and
  `SIM_CACHE` point to temp directories in the container.
- **Ways to simulate a dropped link:**
  - `docker network disconnect af-sim af-sim-mac`, then reconnect.
  - `docker pause` / `docker unpause`.
- **Baseline cases** (current behaviour):
  - `sim ios sync` puts the tree at `~runner/sims/app-feat`, and `.env` does not arrive.
  - `node tests/mcp-probe.mjs --call screenshot '{}' -- sim-mcp ios` lists 2 tools and the call returns the echo.
  - While that probe runs, `sim status` shows ios 1 leased.
  - `sim maestro ios test flows/` with `maestro.rc=1` gives rc 1, and the debug files arrive under
    `$SIM_CACHE/ios/maestro-1/`.
  - `sim reap` with `AGENT_SIM_IDLE_MINUTES=1` and `.active` aged 2 minutes calls `xcrun simctl shutdown`, and
    `~/simstate/agent-ios-1` goes to Shutdown.
  - Dropping the link during `sim-mcp ios` ends the server, and the lease is freed. This records today's behaviour;
    T8 flips the expectation.
- Same output format as `tests/e2e/run.sh` (`N passed, M failed`, `KEEP=1`). Target runtime under 3 minutes after
  the first image build.

**Verify.**
1. `bash tests/e2e/sim-mac.sh` → `N passed, 0 failed`. Run it twice: the second run must pass too.
2. `KEEP=1 bash tests/e2e/sim-mac.sh`, then `docker exec af-sim-mac ls ~runner/sims` shows `app-feat`. Clean up
   with `docker rm -f`.
3. `shellcheck -x tests/e2e/sim-mac.sh` is clean. `bash tests/sim-test.sh` still passes.

**Commit:** `Add a fake-Mac docker e2e for the iOS sim path`

---

### T3 Health checks for the Mac link, and exit code 3 (`agent/sim-mac-health`)

Feedback #8, plus weak points: ssh options and the state directory.

**Outcome.** One cached probe decides whether the Mac answers. Status tells "reaped" apart from "unreachable".
Commands that need the Mac fail within about 5 s with exit 3. Short ssh commands share one connection.

**Spec.**
- **`lib/sim.sh`:**
  - `SIM_SSH_OPTS` adds `ServerAliveCountMax=2`, `ControlMaster=auto`, `ControlPath=$SIM_STATE/ios/ssh-%C` and
    `ControlPersist=60`. `sim_ios_ssh` runs `mkdir -p "$SIM_STATE/ios"` first.
  - New `SIM_SSH_SOLO_OPTS=(-o ControlMaster=no -o ControlPath=none)`, for long sessions (the MCP server, tunnels),
    so a dropped multiplex master never takes them down.
  - `sim_mac_probe [--fresh]`:
    - returns 0 for up, 1 for down, and 2 when not configured (`AGENT_IOS_HOST` or `AGENT_IOS_USER` unset);
    - caches `up|down <epoch>` in `$SIM_STATE/ios/mac.state` for `SIM_MAC_PROBE_TTL` seconds (default 30);
    - runs `ssh -o ConnectTimeout=${SIM_MAC_PROBE_TIMEOUT:-5} … true`;
    - on a down result, runs `ssh -O exit` on the control path, so a stale master is dropped.
  - `sim_mac_require`: when the probe is down, runs `die`-style `sim: mac unreachable: <user>@<host> did not answer
    within 5 s (sim status)` and exits 3. When not configured, the existing `.env` message and exit 1.
  - `SIM_STATE` default: `$XDG_RUNTIME_DIR/agent-sim`. If `XDG_RUNTIME_DIR` is unset, use `/run/user/$(id -u)` when
    it is a writable directory, else `/tmp/agent-sim-$(id -u)`.
- **`bin/sim`:**
  - Exit-3 helper `unavailable()`.
  - `sim_mac_require` at the start of `maestro_ios`, `cmd_metro` for ios, and `cmd_ios`
    sync/prepare/start/stop/gc/bootstrap.
  - `cmd_status` iOS column:
    - one `xcrun simctl list devices` over ssh for all slots, when the probe is up;
    - states `booted`, `off` (shut down, either reaped or by hand), or `unreachable`;
    - `unconfigured` when the host is not set;
    - the old `down` word goes away.
  - `cmd_reap`: probe once before the ios loop. When it is down, print one line
    `ios: <host> unreachable, next round tries again` and skip every ios slot.
- **`bin/sim-mcp`:** the ios startup check uses `sim_mac_probe --fresh`. The server ssh uses `SIM_SSH_SOLO_OPTS`.
  The message on exit 1 says `mac unreachable`.
- **Harness shim:** the ssh shim in `tests/sim/harness.sh` exits 255 for every call while `$T/ssh.down` exists.

**Unit tests (`31-mac-health.sh`).**
- Probe: up gives 0; with `ssh.down` it gives 1; a second probe within the TTL makes no ssh call (the ssh log does
  not grow); `--fresh` makes one.
- Not configured gives 2.
- `sim status` shows `unreachable` for ios while the Mac is down, and `off` after `sim ios stop 1`.
- `sim maestro ios test x` while down: rc 3, the message contains `mac unreachable`, and there is no rsync log.
- `sim metro start ios` while down: rc 3.
- `sim reap` while down, with an aged ios `.active`: exactly one ssh call, the stderr line appears once, and no
  `.down` is created.
- The ssh log contains `ServerAliveCountMax=2` and `ControlPath=`. The `sim-mcp ios` server line contains
  `ControlPath=none`.
- With `SIM_STATE` and `XDG_RUNTIME_DIR` unset, `lib` gives `SIM_STATE=/run/user/$(id -u)/agent-sim` (skip if
  that directory is missing).
- Update `90-reap.sh`'s `status: iOS down` expectation to `off`.

**E2e (`sim-mac.sh`).**
- `docker pause af-sim-mac`: `sim status` prints `unreachable` within 8 s, and `sim maestro ios test flows/`
  exits 3 within 10 s.
- `docker unpause`, then `sim status` shows `booted` or `off`.

**Verify.** `bash tests/sim-test.sh` gives 0 failed. `bash tests/e2e/sim-mac.sh` gives 0 failed. Read-only live
check: `sim status` on as1 shows ios `booted`, `off` or `unreachable`, never `down`.

**Commit:** `Probe the Mac once and fail fast with exit 3 when it is gone`

---

### T4 Remote paths: collision-free tree names, quoting, gc by sync stamp (`agent/sim-remote-paths`)

**Outcome.** Two repos can no longer share a directory on the Mac. Paths with spaces work. `sim ios gc` never
removes a tree that was synced recently.

**Spec.**
- **`sim_tree_name <root>`** returns `<base>-<h6>`:
  - `<base>` is today's name (`<repo>` or `<repo>-<slug>`), with characters outside `[A-Za-z0-9._-]` replaced
    by `_`.
  - `<h6>` is the first 6 hex characters of `sha256(root)`.
- **`sim_mac_dir <root> [app]`** returns the remote relative path `sims/<tree>[/<app>]`, already quoted with
  `printf %q` for use in a remote command. Every remote string uses it:
  - the `cd …` in `maestro_ios`
  - `cmd_metro` start and log
  - `cmd_ios` sync, prepare and the `ls -d` for the workspace
- **sync:**
  - `mkdir -p <dir> && touch <dir>/.agent-sim-synced` before the rsync.
  - `sim_rsync_args` adds `--filter=P .agent-sim-synced`.
  - The rsync destination is quoted (`rsync -s`/`--protect-args`, so spaces survive).
- **gc:**
  - For `sims/*`, a tree is removed when its `.agent-sim-synced` is older than N days, or when it has no stamp and
    the directory's mtime is older than N days. The no-stamp case cleans up trees with old-style names.
  - The other directories keep the mtime rule.
- The `printf %q` quoting in the remote commands has to survive the remote login shell, which is zsh. Use a test
  path containing a space and a `'` to prove it.

**Unit tests (`32-remote-paths.sh`, plus edits to the existing expectations in `30-ports.sh` (tree name) and
`70-commands.sh`/`80-maestro.sh` (`sims/app-feat` becomes `sims/app-feat-<h6>`), with the hash computed in the
test).**
- Names: a checkout and a worktree get different hashes. Two roots with the same basename differ.
- `foo.wt/bar` and a repo called `foo-bar` differ.
- A space in the root gives a quoted `cd` in the ssh log.
- sync touches the stamp, and the rsync args contain `P .agent-sim-synced`.
- The gc command string contains `.agent-sim-synced`.

**E2e.**
- A worktree at `/w/my app.wt/feat` syncs, and `sim maestro ios test flows/` runs in the right directory.
- `sim ios gc 0` after a sync keeps the fresh tree. After `touch -d '10 days ago'` on its stamp, gc 7 removes it.

**Verify.** Unit and e2e pass. `grep -n 'cd \$dir' bin/sim` finds no unquoted remote `cd` left.

**Commit:** `Give each worktree its own quoted directory on the Mac`

---

### T5 Rewrite the MCP relay in Node: wake errors, non-blocking wake, boot checks (`agent/sim-relay`)

Weak points: wake failures swallowed, relay blocking, `tools/call` found by substring match, stale `booted` flag,
orphaned servers.

**Outcome.**
- `bin/sim-mcp` still takes the lease, then runs `node bin/sim-mcp-relay.mjs`, which owns the server process and is
  the only writer of stdout.
- A tool call whose device fails to wake gets an MCP tool error the agent can read. The call never reaches the
  server.
- Pings and notifications keep flowing while a wake is in progress.

**Spec.**
- **`bin/sim-mcp-relay.mjs`** (Node 20 or later, no dependencies). Usage:
  `sim-mcp-relay.mjs --platform P --slot N --wake "<cmd>" --pgid-file F -- <server…>`.
  - **Server process.** Spawns the server `detached: true`, so it gets its own process group, and writes the pgid
    to `F` (`$SIM_STATE/<p>/<N>.pgid`). T6 reads this file. On exit it kills `-pgid` (TERM, then KILL after 5 s)
    and removes `F`.
  - **Parsing.** Reads stdin line by line and parses JSON. A line that is not JSON is passed through unchanged.
  - **Tool calls.** For a request with `method == "tools/call"`, the line goes into an ordered queue. Wake runs
    once per queue drain: the `--wake` command is spawned with stdio `ignore`/`ignore`/`pipe`.
    - Exit 0: forward the queued calls in order.
    - Non-zero: answer each queued call with
      `{"jsonrpc":"2.0","id":<id>,"result":{"content":[{"type":"text","text":"sim: <last stderr line>"}],"isError":true}}`
      and do not forward them.
  - **Everything else** (initialize, tools/list, ping, notifications, responses) is forwarded immediately, even
    while a wake is running.
  - **stdout.** Server stdout is split into lines and written as whole lines. Injected responses are also whole
    lines. This process is the only writer.
  - **End of session.** On stdin EOF, end the server's stdin, wait up to 5 s, then kill the group. SIGTERM, SIGINT
    and SIGHUP do the same. The exit code is the server's.
- **`bin/sim` hidden subcommand `_wake <platform> <N>`.** Not in the usage text. Exit 0 = ready, 3 = unavailable
  (with a one-line reason on stderr), 1 = other failure. It holds the logic of today's `wake`:
  - **android:**
    - `sim_touch`;
    - if the unit is inactive, stop the mobilecli daemon and start the unit;
    - always check `adb shell getprop sys.boot_completed`, and if it is not `1`, run `sim_android_wait`.
    - This replaces the per-process `booted` flag.
  - **ios:**
    - `sim_touch`;
    - `sim_mac_probe`, if T3 has landed; otherwise a plain ssh true;
    - if `$N.down` exists or `$N.booted` is missing, run `sim_ios_boot`, create `$N.booted` and remove `.down`;
    - `sim reap` and `sim ios stop` remove `$N.booted`.
  - **web:** touch only.
- **`bin/sim-mcp`:**
  - Drop the bash `wake`, the relay and the fifo.
  - `exec {SIM_LOCK_FD}>&-`-style: run `"${SIM_RELAY_NODE:-node}" "$REPO/bin/sim-mcp-relay.mjs" … -- "${server[@]}"`
    with the lock fd closed, and wait on it with the existing signal forwarding.
  - Keep `after=` (`mobilecli daemon stop`) after the relay exits.
- **Tests.** The `node` shim in `$T/shims` shadows the real node, so the harness exports
  `SIM_RELAY_NODE=$(command -v node)` captured before `PATH` is changed. T5 edits `harness.sh` for this, plus the
  adb shim, which prints `$(cat $T/boot 2>/dev/null || echo 1)` for `getprop sys.boot_completed`.

**Unit tests (`61-relay.sh`, plus existing `60-mcp.sh` expectations that must still pass unchanged: "messages
reach the server unchanged", "first tool call starts the emulator, once", "telemetry off", "daemon stopped").**
- **Wake fails** (systemctl start shim fails via `$T/systemctl.fail`): the response on stdout has `isError: true`
  and the text contains `did not boot` or `could not start`, and `node.in` lacks the call.
- **Ping during a slow wake** (a `$T/wake.delay` seam in the systemctl shim): the ping reaches `node.in` before the
  call.
- **Restarted unit, not yet booted** (unit active, `$T/boot`=0, then 1 after 1 s): the call waits and is then
  forwarded.
- **`"tools/call"` inside a string argument of another method** does not trigger a wake.
- **Large message:** a 1 MB message reaches the server byte for byte.
- **Process group:** the `.pgid` file exists while running and is gone after exit. A grandchild started by the fake
  server (`sleep 300 &`) is dead after the session ends.

**E2e.** The `sim-mcp ios` probe case still passes. Add one: with `~/simstate/agent-ios-1` on Shutdown and the
`bootstatus` shim failing, the call returns `isError` and its text says `could not boot`.

**Verify.** `bash tests/sim-test.sh` → 0 failed. `bash tests/e2e/sim-mac.sh` → 0 failed. shellcheck is clean.
`node --check bin/sim-mcp-relay.mjs` passes.

**Commit:** `Relay MCP traffic in Node and report device wake failures`

---

### T6 CLI leases, sticky slots, takeover cleanup, own-session preference (`agent/sim-leases`)

Feedback #5 and #6, plus the orphan and two-sessions weak points.

**Outcome.**
- `sim lease <p>` and `sim release <p>` work without an MCP server.
- A worktree gets back the slot it had last.
- A new lease kills any server left over from the slot's previous owner.
- `my_slot` prefers the lease held by the caller's own harness session.

**Spec.**
- **`sim_lease <platform> [root] [kind]`** (kind `mcp` by default, or `cli`):
  - **Sticky slot.** Read `$SIM_STATE/<p>/last/<sha256(root)[:12]>` → N, and try N first (flock `-w 0.2`). Then
    try the others in order. Write the `last` file on every successful lease.
  - **Owner file.** Written atomically (temp file + `mv`) with fields `pid`, `ppid` (the holder's parent: for
    sim-mcp that is the harness), `root`, `since`, `kind`, and for cli leases `until=<epoch>`.
  - **Takeover cleanup.** After taking the flock, if `$N.pgid` exists and `kill -0 -<pgid>` succeeds, send TERM to
    the group, wait up to 3 s, then KILL. Print `sim: stopped a server left by the slot's previous holder (pgid X)`
    to stderr and remove the file. T5 writes the `.pgid` file. The unit test fakes it with `setsid sleep 300`, so
    T6 does not depend on T5.
- **`sim_my_slot`:**
  - When more than one held slot of the platform matches the root, prefer the one whose owner `ppid` is an
    ancestor of `$$` (walk `/proc/<pid>/stat`). Otherwise the lowest one.
  - Fix the header comment: "returns 1 when there is none".
- **`sim lease <p> [--ttl DUR] [dir]`:**
  - DUR is `<n>m|h|d`, default `8h`, maximum `7d`. A bad value is exit 2.
  - If this root already holds a slot of `<p>`, print it and exit 0.
  - Otherwise start a detached holder: `setsid "$REPO/bin/sim" _hold <p> <root> <until>`. `_hold` runs
    `sim_lease … cli` and then `exec sleep <secs>` with the fd still open. Its stdio go to `/dev/null`.
  - Wait up to 3 s for `sim_my_slot` to see the lease, then print
    `<p> slot N leased for <root> until HH:MM (sim release <p>)`.
  - When every slot is taken: exit 3, listing the holders.
- **`sim release <p> [dir]`:**
  - A cli lease of this root: kill its holder pid and wait until the slot is free.
  - An mcp lease: exit 1 with `held by the sim-<p> MCP server (pid X); end that harness session to free it`.
  - No lease: exit 0 with `nothing to release`.
- **`sim reap`** kills cli holders whose `until` has passed, printing `<p> N: CLI lease expired`.
- **`cmd_status`** state column: `leased mcp pid X <root>` or `leased cli until HH:MM <root>`.
- **`my_slot` message:** add `, or sim lease <p>` to the existing hint.

**Unit tests (`41-lease-cli.sh`).**
- Lease and release:
  - `sim lease web` → rc 0, `sim status` shows `cli`, and `sim env`-style commands find the slot.
  - A second `sim lease web` from the same root keeps the same slot and leaves one holder.
  - `sim release web` → the slot is free.
- TTL and capacity:
  - `--ttl 0m`/`9d`/`x` → rc 2.
  - When every slot is full → rc 3.
- Sticky slot: root A on slot 2 (B on 1), then release both; leasing B then A gives A slot 2.
- Takeover: a stale `.pgid` running `setsid sleep 300` is killed when the slot is next leased, and the message is
  printed.
- Own session: two holders of the same root with different ppids. A child of the second holder's parent gets the
  second slot from `sim_my_slot`.
- Expiry: a cli lease with `until` in the past is reaped by `sim reap`.
- `sim release` on an mcp lease → rc 1 and the message.
- The owner file has no partial content: read it 100 times while leasing in a loop.

**Verify.** `bash tests/sim-test.sh` → 0 failed. Read-only live: `sim status` still renders on as1.

**Commit:** `Add CLI leases and give a worktree its last slot back`

---

### T7 Port blocks per slot (`agent/sim-ports`)

Feedback #7.

**Outcome.** Every leased slot owns 100 ports that no other slot or sim service uses. Test stacks bind inside it.

**Spec.**
- **`sim_port_base <p> <N>`** = `20000 + 1000*idx + 100*(N-1)`, where idx is android=0, web=1, ios=2.
  `SIM_PORT_BLOCK=100`. This stays clear of 5037-5046, 5600-5682, 8081-8161, 8101-8109 and 8201-8209, and well
  below the ephemeral range 32768 and up.
- **`sim ports <p>`** (needs a lease, via `my_slot`) prints `export SIM_PORT_BASE=…` and
  `export SIM_PORT_COUNT=100`.
  - `sim ports <p> <k>` prints the first k ports separated by spaces. k from 1 to 100; otherwise rc 2.
  - `sim ports <p> --check` lists the block's ports that are already listening (`ss -Hltn`), each with the
    process from `ss -p` where it is visible. rc 1 if any are bound.
- **`sim_android_env`** (used by `sim env` and `sim run`) also exports `SIM_PORT_BASE` and `SIM_PORT_COUNT` for
  android.

**Unit tests (`42-ports.sh`).**
- Bases: android 1 = 20000, android 3 = 20200, web 2 = 21100, ios 2 = 22100.
- No overlap between any two blocks for slots 1-9, checked with a loop.
- `sim ports web` without a lease → rc 1 with the hint.
- With a lease: eval gives `SIM_PORT_BASE=21000`. `sim ports web 3` prints `21000 21001 21002`. `101` gives rc 2.
- `--check` with a `python3 -m http.server 21000` running reports 21000 and rc 1.
- `sim run` sees `SIM_PORT_BASE`.

**Verify.** `bash tests/sim-test.sh` → 0 failed.

**Commit:** `Hand each slot a block of 100 ports for test stacks`

---

### T8 Keep the iOS MCP session alive across Mac drops (`agent/sim-ios-reconnect`)

Feedback #5 at its root. Depends on T2, T3, T5 and T6.

**Outcome.** When ssh to the Mac drops, `sim-mcp ios` keeps its lease and answers tool calls with a clear error.
It reconnects with backoff and restores the session, so the harness never sees the server disconnect.

**Spec** (in `bin/sim-mcp-relay.mjs`, enabled by `--reconnect`, which sim-mcp passes for ios only).
- **Remember session state.**
  - The client's `initialize` request (the full message) and its `notifications/initialized`.
  - The last `tools/list` result.
  - The last successful `tools/call` whose `params.name` is in `SIM_REPLAY_TOOLS`. Comma list, default
    `session_set_defaults`.
- **When the server exits non-zero and stdin is still open,** enter the reconnecting state:
  - Retry with backoff 5 s, 10 s, 30 s, then every 60 s, with no limit while the harness lives.
  - Each attempt spawns the server again. It is up once it answers the replayed `initialize`, sent with an internal
    id such as `"sim-replay-1"`.
  - Then send `notifications/initialized`, replay the stored tools with internal ids, and drop their responses.
  - Remove `$SIM_STATE/ios/N.booted`, so the next wake checks the simulator again.
  - Log `sim-mcp: reconnected to <host> after Xs` to stderr.
- **While reconnecting:**
  - `tools/call` gets an `isError` result: `sim: mac unreachable (<host>), reconnecting, attempt k; try again in
    about a minute (sim status)`.
  - `tools/list` gets the cached result. `ping` gets `{}`.
  - Other requests get JSON-RPC error -32000 with the same text.
- Responses to the internal ids are never forwarded to the harness.
- The lease is never dropped: sim-mcp is still alive, and the relay only exits on stdin EOF or a signal.

**Unit tests (`62-ios-reconnect.sh`).**
- Shims: an ssh shim mode where the `sim-xcodebuildmcp` server is a small node fake that exits 255 after `$T/die.after`
  messages. A later spawn works.
- Cases:
  - A call during the outage gets `isError` containing `reconnecting`.
  - After reconnect, the fake receives `initialize` then `session_set_defaults` before the next real call.
  - The harness never sees responses with `sim-replay` ids.
  - `sim_held ios 1` stays true the whole time.
  - `tools/list` during the outage returns the cached tools.

**E2e.**
1. Start `mcp-probe` with a long-running script: a small node driver in `tests/e2e/` that keeps the session open
   and issues calls on demand. Make one call.
2. `docker network disconnect` the Mac. A call returns `isError` "reconnecting", and `sim status` still shows ios 1
   leased by the same pid.
3. Reconnect the network. Within 70 s a call succeeds, its echo shows the stub's call counter has `initialize` and
   `session_set_defaults` replayed, and the stub's pid has changed.
4. This replaces T2's "drop frees the lease" expectation.

**Verify.** Unit and e2e → 0 failed.

**Commit:** `Reconnect sim-ios to the Mac without losing the lease`

---

### T9 Maestro run directories, output copy-back, logcat capture (`agent/sim-maestro-runs`)

Feedback #1, #2 and part of #9. Depends on T2 and T4.

**Outcome.**
- Each `sim maestro` run keeps its own directory on the host, with a `latest` link, and only the last K are kept.
- Files a caller asks for with `--output` or `--test-output-dir` arrive at those exact host paths.
- Android runs save logcat.

**Spec.**
- **Run directory layout:**
  - run id `YYYYmmdd-HHMMSS`
  - host path `$SIM_CACHE/<p>/maestro-N/runs/<id>/`, containing `debug/`, `output/`, `artifacts/`, `cmd.txt`
    (args and rc), and on android `logcat.txt`
  - `$SIM_CACHE/<p>/maestro-N/latest` is a symlink to `runs/<id>`
  - prune to `AGENT_SIM_KEEP_RUNS`: new param in `lib/params.sh` and `.env.example`, range 1-50, default 5
- **Output arguments.** Parse `--output`, `--test-output-dir` and `--debug-output`, each as `--x P` or `--x=P`.
  - A path outside the worktree is rc 2: `output paths must lie inside the worktree`.
  - If the caller passed none, inject `--debug-output <run>/debug --test-output-dir <run>/output` for `test`. On
    Android this is done by sim. On iOS it moves out of the launcher.
- **Android:**
  - The run directory is under the mounted `$home`, so Maestro writes into it directly.
  - Worktree paths are written in place, because the worktree is mounted.
  - `adb logcat -c`, then a background `adb logcat -v threadtime > <run>/logcat.txt`, killed in the existing EXIT
    trap.
- **iOS:**
  - The launcher contract becomes `sim-maestro <N> <run-id> <args…>`, and `sim-maestro --version` prints `2`. The
    new launcher in `install-ios-runner.sh`:
    - writes to `~/.cache/agent-sim/maestro-N/runs/<run-id>` and never runs `rm -rf` on the parent;
    - keeps the last 3 runs on the Mac;
    - no longer injects any flags itself.
  - The host:
    - checks `sim-maestro --version` once per run and requires `2`, otherwise rc 1 with
      `the Mac's sim-maestro is out of date: sim ios bootstrap`;
    - rewrites each output path P in the worktree to `<mac-run>/artifacts/<path of P relative to the root>`;
    - after the run, rsyncs `runs/<id>/` only, with no `--delete` across runs, and shows rsync's stderr when it
      fails;
    - copies `artifacts/<rel>` to `<root>/<rel>`, making parent directories as needed.
- **Final stderr lines:** `maestro run <id>: <run dir>` and `latest: <…>/latest`. The rc is still Maestro's.

**Unit tests (`81-maestro-runs.sh`, plus `80-maestro.sh` expectations updated for the new launcher args and rsync
path).**
- Run directories and pruning:
  - Two runs make two directories, and `latest` points at the second.
  - With `AGENT_SIM_KEEP_RUNS=2`, a third run prunes the first.
- Output paths:
  - iOS `--output e2e/report.xml`: the ssh line has `.../runs/<id>/artifacts/client/e2e/report.xml` (or the right
    relative path). After a fake rsync drops the file into the run directory, it appears at `<root>/…/report.xml`.
  - An output path outside the worktree → rc 2.
- Android: `-v` mounts unchanged; the args contain `--debug-output <home>/runs/<id>/debug`; the adb log has
  `logcat -c` and `logcat -v threadtime`.
- Launcher: the launcher heredoc contains no `rm -rf "$out"`. A launcher on version 1 gives rc 1 with the bootstrap
  hint.
- `AGENT_SIM_KEEP_RUNS=0` and `99` are rejected by params.

**E2e.**
- Two `sim maestro ios test flows/ --output e2e/report.xml` runs, the first with rc 1. Both run directories exist
  on the host, `latest` points at the second, and `e2e/report.xml` exists in the host worktree. The Mac keeps at
  most 3 runs.

**Verify.** Unit and e2e → 0 failed. `bash tests/params-test.sh` → 0 failed (new param).

**Commit:** `Keep each Maestro run and bring requested reports home`

---

### T10 Tunnels from the Mac to host services (`agent/sim-tunnels`)

Feedback #3. Depends on T2, T3 and T7.

**Outcome.**
- `sim tunnel ios <ports>` makes host services reachable from the Mac at `127.0.0.1:<port>`.
- `sim maestro ios --forward …` holds forwards for the length of a run.
- A port that is already bound is reported clearly.

**Spec.**
- **`sim tunnel ios <p[,p…]> [--background|--stop|--any-port]`.** Needs an ios lease.
  - **Ports.** Each port must lie in the slot's block (T7) unless `--any-port` is given, which prints a warning
    that other slots may collide.
  - **Pre-check.** One ssh call runs `lsof -nP -iTCP:<p> -sTCP:LISTEN` for each port. If any are bound: rc 1 with
    `port P already bound on the Mac by <command> (pid X)`.
  - **Command.** `ssh "${SIM_SSH_SOLO_OPTS[@]}" -N -o ExitOnForwardFailure=yes -R 127.0.0.1:P:127.0.0.1:P …`.
    `127.0.0.1` is used on both sides, never `localhost`.
  - **Readiness.** Up when `lsof` shows every port listening on the Mac within 5 s. Otherwise kill the tunnel and
    rc 1 with ssh's stderr.
  - **Foreground (default).** Prints `tunnel up: Mac 127.0.0.1:P -> host 127.0.0.1:P` and holds until a signal.
  - **`--background`.** Writes the pidfile `$SIM_STATE/ios/N.tunnel` (pid and ports), prints the same line and
    returns. A watcher loop exits the tunnel within 30 s once the worktree no longer holds an ios lease.
  - **`--stop`.** Kills the background tunnel of this worktree's slot.
- **`sim maestro ios --forward p[,p…]`.** `--forward` is consumed by sim and never passed to Maestro. Starts the
  tunnel (same checks) before the run and stops it in the EXIT trap.
- **`cmd_status`.** Appends `tunnel P,P` to an ios slot with a live pidfile.
- **`cmd_reap`.** Removes pidfiles whose pid is gone.

**Unit tests (`43-tunnel.sh`).**
- The ssh shim records `-R` arguments. Its lsof mode is controlled by `$T/lsof.out`.
- Cases:
  - `sim tunnel ios 22000 --background` → the ssh line has `-R 127.0.0.1:22000:127.0.0.1:22000`,
    `ExitOnForwardFailure=yes` and `ControlPath=none`, and the pidfile exists.
  - A port outside the block → rc 2 with the hint. With `--any-port`: a warning, then rc 0.
  - A bound port → rc 1, and the message names the command.
  - `--stop` → the pid is dead and the pidfile is gone.
  - `sim maestro ios --forward 22000 test x` → tunnel ssh before sim-maestro, `--forward` absent from the Maestro
    args, and the tunnel is gone after the run.
  - Status shows the tunnel.

**E2e.**
1. The host container runs `python3 -m http.server 22000`.
2. `sim tunnel ios 22000 --background`, then `docker exec af-sim-mac curl -s 127.0.0.1:22000` returns the listing.
3. A second `sim tunnel ios 22000` → rc 1 with `already bound`.
4. `sim maestro ios --forward 22001 test flows/`, where the maestro shim curls `127.0.0.1:22001` and records the
   result: success.

**Verify.** Unit and e2e → 0 failed.

**Commit:** `Forward host ports to the Mac with sim tunnel and --forward`

---

### T11 Metro environment and readiness (`agent/sim-metro`)

Feedback #4, plus the `sleep 5` and adb reverse weak points. Depends on T3 and T4.

**Outcome.**
- Metro on the Mac gets the variables the app needs.
- `sim metro start` returns only once Metro answers.
- `sim build` always reapplies `adb reverse`.

**Spec.**
- **`sim metro start <p> [--env K=V]…`.** The variables passed are:
  - every `EXPO_PUBLIC_*` in the caller's environment;
  - every name in `SIM_METRO_ENV` (comma list; T13 fills it from the repo config);
  - each `--env`.
  - Names are checked against `^[A-Za-z_][A-Za-z0-9_]*$`.
  - On the host they are applied through `env`. On iOS they become an `env K=V …` prefix quoted with `printf %q`
    in the remote command.
  - The names passed (not the values) are printed: `env: EXPO_PUBLIC_API_URL, EZ_X`.
- **Readiness.**
  - Poll `http://127.0.0.1:<port>/status` until the body is `packager-status:running`, up to
    `SIM_METRO_READY_TIMEOUT` (default 90 s) at 1 s intervals.
  - On the host with `curl -fs`. On iOS with one remote loop over ssh.
  - On timeout: rc 1 and the last 20 lines of the Metro log.
  - Prints `Metro ready on port P`.
- **`cmd_build`.** Remove `sleep "${SIM_METRO_SETTLE:-5}"`. When Metro is already running, still run
  `adb reverse tcp:8081 tcp:<port>` after `sim_android_wait`. A failed reverse is now rc 1, not a warning.

**Unit tests (`71-metro.sh`).**
- The curl shim prints `$T/metro.status` content. The ssh shim records the remote command.
- Cases:
  - `EXPO_PUBLIC_API_URL=x sim metro start ios --env FOO=b\ c` → the remote command contains
    `env EXPO_PUBLIC_API_URL=x FOO=b\ c npx expo start --port 8081`.
  - A bad `--env 1X=y` → rc 2.
  - Status `packager-status:running` → rc 0 and `ready`. An empty status with `SIM_METRO_READY_TIMEOUT=2` → rc 1,
    with the log tail in stderr.
  - `sim build` with Metro running calls `adb reverse` and does not sleep (it completes in under 1 s with the
    shims).
  - The existing `70-commands.sh` build expectations still pass, after removing `SIM_METRO_SETTLE`.

**E2e.** `EXPO_PUBLIC_API_URL=http://127.0.0.1:22000 sim metro start ios` → ready. The Mac-side npx shim recorded
the variable.

**Verify.** Unit and e2e → 0 failed.

**Commit:** `Pass environment to Metro and wait until it is ready`

---

### T12 sim doctor and device recovery (`agent/sim-doctor`)

Feedback #9. Depends on T3 and T9.

**Outcome.**
- `sim doctor` explains why a device or driver is unhealthy.
- `sim android restart` and `sim maestro … --fresh|--cold` recover without manual steps.

**Spec.**
- **`sim doctor [android|ios|web] [N|all]`.**
  - Defaults: this worktree's leased slots on every platform; `all` means every slot.
  - Each line is `ok|warn|fail  <platform> <N>  <check>  <detail>`. rc 1 if any line is `fail`.
  - **android checks:**
    - unit active, and uptime from `systemctl --user show -p ActiveEnterTimestamp`;
    - `NRestarts` (warn if more than 0);
    - `sys.boot_completed`;
    - adb round trip: time of `adb shell true`, warn above 500 ms, fail above 5 s;
    - the mobilecli daemon for the slot is alive, judged from `$SIM_STATE/android/N.mobilecli`;
    - instrumentation clients on the device, from `adb shell ps -A` filtered for the Maestro driver and
      uiautomator processes. Warn when more than one instruments the device. The agent confirms the exact process
      and package names live (read-only, with `adb -P <port> shell ps -A` and `pm list packages | grep -i
      maestro`) and records them in a code comment;
    - in the last `AGENT_SIM_KEEP_RUNS` runs: the count of `DeviceServerDiedException|Device server died` in the
      Maestro logs, and of `FATAL EXCEPTION|lowmemorykiller|am_crash` in `logcat.txt`;
    - host: MemAvailable, load against nproc, free disk in `$SIM_CACHE`.
  - **ios checks:**
    - probe and round trip;
    - `sim-maestro --version` = 2;
    - `xcodebuildmcp --version` and `maestro --version` match the pins;
    - the runtime is present;
    - `agent-ios-N` exists, and its state;
    - free disk (warn under 15 GB);
    - a live tunnel pidfile, if any.
  - **web checks:** Playwright browsers are installed under `$SIM_PREFIX`.
- **`sim android restart <N|all>`.** Stops the unit, stops the slot's mobilecli daemon, starts the unit, then runs
  `sim_android_wait`. Prints `emulator-XXXX restarted cold; the app is gone, run sim build`.
- **`sim maestro android|ios --fresh`.** Resets the driver without a reboot:
  - android: `am force-stop` on the Maestro driver packages and kill stray uiautomator processes;
  - ios: `simctl terminate` on the Maestro driver bundle, its id confirmed live.
- **`sim maestro android|ios --cold`.**
  - android: `sim android restart N` first, which needs the app reinstalled, so print that and require
    `--cold` to be explicit;
  - ios: `simctl shutdown` then boot. The app persists.
- Both flags are consumed by sim and not passed to Maestro.

**Unit tests (`91-doctor.sh`).**
- adb, systemctl and ssh shims return canned outputs from `$T/doctor/*`.
- Cases:
  - A healthy android slot → all lines ok, rc 0.
  - `NRestarts=2` → warn.
  - boot_completed 0 → fail and rc 1.
  - Two instrumentation processes → warn.
  - A run directory whose log contains `DeviceServerDiedException` → warn with the count.
  - ios with the Mac down → `fail … unreachable` and rc 1. An old launcher version → fail with the bootstrap hint.
  - `sim android restart 1` → the systemctl log has stop then start, and mobilecli `daemon stop`.
  - `--fresh` → the adb log has `am force-stop`, and `--fresh` is absent from the docker args.
  - `--cold` on android → restart before the run.

**E2e.** `sim doctor ios 1` against the fake Mac → ok lines for the probe, launcher and simulator. `docker pause`
→ fail.

**Verify.** Unit and e2e → 0 failed. Read-only live: `sim doctor all` on as1 prints a full report and changes
nothing. Check this with `sim status` before and after.

**Commit:** `Add sim doctor and driver and device recovery`

---

### T13 Per-repo .sim/config and the Expo stack seam (`agent/sim-repo-config`)

Depends on T7, T9, T10 and T11.

**Outcome.**
- A repo states its sim needs in a committed `.sim/config`.
- Every Expo-specific command sits behind `sim_stack_*` functions, ready for another stack later. Behaviour for
  Expo is unchanged.

**Spec.**
- **Format.** `key = value` lines, `#` comments, blank lines allowed. Parsed with a strict reader
  (`sim_repo_config <root>`) that sets `SIM_CFG_<KEY>`. Never sourced.
  - An unknown key warns on stderr.
  - A malformed line or bad value → rc 2, naming `.sim/config:<line>`.
- **Keys:**

  | Key | Meaning |
  |---|---|
  | `stack` | `expo` only, for now |
  | `app_dir` | relative to the root; used when sim runs at the root |
  | `metro_env` | comma list, feeds `SIM_METRO_ENV` |
  | `forward_ios` | comma list of ports; the default for `sim tunnel ios` with no ports, and added to `sim maestro ios` runs when `--forward` is absent; `--forward none` turns it off |
  | `ports` | 1-100, checked against the block; `sim ports <p>` with no count prints that many |
  | `keep_runs` | 1-50, overrides `AGENT_SIM_KEEP_RUNS` |

- **Precedence:** CLI flag, then environment variable, then `.sim/config`, then host `.env`, then the default.
- **Stack seam in `lib/sim.sh`:** `sim_stack_build_android <port> [args]`, `sim_stack_metro_cmd <port> [--web]`,
  `sim_stack_ios_prepare_cmd`, `sim_stack_rsync_rules`. Each dispatches on `stack`, and only `expo` exists.
  `bin/sim` no longer contains the literal `npx expo` outside these functions.
- **`sim enable`** writes `.sim/config` with all keys commented out and their defaults, only when the file is
  absent. It reports `wrote .sim/config` or `kept .sim/config`.

**Unit tests (`51-repo-config.sh`).**
- Parsing:
  - A valid file sets the values.
  - An unknown key warns but rc 0.
  - `ports = 200` → rc 2 with `.sim/config:N`.
  - A line `foo` with no `=` → rc 2.
  - `$(touch /tmp/x)` as a value is never executed (the file is not created).
- Precedence: `keep_runs` in the config (2) beats `.env` (5), and `AGENT_SIM_KEEP_RUNS` in the environment beats
  the config.
- `forward_ios = 22000`: `sim maestro ios test x` starts a tunnel for 22000. `--forward none` starts none.
- `metro_env = FOO`: the remote Metro command carries FOO.
- `sim enable` creates the template once and does not overwrite it.
- `grep -n 'npx expo' bin/sim` finds nothing. Every existing build, metro and prepare expectation still passes.

**Verify.** `bash tests/sim-test.sh` → 0 failed. `bash tests/e2e/sim-mac.sh` → 0 failed.

**Commit:** `Read per-repo needs from .sim/config behind an Expo stack seam`

---

### T14 JSON output, contract version, and `sim enable --check` (`agent/sim-contract`)

Depends on T6, T12 and T13.

**Outcome.**
- Scripts and CI can read sim's state as JSON.
- A repo can tell when its pasted AGENTS.md section or its MCP files are out of date.

**Spec.**
- **Contract version.** `SIM_CONTRACT_VERSION=2` in `lib/sim.sh`. `sim version` prints
  `sim contract 2; maestro 2.11.0; mobile-mcp 1.0.6; xcodebuildmcp 2.7.0; playwright-mcp 0.0.83`.
  `--json` gives an object.
- **`--json`**, built with `jq -n`:
  - `sim status --json`: an array of
    `{platform, slot, device, state, idle_secs, lease: null|{kind, pid, root, since, until}, tunnel: [ports]}`.
  - `sim ports <p> --json`: `{base, count}`.
  - `sim lease <p> --json`: `{platform, slot, root, until}`.
  - `sim doctor --json`: an array of `{level, platform, slot, check, detail}`.
  - Exit codes are unchanged.
- **The AGENTS.md section** from `sim enable`:
  - Wrapped in `<!-- sim-contract: 2 -->` … `<!-- /sim-contract -->`.
  - The text is rewritten for the new contract:
    - devices and leases, including `sim lease` for CLI-only work;
    - `sim ports` for test stacks;
    - `sim tunnel ios` and `--forward` for host services;
    - `sim metro start … --env`;
    - Maestro run directories and `latest`;
    - `sim doctor` and `--fresh`/`--cold`;
    - exit 3 means retry later;
    - never run `maestro` or `npx expo run:*` directly.
  - `sim enable --print-agents` prints only the section.
- **`sim enable --check [dir]`:**
  - rc 0 when all of these hold:
    - the three MCP files contain the current entries;
    - AGENTS.md contains a block whose contract version and body match `--print-agents`;
    - `.sim/config` parses.
  - rc 1 with a unified diff, or a one-line reason per problem, when stale. rc 2 for usage errors.
  - It never writes.

**Unit tests (`52-json-check.sh`).**
- `jq -e` validates each JSON shape: types, and a lease present or null.
- `sim version --json | jq -e .contract==2`.
- `--check`:
  - On a fresh `sim enable` plus a pasted `--print-agents`, rc 0.
  - With an older block (`sim-contract: 1`), rc 1 and the output says `contract 1, current 2`.
  - With an edited body, rc 1 with a diff.
  - With `.mcp.json` missing sim-ios, rc 1.
  - It never writes: the mtimes of the files are unchanged.

**Verify.** `bash tests/sim-test.sh` → 0 failed. `bash tests/params-test.sh` → 0 failed (literal scan over the new
heredoc).

**Commit:** `Add JSON output, a contract version and sim enable --check`

---

## 2. Merge order and conflict handling

- Land the tasks in this order: T1, T2, then T6, T7, T3, T4, T5 (in wave 2, this order lands the smallest
  `sim_lease` and `cmd_status` changes first), then T9, T11, T10, T8, then T12, T13, then T14.
- After each landing, the agent of every open task in the same wave rebases onto the new tip before it finishes,
  and runs the full unit suite again.
- Known conflict pairs:

  | Pair | Where | Resolution |
  |---|---|---|
  | T3 / T4 | `cmd_ios` | Keep `sim_mac_require` at the top and the `sim_mac_dir` quoting in the body |
  | T3 / T6 | `cmd_status` | Keep T6's lease-kind column and T3's ios state values |
  | T5 / T6 | `bin/sim-mcp` startup | T5's relay launch replaces the fifo block; T6's `sim_lease` call is unchanged |
  | T9 / T10 / T12 | argument parsing in `maestro_ios` | Consume `--forward`, `--fresh`, `--cold` in one loop before the path rewriting |

---

## 3. Final end-to-end verification (on `agent/sim-service`, after T14)

### A. Automated, all must be green

```sh
bash tests/sim-test.sh                     # N passed, 0 failed
bash tests/e2e/sim-mac.sh                  # N passed, 0 failed
bash tests/params-test.sh                  # N passed, 0 failed
bash tests/e2e/run.sh                      # install scripts still pass (install-ios-runner.sh and lib/params.sh changed)
shellcheck -x bin/sim bin/sim-mcp install-ios-runner.sh tests/sim-test.sh tests/sim/*.sh tests/e2e/sim-mac.sh
shellcheck -x -s bash lib/sim.sh
node --check bin/sim-mcp-relay.mjs
```

### B. Live, on as1 and the Mac

The operator agrees on a time first, because these steps restart sim units and the Mac launcher.

1. **Install and bootstrap.** Re-run `./install-host.sh --no-tools` (it links the new files), then
   `sim ios bootstrap` (new launcher). `sim doctor all` shows no `fail`. `sim version` prints contract 2.
2. **Fixture app.** Make a scratch Expo app in a throwaway git repo under `~/workspace/sim-e2e-fixture` (created
   for this test and deleted afterwards). Use `npx create-expo-app@latest --template blank`, add two Maestro flows
   (launch and assert text; tap and assert), then `sim enable` and commit.
3. **CLI-only Android.** Start no harness.
   - `sim lease android`, `sim wait`, `sim build`.
   - `sim maestro android test .maestro/` → rc 0. `latest/` has `logcat.txt` and `debug/`.
   - `sim release android`.
4. **Sticky slot and ports.**
   - `sim lease ios` (note slot N), `sim release ios`, `sim lease ios` → the same N.
   - `eval "$(sim ports ios)"`.
   - Start `python3 -m http.server $SIM_PORT_BASE`.
   - `sim tunnel ios $SIM_PORT_BASE --background`.
   - `ssh` on the Mac: `curl 127.0.0.1:$SIM_PORT_BASE` succeeds.
5. **iOS run with environment and output.**
   - `sim ios prepare`, then build with the sim-ios tools through `node tests/mcp-probe.mjs`.
   - `EXPO_PUBLIC_API_URL=http://127.0.0.1:$SIM_PORT_BASE sim metro start ios` → `ready`.
   - `sim maestro ios test .maestro/ --format junit --output e2e/report.xml` → rc 0, and `e2e/report.xml` exists on
     the host.
   - Run it again: two run directories.
6. **Mac drop.**
   - In a harness session (Claude Code) in the fixture, take a screenshot with sim-ios.
   - On the Mac, turn Tailscale off for 2 minutes. Tool calls return "mac unreachable, reconnecting".
     `sim status` shows `unreachable` and the same lease pid.
   - Turn Tailscale back on. Within about 70 s a screenshot works again in the same session, with no harness
     restart.
7. **Driver recovery.** `sim maestro android --fresh test .maestro/` → rc 0. `sim doctor android` reports the
   instrumentation clients and no death counts.
8. **Contract check.**
   - `sim enable --check` in the fixture → rc 0.
   - Replace the pasted block with a `sim-contract: 1` version → rc 1.
   - Run `sim enable --check` against the ezbus checkout read-only → rc 1, as expected. Tell the operator to
     re-paste the section there. This session does not edit ezbus.
9. **Reaping.** With `AGENT_SIM_IDLE_MINUTES=1` exported for one manual `sim reap`, after 2 minutes idle the
   devices stop. `sim status` shows `off` and expired CLI leases are gone.
10. **Clean up.** `sim release` everything, `sim tunnel ios --stop`, remove `~/workspace/sim-e2e-fixture`, and
    `sim ios gc 0` for its tree on the Mac.

**Done when:** A is all green, and B steps 1-10 match their expected results. Record each step's outcome with
pass/fail in the integration branch's last commit body, or in the PR body if the operator wants a PR. Landing on
`main` is a fast-forward of `agent/sim-service`, done when the operator says so.
