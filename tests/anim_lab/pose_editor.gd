class_name PoseEditor
extends PanelContainer
## Live editor for the composed pose clips.
##
## The composed clips are described as timed poses in code, and every round of
## "that arm is wrong" has meant me guessing a euler, rebuilding, relaunching
## and squinting at a screenshot. This edits the pose in the running game: pick
## a clip, a keyframe and a bone, drag the angle, watch it change immediately.
##
## Character-space X/Y/Z behave as documented on PoseAnim — x arches back, y
## yaws, z rolls sideways. TWIST is separate and rolls the bone about its own
## long axis, which is the only way to pronate a wrist onto a shaft.
##
## Export writes the whole clip back out as GDScript ready to paste into
## bobba_anims.gd, so nothing dialled in here is lost.

signal spec_changed(clip_name: String)

const OUT_PATH := "user://edited_poses.gd.txt"

var specs: Array = []                  ## live, mutated in place
var skeleton: Skeleton3D

var _clip_names: Array[String] = []
var _clip_pick: OptionButton
var _key_pick: OptionButton
var _bone_pick: OptionButton
var _add_bone_pick: OptionButton
var _sliders: Dictionary = {}          ## axis -> HSlider
var _values: Dictionary = {}           ## axis -> SpinBox
var _status: Label
var _muted: bool = false


func setup(all_specs: Array, skel: Skeleton3D) -> void:
	specs = all_specs
	skeleton = skel
	_build()
	_refresh_clips()


func _build() -> void:
	custom_minimum_size = Vector2(330, 520)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	add_child(vb)

	var t := Label.new()
	t.text = "POSE EDITOR"
	t.add_theme_font_size_override("font_size", 16)
	vb.add_child(t)

	_clip_pick = _row(vb, "Clip")
	_clip_pick.item_selected.connect(func(_i: int) -> void: _refresh_keys())
	_key_pick = _row(vb, "Keyframe")
	_key_pick.item_selected.connect(func(_i: int) -> void: _refresh_bones())
	_bone_pick = _row(vb, "Bone")
	_bone_pick.item_selected.connect(func(_i: int) -> void: _load_bone_values())

	# Character-space angles plus the bone-axis twist.
	for axis in ["X (arch back)", "Y (yaw)", "Z (side roll)", "TWIST (own axis)"]:
		var box := HBoxContainer.new()
		vb.add_child(box)
		var lab := Label.new()
		lab.text = axis
		lab.custom_minimum_size = Vector2(120, 0)
		box.add_child(lab)
		var sl := HSlider.new()
		sl.min_value = -180.0
		sl.max_value = 180.0
		sl.step = 1.0
		sl.custom_minimum_size = Vector2(130, 0)
		box.add_child(sl)
		var sb := SpinBox.new()
		sb.min_value = -180.0
		sb.max_value = 180.0
		sb.step = 1.0
		box.add_child(sb)
		var key: String = axis.get_slice(" ", 0)
		_sliders[key] = sl
		_values[key] = sb
		sl.value_changed.connect(func(v: float) -> void:
			if _muted: return
			sb.set_value_no_signal(v)
			_write_back())
		sb.value_changed.connect(func(v: float) -> void:
			if _muted: return
			sl.set_value_no_signal(v)
			_write_back())

	var addrow := HBoxContainer.new()
	vb.add_child(addrow)
	var al := Label.new()
	al.text = "Add bone"
	al.custom_minimum_size = Vector2(120, 0)
	addrow.add_child(al)
	_add_bone_pick = OptionButton.new()
	_add_bone_pick.custom_minimum_size = Vector2(180, 0)
	addrow.add_child(_add_bone_pick)
	var addbtn := Button.new()
	addbtn.text = "+"
	addbtn.pressed.connect(_add_bone)
	addrow.add_child(addbtn)

	var btns := HBoxContainer.new()
	vb.add_child(btns)
	var zero := Button.new()
	zero.text = "Zero bone"
	zero.pressed.connect(func() -> void:
		for k in _sliders:
			(_sliders[k] as HSlider).set_value_no_signal(0.0)
			(_values[k] as SpinBox).set_value_no_signal(0.0)
		_write_back())
	btns.add_child(zero)
	var exp := Button.new()
	exp.text = "Export clip to file"
	exp.pressed.connect(_export)
	btns.add_child(exp)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(310, 60)
	_status.text = "pick a clip"
	vb.add_child(_status)


func _row(parent: Node, label: String) -> OptionButton:
	var box := HBoxContainer.new()
	parent.add_child(box)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(120, 0)
	box.add_child(l)
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(190, 0)
	box.add_child(o)
	return o


# --- population -------------------------------------------------------------

func _refresh_clips() -> void:
	_clip_pick.clear()
	_clip_names.clear()
	for sp in specs:
		# Only clips with real keyframes are editable; the carry clips are a
		# single constant pose and still qualify.
		_clip_names.append(String(sp["name"]))
		_clip_pick.add_item(String(sp["name"]))
	if not _clip_names.is_empty():
		_clip_pick.select(0)
		_refresh_keys()


func _spec() -> Dictionary:
	var i: int = _clip_pick.selected
	return specs[i] if i >= 0 and i < specs.size() else {}


func _keys() -> Array:
	var sp := _spec()
	return sp.get("keys", []) if not sp.is_empty() else []


func _refresh_keys() -> void:
	_key_pick.clear()
	var ks := _keys()
	for i in ks.size():
		_key_pick.add_item("t = %.2f s" % float(ks[i]["t"]))
	if ks.size() > 0:
		_key_pick.select(0)
	_refresh_bones()


func _key() -> Dictionary:
	var ks := _keys()
	var i: int = _key_pick.selected
	return ks[i] if i >= 0 and i < ks.size() else {}


func _refresh_bones() -> void:
	_bone_pick.clear()
	var k := _key()
	var seen := {}
	for b in (k.get("pose", {}) as Dictionary):
		seen[b] = true
	for b in (k.get("twist", {}) as Dictionary):
		seen[b] = true
	var names: Array = seen.keys()
	names.sort()
	for b in names:
		_bone_pick.add_item(b)
	if not names.is_empty():
		_bone_pick.select(0)
	_fill_add_bone_list()
	_load_bone_values()


## Everything on the skeleton that this key does NOT already pose, so a bone
## can be brought into the pose without editing code.
func _fill_add_bone_list() -> void:
	_add_bone_pick.clear()
	if skeleton == null:
		return
	var k := _key()
	var have := {}
	for b in (k.get("pose", {}) as Dictionary):
		have[b] = true
	var all: Array[String] = []
	for i in skeleton.get_bone_count():
		var short: String = skeleton.get_bone_name(i) \
				.replace("mixamorig:", "").replace("mixamorig_", "")
		if not have.has(short):
			all.append(short)
	all.sort()
	for b in all:
		_add_bone_pick.add_item(b)


func _add_bone() -> void:
	if _add_bone_pick.selected < 0:
		return
	var bone: String = _add_bone_pick.get_item_text(_add_bone_pick.selected)
	var k := _key()
	if k.is_empty():
		return
	if not k.has("pose"):
		k["pose"] = {}
	(k["pose"] as Dictionary)[bone] = Vector3.ZERO
	_refresh_bones()
	for i in _bone_pick.item_count:
		if _bone_pick.get_item_text(i) == bone:
			_bone_pick.select(i)
			break
	_load_bone_values()
	_emit()


func _bone() -> String:
	var i: int = _bone_pick.selected
	return _bone_pick.get_item_text(i) if i >= 0 else ""


func _load_bone_values() -> void:
	var k := _key()
	var b := _bone()
	if k.is_empty() or b == "":
		return
	var v: Vector3 = (k.get("pose", {}) as Dictionary).get(b, Vector3.ZERO)
	var tw: float = float((k.get("twist", {}) as Dictionary).get(b, 0.0))
	_muted = true
	for pair in [["X", v.x], ["Y", v.y], ["Z", v.z], ["TWIST", tw]]:
		(_sliders[pair[0]] as HSlider).set_value_no_signal(pair[1])
		(_values[pair[0]] as SpinBox).set_value_no_signal(pair[1])
	_muted = false
	_status.text = "%s / t=%.2f / %s" % [
			String(_spec().get("name", "?")), float(_key().get("t", 0.0)), b]


func _write_back() -> void:
	var k := _key()
	var b := _bone()
	if k.is_empty() or b == "":
		return
	if not k.has("pose"):
		k["pose"] = {}
	(k["pose"] as Dictionary)[b] = Vector3(
			(_values["X"] as SpinBox).value,
			(_values["Y"] as SpinBox).value,
			(_values["Z"] as SpinBox).value)
	var tw: float = (_values["TWIST"] as SpinBox).value
	if not k.has("twist"):
		k["twist"] = {}
	if is_zero_approx(tw):
		(k["twist"] as Dictionary).erase(b)
	else:
		(k["twist"] as Dictionary)[b] = tw
	_emit()


func _emit() -> void:
	spec_changed.emit(String(_spec().get("name", "")))


## Select a bone from outside (a joint was grabbed in the viewport).
func focus_bone(bone: String) -> void:
	for i in _bone_pick.item_count:
		if _bone_pick.get_item_text(i) == bone:
			_bone_pick.select(i)
			_load_bone_values()
			return
	# Not in this key yet — the drag will have added it, so rebuild the list.
	_refresh_bones()
	for i in _bone_pick.item_count:
		if _bone_pick.get_item_text(i) == bone:
			_bone_pick.select(i)
			_load_bone_values()
			return


## Spec by clip name, for the viewport editor.
func spec_for(clip_name: String) -> Dictionary:
	for sp in specs:
		if String(sp["name"]) == clip_name:
			return sp
	return {}


## Rebuild the keyframe dropdown after keys were added or removed, keeping the
## selection on whichever key is nearest `t`.
func refresh_keys_preserving(t: float) -> void:
	var ks := _keys()
	_key_pick.clear()
	var best := 0
	var best_d := INF
	for i in ks.size():
		_key_pick.add_item("t = %.2f s" % float(ks[i]["t"]))
		var d: float = absf(float(ks[i]["t"]) - t)
		if d < best_d:
			best_d = d
			best = i
	if ks.size() > 0:
		_key_pick.select(best)
	_refresh_bones()


# --- export -----------------------------------------------------------------

## Emit the selected clip as GDScript matching the style in bobba_anims.gd,
## so a dialled-in pose can be pasted straight back into the source.
func _export() -> void:
	var sp := _spec()
	if sp.is_empty():
		return
	var out := PackedStringArray()
	out.append('\t\t{')
	out.append('\t\t\t"name": "%s", "base": "%s", "length": %.2f,%s' % [
			sp["name"], sp.get("base", "Idle"), float(sp.get("length", 0.0)),
			' "loop": true,' if sp.get("loop", false) else ''])
	out.append('\t\t\t"keys": [')
	for k in _keys():
		var pose: Dictionary = k.get("pose", {})
		var twist: Dictionary = k.get("twist", {})
		var parts := PackedStringArray()
		var bones: Array = pose.keys()
		bones.sort()
		for b in bones:
			var v: Vector3 = pose[b]
			if v == Vector3.ZERO and not twist.has(b):
				continue
			parts.append('"%s": Vector3(%d, %d, %d)' % [b, roundi(v.x), roundi(v.y), roundi(v.z)])
		var tparts := PackedStringArray()
		var tb: Array = twist.keys()
		tb.sort()
		for b in tb:
			tparts.append('"%s": %.1f' % [b, float(twist[b])])
		var line := '\t\t\t\t{"t": %.2f' % float(k["t"])
		if not tparts.is_empty():
			line += ', "twist": {%s}' % ", ".join(tparts)
		line += ', "pose": {%s}},' % ", ".join(parts)
		out.append(line)
	out.append('\t\t\t],')
	out.append('\t\t},')
	var text := "\n".join(out)
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f:
		f.store_string(text)
		f.close()
	DisplayServer.clipboard_set(text)
	print("\n--- %s ---\n%s\n--- copied to clipboard, saved to %s ---" % [
			sp["name"], text, ProjectSettings.globalize_path(OUT_PATH)])
	_status.text = "Exported %s to clipboard and\n%s" % [
			sp["name"], ProjectSettings.globalize_path(OUT_PATH)]
