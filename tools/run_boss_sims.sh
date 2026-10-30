#!/bin/bash
# Overnight bot-vs-colossus batches. Both classes are bots (spectate), the
# game runs headless at LOB_TIME_SCALE, and every match appends a JSON line.
#
#   tools/run_boss_sims.sh                    # 4 workers x 10 matches, co-op bots
#   WORKERS=6 MATCHES=20 tools/run_boss_sims.sh
#   LOB_BOSS_AI=naive tools/run_boss_sims.sh  # control: co-op plays switched off
#   OUT=/path/run1 tools/run_boss_sims.sh
#
# Then: python3 tools/boss_report.py <OUT>
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/home/talves/bin/godot}"
WORKERS="${WORKERS:-4}"
MATCHES="${MATCHES:-10}"
SCALE="${LOB_TIME_SCALE:-2.0}"
OUT="${OUT:-/tmp/lob_boss_sims/$(date +%Y%m%d_%H%M%S)_${LOB_BOSS_AI:-coop}${LOB_BOSS_SOLO:+_solo_$LOB_BOSS_SOLO}}"
mkdir -p "$OUT"
# Preflight: a script that fails to compile would leave every worker idling
# on a broken scene until its timeout. Refuse to start instead.
if GODOT_MCP_RUNTIME_ENABLED=0 timeout 90 "$GODOT" --path "$PWD" --headless \
        --scene res://tests/boss_arena/boss_arena.tscn --quit-after 5 2>&1 \
        | grep -E "Parse Error|Compile Error|Failed to load script"; then
    echo "boss sims: build does not compile — aborting"; exit 1
fi
echo "boss sims: $WORKERS workers x $MATCHES matches, time x$SCALE, ai=${LOB_BOSS_AI:-coop} -> $OUT"
for w in $(seq 1 "$WORKERS"); do
    # Half the workers deal the human seat to each class; irrelevant to bots
    # but it exercises both spawn orders.
    CLS=$([ $((w % 2)) -eq 0 ] && echo paladin || echo archer)
    GODOT_MCP_RUNTIME_ENABLED=0 LOB_TIME_SCALE="$SCALE" LOB_BOSS_MATCHES="$MATCHES" \
    LOB_BOSS_LOG="$OUT/matches_w$w.ndjson" \
        timeout $(( MATCHES * 700 / ${SCALE%.*} + 120 )) \
        "$GODOT" --path "$PWD" --headless --scene res://tests/boss_arena/boss_arena.tscn -- \
            --singleplayer --no-mcp-runtime --spectate "--character-class=$CLS" \
        > "$OUT/worker_$w.log" 2>&1 &
done
wait
cat "$OUT"/matches_w*.ndjson > "$OUT/matches.ndjson" 2>/dev/null || true
python3 tools/boss_report.py "$OUT"
