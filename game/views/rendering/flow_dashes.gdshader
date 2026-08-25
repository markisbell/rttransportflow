// Animated power-flow dashes over the strategic ribbon layer (C2).
// GPU-time animation only (the streamer owns the CPU frame budget): the
// dash phase runs on TIME; per-line values arrive via a 1×N float
// texture (UV2.x = the line's texel column, UV.x = accumulated distance
// along the tile path in tiles, UV.y = 0..1 across the ribbon).
// flow_tex.r = signed dash speed [tiles/s] (positive = from_bus→to_bus,
// the path order the topology walk records); flow_tex.g = intensity.
// Owner review: three layers in one surface — a dark BACKING band (the
// "backlight" separating dashes from pale terrain), a warm HALO, and a
// bright CORE; power keeps shining at night (gentle day dim, unlike the
// base ribbons' full dim).
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, fog_disabled,
	shadows_disabled, specular_disabled;

uniform sampler2D flow_tex : filter_nearest;
uniform float day_level = 1.0;
uniform float dash_density = 1.4;

varying float v_line;

void vertex() {
	v_line = UV2.x;
}

void fragment() {
	vec4 flow = texelFetch(flow_tex, ivec2(int(v_line + 0.5), 0), 0);
	float speed = flow.r;
	float intensity = clamp(flow.g, 0.0, 1.0);
	float u = UV.x;
	float cross_d = abs(UV.y - 0.5) * 2.0; // 0 centerline -> 1 ribbon edge
	float phase = fract(u * dash_density - TIME * speed * dash_density);
	float dash = smoothstep(0.24, 0.40, phase) * (1.0 - smoothstep(0.60, 0.76, phase));
	float core = 1.0 - smoothstep(0.00, 0.34, cross_d);
	float halo = 1.0 - smoothstep(0.10, 0.95, cross_d);
	float backing = 1.0 - smoothstep(0.55, 1.00, cross_d);
	float shine = mix(0.75, 1.0, day_level);
	vec3 core_col = vec3(1.0, 0.97, 0.82) * shine;
	vec3 halo_col = mix(vec3(1.0, 0.62, 0.18), vec3(1.0, 0.9, 0.55), intensity) * shine;
	vec3 backing_col = vec3(0.02, 0.03, 0.06);
	float dash_a = dash * intensity * max(core, halo * 0.55);
	float backing_a = backing * 0.42 * step(0.001, intensity);
	ALBEDO = mix(backing_col, mix(halo_col, core_col, core), clamp(dash_a * 2.2, 0.0, 1.0));
	ALPHA = clamp(max(dash_a * 1.25, backing_a), 0.0, 0.96);
}
