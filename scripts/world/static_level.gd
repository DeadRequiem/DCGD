extends Node3D

func _ready() -> void:
	# DC1's real collision is the あたりポリゴン (the baked `CollisionHull` from <id>_col.json): per-triangle
	# floor/ramp vs wall, authored by the surface NORMAL (floor |ny|≈1, wall |ny|≈0). Stairs are a SMOOTH ramp
	# there; the mountain + fences are walls. So we must NOT collide the stepped VISUAL render mesh (which made
	# the player stop on every step and let the floor-solver climb the mountain). For a georama TOWN we collide
	# ONLY the flat EDITAREA build-plane (the node marked "walk_floor" — the plaza interior, which has no _a
	# sibling); the smooth CollisionHull carries every ramp/stair/wall/perimeter. Interiors (no build-plane
	# marker) still trimesh all geometry (they have no separate hull).
	# BACKFACE collision: the build-plane e01g01 is wound facing down, so a one-sided trimesh lets a capsule/ray
	# pass through from above. Two-sided = solid both ways.
	var geom := get_node_or_null("Geometry")
	if geom == null:
		return
	_apply_glows(geom)   # DC1 torch/fire light-pool quads -> additive blend (black surround vanishes, centre glows)
	var src: Node = geom
	for n in geom.get_children():
		if n.has_meta("walk_floor"):
			src = n   # town: collide only the flat plaza floor; the あたりポリゴン hull does the rest
			break
	for mi in _mesh_instances(src):
		if (mi as MeshInstance3D).mesh == null:
			continue
		var shape := (mi as MeshInstance3D).mesh.create_trimesh_shape()
		if shape == null:
			continue
		shape.backface_collision = true
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		mi.add_child(body)

func _mesh_instances(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out += _mesh_instances(c)
	return out

## DC1 torch/fire LIGHT-POOL quads carry a small dark texture (warm centre, black surround). Rendered opaque
## they look like black squares; converting them to ADDITIVE blend makes the black surround vanish and the warm
## centre glow on the ground. Detected by a small (<=64px) albedo texture whose average is dark.
func _apply_glows(geom: Node) -> void:
	var is_glow := {}   # texture -> bool (cached; one glow texture is reused across surfaces)
	for mi_node in _mesh_instances(geom):
		var mi := mi_node as MeshInstance3D
		var m := mi.mesh
		if m == null:
			continue
		for s in m.get_surface_count():
			var mat := mi.get_active_material(s) as BaseMaterial3D
			if mat == null or mat.albedo_texture == null:
				continue
			var tex := mat.albedo_texture
			if not is_glow.has(tex):
				is_glow[tex] = _is_glow_texture(tex)
			if is_glow[tex]:
				var gm := StandardMaterial3D.new()
				gm.albedo_texture = tex
				gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				gm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
				gm.cull_mode = BaseMaterial3D.CULL_DISABLED
				mi.set_surface_override_material(s, gm)

func _is_glow_texture(tex: Texture2D) -> bool:
	if tex == null or tex.get_width() > 64 or tex.get_height() > 64:
		return false
	var img := tex.get_image()
	if img == null:
		return false
	if img.is_compressed() and img.decompress() != OK:
		return false   # VRAM-compressed glb texture we can't sample -> skip (don't convert)
	var w := img.get_width()
	var h := img.get_height()
	var sum := 0.0
	var n := 0
	var sx: int = maxi(1, int(w / 8))
	var sy: int = maxi(1, int(h / 8))
	for y in range(0, h, sy):
		for x in range(0, w, sx):
			var c := img.get_pixel(x, y)
			sum += (c.r + c.g + c.b) / 3.0
			n += 1
	return n > 0 and (sum / n) < 0.32   # avg brightness < ~0.32 (80/255) = a dark light-pool/glow texture
