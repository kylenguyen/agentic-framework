-- tests/e2e/wezterm-paste.lua: drive the rendered WezTerm module (~/.config/wezterm/wezterm-agent-host.lua) under plain
-- Lua 5.4 with a stub `wezterm` table, so the Cmd+V decision runs exactly as WezTerm would run it, against the real
-- clip-push and the real host. Everything WezTerm would do is printed as one line per event for the shell to check:
--   action PasteFrom Clipboard        the pane got an ordinary paste
--   paste <text>                      pane:paste(text): the path clip-put printed, pasted as one bracketed paste
--   action SendKey ...                a key was sent (nothing does this any more; printed so a regression shows)
--   toast <title>: <message>          a notification, nothing sent
--   domain / key / term / scheme      what apply() put into the config (scenario "apply")
-- Usage: lua5.4 tests/e2e/wezterm-paste.lua <scenario>
--   apply                 print the ssh domain and key bindings apply() adds
--   local  [proc]         a local pane whose foreground process is <proc> (default zsh)
--   domain                a pane in the host's SSH domain
-- CLIP_PUSH_HOST in the environment reaches clip-push unchanged, so an unreachable alias exercises the failure path.
local HOME = os.getenv("HOME")
local scenario, proc = arg[1], arg[2] or "zsh"
if not scenario then io.stderr:write("usage: wezterm-paste.lua apply | local [proc] | domain\n"); os.exit(2) end

-- Stub of the parts of the wezterm module the agent-host module touches. Actions are plain tables so the shell can
-- read them; run_child_process really runs the command, synchronously, and returns (success, stdout, stderr) like
-- WezTerm does.
local function shq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local wezterm = { home_dir = HOME }
wezterm.action = setmetatable({}, { __index = function(_, name) return function(a) return { name = name, arg = a } end end })
wezterm.action_callback = function(fn) return { name = "callback", fn = fn } end
wezterm.config_builder = function() return {} end
wezterm.run_child_process = function(args)
  local parts = {}
  for i, a in ipairs(args) do parts[i] = shq(a) end
  local out, err = os.tmpname(), os.tmpname()
  local ok = os.execute(table.concat(parts, " ") .. " >" .. shq(out) .. " 2>" .. shq(err))
  local function slurp(p) local f = io.open(p, "r"); local s = f and f:read("a") or ""; if f then f:close() end; os.remove(p); return s end
  return ok == true, slurp(out), slurp(err)
end
package.preload["wezterm"] = function() return wezterm end
package.path = HOME .. "/.config/wezterm/?.lua;" .. package.path

local mod = require("wezterm-agent-host")
local config = mod.apply({ color_scheme = "Preset" })   -- a scheme set before the require line must survive

local function describe(a)
  if a.name == "SendKey" then return "SendKey " .. tostring(a.arg.mods) .. " " .. tostring(a.arg.key) end
  if a.name == "SpawnCommandInNewTab" then return "SpawnCommandInNewTab " .. tostring(a.arg.domain and a.arg.domain.DomainName) end
  return a.name .. " " .. tostring(a.arg)
end

if scenario == "apply" then
  for _, d in ipairs(config.ssh_domains) do
    print(("domain %s %s %s %s"):format(d.name, d.remote_address, d.username, d.multiplexing))
  end
  for _, k in ipairs(config.keys) do
    print(("key %s %s %s"):format(k.mods, k.key, k.action.name == "callback" and "callback" or describe(k.action)))
  end
  print("term " .. tostring(config.term)); print("scheme " .. tostring(config.color_scheme))
  os.exit(0)
end

local paste
for _, k in ipairs(config.keys) do if k.key == "v" and k.mods == "CMD" then paste = k.action.fn end end
if not paste then io.stderr:write("no CMD+v binding in the module\n"); os.exit(1) end

local domain = config.ssh_domains[1].name
local pane = {
  get_domain_name = function() return scenario == "domain" and domain or "local" end,
  get_foreground_process_name = function() return scenario == "domain" and "/usr/bin/zsh" or "/usr/bin/" .. proc end,
  paste = function(_, text) print("paste " .. text) end,
}
local window = {
  perform_action = function(_, a) print("action " .. describe(a)) end,
  toast_notification = function(_, title, msg) print("toast " .. title .. ": " .. (msg:gsub("\n.*", ""))) end,
}
paste(window, pane)
