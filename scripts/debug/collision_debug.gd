extends Node3D
## DEBUG collision overlay. Colours every collision triangle the player's solver can hit, by the SAME rule the
## solver uses (the あたりポリゴン surface normal):
##   GREEN = walkable floor / ramp (|normal.y| > 0.3)
##   RED   = wall (|normal.y| < 0.3) — what blocks you / what you fall off the edge of
## So you can SEE what's actually there: the hull, the build-plane, the support braces, the house walls.
## F3 toggles it. (Triangles are nudged out along their normal a hair so they don't z-fight the visual mesh.)

var _mi: MeshInstance3D

func _ready() -> void:
	pass   # overlay starts HIDDEN — press F3 to build + show it (debug only; not in your face during play)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F3:
		if _mi == null:
			_build()
		elif is_instance_valid(_mi):
			_mi.visible = not _mi.visible

func _build() -> void:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	for cs_node in _concaves(get_parent()):
		var cs := cs_node as CollisionShape3D
		var faces: PackedVector3Array = (cs.shape as ConcavePolygonShape3D).get_faces()
		var x := cs.global_transform
		var i := 0
		while i + 2 < faces.size():
			var a := x * faces[i]
			var b := x * faces[i + 1]
			var c := x * faces[i + 2]
			var n := (b - a).cross(c - a)
			if n.length() < 1e-5:
				i += 3
				continue
			n = n.normalized()
			var col := Color(0.1, 1.0, 0.1, 0.45) if absf(n.y) > 0.3 else Color(1.0, 0.12, 0.12, 0.6)
			var off := n * 0.4
			verts.append(a + off); verts.append(b + off); verts.append(c + off)
			cols.append(col); cols.append(col); cols.append(col)
			i += 3
	if verts.is_empty():
		push_warning("collision_debug: no ConcavePolygonShape3D collision found")
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_mi = MeshInstance3D.new()
	_mi.name = "CollisionOverlay"
	_mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # show both sides (the hull is wound facing down)
	_mi.material_override = mat
	add_child(_mi)
	print("collision_debug: %d tris drawn (GREEN=floor, RED=wall; F3 toggles)" % (verts.size() / 3))

func _concaves(n: Node, out: Array = []) -> Array:
	for c in n.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is ConcavePolygonShape3D:
			out.append(c)
		_concaves(c, out)
	return out
