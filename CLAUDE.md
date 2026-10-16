# yt_audio_norm

Bash tool that normalizes FCP masters to -14 LUFS / -1 dBTP for YouTube. Spec: `youtube-audio-normalization-plan_2.md` (source of truth for settings and the "found by breaking it" rules in §6). User docs: `README.md`.

- `yt_audio_norm.sh` — all logic. Installed by `install.sh` as a **symlink** at `~/bin/yt_audio_norm.sh`, so edits here are live immediately.
- Must run under macOS `/bin/bash` 3.2: no associative arrays, `mapfile`, `${var^^}`, negative indices, or `"${arr[@]}"` on possibly-empty arrays under `set -u`. Tests run the script with `/bin/bash` explicitly.
- Watch `set -e` traps: a function whose last command is a failing `[ … ] && …` returns non-zero and kills the script; `cmd | head` in `$(…)` can SIGPIPE under pipefail (use `awk 'NR<=n'`).
- Input lookup: `fcp_export/` file whose name ends in `[-_ ]final.mov|mp4` (case-insensitive). Widened from the plan's `*-final.mp4` at Sam's request 2026-10-14.
- Several file args = batch mode (`run_batch`): the script re-invokes itself once per file (`$BASH "$0" OPTS -- file`) with `YT_AUDIO_NORM_BATCH_CHILD=1` (no per-file notification) and `YT_AUDIO_NORM_RESULT_FILE` (child appends one `\037`-separated line in `finish()`). Keeps every single-file guarantee untouched — put per-file logic in the single-file path, not in `run_batch`.
- Parse loudnorm output with `jq`, never regex. Every measurement pass uses `-vn`.
- Don't edit the script while a long run is in progress — bash reads scripts lazily and the run dies with a bogus syntax error.

## Tests
- `tests/run_tests.sh` — 81 checks on synthetic fixtures (`tests/make_fixtures.sh`, speech from `say`). Fixtures cache in `$FIXTURES` (default `$TMPDIR/yt_audio_norm_fixtures`).
- `tests/regression.sh` — the three real masters under `~/Desktop/Everyday With AI`, symlinked into a temp dir so nothing is written beside the originals. v10 is the primary case.
- Test hooks: `YT_AUDIO_NORM_NOTIFY_LOG=<file>` records notifications instead of showing them; `YT_AUDIO_NORM_NO_NOTIFY=1` suppresses; `YT_AUDIO_NORM_FREE_KB=<n>` fakes free disk space.
