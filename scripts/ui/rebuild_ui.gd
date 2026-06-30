extends CanvasLayer
class_name RebuildUI
## D3.5 — the town-rebuild UI (the Atora board + Edit-mode placement flow, Godot-native stand-in).
##
## A functional placement state machine driven by GeoramaState.carried_atla + a town's georama_grid:
##
##   LIST_ATLA  -> show the carried Atla; pick one                (board: AtoraSelect)
##   PICK_CELL  -> show buildable grid cells; pick one             (edit: PickUpEditAreaPoly + cursor)
##   CONFIRM    -> show the chosen Atla + cell; confirm/cancel     (CheckArea/CheckParts -> SetMapParts)
##   PLACED     -> grid.place_atla spawns the actor; brief result  (RemakeGrid + SetBuildEffect + greeting)
##   DONE       -> nothing left to place; close                    (EditExit)
##
## Navigation: Up/Down (move_up/move_down) move the cursor, `action` (E / A) confirms, `use` (Q / X) cancels/back.
## All transitions are also exposed as public methods (select_atla / select_cell / confirm / cancel) so a headless
## verification probe can drive the full loop without the player solver. Per-NPC dialog is deferred -> a generic
## greeting line on placement.

enum St { LIST_ATLA, PICK_CELL, CONFIRM, PLACED, DONE }

const ROW_H := 30
const PANEL_W := 520
const MAX_VISIBLE_CELLS := 14   # buildable cells shown per page (the EDITAREA is 14x12; we list a workable subset)

var _grid: Node = null          # the town's georama_grid
var _town_id := "e01"
var _state := St.LIST_ATLA
var _cursor := 0
var _sel_atla := -1             # index into carried_atla chosen in LIST_ATLA
var _sel_cell := -1             # grid cell index chosen in PICK_CELL
var _buildable: Array = []      # candidate grid cell indices for PICK_CELL (recomputed on entry)
var _last_result := ""          # the greeting / outcome line shown in PLACED

# UI nodes
var _root: Control
var _title: Label
var _list: VBoxContainer
var _hint: Label

signal closed
signal placed(cell: int, atla_id: int, part_name: String)

func _ready() -> void:
	layer = 50
	_build_ui()
	if _grid == null:
		# try to find a georama_grid in the current scene tree (the active town area)
		_grid = _find_grid()
	_enter_initial()

## Bind to a specific town grid (used by the town when it opens Rebuild Mode). Safe to call before/after _ready.
func bind(grid: Node, town_id := "") -> void:
	_grid = grid
	if town_id != "":
		_town_id = town_id
	elif grid != null and grid.get("town_id") != null and String(grid.get("town_id")) != "":
		_town_id = String(grid.get("town_id"))
	if is_inside_tree():
		_enter_initial()

func _find_grid() -> Node:
	var root := get_tree().current_scene
	if root == null:
		return null
	return _search_grid(root)

func _search_grid(n: Node) -> Node:
	if n.get_script() != null and n.has_method("place_atla"):
		return n
	for c in n.get_children():
		var r := _search_grid(c)
		if r != null:
			return r
	return null

# =====================================================================================================
# UI construction
# =====================================================================================================

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var panel := PanelContainer.new()
	panel.position = Vector2(40, 60)
	panel.custom_minimum_size = Vector2(PANEL_W, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.14, 0.92)
	sb.border_color = Color(0.9, 0.78, 0.3)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", sb)
	_root.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 28)
	_title.add_theme_color_override("font_color", Color(1, 0.92, 0.55))
	vb.add_child(_title)

	var sep := HSeparator.new()
	vb.add_child(sep)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	vb.add_child(_list)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 16)
	_hint.add_theme_color_override("font_color", Color(0.7, 0.82, 1.0))
	vb.add_child(_hint)

# =====================================================================================================
# State machine
# =====================================================================================================

func _enter_initial() -> void:
	if _carried().is_empty():
		_goto(St.DONE)
	else:
		_goto(St.LIST_ATLA)

func _carried() -> Array:
	var st := _gs()
	return st.carried_atla if st != null else []

func _goto(s: int) -> void:
	_state = s
	_cursor = 0
	match s:
		St.LIST_ATLA:
			_sel_atla = -1
			_sel_cell = -1
		St.PICK_CELL:
			_buildable = _compute_buildable()
	_refresh()

func _refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	match _state:
		St.LIST_ATLA: _draw_list_atla()
		St.PICK_CELL: _draw_pick_cell()
		St.CONFIRM:   _draw_confirm()
		St.PLACED:    _draw_placed()
		St.DONE:      _draw_done()

func _draw_list_atla() -> void:
	_title.text = "REBUILD NORUNE  —  Select an Atla"
	var carried := _carried()
	for i in carried.size():
		var a: Dictionary = carried[i]
		var info := _info(int(a.get("id", 0)))
		var row := "%s  (id %d, from floor %d)" % [String(info.get("name", a.get("name", "Atla"))), int(a.get("id", 0)), int(a.get("floor", 0))]
		_add_row(row, i == _cursor)
	_hint.text = "[Up/Down] choose   [E] select   [Q] close"

func _draw_pick_cell() -> void:
	var a: Dictionary = _carried()[_sel_atla]
	var info := _info(int(a.get("id", 0)))
	_title.text = "Place '%s'  —  Pick a grid cell" % String(info.get("name", "Atla"))
	for n in _buildable.size():
		var ci: int = _buildable[n]
		var cell: Dictionary = _grid.cell_at(ci)
		var p: Vector3 = cell.get("pos", Vector3.ZERO)
		_add_row("Cell %d   (%.0f, %.0f)" % [ci, p.x, p.z], n == _cursor)
	_hint.text = "[Up/Down] choose cell   [E] confirm cell   [Q] back"

func _draw_confirm() -> void:
	var a: Dictionary = _carried()[_sel_atla]
	var info := _info(int(a.get("id", 0)))
	var cell: Dictionary = _grid.cell_at(_sel_cell)
	var p: Vector3 = cell.get("pos", Vector3.ZERO)
	_title.text = "Confirm placement"
	_add_row("Atla:  %s (id %d)" % [String(info.get("name", "Atla")), int(a.get("id", 0))], false)
	_add_row("Cell:  %d  @ (%.0f, %.0f)" % [_sel_cell, p.x, p.z], false)
	_add_row("", false)
	_add_row("> CONFIRM" if _cursor == 0 else "  CONFIRM", _cursor == 0)
	_add_row("> CANCEL" if _cursor == 1 else "  CANCEL", _cursor == 1)
	_hint.text = "[Up/Down] choose   [E] select   [Q] back"

func _draw_placed() -> void:
	_title.text = "Built!"
	_add_row(_last_result, true)
	var remaining := _carried().size()
	_add_row("", false)
	_add_row("%d Atla remaining" % remaining, false)
	_hint.text = "[E] %s" % ("place another" if remaining > 0 else "finish")

func _draw_done() -> void:
	_title.text = "Rebuild complete"
	_add_row("No more Atla to place.", true)
	_hint.text = "[E] / [Q] close"

func _add_row(text: String, highlight: bool) -> void:
	var l := Label.new()
	l.text = ("> " + text) if highlight else ("  " + text)
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", Color(1, 1, 0.7) if highlight else Color(0.85, 0.88, 0.95))
	l.custom_minimum_size = Vector2(PANEL_W - 32, ROW_H)
	_list.add_child(l)

# =====================================================================================================
# Buildable cells — the candidate placement targets (CheckArea/EditAreaClip stand-in)
# =====================================================================================================

## Candidate cells the player can build on: grid cells not already occupied by a session placement. Capped to a
## workable page so the list stays usable (the full EDITAREA is 14x12). Ordered by index for determinism.
func _compute_buildable() -> Array:
	var out: Array = []
	if _grid == null:
		return out
	for i in _grid.cell_count():
		if not _grid.is_occupied(i):
			out.append(i)
		if out.size() >= MAX_VISIBLE_CELLS:
			break
	return out

# =====================================================================================================
# Input
# =====================================================================================================

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.is_action_pressed("move_up"):
		_move_cursor(-1)
	elif event.is_action_pressed("move_down"):
		_move_cursor(1)
	elif event.is_action_pressed("action"):
		_confirm_current()
	elif event.is_action_pressed("use"):
		_back_current()

func _move_cursor(d: int) -> void:
	var n := _row_count()
	if n <= 0:
		return
	_cursor = (_cursor + d + n) % n
	_refresh()

func _row_count() -> int:
	match _state:
		St.LIST_ATLA: return _carried().size()
		St.PICK_CELL: return _buildable.size()
		St.CONFIRM:   return 2
		_: return 0

func _confirm_current() -> void:
	match _state:
		St.LIST_ATLA:
			if not _carried().is_empty():
				select_atla(_cursor)
		St.PICK_CELL:
			if _cursor < _buildable.size():
				select_cell(_buildable[_cursor])
		St.CONFIRM:
			if _cursor == 0: confirm()
			else: cancel()
		St.PLACED:
			if _carried().is_empty(): _goto(St.DONE)
			else: _goto(St.LIST_ATLA)
		St.DONE:
			close()

func _back_current() -> void:
	match _state:
		St.LIST_ATLA: close()
		St.PICK_CELL: _goto(St.LIST_ATLA)
		St.CONFIRM:   _goto(St.PICK_CELL)
		St.PLACED:    pass
		St.DONE:      close()

# =====================================================================================================
# Public flow API (also drivable by verification probes)
# =====================================================================================================

## Pick the carried-Atla at index `i` and advance to cell selection.
func select_atla(i: int) -> void:
	if i < 0 or i >= _carried().size():
		return
	_sel_atla = i
	_goto(St.PICK_CELL)

## Pick grid cell `cell` and advance to confirmation.
func select_cell(cell: int) -> void:
	_sel_cell = cell
	_goto(St.CONFIRM)

## Commit the placement: grid.place_atla spawns the actor + records it; advance to the result screen.
func confirm() -> Dictionary:
	if _sel_atla < 0 or _sel_cell < 0 or _grid == null:
		return {}
	var carried := _carried()
	if _sel_atla >= carried.size():
		return {}
	var atla: Dictionary = carried[_sel_atla]
	var rec: Dictionary = _grid.place_atla(atla, _sel_cell)
	if rec.is_empty():
		_last_result = "Could not build there."
		_goto(St.PLACED)
		return {}
	var info := _info(int(atla.get("id", 0)))
	var npc := String(info.get("npc", ""))
	# per-NPC dialog deferred -> a generic greeting tagged with the resident name.
	if npc != "":
		_last_result = "%s: \"Thank you for rebuilding my home!\"" % npc
	else:
		_last_result = "%s placed." % String(rec.get("name", "Atla"))
	placed.emit(_sel_cell, int(rec.get("atla_id", 0)), String(rec.get("name", "")))
	_goto(St.PLACED)
	return rec

## Cancel the in-progress placement, back to the Atla list.
func cancel() -> void:
	_goto(St.LIST_ATLA)

func close() -> void:
	var st := _gs()
	if st != null:
		st.rebuild_pending = false
	closed.emit()
	queue_free()

# state inspectors (verification)
func current_state() -> int: return _state
func selected_atla() -> int: return _sel_atla
func selected_cell() -> int: return _sel_cell
func buildable_cells() -> Array: return _buildable.duplicate()
func last_result() -> String: return _last_result

func _gs() -> Node:
	return get_node_or_null("/root/GeoramaState")

func _info(atla_id: int) -> Dictionary:
	var st := _gs()
	return st.part_info(atla_id) if st != null else {"name": "Atla %d" % atla_id, "npc": "Resident"}
