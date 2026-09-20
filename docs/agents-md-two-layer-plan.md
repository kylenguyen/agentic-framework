# Proposal: house rules in every harness's global scope

Not applied. `install-host.sh` links `config/workspace/CLAUDE.md` to `~/workspace/CLAUDE.md`,
`~/workspace/AGENTS.md` and `~/.codex/AGENTS.md`; of this proposal only the `codex` block in `~/.codex/config.toml`
that raises `project_doc_max_bytes` is in place.

## Goal

Two instruction layers, each delivered to every harness (Claude Code, OpenCode, Oh My Pi, Codex) in its native
scope:

1. Host rules: git discipline, boundaries and working style for every repo on the host, delivered through each
   harness's global (user) scope.
2. Repo rules: architecture, conventions and test commands for one repo, delivered through that repo's `AGENTS.md`.

Layer 1 sets a floor; layer 2 adds to it and never overrides it. Each harness composes them global-first,
project-second.

## Design

One canonical file, symlinked into every harness's global scope:

```
agentic-framework/config/workspace/CLAUDE.md     (single source of truth, versioned)
        |  install-host.sh symlinks it to each harness's global file:
        +-- ~/.claude/CLAUDE.md                  Claude Code: user memory
        +-- ~/.omp/agent/AGENTS.md               Oh My Pi: native user file, priority 100
        +-- ~/.config/opencode/AGENTS.md         OpenCode: global rules
        +-- ~/.codex/AGENTS.md                   Codex: global scope
```

Repo rules stay where they are: one `AGENTS.md` at each repo root.

No parent-directory walk is involved. Host rules reach every harness through its global file, which every harness
reads unconditionally; repo rules reach it through the project-root `AGENTS.md`. This avoids depending on each
harness's ancestor-walk behaviour, which differs per harness and is absent in Codex (it walks down from the git
root, never up).

Propagation is by symlink, not `@import`: `@path` imports are read by Claude Code and Oh My Pi but not by OpenCode
v1 or Codex. Symlinks work in all four, stay version-controlled and reuse the `link` helper.

| Harness | Host rules (global) | Repo rules (project) | Note |
|---|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md` | repo `AGENTS.md` | the user-scope file does not count for the "CLAUDE.md above cwd" check, so it never suppresses the repo `AGENTS.md` |
| Oh My Pi | `~/.omp/agent/AGENTS.md` | repo `AGENTS.md` | native user file, discovery priority 100; `PI_CODING_AGENT_DIR` relocates the directory, the install targets the default |
| OpenCode v1 | `~/.config/opencode/AGENTS.md` | repo `AGENTS.md` | nearest-match walk finds the repo file; the global file is read independently |
| OpenCode v2 | `~/.config/opencode/AGENTS.md` | repo `AGENTS.md` | global plus every project `AGENTS.md`; `CLAUDE.md` is not a fallback in v2 |
| Codex | `~/.codex/AGENTS.md` | repo `AGENTS.md` | walks from the git root down; the global file is the only host-rule path |

Codex truncates its combined instruction chain at `project_doc_max_bytes`, default 32 KiB. The `codex` marker
block `install-host.sh` writes to `~/.codex/config.toml` raises it to 128 KiB; revisit if a repo `AGENTS.md` grows
past that.

## Changes

All in this repo, in one change:

| File | Change |
|---|---|
| `config/workspace/CLAUDE.md` | reword the scope line; remove any self-reference to `~/workspace/AGENTS.md`; optionally rename (see Decisions) |
| `install-host.sh` | replace the two `~/workspace/*` links with the four global links below, `install -d` for the four directories, remove the retired workspace links |
| `tests/params-test.sh` | expect the four global paths; assert the two workspace links are absent |
| `tests/e2e/run.sh` | the Codex link check becomes four |
| `README.md` | section 3 verify block: global link paths instead of `~/workspace/*` |
| `AGENTS.md` | layout row for `config/workspace/CLAUDE.md`; install-contract paragraph on symlinks |
| `docs/remote-agent-host-plan.md` | section 4 item 4: global-scope links |

`install-host.sh` phase 3, replacing the workspace links:

```sh
# House rules: one canonical file, symlinked into each harness's global scope so every repo inherits it
# regardless of harness. Repo rules live in each repo's AGENTS.md.
install -d "$HOME/.claude" "$HOME/.config/opencode" "$HOME/.omp/agent" "$HOME/.codex"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/.config/opencode/AGENTS.md"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/.omp/agent/AGENTS.md"
link "$REPO/config/workspace/CLAUDE.md" "$HOME/.codex/AGENTS.md"
# Retire the parent-directory links; -L guard so a real file is never removed.
[ -L "$HOME/workspace/CLAUDE.md" ] && rm -f "$HOME/workspace/CLAUDE.md" || true
[ -L "$HOME/workspace/AGENTS.md" ] && rm -f "$HOME/workspace/AGENTS.md" || true
```

Repo requirements, for every project under `~/workspace`: one `AGENTS.md` at the repo root; no repo-level
`CLAUDE.md`, since one above a subdirectory would suppress the repo `AGENTS.md` under Claude Code's default
resolution; repo rules add to host rules and never duplicate or contradict them.

## Verification

Link assertions after `./install-host.sh --no-tools --no-root` from `~/workspace/agentic-framework`:

```sh
readlink ~/.claude/CLAUDE.md            # .../agentic-framework/config/workspace/CLAUDE.md
readlink ~/.config/opencode/AGENTS.md   # same target
readlink ~/.omp/agent/AGENTS.md         # same target
readlink ~/.codex/AGENTS.md             # same target
readlink ~/workspace/CLAUDE.md          # fails: link removed
readlink ~/workspace/AGENTS.md          # fails: link removed
```

Per-harness smoke, manual since the unit suite never invokes a harness; each must report both the host file and
the repo `AGENTS.md`:

```sh
claude -p "List every instruction/memory file you have loaded."
# Oh My Pi: a trivial prompt inside a repo; /extensions lists ~/.omp/agent/AGENTS.md and <repo>/AGENTS.md
# OpenCode: run inside a repo; ask "list your instruction sources"
codex --ask-for-approval never "Summarize the current instructions."   # global first, repo root second
```

## Decisions (open)

1. Rename `config/workspace/CLAUDE.md` to `config/house-rules.md`: the current path describes a scope the file
   would no longer have. Recommended: rename, updating the `link` calls, tests and docs in the same change.
2. `~/.claude/CLAUDE.md` is also where Claude Code personal preferences live. Recommended: symlink it to the
   canonical file (symlinks, not copies) and add any personal preference to the canonical file rather than keeping
   a separate unversioned one.
