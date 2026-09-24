shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

uniform vec4 glow_color : source_color = vec4(0.32, 0.65, 1.0, 1.0);
uniform float glow_intensity = 1.5;
uniform float strength : hint_range(0.0, 1.0) = 1.0;

float ring(float r, float radius, float width) {
	return 1.0 - smoothstep(width, width + 0.004, abs(r - radius));
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float ticks = pow(max(0.0, cos(a * 24.0)), 24.0);
	float broken = smoothstep(-0.65, -0.3, sin(a * 6.0 + TIME * 0.22));
	float outer = ring(r, 0.88, 0.004) + ring(r, 0.82, 0.003);
	float glyphs = ticks * smoothstep(0.67, 0.69, r) * (1.0 - smoothstep(0.77, 0.79, r));
	float inner = ring(r, 0.62, 0.004) * broken;
	float wave = ring(r, fract(TIME * 0.28), 0.006) * 0.12 * (1.0 - r);
	float pulse = 0.88 + 0.12 * sin(TIME * 3.0);
	float ink = clamp(outer + glyphs + inner + wave, 0.0, 1.0);
	ALBEDO = glow_color.rgb * glow_intensity;
	ALPHA = ink * pulse * strength * glow_color.a;
}
