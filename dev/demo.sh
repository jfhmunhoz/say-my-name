#!/bin/sh
# say-my-name — one-shot demo bootstrap for testers.
#
# Clones the plugin into an ISOLATED Neovim profile (via NVIM_APPNAME) and opens
# it on the test file with every key mapping wired. It never touches your own
# ~/.config/nvim: config, data, state and shada all live under the separate
# "say-my-name-demo" app name, so nothing here can disturb your setup.
#
#   curl -fsSL https://raw.githubusercontent.com/jfhmunhoz/say-my-name/main/dev/demo.sh | sh
#
# Re-running updates the copy and relaunches. To remove it completely:
#   rm -rf ~/.local/share/say-my-name-demo ~/.local/state/say-my-name-demo \
#          ~/.config/say-my-name-demo ~/.cache/say-my-name-demo
set -eu

REPO="https://github.com/jfhmunhoz/say-my-name"
APP="say-my-name-demo"
DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP/src"

have() { command -v "$1" >/dev/null 2>&1; }
info() { printf '%s\n' "$*"; }
# Speak a line if we can, so a blind tester hears status without reading the term.
say()  { have spd-say && spd-say -w -- "$1" 2>/dev/null || true; }

# --- preflight: what's installed? --------------------------------------------
# Hard deps: neovim (>=0.10, for vim.system) and spd-say (speech-dispatcher).
# Sound: earcons need a WAV player (pw-play or aplay); without one, speech still
# works and only the pitch/buzzer cues go silent.
req=""
have nvim    || req="$req neovim"
have spd-say || req="$req speech-dispatcher"
snd=""
if ! have pw-play && ! have aplay; then snd="alsa-utils"; fi

# --- package manager detection (offer, never force) --------------------------
inst=""
if   have apt-get; then inst="sudo apt-get install -y"
elif have dnf;     then inst="sudo dnf install -y"
elif have pacman;  then inst="sudo pacman -S --noconfirm"
elif have zypper;  then inst="sudo zypper install -y"
fi

pkgs=$(echo $req $snd) # unquoted: collapse/trim whitespace
if [ -n "$pkgs" ]; then
  info ""
  info "Missing packages: $pkgs"
  [ -n "$req" ] && info "  (neovim + speech-dispatcher are required; the rest is for sound cues)"
  if [ -n "$inst" ]; then
    info ""
    info "Suggested install:  $inst $pkgs"
    printf 'Run it now (needs sudo)? [y/N] '
    read ans </dev/tty 2>/dev/null || ans=""
    case "$ans" in
      y|Y|yes|YES) $inst $pkgs || info "Install command failed; continuing." ;;
      *) info "Skipped install." ;;
    esac
  else
    info "No known package manager found. Install these manually: $pkgs"
  fi
fi

# --- hard-dep gate ------------------------------------------------------------
have nvim    || { info "neovim is still missing — cannot run the demo."; exit 1; }
have spd-say || { info "speech-dispatcher (spd-say) is still missing — cannot run the demo."; exit 1; }

ver=$(nvim --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
maj=${ver%%.*}; min=${ver#*.}
if [ "$maj" -eq 0 ] && [ "$min" -lt 10 ] 2>/dev/null; then
  info "Warning: Neovim $ver found, but this needs >= 0.10."
  info "  Get a newer build: https://github.com/neovim/neovim/releases"
fi
have lua-language-server || info "Tip: install lua-language-server to hear the diagnostics demo (<leader>d)."

# --- clone or update ----------------------------------------------------------
if [ -d "$DIR/.git" ]; then
  info "Updating demo copy in $DIR ..."
  git -C "$DIR" pull --ff-only || info "Update skipped (using existing copy)."
else
  info "Cloning say-my-name into $DIR ..."
  mkdir -p "$(dirname "$DIR")"
  git clone --depth 1 "$REPO" "$DIR"
fi

# --- launch, fully isolated ---------------------------------------------------
say "say my name demo ready. press space, then h, for help."
info ""
info "Launching. Leader is Space. Press <Space> h for the key list, <Space> b to"
info "blindfold the screen, and <Space> o for tree navigation. :q to quit."
exec env NVIM_APPNAME="$APP" nvim -u "$DIR/dev/init.lua" "$DIR/dev/test.lua"
