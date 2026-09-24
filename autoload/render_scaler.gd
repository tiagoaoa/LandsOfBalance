extends Node

## Dynamic 3D resolution, steered by measured GPU time.
##
## The night field (volumetric fog, SSAO, MSAA, glow over a grass field) is
## mostly paid per pixel: on an integrated GPU at a laptop's native 3 MP a
## frame took ~28 ms of GPU, two thirds of it scaling with pixel count. Rather
## than dim the look for every machine, the 3D view renders at the window's
## resolution while the GPU keeps up, and steps down (FSR 1 upscaled; the UI
## stays native) only when it doesn't. A GPU with headroom never sees a change.
##
## Steps are discrete and spaced out: every change re-allocates the render
## buffers, a small hitch of its own, so it must not hunt. Down is quick
## (a frame over budget is a visible stutter), up is slow and one step at a
## time (a sharper image nobody asked for is not worth a bounce).
##
##   --no-dynamic-res      keep native resolution
##   --render-scale=0.75   fixed scale, no steering

const LEVELS: Array[float] = [1.0, 0.9, 0.8, 0.72, 0.66, 0.6]
const WINDOW := 1.0          # seconds of GPU time averaged per decision
const SETTLE := 2.0          # seconds ignored after a change (buffers, stale average)
const UP_WINDOWS := 3        # consecutive calm windows before stepping up
## Share of GPU time assumed NOT to scale with resolution (shadow maps,
## skinning, vertex work). Measured ~0.3 on the night field; erring high
## makes the prediction conservative.
const FIXED_SHARE := 0.35

var enabled := false
var level := 0
var gpu_ms := 0.0            # last window's average, for HUDs and the probe

var _rid: RID
var _budget_ms := 15.5
var _sum := 0.0
var _frames := 0
var _elapsed := 0.0
var _settle := SETTLE
var _calm := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	var vp := get_viewport()
	for arg in args:
		if arg.begins_with("--render-scale="):
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
			vp.scaling_3d_scale = clampf(float(arg.get_slice("=", 1)), 0.25, 1.0)
			print("RenderScaler: fixed 3D scale %.2f" % vp.scaling_3d_scale)
			return
	if DisplayServer.get_name() == "headless" or "--no-dynamic-res" in args \
			or RenderingServer.get_current_rendering_method() == "gl_compatibility":
		return
	_rid = vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_rid, true)
	# Aim a little under the refresh interval (capped at 60 Hz: chasing 144
	# on an iGPU would only ever blur). Missing a 60 Hz vsync is a drop to 30.
	var hz := DisplayServer.screen_get_refresh_rate()
	if hz <= 0.0:
		hz = 60.0
	_budget_ms = 1000.0 / minf(hz, 60.0) * 0.93
	enabled = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("RenderScaler: dynamic 3D resolution on (GPU budget %.1f ms)" % _budget_ms)


func _process(delta: float) -> void:
	if not enabled:
		return
	var ms := RenderingServer.viewport_get_measured_render_time_gpu(_rid)
	if _settle > 0.0:
		_settle -= delta
		return
	if ms <= 0.0:
		return
	_sum += ms
	_frames += 1
	_elapsed += delta
	if _elapsed < WINDOW:
		return
	gpu_ms = _sum / _frames
	_sum = 0.0
	_frames = 0
	_elapsed = 0.0
	if gpu_ms > _budget_ms:
		_calm = 0
		var target := level
		while target < LEVELS.size() - 1 and _predict(LEVELS[target]) > _budget_ms * 0.92:
			target += 1
		_apply(maxi(target, level + 1))
	elif level > 0 and _predict(LEVELS[level - 1]) < _budget_ms * 0.85:
		_calm += 1
		if _calm >= UP_WINDOWS:
			_calm = 0
			_apply(level - 1)
	else:
		_calm = 0


## GPU time expected at `scale`, from the current window: the fixed share
## stays, the rest follows pixel count (scale squared).
func _predict(scale: float) -> float:
	var now: float = LEVELS[level]
	var ratio := (scale * scale) / (now * now)
	return gpu_ms * (FIXED_SHARE + (1.0 - FIXED_SHARE) * ratio)


func _apply(new_level: int) -> void:
	new_level = clampi(new_level, 0, LEVELS.size() - 1)
	if new_level == level:
		return
	level = new_level
	var vp := get_viewport()
	var scale: float = LEVELS[level]
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if scale < 1.0 \
			else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = scale
	_settle = SETTLE
	print("RenderScaler: GPU %.1f ms -> 3D scale %.2f" % [gpu_ms, scale])
