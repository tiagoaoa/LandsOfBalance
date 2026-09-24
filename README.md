# Lands of Balance

A 3D medieval fantasy game built with Godot 4. Features real-time multiplayer with a custom C server, archer combat system, and an open world to explore.

## Features

- **Multiplayer Support**: UDP-based networking with a high-performance C server
- **Archer Combat**: Draw and shoot arrows with visual effects and projectile physics
- **Player Characters**: Animated Archer model with full movement and combat animations
- **Enemy AI**: Dragon and Bobba enemies with patrol and attack behaviors
- **Bot Companions**: AI-controlled players that follow and assist in combat
- **Medieval World**: Castle environment with dynamic lighting and day/night cycle

## Requirements

- Godot 4.x
- GCC (for compiling the C server)
- Linux (tested on Linux, may work on other platforms)

## Quick Start

### Single Player
Open the project in Godot and run `game.tscn`.

### Godot MCP

This repo includes both Godot MCP addons and a repo-local MCP client config in `.mcp.json`.

Use the `godot` MCP server entry from `.mcp.json`:

```json
{
  "mcpServers": {
    "godot": {
      "type": "stdio",
      "command": "node",
      "args": ["/home/talves/.local/lib/gopeak/node_modules/gopeak/build/index.js"],
      "env": {
        "GODOT_PATH": "/home/talves/bin/godot",
        "GODOT_BRIDGE_PORT": "6505",
        "GOPEAK_BRIDGE_HOST": "127.0.0.1",
        "GOPEAK_TOOL_PROFILE": "compact"
      }
    }
  }
}
```

Run the local smoke test:

```bash
chmod +x tools/test_godot_mcp.sh
./tools/test_godot_mcp.sh
```

What it verifies:
- GoPeak starts and exposes `http://127.0.0.1:6505/health`
- The Godot editor addon connects to the bridge
- The runtime addon opens its socket on `127.0.0.1:7777`

### Multiplayer

1. **Build the server:**
   ```bash
   cd server
   make
   ```

2. **Run with bot companion:**
   ```bash
   ./restart_multiplayer.sh
   ```

3. **Run two-player local test:**
   ```bash
   ./test_multiplayer.sh
   ```

## Project Structure

```
LandsOfBalance/
├── server/           # C multiplayer server
│   ├── game_server.c # Main game server
│   ├── bot_client.c  # AI bot companion
│   └── Makefile
├── multiplayer/      # Networking code
│   ├── network_manager.gd
│   ├── protocol.gd
│   └── remote_player.gd
├── player/           # Player character
│   ├── player.gd
│   ├── player.tscn
│   └── character/    # Character models & animations
├── enemies/          # Enemy AI
├── stage/            # World and environment
├── addons/           # Godot plugins
└── ui/               # User interface
```

## Controls

| Action | Keyboard / mouse | Controller |
|---|---|---|
| Move | WASD | Left stick |
| Sprint | Hold Shift | Hold L3 |
| Jump | Space | A |
| Dodge / neutral backstep | X (or Ctrl+Space) | B |
| Paladin light attack / combo | LMB or F | LT |
| Paladin heavy attack | V | RB |
| Guard | Hold RMB | Hold RT |
| Parry | G | LB |
| Lock on / unlock | T | R3 |
| Switch locked target | | Flick right stick left/right |
| Archer aim, draw, release shot | Hold then release RMB | Hold then release LT |
| Archer quick shot | LMB or F | RB |
| Heal | H | D-pad Down |
| Cast spell | C | X |
| Revive ally | Hold E | Hold Y |

Sword windups and contact commit the player. Press again to chain one attack, or dodge/guard during recovery. Heavy blows break posture; attack an enemy marked OPEN for a critical. A dodge can cancel a bow draw or a heal, but a cancelled heal still spends its flask. Full stick movement does not consume sprint stamina.

Run `bash tools/run_combat_arena.sh` for the practice duel, or add `--archer` to practice bow combat. Combat changes and checks are recorded in [docs/combat_feel.md](docs/combat_feel.md).

## Multiplayer Protocol

The game uses a custom binary UDP protocol:
- Server broadcasts world state at 60Hz
- Supports up to 32 concurrent players
- Arrow synchronization with spawn/hit events
- Player state includes position, rotation, health, and animation

## License

MIT License - See [LICENSE](LICENSE) for details.

## Credits

- Virtual Joystick addon by [Marco F](https://github.com/MarcoFazioRandom)
- Character models from Mixamo
- Built with [Godot Engine](https://godotengine.org/)
