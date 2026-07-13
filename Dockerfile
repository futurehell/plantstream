FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb \
    chromium \
    ffmpeg \
    intel-media-va-driver \
    libvpl2 \
    && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
RUN chmod +x /start.sh

CMD ["/start.sh"]
