shader_type canvas_item;

// Procedural aged-wood frame for HUD panels.
// Generates domain-warped grain rings + an edge bevel so panels read as
// carved, dimensional planks instead of flat colour blocks.
//
// `panel_size` must be set to the owning Control's current size in pixels
// (updated on resize). Without it, the bevel/carve sizes would scale with
// the panel instead of staying 1-px accurate.

uniform vec4 wood_light : source_color = vec4(0.42, 0.26, 0.12, 1.0);
uniform vec4 wood_dark : source_color = vec4(0.15, 0.08, 0.04, 1.0);
uniform vec4 rim_color : source_color = vec4(0.55, 0.42, 0.18, 1.0);
uniform float grain_scale = 0.22;
uniform float grain_warp = 1.6;
uniform float bevel_size = 6.0;    // pixels — outer rim shading falloff
uniform float carve_offset = 5.0;  // pixels — inner carved-line distance
uniform float carve_width = 1.2;   // pixels
uniform vec2 panel_size = vec2(200.0, 64.0);


// Cheap 2D value noise
float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float noise2d(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// Fractal noise for richer grain
float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.55;
	for (int i = 0; i < 4; i++) {
		v += amp * noise2d(p);
		p *= 2.13;
		amp *= 0.5;
	}
	return v;
}

// Wood grain: domain-warped rings stretched along the long axis of the
// plank (X in UV space), darkened where rings crowd.
float wood_grain(vec2 p) {
	float warp_x = (fbm(p * 0.6) - 0.5) * grain_warp;
	float warp_y = (fbm(p.yx * 0.6 + 12.3) - 0.5) * (grain_warp * 0.3);
	// Stretch rings along X — wood grows lengthwise
	vec2 sp = vec2(p.x * 0.18, p.y + warp_x + warp_y * 0.4);
	float rings = fract(sp.y * 0.55);
	float ring_edge = pow(abs(rings - 0.5) * 2.0, 1.8);
	// Extra knots from fbm
	float knot = smoothstep(0.75, 0.92, fbm(p * 0.35 + 7.1));
	return clamp(ring_edge + knot * 0.6, 0.0, 1.0);
}


void fragment() {
	vec2 px = UV * panel_size;
	vec2 from_edge_xy = min(px, panel_size - px);
	float from_edge = min(from_edge_xy.x, from_edge_xy.y);

	// Outer bevel: pure rim colour within `bevel_size` pixels of the edge,
	// blending into the wood interior beyond.
	float bevel_t = smoothstep(0.0, bevel_size, from_edge);

	// Top highlight / bottom shadow to fake a real plane tilt.
	float vert = UV.y;
	float top_light = (1.0 - vert) * 0.15;
	float bot_shadow = vert * 0.2;

	// Wood interior
	float g = wood_grain(px * grain_scale);
	vec3 wood = mix(wood_dark.rgb, wood_light.rgb, 1.0 - g);
	wood *= mix(0.6, 1.05, bevel_t);
	wood += vec3(top_light);
	wood -= vec3(bot_shadow);

	// Carved inner border — a thin dark line parallel to the outer edge,
	// gives the panel the "picture-frame" look.
	float carve = smoothstep(carve_width, 0.0, abs(from_edge - (bevel_size + carve_offset)));
	// Only show carve a bit inside the bevel.
	float carve_mask = step(bevel_size, from_edge);
	wood -= vec3(carve * carve_mask * 0.32);

	// Final composition: rim colour at edge, wood inside.
	vec3 final_rgb = mix(rim_color.rgb, wood, bevel_t);

	COLOR = vec4(final_rgb, 1.0);
}
