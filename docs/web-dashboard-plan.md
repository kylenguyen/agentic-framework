# Web dashboard: implementation plan

A browser front end on the host for the same work the SSH picker does: list sessions, start and kill them, and
type into them. Tasks T1 to T12 build it, T13 verifies it end to end. Each task is written to be handed to a
separate agent.

## 1. What gets built

A Node service on the host, reachable only through `tailscale serve`, that serves one web page:
- **Session list.** Every base session from `agent ls --json`: name, harness, repo, branch, worktree, state,
  age, devices, attention. Buttons for New and Kill.
- **Terminal.** A full-screen xterm.js terminal per session. Each browser tab runs `agent attach <name>` behind
  a pseudo-terminal, so it is one more grouped view. SSH, WezTerm and the fzf picker keep working unchanged on
  the same sessions. An exited session opens like any other (tmux shows its last screen) and keeps a Kill
  button.
- **Phone layout.** A soft-key bar, a line-input box and installation to the home screen.
- **Image and file paste.** An image goes through `clip-put`, any other file to a spool folder. The resulting
  path is typed into the session.
- **Sim panel.** Shows `sim status --json`.
- **Needs-input alerts.**
  - Claude Code hooks, and Codex `notify` if the installed version supports it, call `agent attention`.
  - For omp and opencode the server guesses from screen silence.
  - The page shows a badge and Web Push reaches the phone. On iPhone, Web Push only works once the page is
    added to the home screen (iOS 16.4 or later).

Out of scope: chat UI, live screen previews, public exposure, multiple users.

Two host facts shape the design:
- **No node-pty.** It ships no prebuilt Linux binaries and the host has no compiler. The terminal bridge is a
  small Python script (`/usr/bin/python3`, standard library only), so nothing needs sudo.
- **Package versions.** The pins below were the latest on npm on 28 Oct 2026.

## 2. Architecture and fixed contracts

All tasks code against these contracts. Change them only in the task that owns them.

**Layout**
```
web/package.json, web/package-lock.json   exact pins, installed with `npm ci --ignore-scripts`
web/server.mjs                            entry: config, HTTP server, route table, WS upgrade
web/lib/*.mjs                             auth.mjs, agent.mjs (execFile wrappers), sessions.mjs, term.mjs,
                                          upload.mjs, sim.mjs, attention.mjs, push.mjs, static.mjs
web/pty-bridge.py                         stdlib-only pty bridge (python3)
web/public/                               index.html, app.mjs, style.css, sw.js, manifest.webmanifest, icons/
config/systemd/agent-web.service          user unit
tests/web-test.sh, tests/web/*.test.mjs   node:test unit and integration tests (real tmux, own socket)
tests/e2e/web.sh, tests/e2e/Dockerfile.web, tests/e2e/web/*.spec.mjs   Playwright in Docker
```

**Dependencies** (exact versions, lockfile committed, served from `web/node_modules`, no bundler):
- runtime: `ws@8.22.0`, `web-push@3.6.7`, `@xterm/xterm@6.0.0` (`lib/xterm.mjs`, `css/xterm.css`),
  `@xterm/addon-fit@0.11.0`, `@xterm/addon-clipboard@0.2.0`
- dev: `@playwright/test@1.64.1`. The Docker image must be the matching
  `mcr.microsoft.com/playwright:v1.64.1-noble`; check the tag exists before using it.

**Runtime configuration** (environment, read from the optional `EnvironmentFile=-%h/.config/agent-web/env`):

| Variable | Default | Meaning |
|---|---|---|
| `AGENT_WEB_PORT` | `7690` | listen port, always on `127.0.0.1` |
| `AGENT_WEB_ALLOW` | none (required) | comma-separated Tailscale logins allowed in. The server refuses to start when it is empty |
| `AGENT_WEB_STATE` | `~/.local/state/agent-web` | VAPID keys and push subscriptions, mode 700/600 |
| `AGENT_WEB_FILES` | `~/.clip/files` | spool for non-image uploads, pruned after 24 h |
| `AGENT_WEB_QUIET_SECS` | `45` | silence before the quiet heuristic raises attention (T10) |
| `AGENT_TMUX_SOCKET`, `CLIP_BRIDGE_SPOOL`, `HOME` | inherited | passed through to `agent`, `clip-put` and `sim`; this is how tests isolate |

No host name, login or address appears in the repo (the literal scan in `tests/params-test.sh` must cover
`web/`).

**Security rules** (enforced in `web/lib/auth.mjs`, tested in T2):
1. Listen on `127.0.0.1` only, and reject any peer that is not loopback.
2. Every request needs a `Tailscale-User-Login` header whose value is in `AGENT_WEB_ALLOW`; otherwise 403.
   `tailscale serve` sets this header.
3. Every state-changing call is a `POST` with `Content-Type: application/json` (or the upload type) and
   `X-Agent-Web: 1`; otherwise 403. The custom header forces a browser preflight, which blocks cross-site
   requests.
4. A WebSocket upgrade needs an `Origin` whose host equals the `Host` header.
5. External commands run through `execFile` with an argument array, never a shell. Inputs are validated:
   - a session name must exist in the current list
   - a repo must match `^[A-Za-z0-9._-]+$` and be a git directory directly under `~/workspace` whose name does
     not end in `.wt`
   - a slug must match `^[a-z0-9][a-z0-9-]{0,40}$`
   - a harness must be one of `claude codex omp opencode shell`
6. Headers `Content-Security-Policy: default-src 'self'; connect-src 'self'; img-src 'self' data:` and
   `X-Frame-Options: DENY`. No directory listing.
7. Uploads are capped at 20 MB. Bodies and terminal data are never logged.

Known residual risk: a local process on the host can reach `127.0.0.1:7690` and forge the header. The host has
one user, and that user's agents can already run `agent`, so this grants nothing new. It is documented, not
mitigated.

**`agent ls --json`** (T1). A JSON array sorted like `ls`, one object per base session:
```json
{"name":"demo-x","harness":"claude","repo":"demo","branch":"agent/x","worktree":true,
 "cwd":"/home/u/workspace/demo.wt/x","state":"running","created":1793160000,
 "devices":["100.64.0.2","web"],"activity":1793167093,
 "attention":{"reason":"permission","source":"claude","since":1793167000}}
```
- `activity` is `#{window_activity}` of the harness window (`@hwin`).
- `attention` is `null` when unset.
- Build the output with `jq`, never by hand-quoting.
- `--porcelain` stays byte-for-byte unchanged.

**`agent attention`** (T1):
- `agent attention set [--reason R] [--source S] [<name>]` and `agent attention clear [<name>]`.
- Values live in tmux options on the base session: `@attention_reason`, `@attention_source`,
  `@attention_since`.
- Without `<name>`, the session is resolved from `$TMUX_PANE`, then a view name `x@n` is mapped to its base
  `x`.
- Always exits 0 and prints nothing when it cannot resolve a session, so a hook never breaks a harness.

**`AGENT_DEVICE`** (T1): when set, `device()` uses it instead of `SSH_CLIENT`. The server sets
`AGENT_DEVICE=web`.

**HTTP API** (T2, T4, T5, T8, T9, T10):

| Method and path | Owner | Result |
|---|---|---|
| `GET /api/health` | T2 | `{"ok":true}`; also behind auth |
| `GET /api/me` | T2 | `{"login":...}` |
| `GET /api/sessions` | T4 | the `agent ls --json` array plus a server-side `attention` merge (T10) |
| `GET /api/repos` | T4 | `["agentic-framework", ...]`: git dirs directly under `~/workspace`, excluding `*.wt` |
| `POST /api/sessions` `{repo,harness,slug?}` | T4 | runs `agent new <repo> --harness H [--slug S] --no-attach`; returns `{"name":...}` or `{"error":...}` with 400 or 409 |
| `GET /api/sessions/:name/worktree` | T4 | `{"worktree":bool,"dirty":bool,"files":["M a.txt",...]}` (at most 50 lines of `git status --porcelain`) |
| `POST /api/sessions/:name/kill` `{force?,keepWorktree?}` | T4 | runs `agent kill`; returns `{"output":...}` |
| `WS /api/sessions/:name/term?cols=&rows=` | T5 | terminal stream |
| `POST /api/sessions/:name/upload` (raw body, `Content-Type` of the file, `X-File-Name`) | T8 | `{"path":...}` |
| `GET /api/sim` | T9 | `{"available":bool,"slots":[...sim status --json]}` |
| `POST /api/sessions/:name/seen` | T10 | runs `agent attention clear <name>` |
| `GET /api/push/key`, `POST /api/push/subscribe`, `POST /api/push/unsubscribe`, `POST /api/push/test` | T10 | Web Push |

**Terminal protocol** (T5):
- Binary frames carry raw terminal bytes in both directions.
- Text frames carry JSON control messages: `{"type":"resize","cols":N,"rows":N}` from the client;
  `{"type":"exit","code":N}` from the server just before it closes.
- The server runs `python3 web/pty-bridge.py --cols C --rows R -- agent attach <name>`. The bridge relays stdin
  to the pty and the pty to stdout, and reads `"<cols> <rows>\n"` lines on fd 3 to resize (TIOCSWINSZ, then
  SIGWINCH).
- Socket closed: the bridge gets SIGHUP and the tmux client goes, so `destroy-unattached` removes the view.
- Bridge exited: the socket closes with `exit`.

## 3. How the tasks are run

- **Integration branch:** `agent/web-dashboard`, made from `main`, with its own worktree at
  `~/workspace/agentic-framework.wt/web-dashboard`.
- **Task branches:** each task runs in its own worktree, `~/workspace/agentic-framework.wt/web-<id>`, on branch
  `agent/web-<id>` taken from the integration branch's current tip.
- **One commit per task:** imperative subject under 72 characters, a body saying why, and the attribution line.
  Squash the task's work into one commit before integrating.
- **Integrating:** the integrator rebases each finished task onto `agent/web-dashboard` (never merges main in)
  and resolves conflicts. It then reruns that task's verification, plus `bash tests/web-test.sh` and
  `bash tests/agent-test.sh`, and only then fast-forwards. Expect conflicts in `web/server.mjs` (route table:
  keep every line), `web/public/app.mjs`, `style.css` and `index.html` (keep both sides; each task owns its own
  section, marked `// --- <task> ---`).
- **Recorded in each commit body:** the test counts and anything unverified.
- **Every task agent follows:** `AGENTS.md` and the house rules. No sudo; never touch tailscale, sshd or
  `~/.clip` contents; tests run on their own tmux socket and throwaway HOME, never the live server.

**Waves** (tasks in one wave run in parallel):

| Wave | Tasks |
|---|---|
| 1 | T1 agent CLI, T2 server skeleton, T3 pty bridge |
| 2 | T4 sessions API, T5 terminal WS, T11 harness hooks |
| 3 | T6 desktop UI and e2e harness |
| 4 | T7 phone UX, T8 paste and upload, T9 sim panel |
| 5 | T10 attention and push |
| 6 | T12 install and service |
| 7 | T13 end-to-end verification |

## 4. Tasks

### T1. `agent ls --json`, `agent attention`, `AGENT_DEVICE`
- **Depends on:** none. **Files:** `bin/agent`, `tests/agent-test.sh`, `AGENTS.md` (layout row for
  `bin/agent`).
- **Outcome:** the JSON listing, the attention subcommand and the device override exactly as in section 2,
  with the usage text and header comment updated.
- **Details:**
  - Extend `rows()` (or add a JSON sibling) to also read `#{@attention_reason}`, `#{@attention_source}`,
    `#{@attention_since}`, and the harness window's `#{window_activity}` (via
    `list-windows -a -F '#{window_id}|#{window_activity}'`, keyed by `@hwin`).
  - Paths still come last in the tmux format.
  - Devices split on `,` into an array; `-` becomes `[]`.
  - `attention` with neither `set` nor `clear` prints usage and exits 2.
  - `agent attention set|clear` exits 0 silently outside tmux or for an unknown session.
- **Verification:**
  1. `bash tests/agent-test.sh` passes with new cases:
     - `ls --json` with no sessions prints `[]`
     - with two sessions (one in a worktree, one exited) it is valid JSON (`jq -e 'length==2'`) and its fields
       equal the `--porcelain` columns for the same sessions
     - a branch or cwd containing `"` and `\` round-trips through `jq -r`
     - `activity` is an integer within 5 s of now after typing into the pane
     - `attention set --reason permission --source claude demo` makes `.attention.reason=="permission"`, and
       `clear` makes it `null`
     - `set` run inside the session's pane with no name (`tm send-keys` a command that runs
       `agent attention set --source test`) marks the base, also when run from a view `demo@1`
     - outside tmux with no name: exit 0, no output
     - `AGENT_DEVICE=web agent attach` records `@device` `web`
     - `--porcelain` output is unchanged against a recorded expectation
  2. `bash -n bin/agent`, `shellcheck -x bin/agent`.
- **Commit:** `Add agent ls --json, agent attention and AGENT_DEVICE`.

### T2. Server skeleton, auth and static files
- **Depends on:** none. **Files:** `web/package.json`, `web/package-lock.json`, `web/server.mjs`,
  `web/lib/auth.mjs`, `web/lib/static.mjs`, `web/public/index.html` (placeholder), `tests/web-test.sh`,
  `tests/web/helpers.mjs`, `tests/web/auth.test.mjs`, `.gitignore` (`web/node_modules/`).
- **Outcome:**
  - `node web/server.mjs` listens on `127.0.0.1:$AGENT_WEB_PORT`.
  - It enforces security rules 1 to 4, 6 and 7 from section 2.
  - It serves `web/public/` and exactly these vendor files: `/vendor/xterm.mjs`, `/vendor/xterm.css`,
    `/vendor/addon-fit.mjs`, `/vendor/addon-clipboard.mjs`.
  - It answers `/api/health` and `/api/me`.
  - It logs one line per request (method, path, status, ms) to stdout.
  - It refuses to start, exit 2 with a message, when `AGENT_WEB_ALLOW` is empty.
  - It exits cleanly on SIGTERM.
- **Details:**
  - Route table in `server.mjs`, one line per route: `[method, pattern, handler]`. Later tasks add lines.
  - `tests/web-test.sh` does `npm ci --ignore-scripts --prefix web` when `web/node_modules` is missing or older
    than the lockfile, then `node --test tests/web/` (a pattern argument filters files), and prints
    `N passed, 0 failed`.
  - `helpers.mjs` provides:
    - `startServer(env)`: a free port, waits for listen, returns `{url, stop}`
    - `req(path, {login, method, headers, body})`: adds `Tailscale-User-Login` unless `login:null`
    - a throwaway HOME with `~/workspace/demo` (a git repo with one commit) and a stand-in harness on PATH,
      mirroring `tests/agent-test.sh`
    - `AGENT_TMUX_SOCKET=aw-test-<pid>` and a cleanup that kills that server
- **Verification:** `bash tests/web-test.sh` passes, covering:
  - no login header → 403
  - wrong login → 403
  - allowed login → 200 on `/api/health`, and `/api/me` returns the login
  - empty `AGENT_WEB_ALLOW` → exit 2
  - a POST without `X-Agent-Web` → 403
  - a POST with a non-JSON type → 403
  - a WS upgrade with a mismatched `Origin` → rejected (on a stub `/api/echo` WS route defined only in tests
    through an exported `addRoute`)
  - CSP and frame headers present
  - `/vendor/xterm.mjs` → 200 `text/javascript`
  - `/../package.json` and `/vendor/../../server.mjs` → 404
  - the listen address is `127.0.0.1` (from `server.address()`)
  - SIGTERM → exit 0 within 2 s
- **Commit:** `Add the web dashboard server skeleton with tailnet auth`.

### T3. pty bridge
- **Depends on:** none. **Files:** `web/pty-bridge.py`, `tests/web/pty-bridge.test.mjs`.
- **Outcome:** `python3 web/pty-bridge.py --cols C --rows R -- <cmd...>` runs `<cmd>` on a fresh pty of that
  size as session leader with `TERM=xterm-256color`.
  - It copies stdin to the pty and the pty to stdout, unbuffered.
  - It resizes on each `"<cols> <rows>\n"` line read from fd 3 (if fd 3 is open).
  - On stdin EOF, SIGTERM or SIGHUP it sends SIGHUP to the child's process group and waits up to 2 s before
    SIGKILL.
  - It exits with the child's exit status (128+signal when the child was killed by a signal).
- **Details:** standard library only (`pty`, `os`, `select`, `fcntl`, `termios`, `struct`, `signal`), Python
  3.10+, `#!/usr/bin/env python3`, a header comment in the repo's style.
- **Verification:**
  1. `python3 -m py_compile web/pty-bridge.py`.
  2. `bash tests/web-test.sh pty-bridge` passes, covering:
     - `-- sh -c 'stty size'` with `--cols 91 --rows 33` prints `33 91`
     - echo round trip: write `echo hi\n` to `sh` and read `hi`
     - a resize via fd 3 followed by `stty size` reflects the new size
     - `-- sh -c 'exit 7'` exits 7
     - closing stdin of a `sleep 100` child ends the bridge in under 3 s with no `sleep` left (`pgrep -f` of a
       unique marker)
     - SIGTERM to the bridge does the same
     - 1 MB of output (`head -c 1000000 /dev/zero | od`) arrives complete
- **Commit:** `Add a stdlib pty bridge for the web terminal`.

### T4. Sessions API
- **Depends on:** T1, T2. **Files:** `web/lib/agent.mjs`, `web/lib/sessions.mjs`, `web/server.mjs` (routes),
  `tests/web/sessions.test.mjs`.
- **Outcome:** the five session and repo routes in section 2.
- **Details:**
  - `agent.mjs` resolves the `agent` binary from `$AGENT_BIN`, otherwise the repo's `bin/agent` (resolved
    relative to `server.mjs`, so the tests use the working tree).
  - It runs `execFile` with a 15 s timeout and maps failures:
    - `agent` exit 2 → 400 with stderr's last line
    - "no such session" → 404
    - "no such repo" → 400
    - anything else → 500
  - Session-name routes first check the name against the current `agent ls --json` and return 404 otherwise.
  - `worktree` runs `git -C <cwd> status --porcelain` only when `worktree` is true.
  - `kill`:
    - `{force:true}` → `agent kill <name> --force`
    - `{keepWorktree:true}` → `--keep-worktree`
    - neither → plain (with no tty, a dirty worktree is kept; see `confirm_dirty`)
- **Verification:** `bash tests/web-test.sh sessions` passes against a real tmux on the test socket:
  - an empty list → `[]`
  - `POST /api/sessions {repo:"demo",harness:"shell"}` → 200 with a name, and the session appears in the list
  - with `slug:"x"`: the worktree `demo.wt/x` exists and branch `agent/x` exists
  - repo `../etc` → 400
  - harness `bash` → 400
  - slug `X Y` → 400
  - a missing repo → 400
  - `/api/repos` lists `demo` and not `demo.wt`
  - the worktree route reports `dirty:false`, and after touching a file `dirty:true` with that file
  - kill without force on a dirty worktree removes the session and keeps the directory; with `force` both go
  - unknown name → 404
  - names containing `;` or `$(...)` never execute (a marker file must not appear)
- **Commit:** `Add session list, create and kill endpoints to the web server`.

### T5. Terminal WebSocket
- **Depends on:** T1, T2, T3. **Files:** `web/lib/term.mjs`, `web/server.mjs` (upgrade route),
  `tests/web/term.test.mjs`.
- **Outcome:** the terminal protocol in section 2.
- **Details:**
  - `cols` and `rows` are clamped to 20–500 and 5–200; resize messages are clamped the same way.
  - Environment for the bridge: the server's environment plus `AGENT_DEVICE=web` and `TERM=xterm-256color`,
    with `TMUX` and `SSH_CLIENT` removed.
  - A WS ping every 25 s; a missed pong closes the socket.
  - Backpressure: pause reading the bridge's stdout while `ws.bufferedAmount` is over 1 MB.
  - At most 16 terminals at once (503 beyond that).
  - On server SIGTERM, every bridge gets SIGHUP.
- **Verification:** `bash tests/web-test.sh term` passes with real tmux (test socket) and a `shell` session:
  - connect, send `echo marker-$RANDOM\r`, receive the marker
  - while connected, `tmux list-sessions` shows `<name>@1` with `@device` `web`
  - a second socket opens `<name>@2`, and input typed in one appears in the other
  - resize to 120x40 → `tmux display -p -t <name>@1 '#{client_width}x#{client_height}'` is `120x40`
  - closing the socket → the view is gone within 2 s and the base remains
  - `exit` typed into a shell session → the client gets `{"type":"exit"}`, then a close (the view goes; the
    base stays as `exited` because of remain-on-exit)
  - unknown name → close before any data
  - bad `Origin` → refused
  - no bridge processes remain after the tests (check with `pgrep -f pty-bridge.py` plus the test marker)
- **Commit:** `Add the terminal WebSocket bridging xterm.js to agent attach`.

### T6. Desktop UI and the browser e2e harness
- **Depends on:** T4, T5. **Files:** `web/public/index.html`, `app.mjs`, `style.css`;
  `tests/e2e/Dockerfile.web`, `tests/e2e/web.sh`, `tests/e2e/web/playwright.config.mjs`,
  `tests/e2e/web/sessions.spec.mjs`; `AGENTS.md` (layout and verification rows for `web/` and the two new
  suites).
- **Outcome:** one page with hash routes, no framework, ES modules:
  - **`#/` (session list).** Rows or cards with:
    - a state dot, the name, a harness chip, repo, branch, a worktree mark, age, devices and an attention badge
      placeholder (`data-attention`, filled by T10)
    - a 3 s poll of `/api/sessions`
    - an empty state
    - a New button opening a dialog: repo select from `/api/repos`, harness select (default `claude`), optional
      slug. Create, then navigate to `#/s/<name>`
    - a Kill action per row that fetches `/worktree` and offers:
      - clean or no worktree: "Kill"
      - dirty: "Kill, keep worktree" or "Kill and discard changes" (force), listing the files
  - **`#/s/<name>` (terminal).** Full viewport with xterm.js, the fit and clipboard addons, a top bar (back,
    name, state, Kill), automatic resize, and a reconnect banner with retry when the socket drops (not after
    `exit`). The tab title is the session name.
  - Light and dark themes (`prefers-color-scheme`); the terminal uses a dark theme in both.
- **e2e harness:**
  - `Dockerfile.web`: the pinned Playwright image plus `tmux git python3 jq zsh`. The repo is copied in;
    `npm ci` runs at image build.
  - `web.sh` builds the image, starts the server in the container (throwaway HOME, demo repo, stand-in
    harness, `AGENT_WEB_ALLOW=tester@example.test`), and runs `npx playwright test`.
  - Playwright sends `extraHTTPHeaders: {'Tailscale-User-Login':'tester@example.test'}`.
  - Projects: `desktop-chromium`, `desktop-webkit`; T7 adds the phone projects.
  - Prints `N passed, 0 failed`. `KEEP=1` keeps the container.
- **Verification:**
  1. `bash tests/web-test.sh`, all pass.
  2. `bash tests/e2e/web.sh` passes on both desktop projects:
     - the list shows the demo session created by the fixture
     - New with a `shell` harness lands on the terminal; typing `echo e2e-ok` shows `e2e-ok` in the xterm buffer
       (read via `page.evaluate` of `term.buffer.active`, exposed as `window.__term` only when `?test=1`)
     - Back shows the session in the list with devices `web` while the tab stays open
     - restarting the server mid-session shows the reconnect banner, and the terminal works again after
       reconnect
     - the kill dialog for a dirty worktree shows the file and the two options; "keep" leaves the directory
     - a missing login header gives the 403 page
  3. A manual screenshot pass at 1440x900 and 1024x768 (Playwright `screenshot`), attached to the commit body as
     file paths in the scratchpad.
- **Commit:** `Add the dashboard page and a Playwright e2e suite`.

### T7. Phone UX and installable app
- **Depends on:** T6. **Files:** `web/public/*` (a `// --- phone ---` section), `manifest.webmanifest`,
  `icons/` (192 and 512 PNG, generated from a simple SVG in the repo), `tests/e2e/web/phone.spec.mjs`, the
  config's phone projects.
- **Outcome:**
  - Under 700 px wide:
    - The list becomes single-column cards: name, age, state, attention.
    - The terminal shows a soft-key bar above the keyboard: `Esc Tab Ctrl ↑ ↓ ← → | / ~ Ctrl+C Ctrl+B`. Ctrl is
      sticky for the next key. Keys send the right byte sequences over the socket.
    - A "line" toggle opens a text box that sends its content plus `\r` on Enter, which works around iOS
      keyboard problems with xterm.js.
    - The font size can be adjusted (12 to 18 px, saved in localStorage inside try/catch).
  - The manifest and `<meta name="apple-mobile-web-app-capable">` make it installable, `display: standalone`.
  - The service worker `sw.js` is registered here with no caching of `/api/`; T10 adds push handling to it.
- **Verification:**
  1. `bash tests/e2e/web.sh` passes the `phone-iphone` (WebKit, iPhone 15 profile) and `phone-android`
     (Chromium, Pixel 7) projects:
     - no horizontal scroll at 390 px (`document.documentElement.scrollWidth <= innerWidth`)
     - soft keys: `Ctrl` then `c` interrupts `sleep 30` (the prompt returns)
     - `Esc` reaches the pane (check with `cat -v` showing `^[`)
     - arrows recall history
     - line mode sends `echo phone-ok` and the output shows
     - the manifest is valid JSON with icons that resolve to 200
     - the service worker registers (`navigator.serviceWorker.ready`)
  2. The desktop projects still pass.
- **Commit:** `Add phone soft keys, line input and an installable manifest`.

### T8. Image and file paste
- **Depends on:** T5, T6. **Files:** `web/lib/upload.mjs`, `web/server.mjs` (route), `web/public/*` (a
  `// --- paste ---` section), `tests/web/upload.test.mjs`, `tests/e2e/web/paste.spec.mjs`.
- **Outcome:**
  - `POST /api/sessions/:name/upload`:
    - `image/png` bodies are piped to `clip-put` (`$CLIP_PUT` or the repo's `bin/clip-put`, honouring
      `CLIP_BRIDGE_SPOOL`), which returns the printed path
    - other `image/*` types are rejected with 415 (the client converts to PNG first)
    - any other type is written to `$AGENT_WEB_FILES/<UTC stamp>-<random>-<sanitised name>` (mode 600,
      directory 700, no spaces), and files older than 24 h are pruned on each upload
    - over 20 MB → 413
  - In the terminal view:
    - Pasting an image (clipboard `items` of type `image/*`), dropping a file, or the paperclip button
      (`<input type=file>`, which also offers the camera on a phone) uploads it.
    - Non-PNG images are converted to PNG through `createImageBitmap` and a canvas.
    - The returned path plus a space is sent as terminal input.
    - Plain-text paste behaves as before.
- **Verification:**
  1. `bash tests/web-test.sh upload` passes:
     - the PNG magic bytes produce a path under the test spool, with identical content
     - a JPEG → 415
     - a text file lands in the test `AGENT_WEB_FILES` with mode 600 and a sanitised name (`a b/../c.txt` → no
       `/`, no space)
     - 21 MB → 413
     - an unknown session → 404
     - a missing `X-Agent-Web` → 403
  2. `bash tests/e2e/web.sh paste` passes:
     - a synthetic paste event with a PNG blob types `<spool>/<stamp>-*.png ` into the shell session (the path
       appears in the buffer and the file exists in the container)
     - a dropped `.txt` file does the same under the files spool
     - a JPEG drop arrives as `.png`
- **Commit:** `Add image and file paste to the web terminal`.

### T9. Sim panel
- **Depends on:** T2, T6. **Files:** `web/lib/sim.mjs`, `web/server.mjs` (route), `web/public/*` (a
  `// --- sim ---` section), `tests/web/sim.test.mjs`, `tests/e2e/web/sim.spec.mjs`,
  `tests/web/fixtures/sim-status.json`.
- **Outcome:**
  - `GET /api/sim` runs `sim status --json` (`$SIM_BIN` or `sim` on PATH, 10 s timeout):
    - `{available:false}` when the command is missing or fails
    - `{available:true, slots:[...]}` otherwise
  - The list page shows a collapsible "Devices" panel, polled every 10 s. It is grouped by platform; each slot
    shows device, state, lease holder (worktree basename from `lease`), idle time humanised, and tunnel ports.
  - The panel is hidden when the service is unavailable.
- **Verification:**
  1. `bash tests/web-test.sh sim` passes with a stub `sim` on PATH that prints the fixture (captured from the
     host on 28 Oct 2026: three Android and two web slots), a stub that exits 1, and no `sim` at all.
  2. `bash tests/e2e/web.sh sim` passes: the panel renders five slots in two groups with the stub, is hidden
     without it, and stays within width at 390 px.
- **Commit:** `Add a simulator panel to the dashboard`.

### T10. Needs-input detection and Web Push
- **Depends on:** T1, T6, T7. **Files:** `web/lib/attention.mjs`, `web/lib/push.mjs`, `web/server.mjs`,
  `web/public/*` (a `// --- alerts ---` section, push handling in `sw.js`), `tests/web/attention.test.mjs`,
  `tests/web/push.test.mjs`, `tests/e2e/web/alerts.spec.mjs`.
- **Outcome:**
  - **Watcher.** Every 2 s the server reads `agent ls --json` and computes each session's effective attention:
    - From a hook: the session's own `attention` object (set by T1 and T11).
    - Quiet heuristic, for harness `omp`, `opencode`, or `codex` when T11 recorded that Codex has no hook:
      - Raise `{reason:"quiet", source:"heuristic", since}` when the harness window was active within the last
        10 s at an earlier poll and has now been silent for 45 s or more (`AGENT_WEB_QUIET_SECS`).
      - Clear it when activity resumes.
      - Never for `shell`, and never for `exited` sessions.
    - From an exit: when the state goes from `running` to `exited`, raise `{reason:"exited", source:"tmux"}`.
    - `GET /api/sessions` returns the effective attention.
  - **Push:**
    - VAPID keys are generated on first start into `$AGENT_WEB_STATE/vapid.json` (600). The subject is the
      `Origin` of the first subscription (`https://...`).
    - Subscriptions live in `subscriptions.json` (600), deduplicated by endpoint, and are removed on a 404 or
      410 from the push service.
    - On a rising edge (null to set, or a new `since`) the server sends to every subscription
      `{"title":"<name> needs you","body":"<reason> · <harness>","url":"/#/s/<name>","tag":"<name>"}` with
      TTL 3600.
    - A push carries only the session name, reason and harness.
  - **Page:**
    - Cards with attention get a badge, and are sorted first.
    - The document title shows the count `(2) Agents`.
    - An "Enable alerts" button in the header subscribes (it only appears when `PushManager` exists; on iOS it
      explains that the page must be added to the home screen first).
    - A "Send test" button calls `/api/push/test`.
    - Opening a session's terminal calls `agent attention clear` for it, through
      `POST /api/sessions/:name/seen`, which this task adds.
  - **Service worker:**
    - It shows the notification unless a focused client is already on that session's URL.
    - A click focuses or opens `/#/s/<name>`.
- **Verification:**
  1. `bash tests/web-test.sh attention push` passes. The attention tests drive a fake clock and a stubbed
     `agent ls --json` sequence:
     - a hook attention passes through
     - quiet raises only after 45 s of silence that followed activity
     - a session that was always idle never raises
     - resumed activity clears
     - `running` to `exited` raises once
     - one rising edge produces exactly one push call
  2. In the push tests, a local HTTPS-less sink stands in for the push service:
     - `web-push`'s `sendNotification` receives that endpoint URL
     - the sink gets a POST with `Content-Encoding: aes128gcm`, a `TTL: 3600` header and an
       `Authorization: vapid ...` header
     - a 410 removes the subscription
     - the files have mode 600
  3. `bash tests/e2e/web.sh alerts` (Chromium only, permissions granted):
     - `agent attention set --reason permission --source claude <name>` run in the container makes the badge
       appear within 4 s and the title count 1
     - opening that session clears it
     - subscribing stores one subscription
     - `/api/push/test` reaches the sink
  4. Live check (in T13): a real push arrives on an iPhone home-screen app and on desktop Chrome.
- **Commit:** `Add needs-input detection and Web Push alerts`.

### T11. Harness hooks
- **Depends on:** T1. **Files:** `config/claude-settings.json`, `install-host.sh` (`codex` block, only if
  supported), `tests/params-test.sh` or `tests/agent-test.sh` (the hook commands), `AGENTS.md` (the
  claude-settings row).
- **Outcome:**
  - Claude Code hooks:
    - `Notification` → `agent attention set --source claude --reason permission`
    - `Stop` → `agent attention set --source claude --reason done`
    - `UserPromptSubmit` → `agent attention clear`
  - All use the absolute command `~/.local/bin/agent` written as `$HOME/.local/bin/agent`, with a 5 s timeout.
  - Codex:
    - Check `codex --help` and the installed version's config docs for `notify`.
    - If it exists, add
      `notify = ["<home>/.local/bin/agent", "attention", "set", "--source", "codex", "--reason", "done"]` to
      the codex block, built from `$HOME` at install time, never a literal.
    - Clearing for Codex is left to T10's "seen" call.
    - If `notify` is absent or its argument contract does not fit, change nothing, and record "Codex:
      heuristic" in the commit body and in a constant in `web/lib/attention.mjs` if T10 has already landed
      (otherwise T10 reads the constant's default `codex: "heuristic"`).
- **Known blocker:** in auto mode Claude Code may refuse writes to `config/claude-settings.json`. If it does,
  the task agent writes the patch to its scratchpad and stops for the operator to apply it.
- **Verification:**
  1. `python3 -m json.tool config/claude-settings.json` succeeds.
  2. A test asserts that the three hook events exist and that each command starts with
     `$HOME/.local/bin/agent attention`.
  3. In a tmux session on the test socket, running each hook command string (with `TMUX_PANE` set by tmux) sets
     and then clears `.attention` in `agent ls --json`.
  4. The commands are no-ops outside tmux (exit 0, no output).
  5. If Codex was changed: `bash tests/e2e/run.sh` (the install block renders, and a rerun is idempotent).
  6. Live (in T13): a real Claude Code permission prompt marks the session.
- **Commit:** `Mark sessions waiting for input from harness hooks`.

### T12. Install, service and docs rows
- **Depends on:** T2 to T11. **Files:** `config/systemd/agent-web.service`, `install-host.sh`,
  `tests/e2e/run.sh`, `tests/params-test.sh` (the literal scan covers `web/`), `AGENTS.md` (status table row
  "web dashboard", layout, verification list), `README.md` (install and verify block, plus the operator-only
  Tailscale steps).
- **Outcome:**
  - **Unit.** `Type=simple`:
    - `ExecStart=%h/.local/share/mise/shims/node %h/workspace/agentic-framework/web/server.mjs`, or the repo
      path through the same symlink convention the sim units use (mirror how `agent-sim-android@.service` finds
      the repo)
    - `EnvironmentFile=-%h/.config/agent-web/env`, `Environment=AGENT_DEVICE=web`, `Restart=on-failure`,
      `NoNewPrivileges=yes`, `PrivateTmp=yes`
  - **`install-host.sh`:**
    - Behind `--no-tools`: `npm ci --ignore-scripts --prefix "$REPO/web"` when the lockfile changed (stamp
      file).
    - Always: link the unit, `daemon-reload`, `enable --now agent-web.service` (same pattern and messages as the
      reap timer), create `~/.config/agent-web/` (700).
    - If `env` there is missing, print the exact line to add (`AGENT_WEB_ALLOW=<your tailnet login>`) rather
      than guessing it.
  - **README** operator steps, never scripted (AGENTS.md: tailscale is out of scope):
    `sudo tailscale set --operator=$USER` once, then `tailscale serve --bg 7690`, then open
    `https://<host>.<tailnet>.ts.net/`.
- **Verification:**
  1. `bash tests/e2e/run.sh`: in the host container the unit is linked, the systemctl shim log shows
     `enable --now agent-web.service`, `web/node_modules` exists after the first run and is not reinstalled on
     the second, and the run is idempotent.
  2. `bash tests/params-test.sh`: the literal scan is clean, including `web/` and the unit.
  3. `systemd-analyze --user verify config/systemd/agent-web.service` on the host.
  4. The full `AGENTS.md` verification list for the touched files.
- **Commit:** `Install the web dashboard as a user service`.

### T13. End-to-end verification (no code unless a defect is found)
- **Depends on:** all tasks.
- **Automated**, from the integration worktree, all green:
  ```
  bash tests/agent-test.sh
  bash tests/web-test.sh
  bash tests/params-test.sh
  bash tests/e2e/web.sh            # all projects: desktop-chromium, desktop-webkit, phone-iphone, phone-android
  bash tests/e2e/run.sh
  bash tests/e2e/tui.sh            # picker unaffected by web views and attention options
  bash tests/sim-test.sh
  shellcheck -x install-host.sh bin/agent && bash -n install-host.sh bin/agent && python3 -m py_compile web/pty-bridge.py
  ```
- **Journey spec** (`tests/e2e/web/journey.spec.mjs`, added here; the one code addition this task makes):
  1. Load the list.
  2. Create `demo` with slug `j` and harness `shell`.
  3. Type a command.
  4. Open a second tab on the same session and see shared output.
  5. Paste a PNG and see its path.
  6. Run `agent attention set` inside the pane and see the badge and a push at the sink.
  7. Open the session and see the badge clear.
  8. Check the sim panel with the stub.
  9. Make the worktree dirty and kill it with keep, then check the directory exists and the session is gone.
  10. Confirm that `agent ls` in the container agrees at every step.
- **Live on the host** (operator plus agent; first run the service from the worktree by hand on a spare port,
  so main's install is not touched before merge):
  1. The operator runs `sudo tailscale set --operator=$USER` once, then
     `tailscale serve --bg --https=8443 7691`, and the agent starts
     `AGENT_WEB_PORT=7691 AGENT_WEB_ALLOW=<login> node web/server.mjs` from the worktree.
  2. Identity:
     - From the Mac, `https://<host>.<tailnet>.ts.net:8443/api/me` returns the login.
     - `curl -H 'Tailscale-User-Login: x' http://<tailnet-ip>:7691/` from the Mac fails to connect (loopback
       only).
     - On the host, `curl localhost:7691/api/health` with no header returns 403.
     - Check whether `tailscale serve` overwrites a client-sent `Tailscale-User-Login` (send a forged one from
       the Mac and see that `/api/me` shows the real login). Record the result.
  3. The WebSocket works through serve: open a Claude session in Mac Chrome and Safari, type, resize the window,
     and see tmux follow.
  4. The same session is open in WezTerm at the same time. Both work, and the picker shows device `web`.
  5. iPhone Safari:
     - add to home screen
     - open a session, use soft keys and line mode
     - paste a screenshot from Photos via the paperclip; Claude Code attaches it
     - enable alerts
     - trigger a Claude permission prompt, then lock the phone; the notification arrives, and tapping it opens
       that session
  6. Kill a dirty worktree session from the phone with keep; the directory remains.
  7. Stop the server: the browser shows the reconnect banner, and nothing is left in `tmux ls` except base
     sessions.
- **Report:** test counts per suite, the live checklist with pass or fail, anything unverified (e.g. Android
  phone), and the result for header forging. Then hand back to the operator. Merging `agent/web-dashboard` to
  `main`, rerunning `install-host.sh` from the main checkout, and moving `tailscale serve` to the service's
  port 7690 happen only when the operator asks.

## 5. Notes for task agents
- **tmux:** the test socket only (`AGENT_TMUX_SOCKET`). Never `tmux kill-server` without `-L`.
- **Workspace:** a throwaway HOME for anything that runs `agent new`. Never create sessions in the operator's
  real `~/workspace` from tests.
- **Shell scripts:** follow AGENTS.md (`set -euo pipefail`, `bash -n`, `shellcheck`, header comments with path
  and install target).
- **Node code:** ES modules, Node 20+ APIs only (the host has 24), no TypeScript, no bundler. Keep comments to
  the repo's density: say why, not what.
- **Package changes:** a new dependency, or a version change, needs the integrator's approval. Pin exactly and
  commit the lockfile.
