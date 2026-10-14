#!/usr/bin/env bash
# Builds small synthetic test masters: real speech from macOS `say`, a tiny
# h264 picture, levels chosen to mimic DJI Mic 2 footage at TX +3 / RX +3.
set -euo pipefail
OUT="${1:?usage: make_fixtures.sh <dir>}"
mkdir -p "$OUT"; cd "$OUT"
ff() { ffmpeg -hide_banner -nostdin -loglevel error -y "$@"; }

if [ ! -f speech.wav ]; then
  say -v Samantha -o s1.aiff "Welcome back to the channel. Today we are going to normalize the audio on a Final Cut Pro export, so it lands right at minus fourteen LUFS for YouTube."
  say -v Samantha -o s2.aiff "The trick is to measure first, then lift the quiet source, compress it gently, limit the peaks, and only then let loudnorm do the last stretch."
  say -v Samantha -o s3.aiff "If the correction would push the true peak over minus one, we simply ship the first stage and accept being a little under target."
  # speech, 2.5 s pause (NR-gated digital silence), speech, pause, speech
  ff -i s1.aiff -i s2.aiff -i s3.aiff -filter_complex \
    "[0]aresample=48000,apad=pad_dur=2.5[a];[1]aresample=48000,apad=pad_dur=2.5[b];[2]aresample=48000[c];[a][b][c]concat=n=3:v=0:a=1,pan=stereo|c0=c0|c1=c0" \
    -c:a pcm_s16le speech.wav
  rm -f s1.aiff s2.aiff s3.aiff
fi
D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 speech.wav)

# level <in.wav> <target LUFS> <out.wav>
level() {
  local i; i=$(ffmpeg -hide_banner -nostdin -i "$1" -af loudnorm=print_format=json -f null - 2>&1 | awk '/^\{/,/^\}/' | jq -r .input_i)
  ff -i "$1" -af "volume=$(awk -v t="$2" -v i="$i" 'BEGIN{print t-i}')dB" -c:a pcm_s16le "$3"
}
# mkvid <audio> <out> [extra ffmpeg args…]
mkvid() {
  local a="$1" o="$2"; shift 2
  ff -f lavfi -i "testsrc2=s=320x240:r=30:d=$D" -i "$a" -map 0:v -map 1:a -shortest \
     -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 192k "$@" "$o"
}

level speech.wav -28 normal.wav       # like v10: pre-gain ≈ +7
level speech.wav -41 quiet.wav        # like the 0 dB-gain era: pre-gain ≈ +20 (drift warning)
mkvid normal.wav normal.mp4
mkvid quiet.wav quiet.mp4
# Mixed sources: first half raw-ish (-40), second half "Enhance Audio" (-18)
H=$(awk -v d="$D" 'BEGIN{print d/2}')
ff -i speech.wav -filter_complex "[0]asplit[x][y];[x]atrim=0:$H,volume=-14dB[p];[y]atrim=$H,asetpts=PTS-STARTPTS,volume=10dB[q];[p][q]concat=n=2:v=0:a=1" -c:a pcm_s16le mixed.wav
mkvid mixed.wav mixed.mp4
# Clipped at the mic: hard-clipped hot speech
# Like +6/+6 gain: hot narration plus one shouted phrase that hard-clips
# (float→s16 conversion clips anything over full scale).
ff -i normal.wav -af "volume=12dB,volume=volume=14dB:enable='between(t,3,4)'" -c:a pcm_s16le clipped.wav
mkvid clipped.wav clipped.mp4
# No audio
ff -f lavfi -i "testsrc2=s=320x240:r=30:d=3" -c:v libx264 -preset ultrafast -pix_fmt yuv420p noaudio.mp4
# .mov with timecode track (like FCP)
mkvid normal.wav fcp.mov -timecode 01:00:00:00
# ProRes .mov
ff -f lavfi -i "testsrc2=s=320x240:r=30:d=$D" -i normal.wav -map 0:v -map 1:a -shortest -c:v prores_ks -profile:v 0 -c:a pcm_s16le prores.mov
# Already at -14 (should be skipped)
level speech.wav -14 hot14.wav
ff -i hot14.wav -af alimiter=limit=0.7:level=disabled -c:a pcm_s16le hot14l.wav
mkvid hot14l.wav already.mp4
# ~10 min, for the Ctrl-C test (long enough to interrupt mid-encode)
for _ in $(seq 1 20); do echo "file '$PWD/normal.mp4'"; done >long.txt
ff -f concat -safe 0 -i long.txt -c copy long.mp4
rm -f hot14.wav hot14l.wav long.txt
ls -la
