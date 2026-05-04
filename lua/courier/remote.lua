local M = {}

local state = {
  ssh = nil,
  enabled = false,
  search_roots = { "~" },
  confirm_on_save = true,
  scp_opts = "-p",
  cache = {}, -- ancestor name -> resolved base abs path on remote
  verbose = false,
}

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'"
end

local function sys(cmd, args)
  local res = vim.system(vim.list_extend({ cmd }, args or {}), { text = true }):wait()
  return (res.code or 1) == 0, res.stdout or "", res.stderr or ""
end

local function notify(msg)
  if state.verbose then vim.notify("[courier.nvim] " .. msg) end
end

local function expand_home(root)
  if root == "~" then return "$HOME" end
  return (root:gsub("^~/", "$HOME/"))
end

local function path_components(abs)
  local comps = {}
  for part in abs:gmatch("[^/]+") do table.insert(comps, part) end
  return comps
end

local function split_args(s)
  local t = {}
  for a in (s or ""):gmatch("%S+") do table.insert(t, a) end
  return t
end

-- Probe candidate remote paths in priority order (ancestor outer L→R, root inner).
-- One SSH round-trip; first existing path wins.
local function resolve_remote_path(local_abs)
  local comps = path_components(local_abs)
  if #comps < 2 then return nil end

  for i = 1, #comps - 1 do
    local base = state.cache[comps[i]]
    if base then
      return base .. "/" .. table.concat(comps, "/", i + 1)
    end
  end

  local candidates = {}
  for i = 1, #comps - 1 do
    local ancestor = comps[i]
    local remainder = table.concat(comps, "/", i + 1)
    for _, root in ipairs(state.search_roots) do
      local base = expand_home(root) .. "/" .. ancestor
      table.insert(candidates, { ancestor = ancestor, base = base, full = base .. "/" .. remainder })
    end
  end

  local lines = {}
  for _, c in ipairs(candidates) do
    table.insert(lines, ([[[ -e %q ] && printf '%%s\n' %q && exit 0]]):format(c.full, c.full))
  end
  table.insert(lines, "exit 1")

  local ok, out = sys("ssh", { state.ssh, "sh -c " .. sh_quote(table.concat(lines, "\n")) })
  if not ok then return nil end
  local hit = vim.trim(out)
  if hit == "" then return nil end

  for _, c in ipairs(candidates) do
    if c.full == hit then
      state.cache[c.ancestor] = c.base
      return hit
    end
  end
end

local function scp_push(local_abs, remote_abs)
  local args = split_args(state.scp_opts)
  table.insert(args, local_abs)
  table.insert(args, state.ssh .. ":" .. remote_abs)
  return sys("scp", args)
end

function M.setup(opts)
  if not opts then return end
  local r = opts.remote or {}
  if r.search_roots and vim.inspect(r.search_roots) ~= vim.inspect(state.search_roots) then
    state.search_roots = r.search_roots
    state.cache = {}
  end
  if r.confirm_on_save ~= nil then state.confirm_on_save = r.confirm_on_save end
  if r.scp_opts then state.scp_opts = r.scp_opts end
  if r.verbose ~= nil then state.verbose = r.verbose end
end

function M.set_ssh(conn_str)
  state.ssh = vim.trim(conn_str or "")
  state.enabled = state.ssh ~= ""
  state.cache = {}
  notify(state.enabled and ("Remote set to: " .. state.ssh) or "Remote cleared")
end

function M.disable()
  state.enabled = false
  notify("Remote sync disabled")
end

function M.is_enabled()
  return state.enabled and state.ssh ~= nil and state.ssh ~= ""
end

function M.push_current(opts)
  if not M.is_enabled() then
    notify("Remote not set. Use :CourierStart {conn-string}.")
    return
  end

  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    notify("Buffer has no name (unsaved).")
    return
  end
  if not vim.loop.fs_stat(name) then
    notify("Local file not found: " .. name)
    return
  end

  local remote_abs = resolve_remote_path(name)
  if not remote_abs then
    notify("Couldn't resolve remote path for: " .. name)
    return
  end

  local function push()
    local ok = scp_push(name, remote_abs)
    notify(ok and ("Pushed → " .. state.ssh .. ":" .. remote_abs) or "scp failed")
  end

  if state.confirm_on_save and not (opts and opts.force) then
    local prompt = ("Replace remote file?\nTarget: %s\nDest: %s:%s"):format(name, state.ssh, remote_abs)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then push() end
  else
    push()
  end
end

function M.on_buf_write_post(ev)
  if M.is_enabled() and ev and ev.match and ev.match ~= "" then
    M.push_current()
  end
end

return M
