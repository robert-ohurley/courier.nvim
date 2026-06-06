local M = {}

local state = {
  ssh = nil,
  enabled = false,
  search_roots = { "~" },
  confirm_on_save = true,
  scp_opts = "-p",
  cache = {}, -- ancestor dir name -> resolved base path on remote
  verbose = false,
}

local function notify(msg)
  if state.verbose then vim.notify("[courier.nvim] " .. msg) end
end

local function sys(cmd, args)
  local res = vim.system(vim.list_extend({ cmd }, args), { text = true }):wait()
  return res.code == 0, res.stdout or ""
end

-- Probe candidate remote paths in priority order (ancestor outer L→R, root inner).
-- One SSH round-trip; first existing path wins and its base is cached.
-- "~" roots become "." (remote-home-relative), which both `[ -e ]` and scp accept.
local function resolve_remote_path(local_abs)
  local comps = vim.split(local_abs, "/", { trimempty = true })
  if #comps < 2 then return end

  for i = 1, #comps - 1 do
    local base = state.cache[comps[i]]
    if base then return base .. "/" .. table.concat(comps, "/", i + 1) end
  end

  local candidates, script = {}, {}
  for i = 1, #comps - 1 do
    local rest = table.concat(comps, "/", i + 1)
    for _, root in ipairs(state.search_roots) do
      local base = root:gsub("^~", ".") .. "/" .. comps[i]
      table.insert(candidates, { name = comps[i], base = base, full = base .. "/" .. rest })
      table.insert(script, ("[ -e %q ] && echo %d && exit 0"):format(base .. "/" .. rest, #candidates))
    end
  end
  table.insert(script, "exit 1")

  local quoted = "'" .. table.concat(script, "\n"):gsub("'", [['"'"']]) .. "'"
  local ok, out = sys("ssh", { state.ssh, "sh -c " .. quoted })
  local hit = ok and candidates[tonumber(vim.trim(out))]
  if hit then
    state.cache[hit.name] = hit.base
    return hit.full
  end
end

function M.setup(opts)
  local r = opts and opts.remote or {}
  for _, k in ipairs({ "search_roots", "confirm_on_save", "scp_opts", "verbose" }) do
    if r[k] ~= nil then state[k] = r[k] end
  end
  if r.search_roots then state.cache = {} end
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
    return notify("Remote not set. Use :CourierStart {conn-string}.")
  end

  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or not vim.loop.fs_stat(name) then
    return notify("No local file: " .. name)
  end

  local remote_abs = resolve_remote_path(name)
  if not remote_abs then
    return notify("Couldn't resolve remote path for: " .. name)
  end

  if state.confirm_on_save and not (opts and opts.force) then
    local prompt = ("Replace remote file?\nTarget: %s\nDest: %s:%s"):format(name, state.ssh, remote_abs)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then return end
  end

  local args = vim.split(state.scp_opts, "%s+", { trimempty = true })
  vim.list_extend(args, { name, state.ssh .. ":" .. remote_abs })
  notify(sys("scp", args) and ("Pushed → " .. state.ssh .. ":" .. remote_abs) or "scp failed")
end

function M.on_buf_write_post(ev)
  if M.is_enabled() and ev and ev.match ~= "" then M.push_current() end
end

return M
