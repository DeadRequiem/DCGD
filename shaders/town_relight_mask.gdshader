shader_type spatial;
render_mode cull_disabled;

// DC1 town relight, alpha-cutout variant (foliage/window MASK + the few BLEND props). Same SHADOW-RECEIVING
// lighting as town_relight; keeps the texture's binary cutout via alpha-scissor.
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
global uniform vec3 dc_light_dir;
global uniform vec3 dc_light_col;
varying vec3 v_wn;

void vertex() {
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec4 t = texture(tex, UV);
	ALBEDO = t.rgb;
	ALPHA = t.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	METALLIC = 0.0;
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}

void light() {
	float ndl = max(dot(v_wn, dc_light_dir), 0.0);
	DIFFUSE_LIGHT += ALBEDO * dc_light_col * ndl * ATTENUATION;
}
