# Cotton candy's TintedIV colour bake, blend mode 3 (kCGBlendModeOverlay).
#
# Shared by ccSugarPickerViewController and ccMachineViewController. Every
# coloured thing on the two cotton candy screens is a TintedIV built with
# blend mode 3:
#
#   ccSugarPicker  picker icons    cc_sugar_icon.png   initializeSugarPicker 0x81220
#                  canister sugar  sugar_tileable.png  addSugar:color:       0x83ABC
#                  falling streams sugar_fall_0N.png   -[ccSugarFall initWithFlavor:] 0x84D30
#   ccMachine      tub wisps       cc_inner/center/outer_0N  addCottonCandyParticle:... 0x7D948
#                  candy on stick  cc_comp01..04       viewDidLoad 0x7E000 / getNewAlpha 0x7CCF4
#                  the Make bake   cc_comp01..04       nextClick: 0x7EFA8
#
# -[TintedIV changeColor:] (0x47304) renders once into a context the size of
# the art (CTM flipped back, so nothing is mirrored): it clips to the art,
# fills with the tint colour -- the tint's own alpha included, and most sugar
# flavours carry alpha 100/255 -- restores the clip, sets the blend mode and
# draws the art over that fill. The result is the TintedIV's image.
#
# The port used to draw these as a plain modulate (art x tint, alpha x tint
# alpha), which is wrong for every unsupported blend mode: modulate
# multiplies, and at alpha 100/255 it also left the sugar 61% transparent
# where the original's art stays opaque and only takes a 39% overlay tint.
# This bakes the real composite.
#
# kcPourOilViewController.bake_tint is the same port of 0x47304 for modes
# 5/7/8/9 but has no mode 3; the formula here is identical (PDF separable
# blend, source-over with the blend term). Mode 3 could be folded into that
# helper later.
#
# Clip coverage is the art's alpha, the same assumption bake_tint makes.
#
# The common case -- an opaque art pixel -- reduces to a per-channel affine
# map of the art value, so it runs through a 256-entry lookup table; only
# antialiased edge pixels take the full formula. That keeps the 320x320
# candy layers cheap enough to bake mid-drag.

extends RefCounted


## Overlay is HardLight with the operands swapped: it multiplies or screens
## by the BACKDROP (the tint fill). cb = backdrop, cs = source (the art).
static func overlay(cb: float, cs: float) -> float:
	if cb <= 0.5:
		return 2.0 * cb * cs
	return 1.0 - 2.0 * (1.0 - cb) * (1.0 - cs)


## The composite for one straight-alpha art pixel (r, g, b, a) under tint.
## Returns straight alpha, like the art.
static func composite(px: Color, tint: Color) -> Color:
	var sa := px.a
	if sa <= 0.0:
		return Color(0, 0, 0, 0)
	var da := tint.a * sa                  # the fill, clipped to the art
	var ao := sa + da * (1.0 - sa)
	var r := sa * (1.0 - da) * px.r + (1.0 - sa) * da * tint.r \
		+ sa * da * overlay(tint.r, px.r)
	var g := sa * (1.0 - da) * px.g + (1.0 - sa) * da * tint.g \
		+ sa * da * overlay(tint.g, px.g)
	var b := sa * (1.0 - da) * px.b + (1.0 - sa) * da * tint.b \
		+ sa * da * overlay(tint.b, px.b)
	return Color(r / ao, g / ao, b / ao, ao)


## changeColor: with blend mode 3, on an Image. Returns a new RGBA8 Image of
## the same size. A tint with alpha 0 (clearColor -- what the candy layers
## start with) fills nothing, so the art comes back unchanged.
static func overlay_image(src: Image, tint: Color) -> Image:
	if src == null:
		return null
	var img: Image = src.duplicate()
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if tint.a <= 0.0:
		return img
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()

	# Opaque pixels: sa = 1, da = ta, so out = s * (1 - ta) + ta * B(t, s).
	var luts: Array[PackedByteArray] = []
	var tc := [tint.r, tint.g, tint.b]
	for ch in 3:
		var lut := PackedByteArray()
		lut.resize(256)
		var t: float = tc[ch]
		for v in 256:
			var s := float(v) / 255.0
			var o := s * (1.0 - tint.a) + tint.a * overlay(t, s)
			lut[v] = clampi(int(round(o * 255.0)), 0, 255)
		luts.append(lut)
	var lr: PackedByteArray = luts[0]
	var lg: PackedByteArray = luts[1]
	var lb: PackedByteArray = luts[2]

	var n := data.size()
	var i := 0
	while i < n:
		var a8 := data[i + 3]
		if a8 == 255:
			data[i] = lr[data[i]]
			data[i + 1] = lg[data[i + 1]]
			data[i + 2] = lb[data[i + 2]]
		elif a8 != 0:
			var c := composite(Color8(data[i], data[i + 1], data[i + 2], a8), tint)
			data[i] = clampi(int(round(c.r * 255.0)), 0, 255)
			data[i + 1] = clampi(int(round(c.g * 255.0)), 0, 255)
			data[i + 2] = clampi(int(round(c.b * 255.0)), 0, 255)
			data[i + 3] = clampi(int(round(c.a * 255.0)), 0, 255)
		i += 4
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)


## The same, from and to a texture. `cache` (optional) is keyed by the art's
## resource path and the tint, so a colour baked once is reused -- the
## original re-runs changeColor: per view, which gives identical pixels.
static func overlay_texture(tex: Texture2D, tint: Color,
		cache: Variant = null) -> Texture2D:
	if tex == null:
		return null
	var key := "%s|%f,%f,%f,%f" % [tex.resource_path, tint.r, tint.g, tint.b, tint.a]
	if cache is Dictionary and tex.resource_path != "" \
			and (cache as Dictionary).has(key):
		return (cache as Dictionary)[key]
	var out := ImageTexture.create_from_image(overlay_image(tex.get_image(), tint))
	if cache is Dictionary and tex.resource_path != "":
		(cache as Dictionary)[key] = out
	return out
