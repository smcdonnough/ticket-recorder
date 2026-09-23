#!/usr/bin/env bash
# Records one Ticket show from the live stream until a fixed Central-time end,
# then uploads it to Google Drive through the Apps Script endpoint.
#
#   record.sh <show-name> <utc-offset> <end-HH:MM-CT>
#
# GitHub schedules run in UTC, so each show is scheduled twice: once for
# daylight time (-0500) and once for standard time (-0600). The run whose
# offset isn't in effect today exits without recording.
set -euo pipefail

SHOW="$1"; OFFSET="$2"; END_CT="$3"
STREAM="https://playerservices.streamtheworld.com/api/livestream-redirect/KTCKAMAAC.aac"
FFMPEG="${FFMPEG:-ffmpeg}"
export TZ=America/Chicago

if [[ "${FORCE:-}" != "1" && "$OFFSET" != "ANY" && "$(date +%z)" != "$OFFSET" ]]; then
  echo "Central offset today is $(date +%z); this run is for $OFFSET. Skipping."
  exit 0
fi

DAY="$(date +%F)"
END_EPOCH="$(date -d "$DAY $END_CT" +%s)"
[[ -n "${MAX_SECONDS:-}" ]] && END_EPOCH=$(( $(date +%s) + MAX_SECONDS ))
if [[ -z "${MAX_SECONDS:-}" ]] && (( $(date +%s) > END_EPOCH - 300 )); then
  # A backup trigger that fired after the show (another run already recorded it).
  echo "It's $(date +%H:%M) CT, past $END_CT. Nothing to record."; exit 0
fi
WORK="$(mktemp -d)"
echo "Recording $SHOW until $(date -d @"$END_EPOCH" +%H:%M) CT"

# Reconnect whenever the stream drops, until the end time.
REC_START="$(date +%s)"
n=0
while (( $(date +%s) < END_EPOCH - 5 )); do
  remaining=$(( END_EPOCH - $(date +%s) ))
  part="$WORK/part$(printf %03d $n).aac"
  timeout $(( remaining + 30 )) \
    curl -s -L --max-time "$remaining" "$STREAM" -o "$part" || true
  echo "segment $n: $(stat -c %s "$part" 2>/dev/null || echo 0) bytes"
  n=$((n + 1))
  (( $(date +%s) < END_EPOCH - 5 )) && sleep 3
done

find "$WORK" -name 'part*.aac' -empty -delete
if ! ls "$WORK"/part*.aac >/dev/null 2>&1; then
  echo "Nothing recorded (started after $END_CT CT, or the stream was down)."; exit 1
fi
cat "$WORK"/part*.aac > "$WORK/all.aac"

# Crop to air time (AIR_START/AIR_END, Central) with a 2-minute margin each
# side; the recording itself starts early and runs late on purpose. The stream
# replays ~1 minute of buffer on connect, so audio runs a little behind the
# wall clock: the front crop errs early, and the back crop is skipped when the
# stream reconnected mid-show (each reconnect adds more lag).
CROP=()
CLOCK0=$REC_START  # wall-clock time of the saved file's first second (approx.)
if [[ -n "${AIR_START:-}" ]]; then
  front=$(( $(date -d "$DAY $AIR_START" +%s) - 120 - REC_START ))
  if (( front > 0 )); then CROP+=(-ss "$front"); CLOCK0=$(( REC_START + front )); fi
  if [[ -n "${AIR_END:-}" && $n -eq 1 ]]; then
    back=$(( $(date -d "$DAY $AIR_END" +%s) + 120 - REC_START ))
    CROP+=(-to "$back")
  fi
  echo "Cropping to air time: ${CROP[*]:-(nothing to crop)}"
fi
OUT="$WORK/$DAY $SHOW.m4a"
"$FFMPEG" -hide_banner -loglevel error -i "$WORK/all.aac" "${CROP[@]}" -c copy -movflags +faststart "$OUT"
SIZE=$(stat -c %s "$OUT")
echo "Recorded $(( SIZE / 1048576 )) MB"

# Hand the file to the transcribe/ad-removal job.
if [[ -n "${OUT_DIR:-}" ]]; then
  mkdir -p "$OUT_DIR" && cp "$OUT" "$OUT_DIR/"
  { echo "recorded=true"; echo "show=$SHOW"; echo "day=$DAY"; echo "clock0=$CLOCK0"; } \
    >> "${GITHUB_OUTPUT:-/dev/null}"
fi

if [[ -z "${DRIVE_UPLOAD_URL:-}" ]]; then
  echo "DRIVE_UPLOAD_URL not set; leaving file at $OUT"; exit 0
fi

# Ask the Apps Script for a one-time Drive upload link, then send the file to it.
NAME="$(basename "$OUT")"
# Apps Script answers with a redirect that only resolves with its cookie kept.
SESSION=""
for attempt in 1 2 3 4 5; do
  SESSION=$(curl -sS --connect-timeout 30 -m 60 -L -c "$WORK/jar" -b "$WORK/jar" -G "$DRIVE_UPLOAD_URL" \
    --data-urlencode "name=$NAME" --data-urlencode "size=$SIZE" || true)
  case "$SESSION" in https://*) break;; esac
  sleep 20
done
case "$SESSION" in https://*) ;; *) echo "Upload link request failed: $SESSION"; exit 1;; esac
curl -sS --fail --retry 3 -X PUT -H "Content-Type: audio/mp4" --upload-file "$OUT" "$SESSION" -o /dev/null
echo "Uploaded $NAME to Google Drive"
