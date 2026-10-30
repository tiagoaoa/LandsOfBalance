#!/bin/bash
# Blind playtest of a packet by outside "testers" who know nothing about
# this project: two independent Claude Code runs and one Codex run.
#
#   tools/playtest/run_testers.sh <packet_dir> <results_dir> [n_claude=2] [n_codex=1] [n_aesthetic=0]
#
# n_aesthetic adds Claude raters with the art-direction brief
# (aesthetics_prompt.md): they judge only how the fight LOOKS.
#
# Isolation (verified by leak probes): the packet is copied to a fresh
# /tmp/pt.XXXXXX OUTSIDE the repo and $HOME (both CLIs walk up the tree for
# AGENTS.md and put the working directory into the prompt). Claude runs with
# --safe-mode --restricted, file-reading tools only, no settings/memory/MCP.
# Codex runs with every tool disabled and gets the packet through stdin and
# -i images, because its read-only sandbox can still read the whole disk.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PACKET="$(cd "$1" && pwd)"
RES="$2"
NCL="${3:-2}"
NCX="${4:-1}"
NAE="${5:-0}"
mkdir -p "$RES"
RES="$(cd "$RES" && pwd)"
PROMPT="$(cat "$HERE/tester_prompt.md")"
APROMPT="$(cat "$HERE/aesthetics_prompt.md")"

for i in $(seq 1 "$NCL"); do
    PT=$(mktemp -d /tmp/pt.XXXXXX)
    cp -r "$PACKET"/* "$PT"/
    ( cd "$PT" && timeout 1500 claude -p --restricted --safe-mode \
        --tools "Read,Glob,Grep" --strict-mcp-config --setting-sources "" \
        --no-session-persistence --permission-mode dontAsk \
        --system-prompt "$PROMPT" --output-format json \
        "Evaluate the playtest packet in this directory. Start with README.txt. Look at every image." \
        > "$RES/claude_$i.json" 2> "$RES/claude_$i.err" ) &
done

for i in $(seq 1 "$NAE"); do
    [ "$NAE" -gt 0 ] || break
    PT=$(mktemp -d /tmp/pt.XXXXXX)
    cp -r "$PACKET"/* "$PT"/
    ( cd "$PT" && timeout 1500 claude -p --restricted --safe-mode \
        --tools "Read,Glob,Grep" --strict-mcp-config --setting-sources "" \
        --no-session-persistence --permission-mode dontAsk \
        --system-prompt "$APROMPT" --output-format json \
        "Evaluate how this boss fight LOOKS. Start with README.txt, then every image." \
        > "$RES/aesthetic_$i.json" 2> "$RES/aesthetic_$i.err" ) &
done

for i in $(seq 1 "$NCX"); do
    PT=$(mktemp -d /tmp/pt.XXXXXX)
    cp -r "$PACKET"/* "$PT"/
    IMGS=()
    while IFS= read -r f; do IMGS+=(-i "$f"); done < <(find "$PT" -name 'sheet.jpg' | sort)
    TEXT=$( { echo "=== README.txt"; cat "$PT/README.txt"; \
        while IFS= read -r f; do \
            echo; echo "=== ${f#$PT/}"; cat "$f"; done < <(find "$PT" -name '*.txt' ! -path "$PT/README.txt" | sort); \
        echo; echo "=== Attached images, in order:"; find "$PT" -name 'sheet.jpg' | sort | sed "s|$PT/||"; } )
    ( cd "$PT" && echo "$TEXT" | timeout 1500 codex exec --skip-git-repo-check --ephemeral \
        --ignore-user-config --ignore-rules -m gpt-6-astra -s read-only -C "$PT" \
        -c project_doc_max_bytes=0 -c web_search='"disabled"' \
        --disable shell_tool --disable unified_exec --disable plugins --disable apps \
        --disable memories --disable personality --disable image_generation \
        --disable browser_use --disable computer_use --disable multi_agent \
        "${IMGS[@]}" -o "$RES/codex_$i.json" \
        "$PROMPT

The packet's text files follow on stdin; the contact sheets are attached as images in the listed order." \
        > "$RES/codex_$i.log" 2>&1 ) &
done
wait
echo "testers done -> $RES"
ls -la "$RES"
