# TintedIV's colour bake, as wsRaceVC's balloons use it (red for the player,
# blue for the two AI clowns). bpTossDartVC keeps its own copy.
#
# From the original binary:
#   -[TintedIV initWithImage:andTintColor:andBlendMode:] 0x46FEC  stores the
#       image, tint and blend mode, puts the image in baseIV, and -- tint
#       non-nil -- calls changeColor: once.
#   -[TintedIV changeColor:] 0x47304  draws, ONCE, into a UIGraphics context
#       the size of the art, with the CTM flipped for Quartz (scale 1,-1 then
#       translate -h) before both the clip and the draw -- so the result is
#       UPRIGHT (this is not MaskedIV's upside-down quirk):
#         clip to the art's mask, fill with the tint colour, restore the clip,
#         CGContextSetBlendMode(bMode), draw the art over the fill;
#       then baseIV.image = the composite.
#   wsRaceVC viewDidLoad (0xAD74) reads baseIV.image straight back out of
#   each TintedIV and releases it, so the port bakes the composite once.
#
# Compositing: the fill clipped to the art's alpha is the backdrop, the art
# the source, source-over with the PDF separable blend term. Only the mode
# this game passes is implemented: 9 = kCGBlendModeHardLight.

extends RefCounted

const MODE_HARD_LIGHT := 9


static func bake(tex: Texture2D, tint: Color, mode: int) -> ImageTexture:
	if tex == null:
		return null
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var s := img.get_pixel(x, y)          # source: the art
			var sa := s.a
			if sa <= 0.0:
				continue
			var da := tint.a * sa                 # the fill, clipped to the art
			var b := Color(
				_blend(tint.r, s.r, mode),
				_blend(tint.g, s.g, mode),
				_blend(tint.b, s.b, mode))
			var ao := sa + da * (1.0 - sa)
			var co := Color(
				sa * (1.0 - da) * s.r + (1.0 - sa) * da * tint.r + sa * da * b.r,
				sa * (1.0 - da) * s.g + (1.0 - sa) * da * tint.g + sa * da * b.g,
				sa * (1.0 - da) * s.b + (1.0 - sa) * da * tint.b + sa * da * b.b)
			if ao > 0.0:
				img.set_pixel(x, y, Color(co.r / ao, co.g / ao, co.b / ao, ao))
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)


## Cb = backdrop (the tint fill), Cs = source (the art).
static func _blend(cb: float, cs: float, mode: int) -> float:
	if mode == MODE_HARD_LIGHT:
		if cs <= 0.5:
			return 2.0 * cs * cb
		return 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb)
	push_error("ws_TintedIV: blend mode %d not ported" % mode)
	return cs
