shader_type spatial;
render_mode cull_disabled;

// DC1 town relight — now SHADOW-RECEIVING. It used to be `unshaded`, and unshaded geometry CANNOT receive Godot
// shadows at all — that one flag silently killed every cast shadow when the relight landed. Reworked: the DC1
// ambient comes from the Environment ambient (sky_cycle sets it per-time = the cfg ambient), and the directional
// term is computed in light() so it picks up the sun's real-time shadow (ATTENUATION = 0 inside a shadow). One sun
// (Light0, shadow_enabled), aligned to dc_light_dir by sky_cycle. Look ≈ the old relight + the cast shadow folded in.
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
global uniform vec3 dc_light_dir;   // world-space, normalized, TOWARD the light
global uniform vec3 dc_light_col;
varying vec3 v_wn;

void vertex() {
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	ALBEDO = texture(tex, UV).rgb;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}

void light() {
	float ndl = max(dot(v_wn, dc_light_dir), 0.0);
	DIFFUSE_LIGHT += ALBEDO * dc_light_col * ndl * ATTENUATION;
}
