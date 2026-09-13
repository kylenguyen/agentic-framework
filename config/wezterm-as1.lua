-- WezTerm: as1 SSH domain and clipboard push. Copy to ~/.config/wezterm/wezterm-as1.lua and in wezterm.lua add:
--   require("wezterm-as1").apply(config)
-- before `return config`.
local wezterm = require("wezterm")
local M = {}

-- Cmd+V in a pane connected to as1 (the as1 SSH domain, or a local pane whose foreground process is ssh or
-- mosh-client). A pty carries text only, so an image cannot be pasted the normal way: clip-push --if-image ships
-- it over SSH into clip-put on as1 and reports the type; for an image we then send Ctrl+V, which is the key
-- Claude Code reads the clipboard on (it calls the xclip shim, which serves the pushed file). Text never
-- touches as1: it is pasted natively, so plain Cmd+V costs nothing. run_child_process is synchronous, so the
-- image is on as1 before Claude Code sees the key. Any other pane gets the ordinary paste.
local function paste_via_as1(window, pane)
  local paste_text = wezterm.action.PasteFrom("Clipboard")
  local proc = pane:get_foreground_process_name() or ""
  local base = proc:match("([^/]+)$") or ""
  local remote = pane:get_domain_name() == "as1" or base == "ssh" or base == "mosh-client"
  if not remote then
    window:perform_action(paste_text, pane)
    return
  end
  local called, ok, stdout, stderr =
    pcall(wezterm.run_child_process, { wezterm.home_dir .. "/.local/bin/clip-push", "--if-image" })
  local kind = called and (stdout or ""):match("^%S+") or ""
  if kind ~= "image/png" and (kind ~= "" or called and ok) then
    window:perform_action(paste_text, pane)   -- text: native bracketed paste, nothing was pushed
    return
  end
  if not called or not ok then
    -- Do not send Ctrl+V: Claude Code would paste whatever as1 still holds from last time.
    local why = called and (stderr or "") or tostring(ok)
    window:toast_notification("as1 clipboard", "clip-push failed: " .. why, nil, 5000)
    return
  end
  window:perform_action(wezterm.action.SendKey { key = "v", mods = "CTRL" }, pane)
end

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
  table.insert(config.keys, {
    key = "v", mods = "CMD",
    action = wezterm.action_callback(paste_via_as1),
  })
  return config
end

return M
