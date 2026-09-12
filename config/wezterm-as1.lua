-- WezTerm: as1 SSH domain. Copy to ~/.config/wezterm/wezterm-as1.lua and in wezterm.lua add:
--   require("wezterm-as1").apply(config)
-- before `return config`.
local wezterm = require("wezterm")
local M = {}

function M.apply(config)
  config.ssh_domains = config.ssh_domains or {}
  table.insert(config.ssh_domains, {
    name = "as1",
    remote_address = "as1",   -- MagicDNS; ~/.ssh/config Host as1 supplies user and key
    username = "kyle",
    multiplexing = "None",    -- plain ssh; tmux on as1 does the multiplexing
  })
  -- tmux on as1 advertises tmux-256color; xterm-256color is what the remote terminfo has.
  config.term = "xterm-256color"
  -- OSC 52 clipboard writes are on by default in WezTerm; tmux set-clipboard on passes them through.
  config.keys = config.keys or {}
  table.insert(config.keys, {
    key = "a", mods = "CMD|SHIFT",
    action = wezterm.action.SpawnCommandInNewTab { domain = { DomainName = "as1" } },
  })
  return config
end

return M
