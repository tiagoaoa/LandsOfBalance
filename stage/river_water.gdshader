shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, specular_schlick_ggx;

uniform sampler2D normal_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float flow_speed = .32;
uniform vec3 shallow_color : source_color = vec3(.13, .26, .22);
uniform vec3 deep_color : source_color = vec3(.025, .11, .13);
uniform vec3 foam_color : source_color = vec3(.65, .75, .69);

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	vec4 n = fract(sin(vec4(dot(i, vec2(127.1, 311.7)),
		dot(i + vec2(1, 0), vec2(127.1, 311.7)),
		dot(i + vec2(0, 1), vec2(127.1, 311.7)),
		dot(i + vec2(1, 1), vec2(127.1, 311.7)))) * 43758.5453);
	return mix(mix(n.x, n.y, f.x), mix(n.z, n.w, f.x), f.y);
}

void vertex() {
	float shore = smoothstep(0.0, .22, min(COLOR.r, 1.0 - COLOR.r));
	float phase = UV.y * 3.1 - TIME * 1.8;
	VERTEX.y += (sin(phase) + .4 * sin(phase * 1.7 + UV.x * 2.0)) * .024 * shore;
}

void fragment() {
	//Both scales travel downstream in the channel's UVs, including around bends.
	vec2 uv = UV - vec2(0, TIME * flow_speed);
	vec3 n1 = texture(normal_a, uv * vec2(1.5, .65)).rgb * 2.0 - 1.0;
	vec3 n2 = texture(normal_b, uv * vec2(3.1, 1.4) + vec2(.31, TIME * .045)).rgb * 2.0 - 1.0;
	NORMAL_MAP = normalize(vec3((n1.xy + n2.xy * .55) * .65, 1.5)) * .5 + .5;
	NORMAL_MAP_DEPTH = .7;
	float depth = COLOR.g;
	float edge = min(COLOR.r, 1.0 - COLOR.r);
	float filaments = noise(uv * vec2(24.0, 3.0) + n1.xy * .4);
	float breakup = noise(uv * vec2(9.0, 6.0));
	float bank_foam = (1.0 - smoothstep(.015, .095, edge)) * smoothstep(.35, .7, breakup);
	float streaks = smoothstep(.70, .86, filaments) * smoothstep(.5, .7, breakup) * .48;
	float foam = clamp(bank_foam * .85 + streaks, 0.0, .9);
	ALBEDO = mix(mix(shallow_color, deep_color, depth), foam_color, foam);
	ROUGHNESS = mix(.13, .68, foam);
	SPECULAR = .65;
	METALLIC = 0.0;
	ALPHA = mix(.48, .86, depth) + foam * .12;
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	//Distant sky fill keeps the ripples readable under the night exposure.
	EMISSION = vec3(.06, .11, .16) * (.1 + .6 * fresnel) * (1.0 - foam);
	NORMAL = normalize(NORMAL * (FRONT_FACING ? 1.0 : -1.0));
}
