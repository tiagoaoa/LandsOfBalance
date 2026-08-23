#!/usr/bin/env bash
# Container entrypoint: bring up a private PulseAudio, then the gateway.
set -euo pipefail
mkdir -p "${XDG_RUNTIME_DIR:-/tmp/xdg}" /tmp/lobcloud
# A per-container Pulse daemon; every session adds its own null sink to it.
pulseaudio --daemonize=yes --exit-idle-time=-1 --disallow-exit \
  --log-target=file:/tmp/lobcloud/pulseaudio.log \
  -L "module-native-protocol-unix" -L "module-null-sink sink_name=dummy" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pactl info >/dev/null 2>&1 && break; sleep 0.3; done
if ! pactl info >/dev/null 2>&1; then echo "pulseaudio did not start; audio disabled"; export LOB_AUDIO=0; fi
# The C game_server can ride along: LOB_GAME_SERVER=1 with the binary at LOB_GAME_SERVER_BIN.
exec lobcloud "$@"
