"""Transcribe a recorded show, have Claude mark the non-show stretches, and cut them.

    python process.py <audio.m4a> <show> <YYYY-MM-DD>

Uploads to the Drive folder (via DRIVE_UPLOAD_URL):
  <date> <show> transcript.txt   - always
  <date> <show> (no ads).m4a     - when ANTHROPIC_API_KEY is set
  <date> <show> cut list.txt     - what was removed, with times
"""
import os
import subprocess
import sys
import time
from typing import List, Literal

import requests
from pydantic import BaseModel

WHISPER_MODEL = os.environ.get("WHISPER_MODEL", "base.en")
CLAUDE_MODEL = "claude-opus-5"
FFMPEG = os.environ.get("FFMPEG", "ffmpeg")

INSTRUCTIONS = """\
This is a timestamped transcript of a recording of The Ticket (KTCK, Sportsradio 96.7 FM /
1310 AM, Dallas), a sports-talk station. Each line is: line number | start time | text.
The listener wants the show with everything that is not the hosts' show content removed.

Mark for removal:
- commercial spots (pre-produced ads: sponsor names, prices, phone numbers, web addresses,
  "call now", "visit", disclaimers, jingles)
- live reads: the hosts reading sponsor copy themselves, including the host's lead-in into
  the read ("this hour brought to you by...", "let me tell you about...") and the tag out
- traffic and weather updates, news breaks
- station promos, imaging and station IDs, promos for other shows or events
- network programming breaks that are ads (e.g. overnight Fox Sports Radio commercial breaks)

Keep everything else: host conversation, interviews, callers, bits, sports talk, and show
openings/teases that are the hosts talking about the show itself.

Rules:
- A removal is a contiguous range of lines, first_line to last_line inclusive.
- Merge adjacent ad material into one range (a break is usually several spots in a row).
- When a line is genuinely ambiguous, keep it. Cutting show content is worse than leaving
  a few seconds of an ad.
- Transcription is imperfect (names and slang are often garbled); judge from context.
- Return an empty list if nothing should be removed.
"""


class Removal(BaseModel):
    first_line: int
    last_line: int
    kind: Literal["commercial", "live_read", "traffic_weather_news", "promo", "other"]
    note: str


class Removals(BaseModel):
    removals: List[Removal]


def hms(t):
    t = int(t)
    return f"{t // 3600}:{t // 60 % 60:02d}:{t % 60:02d}"


def transcribe(path):
    from faster_whisper import WhisperModel

    model = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")
    started = time.time()
    segments, info = model.transcribe(path, beam_size=1, vad_filter=True)
    segs = [(s.start, s.end, s.text.strip()) for s in segments if s.text.strip()]
    print(f"Transcribed {hms(info.duration)} of audio in {hms(time.time() - started)}"
          f" ({len(segs)} lines)", flush=True)
    return segs, info.duration


def find_removals(segs, chunk=1200):
    """Ask Claude one hour-ish slice at a time; ranges that meet at a seam merge later."""
    import anthropic

    client = anthropic.Anthropic(max_retries=5)
    found = []
    for lo in range(0, len(segs), chunk):
        hi = min(lo + chunk, len(segs))
        lines = "\n".join(f"{i}|{hms(segs[i][0])}|{segs[i][2]}" for i in range(lo, hi))
        response = client.messages.parse(
            model=CLAUDE_MODEL,
            max_tokens=16000,
            system=INSTRUCTIONS,
            messages=[{"role": "user", "content": lines}],
            output_format=Removals,
        )
        if response.stop_reason in ("refusal", "max_tokens") or response.parsed_output is None:
            raise RuntimeError(f"No usable answer for lines {lo}-{hi - 1}"
                               f" (stop_reason={response.stop_reason})")
        u = response.usage
        print(f"Claude, lines {lo}-{hi - 1}: {u.input_tokens} in / {u.output_tokens} out tokens,"
              f" {len(response.parsed_output.removals)} removals", flush=True)
        found += response.parsed_output.removals
    return found


def cut_ranges(segs, duration, removals):
    """Seconds to drop: from the first removed line's start to the next kept line's start."""
    ranges = []
    for r in sorted(removals, key=lambda r: r.first_line):
        a = max(0, min(r.first_line, len(segs) - 1))
        b = max(a, min(r.last_line, len(segs) - 1))
        start = segs[a][0]
        end = segs[b + 1][0] if b + 1 < len(segs) else duration
        if ranges and start - ranges[-1][1] < 3:  # swallow slivers between breaks
            ranges[-1][1] = max(ranges[-1][1], end)
        else:
            ranges.append([start, end])
    return ranges


def render_without(src, dst, ranges, duration):
    keep, t = [], 0.0
    for a, b in ranges:
        if a > t:
            keep.append((t, a))
        t = max(t, b)
    if duration > t:
        keep.append((t, duration))
    parts = "".join(
        f"[0:a]atrim={a:.2f}:{b:.2f},asetpts=PTS-STARTPTS[k{i}];" for i, (a, b) in enumerate(keep))
    concat = "".join(f"[k{i}]" for i in range(len(keep))) + f"concat=n={len(keep)}:v=0:a=1[out]"
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", src,
                    "-filter_complex", parts + concat, "-map", "[out]",
                    "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart", dst], check=True)
    return sum(b - a for a, b in keep)


def upload(path, content_type):
    url = os.environ.get("DRIVE_UPLOAD_URL")
    if not url:
        print(f"DRIVE_UPLOAD_URL not set; kept {path}")
        return
    name, size = os.path.basename(path), os.path.getsize(path)
    for attempt in range(5):
        try:
            s = requests.Session()  # keeps the cookie Apps Script's redirect needs
            link = s.get(url, params={"name": name, "size": size}, timeout=120).text.strip()
            if link.startswith("https://"):
                with open(path, "rb") as f:
                    requests.put(link, data=f, headers={"Content-Type": content_type},
                                 timeout=1800).raise_for_status()
                print(f"Uploaded {name}", flush=True)
                return
            print(f"Upload link request failed: {link[:200]}")
        except requests.RequestException as e:
            print(f"Upload attempt {attempt + 1} failed: {e}")
        time.sleep(20)
    raise RuntimeError(f"Could not upload {name}")


def main():
    src, show, day = sys.argv[1:4]
    base = f"{day} {show}"
    segs, duration = transcribe(src)

    transcript = f"{base} transcript.txt"
    with open(transcript, "w") as f:
        f.writelines(f"[{hms(s)}] {text}\n" for s, _, text in segs)
    upload(transcript, "text/plain")

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY not set; skipping ad removal.")
        return
    if not segs:
        print("Empty transcript; skipping ad removal.")
        return

    removals = find_removals(segs)
    ranges = cut_ranges(segs, duration, removals)
    clean = f"{base} (no ads).m4a"
    kept = render_without(src, clean, ranges, duration)
    removed = duration - kept
    print(f"Removed {len(ranges)} stretches, {hms(removed)} of {hms(duration)}", flush=True)

    cut_list = f"{base} cut list.txt"
    with open(cut_list, "w") as f:
        f.write(f"{base}: removed {hms(removed)} of {hms(duration)} in {len(ranges)} cuts\n\n")
        for r in sorted(removals, key=lambda r: r.first_line):
            a = min(r.first_line, len(segs) - 1)
            b = min(r.last_line, len(segs) - 1)
            f.write(f"{hms(segs[a][0])}-{hms(segs[b][1])}  {r.kind:20s} {r.note}\n")
    upload(clean, "audio/mp4")
    upload(cut_list, "text/plain")


if __name__ == "__main__":
    main()
