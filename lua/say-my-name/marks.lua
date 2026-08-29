-- Statement marks (roadmap #6): bookmarks that track the STATEMENT, not the line
-- number. Built on extmarks (nvim_buf_set_extmark), which shift with edits — drop
-- a mark, insert lines above it, and it follows the code down. Vim's own `:mark`
-- stores a line number that rots as you edit; and it's silent. Here every mark
-- speaks: what it points at when set, and the line you land on when you jump.
--
-- Keys are vim-native: `m{letter}` sets, `` `{letter} `` jumps. Anything we don't
-- own falls through to vim's real marks, so `` `` ``, `` `. ``, and A-Z globals
-- keep working.

local speech = require("say-my-name.speech")

local M = {}

local ns = vim.api.nvim_create_namespace("say-my-name-marks")

-- marks[bufnr] = { [letter] = extmark_id }. We store only the id; the statement
-- text is read LIVE from the extmark's current position every time, so speech
-- always reflects edits since the mark was set (the whole point of #6).
local marks = {}

local function buf_marks(buf)
  marks[buf] = marks[buf] or {}
  return marks[buf]
end

-- Trimmed text of a line (0-indexed row), or "blank line".
local function statement_at(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local t = line:gsub("^%s+", ""):gsub("%s+$", "")
  if t == "" then return "blank line" end
  return t
end

-- Live 0-indexed {row, col} of a mark, or nil if it was edited away (deleted).
local function mark_pos(buf, id)
  local p = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
  if not p or #p == 0 then return nil end
  return p
end

-- Set mark `name` at the cursor, overwriting any previous mark by that name.
function M.set(name)
  local buf = vim.api.nvim_get_current_buf()
  local c = vim.api.nvim_win_get_cursor(0) -- {row(1), col(0)}
  local row, col = c[1] - 1, c[2]
  local bm = buf_marks(buf)
  local id = bm[name] -- reuse the id so the gutter sign moves, not duplicates
  id = vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
    id = id,
    sign_text = name,      -- gutter letter (sighted testing / screenshots)
    sign_hl_group = "Title",
  })
  bm[name] = id
  speech.say("mark " .. name .. ", " .. statement_at(buf, row))
end

-- Jump to mark `name`: cursor to its live position, speak the line there.
function M.jump(name)
  local buf = vim.api.nvim_get_current_buf()
  local id = buf_marks(buf)[name]
  if not id then return speech.say("no mark " .. name) end
  local p = mark_pos(buf, id)
  if not p then
    buf_marks(buf)[name] = nil
    return speech.say("mark " .. name .. " gone")
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { p[1] + 1, p[2] })
  speech.say(statement_at(buf, p[1]))
end

-- Whether mark `name` is set (and still live) in the current buffer.
local function have(buf, name)
  local id = buf_marks(buf)[name]
  return id ~= nil and mark_pos(buf, id) ~= nil
end

-- ---------------------------------------------------------------------------
-- Native-key wrappers: read the letter that follows m / ` ourselves, handle our
-- lowercase statement marks, and feed anything else back to vim unchanged.
-- ---------------------------------------------------------------------------

local function read_char()
  local ok, ch = pcall(vim.fn.getcharstr)
  if not ok or ch == "" or ch == "\27" then return nil end -- nil / <Esc>
  return ch
end

-- `m` pressed: set our mark for a lowercase letter, else fall through (native
-- m{A-Z} globals, m< m> etc. keep working).
function M.set_prompt()
  local ch = read_char()
  if not ch then return end
  if ch:match("^%l$") then
    M.set(ch)
  else
    vim.api.nvim_feedkeys("m" .. ch, "n", false)
  end
end

-- `` ` `` pressed: jump our mark if we own that letter, else fall through to the
-- native jump (`` `` `` last position, `` `. `` last edit, A-Z globals, ...).
function M.jump_prompt()
  local ch = read_char()
  if not ch then return end
  local buf = vim.api.nvim_get_current_buf()
  if ch:match("^%l$") and have(buf, ch) then
    M.jump(ch)
  else
    vim.api.nvim_feedkeys("`" .. ch, "n", false)
  end
end

-- ---------------------------------------------------------------------------

-- Sorted (by document position) list of the current buffer's live marks:
-- { { name = "a", row = 11, text = "function greet" }, ... }.
local function live_marks(buf)
  local out = {}
  for name, id in pairs(buf_marks(buf)) do
    local p = mark_pos(buf, id)
    if p then
      out[#out + 1] = { name = name, row = p[1], text = statement_at(buf, p[1]) }
    else
      buf_marks(buf)[name] = nil -- prune ones edited away
    end
  end
  table.sort(out, function(a, b) return a.row < b.row end)
  return out
end

-- Open a navigable buffer listing this buffer's marks (letter — line — text).
-- Plain text, so the plugin's own line reading (or a screen reader) consults it,
-- like M.help(). `q` closes it.
function M.list()
  local buf = vim.api.nvim_get_current_buf()
  local items = live_marks(buf)
  local rows = {}
  for _, it in ipairs(items) do
    rows[#rows + 1] = string.format("%s   line %-5d %s", it.name, it.row + 1, it.text)
  end
  local count = #rows
  if count == 0 then
    speech.say("no marks")
    return
  end
  table.insert(rows, 1, ("say-my-name — %d marks.  q to close."):format(count))
  table.insert(rows, 2, "")

  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, rows)
  vim.bo[list_buf].modifiable = false
  vim.bo[list_buf].bufhidden = "wipe"
  vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = list_buf, desc = "Close marks" })

  vim.cmd("botright split")
  vim.api.nvim_set_current_buf(list_buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  speech.say(("%d marks"):format(count))
end

-- Drop every mark in the current buffer.
function M.clear()
  local buf = vim.api.nvim_get_current_buf()
  for _, id in pairs(buf_marks(buf)) do
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
  end
  marks[buf] = {}
  speech.say("marks cleared")
end

return M
