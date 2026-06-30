extends Node
## Town day/night sky. Holds a continuous PHASE (0..N) over the 12-slot cfg lighting table. On each time-of-day
## change it tweens the phase forward; each frame it interpolates the WorldEnvironment — the sky gradient sampled
## per-town from the actual SKY-DOME TEXTURES (<id>s01-04), and sun/fog/ambient from the cfg table. (Light emitters
## now self-gate via emitter.gd; sky_cycle no longer touches them.)

const SPEED := 3.5          # slots/sec during a transition

# DC1 sun/moon DIRECTION = the cfg LIGHT_C pos, on the +Z side, MOVING over the day. Keyed to the 4 player-set town
# slots {0,1,3,6} (morning/afternoon/dusk/night) and slerped on `phase`. (The raw 12-slot pos jumps at the dusk/dawn
# boundaries; the 4 real states form a smooth +Z arc: morning E & high -> noon highest -> dusk W & low -> night moon
# E & high.) The visible sun (sky_bodies), Light0, and dc_light_dir all read this one dir, so the sun MOVES, the
# shadow TRACKS it, and the shadow falls AWAY from the visible disc. _sun_keys is filled from the table in _ready.
const SUN_SLOTS := [0, 1, 3, 6]                       # the town slots (TimeOfDay.TOWN_SLOT) that get a keyframe dir
const SUN_KEY_PHASE := [0.0, 1.0, 3.0, 6.0, 12.0]     # phase span of each keyframe segment (last wraps 6 -> 0)
var _sun_keys: Array = []                             # normalized cfg-pos dir per SUN_SLOTS entry

# Real sky gradient (zenith=top, horizon=hz) keyed to the phase its look belongs to: DAY=s01 (noon), DUSK=s02,
# NIGHT=s03, DAWN=s04. _build_sky() SAMPLES these per-town at load from the painted sky-dome textures (<id>sNN_0.glb:
# top band -> zenith, bottom band -> horizon), so the gradient is data-grounded + town-agnostic. SKY_FALLBACK (e01's
# hand-sampled values, which match the sampled ones) is used only if a town's domes can't be sampled.
const SKY_DOME_VARIANT := ["01", "02", "03", "04"]   # day, dusk, night, dawn domes
const SKY_PHASE := [1.0, 4.0, 7.0, 10.0]             # the phase each dome's look is keyed to
const SKY_FALLBACK := [
	{ "p": 1.0,  "top": Color8(23, 67, 152),   "hz": Color8(125, 165, 216) },  # DAY   (e01s01)
	{ "p": 4.0,  "top": Color8(183, 129, 66),   "hz": Color8(191, 139, 72) },   # DUSK  (e01s02)
	{ "p": 7.0,  "top": Color8(7, 7, 10),       "hz": Color8(34, 36, 56) },     # NIGHT (e01s03)
	{ "p": 10.0, "top": Color8(184, 140, 214),  "hz": Color8(248, 244, 239) },  # DAWN  (e01s04)
]
var _sky: Array = []

@export var table_path := ""
@export var town_id := ""   # this town's id; used to load its sky-dome textures for the gradient (set by build_level)

var _slots: Array = []
var _phase := 0.0
var _target := 0.0
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _sun: DirectionalLight3D
var current_sun_dir := Vector3(0.0, 0.85, 0.53).normalized()   # the live sun/moon dir; sky_bodies reads this to place the disc

func _ready() -> void:
	if table_path != "" and FileAccess.file_exists(table_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(table_path))
		if parsed is Dictionary:
			_slots = (parsed as Dictionary).get("slots", [])
	_build_sun_keys()
	_build_sky()
	var root := get_parent()
	var we := root.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we != null:
		_env = we.environment
		if _env != null and _env.sky != null:
			_sky_mat = _env.sky.sky_material as ProceduralSkyMaterial
	_sun = root.get_node_or_null("Light0") as DirectionalLight3D
	_phase = float(TimeOfDay.town_slot())
	_target = _phase
	if not TimeOfDay.time_changed.is_connected(_on_time_changed):
		TimeOfDay.time_changed.connect(_on_time_changed)
	_apply(_phase)

func _on_time_changed(_t: int) -> void:
	_target = float(TimeOfDay.town_slot())

func _process(delta: float) -> void:
	if _slots.size() < 2 or is_equal_approx(_phase, _target):
		return
	var n := float(_slots.size())
	var fwd: float = fmod(_target - _phase + n, n)
	var step := SPEED * delta
	_phase = _target if fwd <= step else fmod(_phase + step, n)
	_apply(_phase)

func _apply(phase: float) -> void:
	var n := _slots.size()
	if n < 2:
		return
	var i := int(floorf(phase)) % n
	var a := _slots[i] as Dictionary
	var b := _slots[(i + 1) % n] as Dictionary
	if a == null or b == null:
		return
	var f := phase - floorf(phase)
	if _env != null:
		var av := _v128(a.get("ambient"), b.get("ambient"), f)   # /128 so the now-shaded relight's ambient matches the old look
		_env.ambient_light_color = Color(av.x, av.y, av.z)
		if _sky_mat != null:
			var sky := _sky_colors(phase)
			var top: Color = sky[0]
			var bot: Color = sky[1]
			_sky_mat.sky_top_color = top
			_sky_mat.sky_horizon_color = bot
			_sky_mat.ground_horizon_color = bot
			_sky_mat.ground_bottom_color = bot
			_env.background_color = top
		var fa: Variant = a.get("fog")
		var fb: Variant = b.get("fog")
		if fa != null and fb != null:
			_env.fog_depth_begin = lerpf(float(fa[0]), float(fb[0]), f)
			_env.fog_depth_end = lerpf(float(fa[1]), float(fb[1]), f)
			_env.fog_light_color = Color(lerpf(float(fa[2]), float(fb[2]), f) / 255.0, lerpf(float(fa[3]), float(fb[3]), f) / 255.0, lerpf(float(fa[4]), float(fb[4]), f) / 255.0)
	current_sun_dir = sun_dir(phase)   # cfg LIGHT_C arc dir; the source of truth for the disc, the light, and the shader
	if _sun != null:
		var la: Variant = a.get("light")
		var lb: Variant = b.get("light")
		if la != null and lb != null:
			_sun.light_color = _col(la.get("color"), lb.get("color"), f)
		# light sits at the sun dir and looks at origin -> it shines -dir, so the shadow falls AWAY from the visible disc
		_sun.look_at_from_position(current_sun_dir * 30.0, Vector3.ZERO, Vector3.UP)
	_set_relight(a, b, f)   # DC1 per-vertex relight: feed the town shader's dc_* globals from this slot

## Interpolated (zenith, horizon) sky colours at `phase`, from the 4 sampled SKY keyframes (circular over 12).
func _sky_colors(phase: float) -> Array:
	var n := _sky.size()
	if n == 0:
		return [Color.BLACK, Color.BLACK]
	for i in n:
		var ka: Dictionary = _sky[i]
		var kb: Dictionary = _sky[(i + 1) % n]
		var seg: float = fmod(float(kb["p"]) - float(ka["p"]) + 12.0, 12.0)
		var off: float = fmod(phase - float(ka["p"]) + 12.0, 12.0)
		if off < seg:
			var t: float = off / seg
			return [(ka["top"] as Color).lerp(kb["top"], t), (ka["hz"] as Color).lerp(kb["hz"], t)]
	return [_sky[0]["top"], _sky[0]["hz"]]

func _col(a: Variant, b: Variant, f: float) -> Color:
	if a == null or b == null:
		return Color.WHITE
	return Color(lerpf(float(a[0]), float(b[0]), f) / 255.0, lerpf(float(a[1]), float(b[1]), f) / 255.0, lerpf(float(a[2]), float(b[2]), f) / 255.0)

## Pushes the interpolated LIGHT_NO into the town relight shader's dc_* globals. dc_light_dir = the moving cfg LIGHT_C
## arc dir (sun_dir) — ALSO read by sky_bodies to place the visible disc, so disc + shadow stay aligned. Ambient is
## the Environment ambient, not a shader global.
func _set_relight(a: Dictionary, b: Dictionary, f: float) -> void:
	var la: Variant = a.get("light")
	var lb: Variant = b.get("light")
	if la != null and lb != null:
		RenderingServer.global_shader_parameter_set("dc_light_col", _v128(la.get("color"), lb.get("color"), f))
		RenderingServer.global_shader_parameter_set("dc_light_dir", current_sun_dir)

## Build the 4 town-slot keyframe directions from the cfg LIGHT_C pos (normalized). Called once after _slots loads.
func _build_sun_keys() -> void:
	_sun_keys = []
	for s in SUN_SLOTS:
		var d := Vector3(0.0, 0.85, 0.53)
		if s < _slots.size():
			var l: Variant = (_slots[s] as Dictionary).get("light")
			if l != null and l.get("pos") != null:
				var p: Variant = l["pos"]
				d = Vector3(float(p[0]), float(p[1]), float(p[2]))
		_sun_keys.append(d.normalized())

## The sun/moon direction at `phase` (0..12): slerp across the 4 town-slot keyframes (last segment wraps 6 -> 0).
## Always +Z and above the horizon. Drives the visible disc, Light0, and dc_light_dir so all three stay aligned.
func sun_dir(phase: float) -> Vector3:
	if _sun_keys.size() < SUN_SLOTS.size():
		return Vector3(0.0, 0.85, 0.53).normalized()
	for i in SUN_SLOTS.size():
		if phase >= SUN_KEY_PHASE[i] and phase < SUN_KEY_PHASE[i + 1]:
			var t: float = (phase - SUN_KEY_PHASE[i]) / (SUN_KEY_PHASE[i + 1] - SUN_KEY_PHASE[i])
			return (_sun_keys[i] as Vector3).slerp(_sun_keys[(i + 1) % SUN_SLOTS.size()], t)
	return _sun_keys[0]

## Lerp a cfg LIGHT_NO byte-triple to a normalized Vector3. /128: the PS2 GS modulate treats colour 128 as 1.0x
## (so cfg LIGHT_C ~120 reads near-white) — tune this divisor if the day looks too hot or too dim.
func _v128(a: Variant, b: Variant, f: float) -> Vector3:
	if a == null or b == null:
		return Vector3.ONE
	return Vector3(lerpf(float(a[0]), float(b[0]), f) / 128.0, lerpf(float(a[1]), float(b[1]), f) / 128.0, lerpf(float(a[2]), float(b[2]), f) / 128.0)

## Build the 4 sky-gradient keyframes by sampling this town's painted sky-dome textures (<id>sNN_0.glb): top band ->
## zenith, bottom band -> horizon. Per-town + data-grounded. Any dome unsamplable -> fall back to e01's SKY_FALLBACK.
func _build_sky() -> void:
	_sky = []
	for i in SKY_DOME_VARIANT.size():
		var pair := _sample_dome(SKY_DOME_VARIANT[i])
		if pair.is_empty():
			_sky = SKY_FALLBACK.duplicate(true)
			return
		_sky.append({ "p": SKY_PHASE[i], "top": pair[0], "hz": pair[1] })

## Sample one dome GLB's albedo texture: top 18% of rows -> zenith, bottom 18% -> horizon. [] on any failure.
func _sample_dome(variant: String) -> Array:
	if town_id == "":
		return []
	var path := "res://assets/maps/gedit/%s/%ss%s_0.glb" % [town_id, town_id, variant]
	if not ResourceLoader.exists(path):
		return []
	var ps := load(path) as PackedScene
	if ps == null:
		return []
	var root := ps.instantiate()
	var img := _dome_image(root)
	root.free()
	if img == null:
		return []
	return [_band(img, 0.0, 0.18), _band(img, 0.82, 1.0)]

func _dome_image(root: Node) -> Image:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		for s in m.mesh.get_surface_count():
			var mat: Material = m.get_active_material(s)
			if mat == null:
				mat = m.mesh.surface_get_material(s)
			if mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null:
				var img := (mat as StandardMaterial3D).albedo_texture.get_image()
				if img != null:
					if img.is_compressed():
						img.decompress()
					return img
	return null

## Average a horizontal band of the image (y0f..y1f as fractions of height) -> Color.
func _band(img: Image, y0f: float, y1f: float) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	var y0 := int(y0f * h)
	var y1 := maxi(int(y1f * h), y0 + 1)
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	var sx := maxi(1, int(w / 16))
	for y in range(y0, mini(y1, h)):
		for x in range(0, w, sx):
			var c := img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
			n += 1
	return Color(r / maxi(n, 1), g / maxi(n, 1), b / maxi(n, 1))
