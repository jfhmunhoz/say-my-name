-- Test file for say-my-name. Open with `tvim dev/test.lua`.
--
-- Keymaps (leader = space):
--   <leader>l  speak current line        (comments read in a distinct voice)
--   <leader>$  speak from cursor to end of line
--   <leader>w  speak word under cursor
--   <leader>n  speak line number
--   <leader>i  beep indentation depth    (one beep per leading space)
--   <leader>d  speak diagnostics on line (lua_ls; graver pitch = worse)
--   <leader>s  stop / panic-silence
--
-- Auto-announce (speaks as you move to a new line):
--   <leader>v  cycle verbosity preset  (minimal -> normal -> verbose)
--   <leader>tn toggle auto line number
--   <leader>tl toggle auto line
--   <leader>td toggle auto diagnostics
--   <leader>ti toggle auto indent
--   <leader>tw toggle auto word   (speaks each word as you jump w/b/e)
-- Pick a preset with <leader>v, then tweak with <leader>t*. minimal = commands
-- only; verbose = number + line + diagnostics + indent beep on every new line.
--
-- What to try, and what you should hear:

local M = {}

-- full-line comment: <leader>l reads this whole line in the comment voice
function M.greet(name)
  local message = "hello, " .. name -- trailing comment: code voice, then comment voice
  return message
end

function M.indentation_demo()
  if true then
    while true do -- <leader>i on the lines below: 4, 6, 8 spaces -> more beeps
      for _ = 1, 3 do
        local antidisestablishmentarianism = 1 -- <leader>w on this long word
        return antidisestablishmentarianism
      end
    end
  end
end

function M.has_errors()
  undefined_reference() -- <leader>d -> "warning, undefined global `undefined_reference`"
  local unused_local = 42 -- <leader>d -> "hint, unused local `unused_local`"
  return nil
end

return M
