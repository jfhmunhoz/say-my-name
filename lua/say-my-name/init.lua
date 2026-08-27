-- say-my-name: public API.
-- Content providers are pure-ish: read editor state, hand text to the speech manager.

local speech = require("say-my-name.speech")
local earcon = require("say-my-name.earcon")

local M = {}

-- Voice used for comment text. Distinct timbre so the ear knows "this is prose,
-- not code" without spending a word on it (prosody carries info).
local COMMENT_VOICE = { voice = "female1", pitch = 30 }

-- Column (0-indexed) where a comment begins on the line, or nil if none.
-- Scans left-to-right for the first char whose treesitter node is a comment;
-- everything from there is treated as the comment (handles trailing comments).
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

-- Speak the current line. A trailing/whole-line comment is spoken in the comment
-- voice; any code before it keeps the default voice.
function M.line()
  local lnum = vim.fn.line(".")
  local text = vim.api.nvim_get_current_line()
  local cc = comment_start(lnum)

  if not cc then
    speech.say(text)
    return
  end

  local code = text:sub(1, cc):gsub("%s+$", "")
  local comment = text:sub(cc + 1)
  local segs = {}
  if code ~= "" then segs[#segs + 1] = { text = code } end
  segs[#segs + 1] = { text = comment, opts = COMMENT_VOICE }
  speech.say_segments(segs)
end

-- Speak the word under the cursor.
function M.word()
  speech.say(vim.fn.expand("<cword>"))
end

-- Speak the current line number.
function M.line_number()
  speech.say("line " .. vim.fn.line("."))
end

-- Beep the indentation of the current line: one beep per leading space
-- (tabs expanded to 'tabstop'). Beats reading "space space space".
function M.indent()
  earcon.beep(vim.fn.indent(vim.fn.line(".")))
end

-- Severity -> spoken name + pitch. Graver pitch for worse severity so the ear
-- grades the problem before hearing the message (prosody carries info).
local SEV = {
  [vim.diagnostic.severity.ERROR] = { name = "error",   pitch = -30 },
  [vim.diagnostic.severity.WARN]  = { name = "warning", pitch = -10 },
  [vim.diagnostic.severity.INFO]  = { name = "info",    pitch = 10 },
  [vim.diagnostic.severity.HINT]  = { name = "hint",    pitch = 20 },
}

-- Speak the LSP diagnostics on the current line, worst severity first.
function M.diagnostics()
  local ds = vim.diagnostic.get(0, { lnum = vim.fn.line(".") - 1 })
  if #ds == 0 then
    speech.say("no diagnostics")
    return
  end
  table.sort(ds, function(a, b) return a.severity < b.severity end)
  local segs = {}
  for _, d in ipairs(ds) do
    local s = SEV[d.severity] or { name = "note", pitch = 0 }
    local msg = (d.message or ""):gsub("%s+", " ")
    segs[#segs + 1] = { text = s.name .. ", " .. msg, opts = { pitch = s.pitch } }
  end
  speech.say_segments(segs)
end

-- Panic-silence.
function M.stop()
  speech.stop()
end

return M
