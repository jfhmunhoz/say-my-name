# say-my-name

A Neovim plugin that improves the developer experience for **blind and
low-vision programmers** — a speech layer that announces code structure,
context, and diagnostics on demand, built to be concise and controllable rather
than chatty.

This is the implementation repository for an undergraduate thesis (TCC) in
Computer Science: *"Melhorando a experiência do desenvolvedor para programadores
cegos e com baixa visão por meio de plugins acessíveis para o Neovim"*. The
research, thesis writing, and paper corpus live in a separate private
repository; this repo holds only the open-source code.

## Why

Screen readers present code **linearly** — one line, one character at a time —
and lose its structure. That single root cause drives most of the friction blind
developers report: they can't skim, indentation is read as "space space space",
scope is invisible, and errors are announced without location or type. A
keyboard-driven editor in the terminal, with a **programmable speech layer**, can
attack that root cause directly.

The design is driven by a review of 33 sources (academic + community). The most
underrated finding: **less speech, on demand, beats more speech pushed at you.**
Developers report turning the screen reader *off* because the noise breaks their
flow. So the guiding principle here is a speech layer that is **concise,
interruptible, dismissible, and prosodic** — that is the contribution, and what
separates this from simply reading everything aloud.

## Design principles (non-negotiable)

- **One speech channel.** Nothing calls the synthesizer directly; everything goes
  through a single manager that owns all audio I/O.
- **Never block the editor.** Speech is spawned asynchronously.
- **Always interruptible.** A new utterance cancels the current one — no backlog.
- **Nothing forced or continuous.** Every announcement is on demand or opt-in per
  event. Defaults are minimal. A panic key silences instantly.
- **Coexist with a system screen reader** (Orca, etc.) — complement, don't
  double-speak.
- **Prosody carries information.** Pitch for indentation depth, tone for
  error-vs-warning — cheaper than words.

## Architecture

```
autocmds / keymaps  ──▶  content providers  ──▶  speech manager  ──▶  spd-say
   (triggers)            (line/symbol/diag)      (queue+verbosity)   (async, cancelable)
```

Content providers are **pure** — they return text (and optional prosody) for a
given context. The **speech manager** owns queueing, verbosity, interruption, and
the backend. This keeps providers testable and the backend swappable.

### Speech backend

- Default: **`spd-say`** (speech-dispatcher) — asynchronous, cancelable
  (`spd-say -C`), and on the same bus Orca already uses.
- Fallback: **`espeak-ng`** (direct, lowest latency).
- Later: **piper** (neural, natural voice) in server mode for quality.

Spawned via `vim.system()` (Neovim ≥ 0.10), never blocking.

## Implemented

Working today (preview; the API is still moving). The plugin exposes functions
on `require("say-my-name")`; the example key bindings below live in
[`dev/init.lua`](dev/init.lua) — a test harness, so the plugin never forces
keymaps on you. Leader is space in the harness.

**On-demand commands**

| Key | Speaks |
|-----|--------|
| `<leader>l` | current line (comments in a distinct voice) |
| `<leader>$` | cursor → end of line |
| `<leader>w` | word under the cursor |
| `<leader>n` | line number |
| `<leader>i` | indentation depth as a number ("four" for four leading spaces) |
| `<leader>d` | line diagnostics, worst first, severity graded by pitch |
| `<leader>m` | current mode (also in visual/select) |
| `<leader>v` | the selection (visual mode) |
| `<leader>y` | last yank |
| `<leader>h` | opens a navigable buffer of all key mappings (read it with the commands above) |
| `<leader>o` | toggles **tree navigation mode** (see below) |
| `<leader>s` | stop / panic-silence |

**Tree navigation mode** — instead of moving line by line, walk the file's
structure as a tree (roadmap #4). `<leader>o` enters; then `h`/`j`/`k`/`l` move
by *block*, not line: `j`/`k` = next/previous sibling, `l` = descend into a
block, `h` = ascend to the enclosing block. Descending an `if` exposes its
`then`/`elseif`/`else` branches as siblings, so you can walk each arm. The cursor
follows each hop and the plugin speaks the block's kind and depth, kept terse
("func", "loop", "if", "then", "else", "var", "depth 2"); a descending "beh"
buzzer means there's no block that way. Plain motions still work inside the
mode — `gg`, `G`, `/search`, `{`/`}` — and the tree re-attaches to the nearest
block where you land (so `gg` jumps you to the first node). `<Esc>` (or
`<leader>o` again) exits, leaving
the cursor where you navigated — so `<leader>l` then reads that line. Built on
treesitter, so it needs no LSP and works in any buffer with a parser.

**Auto-announce** — fires as you move/act. Toggle one with `<leader>t<key>`
(`tl` line, `tn` number, `td` diagnostics, `ti` indent, `tw` word, `tm` mode,
`ty` yank), each spoken back as "… on/off". Auto `ti` is a direction ping: a
rising tone when the new line is deeper, a falling tone when shallower — no
beep counting, just pitch. `<leader>t.` (or `<leader>.`)
toggles speaking punctuation — a global speech setting, not an auto-announce.

**Verbosity presets** — `<leader><leader>` cycles them; then tweak with the
toggles above.

| Preset | Auto-announces on a new line / event |
|--------|--------------------------------------|
| `minimal` | nothing — commands only |
| `normal` | line + diagnostics |
| `verbose` | line number + line + diagnostics + indent + mode |

The speech manager foundation is in place: one channel over `spd-say`, async,
cancel-first (interruptible), with a generation guard so fast navigation never
stacks stale utterances.

## Roadmap

Build order is dependency order. Each core feature addresses a specific,
evidence-backed friction point. (✓ done · ◐ partial · ○ not started)

### 0 — Speech manager (foundation, build first) — ◐
Single choke point: async spawn, interruptible queue, verbosity levels
(`off | minimal | normal | verbose`), panic-silence key, Orca coexistence.
Done: channel, async, cancel-first, verbosity presets, panic key. Pending:
per-utterance queueing beyond cancel, Orca coexistence tuning.

### MVP core

| # | State | Feature | Friction addressed | Neovim mechanism |
|---|-------|---------|--------------------|------------------|
| 1 | ◐ | **Mode / action feedback** — "insert", "normal", "saved", "N lines yanked" | no non-visual cue for mode/action (cheapest win) | `ModeChanged`, `BufWritePost`, `TextYankPost` |
| 2 | ✓ | **Cursor context on demand** — current line + line number + indent level | linear reading; lost position | keymap → `getline`/`line('.')`; debounced opt-in `CursorMoved` |
| 3 | ✓ | **Indent / scope depth** — "level 3", or pitch earcon by depth | indentation read as "space space space"; scope invisible | indent calc + treesitter node depth; pitch via espeak/piper |
| 4 | ◐ | **Structural navigation** — walk the file as a tree, speak each block | linear navigation, no overview (the big one) | treesitter node tree (LSP symbols later) |
| 5 | ✓ | **Diagnostics by voice** — "line N, error, <message>" | errors announced without location or type | `vim.diagnostic.get()` + `DiagnosticChanged` / `CursorHold` |
| 6 | ○ | **Statement marks** — bookmarks that track the statement, not the line number | lose your place when consulting other code | **extmarks** (`nvim_buf_set_extmark`) — shift with edits, unlike `:mark` |

Mode/action feedback (#1) is partial: mode and yank announce; **save**
(`BufWritePost`) is not wired yet.

### Deferred (v2+)
Debugger/DAP announcements, autocomplete announce, Git integration, AI-assistant
guardrails, polished sonification. Lower evidence or higher effort — out of the
initial scope.

## Configuration (planned)

A single entry point:

```lua
require("say-my-name").setup({
  backend   = "spd-say",     -- "spd-say" | "espeak-ng" | "piper"
  rate      = 350,           -- words per minute
  verbosity = "minimal",     -- off | minimal | normal | verbose
  speak     = {              -- which events announce
    mode = true, save = true, diagnostics = true,
  },
  -- keymaps for on-demand context, navigation, marks, panic-silence
})
```

## Status

Early development. Core on-demand commands, the auto-announce/verbosity layer,
and a first cut of tree navigation work (see [Implemented](#implemented));
richer structural navigation and statement marks are next. API and keymaps
still subject to change.

## Reference environment

- Ubuntu 24.04.2 LTS
- Neovim 0.12-dev
- speech-dispatcher / espeak-ng

## License

[MIT](LICENSE)
