/**
 * Port of stage/lands_of_balance.tscn — the Lands themselves.
 *
 * Positions, sizes and rotations are read straight off the Godot scene file
 * so the map matches: the same ground slab, the same two river branches, the
 * same three roads, the same three hill masses built from mountain.obj, the
 * Village of Eights GLB, and the landmark labels the minimap indexes.
 */
import { Group, Mesh, MeshStandardMaterial, type Object3D, Vector3 } from 'three'
import { OBJLoader } from 'three/examples/jsm/loaders/OBJLoader.js'
import type { AssetLoader } from '../core/assets'
import { enableShadows } from '../core/assets'
import type { WorldCollision } from '../core/physics'
import { degToRad } from '../core/gdmath'
import { LANDMARKS } from '../core/tuning'
import { Label3D } from './label3d'
import { buildTerrain, terrainHeight, WATER_LEVEL } from './terrain'
import { buildGrass, type Grass } from './grass'
import { buildScatter } from './scatter'
import { waterSurface } from './water'

/** Nominal ground level at the village pad, which terrain.ts keeps flat. */
export const GROUND_Y = 0

const ASSETS = '/assets/world/'

const _labelTmp = new Vector3()

export interface Stage {
  root: Group
  labels: Label3D[]
  grass: Grass
  /** Ground height at (x, z) — the terrain's own function. */
  height(x: number, z: number): number
  /** Fade landmark text with distance so it annotates rather than shouts. */
  updateLabels(cameraPos: Vector3, visible: boolean): void
}

export async function buildStage(assets: AssetLoader, world: WorldCollision): Promise<Stage> {
  const root = new Group()
  root.name = 'LandsOfBalance'
  const labels: Label3D[] = []

  // ── Ground ────────────────────────────────────────────────────────────
  // The Godot scene uses one flat 1070 m slab. This uses displaced terrain
  // instead (see terrain.ts) — the flat pad under the village keeps the
  // buildings and spawn points where the original put them.
  const terrain = buildTerrain(assets)
  root.add(terrain.root)

  // ── River ─────────────────────────────────────────────────────────────
  // Two branches. The bed is draped onto the relief; the water is a TSL
  // surface with travelling ripples and a fresnel rim, because a flat
  // translucent slab reads as a hole in the ground rather than a river.
  // No bed geometry: terrain.ts carves the channel, so the banks ARE the
  // ground. Only the water surface is added, sitting at the carve level.
  const river = new Group()
  river.name = 'River'
  river.add(waterSurface([15, 185], [-20, WATER_LEVEL, 60], 30))
  river.add(waterSurface([15, 125], [40, WATER_LEVEL, -40], 45))
  const riverLabel = new Label3D('The River', { fontSize: 32, outlineSize: 4, worldScale: 0.011 })
  riverLabel.position.set(0, terrainHeight(0, 30) + 3, 30)
  river.add(riverLabel)
  labels.push(riverLabel)
  root.add(river)

  // ── Roads ─────────────────────────────────────────────────────────────
  // No geometry: terrain.ts paints the three roads into the ground material,
  // so they follow the relief with a soft, worn edge instead of sitting on it
  // as hard-edged slabs.
  const roadLabel = new Label3D('Trade Road', { fontSize: 24, outlineSize: 4, worldScale: 0.011 })
  roadLabel.position.set(40, terrainHeight(40, -34.3) + 2, -34.3)
  root.add(roadLabel)
  labels.push(roadLabel)

  // ── Hills ─────────────────────────────────────────────────────────────
  // Three masses built from the same mountain.obj at wildly different
  // scales, exactly as the Godot scene stacks them.
  const hillMat = new MeshStandardMaterial({ color: 0x4a4a41, roughness: 1, flatShading: false })
  try {
    const mountain = await new OBJLoader().loadAsync(`${ASSETS}mountain.obj`)
    const source = mountain.children.find((c) => (c as Mesh).isMesh) as Mesh | undefined
    if (source) {
      const mk = (
        pos: [number, number, number],
        localPos: [number, number, number],
        scale: [number, number, number],
        yawDeg: number,
        name: string,
        labelY: number,
      ): void => {
        const holder = new Group()
        holder.position.set(pos[0], pos[1], pos[2])
        const mesh = new Mesh(source.geometry, hillMat)
        mesh.position.set(localPos[0], localPos[1], localPos[2])
        mesh.scale.set(scale[0], scale[1], scale[2])
        mesh.rotation.y = degToRad(yawDeg)
        mesh.castShadow = true
        mesh.receiveShadow = true
        holder.add(mesh)
        const label = new Label3D(name, { fontSize: 36, outlineSize: 5, worldScale: 0.013 })
        label.position.set(0, labelY, 0)
        holder.add(label)
        labels.push(label)
        root.add(holder)
      }
      // TheHills at (0,-20,-250), mesh offset (-424.5, 19.3, 310.3) x100.
      mk([0, -20, -250], [-424.53, 19.35, 310.28], [100, 100, 100], 0, 'The Hills', 120)
      // Hills2 at (200,-20,-100); basis is a 42.5° yaw at scale (80,80,80).
      mk([200, -20, -100], [174.33, 20, 0], [80, 80, 80], 42.5, 'Hills 2', 100)
      // Hills3 at (-25,-7,514); ~32.3° yaw at scale (100,100,100).
      mk([-25, -7, 514], [0, 0, 0], [100, 100, 100], 32.3, 'Hills 3', 100)
    }
  } catch {
    console.warn('[stage] mountain.obj missing — hills skipped')
  }

  // ── Village of Eights ─────────────────────────────────────────────────
  try {
    const village = await assets.load(`${ASSETS}village_of_eights.glb`)
    const inst = village.scene
    inst.name = 'VillageOfEights'
    enableShadows(inst)
    // The imported model ships an OmniLight at energy 1000 — a floodlight
    // that washes out the whole rainy-night field. The Godot loader tames it
    // to a warm lantern; here we simply drop baked lights and let the
    // moon + firelight own the scene.
    const doomed: Object3D[] = []
    inst.traverse((o) => {
      if ((o as { isLight?: boolean }).isLight) doomed.push(o)
    })
    for (const l of doomed) l.parent?.remove(l)
    root.add(inst)
  } catch {
    console.warn('[stage] village_of_eights.glb missing — village skipped')
  }

  const villageLabel = new Label3D('Village of Eights\nSeat of the Keeper', { fontSize: 48, outlineSize: 6, worldScale: 0.012 })
  villageLabel.position.set(0, 12, 0)
  root.add(villageLabel)
  labels.push(villageLabel)

  // ── Landmark markers ──────────────────────────────────────────────────
  // The minimap indexes these by name; the Godot scene scatters equivalent
  // Label3Ds across the same coordinates.
  for (const [name, [x, z]] of Object.entries(LANDMARKS)) {
    if (name === 'Village of Eights') continue // already labelled above
    const label = new Label3D(name, { fontSize: 36, outlineSize: 5, worldScale: 0.012 })
    label.position.set(x, 9, z)
    root.add(label)
    labels.push(label)
  }

  // Landmark text is an annotation, not signage: small, dim, and gone by the
  // time you are far enough away for it to overlap the horizon.
  const LABEL_NEAR = 25
  const LABEL_FAR = 110
  const updateLabels = (cameraPos: Vector3, visible: boolean): void => {
    for (const label of labels) {
      if (!visible) {
        label.visible = false
        continue
      }
      const d = label.getWorldPosition(_labelTmp).distanceTo(cameraPos)
      const fade = 1 - Math.min(Math.max((d - LABEL_NEAR) / (LABEL_FAR - LABEL_NEAR), 0), 1)
      label.visible = fade > 0.02
      label.setOpacity(fade * 0.55)
    }
  }

  // Register solid world with the collision system before decorating it
  // with things that must never be walked into (grass).
  world.addAll(root)

  // ── Scatter ───────────────────────────────────────────────────────────
  // Trees, rocks and bushes, added after the collision registration above and
  // therefore NOT solid. That is deliberate: MeshBVH builds from a geometry
  // plus one world matrix, so an InstancedMesh would register a single
  // collider at the origin — a phantom tree you bump into in an empty field.
  // Walking through distant scenery is the lesser evil; see the README.
  root.add(buildScatter())

  // ── Grass ─────────────────────────────────────────────────────────────
  const grass = buildGrass(assets)
  root.add(grass.mesh)

  return { root, labels, updateLabels, grass, height: terrainHeight }
}
