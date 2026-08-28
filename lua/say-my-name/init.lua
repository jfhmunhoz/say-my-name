-- say-my-name: public API.
-- Providers are pure builders: they read editor state and RETURN speech segments
-- (a list of { text = "...", opts = {...} }). Manual commands speak one provider;
-- the auto-announce layer concatenates several into one utterance. Sharing the
-- builders is what keeps "speak the line" and "auto-speak on a new line" in sync.

local speech = require("say-my-name.speech")
local earcon = require("say-my-name.earcon")

local M = {}

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

function M.indent() earcon.beep(indent_count()) end
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

-- Speak the enabled line-based announcements as one phrase, in a fixed order
-- (number, line, diagnostic). Returns true if anything was spoken.
local function line_announce()
  local segs = {}
  if auto.line_number then vim.list_extend(segs, seg_line_number()) end
  if auto.line then vim.list_extend(segs, seg_line()) end
  if auto.diagnostics then vim.list_extend(segs, seg_diagnostics()) end
  local spoke = #segs > 0
  if spoke then speech.say_segments(segs) end
  if auto.indent then earcon.beep(indent_count()) end
  return spoke
end

-- CursorMoved handler: line-based announces on a new line; word announce on any
-- word change. On a line change, word-mode defers to line-mode if it spoke.
local last_line, last_word
local function on_cursor()
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
    last_line, last_word = nil, nil
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
