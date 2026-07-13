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
set -e

# ── watchdog tunables (override in .env) ─────────────────────────────────────
CHECK_SECS="${CHECK_SECS:-60}"        # how often to sample the feed
BLACK_HITS="${BLACK_HITS:-3}"         # consecutive dark samples before reloading
BLACK_LEVEL="${BLACK_LEVEL:-16}"      # avg luma 0-255; below this = "black"
CAM_CROP="${CAM_CROP:-600:400:428:285}"  # WxH:X:Y sample box inside the camera feed
FREEZE_HITS="${FREEZE_HITS:-3}"       # consecutive byte-identical frames before reloading
                                      # (live cam feeds always differ via sensor noise,
                                      #  so identical frames == genuinely stalled render)

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
echo ">>> Starting feed watchdog (every ${CHECK_SECS}s: black<${BLACK_LEVEL} crop ${CAM_CROP}, freeze x${FREEZE_HITS})..."
(
  black_hits=0
  freeze_hits=0
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

    # freeze detector: md5 of the full captured frame
    frame_md5=$(ffmpeg -hide_banner -loglevel error \
      -f x11grab -video_size 1920x1080 -i :99 -frames:v 1 \
      -f md5 - 2>/dev/null | sed -n 's/^MD5=//p')

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

    if [ -n "$reason" ]; then
      echo "$(date) [watchdog] feed ${reason} — reloading Chromium"
      pkill -9 chromium 2>/dev/null || true
      sleep 2
      launch_chromium
      black_hits=0; freeze_hits=0; last_md5=""
      sleep 20   # give it time to reload before sampling again
    fi
    sleep "$CHECK_SECS"
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
  -f flv "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_KEY}"
