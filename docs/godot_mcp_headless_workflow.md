# Godot MCP Headless Workflow

This repo is wired for GoPeak MCP with Godot at `/home/talves/bin/godot`.
The current expected version check is:

```bash
/home/talves/bin/godot --version
# 4.5.1.stable.official.f62fdbde1
```

The repo-local `.mcp.json` keeps GoPeak in `compact` mode with paged tools.
Use `tool.catalog` or `tool.groups` from the MCP client to activate dynamic
groups such as `runtime`, `testing`, `lsp`, `dap`, and `version_gate`.

Headless checks:

```bash
bash tools/test_godot_mcp.sh
tools/run_godot_headless.sh --scene res://game.tscn --timeout 30 --quit-after 300
LOB_HEADLESS=1 tools/run_combat_scenario.sh A
```

Visual viewport captures are not fully headless with the current Godot dummy
renderer. `./test_dragon_wings.sh --headless /tmp/lob-dragon-wings` now exits
quickly and reports zero frames instead of hanging; use the default windowed
mode for actual dragon PNG review.

Runtime notes:

- GoPeak runtime tools expect `127.0.0.1:7777`.
- The runtime autoload binds loopback by default and accepts
  `--mcp-runtime-port=<port>` for isolated script runs.
- For normal headless tests, pass `--no-mcp-runtime` to avoid port conflicts
  with the multiplayer server, which also uses port `7777`.
- Use `node tools/godot_runtime_probe.mjs ping` to verify the runtime socket.

If the actual Godot executable needs updating, do it outside the repo write
scope, then verify with `/home/talves/bin/godot --version` and rerun
`bash tools/test_godot_mcp.sh`.
