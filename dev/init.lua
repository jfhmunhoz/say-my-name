-- Dev/test harness for say-my-name. NOT shipped plugin behavior.
-- Launched via:  NVIM_APPNAME=nvim-tcc nvim -u dev/init.lua
-- Loads the plugin from this working copy (latest, uncommitted edits included).
-- Leader and test keymaps live HERE, never in plugin/ or lua/ (would hijack users).

-- repo root = parent dir of this file (dev/../)
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

vim.g.mapleader = " "
vim.g.maplocalleader = " "

local smn = require("say-my-name")

vim.keymap.set("n", "<leader>l", smn.line, { desc = "Speak current line" })
vim.keymap.set("n", "<leader>w", smn.word, { desc = "Speak word under cursor" })
vim.keymap.set("n", "<leader>n", smn.line_number, { desc = "Speak line number" })
vim.keymap.set("n", "<leader>i", smn.indent, { desc = "Beep indentation depth" })
vim.keymap.set("n", "<leader>s", smn.stop, { desc = "Stop speech (panic-silence)" })
