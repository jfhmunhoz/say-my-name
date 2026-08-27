-- Earcons: short non-speech tones. Cheaper than words for quantities like
-- indentation depth (roadmap #3). A tone is synthesized once to a cached WAV,
-- then played N times, chained async so nvim never blocks.

local M = {}

-- Tone: low and soft, easier on the ears than a high beep. Params are baked
-- into the cache filename, so changing them regenerates the WAV automatically.
local FREQ = 180  -- Hz (deep)
local MS = 90     -- tone length
local GAP = 70    -- trailing silence, keeps chained beeps distinct

local path = string.format("%s/say-my-name/beep-%d-%d-%d.wav",
  vim.fn.stdpath("cache"), FREQ, MS, GAP)

-- little-endian byte encoders (LuaJIT has no string.pack)
local function le16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function le32(v)
  return string.char(v % 256, math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- Write a mono 16-bit PCM WAV: `ms` of sine at `freq`, then `gap_ms` silence
-- (the trailing silence keeps chained beeps audibly distinct).
local function write_wav(freq, ms, gap_ms)
  local sr = 44100
  local n = math.floor(sr * ms / 1000)
  local ng = math.floor(sr * gap_ms / 1000)
  local fade = math.floor(sr * 0.005) -- 5ms fade in/out, kills clicks
  local samples = {}
  for i = 0, n - 1 do
    local env = 1.0
    if i < fade then env = i / fade elseif i > n - fade then env = (n - i) / fade end
    local s = math.floor(0.5 * env * math.sin(2 * math.pi * freq * i / sr) * 32767)
    if s < 0 then s = s + 65536 end
    samples[#samples + 1] = le16(s)
  end
  for _ = 1, ng do samples[#samples + 1] = le16(0) end
  local pcm = table.concat(samples)

  local hdr = table.concat({
    "RIFF", le32(36 + #pcm), "WAVE",
    "fmt ", le32(16), le16(1), le16(1),
    le32(sr), le32(sr * 2), le16(2), le16(16),
    "data", le32(#pcm),
  })

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = assert(io.open(path, "wb"))
  fd:write(hdr)
  fd:write(pcm)
  fd:close()
end

local function ensure()
  if vim.fn.filereadable(path) == 0 then
    write_wav(FREQ, MS, GAP)
  end
end

-- pick a file player once
local player
local function player_cmd()
  if player == nil then
    if vim.fn.executable("pw-play") == 1 then
      player = { "pw-play" }
    elseif vim.fn.executable("aplay") == 1 then
      player = { "aplay", "-q" }
    else
      player = false
    end
  end
  if not player then return nil end
  local cmd = vim.deepcopy(player)
  cmd[#cmd + 1] = path
  return cmd
end

-- Play the beep `n` times, one after another (async).
function M.beep(n)
  n = math.max(0, math.floor(n or 0))
  if n == 0 then return end
  ensure()
  local cmd = player_cmd()
  if not cmd then return end
  local i = 0
  local function go()
    i = i + 1
    if i > n then return end
    vim.system(cmd, {}, function() vim.schedule(go) end)
  end
  go()
end

return M
