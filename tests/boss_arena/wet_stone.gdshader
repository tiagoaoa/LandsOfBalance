// Rain-soaked stone: a scanned PBR set mapped in world space on all three
// axes (no UVs needed on CSG), darkened and glossed by the rain, with
// standing puddles on whatever faces the sky that mirror fire and moonlight.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_tex : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float tile_m = 2.0;           // the scan's real-world size
uniform vec3 tint : source_color = vec3(1.0);
uniform float wetness = 0.65;
uniform float puddles = 0.5;
uniform float normal_strength = 1.0;
uniform float saturation = 0.24;      // the scans run warm; night stone is grey

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1)), f.x), f.y);
}

vec3 tn(vec2 uv) {
	vec3 n = texture(normal_tex, uv).rgb * 2.0 - 1.0;
	n.xy *= normal_strength;
	return n;
}

void fragment() {
	vec3 w = pow(abs(wnrm), vec3(6.0));
	w /= (w.x + w.y + w.z);
	w *= step(vec3(0.001), w);
	w /= (w.x + w.y + w.z);
	vec2 ux = wpos.zy / tile_m, uy = wpos.xz / tile_m, uz = wpos.xy / tile_m;
	vec3 alb = vec3(0.0);
	float rough = 0.0;
	float ao = 0.0;
	vec3 nx = vec3(0.0), ny = vec3(0.0), nz = vec3(0.0);
	//Floors and wall faces usually need one projection. Coherent branches
	//avoid eight unused texture reads per pixel on those broad surfaces.
	if (w.x > 0.0) {
		alb += texture(albedo_tex, ux).rgb * w.x;
		rough += texture(rough_tex, ux).r * w.x;
		ao += texture(ao_tex, ux).r * w.x;
		nx = tn(ux);
	}
	if (w.y > 0.0) {
		alb += texture(albedo_tex, uy).rgb * w.y;
		rough += texture(rough_tex, uy).r * w.y;
		ao += texture(ao_tex, uy).r * w.y;
		ny = tn(uy);
	}
	if (w.z > 0.0) {
		alb += texture(albedo_tex, uz).rgb * w.z;
		rough += texture(rough_tex, uz).r * w.z;
		ao += texture(ao_tex, uz).r * w.z;
		nz = tn(uz);
	}
	// Whiteout-blended triplanar normals, back into world space.
	vec3 s = sign(wnrm);
	vec3 wn = normalize(
		vec3(0.0, nx.y, nx.x * s.x) * w.x + vec3(nx.z * s.x, 0.0, 0.0) * w.x +
		vec3(ny.x, 0.0, ny.y) * w.y + vec3(0.0, ny.z * s.y, 0.0) * w.y +
		vec3(nz.x, nz.y, 0.0) * w.z + vec3(0.0, 0.0, nz.z * s.z) * w.z);
	// Water sits in the low spots of what faces the sky.
	float up = smoothstep(0.6, 0.95, wnrm.y);
	float n = vnoise(wpos.xz * 0.16) * 0.65 + vnoise(wpos.xz * 0.6) * 0.35;
	float pud = smoothstep(0.62 - puddles * 0.25, 0.7 - puddles * 0.25, n + (1.0 - ao) * 0.22) * up * min(puddles * 2.0, 1.0);
	float wet = clamp(wetness * (0.55 + 0.45 * up) + pud, 0.0, 1.0);
	alb = mix(vec3(dot(alb, vec3(0.3, 0.59, 0.11))), alb, saturation);
	float weather = vnoise(wpos.xz * 0.31 + wpos.yy * 0.14);
	ALBEDO = alb * tint * mix(0.72, 1.08, weather) * mix(1.0, 0.7, wet) * mix(1.0, 0.85, pud);
	ROUGHNESS = mix(mix(rough, max(rough * 0.62, 0.3), wet), 0.14, pud);
	SPECULAR = mix(0.5, 0.75, wet);
	// Puddles are flat mirrors: the stone's bumps drown under them.
	wn = normalize(mix(wn, wnrm, pud * 0.9));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	AO = ao;
	AO_LIGHT_AFFECT = 0.4;
}
