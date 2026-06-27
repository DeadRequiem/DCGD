extends Node3D
## DEBUG surface highlighter (press F4). Tints every render SURFACE a distinct colour and floats a Label3D
## with its name (e.g. "Mesh.s0") at its centroid, so a broken/stretched surface can be pointed at by name.
## Toggling off restores the real materials. Pairs with the F3 collision overlay. Built lazily on first F4.

var _on := false
var _labels: Array = []

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F4:
		_on = not _on
		if _on:
			_apply()
		else:
			_clear()

func _apply() -> void:
	var i := 0
	for mi_node in _meshes(get_parent()):
		var mi := mi_node as MeshInstance3D
		var m := mi.mesh
		if m == null:
			continue
		for s in m.get_surface_count():
			var col := Color.from_hsv(fmod(i * 0.61803399, 1.0), 0.9, 1.0)
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = col
			mi.set_surface_override_material(s, mat)
			var arr = m.surface_get_arrays(s)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var ctr := Vector3.ZERO
			for v in verts:
				ctr += v
			if verts.size() > 0:
				ctr /= verts.size()
			var lbl := Label3D.new()
			lbl.text = "%s.s%d" % [mi.name, s]
			lbl.font_size = 64
			lbl.outline_size = 16
			lbl.pixel_size = 0.25
			lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			lbl.no_depth_test = true
			lbl.position = ctr
			mi.add_child(lbl)
			_labels.append(lbl)
			i += 1
	print("mesh_debug: %d surfaces tinted + labelled (F4 toggles)" % _labels.size())

func _clear() -> void:
	for mi_node in _meshes(get_parent()):
		var mi := mi_node as MeshInstance3D
		var m := mi.mesh
		if m == null:
			continue
		for s in m.get_surface_count():
			mi.set_surface_override_material(s, null)
	for l in _labels:
		if is_instance_valid(l):
			l.queue_free()
	_labels.clear()

func _meshes(n: Node, out: Array = []) -> Array:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_meshes(c, out)
	return out
