local function remote() return require("courier.remote") end

return {
  setup = function(opts) remote().setup(opts) end,
  remote = {
    set = function(conn) remote().set_ssh(conn) end,
    push = function(opts) remote().push_current(opts) end,
    disable = function() remote().disable() end,
    enabled = function() return remote().is_enabled() end,
  },
}
