# Simulators: every agent on the host can run its app on Android, the web and iOS

The device simulation service: headless Android emulators and browsers on the host, iOS simulators on a Mac
reached over ssh, each driven by an MCP server an agent's harness starts. Any repo opts in with `sim enable`.
README section 6 is the runbook; `lib/sim.sh` holds the model in its header comment; AGENTS.md has the layout rows.

## 1. Goal and decisions

An agent building a mobile or web app (the first is an Expo app: one codebase for iOS, Android and the web) has to
see its own change running: launch the app, tap, type, read the screen, take a screenshot. Several agents work at
once, in different repos and worktrees, under four harnesses.

| Topic | Decision | Why |
|---|---|---|
| Driving the devices | MCP servers: Playwright MCP (web), mobile-mcp (Android), XcodeBuildMCP (iOS) | live, interactive use by the agent; the same in every harness |
| Where they run | Android and web on the host; iOS on a Mac (Xcode only runs there) | the host has KVM and the RAM; the Mac has Xcode |
| Reaching the Mac | XcodeBuildMCP as a stdio server through `ssh <ios-user>@<mac-mini>` over Tailscale | no listening port, key login, nothing to authenticate twice |
| Mac account | a dedicated non-admin login (`AGENT_IOS_USER`) | whatever an agent does on the Mac stays in that account |
| Source for iOS builds | `sim ios sync` rsyncs the worktree to the Mac; the Mac holds no git credentials | an agent builds what it has, committed or not |
| Concurrency | slots: 3 Android, 3 web, 2 iOS by default (`AGENT_SIM_*_SLOTS`) | about 2 GB RAM per emulator on the host; the Mac has 16 GB |
| Isolation | one slot per harness session, held by its MCP server process | agents never share a device or fight over one |
| Registration | per repo (`sim enable` writes `.mcp.json`, `opencode.json`, `.codex/config.toml`) | repos without apps keep a short tool list |
| JS during development | Expo debug build + Metro: on the host via `adb reverse` for Android, on the Mac for iOS | a JS change needs no native rebuild |

Out of scope: Detox, watching the devices live, physical devices, and release builds; each can be added later
without changing the slot model. Maestro flows run on the slot's emulator with `sim maestro` (added 14 Oct 2026, see
Maestro below).

## 2. Architecture

```
 harness session in an opted-in repo (Claude Code, Codex, OpenCode, Oh My Pi)
   │ stdio MCP, started by the harness
   ├─ sim-mcp web      lease web N      → Playwright MCP, headless, in-memory profile (chromium; webkit on request)
   ├─ sim-mcp android  lease android N  → mobile-mcp with ANDROID_ADB_SERVER_PORT=5037+N
   │                                         └─ systemd --user agent-sim-android@N: adb server 5037+N, emulator-(5598+2N)
   └─ sim-mcp ios      lease ios N      → ssh -T <ios-user>@<mac-mini> sim-xcodebuildmcp N
                                             └─ XcodeBuildMCP, session defaults pinned to simulator agent-ios-N
 sim (CLI): status, enable, wait, env, run, build, maestro, metro, android, ios sync|prepare|bootstrap|gc
```

**Leases.** A slot is an flock on `$XDG_RUNTIME_DIR/agent-sim/<platform>/<N>.lock`. `sim-mcp` takes the first
free one and runs the real server as its child until the harness closes it, then exits, which frees the slot. Only
`sim-mcp` holds the descriptor: the server and every helper run with it closed, so an adb daemon or a stray helper
can never keep a slot. `<N>.owner` records pid and worktree; `sim` commands find "my slot" by the worktree's git top
level, so `sim run`, `sim metro` and `sim wait` act on the device the session's MCP server holds.

**Android isolation.** mobile-mcp lists every device its adb server knows and ignores `ANDROID_SERIAL`. So each
emulator registers with a private adb server (port 5037+N), started by its unit, and slot N's mobile-mcp and every
`sim run` command talk to that server only. The default adb server sees no emulator at all. Three things make
that hold:
- Consoles at 5600 and up. An adb server scans 5555–5585 when it starts and adopts every emulator there, so with
  the usual 5554+ ports a slot's server that started late saw its neighbours too.
- One mobilecli daemon per slot. mobile-mcp works through `mobilecli`, whose daemon is shared through a socket in
  `~/.mobilecli` and keeps the adb server of whoever started it. `sim-mcp` gives each slot its own
  `MOBILECLI_HOME` and stops that daemon when the session ends.
- Metro on the slot's port. A default dev build asks `localhost:8081` on the device, which `adb reverse` sends to
  8100+N. `sim build` passes `--port 8100+N` to `expo run:android`, which bakes that port into the build and reuses
  the running Metro. Expo's default would be 8081, and `--no-bundler` cannot be combined with `--port`.

**Emulators.** One AVD (`agent-sim-android`, Pixel 7, API 35 google_apis x86_64) started `-read-only`, so all slots
share its image; headless, `swiftshader_indirect`, no snapshot saving. A unit is started by the slot's first tool
call (see Uptime). A read-only instance writes to qcow2
overlays (about 1 GB at boot, more with use) in `ANDROID_TMP`. The emulator's default is `/tmp`, a tmpfs on the host,
and a crash leaves them there. Each slot uses `~/.cache/agent-sim/android/N` instead, emptied at every start. The
unit restarts an emulator that fails, up to 3 times in 2 minutes.

**Ports** (from the slot number, nothing allocated): Android Metro 8100+N, reversed to the device's 8081; Expo web
8200+N; iOS Metro on the Mac 8081 for slot 1 and 8091 for slot 2 (a React Native debug build asks the port it was
built with, `RCT_METRO_PORT`; the simulators share the Mac's localhost).

**iOS.** `sim ios prepare`, run from the app's directory, syncs the worktree to `~/sims/<repo>[-<slug>]/` on the
Mac (no `.git`, `node_modules`, `.env*`, keystores or build output; the Mac's generated `ios/` survives `--delete`),
then runs `npm ci`, `expo prebuild -p ios` and `pod install` there and prints the workspace path. The agent then
sets XcodeBuildMCP's session defaults (workspace, scheme) and calls `build_run_sim`, `screenshot`, `tap` and so on.
`sim ios sync` alone is enough after a JS-only change.

**Uptime** (added 14 Oct 2026). The simulators are used in bursts, during app development, and a harness session
(with its lease) can stay open in tmux for days. So a lease starts nothing, and nothing stays up unused:

- `sim-mcp` passes the harness's messages to the server through a relay. Before each `tools/call` it touches
  `<N>.active` and, if the slot's device is down, starts it and holds the call until it has booted: the emulator unit
  and `adb wait-for-device` plus `sys.boot_completed` (about 30 s), or `xcrun simctl bootstatus agent-ios-N -b` on
  the Mac (a few seconds). `initialize` and `tools/list` pass straight through, so a harness starts as fast as before.
  Codex gets `tool_timeout_sec = 300` from `sim enable` (its default, 60 s, is close to a cold boot).
- `sim wait`, `run`, `build`, `metro start`, `android start` and `ios start` count as use too.
- `sim reap`, every 5 minutes from `agent-sim-reap.timer`, stops the emulator unit, the iOS simulator (with its Metro
  on the Mac) and the host Metro of every slot unused for `AGENT_SIM_IDLE_MINUTES` (default 30, 0 never), leased or
  not. A slot with no `<N>.active` yet starts its clock there, so a device started by hand gets the full time.
  `<N>.down` marks an iOS simulator shut down by `sim`: the reaper reaches the Mac once per idle spell, and the next
  tool call boots it. Web slots run no device of their own; the reaper stops their Expo web server.
- Cost: an emulator starts clean (`-read-only`), so after an idle stop the agent runs `sim build` again; Gradle's
  cache makes that the incremental build. An iOS simulator keeps its installed apps.
- Measured before (14 Oct 2026): an idle emulator held 3.5–3.7 GB and about 0.75 of a core; the three together
  about 11 GB of the host's 28 GB.

**Maestro** (added 14 Oct 2026). Maestro reads no `ANDROID_ADB_SERVER_PORT`. In 2.11.0 (from its bytecode), it finds
Android devices in two ways: dadb's `Dadb.list()`, which asks an adb server on 5037 and, when that one has no device,
connects straight to every emulator port from 5555 to 5683; and an adb server on 5038, which is also what a session
uses. On the host neither works for a slot. The default server on 5037 sees no emulator, so the scan reaches the
slot's adbd port (5599+2N), where the emulator already serves the slot's adb server and never answers a second
client: Maestro hangs without a word. And 5038 is slot 1's server, whichever slot the agent holds. Its hidden
`--host`/`--port` options connect to adbd directly and hang the same way. The emulator only takes console ports up to
5682, so the slots cannot leave the scan range.

`sim maestro <args>` therefore runs Maestro in a container, which is a network namespace of its own:
- A relay container on the host network (`socat`, same image) offers the slot's adb server, 127.0.0.1:5037+N, as a
  unix socket in `$SIM_STATE/android/N.maestro/`.
- The Maestro container mounts that directory, and its entry point (`config/sim/maestro-entry.sh`) relays its own
  5037 and 5038 to the socket. Nothing listens in the scan range there, so the scan fails at once and Maestro finds
  the slot's emulator through 5037. It runs with `--device emulator-(5598+2N)`, as the host user, with the worktree
  mounted at its own path, and HOME, `~/.cache/agent-sim/android/maestro-N`, too, so the debug output path Maestro
  prints (`.maestro/tests/<run>`, screenshots of a failed step) is right on the host.
- The device reaches Metro through the slot's `adb reverse` as before; Maestro's driver traffic goes through adb
  streams, not a host port, so slots run Maestro at the same time. One run per slot at a time.
- `agent-sim-maestro:<version>-<hash of the Dockerfile and entry script>` is built on first use from `config/sim/Dockerfile.maestro` (Temurin 17 JRE, Ubuntu
  noble, socat), with the release zip checked against `SIM_MAESTRO_SHA256`. Docker usable without sudo is the one
  host requirement; `unshare -rn` would avoid it, but Ubuntu restricts unprivileged user namespaces
  (`kernel.apparmor_restrict_unprivileged_userns=1`) and lifting that needs root.
- A new Maestro version needs the same check: the ports it dials (`AndroidDeviceConnection$Companion`,
  `MaestroSessionManager`, `DeviceService` in its jars) and whether it reads `ANDROID_ADB_SERVER_PORT` by now. If it
  does, `sim run maestro --device <serial> ...` on the host replaces all of this.

**Telemetry.** Off for the servers that have it: `MOBILEMCP_DISABLE_TELEMETRY=1`, `XCODEBUILDMCP_SENTRY_DISABLED=true`,
and for Maestro `MAESTRO_CLI_NO_ANALYTICS=1`.

## 3. Phase 0 findings (14 Oct 2026)

| # | Question | Finding |
|---|---|---|
| S1 | Does mobile-mcp keep to `ANDROID_SERIAL`? | No: it lists every device of its adb server (source of 1.0.6). Hence one adb server per slot, consoles above adb's scan range, and one mobilecli daemon per slot (see 2) |
| S2 | Can the runner boot a simulator, screenshot and build over a non-GUI ssh session? | Yes: boot 23 s, `simctl io screenshot` works, XcodeBuildMCP builds. The runner login also had a console session; untested without one |
| S3 | CocoaPods without admin? | Yes: mise's precompiled Ruby 3.4 (`MISE_RUBY_COMPILE=false`) and `gem install cocoapods` |
| S4 | Project-level MCP config per harness? | Claude Code and Oh My Pi read `.mcp.json`; OpenCode reads `opencode.json` `mcp`; Codex reads `.codex/config.toml` only in a trusted project, and trusting the main checkout covers its worktrees (a trusted parent directory does not) |
| S5 | The emulator on a headless host | needs X/xcb, PulseAudio and font libraries even with `-no-window`; listed in `SIM_APT_PACKAGES` |
| — | XcodeBuildMCP's simulator default | the name alone leaves `screenshot` asking for a UUID; the Mac launcher resolves `agent-ios-N` to its UUID |
| S5b | Three emulators together | Boot within 30 s of each other, about 17 GB RAM in use on the host with all three. Two of the first three starts segfaulted a few seconds in; later starts, together and one by one, did not. Cause not found, hence the restart |
| — | Overlays of a read-only emulator | 1–1.6 GB each in `/tmp`; leftovers from crashed runs filled 12 of the host's 15 GB tmpfs |
| — | `CI=1 expo start` | turns off Metro's file watching; Metro runs with stdin from `/dev/null` instead |
| — | A lock probe and a lease at the same instant | the lease skipped a free slot; `sim_lease` now waits 0.2 s per slot |

## 4. Contract

| Command | Does |
|---|---|
| `sim-mcp <android\|web\|ios>` | stdio MCP server for one slot; the lease banner (stderr) names slot and worktree; exits 1 when the pool is full |
| `sim status` | one line per slot: device, unit state (iOS: `down` once `sim` shut it down), minutes since last use, free or leased (pid, worktree) |
| `sim reap` | stop what idle slots run (above, Uptime); run by `agent-sim-reap.timer` |
| `sim enable [--only P,P] [dir]` | writes or merges the three harness files (only `sim-mcp <platform>`, no host or path), prints the AGENTS.md section |
| `sim wait [secs]` | starts this worktree's emulator if needed and waits for boot |
| `sim env` / `sim run <cmd>` | the slot's `ANDROID_HOME`, `JAVA_HOME`, `ANDROID_ADB_SERVER_PORT`, `ANDROID_SERIAL` |
| `sim build [args]` | from the app's directory: starts the slot's Metro if needed, then `expo run:android --port <slot's Metro>` |
| `sim maestro <args>` | starts the slot's emulator if needed, then `maestro --device <slot's serial> <args>` in a container (above, Maestro); exits with Maestro's code |
| `sim metro start\|stop\|log <P>` | Metro for the slot, from the current (app) directory |
| `sim android start\|stop\|logs <N\|all>` | the emulator units |
| `sim ios start\|stop <N\|all>` | boot (and wait) or shut down `agent-ios-N` on the Mac |
| `sim ios sync\|prepare\|bootstrap\|gc [days]` | the Mac side |

Exit codes: 0 done, 1 failed (message on stderr), 2 usage.

## 5. Test layers

- `tests/sim-test.sh`, unit, no sudo, network, emulator or Mac:
  - It runs a copy of the scripts against a test `.env`, with shims for `systemctl`, `ssh`, `rsync`, `mise` and the server.
  - It covers parameters, port maths, names, leasing (grant, pool exhaustion, release when the holder exits, my-slot lookup) and `sim enable` (merge, idempotency, `--only`, invalid JSON).
  - It also covers the three `sim-mcp` launches with their environment, `sim env`, `run`, `status`, the rsync filter,
    and the two containers of `sim maestro` (with a `docker` shim).
- `tests/mcp-probe.mjs` speaks MCP over stdio the way a harness does: `initialize`, `tools/list`, then `--call`s. It drives the live checks.
- `tests/params-test.sh` covers the new parameters and the literal scan.
- Live, by hand, because KVM, the Mac and the tailnet are not in a container (README section 6, verify block):
  - three emulators leased and booted together;
  - a web page through `sim-mcp web`;
  - the Expo client built, run and screenshotted on `agent-ios-1` through `sim-mcp ios`.
