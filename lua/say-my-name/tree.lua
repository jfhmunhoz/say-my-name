-- Tree navigation mode (roadmap #4): walk the file's structure as a tree instead
-- of line by line. A toggle enters a transient mode where h/j/k/l move over the
-- treesitter node tree — siblings with j/k, descend with l, ascend with h — and
-- the cursor follows each hop while the plugin speaks the node's kind and depth.
-- Pure treesitter: works in any buffer that has a parser, no LSP needed.

local speech = require("say-my-name.speech")
local earcon = require("say-my-name.earcon")

local M = {}

-- Public so the auto-announce layer (init.on_cursor) can stay quiet while we
-- drive the cursor around — otherwise every hop would also read the line.
M.active = false

local node = nil   -- current TSNode
local buf = nil    -- buffer the mode is bound to
local grp = vim.api.nvim_create_augroup("say-my-name-tree", { clear = true })

-- Treesitter type -> friendly spoken name. Anything unmapped falls back to the
-- raw type with "_statement" stripped and underscores turned to spaces.
local KIND = {
  if_statement = "if", elseif_statement = "elseif", else_statement = "else",
  while_statement = "loop", repeat_statement = "loop",
  for_statement = "loop", for_numeric_statement = "loop", for_generic_statement = "loop",
  function_declaration = "func", function_definition = "func", local_function = "func",
  method_declaration = "method",
  function_call = "call", call = "call",
  return_statement = "return", break_statement = "break", goto_statement = "goto",
  variable_declaration = "var", local_declaration = "var", assignment_statement = "set",
  do_statement = "do", table_constructor = "table",
  block = "then", -- only reached when it's an if's then-branch (see interesting)
}

-- Node types worth stopping on: statements, blocks, definitions. Everything
-- else (names, conditions, parameters, identifiers, comments) is skipped, so
-- navigation stays on structure the way the file's indentation reads.
local INTERESTING = {
  function_declaration = true, function_definition = true, local_function = true,
  if_statement = true, elseif_statement = true, else_statement = true,
  while_statement = true, repeat_statement = true, do_statement = true,
  for_statement = true, for_numeric_statement = true, for_generic_statement = true,
  return_statement = true, break_statement = true, goto_statement = true,
  variable_declaration = true, assignment_statement = true, function_call = true,
}

local function interesting(n)
  local t = n:type()
  -- The then-branch of an if has no clause node of its own — it's a bare block.
  -- Make that one block navigable ("then") so then/elseif/else are literal
  -- siblings you can walk. Bodies of loops/functions stay transparent.
  if t == "block" then
    local p = n:parent()
    return p ~= nil and p:type() == "if_statement"
  end
  if not INTERESTING[t] then return false end
  -- `local x = 1` is variable_declaration wrapping an assignment_statement;
  -- surface only the outer one so descending doesn't hit the same line twice.
  if t == "assignment_statement" then
    local p = n:parent()
    return not (p and p:type() == "variable_declaration")
  end
  return true
end

-- First interesting node inside n's subtree, in document order. Recurses through
-- uninteresting wrappers (block, condition) but stops at the first hit — it does
-- not dig past an interesting node into its children.
local function first_inside(n)
  for c in n:iter_children() do
    if c:named() then
      if interesting(c) then return c end
      local r = first_inside(c)
      if r then return r end
    end
  end
end

-- A node's body block, if it has one (if/while/for/function/do all do). Used so
-- descending lands in the body, not in a header expression (a for-loop's
-- iterator call, an if's condition) that happens to sit before the block.
local function body_block(n)
  for c in n:iter_children() do
    if c:type() == "block" then return c end
  end
end

-- Descend one level. On an if, land on its "then" branch (so j reaches
-- elseif/else); on a then-branch block, into its statements; otherwise into the
-- body's first statement. Leaf statements have no body and don't descend.
local function descend(n)
  local t = n:type()
  if t == "if_statement" then return body_block(n) end -- the then-branch block
  if t == "block" then return first_inside(n) end      -- then-branch -> its stmts
  local b = body_block(n)
  if b then return first_inside(b) end
end

-- Nearest interesting ancestor (for ascending out of blocks/conditions).
local function ancestor(n)
  local p = n:parent()
  while p and not interesting(p) do p = p:parent() end
  return p
end

-- Next/prev sibling that is interesting, skipping comments etc. dir "j"|"k".
-- (Explicit branch, not `a and b or c`: next_named_sibling() is nil at the last
-- sibling, which would wrongly fall through to prev_named_sibling.)
local function sibling(n, dir)
  local function step(x)
    if dir == "j" then return x:next_named_sibling() end
    return x:prev_named_sibling()
  end
  local s = step(n)
  while s and not interesting(s) do s = step(s) end
  return s
end

-- Same node? Compare by start + type (TSNode == across calls isn't reliable).
local function same(a, b)
  if not a or not b then return false end
  local ar, ac = a:start()
  local br, bc = b:start()
  return ar == br and ac == bc and a:type() == b:type()
end

-- Snap an arbitrary node (e.g. under the cursor) to an interesting one.
local function normalize(n)
  if not n then return nil end
  if interesting(n) then return n end
  return ancestor(n) or first_inside(n)
end

-- Spoken label for a node: friendly kind + how deep it sits.
local function label(n)
  local t = n:type()
  local name = KIND[t] or (t:gsub("_statement", ""):gsub("_", " "))
  -- depth = logical nesting: count only interesting ancestors (skip block/etc),
  -- so a top-level statement is depth 1, one nested inside it depth 2, ...
  local depth, p = 1, n:parent()
  while p do
    if interesting(p) then depth = depth + 1 end
    p = p:parent()
  end
  return string.format("%s, depth %d", name, depth)
end

-- The cursor position WE last drove to, so the CursorMoved watcher can tell our
-- own hops (cursor already there) apart from the user jumping (gg, G, search)
-- and re-attach only on the latter. A boolean flag would go stale, since the
-- cursor API doesn't emit CursorMoved to consume it.
local self_pos

-- Move the window cursor onto a node's first character.
local function goto_node(n)
  local sr, sc = n:start()
  self_pos = { sr + 1, sc }
  pcall(vim.api.nvim_win_set_cursor, 0, self_pos)
end

-- Best node to attach to at the current cursor: the interesting node there, or,
-- failing that (cursor in a comment / blank line), the file's first one.
local function pick()
  if not buf then return nil end
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then return nil end
  pcall(function() parser:parse() end)
  local n = normalize(vim.treesitter.get_node())
  if n then return n end
  return first_inside(parser:trees()[1]:root())
end

-- Edge cue: a descending "beh" buzzer meaning "can't move that way".
local function edge() earcon.nope() end

-- ===========================================================================

-- Walk one step over interesting nodes only. dir in { "h", "j", "k", "l" }.
--   j/k = next/prev sibling, l = descend to first child block, h = ascend.
function M.move(dir)
  if not M.active or not node then return end
  local target
  if dir == "j" then target = sibling(node, "j")
  elseif dir == "k" then target = sibling(node, "k")
  elseif dir == "l" then target = descend(node)
  elseif dir == "h" then target = ancestor(node)
  end
  if not target then return edge() end
  node = target
  goto_node(node)
  speech.say(label(node))
end

local NAV_KEYS = { "h", "j", "k", "l" }

local function set_maps()
  local opts = { buffer = buf, nowait = true, silent = true }
  for _, k in ipairs(NAV_KEYS) do
    vim.keymap.set("n", k, function() M.move(k) end, opts)
  end
  vim.keymap.set("n", "<Esc>", M.exit, opts)
end

local function clear_maps()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  for _, k in ipairs(NAV_KEYS) do
    pcall(vim.keymap.del, "n", k, { buffer = buf })
  end
  pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
end

-- Re-attach the tree to wherever the cursor lands after a plain motion (gg, G,
-- search, {/}), so tree mode follows you. Our own hops set self_move and are
-- skipped. Only speaks when the attachment actually changed nodes.
local function reattach()
  if not M.active then return end
  local c = vim.api.nvim_win_get_cursor(0)
  if self_pos and c[1] == self_pos[1] and c[2] == self_pos[2] then return end
  local n = pick()
  if not n or same(n, node) then return end
  node = n
  goto_node(node) -- snap onto the node (updates self_pos)
  speech.say(label(node))
end

-- Enter tree mode on the current buffer, starting from the node at the cursor.
function M.enter()
  if M.active then return end
  buf = vim.api.nvim_get_current_buf()
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return speech.say("no tree for this buffer")
  end
  local n = pick()
  if not n then return speech.say("nothing to navigate") end

  node = n
  M.active = true
  goto_node(node) -- align the cursor with the block we announce
  set_maps()
  -- follow plain cursor jumps (gg, G, search, ...): re-attach where you land
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = grp, buffer = buf, callback = reattach,
  })
  -- safety: leaving the buffer exits the mode so no stray maps linger
  vim.api.nvim_create_autocmd("BufLeave", {
    group = grp, buffer = buf, once = true, callback = M.exit,
  })
  speech.say("tree mode, " .. label(node))
end

-- Leave tree mode; the cursor stays on the node you navigated to.
function M.exit()
  if not M.active then return end
  M.active = false
  clear_maps()
  vim.api.nvim_clear_autocmds({ group = grp })
  node, buf = nil, nil
  speech.say("normal")
end

function M.toggle()
  if M.active then M.exit() else M.enter() end
end

return M
