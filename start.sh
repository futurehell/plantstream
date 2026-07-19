#!/bin/bash
# plantstream — Xvfb + Chromium page capture → YouTube.
#
# (Twitch output removed 2026-07: the account was banned for streaming
#  plants that grow at plant speed over music.  Their loss.  To add any
#  other RTMP destination later, copy the YouTube block into a backgrounded
#  self-retrying loop like the old Twitch one — see git history.)
#
# Hardened: a watchdog samples the camera region every minute; if it goes black
# (the video element stalled), it reloads Chromium so the stream self-heals.
# The camera is H.264, so software decode (--disable-gpu) is correct and stable.
#
# UPLINK WATCHDOG (added 2026-07-19 after a silent outage): the display-based
# watchdog above only ever proves CHROMIUM is healthy — it cannot see whether
# bytes are actually reaching YouTube. Observed failure: ffmpeg kept running but
# stopped pushing RTMP (blocked on a dead socket, no timeout on the output), so
# YouTube saw no data and ended the broadcast while the virtual display looked
# perfect. Because ffmpeg never EXITED, `restart: unless-stopped` never fired and
# the stream stayed dark until a manual `docker restart`.
#
# Fix: ffmpeg now writes -progress to $PROGRESS_FILE, and a second watchdog
# verifies out_time_ms keeps ADVANCING. A stall kills ffmpeg — which is PID 1,
# so the container exits and Docker restarts it clean, reconnecting to YouTube
# on its own. This catches ANY stall cause, not just socket timeouts.
set -e

# ── watchdog tunables (override in .env) ─────────────────────────────────────
CHECK_SECS="${CHECK_SECS:-60}"        # how often to sample the feed
BLACK_HITS="${BLACK_HITS:-3}"         # consecutive dark samples before reloading
BLACK_LEVEL="${BLACK_LEVEL:-16}"      # avg luma 0-255; below this = "black"
CAM_CROP="${CAM_CROP:-600:400:428:285}"  # WxH:X:Y sample box inside the camera feed
FREEZE_HITS="${FREEZE_HITS:-3}"       # consecutive byte-identical frames before reloading
                                      # (live cam feeds always differ via sensor noise,
                                      #  so identical frames == genuinely stalled render)
MIN_FRAME_BYTES="${MIN_FRAME_BYTES:-800000}"  # a live 1080p camera frame PNG-compresses to
                                      # 2-3 MB; a loading spinner / blank / error page is
                                      # tiny. Frames under this = "not showing video".
BLANK_HITS="${BLANK_HITS:-3}"         # consecutive tiny frames before reloading

# ── uplink watchdog tunables (override in .env) ──────────────────────────────
PROGRESS_FILE="${PROGRESS_FILE:-/tmp/ffprogress.txt}"  # ffmpeg -progress target
UPLINK_CHECK_SECS="${UPLINK_CHECK_SECS:-15}"  # how often to verify the uplink advanced
UPLINK_STALL_SECS="${UPLINK_STALL_SECS:-60}"  # no progress for this long = dead uplink.
                                      # Generous: brief RTMP hiccups self-heal, and a
                                      # container restart costs a reconnect, so we only
                                      # act on a genuine stall.

launch_chromium() {
  chromium \
    --no-sandbox --disable-gpu --kiosk \
    --window-size=1920,1080 --window-position=0,0 \
    --disable-infobars --disable-translate --disable-extensions \
    --autoplay-policy=no-user-gesture-required \
    "${URL}" &
}

echo ">>> Cleaning up stale X locks / orphans..."
pkill -9 Xvfb 2>/dev/null || true
pkill -9 chromium 2>/dev/null || true
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
sleep 1

echo ">>> Starting virtual display..."
Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &
export DISPLAY=:99
sleep 2

echo ">>> Starting Chromium -> ${URL}"
launch_chromium
echo ">>> Waiting for page to load..."
sleep 8

# ── feed watchdog: reload Chromium if the feed goes black OR freezes ─────────
# Two independent failure modes, two detectors:
#   • BLACK  — the camera region drops below BLACK_LEVEL luma (feed cut to dark).
#   • FROZEN — the whole captured frame is byte-identical across FREEZE_HITS
#     checks. This catches the nasty case the old black-only watchdog slept
#     through: Chromium's renderer soft-wedges after a day or two and keeps a
#     *lit* still frame on screen, so ffmpeg streams a frozen picture forever.
#     Live camera feeds always jitter (sensor noise), so identical frames are a
#     reliable "nothing is updating" signal — no false positives on slow plants.
echo ">>> Starting feed watchdog (every ${CHECK_SECS}s: black<${BLACK_LEVEL}, freeze x${FREEZE_HITS}, blank<${MIN_FRAME_BYTES}B x${BLANK_HITS})..."
(
  black_hits=0
  freeze_hits=0
  blank_hits=0
  last_md5=""
  sleep 30   # let the page settle before the first check
  while true; do
    # black detector: avg luma of the camera crop
    ffmpeg -hide_banner -loglevel error \
      -f x11grab -video_size 1920x1080 -i :99 -frames:v 1 \
      -vf "crop=${CAM_CROP},format=yuv420p,signalstats,metadata=print:file=/tmp/lum.txt:key=lavfi.signalstats.YAVG" \
      -f null - 2>/dev/null || true
    lum=$(grep -oE 'YAVG=[0-9]+' /tmp/lum.txt 2>/dev/null | head -1 | cut -d= -f2)
    lum=${lum:-255}

    # one full-frame PNG grab feeds BOTH the freeze (md5) and blank (size) checks
    ffmpeg -hide_banner -loglevel error \
      -f x11grab -video_size 1920x1080 -i :99 -frames:v 1 \
      -f image2 -y /tmp/frame.png 2>/dev/null || true
    frame_md5=$(md5sum /tmp/frame.png 2>/dev/null | cut -d' ' -f1)
    frame_bytes=$(stat -c%s /tmp/frame.png 2>/dev/null || echo 999999999)

    reason=""

    if [ "$lum" -lt "$BLACK_LEVEL" ]; then
      black_hits=$((black_hits + 1))
      echo "$(date) [watchdog] camera dark (YAVG=$lum) ${black_hits}/${BLACK_HITS}"
      [ "$black_hits" -ge "$BLACK_HITS" ] && reason="black"
    else
      black_hits=0
    fi

    if [ -n "$frame_md5" ] && [ "$frame_md5" = "$last_md5" ]; then
      freeze_hits=$((freeze_hits + 1))
      echo "$(date) [watchdog] frame frozen (md5 unchanged) ${freeze_hits}/${FREEZE_HITS}"
      [ "$freeze_hits" -ge "$FREEZE_HITS" ] && reason="frozen"
    else
      freeze_hits=0
    fi
    last_md5="$frame_md5"

    # blank detector: a loading spinner / error page compresses tiny.
    # Catches the "3s loading loop" the md5+black checks sleep through
    # (the spinner animates, so md5 keeps changing, and it isn't dark).
    if [ "$frame_bytes" -lt "$MIN_FRAME_BYTES" ]; then
      blank_hits=$((blank_hits + 1))
      echo "$(date) [watchdog] frame blank/loading (${frame_bytes}B) ${blank_hits}/${BLANK_HITS}"
      [ "$blank_hits" -ge "$BLANK_HITS" ] && reason="blank"
    else
      blank_hits=0
    fi

    if [ -n "$reason" ]; then
      echo "$(date) [watchdog] feed ${reason} — reloading Chromium"
      pkill -9 chromium 2>/dev/null || true
      sleep 2
      launch_chromium
      black_hits=0; freeze_hits=0; blank_hits=0; last_md5=""
      sleep 20   # give it time to reload before sampling again
    fi
    sleep "$CHECK_SECS"
  done
) &

# ── uplink watchdog: restart the container if ffmpeg stops PUSHING ──────────
# The display watchdog above proves Chromium is drawing; this one proves the
# stream is actually leaving the box. ffmpeg's -progress block appends
# `out_time_ms=<n>` roughly once a second while it is genuinely muxing. If that
# number stops advancing (socket wedged, encoder deadlocked, YouTube dropped us)
# we kill ffmpeg. It is PID 1, so the container exits and Docker's
# `restart: unless-stopped` brings it straight back with a fresh RTMP session.
#
# Note it waits for the file to appear first: ffmpeg starts AFTER this loop, and
# a missing file at boot is normal, not a stall.
echo ">>> Starting uplink watchdog (stall = no ffmpeg progress for ${UPLINK_STALL_SECS}s)..."
(
  rm -f "${PROGRESS_FILE}" 2>/dev/null || true
  last_out=""
  last_change=$(date +%s)
  started=0
  while true; do
    sleep "${UPLINK_CHECK_SECS}"

    # out_time_ms is appended repeatedly; the LAST one is the current position.
    out=$(grep -a '^out_time_ms=' "${PROGRESS_FILE}" 2>/dev/null | tail -1 | cut -d= -f2)

    if [ -z "$out" ]; then
      # No progress data yet. Before ffmpeg's first write that's just startup;
      # after it, treat a vanished/empty file as a stall via the same timer.
      [ "$started" -eq 0 ] && continue
    else
      started=1
    fi

    now=$(date +%s)
    if [ -n "$out" ] && [ "$out" != "$last_out" ]; then
      last_out="$out"
      last_change=$now
      continue
    fi

    stalled=$(( now - last_change ))
    if [ "$stalled" -ge "${UPLINK_STALL_SECS}" ]; then
      echo "$(date) [uplink] NO PROGRESS for ${stalled}s (out_time_ms stuck at ${last_out:-none})"
      echo "$(date) [uplink] killing ffmpeg — container will restart and reconnect"
      pkill -9 -f 'ffmpeg.*rtmp://' 2>/dev/null || true
      exit 0
    fi
    echo "$(date) [uplink] no progress for ${stalled}s (limit ${UPLINK_STALL_SECS}s)"
  done
) &

# --- YouTube: the critical stream, main process ---
# True CBR: plants barely move, so a plain target bitrate undershoots to
# ~2 Mbps and YouTube's ingest sulks ("preparing stream", low-bitrate
# warnings).  nal-hrd=cbr pads the encode to a constant 6800k so YT gets
# the steady feed it recommends.  CPU headroom came free with the Twitch
# encoder's departure.
echo ">>> Starting FFmpeg stream (YouTube)..."
exec ffmpeg \
  -thread_queue_size 1024 -f x11grab -draw_mouse 0 -r 30 -s 1920x1080 -i :99 \
  -thread_queue_size 1024 -stream_loop -1 -f concat -safe 0 -i /config/music/playlist.txt \
  -filter_complex "[0:v]scale=1920:1080,fps=30,format=yuv420p[v]" \
  -map "[v]" \
  -map "1:a" \
  -c:v libx264 -preset veryfast \
  -b:v 6800k -minrate 6800k -maxrate 6800k -bufsize 13600k \
  -x264-params "nal-hrd=cbr:force-cfr=1" \
  -pix_fmt yuv420p -g 60 \
  -c:a aac -b:a 128k -ar 44100 -ac 2 \
  -rw_timeout 20000000 \
  -progress "${PROGRESS_FILE}" \
  -f flv "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_KEY}"
