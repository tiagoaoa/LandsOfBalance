// Wing membrane: thin leather. Light bleeds through it red when the moon or
// a fire is behind it (backlight); it ripples in the wind, most in the middle
// of each panel, never at the bones it is stretched between.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 back_color : source_color = vec3(0.9, 0.22, 0.08);
uniform float flutter = 0.07;
uniform float wet = 0.4;

void vertex() {
	// UV.y runs from the bone edge across the panel (3-4 units per panel).
	float mid = sin(3.14159 * clamp(fract(UV.y / 3.5), 0.0, 1.0));
	float wave = sin(TIME * 2.1 + UV.x * 2.7 + UV.y * 1.3) * 0.7
			+ sin(TIME * 3.7 + UV.x * 5.1) * 0.3;
	VERTEX += NORMAL * wave * flutter * mid;
}

void fragment() {
	ALBEDO = texture(albedo_tex, UV).rgb * 1.8;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = 0.45;
	ROUGHNESS = mix(0.62, 0.3, wet);
	SPECULAR = 0.45;
	BACKLIGHT = back_color;
	RIM = 0.45;
	RIM_TINT = 0.5;
}
