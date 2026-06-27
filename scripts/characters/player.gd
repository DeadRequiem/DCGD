extends CharacterBody3D

@export var walk_speed := 22.0
@export var run_speed := 48.0
@export var acceleration := 320.0
@export var deceleration := 420.0
@export var gravity := 70.0
@export var turn_speed := 12.0
@export var blend_smooth := 12.0
@export var mouse_sensitivity := 0.005
@export var stick_look_speed := 3.0
@export var cam_follow := true
@export var auto_trail_speed := 2.0
@export var center_speed := 9.0
@export var cam_input_grace := 1.2
@export var adjust_cam_speed := 2.2
@export var fp_pivot_height := 14.0

@onready var _model: Node3D = $Model
@onready var _pivot: Node3D = $CamPivot
@onready var _spring: SpringArm3D = $CamPivot/SpringArm3D
@onready var _anim: AnimationPlayer = find_child("AnimationPlayer", true, false)

var _tree: AnimationTree
var _blend := 0.0 
var _pitch := -0.35
var _using_gamepad := false
var _cam_cooldown := 0.0
var _centering := false
var _first_person := false
var _tp_distance := 0.0
var _tp_pivot_y := 0.0

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _spring:
		_spring.rotation.x = _pitch
	_setup_locomotion_tree()
	_tp_distance = _spring.spring_length
	_tp_pivot_y = _pivot.position.y

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_pivot.rotation.y -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.2, 0.4)
		_spring.rotation.x = _pitch
		_cam_cooldown = cam_input_grace   # manual orbit overrides auto-trail
		_centering = false
	elif event.is_action_pressed("camControl"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE \
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED

	# track the active device so the speed model fits it. The >0.5 gate is to ignore idle-stick jitter.
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.5):
		_using_gamepad = true
	elif event is InputEventKey and event.pressed:
		_using_gamepad = false

func _process(delta: float) -> void:
	# right-stick camera orbit
	# switch to look_* actions later for rebindable camera
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		return
	var pad: int = pads[0]
	var steered := false

	# right-stick free orbit
	var look := Vector2(Input.get_joy_axis(pad, JOY_AXIS_RIGHT_X),
						Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y))
	if look.length() >= 0.2:                       # deadzone
		_pivot.rotation.y -= look.x * stick_look_speed * delta
		_pitch = clampf(_pitch - look.y * stick_look_speed * delta, -1.2, 0.4)
		_spring.rotation.x = _pitch
		steered = true

	# L1/R1 rotate (When a COMBAT context exists, gate this to EXPLORE only.)
	var spin := 0.0
	if Input.is_joy_button_pressed(pad, JOY_BUTTON_LEFT_SHOULDER): spin += 1.0
	if Input.is_joy_button_pressed(pad, JOY_BUTTON_RIGHT_SHOULDER): spin -= 1.0
	if spin != 0.0:
		_pivot.rotation.y += spin * adjust_cam_speed * delta
		steered = true

	if steered:
		_cam_cooldown = cam_input_grace
		_centering = false

func _physics_process(delta: float) -> void:
	var move := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var mag := minf(move.length(), 1.0)
	var goal_speed := _goal_speed(mag, _using_gamepad, Input.is_action_pressed("run"))
	var dir := Vector3.ZERO
	
	if mag > 0.0:
		dir = Vector3(move.x, 0.0, move.y).rotated(Vector3.UP, _pivot.global_rotation.y).normalized()
		
	var target := dir * goal_speed
	var rate := acceleration if mag > 0.0 else deceleration
	var hv := Vector3(velocity.x, 0.0, velocity.z).move_toward(target, rate * delta)
	velocity.x = hv.x
	velocity.z = hv.z

	# grav
	velocity.y = -2.0 if is_on_floor() else velocity.y - gravity * delta

	move_and_slide()

	# turn the model to face the move direction
	if dir.length() > 0.01:
		_model.rotation.y = lerp_angle(_model.rotation.y, atan2(dir.x, dir.z), turn_speed * delta)

	# camera auto-trails behind you while moving unless you've recently turned it yourself.
	_cam_cooldown = maxf(_cam_cooldown - delta, 0.0)
	if Input.is_action_just_pressed("center_camera"):
		_centering = true
	if Input.is_action_just_pressed("f_person_toggle"):
		_set_first_person(not _first_person)
	var behind := _model.rotation.y + PI
	if _centering:
		_pivot.rotation.y = lerp_angle(_pivot.rotation.y, behind, center_speed * delta)
		if absf(wrapf(behind - _pivot.rotation.y, -PI, PI)) < 0.03:
			_centering = false
	elif cam_follow and dir.length() > 0.01 and _cam_cooldown <= 0.0:
		_pivot.rotation.y = lerp_angle(_pivot.rotation.y, behind, auto_trail_speed * delta)

	if _tree:
		var spd := Vector2(velocity.x, velocity.z).length()
		var loco := spd / maxf(walk_speed, 0.001)
		if spd > walk_speed:
			loco = 1.0 + (spd - walk_speed) / maxf(run_speed - walk_speed, 0.001)
		loco = clampf(loco, 0.0, 2.0)
		_blend = move_toward(_blend, loco, blend_smooth * delta)
		_tree.set("parameters/blend_position", _blend)

func _setup_locomotion_tree() -> void:
	if _anim == null:
		push_warning("player: no AnimationPlayer found; locomotion blend disabled")
		return
	for n in ["idle", "walk", "run"]:
		if _anim.has_animation(n):
			_anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	var bs := AnimationNodeBlendSpace1D.new()
	bs.min_space = 0.0
	bs.max_space = 2.0
	bs.sync = true
	bs.add_blend_point(_clip_node("idle"), 0.0, -1, "idle")
	bs.add_blend_point(_clip_node("walk"), 1.0, -1, "walk")
	bs.add_blend_point(_clip_node("run"), 2.0, -1, "run")
	_tree = AnimationTree.new()
	_tree.name = "AnimationTree"
	_tree.tree_root = bs
	add_child(_tree)
	_tree.anim_player = _tree.get_path_to(_anim)
	_tree.active = true

func _clip_node(anim_name: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = anim_name
	return node

func _goal_speed(mag: float, gamepad: bool, run_held: bool) -> float:
	if mag <= 0.0:
		return 0.0
	if gamepad:
		return mag * run_speed
	return run_speed if run_held else walk_speed

## Toggle first-person
func _set_first_person(on: bool) -> void:
	_first_person = on
	if on:
		_spring.spring_length = 0.4
		_pivot.position.y = fp_pivot_height
		_model.visible = false
		_pivot.rotation.y = _model.rotation.y + PI   # snap to look where the player is facing
		_centering = false
		_cam_cooldown = 0.0
	else:
		_spring.spring_length = _tp_distance
		_pivot.position.y = _tp_pivot_y
		_model.visible = true
