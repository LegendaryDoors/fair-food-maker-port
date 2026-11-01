# BowlView -- one fish bowl on the ball-toss midway game (ftTossBallVC).
#
# From the class's own methods in the original binary:
#   initWithWaterImage:tintColor:blendMode:frontImage:  0x12291C
#   changeColor:                                       0x122E30
#   areaOfViewOverlappingRect:view:                    0x122FFC
#   adjustHitboxes:                                    0x123180
#   addSubview:  0x123510   setBackView:  0x1235A4   setCenter:  0x123658
#   setFrame:    0x1236AC   setHidden:    0x123750
#
# A UIView whose frame starts at the water image's size (60x60) and holds, in
# subview order:
#   1. ft_bowlshadow.png, centred at (width/2, 48)          -- autoresizing
#   2. baseIV: the water image tinted by changeColor:       -- autoresizing
#   3. frontView: the front glass (ft_bowl_1.png), alpha 0.5 -- autoresizing
#   4. leftRim (tag 1000), centerOfBowl (1002), rightRim (1001): hidden hit
#      boxes, never autoresized (addSubview: skips tags 1000..1002).
# The back glass (ft_bowl_2.png) is a separate UIImageView the controller puts
# in the row's *back* view; setCenter:/setFrame:/setHidden: keep it in step.
#
# This node models the UIView: `frame` is the UIKit frame in the parent row's
# coordinates; the node's position is its top-left, children are laid out in
# bounds coordinates exactly as UIKit would place them.

extends Node2D

const SHADOW_ART := "ft_bowlshadow.png"
## initWithWaterImage: setCenter:(frame.width * 0.5, 48) on the shadow.
const SHADOW_CENTER_Y := 48.0
## frontView setAlpha:0.5.
const FRONT_ALPHA := 0.5

## Hit-box tags (initWithWaterImage:...).
const TAG_LEFT_RIM := 1000
const TAG_RIGHT_RIM := 1001
const TAG_CENTER := 1002
## adjustHitboxes: sizes at scale 1: centre 15x20, rims 25x20.
const CENTER_HIT_SIZE := Vector2(15, 20)
const RIM_HIT_SIZE := Vector2(25, 20)

## CGBlendMode passed by the controller (initBowls 0x11E13C: blendMode:9).
const BLEND_HARD_LIGHT := 9

## The UIView tag (initBowls sets it from the table at 0x682B5C).
var tag := 0
## UIKit frame, in the parent row's coordinates.
var frame := Rect2()

## ft_bowl_2.png image view living in the row's back view, and its frame.
var back_view: Sprite2D = null
var back_frame := Rect2()

var base_img: Image = null
## Cache key for base_img (its texture's resource path).
var _base_key := ""
var tint_color := Color.WHITE
var b_mode := 0

## Hit boxes in subview order (leftRim, centerOfBowl, rightRim):
## { "tag": int, "frame": Rect2 } in bounds coordinates. Always hidden.
var hitboxes: Array[Dictionary] = []

## Dev aid: outline the three hit boxes (the original never draws them).
var debug_hitboxes := false:
	set(v):
		debug_hitboxes = v
		if _debug_layer != null:
			_debug_layer.queue_redraw()

## Autoresizing subviews: { "node": Sprite2D, "frame": Rect2, "tex": Vector2 }.
var _resizing: Array[Dictionary] = []
var _base_iv: Dictionary = {}
var _front_view: Dictionary = {}
var _debug_layer: Node2D = null

## changeColor: renders are pure functions of (image, colour, mode); cache them.
static var _tint_cache: Dictionary = {}


## -[BowlView initWithWaterImage:tintColor:blendMode:frontImage:] 0x12291C.
func init_with_water_image(water: Texture2D, tint: Color, blend_mode: int,
		front: Texture2D) -> void:
	var size := water.get_size()
	frame = Rect2(Vector2.ZERO, size)
	position = frame.position
	base_img = water.get_image()
	_base_key = water.resource_path
	tint_color = tint
	b_mode = blend_mode

	var shadow_tex: Texture2D = Assets.texture(SHADOW_ART)
	var shadow_size := shadow_tex.get_size()
	_add_resizing(shadow_tex, Rect2(
		Vector2(frame.size.x * 0.5, SHADOW_CENTER_Y) - shadow_size * 0.5,
		shadow_size))
	_base_iv = _add_resizing(water, Rect2(Vector2.ZERO, size))
	_front_view = _add_resizing(front, Rect2(Vector2.ZERO, front.get_size()))
	(_front_view["node"] as Sprite2D).modulate.a = FRONT_ALPHA

	hitboxes = [
		{"tag": TAG_LEFT_RIM, "frame": Rect2(Vector2.ZERO, RIM_HIT_SIZE)},
		{"tag": TAG_CENTER, "frame": Rect2(Vector2.ZERO, CENTER_HIT_SIZE)},
		{"tag": TAG_RIGHT_RIM, "frame": Rect2(Vector2.ZERO, RIM_HIT_SIZE)},
	]
	adjust_hitboxes(1.0)

	_debug_layer = Node2D.new()
	_debug_layer.draw.connect(_draw_hitboxes)
	add_child(_debug_layer)

	change_color(tint)


## -[BowlView changeColor:] 0x122E30. In a 1x image context of the water
## image's size, with the CTM flipped properly (scale 1,-1 / translate 0,-h --
## so unlike MaskedIV nothing ends up upside down): clip to the water image,
## fill with the tint, then draw the water image over it in blend mode bMode.
func change_color(color: Color) -> void:
	tint_color = color
	var node: Sprite2D = _base_iv["node"]
	node.texture = tinted_water(base_img, color, b_mode, _base_key)


## The changeColor: render, per pixel. INFERRED (Quartz semantics, not this
## binary): CGContextClipToMask with an RGBA image clips by its alpha -- the
## standard tint recipe relies on that -- so backdrop and source share one
## alpha `a`; the draw then composites with the PDF separable-blend formula
## Quartz implements for kCGBlendModeHardLight:
##   ar = as + ab - as*ab
##   Cr = (1 - as/ar)*Cb + (as/ar)*((1 - ab)*Cs + ab*B(Cb, Cs))
static func tinted_water(img: Image, color: Color, mode: int,
		image_key: String = "") -> Texture2D:
	if image_key == "":
		image_key = str(img.get_instance_id())
	var key := "%s|%s|%d" % [image_key, color.to_html(), mode]
	if _tint_cache.has(key):
		return _tint_cache[key]
	if mode != BLEND_HARD_LIGHT:
		# Only blend mode 9 is used by this game; others are not ported.
		push_warning("ft_BowlView: blend mode %d not ported, drawing untinted" % mode)
		var plain := ImageTexture.create_from_image(img)
		_tint_cache[key] = plain
		return plain
	var src := img.duplicate() as Image
	if src.is_compressed():
		src.decompress()
	src.convert(Image.FORMAT_RGBA8)
	var out := Image.create(src.get_width(), src.get_height(), false, Image.FORMAT_RGBA8)
	for y in src.get_height():
		for x in src.get_width():
			var s := src.get_pixel(x, y)
			var a := s.a
			var ar := a + a - a * a
			if ar <= 0.0:
				out.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var k := a / ar
			var r := (1.0 - k) * color.r + k * ((1.0 - a) * s.r + a * _hard_light(color.r, s.r))
			var g := (1.0 - k) * color.g + k * ((1.0 - a) * s.g + a * _hard_light(color.g, s.g))
			var b := (1.0 - k) * color.b + k * ((1.0 - a) * s.b + a * _hard_light(color.b, s.b))
			out.set_pixel(x, y, Color(r, g, b, ar))
	var tex := ImageTexture.create_from_image(out)
	_tint_cache[key] = tex
	return tex


## kCGBlendModeHardLight: multiply below source 0.5, screen above.
static func _hard_light(cb: float, cs: float) -> float:
	if cs <= 0.5:
		return cb * (2.0 * cs)
	var s := 2.0 * cs - 1.0
	return cb + s - cb * s


## -[BowlView adjustHitboxes:] 0x123180. Sizes scale with `s`; all three are
## centred at y = box height * 0.25 (so they span -5s .. 15s), the centre box
## at the bowl's mid-width and each rim box one rim-width out from it,
## overlapping the centre box by half its width.
func adjust_hitboxes(s: float) -> void:
	var center_size := CENTER_HIT_SIZE * s
	var rim_size := RIM_HIT_SIZE * s
	var left: Dictionary = hitboxes[0]
	var mid: Dictionary = hitboxes[1]
	var right: Dictionary = hitboxes[2]
	# setFrame: keeps each box's current origin, then setCenter: moves it.
	mid["frame"] = Rect2((mid["frame"] as Rect2).position, center_size)
	left["frame"] = Rect2((mid["frame"] as Rect2).position, rim_size)
	right["frame"] = Rect2((mid["frame"] as Rect2).position, rim_size)
	var mid_center := Vector2(frame.size.x * 0.5, center_size.y * 0.25)
	mid["frame"] = _centered(mid_center, center_size)
	var left_center := Vector2(
		mid_center.x - rim_size.x + center_size.x * 0.5, rim_size.y * 0.25)
	left["frame"] = _centered(left_center, rim_size)
	var right_center := Vector2(
		mid_center.x + rim_size.x - center_size.x * 0.5, rim_size.y * 0.25)
	right["frame"] = _centered(right_center, rim_size)
	if _debug_layer != null:
		_debug_layer.queue_redraw()


## -[BowlView areaOfViewOverlappingRect:view:] 0x122FFC. Over subviews with
## tag >= 1000 (the hit boxes, hidden or not), the largest intersection area
## with `r` (bounds coordinates) and the box that produced it; strictly
## greater wins, so ties keep the earlier box. Returns [area, box or null].
func area_of_view_overlapping_rect(r: Rect2) -> Array:
	var best := 0.0
	var best_box: Variant = null
	for hb: Dictionary in hitboxes:
		if int(hb["tag"]) < 1000:
			continue
		var f: Rect2 = hb["frame"]
		if not r.intersects(f):
			continue
		var area := r.intersection(f).get_area()
		if area > best:
			best = area
			best_box = hb
	return [best, best_box]


## Centre of a hit box, in bounds coordinates (UIView center of the box).
static func box_center(box: Dictionary) -> Vector2:
	return (box["frame"] as Rect2).get_center()


## -[BowlView setBackView:] 0x1235A4: centre and frame copied from the bowl.
func set_back_view(iv: Sprite2D) -> void:
	back_view = iv
	set_back_frame(frame)


func set_back_frame(r: Rect2) -> void:
	back_frame = r
	if back_view != null:
		place_image_view(back_view, r)


func get_center() -> Vector2:
	return frame.get_center()


## -[BowlView setCenter:] 0x123658: moves the back view's centre too.
func set_center(p: Vector2) -> void:
	frame.position = p - frame.size * 0.5
	position = frame.position
	if back_view != null:
		set_back_frame(Rect2(p - back_frame.size * 0.5, back_frame.size))


## -[BowlView setFrame:] 0x1236AC. super setFrame: autoresizes the three
## image subviews (mask 18 = flexible width + height: each absorbs the full
## size delta, margins fixed -- which is why the far rows' shadows shrink to
## slivers rather than scale), then the back view takes frontView's frame.
func set_frame(r: Rect2) -> void:
	var delta := r.size - frame.size
	frame = r
	position = r.position
	if delta != Vector2.ZERO:
		for sub: Dictionary in _resizing:
			var f: Rect2 = sub["frame"]
			_set_sub_frame(sub, Rect2(f.position, f.size + delta))
	if back_view != null:
		set_back_frame(_front_view["frame"])


## -[BowlView setHidden:] 0x123750: hides the back view with it.
func set_hidden(h: bool) -> void:
	visible = not h
	if back_view != null:
		back_view.visible = not h


func is_hidden() -> bool:
	return not visible


## A UIImageView with the default contentMode (scale to fill) at `r`.
static func place_image_view(iv: Sprite2D, r: Rect2) -> void:
	iv.centered = false
	iv.position = r.position
	var ts := iv.texture.get_size() if iv.texture != null else Vector2.ONE
	iv.scale = Vector2(r.size.x / ts.x, r.size.y / ts.y)


# -- internals --------------------------------------------------------

## -[BowlView addSubview:] 0x123510 gives non-hitbox subviews mask 18.
func _add_resizing(tex: Texture2D, r: Rect2) -> Dictionary:
	var iv := Sprite2D.new()
	iv.texture = tex
	add_child(iv)
	var sub := {"node": iv, "frame": r}
	_set_sub_frame(sub, r)
	_resizing.append(sub)
	return sub


func _set_sub_frame(sub: Dictionary, r: Rect2) -> void:
	sub["frame"] = r
	place_image_view(sub["node"], r)


static func _centered(c: Vector2, size: Vector2) -> Rect2:
	return Rect2(c - size * 0.5, size)


func _draw_hitboxes() -> void:
	if not debug_hitboxes:
		return
	# The original gives the boxes white / black / white backgrounds.
	for hb: Dictionary in hitboxes:
		var col := Color.BLACK if int(hb["tag"]) == TAG_CENTER else Color.WHITE
		_debug_layer.draw_rect(hb["frame"], col, false, 1.0)
