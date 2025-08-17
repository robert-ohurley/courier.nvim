# courier.nvim

Edit locally, deliver changes to a remote over SSH/SCP on save.

## Install (lazy.nvim)
```lua
{ dir = "~/dev/courier.nvim",
  config = function()
    require("courier").setup({
      remote = {
        search_roots = { "~", "~/dev", "/srv" },
        confirm_on_save = true,
        scp_opts = "-p",
        verbose = true,
      }
    })
  end
}

