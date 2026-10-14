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

Out of scope: scripted test suites (Maestro, Detox), watching the devices live, physical devices, and release
builds; each can be added later without changing the slot model.

## 2. Architecture

```
 harness session in an opted-in repo (Claude Code, Codex, OpenCode, Oh My Pi)
   │ stdio MCP, started by the harness
   ├─ sim-mcp web      lease web N      → Playwright MCP, headless, in-memory profile (chromium; webkit on request)
   ├─ sim-mcp android  lease android N  → mobile-mcp with ANDROID_ADB_SERVER_PORT=5037+N
   │                                         └─ systemd --user agent-sim-android@N: adb server 5037+N, emulator-(5552+2N)
   └─ sim-mcp ios      lease ios N      → ssh -T <ios-user>@<mac-mini> sim-xcodebuildmcp N
                                             └─ XcodeBuildMCP, session defaults pinned to simulator agent-ios-N
 sim (CLI): status, enable, wait, env, run, metro, android, ios sync|prepare|bootstrap|gc
```

**Leases.** A slot is an flock on `$XDG_RUNTIME_DIR/agent-sim/<platform>/<N>.lock`. `sim-mcp` takes the first
free one and runs the real server as its child until the harness closes it, then exits, which frees the slot. Only
`sim-mcp` holds the descriptor: the server and every helper run with it closed, so an adb daemon or a stray helper
can never keep a slot. `<N>.owner` records pid and worktree; `sim` commands find "my slot" by the worktree's git top
level, so `sim run`, `sim metro` and `sim wait` act on the device the session's MCP server holds.

**Android isolation.** mobile-mcp lists every device its adb server knows and ignores `ANDROID_SERIAL`. So each
emulator registers with a private adb server (port 5037+N), started by its unit, and slot N's mobile-mcp and every
`sim run` command talk to that server only. The default adb server sees no emulator at all.

**Emulators.** One AVD (`agent-sim-android`, Pixel 7, API 35 google_apis x86_64) started `-read-only`, so all slots
share its image; headless, `swiftshader_indirect`, no snapshot saving. A unit is started on the first lease and left
running for the next agent; `sim android stop all` frees the memory.

**Ports** (from the slot number, nothing allocated): Android Metro 8100+N, reversed to the device's 8081; Expo web
8200+N; iOS Metro on the Mac 8081 for slot 1 and 8091 for slot 2 (a React Native debug build asks the port it was
built with, `RCT_METRO_PORT`; the simulators share the Mac's localhost).

**iOS.** `sim ios prepare`, run from the app's directory, syncs the worktree to `~/sims/<repo>[-<slug>]/` on the
Mac (no `.git`, `node_modules`, `.env*`, keystores or build output; the Mac's generated `ios/` survives `--delete`),
then runs `npm ci`, `expo prebuild -p ios` and `pod install` there and prints the workspace path. The agent then
sets XcodeBuildMCP's session defaults (workspace, scheme) and calls `build_run_sim`, `screenshot`, `tap` and so on.
`sim ios sync` alone is enough after a JS-only change.

**Telemetry.** Off for the servers that have it: `MOBILEMCP_DISABLE_TELEMETRY=1`, `XCODEBUILDMCP_SENTRY_DISABLED=true`.

## 3. Phase 0 findings (14 Oct 2026)

| # | Question | Finding |
|---|---|---|
| S1 | Does mobile-mcp keep to `ANDROID_SERIAL`? | No: it lists every device of its adb server (source of 1.0.6). Hence one adb server per slot |
| S2 | Can the runner boot a simulator, screenshot and build over a non-GUI ssh session? | Yes: boot 23 s, `simctl io screenshot` works, XcodeBuildMCP builds. The runner login also had a console session; untested without one |
| S3 | CocoaPods without admin? | Yes: mise's precompiled Ruby 3.4 (`MISE_RUBY_COMPILE=false`) and `gem install cocoapods` |
| S4 | Project-level MCP config per harness? | Claude Code and Oh My Pi read `.mcp.json`; OpenCode reads `opencode.json` `mcp`; Codex reads `.codex/config.toml` only in a trusted project, and trusting the main checkout covers its worktrees (a trusted parent directory does not) |
| S5 | The emulator on a headless host | needs X/xcb, PulseAudio and font libraries even with `-no-window`; listed in `SIM_APT_PACKAGES` |
| — | XcodeBuildMCP's simulator default | the name alone leaves `screenshot` asking for a UUID; the Mac launcher resolves `agent-ios-N` to its UUID |
| — | A lock probe and a lease at the same instant | the lease skipped a free slot; `sim_lease` now waits 0.2 s per slot |

## 4. Contract

| Command | Does |
|---|---|
| `sim-mcp <android\|web\|ios>` | stdio MCP server for one slot; the lease banner (stderr) names slot and worktree; exits 1 when the pool is full |
| `sim status` | one line per slot: device, unit state, free or leased (pid, worktree) |
| `sim enable [--only P,P] [dir]` | writes or merges the three harness files (only `sim-mcp <platform>`, no host or path), prints the AGENTS.md section |
| `sim wait [secs]` | starts this worktree's emulator if needed and waits for boot |
| `sim env` / `sim run <cmd>` | the slot's `ANDROID_HOME`, `JAVA_HOME`, `ANDROID_ADB_SERVER_PORT`, `ANDROID_SERIAL`; `sim run npx expo run:android` builds and installs on it |
| `sim metro start\|stop\|log <P>` | Metro for the slot, from the current (app) directory |
| `sim android start\|stop\|logs <N\|all>` | the emulator units |
| `sim ios sync\|prepare\|bootstrap\|gc [days]` | the Mac side |

Exit codes: 0 done, 1 failed (message on stderr), 2 usage.

## 5. Test layers

- `tests/sim-test.sh`, unit, no sudo, network, emulator or Mac:
  - It runs a copy of the scripts against a test `.env`, with shims for `systemctl`, `ssh`, `rsync`, `mise` and the server.
  - It covers parameters, port maths, names, leasing (grant, pool exhaustion, release when the holder exits, my-slot lookup) and `sim enable` (merge, idempotency, `--only`, invalid JSON).
  - It also covers the three `sim-mcp` launches with their environment, `sim env`, `run`, `status` and the rsync filter.
- `tests/mcp-probe.mjs` speaks MCP over stdio the way a harness does: `initialize`, `tools/list`, then `--call`s. It drives the live checks.
- `tests/params-test.sh` covers the new parameters and the literal scan.
- Live, by hand, because KVM, the Mac and the tailnet are not in a container (README section 6, verify block):
  - three emulators leased and booted together;
  - a web page through `sim-mcp web`;
  - the Expo client built, run and screenshotted on `agent-ios-1` through `sim-mcp ios`.
