// Reproduces MaskedIV -- the original's CGContextClipToMask composite.
//
// Two things combine to produce the final alpha:
//
//   coverage  the mask image's shape
//   fill      a moving boundary, for pours and gauges that rise over time
//
// The bundle's masks are not consistently encoded: some are grayscale, some
// RGB, some palette, some RGBA. Core Graphics treats a grayscale image mask as
// "0 paints, max paints nothing", i.e. black shows through -- the inverse of an
// alpha mask. Hence mask_mode rather than a single hardcoded interpretation.

shader_type canvas_item;
render_mode blend_mix;

// 0 = use the mask's alpha channel (RGBA masks)
// 1 = use inverted luminance (Core Graphics image masks: black shows)
uniform int mask_mode : hint_range(0, 1) = 0;

uniform sampler2D mask_tex : filter_linear, source_color;

// MaskedIV's drawRect: hands CGContextClipToMask a raw CGImageMask inside
// UIKit's flipped drawing context and never flips the CTM, so the original
// applies every mask upside down. Screens that reproduce that set this.
uniform bool mask_flip_v = false;

// Visible fraction along fill_dir, 0..1. 1.0 means "no fill boundary".
uniform float fill : hint_range(0.0, 1.0) = 1.0;

// 0 = up (fills from the bottom), 1 = down, 2 = right, 3 = left
uniform int fill_dir : hint_range(0, 3) = 0;

// Softness of the fill boundary in UV units. 0 gives a hard edge, which is
// what the original had; a little softness reads better for liquids.
uniform float fill_feather : hint_range(0.0, 0.2) = 0.0;


float fill_amount(vec2 uv) {
	// Distance past the boundary, positive where the pixel should show.
	float d;
	if (fill_dir == 0) {
		d = uv.y - (1.0 - fill);
	} else if (fill_dir == 1) {
		d = fill - uv.y;
	} else if (fill_dir == 2) {
		d = fill - uv.x;
	} else {
		d = uv.x - (1.0 - fill);
	}
	if (fill_feather <= 0.0) {
		return step(0.0, d);
	}
	return smoothstep(0.0, fill_feather, d);
}


void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec2 muv = mask_flip_v ? vec2(UV.x, 1.0 - UV.y) : UV;
	vec4 m = texture(mask_tex, muv);

	float coverage = (mask_mode == 1)
		? 1.0 - dot(m.rgb, vec3(0.299, 0.587, 0.114))
		: m.a;

	COLOR = vec4(base.rgb, base.a * coverage * fill_amount(UV));
}
