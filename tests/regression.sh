#!/usr/bin/env bash
# Regression on real footage (plan §7.9). Originals are symlinked into a temp
# folder, so outputs land there and nothing is written beside the masters.
# v10 is the primary case — the only one recorded at current mic settings.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../yt_audio_norm.sh"
EWAI="${EWAI:-$HOME/Desktop/Everyday With AI}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/yt_audio_norm_regress.XXXXXX")
export YT_AUDIO_NORM_NO_NOTIFY=1
FAILED=0

# case <label> <path> <exit> <pregain> <final LUFS> <final dBTP>
case_() {
  local label="$1" src="$2" want_rc="$3" want_pg="$4" want_i="$5" want_tp="$6" d out rc pg fi ftp
  if [ ! -f "$src" ]; then echo "  - $label: skipped (not found: $src)"; return; fi
  d="$WORK/$label"; mkdir -p "$d"; ln -s "$src" "$d/$(basename "$src")"
  out=$(cd "$d" && /bin/bash "$SCRIPT" "$(basename "$src")" 2>&1); rc=$?
  pg=$(printf '%s\n' "$out" | awk '$1 == "Pre-gain" { print $2 + 0 }')
  fi=$(printf '%s\n' "$out" | awk '$1 == "Final" { print $2 }')
  ftp=$(printf '%s\n' "$out" | awk '$1 == "Final" { print $4 }')
  if [ "$rc" = "$want_rc" ] && awk -v a="$pg" -v b="$want_pg" -v c="$fi" -v d="$want_i" -v e="$ftp" -v f="$want_tp" \
       'BEGIN { exit !((a - b)^2 <= 0.01 && (c - d)^2 <= 0.04 && (e - f)^2 <= 0.04) }'; then
    printf '  ✓ %-34s exit %s  pre-gain %+.2f  %s LUFS / %s dBTP\n' "$label" "$rc" "$pg" "$fi" "$ftp"
  else
    FAILED=1
    printf '  ✗ %-34s got exit %s, pre-gain %s, %s / %s — want %s, %s, %s / %s\n' "$label" "$rc" "$pg" "$fi" "$ftp" "$want_rc" "$want_pg" "$want_i" "$want_tp"
  fi
}

echo "Regression (outputs in $WORK)"
case_ "v10 - final (+3/+3)" "$EWAI/videos/video 10 - claude chat cowork merging/fcp_export/v10 - final.mov" 5 6.96 -14.8 -1.4
case_ "part1 w CC (0 dB)" "$EWAI/video 9 - claude memory/screen studio/video 9 - claude memory - part1 w CC and transcript.mp4" 0 20.19 -14.1 -1.3   # plan rounds pre-gain to "+20"
case_ "final fcp export (0 dB)" "$EWAI/video 9 - claude memory/fcp/video 9 - claude memory - final fcp export.mov" 5 23.8 -15.7 -1.4
[ "${KEEP:-0}" = 1 ] && echo "Kept: $WORK" || rm -rf "$WORK"
exit "$FAILED"
