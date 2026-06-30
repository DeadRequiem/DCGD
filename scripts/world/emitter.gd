extends Node3D
## A DC1 light emitter (torch / brazier / candle / lamp) baked at a func_* marker. Owns its OWN day/night gating so
## sky_cycle doesn't have to: in a TOWN it shows at DUSK + NIGHT (TimeOfDay.fires_lit) and hides through the bright
## day; in an INTERIOR (gated=false) it stays lit. DC1 has no real per-object lights -- the visual (a flame billboard
## or a glow halo) is built by build_level alongside this script; emitter.gd only toggles visibility.

@export var gated := true   # true: gate by time-of-day (towns); false: always lit (interiors). Set by build_level.

func _ready() -> void:
	if not gated:
		visible = true
		return
	_update()
	if not TimeOfDay.time_changed.is_connected(_on_time):
		TimeOfDay.time_changed.connect(_on_time)

func _on_time(_t: int) -> void:
	_update()

func _update() -> void:
	visible = TimeOfDay.fires_lit()   # DUSK or NIGHT
