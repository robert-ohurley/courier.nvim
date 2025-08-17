local M = {}

function M.setup(opts)
  pcall(function()
    require("courier.remote").setup(opts)
  end)
end

M.remote = {
  disable = function() require("courier.remote").disable() end,
  enabled = function() return require("courier.remote").is_enabled() end,
  push = function(opts) require("courier.remote").push_current(opts) end,
  set = function(conn) require("courier.remote").set_ssh(conn) end,
}

return M
