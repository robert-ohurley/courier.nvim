local M = {}

local state = {
  ssh = nil,              -- e.g. "user@host" or "root@1.2.3.4 -p 2222" or an SSH config Host
  enabled = false,
  search_roots = { "~" }, -- remote roots to search for a common ancestor
  confirm_on_save = true,
  scp_opts = "-p",        -- preserve times/perm by default
  cache = {},             -- [ancestor_dirname] = remote_base_abs_path
  dir_index = nil,        -- remote directory index (built once; see build_remote_dir_index)
  verbose = true,
}

-- =============== helpers ===============
local function sh_single_quote(s)
  -- Wrap in single quotes for sh, escaping any internal single quotes.
  -- 'foo'bar' -> 'foo'"'"'bar'
  return "'" .. tostring(s):gsub("'", [['"'"']]) .. "'"
end

-- run a system command; returns ok, stdout, stderr
local function sys(cmd, args, input)
  if vim.system then
    local res = vim.system(vim.list_extend({ cmd }, args or {}), { text = true, stdin = input }):wait()
    local ok = (res.code or 1) == 0
    return ok, res.stdout or "", res.stderr or ""
  else
    local output = { stdout = {}, stderr = {} }
    local job_id = vim.fn.jobstart(vim.list_extend({ cmd }, args or {}), {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data) if data then output.stdout = data end end,
      on_stderr = function(_, data) if data then output.stderr = data end end,
    })
    if job_id <= 0 then return false, "", "failed to start job" end
    if input and input ~= "" then vim.fn.chansend(job_id, input) end
    vim.fn.chanclose(job_id, "stdin")
    local status = vim.fn.jobwait({ job_id })[1]
    local ok = status == 0
    return ok, table.concat(output.stdout, "\n"), table.concat(output.stderr, "\n")
  end
end

local function notify_info(msg)
  if state.verbose then vim.notify("[courier.nvim] " .. msg) end
end

local function path_components(abs_path)
  local comps = {}
  for part in abs_path:gmatch("[^/]+") do table.insert(comps, part) end
  return comps
end

local function expand_home(root)
  if root == "~" then return "$HOME" end
  return root:gsub("^~/", "$HOME/")
end





-- =============== remote indexing ===============

-- Build an index of immediate subdirectories for each search root on the remote.
-- Output format from remote: NUL-separated records of "name<TAB>abs".
local function build_remote_dir_index()
  print("[courier] building remote dir index…")
  print("[courier] search_roots = " .. vim.inspect(state.search_roots))

  local parts = { "set -u" }
  for _, root in ipairs(state.search_roots) do
    local R = expand_home(root)
    table.insert(parts, ([[
R=%s
if [ -d "$R" ]; then
  # List immediate subdirs. Use a POSIX-safe guard to detect no-match.
  set -- "$R"/*/
  case "$1" in
    *'*'*) set -- ;;  # no subdirs → glob didn't expand; clear the list
  esac

  for d in "$@"; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    # Print: name<TAB>abs<NUL>
    printf "%%s\t%%s\0" "$b" "${d%%/}"
  done
fi
]]):format(R))
  end

  -- Succeed even if no roots matched / no subdirs
  table.insert(parts, "exit 0")

  -- Join with newlines (avoid stray leading/trailing ';')
  local script = table.concat(parts, "\n")
  local remote_cmd = "sh -c " .. sh_single_quote(script)

  print("[courier] index cmd: ssh " .. tostring(state.ssh) .. " " .. remote_cmd)
  local ok, out, err = sys("ssh", { state.ssh, remote_cmd })
  print("[courier] index exit_ok=" .. tostring(ok))
  if (err or "") ~= "" then print("[courier] dir index stderr: " .. err) end
  if (out or "") ~= "" then
    local prev = out:gsub("[\r]", "")
    if #prev > 400 then prev = prev:sub(1, 400) .. " …(trunc)" end
    print("[courier] dir index stdout preview: " .. prev)
  end

  if not ok then
    print("[courier] dir index ssh failed; caching EMPTY index to avoid retries")
    return {}
  end

  local index = {}
  for rec in (out or ""):gmatch("([^%z]+)%z") do
    local name, abs = rec:match("^(.-)\t(.*)$")
    if name and abs then
      index[name] = index[name] or {}
      table.insert(index[name], abs)
    end
  end

  -- Preserve root priority
  if next(index) then
    local expanded = {}
    for i, r in ipairs(state.search_roots) do expanded[i] = expand_home(r) end
    local function rank(p)
      for i, R in ipairs(expanded) do if p:sub(1, #R) == R then return i end end
      return math.huge
    end
    for _, arr in pairs(index) do
      table.sort(arr, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a < b
      end)
    end
  end

  return index
end

local function ensure_dir_index()
  if not state.dir_index then
    state.dir_index = build_remote_dir_index()
  end
  return state.dir_index
end

-- Using the index, resolve <ancestor>/<remainder> by checking candidates in priority order.
local function resolve_remote_for_indexed(ancestor, remainder)
  print(string.format("resolve_remote_for(indexed): ancestor=%s remainder=%s", ancestor, remainder))
  local idx = ensure_dir_index()
  if not idx or not idx[ancestor] then
    print("  (index) no bases for ancestor=" .. ancestor)
    return nil
  end

  for _, base in ipairs(idx[ancestor]) do
    local full = base .. "/" .. remainder

    -- 🔎 New: log the candidate being tested
    print("  (index) probing candidate path: " .. full)

    -- Build test script
    local test_script = ([[test -e %q && printf "%%s\n" %q || true]]):format(full, full)
    local cmd = "sh -c " .. sh_single_quote(test_script)

    -- 🔎 New: log the actual ssh command
    print("  (index) ssh command: ssh " .. state.ssh .. " " .. cmd)

    local ok, out, err = sys("ssh", { state.ssh, cmd })
    if not ok and (err or "") ~= "" then
      print("  (index) ssh failed: " .. err)
    end
    if ok and out and out:find(full, 1, true) then
      print("  (index) ✓ exists: " .. full)
      state.cache[ancestor] = base
      return full
    else
      print("  (index) miss at base=" .. base)
    end
  end

  print("  (index) none of bases have " .. remainder)
  return nil
end















-- =============== path resolution ===============

-- Given a local absolute path, find the first local component that’s also a
-- directory name on remote such that appending the remaining tail exists remotely.
-- Search left→right to match “first common ancestor”.
local function resolve_remote_path(local_abs)
  print("resolve_remote_path: starting for " .. local_abs)

  local comps = path_components(local_abs)
  print("  split into " .. #comps .. " components: " .. table.concat(comps, " / "))

  if #comps == 0 then
    print("  no components → returning nil")
    return nil
  end

  for i = 1, #comps - 1 do
    local ancestor = comps[i]
    local remainder_tbl = vim.list_slice(comps, i + 1)
    local remainder = table.concat(remainder_tbl, "/")
    print(string.format("  try #%d: ancestor=%s remainder=%s", i, ancestor, remainder))

    -- Fast path: cache hit
    if state.cache[ancestor] then
      local full = state.cache[ancestor] .. "/" .. remainder
      print("    cache hit → " .. full)
      return full
    end

    local candidate = resolve_remote_for_indexed(ancestor, remainder)
    if candidate then
      print("    ✓ found → " .. candidate)
      return candidate
    else
      print("    ✗ no match at ancestor=" .. ancestor .. ", continue")
    end
  end

  print("  exhausted all components without finding a match → returning nil")
  return nil
end













-- =============== push ===============

-- split a space-delimited flag string into argv tokens
-- done to prevent passing arg as string in quotes
local function split_args(s)
  local t = {}
  for a in string.gmatch(s or "", "%S+") do table.insert(t, a) end
  return t
end

local function scp_push(local_abs, remote_abs)
  -- Build argv: scp <opts...> <local> <user@host:/abs/path>
  local args = split_args(state.scp_opts)     -- e.g. {"-p","-C"}
  table.insert(args, local_abs)
  table.insert(args, state.ssh .. ":" .. remote_abs)  -- NO extra quotes here

  -- Pretty-print for logs
  print(string.format("scp_push: scp %s %s %s",
    table.concat(split_args(state.scp_opts or ""), " "),
    local_abs,
    state.ssh .. ":" .. remote_abs
  ))

  local ok, _, err = sys("scp", args)
  if not ok then
    print("  ✗ scp failed: " .. (err or "unknown error"))
  end
  return ok, err
end













-- =============== public api ===============

function M.setup(opts)
  if not opts then return end
  local r = opts.remote or {}
  local roots_changed = false

  if r.search_roots and vim.inspect(r.search_roots) ~= vim.inspect(state.search_roots) then
    state.search_roots = r.search_roots
    roots_changed = true
  end
  if r.confirm_on_save ~= nil then state.confirm_on_save = r.confirm_on_save end
  if r.scp_opts then state.scp_opts = r.scp_opts end
  if r.verbose ~= nil then state.verbose = r.verbose end

  if roots_changed then
    state.cache = {}
    state.dir_index = nil
  end
end

function M.set_ssh(conn_str)
  state.ssh = vim.trim(conn_str or "")
  state.enabled = state.ssh ~= ""
  state.cache = {}
  state.dir_index = nil
  if state.enabled then
    vim.notify("[courier.nvim] Remote set to: " .. state.ssh)
  else
    vim.notify("[courier.nvim] Remote cleared")
  end
end

function M.disable()
  state.enabled = false
  vim.notify("[courier.nvim] Remote sync disabled")
end

function M.is_enabled()
  return state.enabled and state.ssh ~= nil and state.ssh ~= ""
end

function M.reindex()
  state.dir_index = nil
  ensure_dir_index()
  notify_info("Rebuilt remote directory index")
end

-- Push current buffer file
function M.push_current(opts)
  if not M.is_enabled() then
    vim.notify("[courier.nvim] Remote not set. Use :CourierStart {ssh-conn-string}.", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    vim.notify("[courier.nvim] Buffer has no name (unsaved).", vim.log.levels.WARN)
    return
  end
  if not vim.loop.fs_stat(name) then
    vim.notify("[courier.nvim] Local file not found: " .. name, vim.log.levels.WARN)
    return
  end

  local remote_abs = resolve_remote_path(name)
  if not remote_abs then
    vim.notify("[courier.nvim] Couldn’t resolve remote path for: " .. name, vim.log.levels.ERROR)
    return
  end

  local function do_push()
    local ok = scp_push(name, remote_abs)
    if ok then
      notify_info(("Pushed → %s:%s"):format(state.ssh, remote_abs))
    else
      vim.notify("[courier.nvim] scp failed (see :messages for prints)", vim.log.levels.ERROR)
    end
  end

  if state.confirm_on_save and not (opts and opts.force) then
    local prompt = ("Replace remote file?\nTarget: %s\nDest: %s:%s"):format(name, state.ssh, remote_abs)
    local choice = vim.fn.confirm(prompt, "&Yes\n&No", 2)
    if choice == 1 then do_push() end
  else
    do_push()
  end
end

-- Autocmd callback
function M.on_buf_write_post(ev)
  if not M.is_enabled() then return end
  if ev and ev.match and ev.match ~= "" then
    M.push_current()
  end
end

return M
