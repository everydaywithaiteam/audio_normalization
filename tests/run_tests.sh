#!/usr/bin/env bash
# Test suite for yt_audio_norm.sh — covers the plan §7.9 checklist on small
# synthetic masters. Runs the script under /bin/bash (3.2) on purpose.
#
#   tests/run_tests.sh            # build fixtures (cached) and run everything
#   KEEP=1 tests/run_tests.sh     # leave the work folder behind for inspection
#
# The real-footage regression cases (v10 etc.) are in tests/regression.sh.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../yt_audio_norm.sh"
FIX="${FIXTURES:-${TMPDIR:-/tmp}/yt_audio_norm_fixtures}"
WORK=$(mktemp -d -t yt_audio_norm_tests)
export YT_AUDIO_NORM_NOTIFY_LOG="$WORK/notifications.txt"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"   # so stray temp files are visible
PASSED=0; FAILED=0; FAILS=""

[ -f "$FIX/long.mp4" ] || "$HERE/make_fixtures.sh" "$FIX" >/dev/null

ok()   { PASSED=$(( PASSED + 1 )); printf '  ✓ %s\n' "$1"; }
bad()  { FAILED=$(( FAILED + 1 )); FAILS="$FAILS  ✗ $1"$'\n'; printf '  ✗ %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# project <name> → creates "$WORK/<name> (test)/fcp_export", echoes project dir
project() { local p="$WORK/$1 (test)"; mkdir -p "$p/fcp_export" "$p/screen studio"; printf '%s' "$p"; }
# run <dir> [args…] → sets RC and OUTPUT
run() { local d="$1"; shift; OUTPUT=$(cd "$d" && /bin/bash "$SCRIPT" "$@" 2>&1); RC=$?; }
check_file() { ls "$1"/⚠️\ CHECK\ THIS* 2>/dev/null | head -1; }
no_temp_left() { [ -z "$(ls -A "$TMPDIR")" ]; }

echo "Work folder: $WORK"
echo; echo "Input resolution"
P=$(project "one"); cp "$FIX/normal.mp4" "$P/fcp_export/one-final.mp4"
cp "$FIX/quiet.mp4" "$P/fcp_export/older take.mp4"
echo 1 >"$P/fcp_export/one-final_SRT_English (United States).srt"
: >"$P/fcp_export/⚠️ CHECK THIS — one-final.txt"            # stale, must vanish
run "$P"
check "bare run from project folder processes it (exit 0)" '[ $RC = 0 ]'
check "output lands as one-final-normalized_audio.mp4" '[ -f "$P/fcp_export/one-final-normalized_audio.mp4" ]'
check "only *-final.mp4 picked (srt + other video ignored)" 'printf "%s" "$OUTPUT" | grep -q "Input: .*one-final.mp4"'
check "PASS run leaves no CHECK THIS file (stale one removed)" '[ -z "$(check_file "$P/fcp_export")" ]'
check "PASS banner printed" 'printf "%s" "$OUTPUT" | grep -q "✅ PASS"'
check "srt mentioned as ready to upload" 'printf "%s" "$OUTPUT" | grep -q "Captions ready.*United States).srt"'
check "PASS notification is silent" 'tail -1 "$YT_AUDIO_NORM_NOTIFY_LOG" | grep -q "^✅ Audio normalized|.*|$"'
check "output tagged with xattr" 'xattr -p com.sam.yt_audio_norm "$P/fcp_export/one-final-normalized_audio.mp4" | grep -q "\"status\":\"pass\""'
check "final within -14 ±0.5" 'printf "%s" "$OUTPUT" | awk "/^  Final/ { v = \$2 } END { exit !(v >= -14.5 && v <= -13.5) }"'
check "temp files cleaned up" 'no_temp_left'

n_before=$(wc -l <"$YT_AUDIO_NORM_NOTIFY_LOG")
run "$P"
check "re-run skips: exit 4, previous output excluded" '[ $RC = 4 ] && [ ! -e "$P/fcp_export/one-final-normalized_audio 2.mp4" ]'
check "skip does not write a CHECK THIS file" '[ -z "$(check_file "$P/fcp_export")" ]'
check "skip is quiet: SKIPPED banner, no notification" 'printf "%s" "$OUTPUT" | grep -q "⏭  SKIPPED" && [ "$(wc -l <"$YT_AUDIO_NORM_NOTIFY_LOG")" = "$n_before" ]'

run "$P" --force
check "--force processes anyway" '[ $RC = 0 ]'
check "collision → \" 2\" suffix" '[ -f "$P/fcp_export/one-final-normalized_audio 2.mp4" ]'
check "existing output untouched by collision" 'xattr -p com.sam.yt_audio_norm "$P/fcp_export/one-final-normalized_audio.mp4" >/dev/null'

run "$P/fcp_export" --force
check "bare run from inside fcp_export works the same" '[ $RC = 0 ] && [ -f "$P/fcp_export/one-final-normalized_audio 3.mp4" ]'

run "$WORK"
check "no fcp_export anywhere → exit 1, clear message" '[ $RC = 1 ] && printf "%s" "$OUTPUT" | grep -q "No fcp_export folder here"'

P2=$(project "two"); cp "$FIX/normal.mp4" "$P2/fcp_export/a-final.mp4"; cp "$FIX/normal.mp4" "$P2/fcp_export/b-final.mp4"
run "$P2"
check "two *-final.mp4 → exit 1, lists both" '[ $RC = 1 ] && printf "%s" "$OUTPUT" | grep -q "a-final.mp4" && printf "%s" "$OUTPUT" | grep -q "b-final.mp4"'
check "…and writes nothing" '[ $(ls "$P2/fcp_export" | wc -l) = 2 ]'

P3=$(project "none"); cp "$FIX/normal.mp4" "$P3/fcp_export/v10 - rough cut.mov"; cp "$FIX/normal.mp4" "$P3/fcp_export/semifinal.mp4"
run "$P3"
check "zero matches → exit 1, lists videos found" '[ $RC = 1 ] && printf "%s" "$OUTPUT" | grep -q "v10 - rough cut.mov"'
check "…'semifinal.mp4' is not taken for '*final'" 'printf "%s" "$OUTPUT" | grep -q "No \*final"'

P3b=$(project "fcp naming"); cp "$FIX/fcp.mov" "$P3b/fcp_export/v12 - final.mov"
run "$P3b"
check "bare run picks real FCP name 'v12 - final.mov'" '[ -f "$P3b/fcp_export/v12 - final-normalized_audio.mp4" ]'
cp "$FIX/normal.mp4" "$P3b/fcp_export/v12-final.mp4"
run "$P3b" --force
check "'v12 - final.mov' + 'v12-final.mp4' → two matches, exit 1" '[ $RC = 1 ] && printf "%s" "$OUTPUT" | grep -q "More than one"'

echo; echo "CLI"
run "$WORK" --help
check "--help exits 0" '[ $RC = 0 ]'
for d in "-14 LUFS" "-1.0 dBTP" "AAC 256k" "48000 Hz" "stereo" "copied, never re-encoded" "denoise          off" \
         "threshold -16dB, ratio 2, attack 20, release 300" "fcp_export/\*final.mp4 / \*final.mov" "normalized_audio.mp4"; do
  check "--help shows default: $d" 'printf "%s" "$OUTPUT" | grep -q -- "$d"'
done
run "$WORK" --bogus;           check "unknown option → exit 1" '[ $RC = 1 ]'
run "$WORK" -t abc x.mp4;      check "non-numeric --target → exit 1" '[ $RC = 1 ]'
run "$WORK" -b 256q x.mp4;     check "bad --bitrate → exit 1" '[ $RC = 1 ]'
run "$WORK" "$WORK/nope.mp4";  check "missing file → exit 1" '[ $RC = 1 ]'

echo; echo "Inputs"
P4=$(project "paths (with) spaces - and (parens)"); cp "$FIX/fcp.mov" "$P4/fcp_export/v10 - final (cut 2).mov"
run "$P4" "fcp_export/v10 - final (cut 2).mov"
OUT4="$P4/fcp_export/v10 - final (cut 2)-normalized_audio.mp4"
check "paths with spaces and parentheses (explicit path)" '[ $RC = 0 ] || [ $RC = 5 ]'
check ".mov input → .mp4 output" '[ -f "$OUT4" ]'
check "timecode track dropped (1 video + 1 audio only)" \
  '[ "$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$OUT4" | sort | tr "\n" " ")" = "audio video " ]'
check "video bit-identical" \
  '[ "$(ffmpeg -nostdin -loglevel error -i "$P4/fcp_export/v10 - final (cut 2).mov" -map 0:v:0 -c copy -f md5 -)" = "$(ffmpeg -nostdin -loglevel error -i "$OUT4" -map 0:v:0 -c copy -f md5 -)" ]'
check "audio is AAC 48 kHz stereo" \
  '[ "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 "$OUT4")" = "aac,48000,2" ]'
check "faststart (moov before mdat)" \
  '[ "$(ffprobe -v trace "$OUT4" 2>&1 | grep -oE "type:.(moov|mdat)" | head -1)" = "type:'"'"'moov" ]'

P5=$(project "prores"); cp "$FIX/prores.mov" "$P5/fcp_export/p-final.mov"
run "$P5" "fcp_export/p-final.mov"
check "ProRes → .mov output with a note" '[ -f "$P5/fcp_export/p-final-normalized_audio.mov" ] && printf "%s" "$OUTPUT" | grep -q "ProRes"'

P6=$(project "noaudio"); cp "$FIX/noaudio.mp4" "$P6/fcp_export/n-final.mp4"
run "$P6"
check "no audio stream → exit 1" '[ $RC = 1 ] && printf "%s" "$OUTPUT" | grep -q "no audio track"'
check "…FAIL writes a CHECK THIS file" '[ -n "$(check_file "$P6/fcp_export")" ]'
check "…FAIL notification has sound" 'tail -1 "$YT_AUDIO_NORM_NOTIFY_LOG" | grep -q "^❌.*|Basso$"'

P7=$(project "junk"); echo "not a video" >"$P7/fcp_export/j-final.mp4"
run "$P7"
check "unreadable input → exit 1" '[ $RC = 1 ]'

echo; echo "Warnings"
P8=$(project "quiet"); cp "$FIX/quiet.mp4" "$P8/fcp_export/q-final.mp4"
run "$P8"
# Drift is a note, not a flag: the output still lands on target (Sam, 2026-10-24).
check "pre-gain drift (+20 dB) → PASS with a note, exit 0" '[ $RC = 0 ] && printf "%s" "$OUTPUT" | grep -q "✅ PASS" && printf "%s" "$OUTPUT" | grep -q "Pre-gain was +.*TX +3 / RX +3"'
check "…no CHECK THIS file, silent notification" '[ -z "$(check_file "$P8/fcp_export")" ] && tail -1 "$YT_AUDIO_NORM_NOTIFY_LOG" | grep -q "^✅ Audio normalized|.*|$"'

P9=$(project "mixed"); cp "$FIX/mixed.mp4" "$P9/fcp_export/m-final.mp4"
run "$P9"
check "mixed sources → warning" 'printf "%s" "$OUTPUT" | grep -q "⚠️  WARN" && printf "%s" "$OUTPUT" | grep -q "Loudness swings a lot"'
CF=$(check_file "$P9/fcp_export")
check "WARN run writes one CHECK THIS file with plain-English fix" '[ -n "$CF" ] && grep -q "clip gain in FCP" "$CF"'
check "…and loudness map printed" 'printf "%s" "$OUTPUT" | grep -q "Loudness by minute"'
check "WARN notification has sound" 'tail -1 "$YT_AUDIO_NORM_NOTIFY_LOG" | grep -q "^⚠️ Check audio|.*|Basso$"'

# Raw OBS Studio takes (2026-10-24): ~+20 dB pre-gain is normal, and a wide
# LRA is one take with long pauses, not mixed sources.
P9o=$(project "obs"); cp "$FIX/obs.mp4" "$P9o/take 1.mp4"
run "$P9o" "take 1.mp4"
check "OBS take at +20 dB pre-gain → PASS, no pre-gain note" '[ $RC = 0 ] && printf "%s" "$OUTPUT" | grep -q "✅ PASS" && ! printf "%s" "$OUTPUT" | grep -q "Pre-gain was"'
check "…no CHECK THIS file" '[ -z "$(check_file "$P9o")" ]'
cp "$FIX/obs_wide.mp4" "$P9o/take 2.mp4"
run "$P9o" "take 2.mp4"
check "OBS take with wide LRA → PASS with a note, not a warning" '[ $RC = 0 ] && printf "%s" "$OUTPUT" | grep -q "✅ PASS" && printf "%s" "$OUTPUT" | grep -q "Loudness range is wide" && ! printf "%s" "$OUTPUT" | grep -q "Loudness swings a lot"'
run "$P9" --map
check "--map prints map and exits 0" '[ $RC = 0 ] && printf "%s" "$OUTPUT" | grep -q "00:00"'

P10=$(project "clipped"); cp "$FIX/clipped.mp4" "$P10/fcp_export/c-final.mp4"
run "$P10"
check "clipped at mic → warning, not abort" '[ -f "$P10/fcp_export/c-final-normalized_audio.mp4" ] && printf "%s" "$OUTPUT" | grep -q "clipped at the mic"'

P11=$(project "already"); cp "$FIX/already.mp4" "$P11/fcp_export/x-final.mp4"
run "$P11"
check "input already at -14 → exit 4 (measured, no state file)" '[ $RC = 4 ]'

echo; echo "Safety"
P12=$(project "dry"); cp "$FIX/normal.mp4" "$P12/fcp_export/d-final.mp4"; cp "$FIX/quiet.mp4" "$P12/fcp_export/note.mp4"
: >"$P12/fcp_export/⚠️ CHECK THIS — d-final.txt"
before=$(ls -la "$P12/fcp_export")
run "$P12" --dry-run
check "--dry-run exits 0 and reports chain" '[ $RC = 0 ] && printf "%s" "$OUTPUT" | grep -q "Chain"'
check "--dry-run writes nothing (folder unchanged)" '[ "$before" = "$(ls -la "$P12/fcp_export")" ]'

run "$P12" -k --force
check "--keep-stage1 keeps <name>-stage1.mp4" '[ -f "$P12/fcp_export/d-final-stage1.mp4" ]'

P13=$(project "disk"); cp "$FIX/normal.mp4" "$P13/fcp_export/s-final.mp4"
OUTPUT=$(cd "$P13" && YT_AUDIO_NORM_FREE_KB=1000 /bin/bash "$SCRIPT" 2>&1); RC=$?
check "insufficient disk space → clean abort before encoding" '[ $RC = 1 ] && printf "%s" "$OUTPUT" | grep -q "Not enough disk space" && [ ! -e "$P13/fcp_export/s-final-normalized_audio.mp4" ]'

P14=$(project "interrupt"); cp "$FIX/long.mp4" "$P14/fcp_export/i-final.mp4"
set -m
( cd "$P14" && exec /bin/bash "$SCRIPT" >"$WORK/int.out" 2>&1 ) &
pid=$!
set +m
# wait until stage 1 is being written, then Ctrl-C the whole process group
for _ in $(seq 1 600); do ls "$TMPDIR"/yt_audio_norm*/stage1.mp4 >/dev/null 2>&1 && break; sleep 0.1; done
sleep 0.3
kill -INT -- -"$pid" 2>/dev/null; wait "$pid"; RC=$?
check "Ctrl-C → exit 130" '[ $RC = 130 ]'
check "…temp files cleaned, no stage1 left" 'no_temp_left && [ -z "$(ls "$P14/fcp_export" | grep -v "^i-final.mp4$")" ]'

# External drive: a real separate volume via a disk image.
DMG="$WORK/ext.dmg"
if hdiutil create -quiet -size 200m -fs HFS+ -volname "YTNORMTEST" "$DMG" && \
   MNT=$(hdiutil attach -nobrowse "$DMG" 2>/dev/null | awk -F'\t' '/YTNORMTEST/ { print $NF }') && [ -n "$MNT" ]; then
  mkdir -p "$MNT/video 3 - ext/fcp_export"; cp "$FIX/normal.mp4" "$MNT/video 3 - ext/fcp_export/e-final.mp4"
  run "$MNT/video 3 - ext"
  check "input on an external drive" '[ $RC = 0 ] && [ -f "$MNT/video 3 - ext/fcp_export/e-final-normalized_audio.mp4" ]'
  check "…no .partial file left on the drive" '[ -z "$(ls -A "$MNT/video 3 - ext/fcp_export" | grep partial)" ]'
  hdiutil detach -quiet "$MNT" || true
else
  bad "input on an external drive (could not create disk image)"
fi

echo; echo "Several files (batch)"
B="$WORK/yt_shorts (batch)"; mkdir -p "$B"
cp "$FIX/normal.mp4" "$B/v10 1 first.mp4"; cp "$FIX/normal.mp4" "$B/v10 2 second (take).mp4"; cp "$FIX/noaudio.mp4" "$B/v10 3 broken.mp4"
YT_AUDIO_NORM_NOTIFY_LOG=/dev/null /bin/bash "$SCRIPT" "$B/v10 1 first.mp4" >/dev/null 2>&1   # already done before the batch
n_before=$(wc -l <"$YT_AUDIO_NORM_NOTIFY_LOG" 2>/dev/null || echo 0)
OUTPUT=$(cd "$B" && /bin/bash "$SCRIPT" *.mp4 missing.mp4 2>&1); RC=$?
check "batch continues past failures, exit = first failure code (1)" '[ $RC = 1 ]'
check "…processes each remaining file" '[ -f "$B/v10 2 second (take)-normalized_audio.mp4" ]'
check "…skips its own outputs (no *-normalized_audio-normalized_audio)" '! ls "$B" | grep -q "normalized_audio-normalized_audio" && printf "%s" "$OUTPUT" | grep -q "Skipping files this tool wrote"'
check "…already-done file is SKIP, not reprocessed" '[ ! -e "$B/v10 1 first-normalized_audio 2.mp4" ] && printf "%s" "$OUTPUT" | grep -q "SKIP.*v10 1 first.mp4"'
check "…summary counts" 'printf "%s" "$OUTPUT" | grep -q "Batch: 4 file(s) — 1 done, 1 skipped, 2 failed"'
check "…missing file listed as FAIL" 'printf "%s" "$OUTPUT" | grep -q "FAIL.*missing.mp4"'
check "…per-file CHECK THIS still written" '[ -f "$B/⚠️ CHECK THIS — v10 3 broken.txt" ]'
check "…exactly one notification, with sound" '[ $(( $(wc -l <"$YT_AUDIO_NORM_NOTIFY_LOG") - n_before )) = 1 ] && tail -1 "$YT_AUDIO_NORM_NOTIFY_LOG" | grep -q "^❌ Audio batch: 2 of 4 failed|.*|Basso$"'

OUTPUT=$(cd "$B" && /bin/bash "$SCRIPT" "v10 1 first.mp4" "v10 2 second (take).mp4" 2>&1); RC=$?
check "batch where every file is already done → exit 4" '[ $RC = 4 ]'
OUTPUT=$(cd "$B" && /bin/bash "$SCRIPT" *normalized_audio* 2>&1); RC=$?
check "only outputs given → exit 1, nothing to process" '[ $RC = 1 ] && printf "%s" "$OUTPUT" | grep -q "Nothing to process"'

B2="$WORK/batch ok"; mkdir -p "$B2"; cp "$FIX/normal.mp4" "$B2/a.mp4"; cp "$FIX/fcp.mov" "$B2/b.mov"
before=$(ls -la "$B2")
OUTPUT=$(cd "$B2" && /bin/bash "$SCRIPT" -n a.mp4 b.mov 2>&1); RC=$?
check "batch --dry-run (options replayed to each file) writes nothing" '[ $RC = 0 ] && [ "$before" = "$(ls -la "$B2")" ] && [ $(printf "%s" "$OUTPUT" | grep -c "Dry run — nothing written") = 2 ]'
OUTPUT=$(cd "$B2" && /bin/bash "$SCRIPT" a.mp4 b.mov 2>&1); RC=$?
check "batch all good → exit 0, both outputs" '[ $RC = 0 ] && [ -f "$B2/a-normalized_audio.mp4" ] && [ -f "$B2/b-normalized_audio.mp4" ]'
check "…✅ summary notification, silent" 'tail -1 "$YT_AUDIO_NORM_NOTIFY_LOG" | grep -q "^✅ Audio normalized: 2 file(s)|.*|$"'

B3="$WORK/batch interrupt"; mkdir -p "$B3"; cp "$FIX/long.mp4" "$B3/one.mp4"; cp "$FIX/long.mp4" "$B3/two.mp4"
set -m
( cd "$B3" && exec /bin/bash "$SCRIPT" one.mp4 two.mp4 >"$WORK/bint.out" 2>&1 ) &
pid=$!
set +m
for _ in $(seq 1 600); do ls "$TMPDIR"/yt_audio_norm.*/stage1.mp4 >/dev/null 2>&1 && break; sleep 0.1; done
sleep 0.3
kill -INT -- -"$pid" 2>/dev/null; wait "$pid"; RC=$?
check "Ctrl-C in a batch → exit 130, second file never started" '[ $RC = 130 ] && ! grep -q "\[2/2\]" "$WORK/bint.out"'
check "…no temp or partial files left" 'no_temp_left && [ "$(ls "$B3" | tr "\n" " ")" = "one.mp4 two.mp4 " ]'

echo; echo "Bash 3.2 compatibility"
check "no associative arrays / mapfile / \${var^^} / negative indices" \
  '! grep -vE "^[[:space:]]*#" "$SCRIPT" | grep -nE "declare -A|mapfile|readarray|\\$\\{[a-zA-Z_]+\\^\\^|\\[-1\\]"'

echo
printf 'Passed: %d   Failed: %d\n' "$PASSED" "$FAILED"
[ -n "$FAILS" ] && printf '%s' "$FAILS"
if [ "${KEEP:-0}" = 1 ]; then echo "Kept: $WORK"; else rm -rf "$WORK"; fi
[ "$FAILED" = 0 ]
