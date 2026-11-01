# Kettle Corn step 1 -- tilt the kernel box to pour kernels into the hot oil.
#
# GROUNDED from initWithNibName:bundle: (0x104450), viewDidLoad (0x104638),
# viewWillAppear: (0x104B88), bubbleTick (0x105358), kernelTick (0x105724,
# rotate/flight durations read from the disassembly at 0x105954 -- both 1.0s),
# animationDidStop:finished:context: (0x105BC8), accelerometer:didAccelerate:
# (0x106098), startAccelerometer (0x106380, 1/30s update), viewWillDisappear:
# (0x1051F8), nextClick: (0x10677C), backClick: (0x10670C), showNextButton
# (0x106E08) and changeInstruction: (0x106F6C).
#
# The mechanic really is accelerometer tilt here (unlike both kc shake screens,
# whose accelerometers are never started -- the startAccelerometer selref's
# only kc referrers are this viewWillAppear and kcSelectSugar's screenSetup /
# selectFlavorButtonClick:). The filtered device x drives a box rotation
# clamped to [-125 deg, -15 deg], and kernels pour while the angle is at or
# past -120 deg. The port makes that press-and-hold on the box: the box
# animates to the clamp-bottom angle (-125 deg, the only original-attested
# "fully tilted" value, 0x106350/0x10637C) and the identical pourTime
# accumulator runs. Only the 0.35s tilt-in/out time is a port choice -- the
# original tracked a continuously filtered angle instead.
#
# The "skip" consumable (buySkip / consumableSkip, built in viewDidLoad with
# btn_IAP_* art at centre (50, 350.5); consumablePurchased: 0x106420) is a
# 3-coin consumable, not IAP; ported, see the skip block.
#
# No particles: kcGLFXView (the kc OpenGL emitter class) is never instantiated
# -- no kc nib contains it and its classRef is only used by its own methods.
#
# This file also carries the kc-shared helpers (the other three kc screens
# preload it, and so do a few other foods for bake_tint / MaskedIV): MaskedIV
# (the pot-window mask), bake_tint (TintedIV changeColor:, 0x47304) and
# OilBubbler (the bubbleTick idiom all four screens repeat with identical
# constants). The kc timing / path / sound helpers live in kcKit.gd.

extends "res://core/Screen.gd"

const kcKit := preload("res://screens/kcKit.gd")

## Skip consumable (ported; the original shows its badge):
## initWithNibName: 0x104450 builds Consumable DM_CONSUMABLE_SKIP / Skip_10Pour,
## cost = the dead server table GameData.CoinCosts ... SkipIngredients, 3 when
## absent; first-time message below. viewDidLoad 0x104638 builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5), inserted ABOVE instIV (insertSubview:aboveSubview:), and
## wires buyClick: 0x1066A0 ("store" sound, purchaseConsumable).
## consumablePurchased: 0x106420 calls nextClick: with the badge as sender --
## the same path as the next button. consumablePurchaseFailed:error: 0x1065CC
## (error 2) shows "You do not have enough coins." (the port's Consumable
## raises that in place of the original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_10Pour"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton


# ======================================================================
# Shared helper: MaskedIV, as -[MaskedIV initWithBaseImg:andMaskImg:]
# (0x46CE0) builds it -- a view SIZED TO THE MASK image (initWithFrame:
# (0,0,maskW,maskH)), so setCenter: on it is a TRUE centre of the mask's
# dimensions. drawRect: (0x46E68) clips to the mask and draws the base
# image at baseOrigPt, natural size.
#
# kc_mask.png (317x166, the pot interior) is black-shape-on-white with a
# fully opaque alpha channel; CGImageMaskCreate paints where the sample is
# 0, so BLACK shows through. Re-expressed as alpha = 1 - red.
#
# UPSIDE DOWN (flip_v): drawRect: calls CGContextClipToMask in the UIKit
# drawRect context, whose CTM is y-down, with no compensating flip -- so the
# mask lands vertically inverted on the device (the trap documented for
# MaskedSprite2D.mask_flip_v / ccbSelectChocolate). kc_mask.png is visibly
# authored for that: its black shape has its rounded corners at the TOP and
# its wide edge at the BOTTOM (rows 27..165), the reverse of kc_pot.png,
# whose body is wide at the top and rounded at the bottom; flipped, it is
# exactly the pot's interior (rows 0..138). It also explains the starting
# piles: kcPourOil's kernels (base y 145) and kcSelectSugar's sugar (base y
# 148) sit wholly below row 138 until poured, i.e. the pot starts empty.
# The kc screens pass flip_v = true. The default stays false so other foods
# that borrow this class (cffAddWater, cffSelectSlicer) are unchanged.
# ======================================================================

class MaskedIV:
	extends Node2D

	var _clip: Sprite2D
	var _base: Sprite2D
	var _mask_size := Vector2.ZERO

	func _init(base_tex: Texture2D, mask_tex: Texture2D, flip_v := false) -> void:
		_clip = Sprite2D.new()
		_clip.centered = false
		_clip.texture = _mask_to_alpha(mask_tex, flip_v)
		_clip.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
		add_child(_clip)
		if mask_tex != null:
			_mask_size = mask_tex.get_size()
		_base = Sprite2D.new()
		_base.centered = false
		_base.texture = base_tex
		_clip.add_child(_base)

	## setCenter: -- a real centre, because the view is mask-sized (0x46CE0).
	func set_center(c: Vector2) -> void:
		position = c - _mask_size * 0.5

	func get_center() -> Vector2:
		return position + _mask_size * 0.5

	## setBaseOrigPt: (0x46EE4) -- where the base art's top-left sits inside
	## the mask window.
	func set_base_orig_pt(p: Vector2) -> void:
		_base.position = p

	func get_base_orig_pt() -> Vector2:
		return _base.position

	## setBaseImg: (0x46F18).
	func set_base_texture(t: Texture2D) -> void:
		_base.texture = t

	func base_size() -> Vector2:
		return _base.texture.get_size() if _base.texture != null else Vector2.ZERO

	## CGImageMaskCreate: sample 0 (black) paints. kc_mask carries no useful
	## alpha (checked: all 255), so the red channel is inverted into alpha.
	## flip_v mirrors the rows (see the block comment above).
	static func _mask_to_alpha(tex: Texture2D, flip_v := false) -> Texture2D:
		if tex == null:
			return null
		var img := tex.get_image()
		if img == null:
			return tex
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		var data := img.get_data()
		for i in range(0, data.size(), 4):
			data[i + 3] = 255 - data[i]
			data[i] = 255
			data[i + 1] = 255
			data[i + 2] = 255
		var out := Image.create_from_data(img.get_width(), img.get_height(),
			false, Image.FORMAT_RGBA8, data)
		if flip_v:
			out.flip_y()
		return ImageTexture.create_from_image(out)


# ======================================================================
# Shared helper: the TintedIV colour bake.
#
# -[TintedIV changeColor:] (0x47304) renders, once, into a context the size
# of the art: it clips to the art's alpha, fills with the tint colour (the
# tint's own alpha included -- several kc colours carry alpha 0.7), then
# draws the art over that fill with CGContextSetBlendMode(bMode). Unlike
# MaskedIV it flips its CTM first (ScaleCTM 1,-1 / TranslateCTM 0,-h), so
# the result is upright. The kc screens then reuse the composite as a plain
# image (they read baseIV.image straight back at 0x111050 / 0x114478), so
# the port bakes exactly that. A nil tint never calls changeColor: at all
# (initWithImage:... 0x46FEC), which alpha 0 reproduces: the art unchanged.
#
# Modes seen on the kc path, by the CGBlendMode value at each call site:
#   5 = kCGBlendModeLighten    (sugar packet 0x10C6E0, swatches 0x10DDE0)
#   7 = kCGBlendModeColorBurn  (sugar piles 0x10D608 / 0x111050, sugar2)
#   9 = kCGBlendModeHardLight  (popcorn piles 0x111050 / 0x114478)
# And on the ms path (the milkshake screens preload this file for the bake):
#   8 = kCGBlendModeSoftLight  (milk stream 0x49C50, syrup stream 0x53500)
# The blend functions are the PDF separable functions CG implements;
# compositing is standard source-over with the blend term.
# ======================================================================

static func bake_tint(tex: Texture2D, tint: Color, mode: int) -> ImageTexture:
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
	match mode:
		5:                                        # Lighten
			return maxf(cb, cs)
		7:                                        # ColorBurn
			if cb >= 1.0:
				return 1.0
			if cs <= 0.0:
				return 0.0
			return 1.0 - minf(1.0, (1.0 - cb) / cs)
		8:                                        # SoftLight
			if cs <= 0.5:
				return cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb)
			var d := ((16.0 * cb - 12.0) * cb + 4.0) * cb if cb <= 0.25 \
				else sqrt(cb)
			return cb + (2.0 * cs - 1.0) * (d - cb)
		9:                                        # HardLight
			if cs <= 0.5:
				return 2.0 * cs * cb
			return 1.0 - 2.0 * (1.0 - cs) * (1.0 - cb)
		_:
			return cs                             # Normal: the art wins


# ======================================================================
# Shared helper: the oil bubbles.
#
# All four kc screens repeat one bubbleTick verbatim (0x105358 / 0x1089D0 /
# 0x10EC00 / 0x113678) on a 0.2s timer, with the same three swirl images
# (initWithNibName: 0x104450) and the same literals (size /5.4, width -60,
# x base 30, cap 5, float 0.25s, fade 0.5s, both UIViewAnimationCurveEaseIn).
# ======================================================================

class OilBubbler:
	extends Node

	const INTERVAL := 0.2          # timer literal, e.g. 0x104EB8
	const SIZE_DIV := 5.4          # 0x105718
	const X_SHRINK := -60.0        # 0x105720 (FloatVectorAdd of -60)
	const X_BASE := 30.0           # the +0x1e
	const MAX_BUBBLES := 5         # "if (4 < count) return"
	const FLOAT_SECONDS := 0.25    # 0x3fd00000
	const FADE_SECONDS := 0.5      # 0x3fe00000
	const ARTS := ["kc_mixed_oil.png", "kc_mixed_oil2.png", "kc_mixed_oil3.png"]

	## The nib's kc_oil sprite; bubbles are its subviews, in its local space.
	var oil: Sprite2D
	var _accum := 0.0

	func _init(oil_sprite: Sprite2D) -> void:
		oil = oil_sprite

	## viewWillDisappear: invalidates bubbleTimer; the next viewWillAppear:
	## schedules a fresh one (first firing a full interval later). Bubbles
	## already rising finish on Core Animation while the screen is covered,
	## so none is left on return (keep-state).
	func restart() -> void:
		_accum = 0.0
		if oil == null or not is_instance_valid(oil):
			return
		for b in oil.get_children():
			b.queue_free()

	func _process(delta: float) -> void:
		if oil == null or not is_instance_valid(oil):
			return
		_accum += delta
		while _accum >= INTERVAL:
			_accum -= INTERVAL
			_tick()

	func _tick() -> void:
		if oil.get_child_count() > MAX_BUBBLES - 1:
			return
		var art := str(ARTS[randi() % ARTS.size()])
		if not Assets.has_image(art):
			return
		var b := Sprite2D.new()
		b.texture = Assets.texture(art)
		b.centered = true
		b.scale = Vector2.ONE / SIZE_DIV
		var w := oil.texture.get_size().x            # 253
		var h := oil.texture.get_size().y            # 38
		var bh := b.texture.get_size().y / SIZE_DIV
		# x = 30 + rand % (w - 60); y = h - rand % (h/2) - bubble.h/2, both
		# truncated to int (the FPToFixed/FixedToFP round trip).
		var x := float(int(X_BASE) + randi() % int(w + X_SHRINK))
		var y := float(int(h - float(randi() % int(h * 0.5)) - bh * 0.5))
		b.position = Vector2(x, y)
		oil.add_child(b)
		# "FloatBubble": 0.25s ease-in to y = 0, then "FadeBubble": 0.5s
		# ease-in to alpha 0, then removeFromSuperview (0x105BC8).
		var t := b.create_tween()
		t.tween_property(b, "position:y", 0.0, FLOAT_SECONDS) \
			.set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_IN))
		t.tween_property(b, "modulate:a", 0.0, FADE_SECONDS) \
			.set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_IN))
		t.tween_callback(b.queue_free)


# ======================================================================
# The screen itself
# ======================================================================

# -- construction (viewDidLoad 0x104638, viewWillAppear: 0x104B88) ------

## kernelPile: MaskedIV(kc_kernelpile_1, kc_mask), centre (160, 293) -- a
## true centre; the 317x166 window lands at top-left (1.5, 210), matching
## the pot art's nib frame. Inserted below the oil.
const PILE_CENTER := Vector2(160, 293)        # 0x43200000 / 0x43928000
## viewWillAppear: setBaseOrigPt:(30, 145). Each landed kernel raises the
## pile by baseImg.height * 0.025 (0x10608C) while pourTime <= 4.0 -- 123px
## art, so 3.075px per kernel, 123px over the 40 rising kernels.
const PILE_ORIG := Vector2(30, 145)           # 0x41F00000 / 0x43110000
const PILE_RISE_FRACTION := 0.025             # 0x1060 8C

## The lid flies from its nib home to centre (160, -height), 0.5s ease-in
## ("MoveLid", curve 1). Its completion (0x105BC8) parks the box at
## centre.x + 300 (on top of viewWillAppear's earlier +300), unhides it and
## slides it to centre (204, 85) over 0.3s ("MoveBox", curve 1).
const LID_EXIT_CENTER_X := 160.0
const LID_SECONDS := 0.5                      # 0x3fe00000
const BOX_PARK_STEP_X := 300.0                # 0x1051F4 and 0x106090, each
const BOX_REST_CENTER := Vector2(204, 85)     # 0x434c0000 / 0x42aa0000
const BOX_SECONDS := 0.3                      # 0x106080

# -- the tilt (accelerometer:didAccelerate: 0x106098) -------------------

## angle = clamp(filteredX * 6, -2.1817, -0.2618); the box transform
## tracks it, so at rest (device flat) the box sits at -15 deg.
const REST_ROTATION := -0.2617994             # 0x10637C
const POUR_ROTATION := -2.1816616             # 0x106350, the clamp bottom
## isPouringKernels = angle <= -2.0943951 && pourTime < 4.0 (0x106370).
const POUR_THRESHOLD := -2.0943951
## PORT CHOICE: the 0.35s tilt animation time; the original's
## angle was a continuously filtered signal (k = 0.05 at 1/30s, 0x106338).
const TILT_SECONDS := 0.35

## spoutTop = box.centre + (sin(a)*115 + 65, cos(a)*(-45) + 30).
const SPOUT_SIN_K := 115.0                    # 0x106358
const SPOUT_X_OFF := 65.0                     # 0x106360
const SPOUT_COS_K := -45.0                    # 0x106368
const SPOUT_Y_OFF := 30.0                     # the literal 30.0 in 0x106098

# -- the kernels (kernelTick 0x105724, animationDidStop 0x105BC8) --------

const KERNEL_INTERVAL := 0.1                  # 0x104EC0
const KERNEL_SCALE := 0.75                    # 0x3f400000, both axes
## CAKeyframe path: MoveTo(spoutTop), CurveTo with BOTH control points at
## (pile.centre.x, spoutTop.y), ending at pile.centre + (0, 35); PACED,
## 1.0s. The UIView "RotateKernel" animation (also 1.0s, VMOV.F64 #1.0 at
## 0x105954, curve 1 ease-in) sets the kernel's transform twice in one
## block, -3.1241 then -6.2657. The port animates to the last value set;
## what UIKit actually renders for that pair is an open device question.
const KERNEL_FLIGHT_SECONDS := 1.0            # 0x3ff00000, both animations
const KERNEL_END_Y_OFF := 35.0                # 0x105BC4
const KERNEL_ROTATION := -6.2657              # 0xc0c880e0
## Landing: remove, pourTime += 0.1f (0x106088); >= 4.0 shows next.
const POUR_TIME_STEP := 0.1
const POUR_TIME_FULL := 4.0
## player1..player5 of viewWillAppear: (0x104B88), in order.
const KERNEL_SOUNDS := ["kernel_01", "kernel_02", "kernel_03", "kernel_04",
	"kernels_02"]

var _pile: MaskedIV
var _box_pivot: Node2D
var _box_ready := false
## The accelerometer delegate (startAccelerometer in viewWillAppear:,
## stopAccelerometer in viewWillDisappear:).
var _accel_on := false
## lidOriginalCenter (viewDidLoad 0x104638): viewWillAppear: puts the lid
## back here before every MoveLid.
var _lid_home := Vector2.ZERO
var _bubbler: OilBubbler
## Every tween this screen starts (kcKit.track / settle, keep-state).
var _tweens: Array = []
var _holding := false
var _tilt_tween: Tween
var _pour_time := 0.0
var _kernel_accum := 0.0
var _kernel_sounds: kcKit.SoundBank
var _done_shown := false


func on_enter() -> void:
	# viewDidLoad (0x104638): the badge, the pile, the box, lidOriginalCenter.
	_build_skip()
	GameState.begin("kc")
	_build_pile()
	_build_box_pivot()
	var lid := outlet("lid") as Sprite2D
	if lid != null:
		_lid_home = lid.position
	_bubbler = OilBubbler.new(outlet("oil") as Sprite2D)
	add_child(_bubbler)
	_kernel_sounds = kcKit.SoundBank.new(KERNEL_SOUNDS)
	add_child(_kernel_sounds)
	_view_will_appear()
	set_process(true)


## Back from kcShakeToFlatten: the same instance, viewWillAppear: again.
## It re-runs the whole step -- pile and pourTime reset, lid back on and
## off, box slid in afresh, next hidden by changeInstruction:.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	kcKit.drop_coin_panel(self)
	_view_will_appear()


## viewWillAppear: (0x104B88), in its order.
func _view_will_appear() -> void:
	_accel_on = true                           # startAccelerometer
	# bubbleTimer 0.2s / kernelTimer 0.1s: fresh timers.
	if _bubbler != null:
		_bubbler.restart()
	_kernel_accum = 0.0
	if _pile != null:
		_pile.set_base_orig_pt(PILE_ORIG)
	_pour_time = 0.0
	_done_shown = false
	_box_ready = false
	_holding = false
	if _box_pivot != null:
		_box_pivot.rotation = REST_ROTATION    # the accel at rest
	# changeInstruction:@"inst_pour.png" (0x6b9504). The banner stays up
	# through the pour; showNextButton is what hides it. It also hides next.
	change_instruction("inst_pour.png")
	_set_next_enabled(false)
	# popcornBox centre.x += 300, hidden (MoveLid's completion adds the
	# second 300 and slides it in). Parked first: the original sets this
	# after committing MoveLid, whose completion only comes 0.5s later.
	if _box_pivot != null:
		_box_pivot.position.x += BOX_PARK_STEP_X
		_box_pivot.visible = false
	# The lid jumps home and flies out (MoveLid), lid_05 alongside.
	var lid := outlet("lid") as Sprite2D
	if lid != null:
		lid.position = _lid_home
	_fly_lid_out()
	Audio.play("lid_05")
	if _skip_button != null:
		_skip_button.visible = true            # buySkip setHidden:NO


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _build_pile() -> void:
	_pile = MaskedIV.new(_tex("kc_kernelpile_1.png"), _tex("kc_mask.png"), true)
	_pile.set_center(PILE_CENTER)
	_pile.set_base_orig_pt(PILE_ORIG)
	var oil := outlet("oil")
	if oil != null and oil != self:
		add_child(_pile)
		move_child(_pile, oil.get_index())     # insertSubview:belowSubview:oil
	else:
		add_child(_pile)


## The nib box sprite is top-left anchored; the original rotates the
## UIImageView about its centre, so the sprite is rehung on a pivot node.
## viewWillAppear parks it at centre.x + 300 hidden; MoveLid's completion
## adds another +300 before the slide-in, so the visible flight starts at
## x = 804.
func _build_box_pivot() -> void:
	var box := outlet("popcornBox")
	if box == null or not (box is Sprite2D):
		return
	var s := box as Sprite2D
	var half: Vector2 = s.texture.get_size() * s.scale * 0.5
	_box_pivot = Node2D.new()
	_box_pivot.position = BOX_REST_CENTER      # the nib centre (153,12,102,146)
	_box_pivot.visible = false
	_box_pivot.rotation = REST_ROTATION        # the accel clamp's rest value
	var parent := s.get_parent()
	parent.add_child(_box_pivot)
	parent.move_child(_box_pivot, s.get_index())
	parent.remove_child(s)
	_box_pivot.add_child(s)
	s.position = -half


func _fly_lid_out() -> void:
	var lid := outlet("lid")
	if lid == null or not (lid is Sprite2D):
		_on_lid_gone()
		return
	var s := lid as Sprite2D
	var size: Vector2 = s.texture.get_size() * s.scale
	var target := Vector2(LID_EXIT_CENTER_X, -size.y) - size * 0.5
	var t := _tween()
	t.tween_property(s, "position", target, LID_SECONDS) \
		.set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_IN))
	t.tween_callback(_on_lid_gone)


## animationDidStop MoveLid (0x105BC8): isBoxAnimating = YES, unhide the box
## off right and slide it in; MoveBox's completion clears isBoxAnimating.
func _on_lid_gone() -> void:
	if _box_pivot == null:
		_box_ready = true
		return
	_box_pivot.position.x += BOX_PARK_STEP_X
	_box_pivot.visible = true
	var t := _tween()
	t.tween_property(_box_pivot, "position", BOX_REST_CENTER, BOX_SECONDS) \
		.set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_IN))
	t.tween_callback(func() -> void: _box_ready = true)


# -- input: press-and-hold on the box (PORT CHOICE) ---------------------

## The accelerometer runs from viewWillAppear, so the box follows the tilt
## even while it slides in; kernelTick is what waits for !isBoxAnimating.
## The hold is therefore accepted as soon as the box is visible.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		if _accel_on and _box_pivot != null and _box_pivot.visible \
				and _box_hit_rect().has_point(mb.position):
			_set_holding(true)
			get_viewport().set_input_as_handled()
	elif _holding:
		_set_holding(false)


func _box_hit_rect() -> Rect2:
	if _box_pivot == null:
		return Rect2()
	# The box's nib frame, tracked to wherever the pivot currently sits.
	return Rect2(_box_pivot.position - Vector2(51, 73), Vector2(102, 146))


func _set_holding(value: bool) -> void:
	if _holding == value:
		return
	_holding = value
	if _box_pivot != null:
		# One tilt tween at a time: a press during the return swing restarts
		# from the current angle instead of fighting the old tween.
		if _tilt_tween != null and _tilt_tween.is_valid():
			_tilt_tween.kill()
		_tilt_tween = _tween()
		_tilt_tween.tween_property(_box_pivot, "rotation",
			POUR_ROTATION if value else REST_ROTATION, TILT_SECONDS) \
			.set_trans(Tween.TRANS_SINE)


## isPouringKernels (0x106098) -- the angle gate and the time gate. The
## spawn's other two conditions (!isBoxAnimating, box not hidden) are
## _box_ready, checked in the tick.
func _is_pouring() -> bool:
	return _box_pivot != null and _pour_time < POUR_TIME_FULL \
		and _box_pivot.rotation <= POUR_THRESHOLD


## spoutTop (0x106098), of the box centre.
func _spout_top() -> Vector2:
	var a: float = _box_pivot.rotation
	return _box_pivot.position + Vector2(
		sin(a) * SPOUT_SIN_K + SPOUT_X_OFF,
		cos(a) * SPOUT_COS_K + SPOUT_Y_OFF)


# -- the kernel rain (kernelTick 0x105724) ------------------------------

func _process(delta: float) -> void:
	_kernel_accum += delta
	while _kernel_accum >= KERNEL_INTERVAL:
		_kernel_accum -= KERNEL_INTERVAL
		_kernel_tick()


func _kernel_tick() -> void:
	if _is_pouring() and _box_ready and _box_pivot.visible:
		_spawn_kernel()
	# The tick's tail (0x105B5C) runs regardless of the spawn guards:
	# pourTime >= 4.0 && nextButton hidden -> showNextButton.
	if _pour_time >= POUR_TIME_FULL and not _done_shown:
		_done_shown = true
		show_next_button()
		_set_next_enabled(true)


func _spawn_kernel() -> void:
	var tex := _tex("kc_kernel.png")
	if tex == null or _pile == null:
		return
	var k := Sprite2D.new()
	k.texture = tex
	k.centered = true
	k.scale = Vector2(KERNEL_SCALE, KERNEL_SCALE)
	var p0 := _spout_top()
	k.position = p0
	# insertSubview:belowSubview:kernelPile.
	var parent := _pile.get_parent()
	parent.add_child(k)
	parent.move_child(k, _pile.get_index())

	var pile_c := _pile.get_center()
	var p12 := Vector2(pile_c.x, p0.y)                 # both control points
	var p3 := pile_c + Vector2(0, KERNEL_END_Y_OFF)    # (160, 328)
	var path := kcKit.PacedCubic.new(p0, p12, p12, p3)
	var t := _tween()
	t.set_parallel(true)
	# kCAAnimationPaced: constant speed along the curve, linear in time.
	t.tween_method(func(u: float) -> void:
		if is_instance_valid(k):
			k.position = path.at(u),
		0.0, 1.0, KERNEL_FLIGHT_SECONDS)
	t.tween_property(k, "rotation", KERNEL_ROTATION, KERNEL_FLIGHT_SECONDS) \
		.set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_IN))
	t.chain().tween_callback(_kernel_landed.bind(k))


## The RotateKernel branch of 0x105BC8.
func _kernel_landed(k: Sprite2D) -> void:
	if is_instance_valid(k):
		k.queue_free()
	_pour_time = kcKit.f32(_pour_time + kcKit.f32(POUR_TIME_STEP))
	if _pour_time <= POUR_TIME_FULL and _pile != null:
		var rise: float = _pile.base_size().y * PILE_RISE_FRACTION   # 3.075
		_pile.set_base_orig_pt(_pile.get_base_orig_pt() - Vector2(0, rise))
	_kernel_sounds.play_first_idle()


# -- navigation ---------------------------------------------------------

func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.set("disabled", not on)


## nextClick: (0x10677C): button_press, push kcShakeToFlattenKernels.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.next()


## backClick: (0x10670C).
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


## viewWillDisappear: (0x1051F8): stopAccelerometer, bubbleTimer and
## kernelTimer invalidated (the port's _process accumulators stop with the
## node out of the tree and are reset by the next viewWillAppear:), the five
## kernel players stopped. Kernels already falling land while covered
## (settled first, so their landing sound is cut by the stop).
func on_exit() -> void:
	_accel_on = false
	_holding = false
	kcKit.settle(_tweens)
	if _bubbler != null:
		_bubbler.restart()
	if _kernel_sounds != null:
		_kernel_sounds.stop_all()


func _tween() -> Tween:
	return kcKit.track(_tweens, create_tween())


# -- skip consumable ----------------------------------------------------

## viewDidLoad's ConsumableButton and the init's Consumable (see header).
func _build_skip() -> void:
	_skip = ConsumableScript.new(SKIP_KEY, SKIP_NAME, SKIP_COST)
	_skip.set("first_time_message", SKIP_MESSAGE)
	_skip.set("on_purchased", _on_skip_purchased)
	_skip.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buySkip"
	b.call("setup", SKIP_ART, 0, -25, SKIP_COST, 65, 3)
	b.position = SKIP_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyClick)
	add_child(b)
	# insertSubview:aboveSubview:instIV -- under the box, lid and buttons.
	var inst := outlet("instIV")
	if inst != null and inst != self:
		move_child(b, inst.get_index() + 1)
	_skip_button = b


## buyClick: -- "store" sound, purchaseConsumable.
func _on_buyClick() -> void:
	Audio.play("store")
	_skip.call("purchase", self)


## consumablePurchased: -> nextClick: (see header).
func _on_skip_purchased(_free: bool) -> void:
	_on_nextClick()


## This screen's changeInstruction: hides nextButton (read from the
## binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
