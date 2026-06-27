extends SceneTree

func _initialize() -> void:
	print("TEST: Script loaded")
	print("Current dir: %s" % OS.get_executable_path())
	quit()
