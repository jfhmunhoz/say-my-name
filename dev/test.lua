-- Test file for say-my-name. Open with `tvim dev/test.lua`.
--
-- Keymaps (leader = space):
--   <leader>l  speak current line        (comments read in a distinct voice)
--   <leader>$  speak from cursor to end of line
--   <leader>w  speak word under cursor
--   <leader>n  speak line number
--   <leader>m  speak current mode      (also in visual/select)
--   <leader>v  speak selection         (VISUAL mode)
--   <leader>y  speak last yank
--   <leader>i  speak indentation depth   (as a number, e.g. "four")
--   <leader>d  speak diagnostics on line (lua_ls; graver pitch = worse)
--   <leader>.  toggle speaking punctuation (brackets, commas, ...)
--   <leader>h  open navigable list of all mappings (read it with the commands above)
--   <leader>o  toggle TREE MODE: walk file structure, not lines
--                h/j/k/l = parent / next / prev / child block; <Esc> exits
--                a blocked move plays the "beh" buzzer
--   <leader>b  toggle BLINDFOLD: blank the screen, test by ear like a blind user
--   m{letter}  set a STATEMENT MARK here (speaks what it points at)
--   `{letter}  jump to a statement mark (exact pos; speaks the line there)
--   '{letter}  jump to a statement mark (line; speaks the line there)
--                marks track edits: insert lines above one and it follows the
--                code down. letters you didn't set fall through to vim's marks.
--   <leader>k  open a navigable list of this buffer's statement marks
--   <leader>K  clear this buffer's statement marks
--   <leader>s  stop / panic-silence
--
-- Auto-announce (speaks as you move to a new line):
--   <leader><leader> cycle verbosity preset  (minimal -> normal -> verbose)
--   <leader>tn toggle auto line number
--   <leader>tl toggle auto line
--   <leader>td toggle auto diagnostics
--   <leader>ti toggle auto indent (deeper line -> rising ping, shallower -> falling)
--   <leader>tw toggle auto word   (speaks each word as you jump w/b/e)
--   <leader>tm toggle auto mode   (speaks the mode whenever you switch)
--   <leader>ty toggle auto yank   (speaks yanked text after each yank)
--   <leader>t. toggle punctuation (also <leader>.)
-- Pick a preset with <leader><leader>, then tweak with <leader>t*. minimal =
-- commands only; verbose = number + line + diagnostics + indent ping per line.

local M = {}

-- config: a table of sibling fields. In TREE MODE, <leader>o then l descends
-- into it and j/k walk the entries; also a good <leader>. punctuation target.
M.config = {
  name = "say-my-name",
  rate = 350,
  voices = { code = "male1", comment = "female1" }, -- nested table, more (), {}
}

-- greet: the body has THREE sibling statements (local, if/else, return). In
-- tree mode, <leader>o on this line then l enters, then j/k walks the three.
function M.greet(name)
  local greeting = "hello, " .. name -- trailing comment: code voice then comment voice
  if name == "" then
    greeting = "hello, stranger" -- <leader>l reads this whole nested line
  else
    greeting = greeting .. "!"
  end
  return greeting -- j from the if lands here (its sibling)
end

-- pipeline: deeply nested WITH siblings at every level. Good for <leader>i
-- (indentation depth), the auto indent ping (ti), and tree l/h drilling.
function M.pipeline(items)
  local total = 0          -- sibling 1
  local seen = {}          -- sibling 2 (j from the line above)
  for _, item in ipairs(items) do        -- sibling 3: the loop
    if item > 0 then
      while item > 1 do
        item = math.floor(item / 2)      -- <leader>i here: deep indent -> "eight"
        total = total + item             -- j: sibling inside the while
      end
      seen[#seen + 1] = item             -- j from the while: its sibling
    elseif item < 0 then
      total = total - item
    else
      total = total                      -- no-op branch
    end
  end
  local antidisestablishmentarianism = 0 -- <leader>w on this very long word
  total = total + antidisestablishmentarianism
  return total, seen                     -- last sibling of the body
end

-- has_issues: two intentional lua_ls diagnostics to hear with <leader>d.
function M.has_issues()
  undefined_reference()          -- <leader>d -> "warning, undefined global ..."
  local unused_local = 42        -- <leader>d -> "hint, unused local ..."
  return nil
end

-- punctuation_demo: brackets, parens, commas, operators. Toggle <leader>.
-- (or <leader>t.) and press <leader>l on the return line to hear the change.
function M.punctuation_demo(a, b)
  local pair = { a, (b or 0), ["k"] = a * 2 } -- () {} [] , * : hear them or not
  return pair
end

return M
