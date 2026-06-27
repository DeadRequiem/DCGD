extends Area3D
## A WORLD-NAV door (baked by build_level from <id>.warps.json). Stand in its volume and press `action`
## (A button / E key) to go through — game_root swaps to `target` and lands the player at `dest_entrance`.
## An EMPTY `target` means RETURN: game_root sends you back to wherever you came from (an interior's exit door).
## A PRESS is required (not on-touch) so you never warp by brushing a doorway; game_root's post-spawn cooldown
## also keeps the door you LAND on from firing until you've had a moment to step off it.

@export var target := ""              # destination area id ("i01h06" / "dungeon"), or "" = return to caller
@export var dest_entrance := "Spawn"  # node name to land at in the destination scene
@export var return_key := ""          # this door's own node name — where a return warp lands you back

var _player_inside := false

func _ready() -> void:
	body_entered.connect(_on_enter)
	body_exited.connect(_on_exit)

func _on_enter(body: Node) -> void:
	if body.is_in_group("player"):
		_player_inside = true

func _on_exit(body: Node) -> void:
	if body.is_in_group("player"):
		_player_inside = false

func _process(_delta: float) -> void:
	if not _player_inside or not Input.is_action_just_pressed("action"):
		return
	var gr := get_tree().get_first_node_in_group("game_root")
	if gr != null and gr.has_method("warp_through") and gr.can_warp():
		gr.warp_through(self)
