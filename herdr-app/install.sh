#!/bin/sh
# Installs the Pad Arcade layout, its `pad` mod (with the bundled herdr-pad
# controller helper) and the herdr-pad theme into the Herdr app.
# Usage: ./install.sh [--switch] [--home <herdr-app home>]
#   --switch   show the layout right away (needs the Herdr app running)
#   --home     install somewhere other than $HERDR_APP_HOME or ~/.config/herdr-app
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
home="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
switch=0
while [ $# -gt 0 ]; do
  case "$1" in
    --switch) switch=1 ;;
    --home) shift; home="$1" ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || { echo "Pad Arcade's controller helper runs on macOS only." >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || warn "The bundled helper is built for Apple Silicon. On Intel, rebuild it with 'make helper'."
[ -d "$home" ] || warn "$home does not exist yet. Open the Herdr app once, or pass --home."

say "Installing Pad Arcade into $home"
mkdir -p "$home/layouts" "$home/mods" "$home/themes"
cp "$here/layouts/pad-arcade.json" "$here/layouts/pad-arcade.svg" "$home/layouts/"
cp "$here/themes/herdr-pad.json" "$home/themes/"
# Replace only our own mod folder; keep the type files Herdr writes into it.
mkdir -p "$home/mods/pad"
rsync -a --delete --exclude 'gpui-kit.d.ts' --exclude 'herdr.d.ts' --exclude 'jsconfig.json' \
  "$here/mods/pad/" "$home/mods/pad/"
chmod +x "$home/mods/pad/herdr-pad"
say "  layout  layouts/pad-arcade.json"
say "  mod     mods/pad (helper: mods/pad/herdr-pad)"
say "  theme   themes/herdr-pad.json"

if command -v herdr-app >/dev/null 2>&1; then
  HERDR_APP_HOME="$home" herdr-app check "$home/mods/pad"
else
  warn "herdr-app is not on PATH, so the mod was not checked. Open the Herdr app once to install it."
fi

# Voice prompts are transcribed locally with whisper.cpp.
model="${WHISPER_MODEL:-$HOME/.local/share/whisper/ggml-large-v3-turbo-q5_0.bin}"
command -v python3 >/dev/null 2>&1 || warn "python3 is missing (voice prompts need it)."
command -v whisper-cli >/dev/null 2>&1 || warn "whisper-cli is missing: brew install whisper-cpp"
[ -f "$model" ] || warn "No Whisper model at $model. Download one, for example:
      mkdir -p ~/.local/share/whisper && curl -L -o $model \\
        https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

if [ "$switch" = 1 ] && command -v herdr-app >/dev/null 2>&1; then
  HERDR_APP_HOME="$home" herdr-app do layout.switch '{"name":"pad-arcade"}' >/dev/null && say "Switched to Pad Arcade."
else
  say "Pick 'pad-arcade' with ctrl-shift-l or in Settings → Look."
fi
