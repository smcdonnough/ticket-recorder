# ticket-recorder

Records The Musers and The Hardline from The Ticket (KTCK 96.7 FM / 1310 AM, Dallas)
off the station's public stream every weekday and saves each show to a "The Ticket"
folder in Google Drive. Recordings older than 30 days are deleted.

- `record.sh` — records the stream until the show's end time, then uploads.
- `.github/workflows/record.yml` — the weekday schedule (5:00–9:05 AM and 2:30–7:05 PM Central).
- `drive-upload.gs` — Google Apps Script web app that hands out Drive upload links.
  Its deployed URL, with `?key=<key>` appended, goes in the `DRIVE_UPLOAD_URL` repo secret.

Run the workflow manually ("Run workflow") for a 2-minute test recording.

## Planned: ad removal

After upload, transcribe (Whisper, word timestamps), have Claude mark non-show stretches, and cut
them to produce "<date> <show> (no ads).m4a" alongside the full recording, plus a cut list.

Cut: commercial spots, **host live reads** (decided 2026-09-23), traffic/weather, station promos,
news breaks. Snap each cut to the nearest pause. Keep full recordings until the cuts are trusted.
Spot-check a few real shows before enabling automatic cutting.
