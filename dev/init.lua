-- Dev/test harness for say-my-name. NOT shipped plugin behavior.
-- Launched via:  NVIM_APPNAME=nvim-tcc nvim -u dev/init.lua
-- Loads the plugin from this working copy (latest, uncommitted edits included).
-- Leader and test keymaps live HERE, never in plugin/ or lua/ (would hijack users).

-- repo root = parent dir of this file (dev/../)
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Minimal LSP for testing diagnostics: lua_ls. Starts on any Lua buffer if the
-- binary is present; no-op otherwise. Install: LuaLS releases -> ~/.local/bin.
-- Registered BEFORE `filetype on` below: enabling filetype detection fires
-- FileType for the startup-arg buffer synchronously, so this must exist first.
if vim.fn.executable("lua-language-server") == 1 then
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "lua",
    callback = function(args)
      -- schedule: starting mid-startup (file passed as arg) doesn't attach.
      vim.schedule(function()
        vim.lsp.start({
          name = "lua_ls",
          cmd = { "lua-language-server" },
          root_dir = vim.fs.root(args.buf, { ".luarc.json", ".git" }) or vim.fn.getcwd(),
          settings = { Lua = { diagnostics = { globals = { "vim" } } } },
        })
      end)
    end,
  })
end

-- -u skips defaults.vim, so turn these on explicitly. syntax on is what the
-- comment-voice fallback (syntax highlight group) relies on when no treesitter
-- parser exists for the buffer's language.
vim.cmd("syntax on")
vim.cmd("filetype plugin indent on")

local smn = require("say-my-name")
smn.setup({ verbosity = "minimal" }) -- start quiet; commands only

-- manual commands (always work)
vim.keymap.set("n", "<leader>l", smn.line, { desc = "Speak current line" })
vim.keymap.set("n", "<leader>$", smn.line_to_end, { desc = "Speak cursor to end of line" })
vim.keymap.set("n", "<leader>w", smn.word, { desc = "Speak word under cursor" })
vim.keymap.set("n", "<leader>n", smn.line_number, { desc = "Speak line number" })
vim.keymap.set("n", "<leader>i", smn.indent, { desc = "Beep indentation depth" })
vim.keymap.set("n", "<leader>d", smn.diagnostics, { desc = "Speak line diagnostics" })
-- <Cmd> so it runs without leaving visual/select (mode() stays correct)
vim.keymap.set({ "n", "x", "s" }, "<leader>m", "<Cmd>lua require('say-my-name').mode()<CR>", { desc = "Speak current mode" })
vim.keymap.set("n", "<leader>y", smn.last_yank, { desc = "Speak last yank" })
vim.keymap.set("n", "<leader>s", smn.stop, { desc = "Stop speech (panic-silence)" })

-- verbosity preset: cycle (normal mode); speak selection (visual/select)
vim.keymap.set("n", "<leader>v", smn.cycle_verbosity, { desc = "Cycle verbosity preset" })
-- <Cmd> so it runs without leaving visual (selection stays valid)
vim.keymap.set({ "x", "s" }, "<leader>v", "<Cmd>lua require('say-my-name').selection()<CR>", { desc = "Speak selection" })

-- per-feature auto toggles (<leader>t<feature>)
vim.keymap.set("n", "<leader>tn", function() smn.toggle("line_number") end, { desc = "Toggle auto line number" })
vim.keymap.set("n", "<leader>tl", function() smn.toggle("line") end, { desc = "Toggle auto line" })
vim.keymap.set("n", "<leader>td", function() smn.toggle("diagnostics") end, { desc = "Toggle auto diagnostics" })
vim.keymap.set("n", "<leader>ti", function() smn.toggle("indent") end, { desc = "Toggle auto indent" })
vim.keymap.set("n", "<leader>tw", function() smn.toggle("word") end, { desc = "Toggle auto word" })
vim.keymap.set("n", "<leader>tm", function() smn.toggle("mode") end, { desc = "Toggle auto mode" })
vim.keymap.set("n", "<leader>ty", function() smn.toggle("yank") end, { desc = "Toggle auto yank" })
