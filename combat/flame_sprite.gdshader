shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;

varying float seed;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}

void vertex() {
	seed = float(INSTANCE_ID) * 1.618;
	mat4 facing = mat4(INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz), MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * facing;
}

void fragment() {
	vec2 flow = UV * vec2(4.0, 5.0) + vec2(seed, TIME * 2.8);
	float curl = noise(flow) * 0.65 + noise(flow * 2.1) * 0.35;
	float sway = (noise(vec2(UV.y * 4.0 + TIME * 1.5, seed)) - 0.5) * 0.5;
	float x = abs(UV.x * 2.0 - 1.0 + sway * (1.0 - UV.y));
	float width = mix(0.03, 0.85, pow(UV.y, 0.7));
	float tongue = 1.0 - smoothstep(width * 0.2, width, x);
	float fade = smoothstep(0.0, 0.2, UV.y) * (1.0 - smoothstep(0.65, 1.0, UV.y));
	float density = smoothstep(0.2, 0.7, curl + tongue * 0.35) * tongue * fade;
	float core = pow(tongue, 3.0) * smoothstep(0.1, 0.8, UV.y);
	vec3 color = mix(vec3(0.8, 0.08, 0.008), vec3(1.0, 0.5, 0.045), density);
	color = mix(color, vec3(1.0, 0.8, 0.3), core * 0.65);
	ALBEDO = color;
	EMISSION = color * (0.8 + core * 0.6);
	ALPHA = density * COLOR.a * 0.78;
}
