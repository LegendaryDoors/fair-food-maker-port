# Lemon Shake Up -- helpers shared by the five lsu screens.
#
# Not a screen: Nav attaches res://screens/<Class>.gd only to a scene of the
# same name, and no lsuShared scene exists. Preload it by path.
#
#   MaskedIV          -[MaskedIV initWithBaseImg:andMaskImg:] 0x46CE0,
#                     drawRect: 0x46E68, setBaseOrigPt: 0x46EE4
#   tinted_image()    -[TintedIV initWithImage:andTintColor:andBlendMode:]
#                     0x46FEC -> changeColor: 0x47304
#   bake_shakeup()    -[lsuPourWaterViewController nextClick:] 0x6C4E4, the
#                     "LemonShakeup" image
#   bake_glass_back() the same method, the "LemonShakeupGlassBack" image
#
# Every pixel loop below composites with the PDF/Quartz source-over formula
# in straight alpha:
#   ao = as + ab(1 - as)
#   co = (as(1 - ab)Cs + (1 - as)ab Cb + as ab B(Cb, Cs)) / ao
# where B is the context's blend mode (Normal: B = Cs).

extends RefCounted


# ======================================================================
# MaskedIV
# ======================================================================

## Port of MaskedIV, where the base image MOVES inside a fixed mask.
##
## initWithBaseImg:andMaskImg: (0x46CE0) sizes the view to the MASK image and
## wraps the mask's pixels in CGImageMaskCreate, so dark samples PAINT;
## drawRect: (0x46E68) clips to that mask, then draws the base image with
## -[UIImage drawAtPoint:] at baseOrigPt (setBaseOrigPt: 0x46EE4 stores the
## point and redisplays).
##
## The clip happens in drawRect:'s UIKit context, whose CTM is flipped, and
## the code never flips it back -- so the MASK lands upside down while the
## base (drawn through UIKit) stays upright. That is the MaskedIV quirk
## confirmed on an iPhone 4 (iOS 6.1.3) for ccbSelectChocolate.
## lsu_cup_mask.png is authored upside down to suit it (its painted region is
## narrow at the top and wide at the bottom); flipped, it is the cup's
## interior. Every lsu MaskedIV therefore flips.
##
## Godot: a clip parent (the mask as an alpha texture, CLIP_CHILDREN_ONLY)
## with the base sprite as a child at baseOrigPt.
class MaskedIV:
	extends Node2D

	var _clip: Sprite2D
	var _base: Sprite2D

	func _init(base_tex: Texture2D, mask_tex: Texture2D, flip_v := true) -> void:
		_clip = Sprite2D.new()
		_clip.centered = false
		_clip.texture = _mask_to_alpha(mask_tex, flip_v)
		_clip.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
		add_child(_clip)
		_base = Sprite2D.new()
		_base.centered = false
		_base.texture = base_tex
		_clip.add_child(_base)

	func set_base_orig_pt(p: Vector2) -> void:
		_base.position = p

	func base_orig_pt() -> Vector2:
		return _base.position

	## CGImageMaskCreate: 0 (black) paints, 255 masks out. The lsu masks are
	## 8-bit grayscale PNGs, so alpha := 255 - luminance.
	static func _mask_to_alpha(tex: Texture2D, flip_v: bool) -> Texture2D:
		if tex == null:
			return null
		var img := tex.get_image()
		if img == null:
			return tex
		img = img.duplicate() as Image
		if img.is_compressed():
			img.decompress()
		if img.detect_alpha() == Image.ALPHA_NONE:
			img.convert(Image.FORMAT_RGBA8)
			var data := img.get_data()
			for i in range(0, data.size(), 4):
				data[i + 3] = 255 - data[i]
				data[i] = 255
				data[i + 1] = 255
				data[i + 2] = 255
			img = Image.create_from_data(img.get_width(), img.get_height(),
				false, Image.FORMAT_RGBA8, data)
		if flip_v:
			img.flip_y()
		return ImageTexture.create_from_image(img)


# ======================================================================
# Image access
# ======================================================================

## Back from a pushed screen (Nav keeps_state_on_push / on_resume). The app
## delegate's coins panel is ONE view that navigationController:
## didShowViewController:animated: (0x1AC3C) takes off the old screen before
## adding it to the new one; core/CoinHUD builds a fresh one on every
## screen_changed and never removes the last, so a kept screen would come back
## carrying two. Nav emits screen_changed right after on_resume(), so dropping
## the old panel there leaves exactly the one CoinHUD adds (as
## MakeViewController.on_resume() does).
static func drop_coin_view(screen: Node) -> void:
	var old := screen.get_node_or_null("CoinInfoView")
	if old != null:
		screen.remove_child(old)
		old.queue_free()


static func load_tex(file: String) -> Texture2D:
	return Assets.texture(file)


## A private RGBA8 copy of a texture's pixels.
static func image_of(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	img = img.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


# ======================================================================
# TintedIV
# ======================================================================

## CGBlendMode values used on the lsu path.
const BLEND_NORMAL := 0
const BLEND_MULTIPLY := 1
const BLEND_OVERLAY := 3


## -[TintedIV changeColor:] (0x47304): into a context the size of the art,
## clip to the art (CGContextClipToMask with the art itself -- its alpha is
## the coverage), fill with the tint, restore, then draw the art over that
## fill with CGContextSetBlendMode(bMode). baseIV shows the result.
##
## Every lsu TintedIV that carries a colour uses blend mode 3, overlay
## (lsu_fruit_juice on the squeeze/ice/water screens, lsu_mixed_juice as
## finishedBlend). The port used to stand a plain modulate in for it.
## A nil tint skips changeColor: entirely (0x46FEC), leaving the art as is.
static func tinted_image(tex: Texture2D, tint: Variant, mode: int) -> Image:
	if tex == null:
		return null
	if not (tint is Color):
		return image_of(tex)
	var c: Color = tint
	var img := image_of(tex)
	var data := img.get_data()
	var tint3 := [c.r, c.g, c.b]
	for i in range(0, data.size(), 4):
		var sa := data[i + 3] / 255.0
		if sa <= 0.0:
			data[i] = 0
			data[i + 1] = 0
			data[i + 2] = 0
			continue
		var ab := c.a * sa                    # the fill, clipped to the art
		var ao := sa + ab * (1.0 - sa)
		for k in 3:
			var cs := data[i + k] / 255.0
			var cb: float = tint3[k]
			var b := blend(cb, cs, mode)
			var co := (sa * (1.0 - ab) * cs + (1.0 - sa) * ab * cb + sa * ab * b) / ao
			data[i + k] = clampi(roundi(co * 255.0), 0, 255)
		data[i + 3] = clampi(roundi(ao * 255.0), 0, 255)
	return Image.create_from_data(img.get_width(), img.get_height(), false,
		Image.FORMAT_RGBA8, data)


static func tinted_texture(tex: Texture2D, tint: Variant, mode: int) -> Texture2D:
	var img := tinted_image(tex, tint, mode)
	return ImageTexture.create_from_image(img) if img != null else null


## The PDF separable blend functions Quartz implements. Cb = backdrop (the
## tint fill), Cs = source (the art).
static func blend(cb: float, cs: float, mode: int) -> float:
	match mode:
		BLEND_MULTIPLY:
			return cs * cb
		BLEND_OVERLAY:
			# Overlay(Cb, Cs) = HardLight(Cs, Cb): keyed on the BACKDROP.
			if cb <= 0.5:
				return 2.0 * cs * cb
			return 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb)
		_:
			return cs


# ======================================================================
# The bake-out: -[lsuPourWaterViewController nextClick:] (0x6C4E4)
# ======================================================================

## Image 1, "LemonShakeup". Context the size of lsu_mixed_juice.png, CTM
## flipped back to Quartz space (so art and clip both land upright); save;
## CGContextSetAlpha 0.9; clip to the art; fill with fruitColor; restore;
## CGContextSetAlpha 0.5; kCGBlendModeMultiply; draw the art.
const SHAKEUP_FILL_ALPHA := 0.9
const SHAKEUP_ART_ALPHA := 0.5


static func bake_shakeup(tint: Color) -> Image:
	var img := image_of(load_tex("lsu_mixed_juice.png"))
	if img == null:
		return null
	var data := img.get_data()
	var tint3 := [tint.r, tint.g, tint.b]
	for i in range(0, data.size(), 4):
		var m := data[i + 3] / 255.0           # the art's own coverage
		if m <= 0.0:
			data[i] = 0
			data[i + 1] = 0
			data[i + 2] = 0
			continue
		var ab := SHAKEUP_FILL_ALPHA * tint.a * m
		var sa := SHAKEUP_ART_ALPHA * m
		var ao := sa + ab * (1.0 - sa)
		for k in 3:
			var cs := data[i + k] / 255.0
			var cb: float = tint3[k]
			var b := cs * cb                    # multiply
			var co := (sa * (1.0 - ab) * cs + (1.0 - sa) * ab * cb + sa * ab * b) / ao
			data[i + k] = clampi(roundi(co * 255.0), 0, 255)
		data[i + 3] = clampi(roundi(ao * 255.0), 0, 255)
	return Image.create_from_data(img.get_width(), img.get_height(), false,
		Image.FORMAT_RGBA8, data)


## Image 2, "LemonShakeupGlassBack". Context the size of lsu_cup.png in
## Quartz space: lsu_cup drawn with kCGBlendModeMultiply (onto a clear
## context that is the art itself), back to Normal, lsu_ice_cubes_for_cup at
## (0, 0, its size), then <prefix>half_1 and <prefix>half_2 at half size with
## their Quartz origins at (70, 50) and (40, 90) -- bottom-left origins, so
## from the image top they sit at H - y - h/2. Unlike the screens, which
## reuse half_1 twice, this draws the real half_2.
const BACK_HALF1_QUARTZ := Vector2(70, 50)
const BACK_HALF2_QUARTZ := Vector2(40, 90)
const BACK_HALF_SCALE := 0.5


static func bake_glass_back(prefix: String) -> Image:
	var out := image_of(load_tex("lsu_cup.png"))
	if out == null:
		return null
	var h := float(out.get_height())
	var ice := image_of(load_tex("lsu_ice_cubes_for_cup.png"))
	if ice != null:
		draw_over(out, ice, Rect2(0, h - ice.get_height(),
			ice.get_width(), ice.get_height()))
	for cfg: Array in [[prefix + "half_1.png", BACK_HALF1_QUARTZ],
			[prefix + "half_2.png", BACK_HALF2_QUARTZ]]:
		var half := image_of(load_tex(str(cfg[0])))
		if half == null:
			continue
		var q: Vector2 = cfg[1]
		var size := Vector2(half.get_width(), half.get_height()) * BACK_HALF_SCALE
		draw_over(out, half, Rect2(q.x, h - q.y - size.y, size.x, size.y))
	return out


## CGContextDrawImage(rect) with kCGBlendModeNormal, in top-left image
## coordinates. Fractional edges get area coverage and the art is sampled
## bilinearly (premultiplied). INFERRED: Quartz's default interpolation
## quality for a bitmap context is not specified; bilinear is the stand-in.
static func draw_over(dest: Image, src: Image, rect: Rect2) -> void:
	var sw := src.get_width()
	var sh := src.get_height()
	if sw == 0 or sh == 0 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var sdata := src.get_data()
	var ddata := dest.get_data()
	var dw := dest.get_width()
	var dh := dest.get_height()
	var x0 := maxi(0, floori(rect.position.x))
	var y0 := maxi(0, floori(rect.position.y))
	var x1 := mini(dw, ceili(rect.end.x))
	var y1 := mini(dh, ceili(rect.end.y))
	var same_size := is_equal_approx(rect.size.x, sw) and is_equal_approx(rect.size.y, sh) \
		and is_equal_approx(rect.position.x, roundf(rect.position.x)) \
		and is_equal_approx(rect.position.y, roundf(rect.position.y))
	for py in range(y0, y1):
		var cy := minf(py + 1.0, rect.end.y) - maxf(float(py), rect.position.y)
		if cy <= 0.0:
			continue
		for px in range(x0, x1):
			var cx := minf(px + 1.0, rect.end.x) - maxf(float(px), rect.position.x)
			if cx <= 0.0:
				continue
			var s: Color
			if same_size:
				var si := ((py - int(rect.position.y)) * sw + (px - int(rect.position.x))) * 4
				s = Color(sdata[si] / 255.0, sdata[si + 1] / 255.0,
					sdata[si + 2] / 255.0, sdata[si + 3] / 255.0)
			else:
				var u := (clampf(px + 0.5, rect.position.x, rect.end.x) - rect.position.x) \
					/ rect.size.x * sw - 0.5
				var v := (clampf(py + 0.5, rect.position.y, rect.end.y) - rect.position.y) \
					/ rect.size.y * sh - 0.5
				s = _sample(sdata, sw, sh, u, v)
			var sa := s.a * cx * cy
			if sa <= 0.0:
				continue
			var di := (py * dw + px) * 4
			var da := ddata[di + 3] / 255.0
			var ao := sa + da * (1.0 - sa)
			for k in 3:
				var cs: float = s[k]
				var cb := ddata[di + k] / 255.0
				var co := (sa * cs + (1.0 - sa) * da * cb) / ao
				ddata[di + k] = clampi(roundi(co * 255.0), 0, 255)
			ddata[di + 3] = clampi(roundi(ao * 255.0), 0, 255)
	dest.set_data(dw, dh, false, Image.FORMAT_RGBA8, ddata)


## Premultiplied bilinear sample, clamped at the art's edges.
static func _sample(data: PackedByteArray, w: int, h: int, u: float, v: float) -> Color:
	var uc := clampf(u, 0.0, w - 1.0)
	var vc := clampf(v, 0.0, h - 1.0)
	var ix := mini(int(uc), w - 1)
	var iy := mini(int(vc), h - 1)
	var fx := uc - ix
	var fy := vc - iy
	var ix1 := mini(ix + 1, w - 1)
	var iy1 := mini(iy + 1, h - 1)
	var acc := [0.0, 0.0, 0.0, 0.0]
	for corner: Array in [[ix, iy, (1.0 - fx) * (1.0 - fy)], [ix1, iy, fx * (1.0 - fy)],
			[ix, iy1, (1.0 - fx) * fy], [ix1, iy1, fx * fy]]:
		var wgt: float = corner[2]
		if wgt <= 0.0:
			continue
		var i := (int(corner[1]) * w + int(corner[0])) * 4
		var a := data[i + 3] / 255.0
		acc[0] += data[i] / 255.0 * a * wgt
		acc[1] += data[i + 1] / 255.0 * a * wgt
		acc[2] += data[i + 2] / 255.0 * a * wgt
		acc[3] += a * wgt
	if acc[3] <= 0.0:
		return Color(0, 0, 0, 0)
	return Color(acc[0] / acc[3], acc[1] / acc[3], acc[2] / acc[3], acc[3])
