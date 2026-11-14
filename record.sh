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
EXTRAS="Full recordings & transcripts"  # Drive subfolder; the main folder holds only the no-ads shows
STREAM="${STREAM:-https://playerservices.streamtheworld.com/api/livestream-redirect/KTCKAMAAC.aac}"
# No audio at all this long after starting: give up on this runner so record.yml can start the
# show again on a fresh one (11/13: one runner got nothing for the whole Hardline while the
# stream was fine elsewhere). ATTEMPT counts those restarts; the fourth runner keeps trying.
SILENT_LIMIT="${SILENT_LIMIT:-600}"; ATTEMPT="${ATTEMPT:-1}"
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
GOT=0
while (( $(date +%s) < END_EPOCH - 5 )); do
  remaining=$(( END_EPOCH - $(date +%s) ))
  part="$WORK/part$(printf %05d $n).aac"
  # curl's own error is kept (sampled) so a dead stream says why (11/13: 4,529 empty segments
  # in a row, the whole Hardline, with no reason logged).
  err=$(timeout $(( remaining + 30 )) \
    curl -sS -L --max-time "$remaining" "$STREAM" -o "$part" 2>&1) || true
  size=$(stat -c %s "$part" 2>/dev/null || echo 0)
  if (( size > 0 || n < 5 || n % 100 == 0 )); then echo "segment $n: $size bytes${err:+ ($err)}"; fi
  GOT=$(( GOT + size ))
  if (( GOT == 0 && $(date +%s) - REC_START >= SILENT_LIMIT && ATTEMPT < 4 )) && [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "::warning::No audio for $(( SILENT_LIMIT / 60 )) min on this runner; restarting $SHOW on a fresh one."
    { echo "restart=true"; echo "restart_show=$SHOW"; } >> "$GITHUB_OUTPUT"
    exit 1
  fi
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
OUT="$WORK/$SHOW $DAY ($(date -d "$DAY" +%a)) full with ads.m4a"
# record.yml installs ffmpeg in the background while recording; wait for it, then install it
# here if that hasn't worked (the lock timeout waits out an apt still running in the background).
if ! command -v "$FFMPEG" >/dev/null; then
  echo "Waiting for ffmpeg..."
  for _ in $(seq 90); do command -v "$FFMPEG" >/dev/null && break; sleep 10; done
  command -v "$FFMPEG" >/dev/null || { sudo apt-get -o DPkg::Lock::Timeout=900 update -qq &&
    sudo apt-get -o DPkg::Lock::Timeout=900 install -y -qq ffmpeg; }
fi
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

# Ask the Apps Script for a one-time Drive upload link, then send the file to it; each try
# gets a fresh link. A failed upload costs only this Drive copy (the file is already handed to
# the ad-removal job above), so it warns instead of failing. 11/11: Drive answered 502 to every
# PUT, the old exit failed this step, the hand-off was skipped and that Hardline was lost.
# Worst case ~17 min, which a Hardline run (~5 h 22 m) still fits under the 350-min limit.
NAME="$(basename "$OUT")"
upload_once() {
  local session
  # Apps Script answers with a redirect that only resolves with its cookie kept.
  session=$(curl -sS --connect-timeout 30 -m 60 -L -c "$WORK/jar" -b "$WORK/jar" -G "$DRIVE_UPLOAD_URL" \
    --data-urlencode "name=$NAME" --data-urlencode "size=$SIZE" \
    --data-urlencode "sub=$EXTRAS" || true)
  case "$session" in https://*) ;; *) echo "Upload link request failed: ${session:0:200}"; return 1;; esac
  curl -sS --fail --connect-timeout 30 -m 240 -X PUT -H "Content-Type: audio/mp4" \
    --upload-file "$OUT" "$session" -o /dev/null
}
for attempt in 1 2 3; do
  if upload_once; then echo "Uploaded $NAME to Google Drive"; exit 0; fi
  (( attempt < 3 )) && sleep $(( attempt * 30 ))
done
echo "::warning::Could not upload $NAME to Google Drive after 3 tries; ad removal goes ahead with the hand-off copy."
