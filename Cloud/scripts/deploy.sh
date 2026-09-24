#!/usr/bin/env bash
# One front door for running the cloud gateway: on this laptop, or on a
# rented vast.ai GPU container over ssh.
#
#   scripts/deploy.sh local [lan]                # laptop: existing-display mode, http://localhost:8080
#   scripts/deploy.sh local lan                  # same, listening on the LAN + C game_server
#   scripts/deploy.sh vast push                  # build gateway + game, rsync to the instance, install deps
#   scripts/deploy.sh vast start [lobcloud args] # (re)start the gateway there, weston mode, print the URL
#   scripts/deploy.sh vast stop | status | logs | ssh
#   scripts/deploy.sh vast all                   # push + start
#
# The instance is named by VAST_SSH (e.g. "ssh://root@ssh5.vast.ai:12345",
# the "Direct ssh" line on the vast.ai console), or VAST_HOST + VAST_PORT.
# Pick it once:  export VAST_SSH=ssh://root@1.2.3.4:40000
#
# Other knobs (all optional): LOB_TOKEN, LOB_MAX_SESSIONS, LOB_WIDTH/HEIGHT/FPS,
# LOB_BITRATE, LOB_ENCODER, VAST_DIR (remote install dir, /workspace/lob),
# LOB_PORT (gateway's internal port, 8080 — map it as tcp when renting).
set -euo pipefail
cd "$(dirname "$0")/.."
CLOUD="$PWD"
ROOT="$(cd .. && pwd)"
GODOT="${GODOT:-/home/talves/bin/godot}"
LOB_PORT="${LOB_PORT:-8080}"
VAST_DIR="${VAST_DIR:-/workspace/lob}"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ---------------------------------------------------------------- local ---
run_local() {
    case "${1:-dev}" in
        dev|"") exec scripts/run_dev.sh "${@:2}" ;;
        lan)    exec scripts/run_lan.sh "${@:2}" ;;
        *)      usage ;;
    esac
}

# ----------------------------------------------------------------- vast ---
vast_target() {
    if [[ -n "${VAST_SSH:-}" ]]; then
        # ssh://user@host:port  or  "ssh -p PORT user@host"
        local s="${VAST_SSH#ssh://}"
        s="${s#ssh -p }"
        if [[ "$s" == *" "* ]]; then VAST_PORT="${s%% *}"; VAST_HOST="${s##* }"
        else VAST_HOST="${s%:*}"; VAST_PORT="${s##*:}"; fi
    fi
    [[ -n "${VAST_HOST:-}" ]] || { echo "Set VAST_SSH=ssh://root@HOST:PORT (or VAST_HOST/VAST_PORT)"; exit 1; }
    VAST_PORT="${VAST_PORT:-22}"
    SSH=(ssh -o StrictHostKeyChecking=accept-new -p "$VAST_PORT" "$VAST_HOST")
}
rssh() { "${SSH[@]}" "$@"; }

vast_push() {
    echo "== building gateway (linux/amd64, static)"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o bin/lobcloud ./cmd/lobcloud
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o bin/lobprobe ./cmd/lobprobe
    if [[ "${SKIP_GAME:-0}" != 1 ]]; then
        echo "== exporting game"
        GODOT="$GODOT" scripts/build_game.sh "$ROOT/build/lob_server.x86_64"
    fi
    echo "== C game_server (for MULTIPLAYER sessions)"
    make -C "$ROOT/server" >/dev/null
    echo "== rsync to $VAST_HOST:$VAST_DIR"
    rssh "mkdir -p $VAST_DIR/bin $VAST_DIR/web $VAST_DIR/game"
    rsync -az --info=progress2 -e "ssh -p $VAST_PORT" \
        bin/lobcloud bin/lobprobe "$VAST_HOST:$VAST_DIR/bin/"
    rsync -az --delete -e "ssh -p $VAST_PORT" web/ "$VAST_HOST:$VAST_DIR/web/"
    rsync -az --info=progress2 -e "ssh -p $VAST_PORT" \
        "$ROOT/build/lob_server.x86_64" "$ROOT/server/game_server" "$VAST_HOST:$VAST_DIR/game/"
    echo "== remote deps (weston, pulseaudio, ffmpeg)"
    rssh bash -s <<'REMOTE'
set -e
export DEBIAN_FRONTEND=noninteractive
need=""
for p in weston pulseaudio pulseaudio-utils ffmpeg libxkbcommon0 libwayland-client0 libdecor-0-0 fontconfig libpulse0 libvulkan1 rsync; do
    dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"
done
if [ -n "$need" ]; then apt-get update -qq && apt-get install -y -qq --no-install-recommends $need; fi
chmod +x /workspace/lob/bin/* /workspace/lob/game/* 2>/dev/null || true
echo "deps ok"
REMOTE
}

vast_start() {
    # ssh flattens its argument list into one string, so an EMPTY value
    # (no token) would silently vanish and shift everything after it: the
    # settings travel as shell-quoted assignments in front of the script.
    {
        printf 'DIR=%q PORT=%q TOKEN=%q MAX=%q W=%q H=%q FPS=%q BR=%q ENC=%q LOB_ICE_TCP_MAP=%q\n' \
            "$VAST_DIR" "$LOB_PORT" "${LOB_TOKEN:-}" "${LOB_MAX_SESSIONS:-2}" \
            "${LOB_WIDTH:-1280}" "${LOB_HEIGHT:-720}" "${LOB_FPS:-60}" "${LOB_BITRATE:-8000}" \
            "${LOB_ENCODER:-auto}" "${LOB_ICE_TCP_MAP:-}"
        cat <<'REMOTE'
set -e
# vast exports its port map / public IP into the container environment;
# a plain ssh shell does not always see it, so pull it from PID 1.
eval "$(tr '\0' '\n' < /proc/1/environ | grep -E '^(PUBLIC_IPADDR|VAST_(TCP|UDP)_PORT_[0-9]+)=' | sed 's/^/export /')" 2>/dev/null || true
PUB="${PUBLIC_IPADDR:-$(curl -s -4 --max-time 5 ifconfig.me || true)}"
EXT_TCP_VAR="VAST_TCP_PORT_$PORT"; EXT_TCP="${!EXT_TCP_VAR:-$PORT}"
# 1:1 UDP mappings become the media port range; none → offer ICE over TCP too.
UDP=$(env | sed -n 's/^VAST_UDP_PORT_\([0-9]*\)=\1$/\1/p' | sort -n)
UDP_ARGS=""; ICE_TCP=""
if [ -n "$UDP" ]; then
    UDP_ARGS="-udp-min $(echo "$UDP" | head -1) -udp-max $(echo "$UDP" | tail -1)"
else
    # No UDP: WebRTC over TCP on the first mapped tcp port that is not the
    # gateway's, advertised as its EXTERNAL number (LOB_ICE_TCP=in:out to pick).
    if [ -n "${LOB_ICE_TCP_MAP:-}" ]; then
        ICE_TCP="-ice-tcp ${LOB_ICE_TCP_MAP%%:*} -ice-tcp-public ${LOB_ICE_TCP_MAP##*:}"
    else
        pair=$(env | sed -n 's/^VAST_TCP_PORT_\([0-9]*\)=\([0-9]*\)$/\1 \2/p' \
            | awk -v p="$PORT" '$1!=p && $1!=22 && $1<=65535 {print; exit}')
        if [ -n "$pair" ]; then ICE_TCP="-ice-tcp ${pair% *} -ice-tcp-public ${pair#* }"; fi
    fi
fi
pkill -x lobcloud 2>/dev/null || true; pkill -x game_server 2>/dev/null || true; sleep 0.5
# Pulse and the gateway must agree on XDG_RUNTIME_DIR or pactl never finds
# the socket ("no audio (pactl load-module: exit status 1)").
export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p "$XDG_RUNTIME_DIR" /tmp/lobcloud
if ! pactl info >/dev/null 2>&1; then
    pulseaudio -k 2>/dev/null || true; sleep 0.3
    pulseaudio --daemonize=yes --exit-idle-time=-1 --disallow-exit \
        -L module-native-protocol-unix -L "module-null-sink sink_name=dummy" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pactl info >/dev/null 2>&1 && break; sleep 0.3; done
    pactl info >/dev/null 2>&1 || echo "warning: pulseaudio not reachable, sessions will have no audio"
fi
cd "$DIR"
LOB_DISPLAY_MODE=weston LOB_GODOT="$DIR/game/lob_server.x86_64" LOB_GAME_DIR= \
LOB_WEB_DIR="$DIR/web" LOB_LOG_DIR=/tmp/lobcloud LOB_LISTEN=":$PORT" LOB_PUBLIC_IP="$PUB" \
LOB_TOKEN="$TOKEN" LOB_MAX_SESSIONS="$MAX" LOB_WIDTH="$W" LOB_HEIGHT="$H" LOB_FPS="$FPS" \
LOB_BITRATE="$BR" LOB_ENCODER="$ENC" LOB_GAME_SERVER=1 LOB_GAME_SERVER_BIN="$DIR/game/game_server" \
    nohup "$DIR/bin/lobcloud" $UDP_ARGS $ICE_TCP "$@" > /tmp/lobcloud/gateway.log 2>&1 &
sleep 1.5
if ! pgrep -x lobcloud >/dev/null; then echo "gateway died:"; tail -30 /tmp/lobcloud/gateway.log; exit 1; fi
echo
echo "gateway up   : http://$PUB:$EXT_TCP   ${TOKEN:+(token: $TOKEN)}"
echo "media        : ${UDP_ARGS:-no 1:1 UDP mapping (rent with -p UDP ports, or rely on ${ICE_TCP:-a TURN server})}"
echo "logs         : scripts/deploy.sh vast logs"
tail -5 /tmp/lobcloud/gateway.log
REMOTE
    } | rssh bash ${DEPLOY_TRACE:+-x} -s -- "$@"
}

run_vast() {
    vast_target
    case "${1:-}" in
        push)   vast_push ;;
        start)  vast_start "${@:2}" ;;
        all)    vast_push; vast_start ;;
        stop)   rssh "pkill -x lobcloud; pkill -x game_server; pkill -x lob_server.x86_64; pkill -x weston; echo stopped" ;;
        status) rssh "pgrep -af lobcloud || echo 'gateway not running'; nvidia-smi --query-gpu=name,utilization.gpu --format=csv,noheader 2>/dev/null || true" ;;
        logs)   rssh "tail -n 60 -f /tmp/lobcloud/gateway.log" ;;
        ssh)    exec "${SSH[@]}" ;;
        *)      usage ;;
    esac
}

case "${1:-}" in
    local) run_local "${@:2}" ;;
    vast)  run_vast "${@:2}" ;;
    *)     usage ;;
esac
