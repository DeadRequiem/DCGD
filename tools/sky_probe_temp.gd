# Headless probe: load e01.tscn, dump sky/fog/env values for slots 0, 1, 3, 6 (morning, noon, dusk, night)
extends SceneTree

func _initialize() -> void:
	var e01 = load("res://scenes/levels/e01.tscn")
	if e01 == null:
		print("ERROR: e01.tscn not found")
		quit()
	
	var root = e01.instantiate()
	if root == null:
		print("ERROR: e01.tscn failed to instantiate")
		quit()
	
	add_child(root)
	await get_tree().process_frame
	
	var we = root.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null:
		print("ERROR: WorldEnvironment not found")
		quit()
	
	var env = we.environment
	var sky_mat = null
	if env.sky != null:
		sky_mat = env.sky.sky_material as ProceduralSkyMaterial
	
	var sky_cycle = root.get_node_or_null("SkyCycle")
	if sky_cycle == null:
		print("ERROR: SkyCycle not found")
		quit()
	
	# Read the time_table to see what slots are
	var tt_path = "res://assets/maps/gedit/e01/e01.time_table.json"
	var slots = []
	if FileAccess.file_exists(tt_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(tt_path))
		if parsed is Dictionary:
			slots = parsed.get("slots", [])
	
	print("\n=== DC1 SKY PROBE: e01 MORNING/NOON/DUSK/NIGHT ===\n")
	
	# Manually set each phase to probe the interpolated values
	var phases = [0, 1, 3, 6]  # morning, noon, dusk, night
	for phase_idx in phases:
		print("--- PHASE %d (slot %d) ---" % [phase_idx, phase_idx])
		
		# Call sky_cycle's _apply directly
		sky_cycle._apply(float(phase_idx))
		
		if env != null:
			print("  background_mode: %d (0=COLOR, 2=SKY)" % env.background_mode)
			print("  background_color: RGB(%d,%d,%d) / (%.3f,%.3f,%.3f)" % [
				int(env.background_color.r * 255),
				int(env.background_color.g * 255),
				int(env.background_color.b * 255),
				env.background_color.r,
				env.background_color.g,
				env.background_color.b
			])
			print("  ambient_light_color: RGB(%d,%d,%d)" % [
				int(env.ambient_light_color.r * 255),
				int(env.ambient_light_color.g * 255),
				int(env.ambient_light_color.b * 255)
			])
			print("  fog_enabled: %s" % env.fog_enabled)
			print("  fog_mode: %d" % env.fog_mode)
			print("  fog_depth_begin: %.1f" % env.fog_depth_begin)
			print("  fog_depth_end: %.1f" % env.fog_depth_end)
			print("  fog_light_color: RGB(%d,%d,%d) / (%.3f,%.3f,%.3f)" % [
				int(env.fog_light_color.r * 255),
				int(env.fog_light_color.g * 255),
				int(env.fog_light_color.b * 255),
				env.fog_light_color.r,
				env.fog_light_color.g,
				env.fog_light_color.b
			])
		
		if sky_mat != null:
			print("  sky_top_color: RGB(%d,%d,%d) / (%.3f,%.3f,%.3f)" % [
				int(sky_mat.sky_top_color.r * 255),
				int(sky_mat.sky_top_color.g * 255),
				int(sky_mat.sky_top_color.b * 255),
				sky_mat.sky_top_color.r,
				sky_mat.sky_top_color.g,
				sky_mat.sky_top_color.b
			])
			print("  sky_horizon_color: RGB(%d,%d,%d) / (%.3f,%.3f,%.3f)" % [
				int(sky_mat.sky_horizon_color.r * 255),
				int(sky_mat.sky_horizon_color.g * 255),
				int(sky_mat.sky_horizon_color.b * 255),
				sky_mat.sky_horizon_color.r,
				sky_mat.sky_horizon_color.g,
				sky_mat.sky_horizon_color.b
			])
			print("  ground_horizon_color: RGB(%d,%d,%d) / (%.3f,%.3f,%.3f)" % [
				int(sky_mat.ground_horizon_color.r * 255),
				int(sky_mat.ground_horizon_color.g * 255),
				int(sky_mat.ground_horizon_color.b * 255),
				sky_mat.ground_horizon_color.r,
				sky_mat.ground_horizon_color.g,
				sky_mat.ground_horizon_color.b
			])
			print("  ground_bottom_color: RGB(%d,%d,%d) / (%.3f,%.3f,%.3f)" % [
				int(sky_mat.ground_bottom_color.r * 255),
				int(sky_mat.ground_bottom_color.g * 255),
				int(sky_mat.ground_bottom_color.b * 255),
				sky_mat.ground_bottom_color.r,
				sky_mat.ground_bottom_color.g,
				sky_mat.ground_bottom_color.b
			])
		
		# Also show the raw slot data for comparison
		if phase_idx < slots.size():
			var slot = slots[phase_idx]
			print("  [RAW SLOT DATA]")
			print("    bgColor: %s" % slot.get("bgColor", "N/A"))
			print("    bgColor2: %s" % slot.get("bgColor2", "N/A"))
			print("    fog: %s" % slot.get("fog", "N/A"))
		
		print()
	
	quit()
