# Lands of Balance cloud gaming node.
#
# One container = one gateway = N game instances (LOB_MAX_SESSIONS), each in
# its own Xvfb with its own PulseAudio sink. Rendering inside the container
# is Mesa: a mounted /dev/dri (AMD/Intel) renders on the GPU through the
# software WSI path; without it lavapipe renders on the CPU. NVIDIA cards
# encode (NVENC) but do not render through Xvfb — for NVIDIA rendering run
# the gateway on the host with --display-mode xorg (see README).
#
# Build from the repo root:   docker build -f Cloud/docker/Dockerfile -t lobcloud .
# The game must be exported first:  Cloud/scripts/build_game.sh

FROM golang:1.24-bookworm AS gobuild
WORKDIR /src
COPY Cloud/go.mod Cloud/go.sum ./
RUN go mod download
COPY Cloud/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/lobcloud ./cmd/lobcloud \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/lobprobe ./cmd/lobprobe

FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11-utils x11-xserver-utils xdotool xauth \
      ffmpeg pulseaudio pulseaudio-utils \
      mesa-vulkan-drivers libvulkan1 libgl1 libegl1 libglu1-mesa vulkan-tools \
      libxcursor1 libxinerama1 libxrandr2 libxi6 libxkbcommon0 libxext6 libxrender1 libx11-6 \
      libasound2 libpulse0 libudev1 libdbus-1-3 fontconfig fonts-dejavu-core \
      libva2 libva-drm2 intel-media-va-driver mesa-va-drivers \
      ca-certificates tini procps \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 -G audio,video lob
WORKDIR /app
COPY --from=gobuild /out/lobcloud /out/lobprobe /usr/local/bin/
COPY Cloud/web/ /app/web/
COPY Cloud/docker/entrypoint.sh /app/entrypoint.sh
# The exported game (Cloud/scripts/build_game.sh writes build/lob_server.x86_64).
COPY build/lob_server.x86_64 /app/game/lob_server.x86_64
RUN chmod +x /app/entrypoint.sh /app/game/lob_server.x86_64 && chown -R lob:lob /app

USER lob
ENV LOB_LISTEN=:8080 \
    LOB_WEB_DIR=/app/web \
    LOB_GODOT=/app/game/lob_server.x86_64 \
    LOB_GAME_DIR= \
    LOB_DISPLAY_MODE=xvfb \
    LOB_LOG_DIR=/tmp/lobcloud \
    LOB_MAX_SESSIONS=2 \
    LOB_WIDTH=1280 LOB_HEIGHT=720 LOB_FPS=60 \
    LOB_ENCODER=auto \
    LOB_UDP_MIN=50000 LOB_UDP_MAX=50099 \
    XDG_RUNTIME_DIR=/tmp/xdg \
    NVIDIA_DRIVER_CAPABILITIES=all
EXPOSE 8080/tcp 50000-50099/udp
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
