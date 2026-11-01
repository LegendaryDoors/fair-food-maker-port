# Lemon Shake Up step 5 -- pull the tank handle to pour water, then shake.
#
# GROUNDED from initFlavors (0x6B678), touchesBegan/Moved/Ended (0x6E1C8 /
# 0x6E280 with thresholds 0x6E670/0x6E678 / 0x6E67C), streamTick (0x6DB80),
# fillTick (0x6DCE0, literals 0x6DF24/0x6DF28), stopStream: (0x6D9E0),
# resetStream (0x6DB2C), shakeCup (0x6DF30, duration 0x6E1B0), stopShakeCup
# (0x6E1B8), shakeClick: (0x6CF8C), viewWillAppear: (0x6B4CC), viewDidAppear:
# (0x6B600) and nextClick: (0x6C4E4).
#
# This screen is NOT accelerometer-poured: the handle is dragged. Its
# accelerometer:didAccelerate: (0x6D7B8) is a shake detector for shakeCup,
# but no method of this class ever calls startAccelerometer -- the delegate
# is left wherever the ice screen put it -- so the shipped path to shakeCup
# is the shakeClick: button, which is also what the port uses.
#
# nextClick: composites the finished drink into the info dict StickSelect
# initWithClassStr:@"LEMON_SHAKE_UP" andInfoDict: receives; ported into
# GameState.custom_categories, the carrier msBlender's
# bake-out (0x56608) uses: "LemonShakeup" (edible, ViewIndex 5), the
# "LemonShakeupGlassBack" composite (ViewIndex 1) and "LemonShakeupGlass"
# (ViewIndex 8), all at ItemCenter (54, 180). StickSelect adds the Straw and
# hands the dict to MakeViewController, which lays the layers out by
# ViewIndex with ItemCenter as each zero-frame view's top-left.
#
# NOTE initFlavors: its first branch is not a switch in which only lemon /
# lime build the scene. The disassembly (0x6B6A0..0x6B6B6) is
# `if ([[IceView subviews] count] < 2)` -> build (every fruit, via the
# 5-way switch at 0x6B8F6), else reset.
#
# Corrected against the original code: the juice and finishedBlend are
# TintedIV's overlay bake; the water mask is applied upside down (MaskedIV);
# the pour no longer hides the instruction; the handle angle uses the
# handle frame's left edge; resetStream parks the stream ABOVE the window
# (+735 offset) so a second pour runs down into view; the completion slide
# is linear and the shake fade/legs ease in-out (both from the binary's
# curve arguments); backClick: (0x6C40C) plays button_press.
#
# Kept alive under the push; on_resume()
# runs viewWillAppear: (0x6B4CC) -> initFlavors' RESET branch and
# viewDidAppear: (0x6B600).

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

const Shared := preload("res://screens/lsuShared.gd")
const lsuSliceFruit := preload("res://screens/lsuSliceFruitViewController.gd")

# -- initFlavors (0x6B678): construction --------------------------------

## fruitJuice: TintedIV(lsu_fruit_juice, fruitColor, blend 3) -- the overlay
## bake -- top-left (-1, 0) in BackCupView (zero-frame class + setCenter:).
const JUICE_TOP_LEFT := Vector2(-1, 0)
## The two spent halves (both <prefix>half_1.png) live in IceView here.
const HALF1_CENTER := Vector2(120, 150)
const HALF2_CENTER := Vector2(76, 130)
const HALF2_ROT := 2.6179938
const HALF_SCALE := 0.5
## finishedBlend: TintedIV(lsu_mixed_juice, fruitColor, blend 3), never
## framed -- top-left (0, 0) of IceView -- alpha 0 until the shake.
## WaterPourMaskedView: MaskedIV(lsu_mixed_juice UNTINTED, lsu_cup_mask) in
## IceView, baseOrigPt (0, 273), alpha 0.8 (0x3F4CCCCD); the mask lands
## upside down, as every MaskedIV's does (lsuShared.gd).
const FILL_ORIG_Y0 := 273.0
const FILL_ALPHA := 0.8
## WaterTankView: UIImageView(lsu_water_container) frame (33, 0, 254, 205)
## -- natural size -- added to the root view, above everything.
const TANK_TOP_LEFT := Vector2(33, 0)
## CupLidView parked off right: centre (480, 76); the 212x69 art's top-left
## is therefore (374, 41.5).
const LID_PARK_CENTER := Vector2(480, 76)
## handleIV: layer anchorPoint (0, 0.5), centre (180, 136) -- the handle
## pivots about its LEFT-MIDDLE at (180, 136), so its frame is
## (180, 116, 117, 40).
const HANDLE_PIVOT := Vector2(180, 136)
const HANDLE_RECT := Rect2(180, 116, 117, 40)
## streamSV: UIScrollView (134, 194, 61, 263) in parentCupView below
## IceView, clipping four TintedIV(lsu_water_stream, nil, blend 1) tiles
## whose top-lefts sit at y = 0 / -245 / -490 / -735.
const STREAM_RECT := Rect2(134, 194, 61, 263)
const STREAM_TILE_YS := [0.0, -245.0, -490.0, -735.0]

# -- the pour ----------------------------------------------------------

## touchesMoved: (0x6E280): rot = atan((touch.y - handle.center.y) /
## (touch.x - handle.frame.origin.x)), clamped to [0, 0.7854] (0x6E678);
## pours while rot > 30 deg (0x6E670). center is the anchor (180, 136);
## frame is the rotated bounding box, whose left edge for a rotation r in
## [0, 45 deg] about the left-middle anchor is 180 - 20*sin(r).
const HANDLE_MAX_ROT := 0.7854
const POUR_ROT := 0.5235988
const HANDLE_HALF_H := 20.0
## Pour start: contentOffset animates to zero over 0.5s linear; streamTick
## and fillTick are first scheduled 0.5s out.
const STREAM_IN_SECONDS := 0.5
## streamTick (0x6DB80): every 0.5s, streamCount--, contentOffset.y
## animates to (newCount * 100) % 500 -- -100 steps, resetting at -4.
const STREAM_TICK_SECONDS := 0.5
## fillTick (0x6DCE0): every 0.1s (first at 0.5s), waterPouredCount++,
## baseOrigPt.y = (count / -50) * 253 + 253 (0x6DF24 / 0x6DF28); complete
## when the count passes 0x31 = 49.
const FILL_TICK_SECONDS := 0.1
const FILL_FIRST_DELAY := 0.5
const FILL_DIV := -50.0
const FILL_MUL := 253.0
const FILL_TICKS := 50
## stopStream: (0x6D9E0): offset snaps to -735, animates 1.0s linear to
## -980 (0xC4750000), and resetStream (0x6DB2C) hides the stream 1.01s later
## and sets the offset to +735 (0x4437C000) -- every tile above the window,
## so the next pour's 0.5s slide to offset 0 runs the water down into view.
## (The very first pour starts from the new scroll view's offset 0.)
const STREAM_OUT_FROM := 735.0
const STREAM_OUT_TO := 980.0
const STREAM_OUT_SECONDS := 1.0
const STREAM_RESET_DELAY := 1.01
const STREAM_PARKED := -735.0

# -- completion and the shake ------------------------------------------

## fillTick's completion block, 0.5s LINEAR (setAnimationCurve:3): tank
## centre -> (160,-400),
## handle anchor -> (180,-264), lid centre -> (160,226), parentCupView
## centre -> (160,200) (i.e. the full-screen cup container shifts up 40).
const TANK_EXIT_CENTER := Vector2(160, -400)
const HANDLE_EXIT := Vector2(180, -264)
const LID_ON_CENTER := Vector2(160, 226)
const CUP_UP := Vector2(0, -40)
const COMPLETE_SECONDS := 0.5

## shakeCup (0x6DF30): lsu_shake.mp3; a 5.0s fade (sugar, water fill and
## juice to 0, finishedBlend to 0.75); the cup snaps to translate (2, -20)
## and autoreverses x12 to (-2, 20) at 0.2s a leg (0x6E1B0); stopShakeCup
## (showNextButton) fires at 5.0s. Neither block sets a curve, so both use
## UIKit's default, ease-in-out.
const SHAKE_FADE_SECONDS := 5.0
const BLEND_ALPHA := 0.75
const SHAKE_OFFSET_A := Vector2(2, -20)
const SHAKE_OFFSET_B := Vector2(-2, 20)
const SHAKE_LEG_SECONDS := 0.2
const SHAKE_REPEATS := 12

var _fill: Shared.MaskedIV
var _juice: Sprite2D
var _blend: Sprite2D
var _tank: Sprite2D
var _handle_pivot: Node2D
var _stream_box: Sprite2D
var _stream_content: Node2D
var _stream_tween: Tween

var _grabbed := false
## handleRot: the model rotation, which frame.origin.x follows.
var _handle_rot := 0.0
## touchesEnded:'s 0.5 s return to upright (see _release_handle).
var _handle_tween: Tween
var _pouring := false
var _full := false
var _completed := false
var _stream_count := 0
var _fill_count := 0
var _stream_accum := 0.0
var _fill_accum := 0.0
## parentCupView's centre offset (the completion slide) and its transform
## translation (the shake) are separate properties in UIKit and compose;
## both feed the one Node2D position here.
var _cup_slide := Vector2.ZERO:
	set(v):
		_cup_slide = v
		_apply_cup()
var _cup_shake := Vector2.ZERO:
	set(v):
		_cup_shake = v
		_apply_cup()


func _apply_cup() -> void:
	var cup := _node2d("parentCupView")
	if cup != null:
		cup.position = _cup_slide + _cup_shake


func on_enter() -> void:
	_build_tableau()
	_build_tank_and_handle()
	_build_stream()
	_set_next_enabled(false)
	var shake := outlet("shakeButton")
	if shake != null and shake != self:
		shake.visible = false
	UIKit.park_instruction(self)
	set_process(true)


## viewDidAppear: (0x6B600), after the push / pop slide:
## changeInstruction:@"inst_add_water.png" -- on every appearance.
func on_did_appear() -> void:
	change_instruction("inst_add_water.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _node2d(outlet_name: String) -> Node2D:
	var n := outlet(outlet_name)
	return n if n is Node2D else null


func _build_tableau() -> void:
	var back := _node2d("BackCupView")
	if back != null:
		_juice = Sprite2D.new()
		_juice.texture = Shared.tinted_texture(_tex("lsu_fruit_juice.png"),
			lsuSliceFruit.fruit_color, Shared.BLEND_OVERLAY)
		_juice.centered = false
		_juice.position = JUICE_TOP_LEFT
		back.add_child(_juice)

	var ice := _node2d("IceView")
	if ice == null:
		return
	for cfg: Array in [[HALF1_CENTER, 0.0], [HALF2_CENTER, HALF2_ROT]]:
		var s := Sprite2D.new()
		s.texture = _tex(lsuSliceFruit.fruit_prefix + "half_1.png")
		s.centered = true
		s.position = cfg[0]
		s.rotation = cfg[1]
		s.scale = Vector2(HALF_SCALE, HALF_SCALE)
		ice.add_child(s)

	_blend = Sprite2D.new()
	_blend.texture = Shared.tinted_texture(_tex("lsu_mixed_juice.png"),
		lsuSliceFruit.fruit_color, Shared.BLEND_OVERLAY)
	_blend.centered = false
	_blend.modulate.a = 0.0
	ice.add_child(_blend)

	_fill = Shared.MaskedIV.new(
		_tex("lsu_mixed_juice.png"), _tex("lsu_cup_mask.png"))
	_fill.set_base_orig_pt(Vector2(0, FILL_ORIG_Y0))
	_fill.modulate.a = FILL_ALPHA
	ice.add_child(_fill)


func _build_tank_and_handle() -> void:
	_tank = Sprite2D.new()
	_tank.texture = _tex("lsu_water_container.png")
	_tank.centered = false
	_tank.position = TANK_TOP_LEFT
	add_child(_tank)     # added to the root view, above the nib children

	var lid := _node2d("CupLidView")
	if lid != null and lid.texture != null:
		lid.position = LID_PARK_CENTER - lid.texture.get_size() * 0.5

	# anchorPoint (0, 0.5) + center (180, 136): rotation pivots at the
	# handle's left-middle. Rebuilt as a pivot node holding the nib sprite.
	var handle := _node2d("handleIV")
	if handle != null:
		_handle_pivot = Node2D.new()
		_handle_pivot.position = HANDLE_PIVOT
		var parent := handle.get_parent()
		parent.add_child(_handle_pivot)
		parent.move_child(_handle_pivot, handle.get_index())
		parent.remove_child(handle)
		_handle_pivot.add_child(handle)
		handle.position = HANDLE_RECT.position - HANDLE_PIVOT


func _build_stream() -> void:
	var img := Image.create(int(STREAM_RECT.size.x), int(STREAM_RECT.size.y),
		false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_stream_box = Sprite2D.new()
	_stream_box.texture = ImageTexture.create_from_image(img)
	_stream_box.centered = false
	_stream_box.position = STREAM_RECT.position
	_stream_box.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	_stream_box.visible = false

	_stream_content = Node2D.new()
	_stream_box.add_child(_stream_content)
	for y: float in STREAM_TILE_YS:
		var tile := Sprite2D.new()
		tile.texture = _tex("lsu_water_stream.png")
		tile.centered = false
		tile.position = Vector2(0, y)
		_stream_content.add_child(tile)

	# insertSubview:belowSubview:IceView, in parentCupView.
	var ice := _node2d("IceView")
	if ice != null:
		ice.get_parent().add_child(_stream_box)
		ice.get_parent().move_child(_stream_box, ice.get_index())
	else:
		add_child(_stream_box)


# -- the handle --------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# touchesBegan: grab only if the touch lands in handleIV.frame.
			if HANDLE_RECT.has_point(_to_cup(event.position)) and not _completed:
				_grabbed = true
				get_viewport().set_input_as_handled()
		elif _grabbed:
			_release_handle()
	elif event is InputEventMouseMotion and _grabbed:
		_handle_moved(_to_cup(event.position))


## The handle lives in parentCupView, which never moves before completion.
func _to_cup(p: Vector2) -> Vector2:
	var cup := _node2d("parentCupView")
	return p - cup.position if cup != null else p


## touchesMoved: (0x6E280).
func _handle_moved(p: Vector2) -> void:
	var dx := p.x - (HANDLE_PIVOT.x - HANDLE_HALF_H * sin(_handle_rot))
	var dy := p.y - HANDLE_PIVOT.y
	var rot: float
	if dx != 0.0:
		rot = atan(dy / dx)
	else:
		rot = HANDLE_MAX_ROT if dy > 0.0 else 0.0   # atan(+-inf), clamped
	rot = clampf(rot, 0.0, HANDLE_MAX_ROT)
	_handle_rot = rot
	if _handle_pivot != null:
		# A re-grab during the 0.5 s return: touchesMoved:'s setTransform:
		# (outside any block) moves the MODEL, and the still-running return
		# -- a CABasicAnimation with only a fromValue -- no longer pulls the
		# handle upright under the finger. PORT CHOICE: the port drops the
		# return here and shows the model at once, where UIKit's
		# presentation would glide on to it over what is left of the 0.5 s.
		# (The port's tween used to keep rotating the handle back to 0 while
		# the player held it at a pour angle, so the juice poured from an
		# upright handle.)
		if _handle_tween != null and _handle_tween.is_valid():
			_handle_tween.kill()
		_handle_pivot.rotation = rot

	if rot > POUR_ROT:
		if not _pouring and not _stream_box.visible and not _full:
			_start_pour()
	elif _pouring:
		Audio.stop("pouring")
		_stop_stream(false)


## touchesEnded: (0x6E67C): the handle animates back upright, 0.5s linear.
## A nameless +beginAnimations: block (curve 3): touches stay on, and
## touchesBegan:'s CGRectContainsPoint(handleIV.frame) reads the MODEL frame
## -- upright already -- which HANDLE_RECT is.
func _release_handle() -> void:
	_grabbed = false
	_handle_rot = 0.0
	if _handle_pivot != null:
		if _handle_tween != null and _handle_tween.is_valid():
			_handle_tween.kill()
		_handle_tween = create_tween()
		_handle_tween.tween_property(_handle_pivot, "rotation", 0.0, 0.5) \
			.set_trans(Tween.TRANS_LINEAR)
	if _pouring:
		Audio.stop("pouring")
		_stop_stream(false)


# -- the stream and the fill -------------------------------------------

func _start_pour() -> void:
	Audio.play("lsu_water_jug")
	Audio.loop("pouring")
	_pouring = true
	_stream_count = 0
	_stream_accum = 0.0
	_fill_accum = FILL_TICK_SECONDS - FILL_FIRST_DELAY   # first tick at 0.5s
	_stream_box.visible = true
	_animate_content(0.0, STREAM_IN_SECONDS)


func _animate_content(to_y: float, seconds: float) -> void:
	if _stream_tween != null and _stream_tween.is_valid():
		_stream_tween.kill()
	_stream_tween = create_tween()
	_stream_tween.tween_property(_stream_content, "position:y", to_y, seconds) \
		.set_trans(Tween.TRANS_LINEAR)


func _process(delta: float) -> void:
	if not _pouring:
		return
	_stream_accum += delta
	while _stream_accum >= STREAM_TICK_SECONDS and _pouring:
		_stream_accum -= STREAM_TICK_SECONDS
		_stream_tick()
	_fill_accum += delta
	while _fill_accum >= FILL_TICK_SECONDS and _pouring:
		_fill_accum -= FILL_TICK_SECONDS
		_fill_tick()


## streamTick (0x6DB80). contentOffset.y steps -100 each half second and
## snaps back after four steps; content position is the offset negated.
func _stream_tick() -> void:
	if _stream_count == -4:
		_stream_content.position.y = 0.0
		_stream_count = 0
	_stream_count -= 1
	var offset := (_stream_count * 100) % 500     # -100 .. -400
	_animate_content(float(-offset), STREAM_TICK_SECONDS)


## fillTick (0x6DCE0).
func _fill_tick() -> void:
	_fill_count += 1
	_fill.set_base_orig_pt(Vector2(0,
		(float(_fill_count) / FILL_DIV) * FILL_MUL + FILL_MUL))
	if _fill_count > FILL_TICKS - 1:
		_complete_pour()


## stopStream: (0x6D9E0): the stream tail falls through the window, then
## resetStream (0x6DB2C) hides it and zeroes the offset.
func _stop_stream(full: bool) -> void:
	_full = full or _full
	_pouring = false
	_stream_content.position.y = STREAM_OUT_FROM
	_animate_content(STREAM_OUT_TO, STREAM_OUT_SECONDS)
	get_tree().create_timer(STREAM_RESET_DELAY).timeout.connect(func() -> void:
		if not is_instance_valid(_stream_box) or _pouring:
			return
		_stream_box.visible = false
		if _stream_tween != null and _stream_tween.is_valid():
			_stream_tween.kill()
		_stream_content.position.y = STREAM_PARKED)


## fillTick's completion branch.
func _complete_pour() -> void:
	_completed = true
	Audio.stop("pouring")
	_stop_stream(true)

	var t := create_tween().set_trans(Tween.TRANS_LINEAR)
	if _tank != null and _tank.texture != null:
		t.tween_property(_tank, "position",
			TANK_EXIT_CENTER - _tank.texture.get_size() * 0.5, COMPLETE_SECONDS)
	if _handle_pivot != null:
		t.parallel().tween_property(_handle_pivot, "position", HANDLE_EXIT,
			COMPLETE_SECONDS)
	var lid := _node2d("CupLidView")
	if lid != null and lid.texture != null:
		t.parallel().tween_property(lid, "position",
			LID_ON_CENTER - lid.texture.get_size() * 0.5, COMPLETE_SECONDS)
	t.parallel().tween_property(self, "_cup_slide", CUP_UP, COMPLETE_SECONDS)

	dismiss_instruction()
	var shake := outlet("shakeButton")
	if shake != null and shake != self:
		shake.visible = true
		shake.set("disabled", false)


# -- the shake ---------------------------------------------------------

## shakeClick: (0x6CF8C).
func _on_shakeClick() -> void:
	if not _completed:
		return
	var shake := outlet("shakeButton")
	if shake != null and shake != self:
		shake.visible = false
	_shake_cup()


## shakeCup (0x6DF30).
func _shake_cup() -> void:
	Audio.play("lsu_shake")

	var fade := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var sugar := _node2d("SugarView")
	if sugar != null:
		fade.tween_property(sugar, "modulate:a", 0.0, SHAKE_FADE_SECONDS)
	if _fill != null:
		fade.parallel().tween_property(_fill, "modulate:a", 0.0, SHAKE_FADE_SECONDS)
	if _juice != null:
		fade.parallel().tween_property(_juice, "modulate:a", 0.0, SHAKE_FADE_SECONDS)
	if _blend != null:
		fade.parallel().tween_property(_blend, "modulate:a", BLEND_ALPHA,
			SHAKE_FADE_SECONDS)

	_cup_shake = SHAKE_OFFSET_A
	var t := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	for i in SHAKE_REPEATS:
		t.tween_property(self, "_cup_shake", SHAKE_OFFSET_B, SHAKE_LEG_SECONDS)
		t.tween_property(self, "_cup_shake", SHAKE_OFFSET_A, SHAKE_LEG_SECONDS)
	# UIKit leaves the model at the animated target.
	t.tween_callback(func() -> void: _cup_shake = SHAKE_OFFSET_B)

	# performSelector:stopShakeCup afterDelay:5.0 -> showNextButton.
	get_tree().create_timer(SHAKE_FADE_SECONDS).timeout.connect(func() -> void:
		if is_inside_tree():
			show_next_button()
			_set_next_enabled(true))


func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.disabled = not on


# -- the bake-out: nextClick: (0x6C4E4) --------------------------------

## Every entry: Type "Stationary", ItemCenterX 54 (0x42580000), ItemCenterY
## 180 (0x43340000).
const BAKE_CENTER := Vector2(54, 180)
const VIEW_INDEX_SHAKEUP := 5
const VIEW_INDEX_GLASS_BACK := 1
const VIEW_INDEX_GLASS := 8


## button_press, stopAccelerometer, then the three layers (lsuShared.gd has
## the compositing) and StickSelect initWithClassStr:@"LEMON_SHAKE_UP"
## andInfoDict:. No sugar and no lid travel on: the dict carries only these.
func _on_nextClick() -> void:
	Audio.play("button_press")
	var color: Color = lsuSliceFruit.fruit_color
	var prefix: String = lsuSliceFruit.fruit_prefix
	GameState.custom_categories = {
		"LemonShakeup": _bake_entry(Shared.bake_shakeup(color), true,
			VIEW_INDEX_SHAKEUP),
		"LemonShakeupGlassBack": _bake_entry(Shared.bake_glass_back(prefix), false,
			VIEW_INDEX_GLASS_BACK),
		"LemonShakeupGlass": _bake_entry(_tex("lsu_cup_Front.png"), false,
			VIEW_INDEX_GLASS),
	}
	Nav.next()


func _bake_entry(image: Variant, edible: bool, view_index: int) -> Dictionary:
	return {
		"Properties": {
			"IsEdible": edible,
			"ViewIndex": view_index,
			"Type": "Stationary",
			"ItemCenterX": BAKE_CENTER.x,
			"ItemCenterY": BAKE_CENTER.y,
		},
		"Image": image,
	}


## backClick: (0x6C40C): button_press, stop "pouring", stopStream:NO, cancel
## the pending ticks, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Audio.stop("pouring")
	Nav.back()


## viewWillDisappear: (0x6B64C) only calls super. Next is only offered after
## the shake, when nothing is pouring; back stops the pour itself. Kept as a
## guard -- nothing visible changes.
func on_exit() -> void:
	Audio.stop("pouring")


## UINavigationController keeps this controller alive under StickSelect
## (nextClick: pushes), so back shows the same instance (Nav.gd opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from StickSelect. viewWillAppear: (0x6B4CC) -> initFlavors
## (0x6B678): IceView already has its subviews (cmp r0,#2 / blo at
## 0x6B6B4), so the RESET branch runs: SugarView alpha 1, the water fill
## alpha 1 -- NOT the 0.8 it was built with (mov.w r2,#0x3f800000 at
## 0x6B6F6; kept as read) -- and baseOrigPt (0,273), fruitJuice alpha 1,
## finishedBlend alpha 0, WaterTankView back at (33,0,254,205) and unhidden,
## waterPouredCount 0, hasPouredSugar and isIceeFull NO, CupLidView centre
## (480,76), handleIV anchor (0,0.5) centre (180,136), parentCupView
## transform identity and centre (160,240), nextButton hidden. Then
## shakeButton hidden; viewDidAppear: (0x6B600) changeInstruction:
## @"inst_add_water.png". The stream keeps the parked offset resetStream left.
## The water is poured and the cup shaken again.
func on_resume() -> void:
	var sugar := _node2d("SugarView")
	if sugar != null:
		sugar.modulate.a = 1.0
	if _fill != null:
		_fill.modulate.a = 1.0
		_fill.set_base_orig_pt(Vector2(0, FILL_ORIG_Y0))
	if _juice != null:
		_juice.modulate.a = 1.0
	if _blend != null:
		_blend.modulate.a = 0.0
	if _tank != null:
		_tank.position = TANK_TOP_LEFT
		_tank.visible = true
	_fill_count = 0
	_completed = false
	_full = false
	_pouring = false
	_grabbed = false
	var lid := _node2d("CupLidView")
	if lid != null and lid.texture != null:
		lid.position = LID_PARK_CENTER - lid.texture.get_size() * 0.5
	if _handle_pivot != null:
		_handle_pivot.position = HANDLE_PIVOT
	_cup_shake = Vector2.ZERO
	_cup_slide = Vector2.ZERO
	_set_next_enabled(false)
	var shake := outlet("shakeButton")
	if shake != null and shake != self:
		shake.visible = false
	# viewDidAppear:'s changeInstruction: runs in on_did_appear().
