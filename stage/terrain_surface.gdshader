shader_type spatial;
render_mode diffuse_burley;

uniform sampler2D soil_color : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_roughness : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D soil_ao : filter_linear_mipmap, repeat_enable;
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float tile_scale = 0.65;
varying vec3 world_pos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
		mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = world_pos.xz * tile_scale;
	vec2 uv2 = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8)) * uv * 0.37;
	float patch = noise(world_pos.xz * 0.065);
	float fine = noise(world_pos.xz * 0.5);
	vec3 soil = texture(soil_color, uv).rgb;
	vec3 broad = texture(soil_color, uv2).rgb;
	soil = mix(vec3(dot(soil, vec3(0.2126, 0.7152, 0.0722))), soil, 0.35);
	broad = mix(vec3(dot(broad, vec3(0.2126, 0.7152, 0.0722))), broad, 0.35);
	vec3 tint = mix(vec3(0.36, 0.30, 0.23), vec3(0.29, 0.34, 0.23), patch);
	float puddle = wetness * smoothstep(0.56, 0.78, patch + fine * 0.12);
	ALBEDO = mix(soil, broad, 0.32) * tint * mix(1.25, 0.76, wetness);
	ROUGHNESS = mix(clamp(texture(soil_roughness, uv).r, 0.72, 1.0), 0.23, puddle);
	SPECULAR = mix(0.3, 0.55, wetness);
	NORMAL_MAP = texture(soil_normal, uv).rgb;
	NORMAL_MAP_DEPTH = mix(1.1, 0.35, puddle);
	AO = mix(1.0, texture(soil_ao, uv).r, 0.65);
}
