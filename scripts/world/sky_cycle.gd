extends Node
## Town day/night sky. Holds a continuous PHASE (0..N) over the 12-slot cfg lighting table. On each time-of-day
## change it tweens the phase forward; each frame it interpolates the WorldEnvironment — the sky gradient from the
## game's actual SKY-DOME TEXTURE colours (sampled from e01s01-04), and sun/fog/ambient from the cfg table — and
## gates the town torches by the phase (ON late-dusk -> night -> dawn -> early-morning, OFF through the bright day).

const SPEED := 3.5          # slots/sec during a transition
const LIGHTS_ON := 5.5      # phase the torches switch ON (late dusk, just before night)
const LIGHTS_OFF := 1.0     # phase they switch OFF (early-mid morning)

# Real sky gradient (zenith=top, horizon=hz) sampled from the game's sky-dome textures, each keyed to the phase its
# look belongs to: DAY=e01s01 (slot~1 noon), DUSK=e01s02 (slot~4), NIGHT=e01s03 (slot~7), DAWN=e01s04 (slot~10).
# These are e01's; TODO generalize = emit per-town sky colours from the C# map step (sample each town's s01-04).
const SKY := [
	{ "p": 1.0,  "top": Color8(23, 67, 152),   "hz": Color8(125, 165, 216) },  # DAY   (e01s01)
	{ "p": 4.0,  "top": Color8(183, 129, 66),   "hz": Color8(191, 139, 72) },   # DUSK  (e01s02)
	{ "p": 7.0,  "top": Color8(7, 7, 10),       "hz": Color8(34, 36, 56) },     # NIGHT (e01s03)
	{ "p": 10.0, "top": Color8(184, 140, 214),  "hz": Color8(248, 244, 239) },  # DAWN  (e01s04)
]

@export var table_path := ""

var _slots: Array = []
var _phase := 0.0
var _target := 0.0
var _fires: Array = []
var _env: Environment
var _sky_mat: ProceduralSkyMaterial
var _sun: DirectionalLight3D

func _ready() -> void:
	if table_path != "" and FileAccess.file_exists(table_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(table_path))
		if parsed is Dictionary:
			_slots = (parsed as Dictionary).get("slots", [])
	var root := get_parent()
	_fires = root.find_children("Fire_*", "Node3D", true, false)
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
		_env.ambient_light_color = _col(a.get("ambient"), b.get("ambient"), f)
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
	if _sun != null:
		var la: Variant = a.get("light")
		var lb: Variant = b.get("light")
		if la != null and lb != null:
			_sun.light_color = _col(la.get("color"), lb.get("color"), f)
			var pa := Vector3(la["pos"][0], la["pos"][1], la["pos"][2])
			var pb := Vector3(lb["pos"][0], lb["pos"][1], lb["pos"][2])
			var dir := pa.lerp(pb, f)
			if dir.length() > 0.01:
				_sun.look_at_from_position(dir.normalized() * 30.0, Vector3.ZERO, Vector3.UP)
	# torches: ON from late dusk -> night -> dawn -> early morning; OFF through the bright day.
	var lit := phase >= LIGHTS_ON or phase < LIGHTS_OFF
	for fire in _fires:
		(fire as Node3D).visible = lit

## Interpolated (zenith, horizon) sky colours at `phase`, from the 4 SKY texture keyframes (circular over 12).
func _sky_colors(phase: float) -> Array:
	var n := SKY.size()
	for i in n:
		var ka: Dictionary = SKY[i]
		var kb: Dictionary = SKY[(i + 1) % n]
		var seg: float = fmod(float(kb["p"]) - float(ka["p"]) + 12.0, 12.0)
		var off: float = fmod(phase - float(ka["p"]) + 12.0, 12.0)
		if off < seg:
			var t: float = off / seg
			return [(ka["top"] as Color).lerp(kb["top"], t), (ka["hz"] as Color).lerp(kb["hz"], t)]
	return [SKY[0]["top"], SKY[0]["hz"]]

func _col(a: Variant, b: Variant, f: float) -> Color:
	if a == null or b == null:
		return Color.WHITE
	return Color(lerpf(float(a[0]), float(b[0]), f) / 255.0, lerpf(float(a[1]), float(b[1]), f) / 255.0, lerpf(float(a[2]), float(b[2]), f) / 255.0)
