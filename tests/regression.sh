#!/usr/bin/env bash
# Regression on real footage (plan §7.9). Originals are symlinked into a temp
# folder, so outputs land there and nothing is written beside the masters.
# v11 and v10 are DJI masters at TX +3 / RX +3; the 0 dB
# files still validate the chain; the OBS Shorts cover raw OBS recordings. Cases whose file is gone are skipped.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../yt_audio_norm.sh"
EWAI="${EWAI:-$HOME/Desktop/Everyday With AI}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/yt_audio_norm_regress.XXXXXX")
export YT_AUDIO_NORM_NO_NOTIFY=1
FAILED=0

# case <label> <filename> <exit> <pregain> <final LUFS> <final dBTP> <level> — level PASS also means no CHECK THIS file
case_() {
  local label="$1" src="$2" want_rc="$3" want_pg="$4" want_i="$5" want_tp="$6" want_lv="$7" d out rc pg fi ftp lv
  # Found by name anywhere under $EWAI, so reorganising folders doesn't break it.
  src=$(find "$EWAI" -type f -name "$src" -not -path "*/yt_audio_norm_*" 2>/dev/null | head -1)
  if [ -z "$src" ]; then echo "  - $label: skipped (not found under $EWAI: $2)"; return; fi
  d="$WORK/$label"; mkdir -p "$d"; ln -s "$src" "$d/$(basename "$src")"
  out=$(cd "$d" && /bin/bash "$SCRIPT" "$(basename "$src")" 2>&1); rc=$?
  pg=$(printf '%s\n' "$out" | awk '$1 == "Pre-gain" && $3 == "dB" { print $2 + 0 }')
  fi=$(printf '%s\n' "$out" | awk '$1 == "Final" { print $2 }')
  ftp=$(printf '%s\n' "$out" | awk '$1 == "Final" { print $4 }')
  lv=$(printf '%s\n' "$out" | awk '/^(✅ PASS|⚠️  WARN|❌ FAIL)/ { print $2 }' | tail -1)
  if [ "$lv" = "PASS" ] && ls "$d"/⚠️* >/dev/null 2>&1; then lv="PASS+CHECKFILE"; fi
  if [ "$rc" = "$want_rc" ] && [ "$lv" = "$want_lv" ] && awk -v a="$pg" -v b="$want_pg" -v c="$fi" -v d="$want_i" -v e="$ftp" -v f="$want_tp" \
       'BEGIN { exit !((a - b)^2 <= 0.01 && (c - d)^2 <= 0.04 && (e - f)^2 <= 0.04) }'; then
    printf '  ✓ %-34s exit %s  %s  pre-gain %+.2f  %s LUFS / %s dBTP\n' "$label" "$rc" "$lv" "$pg" "$fi" "$ftp"
  else
    FAILED=1
    printf '  ✗ %-34s got exit %s %s, pre-gain %s, %s / %s — want %s %s, %s, %s / %s\n' "$label" "$rc" "$lv" "$pg" "$fi" "$ftp" "$want_rc" "$want_lv" "$want_pg" "$want_i" "$want_tp"
  fi
}

echo "Regression (outputs in $WORK)"
case_ "v11 - fcp export (+3/+3)" "video 11 - 5 Claude Features You Should Be Using - screen studio - fcp export.mov" 5 7.29 -14.86 -1.38 PASS   # under target, nothing to do
case_ "v10 - final (+3/+3)" "v10 - final.mov" 5 6.96 -14.8 -1.4 PASS   # under target, but nothing to do
case_ "part1 w CC (0 dB)" "video 9 - claude memory - part1 w CC and transcript.mp4" 0 20.19 -14.1 -1.3 PASS   # plan rounds pre-gain to "+20"; 0 dB-era gain → drift note only (2026-10-24)
case_ "final fcp export (0 dB)" "video 9 - claude memory - final fcp export.mov" 5 23.8 -15.7 -1.4 PASS   # drift note only (+23.8)
# Raw OBS Studio Shorts, DJI at TX +3 / RX +3 (2026-10-24): pre-gain ~+19–21, now outside the MV7+ range → drift note only.
case_ "OBS short 1 (wide LRA)" "1 Tina luck - Short_2026-10-24 08-51-45.mp4" 0 18.69 -14.0 -1.0 PASS   # 21.6 LU from a mostly-empty take → note
case_ "OBS short 11" "11 Tina luck - Short_2026-10-24 09-00-15.mp4" 5 19.64 -15.6 -1.44 PASS   # 1.6 LU under, nothing to do
# Raw OBS Studio Shorts, Shure MV7+ (2026-11-16): pre-gain ~+1.3–1.7 is normal.
case_ "MV7+ short 1" "v14 1 - Short_2026-11-16 09-37-25.mp4" 5 1.27 -14.55 -1.39 PASS   # 0.55 under, nothing to do
case_ "MV7+ short 2 (one spike)" "v14 2 - Short_2026-11-16 09-40-53.mp4" 5 1.46 -14.52 -1.41 PASS   # one 0 dBFS transient → note, not "clipped"
[ "${KEEP:-0}" = 1 ] && echo "Kept: $WORK" || rm -rf "$WORK"
exit "$FAILED"
