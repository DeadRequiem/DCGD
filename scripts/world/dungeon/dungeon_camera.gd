extends Node3D
class_name DungeonCamera
## DC1 Dungeon — follow-cam constraint for the dungeon floors.
##
## The dungeon follow-cam must stay out of the cave WALLS but must NOT collapse onto the player because of the
## FLOOR. The previous integration let the player's SpringArm3D collide the whole dungeon CollisionHull on the
## default layer — but that hull is one trimesh mixing the walkable FLOOR tris and the cave WALL tris, plus the
## per-cell FloorPatch boxes. A SpringArm pitched ~20deg down from a pivot 11u up therefore HITS the floor patch
## a few units behind/below the pivot and collapses the arm 50u -> ~3u onto Toan's back (the "back-of-poncho"
## spawn shot + the wall-graze collapses seen in real play).
##
## FIX (real-play): we take the dungeon hull off the SpringArm's own collision (collision_mask=0) and resolve the
## camera distance OURSELVES, the DC1 way — by the あたりポリゴン NORMAL. We cast pivot->desired-eye against the
## default world layer; only a tri the game authored as a WALL (|normal.y| < FLOOR_NY) pulls the camera IN, and
## never closer than MIN_CAM_DIST (the cam never rams the poncho). FLOOR/ramp tris (and the FloorPatch boxes,
## which read as up-facing) are IGNORED so the floor can never collapse the cam. No _v hull is collided (those
## don't enclose the pivot on stair/entry tiles); this normal-classified wall cast replaces it cleanly.

const CAM_LAYER := 4    # must match DungeonFloorGen.CAM_LAYER (kept for compatibility / boss arena hulls)
const FLOOR_NY := 0.3   # |normal.y| above this = walkable floor/ramp -> NEVER collapses the cam; below = a wall.
const MIN_CAM_DIST := 20.0   # the cam never pulls closer than this to the pivot (no back-of-poncho collapse).
const STANDOFF := 4.0        # back the eye off a wall hit by this much so the near-plane doesn't clip the wall.

@export var player_path: NodePath
@export var enable_hard_clamp := true

# the active floor handle (DungeonFloorGen or DungeonBossFloor) — kept so rebind() still works, but the wall
# cast queries the default WORLD layer (the real cave hull) rather than the CAM_LAYER _v volumes.
var _floor: Node3D = null
var _player: Node3D = null
var _pivot: Node3D = null
var _spring: SpringArm3D = null
var _camera: Camera3D = null
var _full_len := 50.0        # the arm's authored full length (captured before we zero its own collision).
var _world_mask := 1         # the default world physics layer the dungeon CollisionHull lives on.

func _ready() -> void:
	if player_path != NodePath():
		_player = get_node_or_null(player_path) as Node3D
	if _player == null:
		var p := get_parent()
		if p:
			_player = p.get_node_or_null("Player") as Node3D
	if _player == null:
		# D3.5: when hosted under game_root the persistent Player is in the "player" group, not a sibling.
		_player = get_tree().get_first_node_in_group("player") as Node3D
	_grab_spring()

func _grab_spring() -> void:
	if _player == null:
		return
	_pivot = _player.get_node_or_null("CamPivot") as Node3D
	if _pivot:
		_spring = _pivot.get_node_or_null("SpringArm3D") as SpringArm3D
	if _spring:
		_camera = _spring.get_node_or_null("Camera3D") as Camera3D
		# Capture the authored full length, then DISABLE the SpringArm's own collision entirely. We resolve the
		# camera distance ourselves below (normal-classified wall cast), so the floor/floor-patch can never
		# collapse the arm. Re-grab safe (idempotent): only overwrite _full_len from a non-collapsed spring.
		if _spring.spring_length > 1.0:
			_full_len = _spring.spring_length
		_spring.collision_mask = 0
		_spring.spring_length = _full_len

## Called by dungeon_run.gd after every floor (re)build so the cam re-grabs the spring if needed.
func rebind(floor: Node3D) -> void:
	_floor = floor
	if _spring == null:
		_grab_spring()

func _physics_process(_delta: float) -> void:
	if _spring == null or _pivot == null:
		return
	# Desired eye = the arm's full extent along the pitched spring -Z, in world space.
	var pivot_pos := _pivot.global_position
	var arm_dir := (_spring.global_transform.basis * Vector3(0, 0, 1)).normalized()  # +Z local = backward along arm
	var desired := MIN_CAM_DIST
	var space := get_world_3d().direct_space_state
	# cast pivot -> full-length eye; a WALL tri shortens us, a FLOOR/ramp tri is ignored (never collapses the cam).
	var from := pivot_pos
	var to := pivot_pos + arm_dir * _full_len
	var hit_len := _full_len
	# walk the ray: the first WALL-normal hit wins. We re-cast from just past a floor hit so a grazed floor patch
	# doesn't end the search. A couple of iterations is plenty for the cave cross-section.
	var cursor := from
	var excl: Array[RID] = []
	if _player is CollisionObject3D:
		excl = [(_player as CollisionObject3D).get_rid()]
	for _i in range(4):
		var q := PhysicsRayQueryParameters3D.create(cursor, to)
		q.collision_mask = _world_mask
		q.exclude = excl
		var h := space.intersect_ray(q)
		if h.is_empty():
			break
		var n: Vector3 = h["normal"]
		var hp: Vector3 = h["position"]
		if absf(n.y) >= FLOOR_NY:
			# a floor/ramp tri (or an up/down-facing FloorPatch face) — IGNORE it, continue past it.
			cursor = hp + arm_dir * 0.5
			continue
		# a true WALL ahead -> shorten the arm to just short of it (with a standoff), never below MIN.
		hit_len = pivot_pos.distance_to(hp) - STANDOFF
		break
	desired = clampf(hit_len, MIN_CAM_DIST, _full_len)
	_spring.spring_length = desired
