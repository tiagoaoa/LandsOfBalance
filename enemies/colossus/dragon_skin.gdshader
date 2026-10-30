// The dragon's hide: tiling scales on skeleton-following UVs, multiplied by
// the baked colour zones + AO (vertex colour); rain-wet sheen on the upper
// surfaces; and fire showing through the SEAMS between scales where the
// masks say, packed in UV2: x > 0 chest (the core), y > 0 throat (the
// breath's tell), x < 0 left wrist, y < 0 right wrist (a pinned fist).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
// the same texture read raw (sRGB values): the seam test thresholds in it
uniform sampler2D seam_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform bool has_rough = false;
uniform float rough_base = 0.6;
uniform float normal_depth = 1.25;
uniform float wet = 0.55;            // rain on the scales
uniform vec3 fire_color : source_color = vec3(1.0, 0.38, 0.07);
uniform float core_glow = 0.6;
uniform float throat_glow = 0.0;
uniform float ember_l = 0.4;
uniform float ember_r = 0.4;
uniform float rim_amount = 0.35;
uniform float albedo_boost = 1.5;     // black, but not a hole in the night

varying vec3 up_n;

void vertex() {
	up_n = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

void fragment() {
	vec3 a = texture(albedo_tex, UV).rgb;
	ALBEDO = a * COLOR.rgb * albedo_boost;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_depth;
	float r = has_rough ? texture(rough_tex, UV).r : rough_base;
	// Water beads on what faces the sky: glossier, a touch darker.
	float sky = clamp(normalize(up_n).y, 0.0, 1.0);
	float w = wet * smoothstep(0.1, 0.7, sky);
	ROUGHNESS = mix(r, 0.18, w);
	ALBEDO *= 1.0 - 0.25 * w;
	SPECULAR = 0.5 + 0.2 * w;
	RIM = rim_amount;
	RIM_TINT = 0.65;
	// Seams = the dark crevices of the scale texture.
	float lum = dot(texture(seam_tex, UV).rgb, vec3(0.3, 0.55, 0.15));
	float seam = 1.0 - smoothstep(0.025, 0.07, lum);
	float k = max(UV2.x, 0.0) * core_glow + max(UV2.y, 0.0) * throat_glow
			+ max(-UV2.x, 0.0) * ember_l + max(-UV2.y, 0.0) * ember_r;
	// A little light bleeds through the scales themselves, most through the seams.
	EMISSION = fire_color * k * (seam * 1.0 + 0.08);
}
