#!/usr/bin/env bash
# yt_audio_norm — normalize a Final Cut Pro master's audio for YouTube.
#
# Pipeline: DJI Mic 2 → Screen Studio (Enhance off) → FCP → this → YouTube,
# or DJI Mic 2 → OBS Studio → this (raw OBS recordings, e.g. Shorts).
# Two-pass loudnorm behind a pre-gain / compressor / limiter chain, then a
# static volume correction only if headroom allows. Video is never re-encoded.
#
# Written for macOS system bash 3.2: no associative arrays, no ${var^^},
# no mapfile, no negative indices, no empty-array expansion under set -u.
# Full rationale for every setting lives in README.md and the build plan.

set -euo pipefail

VERSION="1.3.0"

# ── Defaults (all baked in; running bare is the intended use) ─────────────────
TARGET_I="-14"            # integrated loudness, LUFS
PEAK_CEIL="-1.0"          # true peak ceiling, dBTP
BITRATE="256k"
SAMPLE_RATE="48000"
LRA_TARGET="11"
WORK_LEVEL="-21"          # pre-gain lifts the source to this before the chain
TOLERANCE="0.5"           # ± LU around target that counts as on-target
SKIP_CORRECTION="0.3"     # |delta| below this: stage 1 is final
MAX_DELTA="6"             # |delta| above this: something upstream is wrong
EXPECTED_SHORTFALL="3"    # stage 1 normally lands 0.8–3 LU under when headroom runs out (plan §5)
PREGAIN_MIN="-10"         # hard abort range
PREGAIN_MAX="32"
PREGAIN_OK_MIN="4"        # expected range at TX +3 / RX +3 (plan §3)
PREGAIN_OK_MAX="15"
# OBS records the same mic ~10 dB quieter: +18.7…+21.3 across 12 Shorts on
# 2026-10-24 at TX +3 / RX +3.
OBS_PREGAIN_OK_MIN="15"
OBS_PREGAIN_OK_MAX="25"
MIXED_LRA="12"            # raw LRA above this on talking head = mixed sources
HIGHPASS="highpass=f=80"
# No makeup gain: with fast attack it overshot to +4.5 dBTP (plan §6 rule 4).
COMPRESSOR="acompressor=threshold=-16dB:ratio=2:attack=20:release=300"
# level=disabled: the default auto-levels back to 0 dBFS and erases the
# headroom the limiter just created (plan §6 rule 1).
LIMITER="alimiter=limit=0.7:level=disabled"
DENOISE_FILTER="afftdn=nr=10:nf=-55:tn=1"   # above nr=15 speech turns watery
SILENCE_FILTER="silencedetect=noise=-40dB:d=2"
XATTR_KEY="com.sam.yt_audio_norm"
LOG_DIR="$HOME/Library/Logs/yt_audio_norm"
INPUT_DIR_NAME="fcp_export"
# Name ends in "final" after -, _ or space, .mp4 or .mov, any case:
# "v12-final.mp4", "v10 - final.mov", "final.mp4". Plan §7.2 said *-final.mp4
# only; widened 2026-10-14 because real FCP exports are named "v10 - final.mov".
INPUT_PATTERN="*final.mp4 / *final.mov"   # display only; the globs are inline below

# ── Options ──────────────────────────────────────────────────────────────────
DENOISE=0; MAP_ONLY=0; FORCE=0; DRY_RUN=0; KEEP_STAGE1=0; VERBOSE=0
FILE_ARG=""
FILES=(); NFILES=0       # every file argument (batch mode when > 1)
OPTS=()                   # option arguments, replayed to each batch child

# ── Run state ────────────────────────────────────────────────────────────────
LOG="/dev/null"
TMP=""
PARTIAL=""                # final output being written; removed if we die
INPUT=""; OUTDIR=""; BASE=""; OUT_EXT="mp4"; OUT=""
CHECK_FILE=""
DUR_US=0
ISSUES=""                 # one "• problem — fix" per line
NOTES=""
LEVEL="PASS"
MAP_TEXT=""
SILENCE_TEXT=""
RAW_I=""; RAW_TP=""; RAW_LRA=""; RAW_PEAK=""
CH_I=""; CH_TP=""; CH_LRA=""; CH_THRESH=""
S1_I=""; S1_TP=""; S1_LRA=""
F_I=""; F_TP=""; F_LRA=""
PREGAIN=""; CORRECTION_TEXT=""
SOURCE="fcp"              # "obs" for a raw OBS Studio recording (encoder tag)

usage() {
  cat <<EOF
yt_audio_norm $VERSION — normalize a Final Cut Pro master's audio for YouTube

Usage: yt_audio_norm [OPTIONS] [FILE…]

Normal use: cd to the video project folder, run yt_audio_norm. No arguments.
Several files: yt_audio_norm *.mp4 — each is processed in turn, then one summary.
  Files this tool wrote (*-normalized_audio*, *-stage1*) are skipped automatically.

Defaults (all baked in — running bare is the intended use):
  input            ./$INPUT_DIR_NAME/$INPUT_PATTERN  (or . if already inside $INPUT_DIR_NAME/)
  output           <input>-normalized_audio.mp4, same folder (.mov for ProRes)
                   never overwrites: adds " 2", " 3"… on collision
  target           $TARGET_I LUFS  (±$TOLERANCE)
  peak ceiling     $PEAK_CEIL dBTP
  audio            AAC $BITRATE, $SAMPLE_RATE Hz, stereo
  video            copied, never re-encoded
  denoise          off  ($DENOISE_FILTER when on)
  pre-gain         computed per file to reach $WORK_LEVEL LUFS; usual +$PREGAIN_OK_MIN…+$PREGAIN_OK_MAX dB (OBS +$OBS_PREGAIN_OK_MIN…+$OBS_PREGAIN_OK_MAX)
  chain            $HIGHPASS
                   $COMPRESSOR
                   $LIMITER
                   loudnorm I=target TP=ceiling-0.5 LRA=$LRA_TARGET (two-pass)
                   then a static volume correction only if peaks stay under the ceiling
  compressor       threshold -16dB, ratio 2, attack 20, release 300
  logs             $LOG_DIR/

Options:
  -t, --target LUFS    Override integrated target
  -p, --peak DBTP      Override true peak ceiling
  -b, --bitrate RATE   Override AAC bitrate (e.g. 320k)
      --denoise        Add afftdn before pre-gain
      --map            Print per-minute loudness map and exit
  -f, --force          Process even if already within tolerance / already done
  -n, --dry-run        Measure and report, write nothing
  -k, --keep-stage1    Keep the intermediate file (<name>-stage1.mp4)
  -v, --verbose        Show full ffmpeg output
  -h, --help           Print this

Exit codes:
  0 success   1 bad usage or input   2 missing dependency   3 ffmpeg failure
  4 skipped, already normalized      5 shipped stage 1, headroom exhausted
  Several files: the first failure code if any failed, else 5 if any shipped
  under target, else 0 — or 4 if every file was skipped.

When anything needs attention, a "⚠️ CHECK THIS — <name>.txt" file appears
next to the input. No such file means a clean run.
EOF
}

# ── Small helpers ────────────────────────────────────────────────────────────
log() { printf '%s\n' "$*" >>"$LOG"; }
say() { printf '%s\n' "$*"; log "$*"; }
warn_issue() { ISSUES="${ISSUES}• $1"$'\n'; [ "$LEVEL" = "FAIL" ] || LEVEL="WARN"; log "ISSUE: $1"; }
note() { NOTES="${NOTES}  $1"$'\n'; log "NOTE: $1"; }

# Float math via awk (no bc dependency).
calc() { awk "BEGIN { printf \"%.2f\", $1 }"; }
is_num() { case "$1" in ''|*[!0-9.+-]*) return 1 ;; *) awk -v x="$1" 'BEGIN { exit !(x == x + 0) }' ;; esac; }
f_le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }
f_lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
f_abs() { awk -v a="$1" 'BEGIN { printf "%.2f", (a < 0 ? -a : a) }'; }
signed() { awk -v a="$1" 'BEGIN { printf "%+.2f", a }'; }
mmss() { awk -v s="$1" 'BEGIN { s = int(s + 0.5); printf "%02d:%02d", int(s / 60), s % 60 }'; }

free_kb() { df -Pk "$1" | awk 'NR == 2 { print $4 }'; }
mount_of() { df -P "$1" | awk 'NR == 2 { print $NF }'; }

notify() { # notify <title> <message> [sound]
  log "notify: $1 — $2 ${3:+[sound: $3]}"
  # Batch children stay quiet; the batch sends one summary notification.
  [ "${YT_AUDIO_NORM_BATCH_CHILD:-0}" = "1" ] && return 0
  # Test hooks: record instead of showing, or suppress entirely.
  if [ -n "${YT_AUDIO_NORM_NOTIFY_LOG:-}" ]; then printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >>"$YT_AUDIO_NORM_NOTIFY_LOG"; return 0; fi
  [ "${YT_AUDIO_NORM_NO_NOTIFY:-0}" = "1" ] && return 0
  command -v osascript >/dev/null 2>&1 || return 0
  # Pass text as argv so quotes in filenames can't break the AppleScript.
  osascript - "$1" "$2" "${3:-}" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  if item 3 of argv is "" then
    display notification (item 2 of argv) with title (item 1 of argv)
  else
    display notification (item 2 of argv) with title (item 1 of argv) sound name (item 3 of argv)
  end if
end run
APPLESCRIPT
}

cleanup() {
  [ -n "$PARTIAL" ] && rm -f "$PARTIAL"
  [ -n "$TMP" ] && rm -rf "$TMP"
  return 0
}

on_interrupt() {
  trap - INT TERM HUP
  printf '\n%s\n' "Interrupted — temp files removed, nothing written." >&2
  log "INTERRUPTED"
  exit 130
}

# Progress meter: consumes ffmpeg -progress key=value lines on stdin.
progress() {
  local label="$1" k v pct last=-1 show=0
  [ -t 2 ] && [ "$DUR_US" -gt 0 ] && show=1
  while IFS='=' read -r k v; do
    [ "$show" = 1 ] || continue
    case "$k" in
      out_time_us)
        case "$v" in ''|*[!0-9]*) continue ;; esac
        pct=$(( v * 100 / DUR_US )); [ "$pct" -gt 100 ] && pct=100
        if [ "$pct" != "$last" ]; then printf '\r  %-22s %3d%%' "$label" "$pct" >&2; last=$pct; fi ;;
      progress) [ "$v" = "end" ] && printf '\r  %-22s %3d%%\n' "$label" 100 >&2 ;;
    esac
  done
  return 0
}

# ff <label> <stderr-capture> <ffmpeg args…> — runs ffmpeg, quiet by default.
ff() {
  local label="$1" errf="$2" rc=0; shift 2
  log "+ ffmpeg $*"
  if [ "$VERBOSE" = 1 ]; then
    ffmpeg -hide_banner -nostdin "$@" 2>&1 | tee "$errf" >&2 || rc=$?
  else
    ffmpeg -hide_banner -nostdin -nostats -progress pipe:1 "$@" 2>"$errf" | progress "$label" || rc=$?
  fi
  cat "$errf" >>"$LOG"
  return $rc
}

# Pull the last loudnorm JSON block out of an ffmpeg stderr capture.
loudnorm_json() {
  awk '/^\{/ { buf = ""; on = 1 } on { buf = buf $0 "\n" } /^\}/ { on = 0; last = buf } END { printf "%s", last }' "$1"
}

# measure <file> <prefilter-or-empty> <label> — sets M_I M_TP M_LRA M_THRESH.
# Always -vn: skipping the 4K decode is ~5× faster with identical numbers.
M_I=""; M_TP=""; M_LRA=""; M_THRESH=""; M_ERR=""
measure() {
  local f="$1" pre="$2" label="$3" json
  M_ERR="$TMP/measure.$RANDOM.txt"
  local tp_target; tp_target=$(calc "$PEAK_CEIL - 0.5")
  ff "$label" "$M_ERR" -i "$f" -vn -map 0:a:0 \
     -af "${pre:+$pre,}loudnorm=I=$TARGET_I:TP=$tp_target:LRA=$LRA_TARGET:print_format=json" \
     -f null /dev/null || fail 3 "ffmpeg failed while measuring ($label)." "Re-run with --verbose to see the ffmpeg error."
  json=$(loudnorm_json "$M_ERR")
  [ -n "$json" ] || fail 3 "Could not read loudness measurement ($label)." "Re-run with --verbose and check the log: $LOG"
  M_I=$(jq -r '.input_i' <<<"$json")
  M_TP=$(jq -r '.input_tp' <<<"$json")
  M_LRA=$(jq -r '.input_lra' <<<"$json")
  M_THRESH=$(jq -r '.input_thresh' <<<"$json")
  log "measure[$label]: I=$M_I TP=$M_TP LRA=$M_LRA thresh=$M_THRESH"
}

# Per-minute integrated loudness. A 10+ LU jump between minutes = mismatched part.
build_map() {
  local dur_s s prev="" line i mark errf
  dur_s=$(( DUR_US / 1000000 ))
  MAP_TEXT=""
  errf="$TMP/map.txt"
  s=0
  while [ "$s" -le "$dur_s" ]; do
    ffmpeg -hide_banner -nostdin -ss "$s" -t 60 -i "$INPUT" -vn -map 0:a:0 -af ebur128 -f null /dev/null 2>"$errf" \
      || fail 3 "ffmpeg failed while building the loudness map." "Re-run with --verbose."
    i=$(awk '$1 == "I:" { v = $2 } END { print v }' "$errf")
    [ -z "$i" ] && i="-70.0"
    mark=""
    if [ -n "$prev" ] && awk -v a="$i" -v b="$prev" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d >= 10) }'; then
      mark="   ◀ jump"
    fi
    line=$(printf '  %s  %6s LUFS%s' "$(mmss "$s")" "$i" "$mark")
    MAP_TEXT="${MAP_TEXT}${line}"$'\n'
    prev="$i"
    s=$(( s + 60 ))
    [ "$s" -ge "$dur_s" ] && break
  done
  log "loudness map:"; log "$MAP_TEXT"
}

# Next free path: <stem><ext>, <stem> 2<ext>, <stem> 3<ext>…
free_path() {
  local stem="$1" ext="$2" n=2 p
  p="$stem.$ext"
  while [ -e "$p" ]; do p="$stem $n.$ext"; n=$(( n + 1 )); done
  printf '%s' "$p"
}

row() { # row <label> <I> <TP> <LRA>
  local i="${2:-}" tp="${3:-}" lra="${4:-}"
  [ -n "$i" ] && i="$i LUFS"; [ -n "$tp" ] && tp="$tp dBTP"; [ -n "$lra" ] && lra="$lra LU"
  printf '  %-14s %-14s %-14s %s\n' "$1" "$i" "$tp" "$lra"
}

loudness_table() {
  printf '  %-14s %-14s %-14s %s\n' "" "Integrated" "True peak" "LRA"
  [ -n "$RAW_I" ] && row "Raw" "$RAW_I" "$RAW_TP" "$RAW_LRA"
  [ -n "$PREGAIN" ] && printf '  %-14s %s dB\n' "Pre-gain" "$(signed "$PREGAIN")"
  [ -n "$CH_I" ] && row "Chain" "$CH_I" "$CH_TP" "$CH_LRA"
  [ -n "$S1_I" ] && row "Stage 1" "$S1_I" "$S1_TP" "$S1_LRA"
  [ -n "$CORRECTION_TEXT" ] && printf '  %-14s %s\n' "Correction" "$CORRECTION_TEXT"
  [ -n "$F_I" ] && row "Final" "$F_I" "$F_TP" "$F_LRA"
  return 0
}

# finish <exit-code> — the one place a run ends after input is resolved.
finish() {
  local code="$1" banner title msg sound="" report
  case "$LEVEL" in
    PASS) banner="✅ PASS" ;;
    WARN) banner="⚠️  WARN" ;;
    FAIL) banner="❌ FAIL" ;;
    SKIP) banner="⏭  SKIPPED" ;;
  esac
  report=$(
    printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    printf '%s   %s\n' "$banner" "${INPUT:+$(basename "$INPUT")}"
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    if [ -n "$RAW_I" ]; then printf '\n'; loudness_table; fi
    if [ -n "$ISSUES" ]; then printf '\nWhat needs attention:\n%s' "$ISSUES"; fi
    if [ -n "$MAP_TEXT" ] && [ "$MAP_ONLY" = 0 ]; then printf '\nLoudness by minute:\n%s' "$MAP_TEXT"; fi
    if [ -n "$NOTES" ]; then printf '\nNotes:\n%s' "$NOTES"; fi
    if [ -n "$OUT" ] && [ -e "$OUT" ]; then printf '\nUpload: %s\n' "$OUT"; fi
    if [ "$DRY_RUN" = 1 ]; then printf '\nDry run — nothing written.\n'; fi
  )
  printf '%s\n' "$report"
  log "$report"
  log "EXIT $code LEVEL $LEVEL"
  if [ -n "${YT_AUDIO_NORM_RESULT_FILE:-}" ]; then   # one line per file for the batch summary; \037 (unit separator) because tab
    # is IFS whitespace and would collapse the empty fields of a FAIL
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$code" "$LEVEL" "${F_I:-}" "${F_TP:-}" \
      "$(basename "${INPUT:-?}")" "$(first_issue)" >>"$YT_AUDIO_NORM_RESULT_FILE" 2>/dev/null || true
  fi

  # The problem-only sidecar. Its presence is the signal; a clean folder = clean run.
  if { [ "$LEVEL" = "WARN" ] || [ "$LEVEL" = "FAIL" ]; } && [ -n "$CHECK_FILE" ] && [ "$DRY_RUN" = 0 ]; then
    {
      printf 'yt_audio_norm — %s — %s\n' "$LEVEL" "$(date '+%Y-%m-%d %H:%M')"
      printf 'Input: %s\n' "$INPUT"
      [ -n "$OUT" ] && [ -e "$OUT" ] && printf 'Output: %s\n' "$OUT"
      printf '\nWhat needs attention:\n%s' "$ISSUES"
      if [ -n "$RAW_I" ]; then printf '\nLoudness:\n'; loudness_table; fi
      [ -n "$MAP_TEXT" ] && printf '\nLoudness by minute:\n%s' "$MAP_TEXT"
      printf '\nFull log: %s\n' "$LOG"
      printf 'Delete this file once you have dealt with it.\n'
    } >"$CHECK_FILE" 2>/dev/null || true
  fi

  # A skip changed nothing and needs nothing, so it doesn't notify.
  if [ "$DRY_RUN" = 0 ] && [ "$MAP_ONLY" = 0 ] && [ "$LEVEL" != "SKIP" ]; then
    case "$LEVEL" in
      PASS) title="✅ Audio normalized"; msg="${F_I:-?} LUFS, ${F_TP:-?} dBTP" ;;
      WARN) title="⚠️ Check audio"; sound="Basso"
            msg=$(first_issue) ;;
      FAIL) title="❌ Audio normalization failed"; sound="Basso"
            msg=$(first_issue) ;;
    esac
    notify "$title" "$msg" "$sound"
  fi
  exit "$code"
}

first_issue() { printf '%s' "$ISSUES" | awk 'NR == 1 { sub(/^• /, ""); print substr($0, 1, 120) }'; }

# fail <exit-code> <problem> <fix>
fail() {
  LEVEL="FAIL"
  ISSUES="${ISSUES}• $2 $3"$'\n'
  log "FAIL: $2 $3"
  finish "$1"
}

# Usage/setup errors before an input exists: no sidecar, no notification.
die_early() { printf '❌ %s\n' "$2" >&2; log "EARLY EXIT $1: $2"; exit "$1"; }

# ── Argument parsing ─────────────────────────────────────────────────────────
need_val() { [ $# -ge 2 ] && [ -n "$2" ] || die_early 1 "$1 needs a value. See --help."; }
while [ $# -gt 0 ]; do
  case "$1" in
    -t|--target)  need_val "$@"; TARGET_I="$2"; OPTS+=("$1" "$2"); shift 2 ;;
    --target=*)   TARGET_I="${1#*=}"; OPTS+=("$1"); shift ;;
    -p|--peak)    need_val "$@"; PEAK_CEIL="$2"; OPTS+=("$1" "$2"); shift 2 ;;
    --peak=*)     PEAK_CEIL="${1#*=}"; OPTS+=("$1"); shift ;;
    -b|--bitrate) need_val "$@"; BITRATE="$2"; OPTS+=("$1" "$2"); shift 2 ;;
    --bitrate=*)  BITRATE="${1#*=}"; OPTS+=("$1"); shift ;;
    --denoise)    DENOISE=1; OPTS+=("$1"); shift ;;
    --map)        MAP_ONLY=1; OPTS+=("$1"); shift ;;
    -f|--force)   FORCE=1; OPTS+=("$1"); shift ;;
    -n|--dry-run) DRY_RUN=1; OPTS+=("$1"); shift ;;
    -k|--keep-stage1) KEEP_STAGE1=1; OPTS+=("$1"); shift ;;
    -v|--verbose) VERBOSE=1; OPTS+=("$1"); shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; while [ $# -gt 0 ]; do FILES+=("$1"); NFILES=$(( NFILES + 1 )); shift; done ;;
    -*)           die_early 1 "Unknown option: $1. See --help." ;;
    *)            FILES+=("$1"); NFILES=$(( NFILES + 1 )); shift ;;
  esac
done
[ "$NFILES" -eq 1 ] && FILE_ARG="${FILES[0]}"

is_num "$TARGET_I" || die_early 1 "--target must be a number (e.g. -14), got '$TARGET_I'."
is_num "$PEAK_CEIL" || die_early 1 "--peak must be a number (e.g. -1.0), got '$PEAK_CEIL'."
case "$BITRATE" in ''|[kK]*|*[!0-9kK]*|*[kK]?*) die_early 1 "--bitrate must look like 256k, got '$BITRATE'." ;; esac

# ── Dependencies ─────────────────────────────────────────────────────────────
missing=""
for dep in ffmpeg ffprobe jq awk xattr df; do
  command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
done
if [ -n "$missing" ]; then
  printf '❌ FAIL — missing:%s\n   Install with: brew install ffmpeg jq\n' "$missing" >&2
  notify "❌ Audio normalization failed" "Missing:$missing" "Basso"
  exit 2
fi

# ── Several files: one child run per file, then one summary ──────────────────
# Added 2026-10-16 for folders of Shorts (plan §7 is one file per run). Each
# file runs as its own child process so every single-file guarantee — temp
# cleanup, CHECK THIS sidecar, skip detection, never overwriting — holds
# unchanged. A failure doesn't stop the batch; Ctrl-C does.
is_own_output() {
  case "$(basename "$1")" in
    *-normalized_audio.*|*-normalized_audio\ [0-9]*.*|*-stage1.*|*-stage1\ [0-9]*.*|"⚠️ CHECK THIS"*) return 0 ;;
  esac
  return 1
}

run_batch() {
  local results f i=0 n rc code level f_i f_tp name issue line worst_fail="" any5=0 n_done=0 n_skip=0 n_warn=0 n_fail=0
  local queue=() skipped="" before after table="" title sound="" msg
  for f in ${FILES[@]+"${FILES[@]}"}; do
    if is_own_output "$f"; then skipped="${skipped}    $(basename "$f")"$'\n'; else queue+=("$f"); fi
  done
  n=${#queue[@]}
  [ -n "$skipped" ] && printf 'Skipping files this tool wrote:\n%s' "$skipped"
  [ "$n" -gt 0 ] || die_early 1 "Nothing to process — every file given was an output of this tool."

  results=$(mktemp "${TMPDIR:-/tmp}/yt_audio_norm_batch.XXXXXX") || die_early 1 "Could not create a temp file."
  trap 'rm -f "$results"' EXIT
  trap 'trap - INT TERM HUP; printf "\nInterrupted — batch stopped. Files already finished are kept.\n" >&2; exit 130' INT TERM HUP

  for f in "${queue[@]}"; do
    i=$(( i + 1 ))
    printf '\n▶ [%d/%d] %s\n' "$i" "$n" "$(basename "$f")"
    before=$(wc -l <"$results")
    rc=0
    YT_AUDIO_NORM_BATCH_CHILD=1 YT_AUDIO_NORM_RESULT_FILE="$results" \
      "$BASH" "$0" ${OPTS[@]+"${OPTS[@]}"} -- "$f" || rc=$?
    [ "$rc" = 130 ] && { printf '\nInterrupted — batch stopped. Files already finished are kept.\n' >&2; exit 130; }
    after=$(wc -l <"$results")
    # A child that stopped before resolving its input (e.g. file not found) leaves no line.
    [ "$after" -gt "$before" ] || printf '%s\037FAIL\037\037\037%s\037%s\n' "$rc" "$(basename "$f")" "stopped before processing — see the message above" >>"$results"
  done

  while IFS=$'\037' read -r code level f_i f_tp name issue; do
    case "$code" in
      4) n_skip=$(( n_skip + 1 )); line="⏭  SKIP"; issue="already normalized — nothing written (--force to redo)" ;;
      0|5) n_done=$(( n_done + 1 ))
           if [ "$level" = "PASS" ]; then line="✅ PASS"; else line="⚠️  WARN"; n_warn=$(( n_warn + 1 )); fi
           [ "$code" = 5 ] && any5=1 ;;
      *) n_fail=$(( n_fail + 1 )); line="❌ FAIL"; [ -n "$worst_fail" ] || worst_fail="$code" ;;
    esac
    line=$(printf '%s  %7s %-4s %6s %-4s' "$line" "$f_i" "${f_i:+LUFS}" "$f_tp" "${f_tp:+dBTP}")
    line="  $line  $name"
    if [ "$level" != "PASS" ] && [ -n "$issue" ]; then
      line="$line"$'\n'"        ↳ $(printf '%s' "$issue" | awk '{ print (length($0) > 110 ? substr($0, 1, 109) "…" : $0) }')"
    fi
    table="${table}${line}"$'\n'
  done <"$results"

  printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
  printf 'Batch: %d file(s) — %d done, %d skipped, %d failed\n' "$n" "$n_done" "$n_skip" "$n_fail"
  printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n%s' "$table"
  [ $(( n_warn + n_fail )) -gt 0 ] && [ "$DRY_RUN" = 0 ] && printf '\nDetails and fixes: the "⚠️ CHECK THIS — <name>.txt" file next to each flagged video.\n'

  if [ "$DRY_RUN" = 0 ] && [ "$MAP_ONLY" = 0 ]; then
    msg="$n_done done, $n_skip skipped, $n_fail failed"
    if [ "$n_fail" -gt 0 ]; then title="❌ Audio batch: $n_fail of $n failed"; sound="Basso"
    elif [ "$n_warn" -gt 0 ]; then title="⚠️ Audio batch: $n_warn of $n need a look"; sound="Basso"
    else title="✅ Audio normalized: $n file(s)"; fi
    notify "$title" "$msg" "$sound"
  fi

  if [ -n "$worst_fail" ]; then exit "$worst_fail"
  elif [ "$any5" = 1 ]; then exit 5
  elif [ "$n_done" -eq 0 ]; then exit 4
  else exit 0
  fi
}

[ "$NFILES" -gt 1 ] && run_batch

# ── Logging and temp space ───────────────────────────────────────────────────
mkdir -p "$LOG_DIR" 2>/dev/null && LOG="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$$.log" && : >"$LOG" || LOG="/dev/null"
log "yt_audio_norm $VERSION  $(date)  cwd=$PWD  args: target=$TARGET_I peak=$PEAK_CEIL bitrate=$BITRATE denoise=$DENOISE map=$MAP_ONLY force=$FORCE dry=$DRY_RUN keep=$KEEP_STAGE1 file=$FILE_ARG"
# Explicit template: macOS `mktemp -t` ignores $TMPDIR, and honoring it lets
# stage 1 go to another drive when the startup disk is short on space.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/yt_audio_norm.XXXXXX") || die_early 1 "Could not create a temp folder."
trap cleanup EXIT
trap on_interrupt INT TERM HUP

# ── 1. Resolve input (plan §7.2a) ────────────────────────────────────────────
if [ -n "$FILE_ARG" ]; then
  [ -e "$FILE_ARG" ] || die_early 1 "File not found: $FILE_ARG"
  [ -f "$FILE_ARG" ] && [ -r "$FILE_ARG" ] || die_early 1 "Not a readable file: $FILE_ARG"
  pick="$FILE_ARG"
else
  if [ -d "./$INPUT_DIR_NAME" ]; then dir="./$INPUT_DIR_NAME"
  elif [ "$(basename "$PWD")" = "$INPUT_DIR_NAME" ]; then dir="."
  else die_early 1 "No $INPUT_DIR_NAME folder here. cd to the video project folder and try again."
  fi
  shopt -s nocaseglob
  matches=""; count=0
  for f in "$dir"/*[-_\ ]final.mp4 "$dir"/*[-_\ ]final.mov "$dir"/final.mp4 "$dir"/final.mov; do
    [ -f "$f" ] || continue
    case "$f" in *-normalized_audio.mp4|*-stage1.*) continue ;; esac
    matches="${matches}    $(basename "$f")"$'\n'; count=$(( count + 1 )); pick="$f"
  done
  if [ "$count" -eq 0 ]; then
    found=""
    for f in "$dir"/*.mp4 "$dir"/*.mov "$dir"/*.m4v; do
      [ -f "$f" ] && found="${found}    $(basename "$f")"$'\n'
    done
    shopt -u nocaseglob
    [ -n "$found" ] || found="    (no video files)"$'\n'
    die_early 1 "No $INPUT_PATTERN in $INPUT_DIR_NAME/. Found:
$found   Name the FCP export '<name> - final.mov' or '<name>-final.mp4', or pass the file path."
  fi
  shopt -u nocaseglob
  if [ "$count" -gt 1 ]; then
    die_early 1 "More than one $INPUT_PATTERN in $INPUT_DIR_NAME/ — not guessing:
${matches}   Run again with the path of the one you want: yt_audio_norm \"$INPUT_DIR_NAME/<file>\""
  fi
fi
OUTDIR=$(cd "$(dirname "$pick")" && pwd)
INPUT="$OUTDIR/$(basename "$pick")"
BASE=$(basename "$INPUT"); BASE="${BASE%.*}"
CHECK_FILE="$OUTDIR/⚠️ CHECK THIS — $BASE.txt"
log "input: $INPUT"
say "Input: $INPUT"

# ── 2. Validate ──────────────────────────────────────────────────────────────
probe=$(ffprobe -v error -show_entries stream=index,codec_type,codec_name:format=duration,size:format_tags=encoder:stream_tags=handler_name -of json "$INPUT" 2>>"$LOG") \
  || fail 1 "Can't read $(basename "$INPUT") — not a media file, or it's damaged." "Re-export from Final Cut Pro."
n_audio=$(jq '[.streams[] | select(.codec_type == "audio")] | length' <<<"$probe")
[ "$n_audio" -gt 0 ] || fail 1 "$(basename "$INPUT") has no audio track." "Check the FCP export settings include audio."
vcodec=$(jq -r '[.streams[] | select(.codec_type == "video")][0].codec_name // "none"' <<<"$probe")
dur=$(jq -r '.format.duration // "0"' <<<"$probe")
in_size=$(jq -r '.format.size // "0"' <<<"$probe")
DUR_US=$(awk -v d="$dur" 'BEGIN { printf "%d", d * 1000000 }')
# OBS tags its files (encoder "OBS Studio (x.y)", handler "OBS Audio Handler").
# FCP rewrites both, so an OBS take edited in FCP counts as an FCP master.
obs_tags=$(jq -r '[.format.tags.encoder // "", (.streams[] | select(.codec_type == "audio") | .tags.handler_name // "")] | join("|")' <<<"$probe")
case "|$obs_tags" in
  *"|OBS "*) SOURCE="obs"; PREGAIN_OK_MIN="$OBS_PREGAIN_OK_MIN"; PREGAIN_OK_MAX="$OBS_PREGAIN_OK_MAX" ;;
esac
log "video=$vcodec duration=$dur size=$in_size audio_streams=$n_audio source=$SOURCE"
if [ "$vcodec" = "prores" ]; then
  OUT_EXT="mov"
  note "Video is ProRes, so the output is .mov (ProRes doesn't belong in .mp4). YouTube accepts it."
fi
[ "$n_audio" -gt 1 ] && note "Input has $n_audio audio tracks; only the first is used."

# Already ours? (input carries our marker, or a marked output already exists)
done_marker=""
if xattr -p "$XATTR_KEY" "$INPUT" >/dev/null 2>&1; then
  done_marker="$INPUT"
else
  for f in "$OUTDIR/$BASE-normalized_audio"*.mp4 "$OUTDIR/$BASE-normalized_audio"*.mov; do
    [ -f "$f" ] && xattr -p "$XATTR_KEY" "$f" >/dev/null 2>&1 && { done_marker="$f"; break; }
  done
fi
if [ -n "$done_marker" ] && [ "$FORCE" = 0 ] && [ "$MAP_ONLY" = 0 ]; then
  meta=$(xattr -p "$XATTR_KEY" "$done_marker" 2>/dev/null || true)
  when=$(jq -r '.date // "?"' <<<"$meta" 2>/dev/null || echo "?")
  lufs=$(jq -r '.lufs // "?"' <<<"$meta" 2>/dev/null || echo "?")
  tp=$(jq -r '.tp // "?"' <<<"$meta" 2>/dev/null || echo "?")
  LEVEL="SKIP"
  note "Already normalized: $(basename "$done_marker") ($lufs LUFS, $tp dBTP, made $when). Nothing written. Use --force to process again."
  # Skipping changes nothing on disk, so leave the folder (and any earlier
  # CHECK THIS file) exactly as the last real run left it.
  CHECK_FILE=""
  finish 4
fi

# Stale sidecar from a previous run goes now, so its presence always means *this* run.
[ "$DRY_RUN" = 0 ] && [ "$MAP_ONLY" = 0 ] && rm -f "$CHECK_FILE"

# ── --map ────────────────────────────────────────────────────────────────────
if [ "$MAP_ONLY" = 1 ]; then
  build_map
  printf '\nLoudness by minute — %s\n%s' "$(basename "$INPUT")" "$MAP_TEXT"
  log "map only, exit 0"
  exit 0
fi

# ── 3. Measure raw ───────────────────────────────────────────────────────────
# silencedetect and astats pass audio through untouched, so loudnorm still sees raw.
measure "$INPUT" "$SILENCE_FILTER,astats=measure_overall=Peak_level:measure_perchannel=none" "Measuring raw"
RAW_I="$M_I"; RAW_TP="$M_TP"; RAW_LRA="$M_LRA"
RAW_PEAK=$(awk -F'Peak level dB: ' 'NF > 1 { v = $2 } END { print v }' "$M_ERR")
log "raw sample peak: $RAW_PEAK dBFS"
is_num "$RAW_I" || fail 1 "The audio is silent (loudness $RAW_I)." "Check the mic was recording and FCP didn't mute the track."

# Silence report → edit notes, never auto-cut.
sil=$(awk '
  /silence_start:/ { s = $NF }
  /silence_end:/ { for (i = 1; i <= NF; i++) if ($i == "silence_end:") e = $(i + 1); printf "%s %s\n", s, e }
' "$M_ERR")
if [ -n "$sil" ]; then
  n_sil=$(printf '%s\n' "$sil" | wc -l | tr -d ' ')
  SILENCE_TEXT=$(printf '%s\n' "$sil" | awk 'NR <= 10' | while read -r a b; do
    printf '    %s–%s (%ss)\n' "$(mmss "$a")" "$(mmss "$b")" "$(awk -v a="$a" -v b="$b" 'BEGIN { printf "%.1f", b - a }')"
  done)
  note "Edit notes: $n_sil pause(s) of 2 s or more$( [ "$n_sil" -gt 10 ] && printf ' (first 10 shown; all in log)'):"
  NOTES="${NOTES}${SILENCE_TEXT}"$'\n'
  log "silences:"; log "$sil"
fi

if f_le "$(f_abs "$(calc "$RAW_I - $TARGET_I")")" "$TOLERANCE" && f_le "$RAW_TP" "$PEAK_CEIL" && [ "$FORCE" = 0 ]; then
  LEVEL="SKIP"
  note "Already normalized: input is $RAW_I LUFS / $RAW_TP dBTP, within $TARGET_I ±$TOLERANCE. Nothing written. Use --force to process anyway."
  CHECK_FILE=""
  finish 4
fi

# Only an edited master can mix an enhanced and a raw part. A raw OBS take is
# one recording; a high LRA there is long pauses or a false start, and the
# output still lands on target, so it's not worth a flag (Sam, 2026-10-24).
if f_lt "$MIXED_LRA" "$RAW_LRA" && [ "$SOURCE" = "obs" ]; then
  note "Loudness range is wide (raw LRA $RAW_LRA LU) — usually long pauses in a single take. Output is still on target."
elif f_lt "$MIXED_LRA" "$RAW_LRA"; then
  warn_issue "Loudness swings a lot between parts (raw LRA $RAW_LRA LU, normal is under $MIXED_LRA). Usually an Enhance-Audio export mixed with a raw one. Look for the ◀ jump in the map below, even out that part with clip gain in FCP, and re-export."
  build_map
fi

if [ -n "$RAW_PEAK" ] && is_num "$RAW_PEAK" && f_le 0 "$RAW_PEAK"; then
  warn_issue "The recording clipped at the mic (peak $RAW_PEAK dBFS). It was still processed — listen for distortion on loud words. For next time, lower DJI TX/RX gain."
fi

# ── 4. Pre-gain ──────────────────────────────────────────────────────────────
# Before the compressor, or a -16 dB threshold never engages on quiet sources.
PREGAIN=$(calc "$WORK_LEVEL - ($RAW_I)")
log "pregain: $PREGAIN"
if f_lt "$PREGAIN" "$PREGAIN_MIN" || f_lt "$PREGAIN_MAX" "$PREGAIN"; then
  fail 1 "Needs $(signed "$PREGAIN") dB of pre-gain (allowed $PREGAIN_MIN…+$PREGAIN_MAX) — the source is far too quiet or too loud to fix safely." "Check the FCP export: muted or doubled tracks, or the wrong file."
fi
# A note, not a flag: the chain absorbs drift and the output still lands on
# target (Sam, 2026-10-24). The abort range above catches a broken source.
if f_lt "$PREGAIN" "$PREGAIN_OK_MIN" || f_lt "$PREGAIN_OK_MAX" "$PREGAIN"; then
  if [ "$SOURCE" = "obs" ]; then
    note "Pre-gain was $(signed "$PREGAIN") dB (usual for OBS: +$PREGAIN_OK_MIN to +$PREGAIN_OK_MAX). Output is fine; if it keeps happening, check DJI TX +3 / RX +3 and the OBS mic level."
  else
    note "Pre-gain was $(signed "$PREGAIN") dB (usual: +$PREGAIN_OK_MIN to +$PREGAIN_OK_MAX). Output is fine; if it keeps happening, check DJI TX +3 / RX +3, noise reduction on, macOS input 50–60%, Screen Studio Enhance Audio off."
  fi
fi

CHAIN="volume=${PREGAIN}dB,$HIGHPASS,$COMPRESSOR,$LIMITER"
[ "$DENOISE" = 1 ] && CHAIN="$DENOISE_FILTER,$CHAIN"

# ── 5. Measure through the chain ─────────────────────────────────────────────
measure "$INPUT" "$CHAIN" "Measuring chain"
CH_I="$M_I"; CH_TP="$M_TP"; CH_LRA="$M_LRA"; CH_THRESH="$M_THRESH"
if is_num "$CH_TP" && f_le 0 "$CH_TP"; then
  warn_issue "Peaks reached $CH_TP dBTP inside the chain — the limiter isn't holding. Output may be harsh; re-run with --verbose and check the log."
fi

if [ "$DRY_RUN" = 1 ]; then
  note "Dry run stops before encoding. Stage 1 usually lands 0.8–3 LU under the chain-measured target."
  finish 0
fi

# ── Disk space: stage 1 in temp, final beside the input ─────────────────────
need_kb=$(awk -v s="$in_size" 'BEGIN { printf "%d", s / 1024 * 1.05 + 51200 }')
out_free=$(free_kb "$OUTDIR"); tmp_free=$(free_kb "$TMP")
[ -n "${YT_AUDIO_NORM_FREE_KB:-}" ] && { out_free="$YT_AUDIO_NORM_FREE_KB"; tmp_free="$YT_AUDIO_NORM_FREE_KB"; }
if [ "$(mount_of "$OUTDIR")" = "$(mount_of "$TMP")" ]; then
  [ "$out_free" -ge $(( need_kb * 2 )) ] || fail 1 "Not enough disk space: need $(( need_kb * 2 / 1048576 + 1 )) GB free (2× the input), have $(( out_free / 1048576 )) GB." "Free up space and run again."
else
  [ "$out_free" -ge "$need_kb" ] || fail 1 "Not enough space on the drive holding $INPUT_DIR_NAME/: need $(( need_kb / 1048576 + 1 )) GB, have $(( out_free / 1048576 )) GB." "Free up space and run again."
  [ "$tmp_free" -ge "$need_kb" ] || fail 1 "Not enough space on the startup disk for the temp file: need $(( need_kb / 1048576 + 1 )) GB, have $(( tmp_free / 1048576 )) GB." "Free up space and run again."
fi

# ── 6. Encode stage 1 ────────────────────────────────────────────────────────
# Explicit maps keep one video + one audio; -write_tmcd 0 stops the muxer
# re-creating FCP's timecode track from metadata (the maps alone don't).
STAGE1="$TMP/stage1.$OUT_EXT"
tp_target=$(calc "$PEAK_CEIL - 0.5")
ff "Encoding stage 1" "$TMP/stage1.err" -i "$INPUT" -map '0:v:0?' -map 0:a:0 -c:v copy \
  -af "$CHAIN,loudnorm=I=$TARGET_I:TP=$tp_target:LRA=$LRA_TARGET:measured_I=$CH_I:measured_TP=$CH_TP:measured_LRA=$CH_LRA:measured_thresh=$CH_THRESH,aformat=channel_layouts=stereo" \
  -c:a aac -b:a "$BITRATE" -ar "$SAMPLE_RATE" -ac 2 -movflags +faststart -write_tmcd 0 -y "$STAGE1" \
  || fail 3 "ffmpeg failed encoding stage 1." "Re-run with --verbose to see the error. Log: $LOG"

# ── 7. Verify stage 1 ────────────────────────────────────────────────────────
measure "$STAGE1" "" "Verifying stage 1"
S1_I="$M_I"; S1_TP="$M_TP"; S1_LRA="$M_LRA"

if [ "$KEEP_STAGE1" = 1 ]; then
  keep=$(free_path "$OUTDIR/$BASE-stage1" "$OUT_EXT")
  cp "$STAGE1" "$keep" && note "Kept stage 1: $keep"
fi

# ── 8. Static correction (plan §5 step 5) ────────────────────────────────────
# Nothing may follow this volume filter: a trailing limiter absorbed half of a
# +2.6 dB boost (rule 3). If it doesn't fit under the ceiling, ship stage 1
# rather than limit after it (rule 7). loudnorm's offset= is not used: in
# dynamic mode it's largely ignored (+2.8 requested, +0.3 delivered; rule 2).
OUT=$(free_path "$OUTDIR/$BASE-normalized_audio" "$OUT_EXT")
PARTIAL="$OUTDIR/.$(basename "${OUT%.*}").partial.$OUT_EXT"
delta=$(calc "$TARGET_I - ($S1_I)")
abs_delta=$(f_abs "$delta")
peak_after=$(calc "$S1_TP + $delta")
exit_code=0
if f_lt "$MAX_DELTA" "$abs_delta"; then
  fail 3 "Stage 1 landed at $S1_I LUFS, $(signed "$delta") LU from target — too far to correct, so something upstream is wrong." "Check the source with: yt_audio_norm --map"
elif f_lt "$abs_delta" "$SKIP_CORRECTION"; then
  CORRECTION_TEXT="not needed ($(signed "$delta") dB)"
  mv "$STAGE1" "$PARTIAL"
elif f_le "$peak_after" "$PEAK_CEIL"; then
  CORRECTION_TEXT="$(signed "$delta") dB"
  ff "Applying correction" "$TMP/final.err" -i "$STAGE1" -map '0:v:0?' -map 0:a:0 -c:v copy \
    -af "volume=${delta}dB" -c:a aac -b:a "$BITRATE" -ar "$SAMPLE_RATE" -ac 2 -movflags +faststart -write_tmcd 0 -y "$PARTIAL" \
    || fail 3 "ffmpeg failed applying the final correction." "Re-run with --verbose to see the error. Log: $LOG"
else
  CORRECTION_TEXT="skipped — $(signed "$delta") dB would put peaks at $(signed "$peak_after") dBTP"
  mv "$STAGE1" "$PARTIAL"
  if f_lt "$TOLERANCE" "$abs_delta"; then
    exit_code=5
    # Only a flag when there's something to do (Sam, 2026-10-22). Landing
    # 0.8–3 LU under is the normal result at TX +3 / RX +3 and fine to upload,
    # so it stays PASS with a note; beyond that range the source is unusual.
    if f_lt "$EXPECTED_SHORTFALL" "$abs_delta"; then
      warn_issue "Shipped $abs_delta LU under target — more than the usual 0.8–3 LU, so the source has unusually sharp peaks. Check it with: yt_audio_norm --map, and listen for a loud spike (a clap, a bump on the mic)."
    else
      note "Landed $abs_delta LU under target (normal at current mic settings: raising it would push peaks past $PEAK_CEIL dBTP). Nothing to do."
    fi
  fi
fi
# Still counts as partial until verified and tagged: an interrupt or failure
# before then removes it, so "nothing written" stays true.
mv "$PARTIAL" "$OUT"; PARTIAL="$OUT"

# ── 9. Verify final ──────────────────────────────────────────────────────────
measure "$OUT" "" "Verifying final"
F_I="$M_I"; F_TP="$M_TP"; F_LRA="$M_LRA"
if [ "$exit_code" = 0 ] && f_lt "$TOLERANCE" "$(f_abs "$(calc "$F_I - $TARGET_I")")"; then
  warn_issue "Final loudness is $F_I LUFS, outside $TARGET_I ±$TOLERANCE. Listen to it; if it sounds wrong, re-run with --verbose and check the log."
fi
if f_lt "$PEAK_CEIL" "$F_TP"; then
  warn_issue "Final true peak is $F_TP dBTP, above the $PEAK_CEIL ceiling. Listen for distortion on loud words before uploading."
fi

# ── 11. Mark output so a re-run skips it ─────────────────────────────────────
status=$(printf '%s' "$LEVEL" | tr 'A-Z' 'a-z')
marker=$(jq -cn --arg date "$(date '+%Y-%m-%dT%H:%M:%S')" --arg src "$(basename "$INPUT")" \
  --argjson lufs "$F_I" --argjson tp "$F_TP" --arg status "$status" \
  '{date: $date, source: $src, lufs: $lufs, tp: $tp, status: $status}')
xattr -w "$XATTR_KEY" "$marker" "$OUT" 2>>"$LOG" || note "Couldn't tag the output (drive may not support it); a re-run won't auto-skip it."
PARTIAL=""

# ── 12. Captions ─────────────────────────────────────────────────────────────
shopt -s nocaseglob
for f in "$OUTDIR"/*.srt; do
  [ -f "$f" ] && note "Captions ready to upload separately (YouTube Studio → Subtitles): $(basename "$f")"
done
shopt -u nocaseglob

# Drift tracking across episodes.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" "$(basename "$INPUT")" \
  "$RAW_I" "$RAW_PEAK" "$PREGAIN" "$F_I" "$F_TP" "$LEVEL" >>"$LOG_DIR/history.tsv" 2>/dev/null || true

finish "$exit_code"
