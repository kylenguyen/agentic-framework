# Two-layer AGENTS.md across all projects and harnesses

Applies the two-layer instruction model — host-wide house rules + per-repo guidance —
to every project under `~/workspace` and to all four harnesses: Claude Code, OpenCode,
Oh My Pi, and Codex.

## Goal

Two instruction layers, each delivered to every harness in its native scope:

1. **Host rules** — git discipline, boundaries, and working style that apply to every
   repo on this host. Delivered through each harness's *global* (user) scope.
2. **Repo rules** — architecture, conventions, and test commands specific to one
   repo. Delivered through each repo's own `AGENTS.md`.

Layer 1 sets a floor; layer 2 adds to it and never overrides it. The contract is
stated in the host file and composed by each harness as global-first, project-second.

## Design

One canonical source, symlinked into every harness's global scope:

```
agentic-framework/config/workspace/CLAUDE.md     (single source of truth, versioned)
        │  install-host.sh symlinks it to each harness's GLOBAL file:
        ├── ~/.claude/CLAUDE.md                  Claude Code: user memory
        ├── ~/.omp/agent/AGENTS.md               omp: native user file, priority 100
        ├── ~/.config/opencode/AGENTS.md         opencode: global rules
        └── ~/.codex/AGENTS.md                   Codex: global scope
```

Repo rules stay where they are: one `AGENTS.md` at each repo root.

There is **no** parent-directory walk involved. Host rules reach every harness through
its global file, which every harness reads unconditionally; repo rules reach every
harness through the project-root `AGENTS.md`. This avoids depending on each harness's
ancestor-walk behaviour, which differs per harness and is absent in Codex (Codex walks
down from the git root, never up).

Propagation is by **symlink, not `@import`**: `@path` imports are read by Claude Code
and omp but not by opencode v1 or Codex. Symlinks work uniformly in all four, stay
version-controlled, and reuse the existing `link` idempotency convention.

## Per-harness resolution

| Harness | Host rules (global) | Repo rules (project) | Note |
|---|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md` | repo `AGENTS.md` | User-scope `CLAUDE.md` does not count for the "CLAUDE.md above cwd" check, so it never suppresses the repo `AGENTS.md` |
| omp | `~/.omp/agent/AGENTS.md` | repo `AGENTS.md` | Native user file is discovery priority 100 |
| opencode v1 | `~/.config/opencode/AGENTS.md` | repo `AGENTS.md` | Nearest-match walk finds the repo file; the global file is read independently |
| opencode v2 | `~/.config/opencode/AGENTS.md` | repo `AGENTS.md` | Global + every project `AGENTS.md`; `CLAUDE.md` is not a fallback in v2 |
| Codex | `~/.codex/AGENTS.md` | repo `AGENTS.md` | Walks from git root down; global file is the only host-rule path |

## Codex configuration

Codex truncates its combined instruction chain at `project_doc_max_bytes`, default
32 KiB (32,768 B). The largest repo `AGENTS.md` exceeds this, so the cap must be
raised.

Raise it in `~/.codex/config.toml`:

```toml
project_doc_max_bytes = 131072   # 128 KiB; headroom over the largest repo AGENTS.md
```

`install-host.sh` writes this file when Codex is installed (or links a checked-in
template under `config/`). Revisit the value if a repo `AGENTS.md` grows past 128 KiB.

## Changes

All in the `agentic-framework` repo.

| File | Change |
|---|---|
| `config/workspace/CLAUDE.md` | Reword the "applies to every harness and every repo" line to be accurate; remove any self-reference to `~/workspace/AGENTS.md`. Optionally rename to `config/house-rules.md` (see Decisions) |
| `install-host.sh` | Replace the two `~/workspace/*` links with the four global links below; add `install -d` for the four directories; remove the retired workspace links |
| `tests/params-test.sh` | Literal scan and link assertions: expect the four global paths, assert the two workspace links are absent |
| `README.md` | Verify block and layout/parameters table: global link paths instead of `~/workspace/*` |
| `AGENTS.md` (this repo) | Layout-table row for `config/workspace/CLAUDE.md`; install-contract "symlinks not copies" paragraph |
| `docs/remote-agent-host-plan.md` | Section on shared agent context: global-scope links and a Codex row |

`install-host.sh` (phase 3, replacing the current two links):

```sh
# House rules: one canonical file, symlinked into each harness's global scope so
# every repo inherits it regardless of harness. Repo rules live in each repo's AGENTS.md.
install -d "$HOME/.claude" "$HOME/.config/opencode" "$HOME/.omp/agent" "$HOME/.codex"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/.config/opencode/AGENTS.md"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/.omp/agent/AGENTS.md"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/.codex/AGENTS.md"
# Retire the parent-directory links; -L guard so a real file is never removed.
[ -L "$HOME/workspace/CLAUDE.md" ] && rm -f "$HOME/workspace/CLAUDE.md" || true
[ -L "$HOME/workspace/AGENTS.md" ] && rm -f "$HOME/workspace/AGENTS.md" || true
```

Note: `~/.omp/agent` is the default native agent directory; `PI_CODING_AGENT_DIR`
relocates it. The install targets the default.

## Repo requirements

Every project under `~/workspace` (including future repos):

- Keep one `AGENTS.md` at the repo root.
- Do not add a repo-level `CLAUDE.md`; a repo `CLAUDE.md` above a subdirectory would
  suppress the repo `AGENTS.md` under Claude Code's default resolution.
- Repo rules add to host rules; they must not duplicate or contradict them.

## Apply steps

1. Edit `config/workspace/CLAUDE.md`, `install-host.sh`, `tests/params-test.sh`,
   `README.md`, `AGENTS.md`, `docs/remote-agent-host-plan.md` in one change.
2. `bash -n install-host.sh` and `shellcheck` where available.
3. `bash tests/params-test.sh` — green.
4. Run `./install-host.sh --no-tools --no-root` from `~/workspace/agentic-framework`
   (never from a worktree) to apply the links.
5. Run the per-harness smoke checks in Verification.

## Verification

Link assertions (after install):

```sh
readlink ~/.claude/CLAUDE.md            # .../agentic-framework/config/workspace/CLAUDE.md
readlink ~/.config/opencode/AGENTS.md   # same target
readlink ~/.omp/agent/AGENTS.md         # same target
readlink ~/.codex/AGENTS.md             # same target
readlink ~/workspace/CLAUDE.md          # fails — link removed
readlink ~/workspace/AGENTS.md          # fails — link removed
```

Per-harness smoke — each must report both the host file and the repo `AGENTS.md`:

```sh
# Claude Code
claude -p "List every instruction/memory file you have loaded."
# omp — trivial prompt inside a repo; /extensions lists ~/.omp/agent/AGENTS.md and <repo>/AGENTS.md
# opencode — run inside a repo; ask "list your instruction sources"
# Codex
codex --ask-for-approval never "Summarize the current instructions."   # global first, repo root second
```

`tests/params-test.sh` covers the symlink existence, target, and literal-scan
assertions; the per-harness smoke is manual (it needs the harnesses, which the unit
suite never invokes).

## Decisions

1. **Rename `config/workspace/CLAUDE.md` → `config/house-rules.md`.** The current
   path describes a scope the file no longer has. Recommended: rename; update the
   `link` calls, tests, and docs in the same change.
2. **`~/.claude/CLAUDE.md` is also where Claude personal preferences live.** Recommended:
   symlink it to the canonical file (matches "symlinks not copies"); add personal
   preferences to the canonical file itself if ever needed, rather than maintaining a
   separate unversioned file.
