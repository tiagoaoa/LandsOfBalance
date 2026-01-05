# Agent Workflow Guide

## Project Overview
3D platformer game built with Godot 4.5.1. Features a third-person character with FBX animations, day/night lighting system, and multiple landmark locations.

## Key Directories
- `player/` - Player character scripts and FBX animations
- `stage/` - Level scenes and stage-related scripts
- `assets/` - 3D models (GLB/FBX), textures, and imported assets
- `ui/` - UI components including minimap and touch controls
- `addons/` - Third-party plugins (lightning effects, spatial gardener, etc.)

## File Conventions
- GDScript files use snake_case: `player.gd`, `lighting_manager.gd`
- Scene files: `.tscn` for scenes, `.tres` for resources
- 3D models: Prefer GLB/FBX formats, import via Godot's resource system

## Running the Game
```bash
# Run game
/home/talves/bin/godot --path /home/talves/mthings/tpgame/godot-demo-projects/3d/platformer

# Import resources (headless)
timeout 60 /home/talves/bin/godot --path /home/talves/mthings/tpgame/godot-demo-projects/3d/platformer --headless --import

# Open editor
/home/talves/bin/godot --path /home/talves/mthings/tpgame/godot-demo-projects/3d/platformer -e
```

## Key Systems

### Lighting System
- `stage/lighting_manager.gd` - Day/night cycle management
- Press `L` to toggle between DAY and NIGHT modes
- Default: DAY

### Player Character
- `player/player.gd` - Main player controller
- FBX animations loaded dynamically from `player/character/`
- Supports armed/unarmed character states

### Village of Eights
- `stage/village_loader.gd` - Loads village FBX with collision
- Uses trimesh collision shapes for accurate wall collision
- Asset: `assets/village_of_eights.fbx`

### Landmarks (from minimap.gd)
| Location | Position |
|----------|----------|
| Village of Eights | (0, 0) |
| Common Ground | (0, 70) |
| Tower of Hakutnas | (-80, -60) |
| Realm of Hudson | (80, -50) |
| The Hills | (-30, 20) |
| The Burning Peaks | (-120, 0) |
| The Silent Woods | (120, 0) |
| Fire Creature Lair | (-115, 5) |
| Silent Creature Lair | (120, 1) |
| Fields | (60, -35) |

## Adding 3D Assets with Auto-Collision

### Option 1: Via Agent Instructions
Tell the agent:
```
"Add [asset_name.glb] from [path] at position (x, y, z) with trimesh collision"
```
The agent will:
1. Copy asset to `assets/`
2. Import it
3. Add AssetLoader node to scene with proper collision

### Option 2: Manual in Godot Editor
1. Copy GLB/FBX to `assets/` folder
2. In Scene tree, add new Node3D
3. Attach `stage/asset_loader.gd` script
4. In Inspector, set:
   - `Asset Path`: select your GLB/FBX
   - `Collision Type`: TRIMESH (buildings/terrain), CONVEX (props), NONE (decorative)
   - `Scale Factor`: adjust size
   - `Rotation Offset`: fix orientation if needed

### Option 3: Quick Collision in Editor
1. Drag GLB/FBX into scene
2. Select the MeshInstance3D
3. Right-click → "Create Trimesh Static Body"

## AssetLoader Script
`stage/asset_loader.gd` - Generic loader with auto-collision:
- **TRIMESH**: Accurate collision for buildings, rocks, terrain
- **CONVEX**: Fast collision for simple props
- **NONE**: No collision for decorative objects

## Free Asset Sources
- **Kenney.nl**: https://kenney.nl/assets (CC0 license)
- **Quaternius**: https://quaternius.com (CC0 license)
- **Poly.pizza**: https://poly.pizza (various licenses)
- **Sketchfab**: https://sketchfab.com (filter by downloadable)
- **AmbientCG**: https://ambientcg.com (CC0 textures/materials)

## External Asset Directories
- FBX animations: `/home/talves/mthings/fbxs/` and `/home/talves/mthings/fbx2/`
- GLB models: `/home/talves/mthings/glbs/`

## Collision Types Guide
| Asset Type | Collision | Why |
|------------|-----------|-----|
| Buildings | TRIMESH | Accurate walls, player can't walk through |
| Terrain/Mountains | TRIMESH | Player can climb slopes |
| Rocks | TRIMESH or CONVEX | TRIMESH for climbable, CONVEX for obstacles |
| Trees | CONVEX (trunk only) | Simple collision, leaves don't need it |
| Props (barrels, crates) | CONVEX | Fast and sufficient |
| Grass, flowers | NONE | Decorative, no collision |
