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
| `install-mac.sh` | Mac | you, no sudo | mosh, pngpaste, `~/.ssh/config` block, SSH key, as1 host key and key login (asks for kyle's password once if needed), WezTerm include, `clip-push` |

All three are idempotent. Configs on as1 are symlinks into this checkout, so edit here, never the installed copy.

## Set up a Mac

One script, run in a terminal. as1 must already be up on the tailnet (parts A and D of
[docs/setup-from-scratch.md](docs/setup-from-scratch.md)); the Mac needs Homebrew, the Tailscale app signed in
to the same tailnet, and WezTerm.

```
mkdir -p ~/workspace && git clone https://github.com/kylenguyen/agentic-framework.git ~/workspace/agentic-framework
cd ~/workspace/agentic-framework && ./install-mac.sh
```

What it does, in order:

1. Installs mosh and pngpaste, writes the `as1`, `as1-lan` and `as1-clip` blocks into `~/.ssh/config`, and
   generates `~/.ssh/id_ed25519` if you have none.
2. Installs the WezTerm include (writes a minimal `wezterm.lua` if you have none, otherwise prints the one line to add).
3. Installs `clip-push` and puts `~/.local/bin` on PATH via a marker block in `~/.zshrc`.
4. Makes `ssh as1` keyless. On the first contact it stores as1's host key and prints the fingerprint. If as1
   already trusts another key of yours, it installs the repo key over it with no password. If as1 trusts no
   local key, it runs `ssh-copy-id` and asks for kyle's password on as1, once. It then re-tests and ends with
   `ok   ssh as1 logs in by key`.

The script exits 1 if step 4 could not finish, with the reason and the one command to run. The cases it will
not handle on its own, by design: as1 unreachable (check Tailscale), a stored host key that no longer matches
(you run `ssh-keygen -R as1` after a reinstall), and password login off on as1 with no trusted key (run the
root script on as1 first, or paste the key at the console). Re-run `./install-mac.sh` after fixing any of them;
every step is idempotent.

Then open a new shell, reload WezTerm (Cmd+Shift+R), and run the joint checkpoints in
[docs/mac-client-setup.md](docs/mac-client-setup.md).

## Status

Phases 1 to 4 (access, sessions, harnesses, clipboard bridge) are scripted and in use. Phases 5 and 6
(automation, sandbox) are designed in the plan and not yet built. The table in `AGENTS.md` is authoritative.
