#!/bin/bash
# Phase-locked contact sheet of one Bobba clip: the same pose, every time.
#
#   tools/clip_contact_sheet.sh AxeAttack                   8 frames, side view
#   tools/clip_contact_sheet.sh AxeAttack 12 90            12 frames, 90 degrees
#   tools/clip_contact_sheet.sh AxeAttack 8 0 hit          strike Bobba too
#   tools/clip_contact_sheet.sh AxeAttack 8 180 "" .3 .5   zoom on the strike
#
# The last two arguments narrow the sampled range, which is how you look at a
# damage window closely: eight frames spread over a 2.3 s clip step right past
# the fifth of a second that actually matters.
#
# Output: /tmp/clip_sheet/<Clip>_sheet.png plus the individual frames.
#
# Each frame is its own GEARSIM run pinned with LOB_GEAR_SEEK, because
# sampling a PLAYING clip by wall clock is not phase locked — "the apex frame"
# came back as something else every run, and several rounds of animation
# tuning here were done against poses that were never the pose being judged.
# One launch per frame is slow and correct; the fast version was neither.

set -uo pipefail
cd "$(dirname "$0")/.."

CLIP="${1:-AxeAttack}"
FRAMES="${2:-8}"
ANGLE="${3:-90}"
HIT="${4:-}"
FROM="${5:-0}"
TO="${6:-1}"

OUT=/tmp/clip_sheet
rm -rf "$OUT"
mkdir -p "$OUT"

echo "== $CLIP: $FRAMES frames over $FROM..$TO at ${ANGLE} degrees =="

for i in $(seq 0 $((FRAMES - 1))); do
    SEEK=$(awk "BEGIN{printf \"%.4f\", $FROM + ($TO-$FROM)*$i/($FRAMES-1)}")
    rm -rf /tmp/combat_test
    # Windowed, not headless: _capture() reads the viewport texture, and a
    # headless run has nothing to read — it completes happily and writes zero
    # frames. This opens a game window on the desktop for ~25 s per frame.
    LOB_HEADLESS=0 \
    LOB_GEAR_TARGET=bobba \
    LOB_GEAR_CLIP="$CLIP" \
    LOB_GEAR_SEEK="$SEEK" \
    LOB_GEAR_ANGLE="$ANGLE" \
    LOB_GEAR_ORBIT=7.0 \
    LOB_GEAR_HEIGHT=1.6 \
    ${HIT:+LOB_GEAR_HIT=1} \
        timeout 90 tools/run_combat_scenario.sh GEARSIM 25 >/dev/null 2>&1

    # Late frames only: the first second is spent teleporting the rig into
    # place, and those shots are of the wrong thing entirely.
    SHOT=$(ls -1 /tmp/combat_test/*.png 2>/dev/null | tail -1)
    if [ -z "$SHOT" ]; then
        echo "  seek $SEEK -> NO FRAME"
        continue
    fi
    DEST=$(printf "%s/%s_%02d.png" "$OUT" "$CLIP" "$i")
    cp "$SHOT" "$DEST"
    convert "$DEST" -gravity north -pointsize 34 -fill yellow -undercolor '#00000090' \
        -annotate +0+8 "t=$SEEK" "$DEST" 2>/dev/null
    echo "  seek $SEEK -> $(basename "$DEST")"
done

COUNT=$(ls -1 "$OUT"/${CLIP}_*.png 2>/dev/null | wc -l)
if [ "$COUNT" -eq 0 ]; then
    echo "No frames captured." >&2
    exit 1
fi

SHEET="$OUT/${CLIP}_sheet.png"
montage "$OUT"/${CLIP}_[0-9]*.png -tile 4x -geometry 480x+4+4 -background '#101010' "$SHEET"
echo
echo "Sheet: $SHEET  ($COUNT frames)"
