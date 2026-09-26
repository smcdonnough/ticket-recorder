# CLAUDE.md — ticket-recorder

**Read [HANDOFF.md](HANDOFF.md) first.** It has the running state: what is live, the Drive
folder and feed, the scheduled check-ins and their IDs, Sean's decisions, and open items.
Keep it current as things change.

## What this is

Records The Musers (6–9 AM) and The Hardline (3–7 PM) from The Ticket (KTCK, Dallas) every
weekday, crops to air time, transcribes, has Claude find the ads, cuts them, and saves an
ad-free episode to Google Drive, which also publishes a private podcast feed Sean listens to in
Apple Podcasts.

- `record.sh`: records the stream, crops to air time, uploads the full recording.
- `process.py`: transcription (faster-whisper), ad review (Claude), cutting (ffmpeg), uploads,
  feed refresh. `INSTRUCTIONS` holds the ad rules.
- `.github/workflows/record.yml`: the record → remove-ads pipeline. `reprocess.yml` reruns ad
  removal on an earlier run's recording (the hand-off copy is kept one day).
- `drive-upload.gs`: the Google Apps Script web app (uploads, 30-day cleanup, podcast feed).
  Sean pastes it into script.google.com himself; the repo copy has a placeholder key.

## Rules

- **The repo is public.** Never commit the Apps Script URL, its key, the Anthropic key, or any
  token. They live in GitHub repo secrets (`DRIVE_UPLOAD_URL`, `ANTHROPIC_API_KEY`) and in
  Sean's Apps Script.
- Push straight to `main`; the workflows run from `main`. Verify on `origin/main` after pushing.
- Before claiming a change works, run it: a manual run of record.yml (show `Test` = 10-minute
  sample) or `reprocess.yml`, then check the files in Drive.
- When changing the ad rules, check the result against a real transcript and cut list (a
  subagent reading both in full works well) before telling Sean it is better.
- Any change to `drive-upload.gs` needs Sean to paste it and redeploy (Deploy → Manage
  deployments → edit → New version). Keep those asks rare and give him the full code in a
  fenced block with the key already filled in.

## How to talk to Sean

He is not a coder. No branches, commits, file names, YAML or tool names in replies: say what
happens in plain words. Anything he must copy goes in a fenced block. Lead with what he needs to
do. Only message him from a scheduled check-in when something is wrong or needs his call.
