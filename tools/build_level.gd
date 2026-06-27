# Headless builder: wrap each baked map glb into a loadable area scene
# (geometry + lighting + collision hull + func_ markers + Spawn).
# Builds EVERY scene under res://assets/maps/gedit/<id>/ that has a <id>_m0.glb.
# Run: godot --headless --path <Project> --script res://tools/build_level.gd
extends SceneTree

const GEDIT := "res://assets/maps/gedit/"

func _initialize() -> void:
	var built := 0
	var failed := 0
	for id in DirAccess.get_directories_at(GEDIT):
		# build any scene dir with at least one render glb — named GROUND/BUILD glbs for towns (e01g02.glb …),
		# or "<id>_m*.glb" / "<id>.glb" for interiors/story.
		var has_glb := false
		for f in DirAccess.get_files_at("%s%s" % [GEDIT, id]):
			if String(f).get_extension() == "glb":
				has_glb = true
				break
		if not has_glb:
			continue
		if build_one(id):
			built += 1
		else:
			failed += 1
			push_warning("build_level: failed %s" % id)
	print("built %d level scenes (%d failed)" % [built, failed])
	quit()

func build_one(id: String) -> bool:
	# A scene can embed several RENDER MDS (e.g. georama towns: e01 = 5 render glbs); load them all.
	# Each render MDS exports as "<id>_m<k>.glb" (multi-MDS) or "<id>.glb" (single); collision MDS emit no glb.
	var glbs: Array = []
	for f in DirAccess.get_files_at("%s%s" % [GEDIT, id]):
		if String(f).get_extension() == "glb":
			glbs.append("%s%s/%s" % [GEDIT, id, f])
	glbs.sort()
	if glbs.is_empty():
		return false

	var root := Node3D.new()
	root.name = id
	root.set_script(load("res://scripts/static_level.gd"))

	var geo := Node3D.new()
	geo.name = "Geometry"
	root.add_child(geo); geo.owner = root
	# EDITAREA placement (from grid.json): the build-plane mesh (e01g01) is authored at its local origin and must
	# shift to the EDITAREA origin to sit under the grid cells. Read it so we can offset that one glb.
	var ed_mesh := ""
	var ed_origin := Vector3.ZERO
	var placements := {}
	var grid_json := "%s%s/%s.grid.json" % [GEDIT, id, id]
	if FileAccess.file_exists(grid_json):
		var gj = JSON.parse_string(FileAccess.get_file_as_string(grid_json))
		if gj is Dictionary:
			if gj.has("editarea"):
				ed_mesh = String(gj["editarea"].get("mesh", ""))
				var o = gj["editarea"].get("origin", [0, 0, 0])
				ed_origin = Vector3(o[0], o[1], o[2])
			if gj.has("placements"):
				placements = gj["placements"]
	# The C# 'map' step already emits ONLY the meshes that belong in the scene: for georama towns that's the
	# named GROUND + fixed BUILD glbs (no part-template pile); for interiors/story it's the whole scene. So just
	# load every emitted glb into Geometry, positioned at its cfg-authored spot (most 0,0,0; some local-authored).
	for g in glbs:
		var packed := load(g) as PackedScene
		if packed == null:
			continue
		var part := packed.instantiate()
		part.name = String((g as String).get_file().get_basename())
		if ed_mesh != "" and part.name == ed_mesh:
			part.position = ed_origin  # build-plane -> the EDITAREA (grid) origin
		elif placements.has(part.name):
			var pp = placements[part.name]  # GROUND/BUILD -> its cfg authored position
			part.position = Vector3(pp[0], pp[1], pp[2])
		geo.add_child(part); part.owner = root

	# georama buildable-cell grid (towns only): GeoramaGrid loads <id>.grid.json and shows the cells.
	if FileAccess.file_exists(grid_json):
		var grid := Node3D.new()
		grid.name = "GeoramaGrid"
		grid.set_script(load("res://scripts/georama_grid.gd"))
		grid.set("grid_path", grid_json)
		root.add_child(grid); grid.owner = root

	# lighting — the room's real values from <id>.cfg (via <id>.lighting.json); neutral fallback otherwise.
	var we := WorldEnvironment.new(); we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = 1.0
	env.background_color = Color(0.05, 0.05, 0.07)
	env.ambient_light_color = Color(0.4, 0.4, 0.45)
	var lights_data: Array = []
	var lighting_path := "%s%s/%s.lighting.json" % [GEDIT, id, id]
	if FileAccess.file_exists(lighting_path):
		var lp = JSON.parse_string(FileAccess.get_file_as_string(lighting_path))
		if lp is Dictionary:
			if lp.has("ambient"):
				env.ambient_light_color = Color(lp["ambient"][0] / 255.0, lp["ambient"][1] / 255.0, lp["ambient"][2] / 255.0)
			var top := Color(0.05, 0.05, 0.07)
			if lp.has("bgColor"):
				top = Color(lp["bgColor"][0] / 255.0, lp["bgColor"][1] / 255.0, lp["bgColor"][2] / 255.0)
				env.background_color = top
			# towns ship BG_COL (sky top) + BG_COL2 (sky bottom) = a gradient sky, plus FOG (start,end,rgb).
			if lp.has("bgColor2"):
				var bottom := Color(lp["bgColor2"][0] / 255.0, lp["bgColor2"][1] / 255.0, lp["bgColor2"][2] / 255.0)
				var sky_mat := ProceduralSkyMaterial.new()
				sky_mat.sky_top_color = top
				sky_mat.sky_horizon_color = bottom
				sky_mat.ground_horizon_color = bottom
				sky_mat.ground_bottom_color = bottom
				sky_mat.sun_angle_max = 0.0
				var sky := Sky.new(); sky.sky_material = sky_mat
				env.sky = sky
				env.background_mode = Environment.BG_SKY
			if lp.has("fog"):
				var fg: Array = lp["fog"]
				env.fog_enabled = true
				env.fog_mode = Environment.FOG_MODE_DEPTH
				env.fog_depth_begin = float(fg[0])
				env.fog_depth_end = max(float(fg[1]), float(fg[0]) + 1.0)
				env.fog_light_color = Color(fg[2] / 255.0, fg[3] / 255.0, fg[4] / 255.0)
			lights_data = lp.get("lights", [])
	we.environment = env
	root.add_child(we); we.owner = root

	if lights_data.is_empty():
		var fill := DirectionalLight3D.new(); fill.name = "Fill"
		fill.rotation_degrees = Vector3(-55, -35, 0); fill.light_energy = 0.8
		root.add_child(fill); fill.owner = root
	else:
		var li := 0
		for L in lights_data:
			var light := DirectionalLight3D.new(); light.name = "Light%d" % li; li += 1
			light.light_color = Color(L["color"][0] / 255.0, L["color"][1] / 255.0, L["color"][2] / 255.0)
			light.light_energy = 1.4
			var src := Vector3(L["pos"][0], L["pos"][1], L["pos"][2])
			if src.length() > 0.01:
				light.look_at_from_position(src.normalized() * 30.0, Vector3.ZERO, Vector3.UP)
			root.add_child(light); light.owner = root

	# COLLISION: the named flat-hull collision (<id>_col.json). For georama towns the C# step routes ONLY the
	# GROUND/BUILD chunks' collision (e01g02_a etc.) — the real walkable ground at Y~0, not the part pile.
	var col_path := "%s%s/%s_col.json" % [GEDIT, id, id]
	if FileAccess.file_exists(col_path):
		var cdata = JSON.parse_string(FileAccess.get_file_as_string(col_path))
		if cdata is Dictionary and cdata.has("faces"):
			var arr: Array = cdata["faces"]
			var pts := PackedVector3Array()
			var ci := 0
			while ci + 2 < arr.size():
				pts.append(Vector3(arr[ci], arr[ci + 1], arr[ci + 2]))
				ci += 3
			if pts.size() >= 3:
				var shape := ConcavePolygonShape3D.new(); shape.set_faces(pts)
				var body := StaticBody3D.new(); body.name = "CollisionHull"
				var cs := CollisionShape3D.new(); cs.name = "Hull"; cs.shape = shape
				body.add_child(cs)
				root.add_child(body); body.owner = root; cs.owner = root

	# markers: a named Marker3D per func_ point + spawn the player at the entrance (any func_mapj*, then func_drr*).
	var spawn_pos := Vector3(0, 8, 0)
	var spawn_rot := 0.0
	var markers_path := "%s%s/%s.markers.json" % [GEDIT, id, id]
	if FileAccess.file_exists(markers_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(markers_path))
		if parsed is Dictionary:
			var by_name := {}
			for m in parsed.get("markers", []):
				by_name[m["name"]] = m
				var mk := Marker3D.new(); mk.name = m["name"]
				mk.position = Vector3(m["pos"][0], m["pos"][1], m["pos"][2])
				mk.rotation.y = float(m["rotY"])
				root.add_child(mk); mk.owner = root
			var entry = null
			for mname in by_name:
				if String(mname).begins_with("func_mapj"):
					entry = by_name[mname]; break
			if entry == null:
				for mname in by_name:
					if String(mname).begins_with("func_drr"):
						entry = by_name[mname]; break
			if entry != null:
				spawn_pos = Vector3(entry["pos"][0], entry["pos"][1] + 2.0, entry["pos"][2])
				spawn_rot = float(entry["rotY"])

	var spawn := Marker3D.new(); spawn.name = "Spawn"
	spawn.position = spawn_pos; spawn.rotation.y = spawn_rot
	root.add_child(spawn); spawn.owner = root

	var ps := PackedScene.new()
	if ps.pack(root) != OK:
		return false
	return ResourceSaver.save(ps, "res://scenes/levels/%s.tscn" % id) == OK
