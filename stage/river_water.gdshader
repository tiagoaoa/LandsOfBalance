shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, specular_schlick_ggx;

// Realistic flowing river water: two counter-scrolling normal layers give
// moving ripples, fresnel blends shallow tint into a dark depth colour, low
// roughness catches the moon as a long specular glint, and a gentle vertex
// swell keeps the surface from reading as a static sheet.

uniform sampler2D normal_a;
uniform sampler2D normal_b;
uniform vec2 flow_dir = vec2(0.0, 1.0);
uniform float flow_speed : hint_range(0.0, 1.0) = 0.06;
uniform float ripple_scale : hint_range(0.5, 16.0) = 5.0;
uniform float normal_strength : hint_range(0.0, 2.0) = 0.55;
uniform vec4 shallow_color : source_color = vec4(0.10, 0.18, 0.20, 0.55);
uniform vec4 deep_color : source_color = vec4(0.015, 0.045, 0.07, 0.92);
uniform float water_roughness : hint_range(0.0, 1.0) = 0.08;
uniform float swell_height : hint_range(0.0, 0.2) = 0.035;
// Fake sky reflection: at night the lit sky is what makes water read as
// water instead of a void — always-on shimmer, stronger at grazing angles.
// Calibrated against the night grade (ACES + contrast crush everything
// below ~0.1): peak shimmer must reach ~0.5 to survive the tonemap.
uniform vec4 sky_tint : source_color = vec4(0.14, 0.18, 0.26, 1.0);
uniform float sky_reflect : hint_range(0.0, 4.0) = 2.2;

varying vec2 world_uv;

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_uv = world_pos.xz / ripple_scale;
	// Slow travelling swell along the flow direction.
	float phase = dot(world_pos.xz, flow_dir) * 0.35 + TIME * 0.9;
	VERTEX.y += (sin(phase) + 0.5 * sin(phase * 2.3 + 1.7)) * swell_height;
}

void fragment() {
	vec2 drift = flow_dir * TIME * flow_speed;
	vec3 n1 = texture(normal_a, world_uv + drift).rgb;
	vec3 n2 = texture(normal_b, world_uv * 1.7 - drift * 1.4 + vec2(0.37, 0.11)).rgb;
	vec3 blended = normalize(vec3(
			(n1.xy * 2.0 - 1.0) + (n2.xy * 2.0 - 1.0),
			2.0 / max(normal_strength, 0.001)));
	NORMAL_MAP = blended * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_strength;

	// Fresnel: looking across the water reflects (dark mirror at night),
	// looking straight down shows the shallow tint.
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec4 col = mix(shallow_color, deep_color, clamp(fresnel * 1.4, 0.0, 1.0));
	ALBEDO = col.rgb;
	ALPHA = clamp(col.a + fresnel * 0.25, 0.0, 0.97);
	METALLIC = 0.0;
	ROUGHNESS = water_roughness;
	SPECULAR = 0.6;
	// Ripple-modulated sky shimmer keeps the surface alive from any angle.
	// Use the combined normal DEVIATION for contrast — raw samples hover
	// around 0.5 and modulate nothing.
	vec2 rip = (n1.xy * 2.0 - 1.0) + (n2.xy * 2.0 - 1.0);
	float ripple_lum = clamp(length(rip), 0.0, 1.5);
	// Floor keeps the band reading as water at distance, where the normal
	// detail (and so ripple_lum) averages away.
	EMISSION = sky_tint.rgb * sky_reflect * (0.35 + 0.65 * fresnel) * (0.5 + 0.8 * ripple_lum);
}
