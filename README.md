# plantstream

A self-healing 24/7 stream: a headless Debian container runs Xvfb + Chromium to
render a camera page, and ffmpeg captures that virtual display and pushes it to
YouTube Live over RTMP (CBR H.264). A watchdog reloads Chromium automatically if
the feed goes **black** or **freezes**, so the stream survives renderer wedges
without a babysitter.

## Run it

```bash
cp .env.example .env      # fill in camera creds, YouTube key, and page URL
docker compose up -d --build
docker logs -f plantstream
```

## How it works

- **Xvfb** — a 1920x1080 virtual X display (`:99`), no monitor needed.
- **Chromium** — kiosk mode, loads `$URL` (a camera view / dashboard).
- **ffmpeg** — `x11grab` of the display + looped music → YouTube RTMP at a
  constant 6800k (CBR keeps YouTube's ingest happy when plants barely move).
- **Watchdog** — every `CHECK_SECS` it samples the display two ways:
  - *black*: average luma of a crop drops below `BLACK_LEVEL`
  - *frozen*: the whole frame is byte-identical across `FREEZE_HITS` checks
    (live camera feeds always jitter from sensor noise, so identical frames
    mean the render genuinely stalled)

  On either condition it kills and relaunches Chromium; the stream never drops.

## Config

All via `.env` (see `.env.example`). Watchdog tunables have sane defaults in
`start.sh` and can be overridden per-deployment.

## Not in this repo

- `.env` — real keys/credentials (gitignored)
- `music/` — the background playlist is third-party music, not redistributed
  here; drop your own tracks in `music/` and point the ffmpeg concat playlist
  at them
