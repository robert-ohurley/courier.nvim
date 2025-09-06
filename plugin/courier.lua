if vim.g.loaded_courier then return end
vim.g.loaded_courier = true

local group = vim.api.nvim_create_augroup("CourierAuto", { clear = true })

vim.api.nvim_create_user_command("CourierStart", function(opts)
  require("courier.remote").set_ssh(opts.args)
end, { nargs = 1 })

vim.api.nvim_create_user_command("CourierStop", function()
  require("courier.remote").disable()
end, {})

vim.api.nvim_create_user_command("CourierPush", function()
  require("courier.remote").push_current()
end, {})

vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  callback = function(ev)
    require("courier.remote").on_buf_write_post(ev)
  end,
})
