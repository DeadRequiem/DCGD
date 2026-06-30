extends Node3D
## DC1 sky dome (dome only — clouds). Instances the current time's cloud-dome GLB, follows the camera as an
## infinite backdrop, renders it UNSHADED + double-sided + OPAQUE (writes depth so the ProceduralSky can't paint
## over it), and swaps by the TimeOfDay slot. <id>s01=day, s02=dusk, s03=night.

@export var town_id := "e01"
const DOME_VARIANT := { 0: "01", 1: "01", 3: "02", 6: "03" }
const RADIUS := 3000.0

var _dome: Node3D
var _slot := -99

func _ready() -> void:
	_swap(TimeOfDay.town_slot())
	if not TimeOfDay.time_changed.is_connected(_on_time):
		TimeOfDay.time_changed.connect(_on_time)

func _on_time(_t: int) -> void:
	_swap(TimeOfDay.town_slot())

func _process(_delta: float) -> void:
	pass   # WORLD-ANCHORED: the cloud dome stays fixed in the world (was camera-followed). Only the ProceduralSky
	# gradient behind it is camera-fixed; the player now moves under the clouds.

func _swap(slot: int) -> void:
	if slot == _slot:
		return
	_slot = slot
	if _dome != null:
		_dome.queue_free()
		_dome = null
	var variant: String = DOME_VARIANT.get(slot, "01")
	var path := "res://assets/maps/gedit/%s/%ss%s_0.glb" % [town_id, town_id, variant]
	var ps := load(path) as PackedScene
	if ps == null:
		return
	_dome = ps.instantiate()
	add_child(_dome)
	var aabb := _combined_aabb(_dome)
	var r: float = maxf(aabb.size.length() * 0.5, 0.001)
	_dome.scale = Vector3.ONE * (RADIUS / r)
	for mi in _dome.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # sky meshes never cast shadows
		for s in m.get_surface_override_material_count():
			var src := m.get_active_material(s)
			var mat: StandardMaterial3D = (src.duplicate() if src is StandardMaterial3D else StandardMaterial3D.new())
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			mat.vertex_color_use_as_albedo = false
			mat.albedo_color = Color.WHITE
			m.set_surface_override_material(s, mat)

func _combined_aabb(root: Node) -> AABB:
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
