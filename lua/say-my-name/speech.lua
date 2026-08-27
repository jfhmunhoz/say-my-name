-- Speech manager: the single channel that owns all audio I/O.
-- Everything that speaks goes through here — never call the synthesizer directly.
-- (Seed of roadmap #0: async spawn, interruptible. Queue/verbosity land later.)

local M = {}

-- Generation token: any new utterance bumps it, so an in-flight segment chain
-- from a previous call stops spawning (matters for fast cursor navigation).
local gen = 0

-- Build a spd-say argv for one utterance.
--   opts.voice  spd-say voice type (e.g. "female1") — carries meaning via timbre
--   opts.pitch  -100..100
--   opts.rate   -100..100
--   wait        add -w (block THIS process until spoken; used to order segments)
local function build_cmd(text, opts, wait)
  opts = opts or {}
  local cmd = { "spd-say" }
  if wait then cmd[#cmd + 1] = "-w" end
  if opts.voice then vim.list_extend(cmd, { "-t", opts.voice }) end
  if opts.pitch then vim.list_extend(cmd, { "-p", tostring(opts.pitch) }) end
  if opts.rate then vim.list_extend(cmd, { "-r", tostring(opts.rate) }) end
  vim.list_extend(cmd, { "--", text })
  return cmd
end

-- Speak text. Cancels any in-flight utterance first (always interruptible),
-- spawns asynchronously (never blocks the editor).
function M.say(text, opts)
  gen = gen + 1
  if not text or text == "" then
    vim.system({ "spd-say", "-C" })
    return
  end
  vim.system({ "spd-say", "-C" }) -- interrupt current utterance, no backlog
  vim.system(build_cmd(text, opts))
end

-- Speak a sequence of segments, each with its own voice, in order.
-- list = { { text = "...", opts = {...} }, ... }
-- Each segment waits (-w) and the next is spawned from its on_exit, so order
-- is guaranteed. nvim stays non-blocking (the waiting happens in the child).
function M.say_segments(list)
  gen = gen + 1
  local mygen = gen
  vim.system({ "spd-say", "-C" }) -- cancel once, up front
  local i = 0
  local function next_seg()
    if mygen ~= gen then return end -- superseded by a newer utterance
    i = i + 1
    local s = list[i]
    if not s then return end
    if not s.text or s.text == "" then return next_seg() end
    vim.system(build_cmd(s.text, s.opts, true), {}, function()
      vim.schedule(next_seg)
    end)
  end
  next_seg()
end

-- Silence immediately (panic key).
function M.stop()
  gen = gen + 1
  vim.system({ "spd-say", "-C" })
end

return M
