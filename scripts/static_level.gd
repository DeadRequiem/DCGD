extends Node3D

func _ready() -> void:
	# Trimesh ONLY the baked "Geometry"; never sibling helper nodes. The GeoramaGrid debug pads are
	# MeshInstance3Ds too; trimeshing them turned each colored cell into an invisible solid floor at Y≈3,
	# floating the player ~74u above the real ground and dropping them when they walked off a pad.
	# Use BACKFACE collision: some ground meshes (e.g. the build-plane e01g01) are wound facing down, so a
	# one-sided trimesh lets a ray/capsule from above pass straight through. Two-sided = solid both ways.
	var geom := get_node_or_null("Geometry")
	for mi in _mesh_instances(geom if geom != null else self):
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
