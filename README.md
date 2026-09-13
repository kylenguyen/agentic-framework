# agentic-framework

Source of truth for `as1`, a headless Ubuntu box on a Tailscale tailnet that runs coding agents
(Claude Code, OpenCode, Oh My Pi), and for the Macs that reach it from WezTerm over SSH or mosh.
Scripts, configs and docs for both sides live here; nothing is configured by hand on either machine.

## Start here

| You want to | Read |
|---|---|
| Build as1 and a Mac from nothing, in order | [docs/setup-from-scratch.md](docs/setup-from-scratch.md) |
| Set up or verify a Mac, step by step, with rollback | [docs/mac-client-setup.md](docs/mac-client-setup.md) |
| Understand the design, per-phase tests, and what is still planned | [docs/remote-agent-host-plan.md](docs/remote-agent-host-plan.md) |
| Change something in this repo (human or agent) | [AGENTS.md](AGENTS.md): status table, layout, install contract, boundaries |

## The three scripts

| Script | Runs on | As | Does |
|---|---|---|---|
| `install-as1-root.sh` | as1 | root, by a human | sshd hardening, ufw, apt packages, zsh as login shell, linger, Tailscale auto-update |
| `install-as1.sh` | as1 | `kyle` | symlinks configs, secrets file skeleton, `xclip` shim, and with network: oh-my-zsh, mise toolchains, uv, the three harnesses |
| `install-mac.sh` | Mac | you, no sudo | mosh, pngpaste, `~/.ssh/config` block, SSH key, WezTerm include, `clip-push` |

All three are idempotent. Configs on as1 are symlinks into this checkout, so edit here, never the installed copy.

## Status

Phases 1 to 4 (access, sessions, harnesses, clipboard bridge) are scripted and in use. Phases 5 and 6
(automation, sandbox) are designed in the plan and not yet built. The table in `AGENTS.md` is authoritative.
