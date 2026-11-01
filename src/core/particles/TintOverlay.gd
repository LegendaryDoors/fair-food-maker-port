# The TintedIV bake SSEmitter uses for tinted particles: blend mode 3.
#
# -[SSEmitter emit] (0xB2D54), when `tint` is non-nil, builds each particle as
#   [[[TintedIV alloc] initWithImage:[UIImage imageNamed:name]
#                       andTintColor:tint andBlendMode:3] autorelease].baseIV
# and initWithImage:andTintColor:andBlendMode: (0x46FEC) runs changeColor:
# (0x47304) once. changeColor: renders into UIGraphicsBeginImageContext(size)
# with the CTM flipped back (scale 1,-1 + translate 0,-h -- so the result is
# upright, unlike the MaskedIV quirk), then:
#   CGContextClipToMask(art)          coverage = the art's alpha
#   [tint set]; CGContextFillRect     the tint, its own alpha included
#   CGContextRestoreGState            (drops the clip)
#   CGContextSetBlendMode(3)          kCGBlendModeOverlay
#   CGContextDrawImage(art)           the art over the fill
# The baked image replaces baseIV's image; baseIV keeps the art's size.
#
# The formula is the PDF separable-blend composite (backdrop = the clipped
# fill, source = the art). screens/ccSugarTint.gd ports the same call for the
# cotton candy screens; this is a self-contained copy so the particle
# component does not depend on a screen file. The two must agree; a
# development test checks the formula on fixed pixels.

extends RefCounted


## kCGBlendModeOverlay: HardLight with the operands swapped -- multiply or
## screen by the BACKDROP. cb = backdrop (tint fill), cs = source (art).
static func overlay(cb: float, cs: float) -> float:
	if cb <= 0.5:
		return 2.0 * cb * cs
	return 1.0 - 2.0 * (1.0 - cb) * (1.0 - cs)


## One straight-alpha art pixel under `tint`. Returns straight alpha.
static func composite(px: Color, tint: Color) -> Color:
	var sa := px.a
	if sa <= 0.0:
		return Color(0, 0, 0, 0)
	var da := tint.a * sa                 # the fill, clipped to the art
	var ao := sa + da * (1.0 - sa)
	var o := Color(0, 0, 0, ao)
	for ch in 3:
		var s: float = px[ch]
		var t: float = tint[ch]
		o[ch] = (sa * (1.0 - da) * s + (1.0 - sa) * da * t
			+ sa * da * overlay(t, s)) / ao
	return o


## changeColor: with mode 3 on an Image. A tint with alpha 0 fills nothing
## and returns the art unchanged.
static func bake_image(src: Image, tint: Color) -> Image:
	var img: Image = src.duplicate()
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if tint.a <= 0.0:
		return img
	var data := img.get_data()
	var n := data.size()
	var i := 0
	while i < n:
		var a8 := data[i + 3]
		if a8 != 0:
			var c := composite(Color8(data[i], data[i + 1], data[i + 2], a8), tint)
			data[i] = clampi(int(round(c.r * 255.0)), 0, 255)
			data[i + 1] = clampi(int(round(c.g * 255.0)), 0, 255)
			data[i + 2] = clampi(int(round(c.b * 255.0)), 0, 255)
			data[i + 3] = clampi(int(round(c.a * 255.0)), 0, 255)
		i += 4
	return Image.create_from_data(img.get_width(), img.get_height(), false,
		Image.FORMAT_RGBA8, data)


static var _cache := {}


## The baked texture, cached per (art, tint): changeColor: is deterministic,
## so re-running it per particle (as the original does) gives the same pixels.
static func bake(tex: Texture2D, tint: Color) -> Texture2D:
	if tex == null:
		return null
	var key := "%s|%f,%f,%f,%f" % [tex.resource_path if tex.resource_path != "" \
		else str(tex.get_instance_id()), tint.r, tint.g, tint.b, tint.a]
	if _cache.has(key):
		return _cache[key]
	var img := tex.get_image()
	if img == null:
		return tex
	var out := ImageTexture.create_from_image(bake_image(img, tint))
	_cache[key] = out
	return out
