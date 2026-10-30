shader_type fog;

void fog() {
	vec3 p = WORLD_POSITION * 0.18;
	float drift = sin(p.x + TIME * 0.12 + sin(p.z * 1.3));
	drift *= cos(p.z * 0.8 - TIME * 0.08 + p.y);
	float edge = pow(clamp(-SDF / 5.0, 0.0, 1.0), 1.5);
	float upper = 1.0 - smoothstep(0.55, 0.95, UVW.y);
	DENSITY = edge * upper * (0.13 + drift * 0.045);
	ALBEDO = vec3(0.34, 0.39, 0.41);
	EMISSION = vec3(0.009, 0.012, 0.014);
}
