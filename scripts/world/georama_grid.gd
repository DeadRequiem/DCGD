extends Node3D

@export_file("*.json") var grid_path: String = ""
@export var debug_draw: bool = true

var cells: Array = []   ## [{ i:int, type:int, flag:int, pos:Vector3 }]

func _ready() -> void:
	if grid_path == "" or not FileAccess.file_exists(grid_path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(grid_path))
	if not (data is Dictionary and data.has("cells")):
		return
	for c in data["cells"]:
		var p: Array = c["pos"]
		cells.append({"i": int(c["i"]), "type": int(c["type"]), "flag": int(c["flag"]),
			"pos": Vector3(p[0], p[1], p[2])})
	if debug_draw:
		_draw_cells()

func _draw_cells() -> void:
	for cell in cells:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(90, 4, 90)
		mi.mesh = bm
		mi.position = cell["pos"] + Vector3(0, 1, 0)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color.from_hsv(float(cell["type"] % 16) / 16.0, 0.65, 0.95, 0.4)
		mi.material_override = mat
		add_child(mi)

## Cell record by index — placement targets for step B.
func cell_at(i: int) -> Dictionary:
	return cells[i] if i >= 0 and i < cells.size() else {}
