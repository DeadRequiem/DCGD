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
	root.set_script(load("res://scripts/world/static_level.gd"))

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
			part.set_meta("walk_floor", true)   # the flat plaza-interior floor. static_level collides ONLY
												# this; the other meshes are visual props (stepped stairs etc.)
												# whose real collision is the smooth あたりポリゴン CollisionHull.
		elif placements.has(part.name):
			var pp = placements[part.name]  # GROUND/BUILD -> its cfg authored position
			part.position = Vector3(pp[0], pp[1], pp[2])
		geo.add_child(part); part.owner = root

	# georama buildable-cell grid (towns only): GeoramaGrid loads <id>.grid.json and shows the cells.
	if FileAccess.file_exists(grid_json):
		var grid := Node3D.new()
		grid.name = "GeoramaGrid"
		grid.set_script(load("res://scripts/world/georama_grid.gd"))
		grid.set("grid_path", grid_json)
		root.add_child(grid); grid.owner = root

	# lighting — the room's real values from <id>.cfg (via <id>.lighting.json); neutral fallback otherwise.
	# INTERIORS (i##) are enclosed rooms: brighter ambient + a stronger key light, and NO sky/fog (exterior-only).
	# The cfg LIGHT_C is a sun-ish DIRECTION (a unit-ish vector, often the SAME one copied across rooms), not a
	# room lamp position — so a DirectionalLight is correct; interiors just need more exposure than the raw cfg
	# energies give, else correctly-textured walls read as flat black (what looked like "broken textures").
	var is_interior := id.begins_with("i")
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
			if lp.has("bgColor2") and not is_interior:
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
			if lp.has("fog") and not is_interior:
				var fg: Array = lp["fog"]
				env.fog_enabled = true
				env.fog_mode = Environment.FOG_MODE_DEPTH
				env.fog_depth_begin = float(fg[0])
				env.fog_depth_end = max(float(fg[1]), float(fg[0]) + 1.0)
				env.fog_light_color = Color(fg[2] / 255.0, fg[3] / 255.0, fg[4] / 255.0)
				env.fog_sky_affect = 0.0   # default 1.0 washes the whole sky dome with the warm fog colour (cream); fog should tint distant geometry ONLY
			lights_data = lp.get("lights", [])
	env.ambient_light_energy = 2.0 if is_interior else 1.0   # enclosed rooms need more fill than the dim cfg ambient
	we.environment = env
	root.add_child(we); we.owner = root

	if lights_data.is_empty():
		var fill := DirectionalLight3D.new(); fill.name = "Fill"
		fill.rotation_degrees = Vector3(-55, -35, 0); fill.light_energy = 1.2 if is_interior else 0.8
		root.add_child(fill); fill.owner = root
	else:
		var li := 0
		for L in lights_data:
			var light := DirectionalLight3D.new(); light.name = "Light%d" % li; li += 1
			light.light_color = Color(L["color"][0] / 255.0, L["color"][1] / 255.0, L["color"][2] / 255.0)
			light.light_energy = 2.6 if is_interior else 1.4
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
				# The あたりポリゴン floor/ramp tris are wound facing DOWN. Jolt (and GodotPhysics)
				# back-face-cull concave raycasts, so a vertical floor-probe ray MISSES the hull
				# entirely unless backface collision is on (proven: identical tri hits one way, misses
				# the other). Without this the whole hull is invisible to a down-ray floor solver.
				shape.backface_collision = true
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
				if String(m["name"]).begins_with("func_fire"):   # brazier/torch spot -> bake a flame + warm light
					_bake_fire(root, mk.position)
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

	# WORLD-NAV door triggers. A TOWN bakes one Area3D per build/ground warp (from <id>.warps.json) — walk into
	# it and game_root swaps to its target, landing you at that area's Spawn. An INTERIOR bakes a single RETURN
	# trigger on its exit door (the Spawn) so walking back onto it sends you to wherever you came from. The
	# kind:"part" town doors ride placed georama parts (no fixed entrance yet) — skipped here.
	var warps_path := "%s%s/%s.warps.json" % [GEDIT, id, id]
	if FileAccess.file_exists(warps_path):
		var wj = JSON.parse_string(FileAccess.get_file_as_string(warps_path))
		if wj is Dictionary:
			for w in wj.get("warps", []):
				if String(w.get("kind", "")) == "part" or w.get("entrance", null) == null:
					continue
				var en = w["entrance"]
				# The cfg ENTRANCE is in the owner building's LOCAL frame (same as its render glb + collision
				# hull). Shift it by the owner's cfg placement so the trigger lands ON the building, not ~800u
				# away at the local origin (the render glb + the C#-side collision both get this same offset).
				var off := Vector3.ZERO
				var owner_id := String(w.get("owner", ""))
				if placements.has(owner_id):
					off = Vector3(placements[owner_id][0], placements[owner_id][1], placements[owner_id][2])
				var dname := "Door_%s_%d" % [String(w["target"]), int(w["slot"])]
				var door := _make_door(dname, Vector3(en["pos"][0], en["pos"][1], en["pos"][2]) + off,
					Vector3(en["size"][0], en["size"][1], en["size"][2]), float(en.get("rotY", 0.0)))
				door.set("target", String(w["target"]))
				door.set("dest_entrance", "Spawn")
				door.set("return_key", dname)
				root.add_child(door); _own_rec(door, root)
	elif id.begins_with("i"):
		var ret := _make_door("ReturnDoor", spawn_pos, Vector3(14, 16, 14), spawn_rot)
		ret.set("target", "")          # empty target = return to caller
		ret.set("dest_entrance", "")
		ret.set("return_key", "")
		root.add_child(ret); _own_rec(ret, root)

	# TOWN DAY/NIGHT: attach the sky-cycle controller (interpolates the 12-slot time_table at runtime + gates fires).
	var tt_path := "%s%s/%s.time_table.json" % [GEDIT, id, id]
	if not id.begins_with("i") and FileAccess.file_exists(tt_path):
		var sky := Node.new()
		sky.name = "SkyCycle"
		sky.set_script(load("res://scripts/world/sky_cycle.gd"))
		sky.set("table_path", tt_path)
		root.add_child(sky); sky.owner = root

	var ps := PackedScene.new()
	if ps.pack(root) != OK:
		return false
	return ResourceSaver.save(ps, "res://scenes/levels/%s.tscn" % id) == OK

## Build a world-nav door Area3D (door_trigger.gd) with a box volume. Min dims keep the trigger comfortably
## tall/wide so the player's capsule reliably overlaps it even when the cfg authored a tight door.
func _make_door(dname: String, pos: Vector3, size: Vector3, rot_y: float) -> Area3D:
	var area := Area3D.new()
	area.name = dname
	area.position = pos
	area.rotation.y = rot_y
	area.set_script(load("res://scripts/world/door_trigger.gd"))
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(size.x, 8.0), maxf(size.y, 16.0), maxf(size.z, 8.0))
	cs.shape = box
	area.add_child(cs)
	return area

## Set `owner` on a freshly added node and all its descendants so PackedScene.pack() serializes them.
func _own_rec(n: Node, r: Node) -> void:
	n.owner = r
	for c in n.get_children():
		_own_rec(c, r)

## Bake an animated flame (additive billboard particles) + a warm point light at a func_fire marker (brazier/
## torch). Procedural — no texture asset needed; works for every scene's fire markers. Tune the look in-engine.
func _bake_fire(root: Node3D, pos: Vector3) -> void:
	var fire := Node3D.new()
	fire.name = "Fire_%d_%d_%d" % [int(pos.x), int(pos.y), int(pos.z)]
	fire.position = pos
	root.add_child(fire); fire.owner = root

	var light := OmniLight3D.new()
	light.name = "Light"
	light.light_color = Color(1.0, 0.6, 0.25)
	light.light_energy = 2.0
	light.omni_range = 28.0
	light.position = Vector3(0, 4, 0)
	fire.add_child(light); light.owner = root

	var flame := GPUParticles3D.new()
	flame.name = "Flame"
	flame.amount = 24
	flame.lifetime = 0.6
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 12.0
	pm.initial_velocity_min = 6.0
	pm.initial_velocity_max = 12.0
	pm.gravity = Vector3(0, 4, 0)
	pm.scale_min = 1.5
	pm.scale_max = 3.0
	pm.color = Color(1.0, 0.55, 0.15)
	flame.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(3, 3)
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dm.albedo_color = Color(1.0, 0.5, 0.1)
	qm.material = dm
	flame.draw_pass_1 = qm
	fire.add_child(flame); flame.owner = root
