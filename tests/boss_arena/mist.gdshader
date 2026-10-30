// A layer of the abyss's mist: soft drifting noise, brightest where the moon
// lights it, fading out at the edges of the sheet. Several stacked layers at
// different depths read as a sea of cloud below the rim.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;
uniform vec3 tint : source_color = vec3(0.2, 0.24, 0.32);
uniform float density = 0.55;
uniform float drift = 0.006;
uniform float scale = 0.012;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = wpos.xz * scale;
	float n = texture(noise_tex, p + vec2(TIME * drift, TIME * drift * 0.6)).r * 0.6
			+ texture(noise_tex, p * 2.3 - vec2(TIME * drift * 1.7, 0.0)).r * 0.4;
	float edge = 1.0 - smoothstep(0.35, 0.5, length(UV - 0.5));
	float a = smoothstep(0.35, 0.8, n) * density * edge;
	ALBEDO = tint * (0.8 + 0.4 * n);
	ALPHA = a;
}
