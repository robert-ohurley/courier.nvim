# courier.nvim

> ✉️ Work locally, sync remotely.

**courier.nvim** lets you edit files locally in Neovim and push the saved file to a matching path on a remote machine over SSH.

---

## But why? 🤔 

You could already keep local and remote files in sync with tools like **rsync**. So why even bother making this? I'm just listing what was important for me and why something like rsync wasn't the right tool for me due to my own shortcomings. 

**With `courier.nvim`:**
- 📝 The priority for me was keeping my normal workflow: open/edit/save files in Neovim.  
- ⚡ Immediate feedback: every save triggers a targeted push of *just that file*.  
- 🧠 Smart path resolution: it auto-detects where your file belongs on the remote, using cached directory indexes.  
- 🛡️ Granularity: optional confirmation prompt so you don’t overwrite a file if you don't want.  
- 🪶 Lightweight: No extra processes or external watch loops.

**With `rsync`:**
- ✅ Obviously great for bulk syncs (whole project trees).  
- ✅ Extremely efficient for many-file transfers.  
- ❌ Requires manual commands and/or background watcher (`fswatch`, `entr`, `lsyncd`).  
- ❌ Doesn’t integrate into the editor — I.e. I can forget to run it (and I would ALWAYS forget).  
- ❌ Sometimes I only care about “the file I just saved.”

**Trade-offs:**
- `courier.nvim` is great for the “edit a file and test it immediately on the remote” workflow.  
- `rsync` is better if you need continuous mirroring of entire directories, or if lots of files change outside of Neovim.  
- You could feasibly use both: `rsync` occasionally for bulk sync, and `courier.nvim` for individual file syncs. I'm not going to die on any hill over this. 

---

## ✨ Features

- `:CourierStart {ssh-string}` to enable syncing (e.g. `root@server`, or a host from `~/.ssh/config`).
- Add the path to where your project is on the remote in your config and courier will figure out the rest. 
- Push on save (`BufWritePost`) with optional confirmation.
- Finds the first common ancestor under configured remote roots.
- Configurable scp flags (e.g. `-p -C`).
- Caches a remote directory index for minimal SSH round-trips.
---
## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "robert-ohurley/courier.nvim",
  config = function()
    require("courier").setup({
      remote = {
        search_roots    = { "~", "/root" },
        confirm_on_save = true,            
        scp_opts        = "-p -C",          
        verbose         = false,          
      }
    })
  end,
}
```
## ⚙️ Options

All configuration is passed to `require("courier").setup({ remote = { … } })`.  
Here are the available fields:

| Key               | Type     | Default Value    | Description                                                                 |
|-------------------|----------|-----------|-----------------------------------------------------------------------------|
| `ssh`             | string   | `nil`     | The SSH connection string. Examples: `user@host`, `root@1.2.3.4 -p 2222`, or a host alias from `~/.ssh/config`. |
| `search_roots`    | string[] | `{ "~" }`  | List of parent directories on the remote to search for your project. Use the **parent** of the project dir (e.g. `"/root"`, not `"/root/app"`). |
| `confirm_on_save` | boolean  | `true`    | If `true`, prompt before overwriting the remote file on save.|
| `scp_opts`        | string   | `"-p"`    | Flags passed to `scp`. Default preserves timestamps and permissions.|
| `verbose`         | boolean  | `true`    | If `true`, logs info/debug messages to `:messages` (scp commands, path resolution, index building). |
