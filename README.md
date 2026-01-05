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

- **WASD** - Movement
- **Space** - Jump
- **Left Click** - Draw bow / Release arrow
- **Right Click** - Combat stance
- **Shift** - Sprint

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
