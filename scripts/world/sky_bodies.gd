extends Node3D
## DC1 celestial bodies — sun / moon / stars / wisps. A SEPARATE TimeOfDay reader from sky_dome, with its own node
## hierarchy, so it can NEVER touch the cloud dome (which stays exactly as-is). Follows the camera.
##   sun (day s0N_1) / moons (night s03_1): tiny 500-unit quads authored at the origin -> we lift them into the sky
##     and billboard them. They live in an UNSCALED root because Godot billboards distort under a scaled parent
##     (that was the bug). They sit CLOSER than the cloud dome so the opaque dome doesn't occlude them.
##   night stars (s05) / wisps (s06): big alpha domes, each scaled individually (NOT the root), to sit just inside
##     the cloud dome.

@export var town_id := "e01"
# The sun/moon DIRECTION is no longer fixed — sky_cycle publishes it as the `dc_light_dir` global (the moving cfg
# LIGHT_C arc), read every frame in _process so the disc rides the day and stays aligned with the shadow.
const SUN_DIST := 1900.0                        # closer than the cloud dome (~3000) so it isn't occluded — tune
const SUN_SCALE := 0.5                          # shrink the 500-unit quad to a disc — tune
const LAYER_RADIUS := 2850.0                    # star/wisp domes, just inside the cloud dome
const SLOT_BODY := { 0: "01_1", 1: "01_1", 3: "02_1", 6: "03_1" }   # sun day / moons night
const SLOT_LAYERS := { 6: ["06_0"] }            # night: wisps only — s05 (stars) is TEXTURELESS, so albedo-white turns
                                                # it into a solid white dome (the band). It needs its own handling.

var _root: Node3D
var _body: Node3D
var _sky_cycle: Node
var _slot := -99

func _ready() -> void:
	_sky_cycle = _find_sky_cycle()
	_swap(TimeOfDay.town_slot())
	if not TimeOfDay.time_changed.is_connected(_on_time):
		TimeOfDay.time_changed.connect(_on_time)

## sky_cycle is a sibling under the town root; it owns the moving sun dir (current_sun_dir). Found by name, then script.
func _find_sky_cycle() -> Node:
	var p := get_parent()
	if p == null:
		return null
	var n := p.get_node_or_null("SkyCycle")
	if n != null:
		return n
	for c in p.get_children():
		var s: Script = c.get_script()
		if s != null and s.resource_path.ends_with("sky_cycle.gd"):
			return c
	return null

func _on_time(_t: int) -> void:
	_swap(TimeOfDay.town_slot())

func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _root == null:
		return
	_root.global_position = cam.global_position   # follow camera; root stays UNSCALED so billboards stay true
	if _body != null:
		_body.position = _sky_dir() * SUN_DIST    # ride sky_cycle's moving sun dir (local to _root @ the camera)

func _swap(slot: int) -> void:
	if slot == _slot:
		return
	_slot = slot
	if _root != null:
		_root.queue_free()
		_root = null
		_body = null
	_root = Node3D.new()
	add_child(_root)
	# sun (day) / moons (night): lifted billboard quad, positioned every frame in _process along the sky dir
	var bpart := String(SLOT_BODY.get(slot, ""))
	if bpart != "":
		var body := _load(bpart)
		if body != null:
			_root.add_child(body)
			body.position = _sky_dir() * SUN_DIST
			body.scale = Vector3.ONE * SUN_SCALE
			_apply_mat(body, true)
			_body = body
	# night star/wisp layers: big alpha domes, each scaled on ITSELF (never the root)
	var layers: Array = SLOT_LAYERS.get(slot, [])
	for part in layers:
		var dome := _load(String(part))
		if dome == null:
			continue
		_root.add_child(dome)
		var r: float = maxf(_aabb(dome).size.length() * 0.5, 0.001)
		dome.scale = Vector3.ONE * (LAYER_RADIUS / r)
		_apply_mat(dome, false)

func _load(part: String) -> Node3D:
	var ps := load("res://assets/maps/gedit/%s/%ss%s.glb" % [town_id, town_id, part]) as PackedScene
	return (ps.instantiate() as Node3D) if ps != null else null

func _apply_mat(root: Node, billboard: bool) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # sky meshes never cast shadows
		for s in m.get_surface_override_material_count():
			var src := m.get_active_material(s)
			var mat: StandardMaterial3D = (src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new())
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.vertex_color_use_as_albedo = false
			mat.albedo_color = Color.WHITE
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA   # blend over the dome behind them
			if billboard:
				mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			m.set_surface_override_material(s, mat)

func _aabb(root: Node) -> AABB:
	var out := AABB()
	var first := true
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var a: AABB = m.transform * m.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out

## sky_cycle's live sun/moon direction (the cfg LIGHT_C arc). Read straight off the SkyCycle sibling (NOT the shader
## global — global_shader_parameter_get is unreliable headless). Falls back to a sane up+Z dir. Normalized.
func _sky_dir() -> Vector3:
	if _sky_cycle != null:
		var d: Variant = _sky_cycle.get("current_sun_dir")
		if d is Vector3 and (d as Vector3).length() > 0.01:
			return (d as Vector3).normalized()
	return Vector3(0.0, 0.85, 0.53).normalized()
