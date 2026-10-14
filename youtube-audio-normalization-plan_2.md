# YouTube Audio Normalization — Plan & Build Spec

**Pipeline:** DJI Mic 2 (USB) → Screen Studio (Enhance Audio **off**) → Final Cut Pro → `yt_audio_norm` → YouTube
**Status:** validated end to end on `v10 - final.mov` (8:23, 4K60) at current mic settings
**Last updated:** 2026-10-14

---

## 1. Targets

| Property | Target | Notes |
|---|---|---|
| Integrated loudness | **-14.0 LUFS** (±0.5) | YouTube's normalization target |
| True peak | **≤ -1.0 dBTP** | Hard ceiling |
| Channels | Stereo | |
| Sample rate | 48 kHz | |
| Audio codec | AAC-LC, 256 kbps | |
| Video | **untouched** (`-c:v copy`) | Never re-encode the picture for an audio fix |
| Container | MP4 with `+faststart` | Input may be `.mov`; output is `.mp4` |

YouTube only turns audio **down**, never up. Under target plays quieter than other videos; over target gets attenuated.

---

## 2. Capture and export settings

These are fixed. Don't change them per project.

### DJI Mic 2

| Setting | Value |
|---|---|
| Transmitter (TX) gain | **+3 dB** |
| Receiver (RX) gain | **+3 dB** |
| Noise reduction | **On** |
| Connection | USB-C to Mac, appears as "Wireless Microphone RX" |
| Mic placement | Center-chest, consistent distance (omnidirectional capsule) |

Both gains matter — they're independent stages and each contributes. +6/+6 was tested and clipped on normal narration (peak +0.20 dBFS); +3/+3 lands at -2.35 with no clipping.

**Noise reduction is a gate.** With it on, pauses drop to -89 to -96 dBFS — digital silence. With it off, room tone sits around -48. On is right for talking-head video, but listen to the ends of sentences occasionally: aggressive gates can clip word tails and cut breaths off abruptly. If that happens, turn NR off and use `yt_audio_norm --denoise` instead, where the amount is under your control.

### Screen Studio

- **Enhance Audio / Adjust Audio: off**
- **No gain or level adjustments of any kind**
- Export each recording as MP4

Screen Studio's Enhance Audio peak-normalizes to ~0 dBFS instead of normalizing loudness. That leaves no headroom for anything downstream and bakes in noise reduction you can't control. Mixing an enhanced export with a raw one also creates a large level step at the seam (§6, rule 8).

### macOS

- System Settings → Sound → Input → DJI Mic 2, input volume **50-60%**
- Mic Mode (Control Center): **Standard**, not Voice Isolation

### Final Cut Pro
1. Import all Screen Studio parts — do not pre-normalize
2. Edit: cut, arrange, add music/b-roll
3. If a seam is audibly uneven, fix it with clip gain by ear
4. Export the master into the project's **`fcp_export/`** folder, named **`<something>-final.mp4`**:
   - Video: H.264
   - Audio: AAC is what FCP gives you with H.264 — that's fine (see note below)
   - No loudness or limiter effect in the export preset
   - Captions: FCP writes an `.srt` sidecar beside the export
5. `cd` to the project folder and run `yt_audio_norm` — no arguments
6. Listen on headphones and a phone speaker
7. Upload `*-final-normalized_audio.mp4`; upload the `.srt` separately in YouTube Studio → Subtitles

The `fcp_export/` folder and the `-final.mp4` suffix are what let the script run with no arguments (§7.2).

**On PCM audio:** FCP ties audio codec to video codec — H.264 gives AAC, ProRes gives Linear PCM, with no way to mix them without Compressor. Since the source was already AAC from Screen Studio, the FCP AAC step is not the weak link and isn't worth working around. If you ever want PCM anyway, export audio-only as WAV (File → Share → Export File → Audio Only) and feed both files to ffmpeg.

---

## 3. Source profile and mic level

### Which meter to trust

**Peak — for headroom.** This is the one that decides gain settings. Target **-6 to -3 dBFS** on normal narration, with a low `Abs Peak count`. Anything at or above 0 is clipping.

**RMS — only within a controlled test.** RMS over a whole file depends on how much of it is silence, so it is *not* comparable across takes with different content. Two takes at identical settings measured 3.1 dB apart; one 3 dB gain change appeared as a 9.6 dB RMS swing purely from speaking-level variation. Use RMS only when comparing recordings of the same fixed script.

**`RMS through dB` — the noise floor.** Note `astats` spells it "through", not "trough"; grepping for "trough" silently returns nothing.

```bash
ffmpeg -hide_banner -i test.mp4 -vn \
  -af astats=measure_overall=Peak_level+RMS_level+RMS_peak+RMS_trough+Abs_Peak_count \
  -f null - 2>&1 | grep -E "Peak level dB|RMS level|RMS peak|RMS through|Abs Peak count" | tail -5
```

### Validated at TX +3 / RX +3, NR on

| Measure | Value | Reading |
|---|---|---|
| Peak | **-2.35 dBFS** | Headroom present, no clipping |
| Abs peak count | 1 | |
| RMS | -44.1 | Low, but this take was quiet — not a defect |
| RMS peak | -26.3 | Loudest sustained passage |
| Noise floor | -89 to -96 | NR gating pauses to digital silence |

At +6/+6 the same kind of take peaked at **+0.20 dBFS** with RMS peak -13.9 — a 14 dB crest, meaning real speech at the ceiling rather than a stray transient. Hence +3.

### Testing gain changes properly

Gain changes are small relative to how much delivery varies between takes, so an uncontrolled comparison shows nothing. To test:

- Record direct, bypassing Screen Studio: `ffmpeg -f avfoundation -i ":0" -t 20 -c:a pcm_s16le test.wav` (`:0` is "Wireless Microphone RX" — confirm with `-list_devices true`)
- Same fixed script both takes — count steadily to 20, **no pauses**
- Same distance, don't touch the mic between takes
- Compare **peak** and gated loudness (`input_i` from `loudnorm`), not RMS
- Check `input_lra` is low and similar across takes; a high value means that take had pauses and is not comparable

A controlled pair like this showed a clean +14.2 LU gated / +8.9 dB RMS response from 0 to +6, confirming receiver gain does reach the USB output.

### Expected pre-gain

**Measured on an FCP master at +3/+3: `+6.96 dB`** (video 10, raw -27.96 LUFS). Expect roughly **+5 to +12 dB**.

At 0 dB mic gain the same kind of file needed +20 to +24, so the mic change moved the source nearly 17 dB. Lower pre-gain is the point: less post gain means less amplified noise and better preserved dynamics (video 10 held LRA 3.7 vs video 9's 3.1).

The script computes pre-gain per file, so this is a sanity-check range, not a constant. A value back above +15 means the mic settings drifted.

### Corrections to earlier versions of this plan

Recorded so the same wrong turns aren't repeated:

- **The 0 dBFS peak was not a device artifact.** It was clipping caused by too much gain. At 0 dB gain the same mic peaks at -4.99. The recurring `0.000265` value is ffmpeg's clip ceiling, not a signature.
- **Peak is a valid gauge.** An earlier version said to ignore it. It pins at 0 only when the signal is actually over the ceiling.
- **The "+6.8 dB improvement, +4.2 dB signal-above-floor" figure was wrong** — it compared takes with different content and lengths.
- **Screen Studio was not normalizing** in those tests. Flat gain results came from reading peak while clipped, plus uncontrolled content.

---

## 4. Filter chain

| Stage | Filter | Purpose |
|---|---|---|
| 1 | `volume=<pregain>dB` | Lift source to working level (~-21 LUFS). Computed per file. |
| 2 | `highpass=f=80` | Remove rumble and DC offset |
| 3 | `acompressor=threshold=-16dB:ratio=2:attack=20:release=300` | Even out level swings. No makeup gain. |
| 4 | `alimiter=limit=0.7:level=disabled` | Cap transients at -3.1 dBFS |
| 5 | `loudnorm=I=-14:TP=-1.5:LRA=11:measured_*=…` | Two-pass loudness normalization |
| 6 | `aformat=channel_layouts=stereo` | Guarantee stereo output |
| 7 | *(separate encode)* `volume=<delta>dB` | Static correction to land on target. **Nothing after it.** |

Optional, off by default: `afftdn=nr=10:nf=-55:tn=1` **before** stage 1 for audible hiss. Above `nr=15` speech turns watery.

ffmpeg filters run in floating point, so peaks above 0 dBFS between stages 1 and 4 don't clip.

---

## 5. Procedure

This is what the script automates — run it by hand only when debugging.

```bash
cd fcp_export
F=$(ls *-final.* | head -1)
OUT="${F%.*}"                  # basename without extension
```

All measurement passes use **`-vn`** — skipping the 4K decode cuts a 15-minute file from ~2 min to ~25 s.

### Step 1 — Inspect and measure raw

```bash
ffprobe -v error -show_entries stream=index,codec_type,codec_name,channels,sample_rate,bit_rate \
  -of default=noprint_wrappers=1 "$F"

ffmpeg -hide_banner -i "$F" -vn -af loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json -f null - 2>&1 | tail -14
```

- `pregain = -21 - input_i`
- If `input_lra` > 12, stop and run the loudness map (Step 1b) — likely mixed sources

### Step 1b — Loudness map (only if LRA is suspicious)

```bash
for s in $(seq 0 60 900); do
  printf "%02d:%02d  " $((s/60)) $((s%60))
  ffmpeg -hide_banner -ss $s -t 60 -i "$F" -vn -af ebur128 -f null - 2>&1 | grep -E "^\s+I:" | tail -1
done
```

A jump of 10+ LU between minutes means a mismatched part. Fix in FCP and re-export.

### Step 2 — Measure through the chain

```bash
ffmpeg -hide_banner -i "$F" -vn -af \
"volume=<pregain>dB,highpass=f=80,acompressor=threshold=-16dB:ratio=2:attack=20:release=300,alimiter=limit=0.7:level=disabled,loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json" \
-f null - 2>&1 | tail -14
```

Record `input_i`, `input_tp`, `input_lra`, `input_thresh`. `input_tp` must be negative.

### Step 3 — Encode stage 1

```bash
ffmpeg -i "$F" -map 0:v:0 -map 0:a:0 -c:v copy -af \
"volume=<pregain>dB,highpass=f=80,acompressor=threshold=-16dB:ratio=2:attack=20:release=300,alimiter=limit=0.7:level=disabled,loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=<input_i>:measured_TP=<input_tp>:measured_LRA=<input_lra>:measured_thresh=<input_thresh>,aformat=channel_layouts=stereo" \
-c:a aac -b:a 256k -ar 48000 -ac 2 -movflags +faststart \
"$OUT-stage1.mp4"
```

Explicit `-map` keeps one video and one audio stream and drops FCP's timecode track.

### Step 4 — Verify stage 1

```bash
ffmpeg -hide_banner -i "$OUT-stage1.mp4" -vn \
  -af loudnorm=I=-14:TP=-1:LRA=11:print_format=summary -f null - 2>&1 \
  | grep -E "Input (Integrated|True Peak|LRA)"
```

### Step 5 — Static correction

`delta = -14.0 - integrated`

| Condition | Action |
|---|---|
| `|delta| < 0.3` | Stage 1 is final |
| `true_peak + delta ≤ -1.0` | Apply `volume=<delta>dB` (below) |
| `true_peak + delta > -1.0` | **Headroom exhausted** — ship stage 1 as final |
| `|delta| > 6` | Abort; something upstream is wrong |

```bash
ffmpeg -i "$OUT-stage1.mp4" -map 0:v:0 -map 0:a:0 -c:v copy \
  -af "volume=<delta>dB" -c:a aac -b:a 256k -ar 48000 -ac 2 -movflags +faststart \
  "$OUT-normalized_audio.mp4"
```

### Step 6 — Verify final

Same as Step 4. Pass: -14.0 ±0.5 LUFS, true peak ≤ -1.0 dBTP.

### Worked examples

**A — Correction applied** (`part1 w CC and transcript.mp4`, raw Screen Studio clip)

| Stage | Integrated | True peak | LRA |
|---|---|---|---|
| Raw | -41.2 | -14.9 | 7.6 |
| Pre-gain | +20 dB | | |
| Stage 1 | -17.0 | -4.4 | 3.2 |
| Correction | +3.0 dB | | |
| **Final** | **-14.1** | **-1.3** | **3.2** |

**B — Headroom exhausted** (`final fcp export.mov`, full edited master)

| Stage | Integrated | True peak | LRA |
|---|---|---|---|
| Raw | -44.8 | -20.9 | 7.9 |
| Pre-gain | +23.8 dB | | |
| Chain measurement | -22.6 | -3.1 | 5.9 |
| Stage 1 | **-15.7** | **-1.4** | **4.6** |
| Correction needed | +1.7 dB → peak would be +0.3 | | |
| **Result** | Ship stage 1 (1.7 LU under target) | | |

**C — Current reference** (`v10 - final.mov`, 8:23 FCP master, mic at +3/+3)

| Stage | Integrated | True peak | LRA |
|---|---|---|---|
| Raw | -27.96 | -6.02 | 4.8 |
| Pre-gain | **+6.96 dB** | | |
| Chain measurement | -21.81 | -3.10 | 4.3 |
| **Stage 1 — shipped** | **-14.8** | **-1.4** | **3.7** |
| Correction skipped | +0.8 dB would put peak at -0.6 | | |

This is the shape to expect now: one pass, lands under 1 LU from target, correction usually doesn't fit. Shipping 0.8 LU under is a pass, not a problem.

Stage 1 lands anywhere from ~0.8 to ~3 LU under target. Whether the correction fits depends on how much headroom loudnorm used.

---

## 6. Rules the script must honor

Each was found by breaking it.

1. **`alimiter` uses `level=disabled`.** The default auto-levels output back to 0 dBFS, erasing the headroom it created.
2. **Don't use `loudnorm`'s `offset=`.** In dynamic mode it's largely ignored (+2.8 requested, +0.3 delivered).
3. **Nothing follows the final `volume` correction.** A trailing limiter absorbed half of a +2.6 dB boost.
4. **No compressor makeup gain.** With fast attack it overshot to +4.5 dBTP.
5. **Pre-gain before the compressor.** Otherwise a -16 dB threshold never engages on quiet sources.
6. **Expect dynamic mode.** `linear=true` falls back silently when headroom is short; fine for speech.
7. **Static correction only when headroom allows.** Otherwise ship stage 1 — never limit after the correction to force it.
8. **Check for mixed sources.** Raw LRA > 12 on a talking-head video almost always means an enhanced and a raw part were combined. Warn and print the loudness map.
9. **`-vn` on every measurement pass.** Same numbers, ~5× faster.
10. **Compare loudness, not RMS.** RMS over a whole file tracks how much of it is silence, so it swings wildly between takes. Any level comparison the script reports must use gated loudness (`input_i`); RMS is only meaningful for fixed-content test recordings.

### Open question (not in defaults)

When headroom is exhausted, raising loudnorm's target by the shortfall (e.g. `I=-12.3` to land at -14) may let its internal true-peak limiter reach target without breaking the ceiling. **Unverified.** Test on a real file before adding it as a `--hot` retry option.

---

## 7. Build spec for Claude Code

### Design

**Environment:** macOS, **bash** (not zsh), ffmpeg 9.x from Homebrew at `/opt/homebrew/bin`. Write the script for bash — `#!/usr/bin/env bash`, no zsh-only syntax (no `${array[1]}` 1-indexing, no `setopt`, no `print -r`). Shell config lives in `~/.bashrc`.

- **Zero-argument by default.** `yt_audio_norm` with no arguments does the whole job with built-in settings. No flag needs to be remembered.
- **Convention over configuration.** Fixed input folder, fixed filename pattern, fixed output name.
- **Source never moved or copied.** Read in place; write beside it.
- **No state files.** Already-normalized input is detected by measuring it.

### 7.1 Deliverables

| # | Artifact | Purpose |
|---|---|---|
| 1 | `~/bin/yt_audio_norm.sh` | All logic |
| 2 | Function in `~/.bashrc` | `yt_audio_norm` from anywhere |
| 3 | `README.md` beside the script | Usage, flags, troubleshooting |

### 7.2 Folder convention

```
video 10 - some topic/          ← project folder, cd here
├── screen studio/              ← ignored
└── fcp_export/                 ← the script's only concern
    ├── video 10-final.mp4                       ← input
    ├── video 10-final-normalized_audio.mp4      ← output, written here
    └── …anything else           ← ignored
```

**Input:** the single file matching `*-final.mp4` inside `fcp_export/`.
**Output:** the same name with `-normalized_audio` before the extension, in the same folder.

```
video 10-final.mp4  →  video 10-final-normalized_audio.mp4
```

Everything else in `fcp_export/` — `.srt` sidecars, stray exports, earlier takes — is ignored. The `*-final.mp4` pattern is the contract: name the FCP export that way and nothing else needs configuring.

Never overwrite. On collision, insert ` 2`, ` 3` before the extension.

### 7.2a Locating the input

Run with no arguments. Resolve the input folder in this order:

1. `./fcp_export/` if it exists (normal case: run from the project folder)
2. `.` if the current folder is itself named `fcp_export`
3. Otherwise exit `1`: "No fcp_export folder here. cd to the video project folder and try again."

Then glob `*-final.mp4` in that folder, excluding `*-normalized_audio.mp4` and `*-stage1.*`:

| Matches | Behavior |
|---|---|
| Exactly 1 | Process it |
| 0 | Exit `1`: "No `*-final.mp4` in fcp_export/. Found: <list of video files there>." |
| More than 1 | List them, exit `1`, ask for an explicit path |

Never guess between candidates — these are multi-gigabyte files and a wrong pick wastes minutes.

An explicit file path as an argument bypasses all of the above and is processed directly, keeping the same output-naming rule.

### 7.3 CLI

Every setting has a built-in default. **The flags exist for exceptions and are not needed in normal use.**

```
yt_audio_norm [OPTIONS] [FILE]

Defaults (all baked in — running bare is the intended use):
  input            ./fcp_export/*-final.mp4
  output           <input>-normalized_audio.mp4, same folder
  target           -14 LUFS
  peak ceiling     -1.0 dBTP
  audio            AAC 256k, 48 kHz, stereo
  video            copied, never re-encoded
  denoise          off
  compressor       threshold -16dB, ratio 2, attack 20, release 300

Options:
  -t, --target LUFS    Override integrated target
  -p, --peak DBTP      Override true peak ceiling
  -b, --bitrate RATE   Override AAC bitrate
      --denoise        Add afftdn before pre-gain
      --map            Print per-minute loudness map and exit
  -f, --force          Process even if already within tolerance
  -n, --dry-run        Measure and report, write nothing
  -k, --keep-stage1    Keep the intermediate file
  -v, --verbose        Show full ffmpeg output
  -h, --help           Print this, including every default above
```

`--help` must print the resolved defaults, so the settings are recoverable from the script itself rather than from this document.

**Exit codes:** `0` success · `1` bad usage or input · `2` missing dependency · `3` ffmpeg failure · `4` skipped, already normalized · `5` shipped stage 1, headroom exhausted

### 7.4 Dependencies

`ffmpeg`, `ffprobe`, `jq` (parse JSON — never regex), `bc` or awk for float math. Check at startup; exit `2` with a Homebrew hint.

### 7.5 Algorithm

1. **Resolve input** per §7.2a.
2. **Validate** — readable, has an audio stream. Detect video codec (ProRes → `.mov` output with a warning).
3. **Measure raw** with `-vn`.
   - Within ±0.5 LU of target and peak ≤ ceiling → exit `4` unless `--force`
   - `input_lra` > 12 → warn about mixed sources and print the loudness map
   - Raw peak ≥ 0 dBFS → warn that the recording clipped at the mic and to lower DJI gain. Don't abort.
4. **Pre-gain** — `-21 - raw_i`. Outside -10…+32 dB → abort. Expected range at current mic settings is +5 to +12 (§3).
5. **Measure chain** with `-vn`. Warn if `input_tp ≥ 0`.
6. **Encode stage 1** with explicit `-map 0:v:0 -map 0:a:0`, into the temp dir.
7. **Verify** with `-vn`.
8. **Correct** per the §5 step 5 table, writing the final output into `fcp_export/`.
9. **Verify final.**
10. **Report** per §7.7 — terminal banner, problem-only sidecar file, notification, exit code.
11. **Mark the output** so a re-run skips it:
    ```bash
    xattr -w com.sam.yt_audio_norm '{"date":"…","lufs":-14.1,"tp":-1.3,"status":"pass"}' "$OUT"
    ```
12. **Sidecar captions** — if an `.srt` sits in `fcp_export/`, mention it in the report as ready to upload. Don't modify it.

### 7.6 Implementation requirements

- `#!/usr/bin/env bash` — bash, not zsh or sh. Target bash 3.2 (macOS system bash) unless the script checks for and requires a newer Homebrew bash: **no associative arrays, no `${var^^}`, no `mapfile`/`readarray`, no negative array indices.**
- `set -euo pipefail`
- **Quote every path.** Real paths contain spaces, hyphens with spaces, and parentheses (`…_SRT 2_English (United States).srt`).
- Temp files in `mktemp -d`, removed by `trap … EXIT` including on failure or Ctrl-C. Stage 1 is a temp file, not a folder artifact, unless `--keep-stage1`.
- `-movflags +faststart` on every output
- Quiet by default; progress on long files; full output with `--verbose`
- Log each run to `~/Library/Logs/yt_audio_norm/<timestamp>.log`
- Expect large files: a 15-minute 4K60 master is ~9.3 GB. Check free space before writing (need ≥ 2× input size for stage 1 + final).

### 7.7 Telling the user something went wrong

**Assume log files are never read.** The design rule: when everything worked, the script leaves no homework. When something needs attention, it is impossible to miss.

| Level | Meaning |
|---|---|
| **PASS** | Within ±0.5 LU of target, true peak ≤ ceiling, no warnings |
| **WARN** | Output is usable but not ideal — needs a look, not a redo |
| **FAIL** | No usable output |

**WARN conditions**
- Shipped stage 1 under target, headroom exhausted (exit `5`)
- Raw `input_lra` > 12 — possible mixed sources
- Raw peak ≥ 0 dBFS — the recording clipped at the mic; lower DJI gain
- Pre-gain outside +4…+15 dB — mic settings drifted from §2
- Final loudness outside ±0.5 LU of target
- Input already normalized, skipped (exit `4`)

**FAIL conditions**
- Missing dependency, no audio stream, unreadable input, no input found
- Any ffmpeg non-zero exit
- Insufficient disk space

**How each is surfaced**

1. **Terminal summary** — last thing printed, visually unmissable: a `✅ PASS` / `⚠️ WARN` / `❌ FAIL` banner line, the before/after loudness table, and for WARN or FAIL one plain-English line per issue saying what to do about it. No jargon-only messages.

2. **A file that only exists when there's a problem.** On WARN or FAIL, write `⚠️ CHECK THIS — <basename>.txt` into `fcp_export/` listing the issues and suggested fixes. On PASS, write nothing. **Presence of that file is the signal** — a clean folder means a clean run. Delete any stale copy at the start of a run.

3. **macOS notification**, differentiated so it reads at a glance:
   ```bash
   # PASS
   osascript -e 'display notification "-14.0 LUFS, -1.3 dBTP" with title "✅ Audio normalized"'
   # WARN / FAIL — include a sound
   osascript -e 'display notification "Shipped 1.7 LU under target" with title "⚠️ Check audio" sound name "Basso"'
   ```

4. **Exit code** per §7.3, so it composes in scripts.

Logs still get written for the rare case of digging in, but nothing routine should require opening them.

### 7.8 Wrapper

**Shell function** in `~/.bashrc`. The shell here is **bash**, not zsh. macOS Terminal starts login shells, which read `~/.bash_profile` and not `~/.bashrc`, so make sure `~/.bash_profile` sources `~/.bashrc`:

```bash
# in ~/.bash_profile
[ -f ~/.bashrc ] && . ~/.bashrc
```

Then in `~/.bashrc`:
```bash
yt_audio_norm() { ~/bin/yt_audio_norm.sh "$@"; }
```

Normal use is two steps: `cd` to the video project folder, then `yt_audio_norm`.

No Finder Quick Action — the terminal path covers it.

### 7.9 Tests

- [ ] Bare run from a project folder containing `fcp_export/one-final.mp4` → processes it
- [ ] Output lands in `fcp_export/` as `one-final-normalized_audio.mp4`
- [ ] Bare run from inside `fcp_export/` itself → works the same
- [ ] Bare run with no `fcp_export/` anywhere → exit `1`, clear message
- [ ] `fcp_export/` with `*-final.mp4` plus `.srt` and other videos → only `*-final.mp4` picked
- [ ] `fcp_export/` with two `*-final.mp4` files → lists them, exit `1`, writes nothing
- [ ] Re-run after a successful run → previous output excluded, exit `4`, not reprocessed
- [ ] `--force` processes anyway
- [ ] Output collision → ` 2` suffix, existing file untouched
- [ ] `--help` prints every default value
- [ ] PASS run leaves **no** `⚠️ CHECK THIS` file
- [ ] WARN run writes one, with plain-English fixes
- [ ] Stale `⚠️ CHECK THIS` from a prior run is removed at start
- [ ] Notification fires with sound on WARN/FAIL, silent on PASS
- [ ] Paths with spaces and parentheses
- [ ] `.mov` input → `.mp4` output, timecode track dropped, video bit-identical
- [ ] No audio stream → exit `1`
- [ ] Headroom-exhausted file → exit `5`, stage 1 shipped, report says so
- [ ] Mixed-source file → warning and loudness map
- [ ] `--dry-run` writes nothing
- [ ] Ctrl-C → temp files cleaned, no stage1 left behind
- [ ] Insufficient disk space → clean abort before encoding
- [ ] Input on an external drive

**Regression cases:**

| File | Mic gain | Expected |
|---|---|---|
| `v10 - final.mov` | +3/+3 | exit `5`, pre-gain ≈ +6.96, ≈ -14.8 LUFS / -1.4 dBTP |
| `part1 w CC and transcript.mp4` | 0 dB | exit `0`, ≈ -14.1 LUFS / -1.3 dBTP |
| `final fcp export.mov` | 0 dB | exit `5`, ≈ -15.7 LUFS / -1.4 dBTP |

**`v10 - final.mov` is the primary regression case** — it's the only one recorded at current mic settings. The two 0 dB files still validate the chain, but their pre-gain values (+20 and +23.8) are not what new footage should produce.

---

## 8. Other YouTube prep

**In the script**
- `+faststart` on output
- Silence report as edit notes (not auto-cut):
  ```bash
  ffmpeg -hide_banner -i "$F" -vn -af silencedetect=noise=-40dB:d=2 -f null - 2>&1 | grep silence_
  ```
- Before/after loudness in the run log, to track drift across episodes

**Test before adding to defaults**
- `--denoise` if pauses carry hiss after pre-gain
- De-esser (`deesser=i=0.4`) if sibilance is harsh

**Manual**
- Upload the FCP `.srt` in YouTube Studio → Subtitles (better for search than burned-in captions)
- Chapters from caption timestamps
- Title, description, tags, thumbnail
- Final listen on headphones **and** phone speaker

---

## 9. Settled questions

Things already tested — don't re-investigate.

| Question | Answer |
|---|---|
| Does DJI RX/TX gain affect the USB output? | **Yes.** A controlled fixed-script pair showed +14.2 LU gated / +8.9 dB RMS from 0 to +6. |
| Why did six earlier gain tests look identical? | Peak was pinned by clipping, and RMS was confounded by content differences between takes. Neither was measuring gain. |
| Is Screen Studio normalizing the audio? | **No**, with Enhance off. The 0 dBFS peaks came from too much mic gain, not from the app. |
| Is the macOS input slider the cause? | **No.** Moving it to 50% changed nothing. |
| Is +6/+6 usable? | **No.** Normal narration peaked at +0.20 dBFS with RMS peak -13.9 — real speech at the ceiling. +3/+3 peaks at -2.35. |
| What does DJI noise reduction do? | Gates pauses to -89…-96 dBFS (digital silence). Off leaves room tone around -48. |
| Does Screen Studio's transcript option embed captions? | **No** subtitle track and no sidecar in the MP4 export. FCP's `.srt` sidecar is the caption source. |
| Can FCP export H.264 with PCM audio? | **No**, not without Compressor. Not worth working around (§2). |
| Does raising the compressor threshold preserve dynamics? | **Barely.** -20 dB vs -16 dB → final LRA 3.1 vs 3.2. loudnorm's internal limiter controls dynamics, not the compressor. |

### The biggest remaining variable is delivery, not gear

Across every test, receiver settings moved the signal a few dB while take-to-take variation moved it 10+ dB. Consistent mic placement (center-chest, same distance) and consistent speaking level will do more for the audio than any setting in this document.
