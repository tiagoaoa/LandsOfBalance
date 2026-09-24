shader_type spatial;
render_mode cull_disabled, diffuse_burley;

uniform sampler2D positions : filter_linear, repeat_disable;
uniform vec3 cloth_color : source_color = vec3(0.29, 0.32, 0.205);

vec3 point(vec2 uv) {
	vec2 size = vec2(textureSize(positions, 0));
	return textureLod(positions, (clamp(uv, vec2(0.0), vec2(1.0)) * (size - 1.0) + .5) / size, 0.0).xyz;
}

void vertex() {
	vec2 step_uv = 1.0 / (vec2(textureSize(positions, 0)) - 1.0);
	VERTEX = point(UV);
	vec3 across = point(UV + vec2(step_uv.x, 0)) - point(UV - vec2(step_uv.x, 0));
	vec3 down = point(UV + vec2(0, step_uv.y)) - point(UV - vec2(0, step_uv.y));
	TANGENT = normalize(across);
	NORMAL = normalize(cross(across, down));
	BINORMAL = normalize(cross(NORMAL, TANGENT));
}

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

void fragment() {
	vec2 thread = UV * vec2(220.0, 310.0);
	vec2 detail = 1.0 - smoothstep(vec2(.2), vec2(.85), fwidth(thread));
	vec2 weave = sin(thread * 6.283185) * detail;
	float dye = noise(UV * vec2(12, 16)) * .13 + noise(UV * 47.0) * .055;
	float edge = min(min(UV.x, 1.0 - UV.x), 1.0 - UV.y);
	float hem = 1.0 - smoothstep(.016, .026, edge);
	float seam = exp(-pow((edge - .012) * 750.0, 2.0));
	float stitch = seam * smoothstep(-.2, .2, sin((UV.x + UV.y) * 1050.0));
	vec3 base = cloth_color * (.92 + dye + .018 * (weave.x + weave.y));
	base *= 1.0 - .22 * hem;
	base += vec3(.09, .075, .045) * stitch;
	ALBEDO = base;
	METALLIC = 0.0;
	ROUGHNESS = .92;
	SPECULAR = .12;
	RIM = .22;
	RIM_TINT = .85;
	NORMAL = normalize(NORMAL * (FRONT_FACING ? 1.0 : -1.0)
		+ TANGENT * weave.x * .075 + BINORMAL * weave.y * .075);
}
