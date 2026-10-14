#!/usr/bin/env bash
# Installs yt_audio_norm: symlinks into ~/bin and adds the shell function to
# ~/.bashrc (idempotent — safe to re-run).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$HOME/bin"
ln -sf "$HERE/yt_audio_norm.sh" "$HOME/bin/yt_audio_norm.sh"
ln -sf "$HERE/README.md" "$HOME/bin/yt_audio_norm.README.md"
chmod +x "$HERE/yt_audio_norm.sh"
echo "Linked ~/bin/yt_audio_norm.sh → $HERE/yt_audio_norm.sh"

# macOS Terminal starts login shells, which read ~/.bash_profile, not ~/.bashrc.
if ! grep -qE '(\.|source) +~/\.bashrc|(\.|source) +"?\$HOME/\.bashrc' "$HOME/.bash_profile" 2>/dev/null; then
  printf '\n[ -f ~/.bashrc ] && . ~/.bashrc\n' >>"$HOME/.bash_profile"
  echo "Added: ~/.bash_profile now sources ~/.bashrc"
fi

if ! grep -q 'yt_audio_norm()' "$HOME/.bashrc" 2>/dev/null; then
  printf '\n# YouTube audio normalization — see ~/bin/yt_audio_norm.README.md\nyt_audio_norm() { ~/bin/yt_audio_norm.sh "$@"; }\n' >>"$HOME/.bashrc"
  echo "Added yt_audio_norm() to ~/.bashrc"
else
  echo "yt_audio_norm() already in ~/.bashrc"
fi

for dep in ffmpeg ffprobe jq; do
  command -v "$dep" >/dev/null 2>&1 || echo "Missing $dep — run: brew install ffmpeg jq"
done
echo "Done. Open a new Terminal window, then: cd <video project> && yt_audio_norm"
