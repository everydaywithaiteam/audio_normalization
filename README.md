# yt_audio_norm

Normalizes the audio on a Final Cut Pro master for YouTube: **-14 LUFS integrated, ≤ -1.0 dBTP true peak**, AAC 256k / 48 kHz / stereo. The video stream is copied untouched.

Pipeline: DJI Mic 2 (USB) → Screen Studio (Enhance Audio **off**) → Final Cut Pro → `yt_audio_norm` → YouTube.
Raw OBS Studio recordings (e.g. Shorts) work too: `yt_audio_norm *.mp4` in their folder. OBS files are recognised by their tags and get OBS-specific expectations.
Full rationale, measurements and capture settings: [youtube-audio-normalization-plan_2.md](youtube-audio-normalization-plan_2.md).

## Use

```bash
cd ~/"Desktop/Everyday With AI/videos/video 11 - something"
yt_audio_norm
```

That's it. The script finds the FCP export in `fcp_export/` (any name ending in `final.mov` or `final.mp4`, e.g. `v12 - final.mov`), writes `<name>-normalized_audio.mp4` next to it, and tells you how it went.

```
video 11 - something/          ← cd here (or into fcp_export/ itself)
├── screen studio/             ← ignored
└── fcp_export/
    ├── v11 - final.mov                    ← input (name ends in "final", .mov or .mp4)
    ├── v11 - final-normalized_audio.mp4   ← output: upload this
    ├── v11 - final_SRT_English….srt       ← upload separately in YouTube Studio → Subtitles
    └── ⚠️ CHECK THIS — v11 - final.txt    ← only exists if something needs a look
```

## Reading the result

| You see | Meaning | Exit |
|---|---|---|
| `✅ PASS`, no CHECK THIS file | On target. Upload it. | 0 |
| `⚠️ WARN` + CHECK THIS file | Something needs your action. The file says what. | 0 or 5 |
| `❌ FAIL` + CHECK THIS file | No usable output. The file says why. | 1, 3 |
| `⏭ SKIPPED` | Already done. Nothing written, no notification. `--force` to redo. | 4 |

You also get a macOS notification: silent on PASS, with the Basso sound on WARN/FAIL, and none on a skip.

**The rule: you're only flagged when there's something to do.** A CHECK THIS file or the Basso sound always means an action: listen for distortion, check the mic settings, or fix a part in FCP.

**Landing 0.8–3 LU under target is a PASS.** That's the normal result at current mic settings (v10 -14.76, v11 -14.86). Raising it further would push peaks past -1 dBTP, so the script ships stage 1 instead of limiting after the correction. It's a note in the terminal and nothing else (exit `5`, for scripts). It's only flagged when it lands more than 3 LU under, because that points at an unusual spike in the source.

## Options

Nothing here is needed in normal use. `yt_audio_norm --help` prints every default.

```
yt_audio_norm [OPTIONS] [FILE…]
  -t, --target LUFS    Override integrated target (default -14)
  -p, --peak DBTP      Override true peak ceiling (default -1.0)
  -b, --bitrate RATE   Override AAC bitrate (default 256k)
      --denoise        Add afftdn=nr=10:nf=-55:tn=1 before pre-gain
      --map            Print per-minute loudness map and exit
  -f, --force          Process even if already within tolerance / already done
  -n, --dry-run        Measure and report, write nothing
  -k, --keep-stage1    Keep the intermediate file
  -v, --verbose        Show full ffmpeg output
  -h, --help           Print help with all defaults
```

**Input naming:** the name must end in `final` after a `-`, `_` or space, with `.mov` or `.mp4` in any case: `v12 - final.mov`, `v12-final.mp4`, `final.mov`. `semifinal.mp4` doesn't count. The plan originally said `*-final.mp4` only; it was widened on 2026-10-14 because real FCP exports are named `v10 - final.mov`.

Passing a `FILE` skips the `fcp_export/` lookup. The output still goes beside that file, using the same naming rule. Use this for an export with any other name, e.g. `yt_audio_norm "fcp_export/rough cut.mov"`.

### Several files at once

```bash
cd ~/"Desktop/Everyday With AI/videos/video 10 - claude chat cowork merging/yt_shorts"
yt_audio_norm *.mp4
```

Each file is processed in turn, with the same options, and its output goes beside it. At the end you get one summary table and **one** notification instead of one per file.

- **Its own files are skipped.** `*.mp4` also matches outputs from earlier runs (`*-normalized_audio*`, `*-stage1*`); those are listed and skipped automatically.
- **Already-done files are skipped.** A file that already has a tagged output shows as `⏭ SKIP`, so re-running `*.mp4` after adding new Shorts only processes the new ones.
- **One failure doesn't stop the batch.** The rest still run. Each flagged file still gets its own `⚠️ CHECK THIS` file.
- **Ctrl-C stops the whole batch.** Files already finished are kept. The one in progress leaves nothing behind.

Exit codes: `0` success · `1` bad usage or input · `2` missing dependency · `3` ffmpeg failure · `4` skipped, already normalized · `5` shipped stage 1, headroom exhausted.
With several files: the first failure code if any file failed, else `5` if any shipped under target, else `0`, or `4` if every file was skipped.

## What it does

1. **Measure raw** (audio only, `-vn`, ~5× faster). Skip if already within -14 ±0.5 and under the ceiling. Warn on LRA > 12 (mixed sources, prints a loudness map) — except on a raw OBS take, which is a single recording, so a wide range there is just long pauses and only gets a note and on sample peak ≥ 0 dBFS (clipped at the mic).
2. **Pre-gain** to -21 LUFS, computed per file. At TX +3 / RX +3 expect **+5 to +12 dB** from Screen Studio/FCP, **+18 to +22 dB** from OBS (it records ~10 dB quieter). Outside +4…+15 (OBS: +15…+25) it adds a note — not a warning, since the output still lands on target. Outside -10…+32 it aborts.
3. **Chain:** `volume → highpass 80 Hz → acompressor (-16 dB, 2:1, no makeup) → alimiter 0.7 (level=disabled) → loudnorm two-pass → stereo`.
4. **Verify stage 1**, then apply a static `volume` correction only if `true_peak + delta ≤ ceiling`. Otherwise ship stage 1. Nothing follows the correction.
5. **Verify final.** Tag the output with an xattr (`com.sam.yt_audio_norm`) so a re-run skips it. Report.

It also lists pauses of 2 s or more as edit notes (never auto-cut) and mentions any `.srt` in the folder.

### Why some obvious things are *not* done

Each of these was found by breaking it (plan §6):

- **No `loudnorm offset=`.** It's mostly ignored in dynamic mode: +2.8 requested, +0.3 delivered.
- **No limiter after the final correction.** A trailing limiter absorbed half of a +2.6 dB boost. If the correction doesn't fit, stage 1 ships.
- **No compressor makeup gain.** With fast attack it overshot to +4.5 dBTP.
- **`alimiter level=disabled`.** The default auto-levels back to 0 dBFS and erases the headroom.
- **Pre-gain goes before the compressor.** Otherwise the -16 dB threshold never engages on quiet sources.
- **RMS is never compared.** Whole-file RMS mostly tracks how much of the file is silence. Loudness comparisons use gated `input_i`.
- **`-write_tmcd 0`.** Explicit `-map` alone doesn't drop FCP's timecode track: the MP4 muxer re-creates it from metadata.

## Install

```bash
./install.sh
```

This symlinks `~/bin/yt_audio_norm.sh` (and `~/bin/yt_audio_norm.README.md`) to this folder, so edits here are live. It also adds the `yt_audio_norm` function to `~/.bashrc`. Open a new Terminal window afterwards. Needs `brew install ffmpeg jq`.

## Files and logs

- Run logs: `~/Library/Logs/yt_audio_norm/<timestamp>.log`. You shouldn't need them, because problems surface in the terminal, the CHECK THIS file and the notification.
- Drift history: `~/Library/Logs/yt_audio_norm/history.tsv` has one line per run (raw loudness, raw peak, pre-gain, final). Watch pre-gain creep up across episodes.
- Temp files go in `$TMPDIR` and are removed on exit, failure or Ctrl-C. Set `TMPDIR` to put stage 1 on another drive.
- Disk space: needs about 2× the input free when temp and output share a drive (a 15-min 4K60 master is ~9.3 GB).

## Troubleshooting

| Message | Fix |
|---|---|
| No fcp_export folder here | `cd` to the video project folder (the one containing `fcp_export/`). |
| No `*final.mp4 / *final.mov` in fcp_export/ | Name the FCP export `<name> - final.mov`, or pass the path. |
| More than one match | Pass the one you want: `yt_audio_norm "fcp_export/v12 - final.mov"`. |
| Pre-gain note (outside +4…+15, OBS +15…+25) | Nothing to do for this file. If it keeps happening, check DJI TX +3 / RX +3, NR on, macOS input 50–60%, Mic Mode Standard, Screen Studio Enhance Audio off. |
| Loudness swings a lot (LRA > 12) | An enhanced and a raw part were probably combined. Find the `◀ jump` in the map, fix it with clip gain in FCP, and re-export. |
| Clipped at the mic | Listen for distortion. Lower DJI gain for future recordings. |
| Already normalized | It's done. `--force` to redo; the new output gets a ` 2` suffix. |

## Tests

```bash
tests/run_tests.sh       # 82 checks on synthetic masters (speech from `say`), ~2 min
tests/regression.sh      # the three real masters from the plan, ~6 min
```

Real-footage results (2026-10-14, video 11 and the PASS/WARN levels re-checked 2026-10-22). `regression.sh` finds the files by name anywhere under `~/Desktop/Everyday With AI` and skips any that have since been deleted.

| File | Mic | Expected | Got |
|---|---|---|---|
| `video 11 … fcp export.mov` | +3/+3 | exit 5, PASS (no flag) | exit 5, PASS, +7.29, -14.86 / -1.38 |
| `v10 - final.mov` | +3/+3 | exit 5, +6.96, ≈-14.8 / -1.4 | exit 5, +6.96, -14.76 / -1.45 |
| `final fcp export.mov` | 0 dB | exit 5, ≈-15.7 / -1.4 | exit 5, +23.76, -15.67 / -1.35 |
| `part1 w CC and transcript.mp4` | 0 dB | exit 0, +20, ≈-14.1 / -1.3 | exit 0, +20.19, -14.00 / -1.25 |

The headroom-exhausted path (exit 5) isn't reproducible with synthetic speech, which always fit the correction. Only the real masters cover it.

## Open question (not in defaults)

When headroom is exhausted, raising loudnorm's target by the shortfall (e.g. `I=-12.3` to land at -14) might reach target without breaking the ceiling. This is unverified. Test it on a real file before adding a `--hot` retry.
