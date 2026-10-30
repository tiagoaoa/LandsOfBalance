## The boss's VISIBLE body, sampled: a subset of the skinned mesh's vertices
## skinned on the CPU (the same maths as the renderer: bone pose x bind pose,
## checked against MeshInstance3D.bake_mesh_from_current_skeleton_pose), so a
## point can be tested against the skin a player actually sees rather than
## the hitbox capsules standing in for it.
##
## Inside/outside is a generalized winding number over the oriented samples
## (Barill et al., "Fast Winding Numbers for Soups and Clouds", 2018):
##   w(p) = sum_i a_i (x_i - p) . n_i / (4 pi |x_i - p|^3)
## ~1 inside a closed hide, ~0 outside; robust where a nearest-sample normal
## test is not (deep inside the torso, or metres away from any scale).
## Samples are binned in a 2 m grid: near cells exact, far cells as a single
## dipole each.
class_name SkinProbe
extends RefCounted

const CELL := 2.0
const FOUR_PI := 4.0 * PI

var skel: Skeleton3D
var skin: Skin
var mi: MeshInstance3D
var rest_pos := PackedVector3Array()
var rest_nrm := PackedVector3Array()
var rest_area := PackedFloat32Array() # mesh area each sample stands for (rest)
var bones := PackedInt32Array()       # 4 per sample, bind indices
var weights := PackedFloat32Array()   # 4 per sample
var dominant := PackedInt32Array()    # bind index of the biggest weight
var pos := PackedVector3Array()       # skinned, world space
var nrm := PackedVector3Array()
var area := PackedFloat32Array()      # world-space area
var bind_bone := PackedInt32Array()   # bind index -> skeleton bone
var bone_names: Array[String] = []
var _grid := {}                       # Vector3i -> Array[int]
var _cells: Array = []                # [centroid, dipole, radius, Vector3i]
var _batches: Array = []
var threaded := OS.get_processor_count() >= 4 and OS.get_environment("LOB_SKIN_THREADS") != "0"


#Each worker owns its output arrays and reads a snapshot of bone matrices.
#Skeleton3D, physics queries and the spatial grid stay on the main thread.
class SkinBatch extends RefCounted:
	var rest_pos: PackedVector3Array
	var rest_nrm: PackedVector3Array
	var bones: PackedInt32Array
	var weights: PackedFloat32Array
	var mats: Array[Transform3D]
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var first := 0
	var count := 0

	func run() -> void:
		for j in count:
			var i := first + j
			var p := Vector3.ZERO
			var n := Vector3.ZERO
			for k in 4:
				var w := weights[i * 4 + k]
				if w <= 0.0:
					continue
				var m := mats[bones[i * 4 + k]]
				p += (m * rest_pos[i]) * w
				n += (m.basis * rest_nrm[i]) * w
			pos[j] = p
			nrm[j] = n.normalized()


func build(mesh_instance: MeshInstance3D, skeleton: Skeleton3D,
		target_samples: int = 5000, fine_contacts: bool = false) -> bool:
	mi = mesh_instance
	skel = skeleton
	skin = mi.skin
	if mi.mesh == null or skin == null or skel == null:
		return false
	var arr := mi.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var b: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var w: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	# Area each vertex owns: a third of every triangle around it.
	var vert_area := PackedFloat32Array()
	vert_area.resize(v.size())
	for t in range(0, idx.size(), 3):
		var a := (v[idx[t + 1]] - v[idx[t]]).cross(v[idx[t + 2]] - v[idx[t]]).length() / 6.0
		vert_area[idx[t]] += a
		vert_area[idx[t + 1]] += a
		vert_area[idx[t + 2]] += a
	for k in skin.get_bind_count():
		var bb := skin.get_bind_bone(k)
		if bb < 0:
			bb = skel.find_bone(skin.get_bind_name(k))
		bind_bone.append(bb)
		bone_names.append(skel.get_bone_name(bb) if bb >= 0 else "?")
	var per := b.size() / maxi(1, v.size())
	var stride := maxi(1, v.size() / target_samples)
	#The repaired exports retain all fingers. Use finer samples on the
	#small contact surfaces; uniform sampling missed thin palms and jaws.
	var fine := maxi(1, stride / 4) if fine_contacts else stride
	stride = maxi(1, stride / fine) * fine
	var samples := PackedInt32Array()
	for i in range(0, v.size(), fine):
		var best := 0
		for k in range(1, mini(4, per)):
			if w[i * per + k] > w[i * per + best]:
				best = k
		var name := bone_names[b[i * per + best]]
		var step := fine if name in ["head", "jaw", "hand.L", "hand.R"] else stride
		if i % step != 0:
			continue
		rest_pos.append(v[i])
		rest_nrm.append(n[i])
		samples.append(i)
		best = 0
		var best_w := -1.0
		for k in 4:
			var bi: int = b[i * per + k] if k < per else 0
			var wk: float = w[i * per + k] if k < per else 0.0
			bones.append(bi)
			weights.append(wk)
			if wk > best_w:
				best_w = wk
				best = bi
		dominant.append(best)
	#Each vertex contributes once, including where sample spacing changes.
	for i in samples.size():
		var end := samples[i + 1] if i + 1 < samples.size() else v.size()
		var a_sum := 0.0
		for j in range(samples[i], end):
			a_sum += vert_area[j]
		rest_area.append(a_sum)
	pos.resize(rest_pos.size())
	nrm.resize(rest_pos.size())
	area.resize(rest_pos.size())
	for k in 4:
		var batch := SkinBatch.new()
		batch.rest_pos = rest_pos
		batch.rest_nrm = rest_nrm
		batch.bones = bones
		batch.weights = weights
		batch.first = rest_pos.size() * k / 4
		batch.count = rest_pos.size() * (k + 1) / 4 - batch.first
		batch.pos.resize(batch.count)
		batch.nrm.resize(batch.count)
		_batches.append(batch)
	return true


func _skin_batch(index: int) -> void:
	_batches[index].run()


func _skin_vertices(mats: Array[Transform3D]) -> void:
	for batch: SkinBatch in _batches:
		batch.mats = mats
	if threaded and rest_pos.size() >= 2048:
		var task := WorkerThreadPool.add_group_task(_skin_batch, _batches.size(), 4, true, "Boss skin")
		WorkerThreadPool.wait_for_group_task_completion(task)
	else:
		for batch: SkinBatch in _batches:
			batch.run()
	pos.clear()
	nrm.clear()
	for batch: SkinBatch in _batches:
		pos.append_array(batch.pos)
		nrm.append_array(batch.nrm)


func update() -> void:
	var mats: Array[Transform3D] = []
	var base := mi.global_transform
	var s2 := pow(base.basis.get_scale().x, 2.0)
	for k in bind_bone.size():
		var bb := bind_bone[k]
		var pose := skel.get_bone_global_pose(bb) if bb >= 0 else Transform3D.IDENTITY
		mats.append(base * pose * skin.get_bind_pose(k))
	_skin_vertices(mats)
	_grid.clear()
	for i in rest_pos.size():
		var p := pos[i]
		area[i] = rest_area[i] * s2
		# Plain Arrays: a PackedInt32Array taken out of a Dictionary is a COPY,
		# and appending to it filled nothing (every cell came back empty).
		var c := Vector3i(floori(p.x / CELL), floori(p.y / CELL), floori(p.z / CELL))
		var cell = _grid.get(c)
		if cell == null:
			cell = []
			_grid[c] = cell
		cell.append(i)
	_cells.clear()
	for key: Vector3i in _grid:
		var cent := Vector3.ZERO
		var dip := Vector3.ZERO
		var tot := 0.0
		for i: int in _grid[key]:
			cent += pos[i] * area[i]
			dip += nrm[i] * area[i]
			tot += area[i]
		cent = cent / maxf(tot, 1e-6)
		var rad := 0.0
		for i: int in _grid[key]:
			rad = maxf(rad, pos[i].distance_to(cent))
		_cells.append([cent, dip, rad, key])


## Generalized winding number at p (~1 inside the hide, ~0 outside).
func winding(p: Vector3) -> float:
	var w := 0.0
	for cell in _cells:
		var cent: Vector3 = cell[0]
		var d := cent - p
		var r := d.length()
		if r > 2.5 * float(cell[2]) + 0.5:
			w += (cell[1] as Vector3).dot(d) / (FOUR_PI * r * r * r)
			continue
		for i: int in _grid[cell[3]]:
			var di := pos[i] - p
			var ri := maxf(di.length(), 0.05)
			w += area[i] * nrm[i].dot(di) / (FOUR_PI * ri * ri * ri)
	return w


## The nearest sample (index, distance), searching outward shell by shell.
func nearest(p: Vector3) -> Array:
	var best := INF
	var bi := -1
	#Visit occupied cells only. The shell search did thousands of empty
	#Dictionary lookups for heroes standing several metres from the boss.
	for cell in _cells:
		var lo := Vector3(cell[3]) * CELL
		var near := p.clamp(lo, lo + Vector3.ONE * CELL)
		if near.distance_squared_to(p) >= best:
			continue
		for i: int in _grid[cell[3]]:
			var d2 := pos[i].distance_squared_to(p)
			if d2 < best:
				best = d2
				bi = i
	return [bi, sqrt(best)]


## {depth, normal, bone, dist}: depth > 0 means p is inside the hide, that
## far from its nearest point of skin; < 0, how far in front of it.
## normal is the outward normal there (the way out).
func contact(p: Vector3) -> Dictionary:
	var nb := nearest(p)
	var i: int = nb[0]
	if i < 0:
		return {"depth": -INF, "normal": Vector3.ZERO, "bone": "", "dist": INF}
	var dist: float = nb[1]
	var bone_name := bone_names[dominant[i]] if dominant[i] < bone_names.size() else "?"
	# Only near the hide does the sign matter for gameplay: far outside it is
	# simply "outside" (and cheap).
	if dist > 6.0:
		return {"depth": -dist, "normal": nrm[i], "bone": bone_name, "dist": dist}
	var inside := winding(p) > 0.5
	return {"depth": dist if inside else -dist, "normal": nrm[i], "bone": bone_name, "dist": dist}


## Back-compat for the arena's instrument.
func inside(p: Vector3, _reach: float = 1.6) -> Dictionary:
	return contact(p)


## Highest point of the hide inside an XZ footprint (world), within [lo, hi]
## height; -INF if none. For ledges that must sit ON the shoulders.
func top_in(center: Vector3, half_x: Vector3, half_z: Vector3, lo: float, hi: float) -> float:
	var best := -INF
	var ax := half_x.normalized()
	var az := half_z.normalized()
	var hx := half_x.length()
	var hz := half_z.length()
	var r := int(ceil(maxf(hx, hz) / CELL)) + 1
	var c0 := Vector3i(floori(center.x / CELL), 0, floori(center.z / CELL))
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			for cy in range(floori(lo / CELL), floori(hi / CELL) + 1):
				var cell = _grid.get(Vector3i(c0.x + dx, cy, c0.z + dz))
				if cell == null:
					continue
				for i: int in cell:
					var q := pos[i]
					if q.y < lo or q.y > hi:
						continue
					var rel := q - center
					if absf(rel.dot(ax)) <= hx and absf(rel.dot(az)) <= hz:
						best = maxf(best, q.y)
	return best
