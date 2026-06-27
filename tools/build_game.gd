# Headless builder: scaffolds the persistent-root architecture.
#   scenes/player.tscn ; the player, standalone (model + collision + camera rig)
#   scenes/levels/test_area.tscn ; the first area (ground/boxes/lights/env + Spawn), NO player
#   scenes/game_root.tscn ; persistent root: Player + CurrentLevel slot + game_root.gd
# Run: godot --headless --path <Project> --script res://build_game.gd
extends SceneTree

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scenes/levels"))
	_build_player()
	_build_test_area()
	_build_game_root()
	quit()

func _save(node: Node, path: String) -> void:
	var ps := PackedScene.new()
	var err := ps.pack(node)
	print("pack %s = %d ; save = %d" % [path, err, ResourceSaver.save(ps, path)])

func _build_player() -> void:
	var player := CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://scripts/characters/player.gd"))

	var model := (load("res://assets/models/chara/c01d/c01d.glb") as PackedScene).instantiate()
	model.name = "Model"
	player.add_child(model); model.owner = player

	var col := CollisionShape3D.new(); col.name = "CollisionShape3D"
	var cap := CapsuleShape3D.new(); cap.radius = 2.5; cap.height = 14.0
	col.shape = cap; col.position = Vector3(0, 7, 0)
	player.add_child(col); col.owner = player

	var pivot := Node3D.new(); pivot.name = "CamPivot"; pivot.position = Vector3(0, 11, 0)
	player.add_child(pivot); pivot.owner = player
	var arm := SpringArm3D.new(); arm.name = "SpringArm3D"
	arm.spring_length = 50.0; arm.rotation_degrees = Vector3(-20, 0, 0)
	pivot.add_child(arm); arm.owner = player
	var cam := Camera3D.new(); cam.name = "Camera3D"; cam.far = 4000.0; cam.current = true
	arm.add_child(cam); cam.owner = player

	_save(player, "res://scenes/player.tscn")

func _build_test_area() -> void:
	var root := Node3D.new(); root.name = "TestArea"

	var we := WorldEnvironment.new(); we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.52, 0.6, 0.72)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.45, 0.5)
	env.ambient_light_energy = 0.7
	we.environment = env
	root.add_child(we); we.owner = root

	var sun := DirectionalLight3D.new(); sun.name = "Sun"
	sun.rotation_degrees = Vector3(-52, -40, 0); sun.light_energy = 1.2; sun.shadow_enabled = true
	root.add_child(sun); sun.owner = root

	var ground := StaticBody3D.new(); ground.name = "Ground"
	root.add_child(ground); ground.owner = root
	var gmesh := MeshInstance3D.new(); gmesh.name = "Mesh"
	var plane := PlaneMesh.new(); plane.size = Vector2(800, 800)
	var gmat := StandardMaterial3D.new(); gmat.albedo_color = Color(0.32, 0.36, 0.32)
	plane.material = gmat; gmesh.mesh = plane
	ground.add_child(gmesh); gmesh.owner = root
	var gcol := CollisionShape3D.new(); gcol.name = "Col"
	gcol.shape = WorldBoundaryShape3D.new()
	ground.add_child(gcol); gcol.owner = root

	var bmat := StandardMaterial3D.new(); bmat.albedo_color = Color(0.7, 0.5, 0.35)
	for i in range(7):
		var box := StaticBody3D.new(); box.name = "Box%d" % i
		box.position = Vector3(cos(i * 1.3) * 55.0, 5.0, sin(i * 2.1) * 55.0)
		root.add_child(box); box.owner = root
		var bm := MeshInstance3D.new()
		var bmesh := BoxMesh.new(); bmesh.size = Vector3(10, 10, 10); bmesh.material = bmat
		bm.mesh = bmesh; box.add_child(bm); bm.owner = root
		var bc := CollisionShape3D.new()
		var bs := BoxShape3D.new(); bs.size = Vector3(10, 10, 10)
		bc.shape = bs; box.add_child(bc); bc.owner = root

	var spawn := Marker3D.new(); spawn.name = "Spawn"; spawn.position = Vector3(0, 4, 35)
	root.add_child(spawn); spawn.owner = root

	_save(root, "res://scenes/levels/test_area.tscn")

func _build_game_root() -> void:
	var root := Node3D.new(); root.name = "Game"
	root.set_script(load("res://scripts/game_root.gd"))

	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate()
	player.name = "Player"
	root.add_child(player); player.owner = root

	var slot := Node3D.new(); slot.name = "CurrentLevel"
	root.add_child(slot); slot.owner = root

	_save(root, "res://scenes/game_root.tscn")
