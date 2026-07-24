# plantstream

A self-healing 24/7 stream: a headless Debian container runs Xvfb + Chromium to
render a camera page, and ffmpeg captures that virtual display and pushes it to
YouTube Live over RTMP (CBR H.264). Two independent watchdogs keep it alive —
one proves the *picture* is healthy, one proves the *uplink* is healthy — so
the stream survives renderer wedges and dead sockets without a babysitter.

## Run it

```bash
cp .env.example .env      # fill in your YouTube key and page URL
docker compose up -d --build
docker logs -f plantstream
```

Optional: drop audio tracks in `music/` and list them in
`music/playlist.txt` (ffmpeg concat format). No playlist? The stream runs
with silent audio instead of dying.

## How it works

- **Xvfb** — a 1920x1080 virtual X display (`:99`), no monitor needed.
- **Chromium** — kiosk mode, loads `$URL` (a camera view / dashboard).
- **ffmpeg** — `x11grab` of the display + looped music → YouTube RTMP at a
  constant 6800k (CBR keeps YouTube's ingest happy when plants barely move).

### Feed watchdog (is the picture healthy?)

Every `CHECK_SECS` it samples the display three ways:

- *black*: average luma of a crop drops below `BLACK_LEVEL`
- *frozen*: the whole frame is byte-identical across `FREEZE_HITS` checks
  (live camera feeds always jitter from sensor noise, so identical frames
  mean the render genuinely stalled)
- *blank*: the frame PNG-compresses below `MIN_FRAME_BYTES` — a loading
  spinner or error page is tiny, a real 1080p camera frame isn't. This
  catches the case the other two sleep through: an animated spinner that's
  neither dark nor frozen.

On any of the three it kills and relaunches Chromium; the stream never drops.

### Uplink watchdog (are bytes actually reaching YouTube?)

The feed watchdog can only ever prove Chromium is drawing. The failure that
motivated this second watchdog: ffmpeg kept "running" but stopped pushing RTMP
— blocked on a dead socket — so YouTube ended the broadcast while the virtual
display looked perfect, and because ffmpeg never *exited*, Docker's restart
policy never fired. The stream stayed dark until a manual restart.

Fix: ffmpeg writes `-progress` output continuously, and the watchdog verifies
`out_time_ms` keeps advancing. If it stalls for `UPLINK_STALL_SECS`, the
watchdog kills ffmpeg — which is PID 1, so the container exits and Docker's
`restart: unless-stopped` brings it back with a fresh RTMP session. This
catches *any* stall cause, not just socket timeouts.

## Config

All via `.env` (see `.env.example`). Watchdog tunables have sane defaults in
`start.sh` and can be overridden per-deployment.

## Repo extras

- `setup-vm.sh` — one-shot bootstrap for a fresh Debian 12 VM (Docker install)
- `docs/` — the stream overlay graphic and a project case sheet

## Not in this repo

- `.env` — real keys/credentials (gitignored)
- `music/` — the background playlist is third-party music, not redistributed
  here; drop your own tracks in `music/` and point `music/playlist.txt`
  at them

## License

MIT
