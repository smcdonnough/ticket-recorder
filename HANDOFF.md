# HANDOFF — ticket-recorder (as of 2026-09-26)

Built 9/22–9/25 in a session that started in the pipeline-routine repo; moved here 9/26.
Nothing about the recorder depends on that session. The scheduled check-ins below were
re-created in the ticket-recorder session on 9/26.

## What runs, end to end

1. **Start.** A run of `record.yml` with `show: Musers` or `show: Hardline`. **GitHub's own cron
   is unreliable for this repo** (9/23: the 5 AM trigger never fired, others fired ~4 h late), so
   a Claude check-in starts each show by hand (see Check-ins). The cron entries stay as a backup;
   the per-show concurrency group de-dupes and late triggers exit cleanly once the show is over.
2. **Record** (`record.sh`). KTCK AAC stream (StreamTheWorld, HE-AACv2 48 kbps, ~22 MB/h). It
   reconnects on drops and records until 9:05 AM / 7:05 PM Central, then crops to air time ±2 min
   (Musers 6:00–9:00, Hardline 3:00–7:00; the 5:30 pregame is cropped by design). It uploads
   "<Show> <date> (<Day>) full with ads.m4a" to the Drive subfolder and hands the file to the
   next job as a 1-day artifact encrypted with the `DRIVE_UPLOAD_URL` secret (the repo is public).
3. **Remove ads** (`process.py`). faster-whisper base.en with word timestamps, each 30 s window
   transcribed fresh (`condition_on_previous_text=False`), lines split at sentence ends/pauses. Claude (`claude-opus-5`) reviews ~2,500-line slices and returns line
   ranges to remove. ffmpeg drops them, re-encodes AAC 64k, and uploads
   "<Show> <date> (<Day>).m4a" to the main folder plus the transcript and cut list (with
   approximate clock times and AI cost) to the subfolder. It then asks the Apps Script to
   rebuild the podcast feed.
4. **Apps Script** (`drive-upload.gs`, deployed from Sean's account at script.google.com).
   `?key=…&name=…&size=…[&sub=…]` returns a one-time resumable Drive upload link (needs a cookie
   jar: the redirect to googleusercontent 404s without it). Each call trashes files older than
   30 days. `?key=…&action=feed` rebuilds `feed.xml` and shares the episodes "anyone with link".
   **The deployed version = the repo file minus the `GH_TOKEN` / `setupSchedule` block** (Sean
   held off on that, 9/23).

## Where things are

- Drive main folder "The Ticket": `1simlYEztkruDeFOsxzQCck0_U32PkmUN` (only ad-free episodes).
- Subfolder "Full recordings & transcripts": `1oLvwwjvZ-WRy9Vo6xb3f-BZ1yb_apMSQ`.
- Podcast feed (Sean follows it in Apple Podcasts; works): `feed.xml` in the subfolder, at
  `https://drive.usercontent.google.com/download?id=<feed.xml id>&export=download&confirm=t`.
  Keep the real address out of this public repo: anyone with it can download every episode.
  (`confirm=t` is required: Drive flags .xml as executable and serves a warning page otherwise.)
- Secrets: repo secrets `DRIVE_UPLOAD_URL` (Apps Script URL + `?key=`) and `ANTHROPIC_API_KEY`.
  The Apps Script key is in Sean's deployed script. Never commit either.

## Sean's decisions

- Cut: commercials, paid live reads (with the host's lead-in), traffic/weather/news, the sports
  ticker, station promos/IDs/imaging (including lone ones between segments).
- Keep: host talk, time checks, teases, segment intros, short "brought to us by" tags in intros,
  and the hosts' own events/charity (e.g. the DNM Open golf tournament), thank-yous and podcast
  plugs. He accepts missing an occasional mid-segment read.
- Crop to actual show times. Only review the show.
- Keep full recordings as a backup for now; 30-day retention on everything.
- Cost: keep him close on it (weekly check). Budget ~$23/month at current settings. Planned
  savings: limit the AI review to the usual break windows once there is data (reminder 10/1), and
  maybe a cheaper model later after an A/B on the same show.
- 9/23: declined for now to set up the Google-started schedule (needs a GitHub token in his
  Apps Script). Offer it again only if manual starts become a burden or fail.

## Quality so far (verified against full transcripts)

- 9/23 Musers v2: all ads, reads and ticker caught; host talk kept. The hosts' own golf thank-you
  was kept. One 3 s tease clipped.
- 9/23 Hardline: ~10 s of host talk cut, ~3 min of lone station IDs/promos left in. The rules
  were tightened afterward (9/24).
- Break pattern seen so far (Musers): roughly :11–:19, :36–:42 and :51–:01 each hour. The
  Hardline has 13 breaks of 5–9 min and a ticker at about :03 and :23.
- Cost per show: Musers ~45¢, Hardline ~66¢.
- 9/23–9/25: Whisper stopped punctuating for the last 1.5–2.5 h of every Hardline (and 2 h of
  the 9/24 Musers), so lines ran host talk into ad copy and three 9/24 Hardline cuts took a few
  seconds of host talk. Cause: `condition_on_previous_text` (on by default). Turned off 9/26.
  Tested on the 9/24 Hardline episode: longest unpunctuated stretch 24 min → 75 s (the rest are
  isolated ≤75 s lapses, ~20 of 144 min), same speed, same amount of text, ~50% more lines.
- Input cost is ~1,900 tokens per call + ~12.3 tokens per transcript line (line number and
  timestamp) + ~0.27 per character of text (fit to all 11 calls 9/23–9/25, within 4%). The line
  labels are 32–53% of input. The turn-off above changes line counts only where punctuation
  used to drift (test: −8% tokens where it was fine, +38% where it had drifted), so expect
  ~15–20% more per Hardline and about the same per Musers, ~$2–3/month.
- Review-window check (9/26, 3 days, windows learned from 2 days and tested on the third):
  Musers breaks repeat within a couple of minutes (~:11–:21, :35–:45, :51–:02); ±3 min windows
  missed nothing and would send 75% of the tokens. Hardline breaks drift up to ~5 min: ±5 min
  windows miss nothing but send 93%; ±3 min send 78% and leave ~70 s of ads per show.

## Check-ins (Claude Code Routines)

Moved 9/26 from the old session (`session_01UCgeijFb58WcZUSZfjEds2`) to the ticket-recorder
session (`session_01FPfwPSpAXKMqFaqoLuxdKy`): same prompt text and schedule, old ones deleted.
Starting a show from the new session was checked the same day (a Musers start on a Saturday,
which exited "past 09:05, nothing to record"). If the recorder moves again, re-create each one
bound to the new session with the prompt text from `get_trigger`, then delete these.

| Id | What | When (UTC) |
|---|---|---|
| trig_015eTt6C3HL7AV7vZfvoSBkM | Start Musers if no run is recording; check last Hardline's remove-ads | 15 10 * * 1-5 |
| trig_01CG3MMQftyZKXfhKzbHPH2K | Start Hardline if no run is recording; check this morning's Musers | 45 19 * * 1-5 |
| trig_01B46Ps9L3wcTaYFSeG6sJLb | Weekly cost report to Sean (Mondays 9 AM CT) | 0 14 * * 1 |
| trig_01Lsj6VzWEjnof63PRHFQsi2 | One-shot: propose break-window review from the cut lists | 2026-10-01T15:00Z |

The one-shot's prompt says the cut lists are in the main folder; they are in the subfolder.

Do not touch the pipeline-routine (job search) routines, e.g. "Morning Brief". They are
unrelated.

## Open items

- 11/1 DST: the UTC check-in times become 4:15 AM / 1:45 PM CST. Recording still works: a
  Hardline started at 1:45 PM runs ~5 h 20 m, under the 350-min job limit.
- The Anthropic credit is prepaid ($10 initially). Remind Sean about auto-reload or a top-up if
  runs start failing with auth/billing errors.
- The Node 20 deprecation warning on actions/checkout@v4 is harmless for now.
- Transcripts and cut lists land in Drive as `audio/mp4`: `drive-upload.gs` sends
  `X-Upload-Content-Type: audio/mp4` for every upload. Fold a fix (pass the type through) into
  the next Apps Script change rather than asking Sean to redeploy for this alone.
