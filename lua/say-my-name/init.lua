-- say-my-name: public API.
-- Providers are pure builders: they read editor state and RETURN speech segments
-- (a list of { text = "...", opts = {...} }). Manual commands speak one provider;
-- the auto-announce layer concatenates several into one utterance. Sharing the
-- builders is what keeps "speak the line" and "auto-speak on a new line" in sync.

local speech = require("say-my-name.speech")
local earcon = require("say-my-name.earcon")
local tree = require("say-my-name.tree")
local marks = require("say-my-name.marks")

local M = {}

-- Tree navigation mode (see tree.lua). Toggle walks the file's structure with
-- h/j/k/l instead of moving line by line.
M.tree_toggle = tree.toggle

-- Statement marks (see marks.lua). Extmark bookmarks that track the statement
-- across edits and speak on set/jump. mark_set/mark_jump wrap vim's m / ` keys.
M.mark_set = marks.set_prompt
M.mark_jump = marks.jump_prompt
M.mark_list = marks.list
M.mark_clear = marks.clear

-- ===========================================================================
-- Providers (pure: return a segment list, possibly empty)
-- ===========================================================================

-- Voice for comment text — distinct timbre so the ear knows prose from code.
local COMMENT_VOICE = { voice = "female1", pitch = 30 }

-- Severity -> spoken name + pitch (graver pitch = worse).
local SEV = {
  [vim.diagnostic.severity.ERROR] = { name = "error",   pitch = -30 },
  [vim.diagnostic.severity.WARN]  = { name = "warning", pitch = -10 },
  [vim.diagnostic.severity.INFO]  = { name = "info",    pitch = 10 },
  [vim.diagnostic.severity.HINT]  = { name = "hint",    pitch = 20 },
}

local function seg_line_number()
  return { { text = "line " .. vim.fn.line(".") } }
end

-- Word under the cursor, but "" unless the cursor is actually ON a keyword char.
-- (vim's <cword> otherwise jumps to the NEXT word when sitting on punctuation.)
local function word_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col(".")
  local ch = line:sub(col, col)
  if ch == "" or vim.fn.match(ch, "\\k") < 0 then return "" end
  return vim.fn.expand("<cword>")
end

local function seg_word()
  local w = word_at_cursor()
  if w == "" then return {} end
  return { { text = w } }
end

-- Column (0-indexed) where a comment begins on the line, or nil.
local function comment_start(lnum)
  local text = vim.fn.getline(lnum)
  local ok, parser = pcall(vim.treesitter.get_parser, 0)
  if not ok or not parser then return nil end
  pcall(function() parser:parse() end)
  for c = 0, #text - 1 do
    local node = vim.treesitter.get_node({ pos = { lnum - 1, c } })
    while node do
      if node:type():find("comment") then return c end
      node = node:parent()
    end
  end
  return nil
end

-- Current line, splitting a trailing/whole-line comment into the comment voice.
local function seg_line()
  local lnum = vim.fn.line(".")
  local text = vim.api.nvim_get_current_line()
  local cc = comment_start(lnum)
  if not cc then return { { text = text } } end
  local code = text:sub(1, cc):gsub("%s+$", "")
  local comment = text:sub(cc + 1)
  local segs = {}
  if code ~= "" then segs[#segs + 1] = { text = code } end
  segs[#segs + 1] = { text = comment, opts = COMMENT_VOICE }
  return segs
end

-- LSP diagnostics on the current line, worst severity first.
local function seg_diagnostics()
  local ds = vim.diagnostic.get(0, { lnum = vim.fn.line(".") - 1 })
  if #ds == 0 then return {} end
  table.sort(ds, function(a, b) return a.severity < b.severity end)
  local segs = {}
  for _, d in ipairs(ds) do
    local s = SEV[d.severity] or { name = "note", pitch = 0 }
    local msg = (d.message or ""):gsub("%s+", " ")
    segs[#segs + 1] = { text = s.name .. ", " .. msg, opts = { pitch = s.pitch } }
  end
  return segs
end

local function indent_count()
  return vim.fn.indent(vim.fn.line("."))
end

-- Indent-change ping: an octave pair, easy on the ears (a table-tennis "pock").
-- Auto-indent plays the rising tone when you move to a deeper line, the falling
-- tone when shallower — direction by pitch, no words.
local INDENT_TONE = { up = 659, down = 330 } -- E5 rising / E4 falling

-- Spoken name for the current vim mode.
local MODE_NAMES = {
  n = "normal", i = "insert", v = "visual", V = "visual line",
  ["\22"] = "visual block", s = "select", S = "select line",
  ["\19"] = "select block", R = "replace", c = "command",
  t = "terminal", r = "prompt", ["!"] = "shell",
}
local function mode_name()
  local m = vim.fn.mode()
  return MODE_NAMES[m] or MODE_NAMES[m:sub(1, 1)] or m
end

-- ===========================================================================
-- Manual commands (always work, independent of verbosity)
-- ===========================================================================

function M.line() speech.say_segments(seg_line()) end

-- Speak from the cursor to the end of the line (like vim's $).
function M.line_to_end()
  speech.say(vim.api.nvim_get_current_line():sub(vim.fn.col(".")))
end

function M.word() speech.say_segments(seg_word()) end
function M.line_number() speech.say_segments(seg_line_number()) end

function M.diagnostics()
  local segs = seg_diagnostics()
  if #segs == 0 then speech.say("no diagnostics") else speech.say_segments(segs) end
end

-- Speak the indentation depth as a number ("four" for four leading spaces).
function M.indent() speech.say(tostring(indent_count())) end
function M.mode() speech.say(mode_name()) end
function M.stop() speech.stop() end

-- Speak the current visual selection (call from visual mode via <Cmd>).
function M.selection()
  local m = vim.fn.mode()
  if m ~= "v" and m ~= "V" and m ~= "\22" then return end
  local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = m })
  speech.say(table.concat(lines, " "))
end

-- Speak the last yank (register 0).
function M.last_yank()
  speech.say((vim.fn.getreg("0"):gsub("%s+", " ")))
end

-- Toggle whether punctuation (brackets, commas, ...) is spoken.
function M.toggle_punctuation()
  local on = not speech.get_punctuation()
  speech.set_punctuation(on)
  speech.say("punctuation " .. (on and "on" or "off"))
end

-- Open a navigable buffer listing the leader key mappings (key — description).
-- Blind-accessible by construction: it's plain text, so this plugin's own line
-- reading (or a screen reader) consults it. Built from live keymaps' desc, so
-- it always matches whatever is bound. `q` closes it.
function M.help()
  -- collapse the same key across modes into one row, tagging visual bindings
  local by_key, keys = {}, {}
  for _, mode in ipairs({ "n", "x", "s" }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      if m.desc and m.lhs:sub(1, 1) == " " then -- leader (space) mappings
        local key = vim.fn.keytrans(m.lhs)
        local e = by_key[key]
        if not e then e = { desc = m.desc, visual = false }; by_key[key] = e; keys[#keys + 1] = key end
        if mode == "x" or mode == "s" then e.visual = true end
      end
    end
  end
  table.sort(keys)
  local rows = {}
  for _, key in ipairs(keys) do
    local e = by_key[key]
    rows[#rows + 1] = string.format("%-18s %s%s", key, e.desc, e.visual and "  (visual)" or "")
  end
  local count = #rows
  table.insert(rows, 1, ("say-my-name — %d key mappings.  q to close."):format(count))
  table.insert(rows, 2, "")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, desc = "Close help" })

  vim.cmd("botright split")
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  speech.say(("help, %d mappings"):format(count))
end

-- Blindfold: blank the screen (conceal every character, hide numbers/status/
-- cursorline) so you can test the plugin by ear, like a blind user, while the
-- buffer and all editing keep working. Reversible — toggles back to what it was.
local blindfold = { on = false, match = nil, saved = {} }
function M.blindfold()
  if not blindfold.on then
    blindfold.saved = {
      conceallevel = vim.wo.conceallevel, concealcursor = vim.wo.concealcursor,
      number = vim.wo.number, relativenumber = vim.wo.relativenumber,
      cursorline = vim.wo.cursorline, signcolumn = vim.wo.signcolumn,
      laststatus = vim.o.laststatus, guicursor = vim.o.guicursor,
      termguicolors = vim.o.termguicolors,
      hl_normal = vim.api.nvim_get_hl(0, { name = "Normal" }),
      hl_cursor = vim.api.nvim_get_hl(0, { name = "Cursor" }),
    }
    vim.wo.conceallevel = 3
    vim.wo.concealcursor = "nvic" -- conceal the cursor line too, in every mode
    vim.wo.number = false
    vim.wo.relativenumber = false
    vim.wo.cursorline = false
    vim.wo.signcolumn = "no"
    vim.o.laststatus = 0
    -- conceal every character in the window; at conceallevel 3 the replacement
    -- char is hidden too, so the whole buffer renders blank
    blindfold.match = vim.fn.matchadd("Conceal", ".", 10, -1, { conceal = " " })
    -- hide the cursor too: paint a solid background and make the cursor block
    -- the same color, so it vanishes. termguicolors so the terminal obeys.
    local bg = blindfold.saved.hl_normal.bg
    local color = bg and string.format("#%06x", bg) or "#000000"
    vim.o.termguicolors = true
    vim.api.nvim_set_hl(0, "Normal", { fg = color, bg = color })
    vim.api.nvim_set_hl(0, "Cursor", { fg = color, bg = color, blend = 100 })
    vim.o.guicursor = "a:Cursor/lCursor"
    blindfold.on = true
    speech.say("blindfold on")
  else
    if blindfold.match then pcall(vim.fn.matchdelete, blindfold.match); blindfold.match = nil end
    local s = blindfold.saved
    vim.wo.conceallevel = s.conceallevel
    vim.wo.concealcursor = s.concealcursor
    vim.wo.number = s.number
    vim.wo.relativenumber = s.relativenumber
    vim.wo.cursorline = s.cursorline
    vim.wo.signcolumn = s.signcolumn
    vim.o.laststatus = s.laststatus
    vim.o.guicursor = s.guicursor
    vim.api.nvim_set_hl(0, "Normal", s.hl_normal)
    vim.api.nvim_set_hl(0, "Cursor", s.hl_cursor)
    vim.o.termguicolors = s.termguicolors
    blindfold.on = false
    speech.say("blindfold off")
  end
end

-- ===========================================================================
-- Verbosity + per-feature auto toggles
-- ===========================================================================

-- Which features fire automatically. `word` fires on any word change; `mode`
-- fires on mode switch; the rest fire when you enter a new line.
local auto = {
  line_number = false, line = false, diagnostics = false,
  indent = false, word = false, mode = false, yank = false,
}

local labels = {
  line_number = "line number",
  line = "line",
  diagnostics = "diagnostics",
  indent = "indent",
  word = "word",
  mode = "mode",
  yank = "yank",
}

-- Presets set a bundle of flags; tweak individually afterward.
local presets = {
  minimal = {},
  normal  = { line = true, diagnostics = true },
  verbose = { line_number = true, line = true, diagnostics = true, indent = true, mode = true },
}
local preset_order = { "minimal", "normal", "verbose" }
local current_preset = "minimal"

local function apply_preset(name)
  local p = presets[name] or {}
  for k in pairs(auto) do auto[k] = p[k] == true end
  current_preset = name
end

-- Select a verbosity preset (speaks its name).
function M.verbosity(name)
  if not presets[name] then return end
  apply_preset(name)
  speech.say(name)
end

-- Cycle minimal -> normal -> verbose -> minimal ...
function M.cycle_verbosity()
  local idx = 1
  for i, n in ipairs(preset_order) do if n == current_preset then idx = i end end
  M.verbosity(preset_order[(idx % #preset_order) + 1])
end

-- Toggle one feature's auto-announce (speaks "line on" / "line off").
function M.toggle(feature)
  if auto[feature] == nil then return end
  auto[feature] = not auto[feature]
  speech.say((labels[feature] or feature) .. " " .. (auto[feature] and "on" or "off"))
end

-- Indent depth of the previous line visited, for the auto-indent direction ping.
local last_indent

-- Speak the enabled line-based announcements as one phrase, in a fixed order
-- (number, line, diagnostic). Returns true if anything was spoken.
local function line_announce()
  local segs = {}
  if auto.line_number then vim.list_extend(segs, seg_line_number()) end
  if auto.line then vim.list_extend(segs, seg_line()) end
  if auto.diagnostics then vim.list_extend(segs, seg_diagnostics()) end
  local spoke = #segs > 0
  if spoke then speech.say_segments(segs) end
  if auto.indent then
    local cur = indent_count()
    if last_indent ~= nil then
      if cur > last_indent then earcon.tone(INDENT_TONE.up)
      elseif cur < last_indent then earcon.tone(INDENT_TONE.down) end
    end
    last_indent = cur
  end
  return spoke
end

-- CursorMoved handler: line-based announces on a new line; word announce on any
-- word change. On a line change, word-mode defers to line-mode if it spoke.
local last_line, last_word
local function on_cursor()
  if tree.active then return end -- tree mode drives the cursor and speaks itself
  local l = vim.fn.line(".")
  local w = word_at_cursor()
  if l ~= last_line then
    last_line = l
    local spoke = line_announce()
    if auto.word and not spoke and w ~= "" and w ~= last_word then
      speech.say(w)
    end
    last_word = w
    return
  end
  if auto.word and w ~= "" and w ~= last_word then
    last_word = w
    speech.say(w)
  end
end

-- Arm the auto layer and apply an initial preset. Call once (e.g. from config).
--   opts.verbosity  initial preset name (default "minimal")
function M.setup(opts)
  opts = opts or {}
  apply_preset(opts.verbosity or "minimal")
  if M._armed then return end
  M._armed = true
  local grp = vim.api.nvim_create_augroup("say-my-name-auto", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", { group = grp, callback = on_cursor })
  -- forget position on buffer switch so the first move there announces
  vim.api.nvim_create_autocmd("BufEnter", { group = grp, callback = function()
    last_line, last_word, last_indent = nil, nil, nil
  end })
  -- mode announce on switch, deduped (skips transient same-name transitions)
  local last_mode
  vim.api.nvim_create_autocmd("ModeChanged", { group = grp, callback = function()
    if not auto.mode then last_mode = nil; return end
    local name = mode_name()
    if name ~= last_mode then
      last_mode = name
      speech.say(name)
    end
  end })
  -- announce yanked text (only yanks, not deletes/changes)
  vim.api.nvim_create_autocmd("TextYankPost", { group = grp, callback = function()
    if not auto.yank or vim.v.event.operator ~= "y" then return end
    speech.say(table.concat(vim.v.event.regcontents or {}, " "))
  end })
end

return M
