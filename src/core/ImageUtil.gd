# Small image helpers.
#
# average_color ports -[msScoopViewController getAverageUIColorFromUIImage:]
# (0x43128), which the original used to derive a tint from the chosen swatch
# rather than hardcoding a colour per flavour. That is why so much of the art
# is authored greyscale.
#
# It is NOT a sampling loop -- the port's previous implementation was invented.
# The original draws the whole image into a 1x1 CGBitmapContext and reads the
# single resulting pixel back:
#
#   CGBitmapContextCreate(w:1, h:1, bpc:8, bpr:4, bitmapInfo: 5)
#
# bitmapInfo 5 is kCGImageAlphaNoneSkipLast over a zero-initialised buffer, so
# there is no destination alpha and transparent source pixels composite against
# black. Every pixel counts, and transparency drags the mean down. Then:
#
#   scale = (1 - min(r,g,b)) / max(r,g,b)
#   out   = (r,g,b) * scale, alpha 1
#
# That normalise step -- which pins the largest channel to (1 - min) and so
# brightens and saturates the result -- is the half the port was missing.

# Not `class_name`: the global class registry is editor-built and this
# project is CLI-driven. Preload this file by path instead.
extends RefCounted

static var _cache: Dictionary = {}


## The tint the original derived from a swatch. Cached by resource path; the
## full-image walk runs once per texture.
static func average_color(tex: Texture2D) -> Color:
	if tex == null:
		return Color.WHITE
	var key := tex.resource_path
	if key != "" and _cache.has(key):
		return _cache[key]

	var img := tex.get_image()
	if img == null:
		return Color.WHITE
	if img.is_compressed():
		img.decompress()

	var w := img.get_width()
	var h := img.get_height()
	if w == 0 or h == 0:
		return Color.WHITE

	# Premultiplied mean over *every* pixel, matching CG's downscale into an
	# alpha-less black context.
	var r := 0.0
	var g := 0.0
	var b := 0.0
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			r += c.r * c.a
			g += c.g * c.a
			b += c.b * c.a
	var n := float(w * h)

	var out := normalise(Color(r / n, g / n, b / n))
	if key != "":
		_cache[key] = out
	return out


## The (1 - min) / max boost from the tail of 0x43128.
##
## Divergence: an all-black input divides by zero in the original and produces
## a NaN UIColor. What CG renders for that was never verified, so the port
## returns black rather than letting a NaN escape into the tint chain.
static func normalise(c: Color) -> Color:
	var hi := maxf(c.r, maxf(c.g, c.b))
	var lo := minf(c.r, minf(c.g, c.b))
	if hi <= 0.0:
		return Color.BLACK
	var scale := (1.0 - lo) / hi
	return Color(c.r * scale, c.g * scale, c.b * scale, 1.0)
