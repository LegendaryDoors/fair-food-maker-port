# Funnel Cake step 5 -- drag the funnel over the oil, drawing the cake.
#
# GROUNDED from initWithBatterID: (0x9E550), viewDidLoad (0x9E5D4),
# viewWillAppear: (0x9EE84), viewDidAppear: (0x9F06C), resetClick: (0x9F348),
# bubbleTickForIndex: (0x9FD80), draggableTouchBegan/Moved/Ended (0xA0394 /
# 0xA05DC / 0xA0DBC), nextClick: (0x9F5D4), slideView:toPoint:overDuration:
# (0x9FCD0) and fcCakeView initWithFrame:andBrushImage: (0xD5F5C),
# addCakeAtPt: (0xD60A0), clearView (0xD6338), drawRect: (0xD606C),
# +distanceBetweenPt:andPt: (0xD5F2C, from the disassembly: plain hypot).
# Read from the original binary.
#
# Mechanic, as read -- a FREE-DRAWING screen, not a pour: the funnel is a
# DraggableIV whose delegate re-centres it to the (clamped) touch point, and
# every touch-move stamps brush_*.png into an offscreen image at
# funnel.center + (-2, +80) while draining batterAmt by 0.0025 per event
# (bits 0xBB23D70A, 0xA05DC). When the batter runs out the funnel's batter
# sprite hides, a black silhouette of the drawn cake fades to alpha 0.2 over
# 3.0s ("DarkenCake" -- the fry browning) and showNextButton fires 3.0s later.
# nextClick: hands fcSiftSugarVC the RAW drawn image (cakeView.cakeImg) --
# the darkening overlay never reaches the hand-off. Original quirk, kept.
#
# LAYOUT: the scene is generated from the nib. It was once blank (the Python
# nib converter walked only the widest view's UISubviews, and this nib keeps
# its views as top-level siblings), so this screen built everything in code
# meanwhile. The scene now carries bg_funnel_cake (0,0,320,480), fc_fryer
# (0,0,320,391), oilIV = fc_oil (23,51,275,275), resetBtn (0,347,94,63),
# backBtn (0,417,94,63), nextBtn (226,415,94,63) and instIV (102,416,218,59)
# (all UIImageView / UIButton, so true frames), and the nib bindings wire
# resetClick: / backClick: / nextClick: to the buttons. Extraction gaps are
# compensated in _fix_extraction_gaps (fcSiftSugarVC precedent):
#   * the three buttons carry btn_new_design / btn_back / btn_next as
#     UIButton background images; the nib converter once dropped those and
#     now emits them, so the texture assignment is only a fallback;
#   * instIV has no image in the nib (changeInstruction: supplies it), so the
#     generator emitted a bare, centred Sprite2D with no frame size.
# What viewDidLoad builds -- cake canvas, bubbles, funnel -- is still built
# here, parented under the nib's root view so insertion order matches: bubbles
# directly above oilIV, the cake canvas above the bubbles, the funnel below the
# chrome (the previous read of 0x9E5D4; unchanged by the regeneration).
#
# DRAIN RATE, read end to end. Everything between the finger and batterAmt:
#   * DraggableIV touchesBegan: (0x464F4) stores touchOffset and forwards to
#     the delegate; touchesMoved: (0x46614) recentres by touch + touchOffset
#     (min/max default to INT_MIN/INT_MAX -- no clamp) and forwards EVERY
#     move to draggableTouchMoved:fromSender: -- no distance threshold, no
#     timer, no filtering; touchesEnded: (0x46860) snapTime is 0, so no snap.
#   * draggableTouchMoved: (0xA05DC): its only guard is sender == funnelIV.
#     It recentres the funnel on the touch clamped to oilDetectFrame, so the
#     funnel is always "over the oil"; then batterAmt += -0.0025 (bits
#     0xBB23D70A) UNCONDITIONALLY -- no minimum move, no timer, no spawn
#     rate. While batterAmt > 0 it squashes batterIV and calls addCakeAtPt:.
#   * fcCakeView addCakeAtPt: (0xD60A0) only draws: a 1 px-spaced line of
#     shadowed alpha-0.5 brush stamps from lastBrushPt. It never touches
#     batterAmt and has no early-out.
#   * The end: the first move with batterAmt <= 0 (the 401st, float32) hides
#     batterIV, starts DarkenCake and schedules showNextButton. Nothing else
#     reads batterAmt; bubbleTickForIndex: (0x9FD80) is cosmetic.
# So the per-move step is the ONLY rate limiter in the code, and the port
# matches it at <= 60 counted moves/s (accept_touch_move): >= 6.7 s of
# continuous dragging to empty. If the phone is slower, it delivers fewer
# touchesMoved: than 60/s on this screen. INFERRED, not measured: every move
# here rebuilds a 275x275 bitmap context, redraws the whole cake, stamps one
# shadowed brush per pixel travelled and redisplays the view, all on the main
# thread of an A4; UIKit coalesces moves while the main thread is busy. Only
# a device measurement can turn that into a number (time a full continuous
# pour on the phone: rate = 401 / seconds).
#
# QUIRK, kept: viewWillAppear: calls resetClick: (0x9EE84), and resetClick:
# unconditionally plays button_press -- so entering the screen clicks.
#
# Not ported: buyAllBtn (IAP, suppressed) and backClick: 0x9F294's own sound
# stops, which on_exit covers.

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

## initWithBatterID: (0x9E550): the funnel centre's clamp region.
const OIL_DETECT := Rect2(46, -10, 240, 240)
## Nib: oilIV = fc_oil.png at (23, 51, 275, 275); centre (160.5, 188.5).
const OIL_RECT := Rect2(23, 51, 275, 275)
## Nib: instIV frame. The banner art is 220x60 and UIImageView scales it in.
const INST_FRAME := Rect2(102, 416, 218, 59)
## Nib UIButtonContent art the extractor drops (header).
const BUTTON_ART := {"backBtn": "btn_back.png", "resetBtn": "btn_new_design.png",
	"nextBtn": "btn_next.png"}
## viewDidLoad (0x9E5D4): funnel DraggableIV frame 500x500 (0x43FA0000),
## contentMode 4 = center, art fc_funnel_top.png at natural size.
const FUNNEL_HIT := Vector2(500, 500)
## batterIV: fc_batter_*_for_Funnel_Top in a (0,0,105,67) frame
## (0x42D20000/0x42860000), centre = funnel.frame.size/2 + (-8,-8).
const BATTER_FRAME_SIZE := Vector2(105, 67)
const BATTER_OFFSET := Vector2(-8, -8)
## draggableTouchMoved: (0xA05DC): batter drains 0.0025 per move event; the
## batter sprite's transform is translate(0, (1-amt)*35) then scale(amt).
const BATTER_STEP := 0.0025
const BATTER_DROP := 35.0
## Brush stamp point: funnel.center + (-2, 80) (0xA05DC).
const DRAW_OFFSET := Vector2(-2, 80)
## addCakeAtPt: (0xD60A0): the stamp's top-left is pt - (brushW, brushH*0.5)
## -- the FULL width but only HALF the height. Original quirk, kept.
## Stamps draw at alpha 0.5 with a (2,2) blur-0 shadow (CG default shadow:
## black at 1/3 alpha).
const STAMP_ALPHA := 0.5
const SHADOW_OFFSET := Vector2i(2, 2)
const SHADOW_ALPHA := 1.0 / 3.0
## The darken overlay: TintedIV(cakeImg, black, multiply) fading 0 -> 0.2
## over 3.0s linear; showNextButton 3.0s after the batter runs out (0xA05DC).
const DARKEN_ALPHA := 0.2
const DARKEN_SECONDS := 3.0
const NEXT_DELAY := 3.0
## viewDidAppear: (0x9F06C): funnel slides in from +500 x over 0.25s
## (slideView:toPoint:overDuration: 0x9FCD0, bits 0x3E800000).
const SLIDE_IN := 0.25
## viewDidLoad: 16 bubbles, SpriteSheetView frame 62x62 (0x42780000) over the
## 248x68 strip (cells 62x68, the bottom 6px clipped), transform scale 0.5.
const BUBBLE_COUNT := 16
const BUBBLE_CELL := Vector2(62, 62)
const BUBBLE_SCALE := 0.5
## bubbleTickForIndex: (0x9FD80): spawn at oil.origin + 25 + rand % (size-50)
## per axis; tick every 0.1s; after a full 4-frame cycle hide and reschedule
## in (rand % 25)/100 + 0.1 s. Initial delay (rand % 100)/100 (0x9E5D4).
const BUBBLE_INSET := 25.0
const BUBBLE_SHRINK := 50.0
const BUBBLE_TICK := 0.1
## frying_hi_loop plays at volume 0.5 while dragging (0xA0394).
const FRY_HI_DB := -6.0206  # linear 0.5

const BRUSH := {0: "brush_Original.png", 1: "brush_Strawberry.png",
	2: "brush_Caramel.png", 3: "brush_Chocolate.png"}
const BATTER_TOP_ART := {0: "fc_batter_original_for_Funnel_Top.png",
	1: "fc_batter_strawberry_for_Funnel_Top.png",
	2: "fc_batter_caramel_for_Funnel_Top.png",
	3: "fc_batter_choc_for_Funnel_Top.png"}

var _batter := 0
var _view: Node2D                 # the nib's root view; code-built nodes go here
var _funnel: Node2D
var _batter_iv: Sprite2D
var _batter_base_scale := Vector2.ONE
var _cake_node: Sprite2D          # cakeView: top-left (23,51), 275x275
var _cake_img: Image              # cakeImg, rebuilt per stamp
var _cake_tex: ImageTexture
var _has_cake := false            # cakeImg == nil until the first stamp
var _last_brush := Vector2.ZERO   # lastBrushPt; (0,0) means "none yet"
var _brush: Image                 # brush at STAMP_ALPHA
var _brush_shadow: Image          # black silhouette for the (2,2) shadow
var _darken: Sprite2D
var _batter_amt := 1.0
var _dragging := false
var _next_pending_gen := 0        # cancels a scheduled showNextButton
var _next_btn: TextureButton
var _bubbles: Array[Sprite2D] = []
var _bubble_frame: Array[int] = []
var _funnel_tween: Tween


func on_enter() -> void:
	_batter = int(GameState.custom_categories.get("batter", 0))
	var v := outlet("view")
	_view = v as Node2D if v is Node2D else self
	_fix_extraction_gaps()
	_build_cake()
	_build_funnel()
	_build_bubbles()
	_view_will_appear()
	UIKit.park_instruction(self)


## viewDidAppear: runs when the push / pop slide is over: the banner
## and the funnel's slide-in start after the slide, as on the phone.
func on_did_appear() -> void:
	_view_did_appear()


## UINavigationController keeps this controller alive under fcSift (Nav.gd's
## opt-in). fcFryBatterVC has no viewWillDisappear:/viewDidDisappear:, so
## nothing stops on push -- the bubble performSelector: chain keeps running
## while covered (the port keeps it running too, see _bubble_tick). On back
## viewWillAppear: + viewDidAppear: run again and RESET the step through
## resetClick: -- the drawn cake is cleared and the funnel refilled.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	_dragging = false
	_view_will_appear()
	# _view_did_appear() follows from on_did_appear(), after the pop slide.


## viewWillAppear: (0x9EE84): resetClick (with its click sound -- quirk),
## frying_lo_loop, funnel hidden, instIV shown, next hidden.
func _view_will_appear() -> void:
	_on_resetClick()
	Audio.loop("frying_lo_loop")
	_funnel.visible = false
	_next_btn.visible = false


## viewDidAppear: (0x9F06C): instruction, then the funnel appears offset
## +500 x from the oil centre and slides in over 0.25s.
func _view_did_appear() -> void:
	change_instruction("inst_funnel_batter.png")
	var home := OIL_RECT.get_center()
	_funnel.position = home + Vector2(500, 0)
	_funnel.visible = true
	if _funnel_tween != null and _funnel_tween.is_valid():
		_funnel_tween.kill()
	_funnel_tween = create_tween()
	_funnel_tween.tween_property(_funnel, "position", home, SLIDE_IN) \
		.set_trans(Tween.TRANS_LINEAR)


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## The two extraction gaps (header): button art, and instIV's anchor + frame.
func _fix_extraction_gaps() -> void:
	for outlet_name: String in BUTTON_ART:
		var b := outlet(outlet_name)
		if b is TextureButton and (b as TextureButton).texture_normal == null:
			var tb := b as TextureButton
			tb.texture_normal = _tex(BUTTON_ART[outlet_name])
			tb.ignore_texture_size = true
			tb.stretch_mode = TextureButton.STRETCH_SCALE
	_next_btn = outlet("nextBtn") as TextureButton
	if _next_btn == null:
		push_error("fcFryBatterVC: no nextBtn outlet -- scene not regenerated?")
	var inst := outlet("instIV")
	if inst is Sprite2D:
		var s := inst as Sprite2D
		s.centered = false
		var t := _tex("inst_funnel_batter.png")
		if t != null:
			s.scale = INST_FRAME.size / Vector2(t.get_size())


## fcCakeView: a clear 275x275 canvas centred on the oil pan, above the oil
## and the bubbles, below the funnel (viewDidLoad insertion order).
func _build_cake() -> void:
	_cake_img = Image.create(int(OIL_RECT.size.x), int(OIL_RECT.size.y),
		false, Image.FORMAT_RGBA8)
	_cake_tex = ImageTexture.create_from_image(_cake_img)
	_cake_node = Sprite2D.new()
	_cake_node.texture = _cake_tex
	_cake_node.centered = false
	_cake_node.position = OIL_RECT.position
	_view.add_child(_cake_node)
	var oil := outlet("oilIV")
	if oil != null and oil.get_parent() == _view:
		_view.move_child(_cake_node, oil.get_index() + 1)

	var brush_tex := _tex(BRUSH.get(_batter, BRUSH[0]))
	if brush_tex != null:
		var src := brush_tex.get_image()
		if src.is_compressed():
			src.decompress()
		src.convert(Image.FORMAT_RGBA8)
		_brush = Image.create(src.get_width(), src.get_height(), false,
			Image.FORMAT_RGBA8)
		_brush_shadow = Image.create(src.get_width(), src.get_height(),
			false, Image.FORMAT_RGBA8)
		for y in src.get_height():
			for x in src.get_width():
				var c := src.get_pixel(x, y)
				_brush.set_pixel(x, y,
					Color(c.r, c.g, c.b, c.a * STAMP_ALPHA))
				_brush_shadow.set_pixel(x, y,
					Color(0, 0, 0, c.a * STAMP_ALPHA * SHADOW_ALPHA))


## The funnel: fc_funnel_top.png at natural size, centred in a 500x500 hit
## frame, with the batter sprite riding at (-8,-8) from its centre. Sits
## below the chrome, which the nib lists after the gameplay views.
func _build_funnel() -> void:
	_funnel = Node2D.new()
	_view.add_child(_funnel)
	var chrome := outlet("backBtn")
	if chrome != null and chrome.get_parent() == _view:
		_view.move_child(_funnel, chrome.get_index())
	var art := Sprite2D.new()
	art.texture = _tex("fc_funnel_top.png")
	_funnel.add_child(art)

	_batter_iv = Sprite2D.new()
	var btex := _tex(BATTER_TOP_ART.get(_batter, BATTER_TOP_ART[0]))
	_batter_iv.texture = btex
	if btex != null:
		# UIImageView scaleToFill into the (0,0,105,67) frame.
		_batter_base_scale = BATTER_FRAME_SIZE / Vector2(btex.get_size())
	_batter_iv.position = BATTER_OFFSET
	_batter_iv.scale = _batter_base_scale
	# addSubview (0x9E5D4) puts the batter ON TOP of the funnel art.
	_funnel.add_child(_batter_iv)


# -- bubbles (0x9E5D4 + 0x9FD80) --------------------------------------

func _build_bubbles() -> void:
	var strip := _tex("fc_fry_bubble1-4.png")
	if strip == null:
		return
	# Insert below the cake canvas, above the oil (insertSubview:aboveSubview:
	# oilIV for each bubble, after the cakeView insertion).
	var cake_index := _cake_node.get_index()
	for i in BUBBLE_COUNT:
		var atlas := AtlasTexture.new()
		atlas.atlas = strip
		atlas.region = Rect2(Vector2.ZERO, BUBBLE_CELL)
		var b := Sprite2D.new()
		b.texture = atlas
		b.scale = Vector2(BUBBLE_SCALE, BUBBLE_SCALE)
		b.visible = false
		_view.add_child(b)
		_view.move_child(b, cake_index)
		_bubbles.append(b)
		_bubble_frame.append(0)
		get_tree().create_timer(float(randi() % 100) / 100.0) \
			.timeout.connect(_bubble_tick.bind(i))


func _bubble_tick(i: int) -> void:
	# bubbleTickForIndex: (0x9FD80) re-performs itself with no cancel and no
	# appearance test, so the bubbles keep cycling while fcSift covers this
	# screen. The chain therefore runs off the main SceneTree, not get_tree()
	# (null out of the tree); freeing the screen drops the connection.
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var b := _bubbles[i]
	var delay := BUBBLE_TICK
	if not b.visible:
		b.position = OIL_RECT.position + Vector2(BUBBLE_INSET, BUBBLE_INSET) \
			+ Vector2(
				float(randi() % int(OIL_RECT.size.x - BUBBLE_SHRINK)),
				float(randi() % int(OIL_RECT.size.y - BUBBLE_SHRINK)))
		b.visible = true
	else:
		# SpriteSheetView tick: show currentFrameIdx, then increment.
		var f := _bubble_frame[i]
		(b.texture as AtlasTexture).region = \
			Rect2(Vector2(BUBBLE_CELL.x * f, 0), BUBBLE_CELL)
		_bubble_frame[i] = (f + 1) % 4
		if _bubble_frame[i] == 0:
			b.visible = false
			delay = float(randi() % 25) / 100.0 + BUBBLE_TICK
	tree.create_timer(delay).timeout.connect(_bubble_tick.bind(i))


# -- the drag + draw (0xA0394 / 0xA05DC / 0xA0DBC) --------------------

func _unhandled_input(event: InputEvent) -> void:
	if _funnel == null or not _funnel.visible:
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and not _dragging and _funnel_hit(mb.position):
			_dragging = true
			# The touch takes over from the slide-in: touchBegan's setCenter:
			# moves the model, so the funnel stays with the finger.
			if _funnel_tween != null and _funnel_tween.is_valid():
				_funnel_tween.kill()
			# touchBegan (0xA0394): funnel centre = the clamped touch point,
			# frying_hi_loop at volume 0.5.
			_funnel.position = _clamp_to_oil(mb.position)
			Audio.loop("frying_hi_loop", FRY_HI_DB)
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			# touchEnded (0xA0DBC): stop frying_hi_loop, clamp once more.
			Audio.stop("frying_hi_loop")
			_funnel.position = _clamp_to_oil(_funnel.position)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		# iOS delivered touchesMoved: at most once per frame (60 Hz); see
		# Screen.accept_touch_move. Without it the funnel cake mix and drain
		# ran far too fast on a high-refresh monitor.
		if not accept_touch_move():
			get_viewport().set_input_as_handled()
			return
		_move_funnel((event as InputEventMouseMotion).position)
		get_viewport().set_input_as_handled()


## The slide-in is +beginAnimations:"SlideView" (slideView:toPoint:
## overDuration: 0x9FCD0, 0.25 s linear), which leaves the funnel touchable
## (0x3307B220) and hit-tested at its MODEL centre -- the oil centre from
## the moment the slide commits, not the drawn spot sliding in from +500.
## The port used to hit-test the drawn funnel and let the slide run on under
## the finger, carrying the funnel off the drawing point until the next
## move.
func _funnel_hit(p: Vector2) -> bool:
	var c := _funnel.position
	if _funnel_tween != null and _funnel_tween.is_valid() \
			and _funnel_tween.is_running():
		c = OIL_RECT.get_center()
	return Rect2(c - FUNNEL_HIT * 0.5, FUNNEL_HIT).has_point(p)


func _clamp_to_oil(p: Vector2) -> Vector2:
	return Vector2(
		clampf(p.x, OIL_DETECT.position.x, OIL_DETECT.end.x),
		clampf(p.y, OIL_DETECT.position.y, OIL_DETECT.end.y))


## draggableTouchMoved: (0xA05DC): clamp, drain, squash the batter sprite,
## stamp; or -- once the batter is gone -- start the darken + next timer.
func _move_funnel(touch: Vector2) -> void:
	_funnel.position = _clamp_to_oil(touch)
	_batter_amt -= BATTER_STEP
	if _batter_amt > 0.0:
		_batter_iv.position = BATTER_OFFSET \
			+ Vector2(0, (1.0 - _batter_amt) * BATTER_DROP)
		_batter_iv.scale = _batter_base_scale * _batter_amt
		_stamp_line(_funnel.position + DRAW_OFFSET - OIL_RECT.position)
	elif _batter_iv.visible:
		_batter_iv.visible = false
		_start_darken()


## addCakeAtPt: (0xD60A0): interpolated stamps from lastBrushPt, each with a
## (2,2) shadow, alpha 0.5, into the persistent cake image.
func _stamp_line(pt: Vector2) -> void:
	if _brush == null:
		return
	var draw := pt - Vector2(_brush.get_width(), _brush.get_height() * 0.5)
	if not _has_cake or _last_brush == Vector2.ZERO:
		_stamp(draw)
	else:
		var dist := int(_last_brush.distance_to(draw))
		if dist < 1:
			_stamp(draw)
		else:
			var delta := draw - _last_brush
			for i in range(1, dist + 1):
				_stamp(_last_brush + delta * (float(i) / float(dist)))
			_stamp(draw)
	_last_brush = draw
	_has_cake = true
	_cake_tex.update(_cake_img)


func _stamp(top_left: Vector2) -> void:
	var full := Rect2i(Vector2i.ZERO, _brush.get_size())
	_cake_img.blend_rect(_brush_shadow, full,
		Vector2i(top_left.round()) + SHADOW_OFFSET)
	_cake_img.blend_rect(_brush, full, Vector2i(top_left.round()))


## Batter exhausted: black silhouette of the drawn cake fades in to 0.2 over
## 3.0s linear ("DarkenCake"), showNextButton after 3.0s. Both cancellable by
## resetClick: (cancelPreviousPerformRequests / subview removal).
func _start_darken() -> void:
	var dark_img := _cake_img.duplicate() as Image
	for y in dark_img.get_height():
		for x in dark_img.get_width():
			var a := dark_img.get_pixel(x, y).a
			dark_img.set_pixel(x, y, Color(0, 0, 0, a))
	_darken = Sprite2D.new()
	_darken.texture = ImageTexture.create_from_image(dark_img)
	_darken.centered = false
	_darken.modulate.a = 0.0
	_cake_node.add_child(_darken)
	create_tween().tween_property(_darken, "modulate:a", DARKEN_ALPHA,
		DARKEN_SECONDS).set_trans(Tween.TRANS_LINEAR)

	_next_pending_gen += 1
	var gen := _next_pending_gen
	get_tree().create_timer(NEXT_DELAY).timeout.connect(func() -> void:
		if is_inside_tree() and gen == _next_pending_gen:
			show_next_button())


# -- buttons (wired to the nib's buttons by the nib bindings) ------------

## resetClick: (0x9F348): sound, hide next + instruction back, cancel the
## pending showNextButton, funnel to the oil centre, batter restored,
## cake cleared (clearView 0xD6338 + subview removal).
func _on_resetClick() -> void:
	Audio.play("button_press")
	if _next_btn != null and _next_btn.visible:
		_next_btn.visible = false
		change_instruction("inst_funnel_batter.png")
	_next_pending_gen += 1
	_funnel.position = OIL_RECT.get_center()
	_batter_iv.visible = true
	_batter_iv.position = BATTER_OFFSET
	_batter_iv.scale = _batter_base_scale
	if _darken != null and is_instance_valid(_darken):
		_darken.queue_free()
		_darken = null
	_cake_img.fill(Color(0, 0, 0, 0))
	_cake_tex.update(_cake_img)
	_has_cake = false
	_last_brush = Vector2.ZERO
	_batter_amt = 1.0


## nextClick: (0x9F5D4): button_press, stop both frying loops, push
## fcSiftSugarVC initWithImage:cakeView.cakeImg batterID: -- the RAW drawn
## image, without the darkening overlay.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Audio.stop("frying_hi_loop")
	Audio.stop("frying_lo_loop")
	# initWithImage:batterID: -- built from this controller's own state, not
	# by copying the carrier, which holds a later screen's dict when this
	# step is next-ed again after a back (keeps_state_on_push).
	var info: Dictionary = {"batter": _batter}
	info["cakeImg"] = ImageTexture.create_from_image(_cake_img)
	GameState.custom_categories = info
	Nav.next()


func _on_backClick() -> void:
	# backClick: (0x9F294): button_press, stop frying_lo_loop and
	# frying_hi_loop, pop.
	Audio.play("button_press")
	Audio.stop("frying_lo_loop")
	Audio.stop("frying_hi_loop")
	Nav.back()


## fcFryBatterVC defines no viewWillDisappear:/viewDidDisappear:. The
## frying loops are stopped by nextClick:/backClick:, the only ways off this
## screen; stopping them here too is a PORT CHOICE safety net that changes
## nothing on those paths. The step's state is left for the return.
func on_exit() -> void:
	_dragging = false
	Audio.stop("frying_hi_loop")
	Audio.stop("frying_lo_loop")
