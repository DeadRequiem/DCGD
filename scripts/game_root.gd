extends Node3D

@export_file("*.tscn") var start_level_path := "res://scenes/levels/e01.tscn"

@onready var _player: Node3D = $Player
@onready var _level_slot: Node3D = $CurrentLevel

func _ready() -> void:
	if start_level_path != "":
		load_level(load(start_level_path))

## Swap the active area. Frees the current one, instances the new, and drops the player at its
## `Spawn` marker (if present). `scene` may be a baked area or, later, a generated dungeon floor.
func load_level(scene: PackedScene) -> void:
	for c in _level_slot.get_children():
		_level_slot.remove_child(c)
		c.queue_free()
	if scene == null:
		return
	var lvl := scene.instantiate()
	_level_slot.add_child(lvl)
	await get_tree().physics_frame        # let the new area's collision register before resolving the spawn
	if _player:
		_player.global_position = _resolve_spawn(lvl)
		_player.velocity = Vector3.ZERO

## Where to drop the player. For a GEORAMA town the entry marker can sit inside a terrain hill (the town is
## un-built — no placed parts to enter through), so snap to the lowest buildable-cell floor (the valley you
## actually build on). Otherwise use the area's `Spawn` marker.
func _resolve_spawn(lvl: Node) -> Vector3:
	var grid := lvl.get_node_or_null("GeoramaGrid")
	var space := (lvl as Node3D).get_world_3d().direct_space_state if lvl is Node3D else null
	if grid != null and space != null:
		var best := Vector3.INF
		for c in grid.get("cells"):
			var p: Vector3 = c["pos"]
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3(0, 400, 0), p + Vector3(0, -400, 0)))
			if not hit.is_empty() and hit["position"].y < best.y:
				best = hit["position"]
		if best != Vector3.INF:
			return best + Vector3(0, 3, 0)
	var spawn := lvl.get_node_or_null("Spawn") as Node3D
	return spawn.global_position if spawn != null else Vector3(0, 8, 0)
