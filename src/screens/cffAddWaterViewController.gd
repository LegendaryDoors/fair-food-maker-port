# Curly Fries step 3 -- tilt the bottle to pour water over the slices, then
# press SOAK and wait for the starch to cloud the water.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithInfoDict: 0x13D608, viewDidLoad 0x13D63C, viewWillAppear:
#   0x13DDF0, viewWillDisappear: 0x13E49C, bubbleTick 0x13E594, kernelTick
#   0x13E834, soakTick 0x13E968, animationDidStop: 0x13EA34,
#   accelerometer:didAccelerate: 0x13EE10, startAccelerometer 0x13F258
#   (delegate + 1/30s -- live: scheduled 0.5s after viewWillAppear),
#   soakButtonClick: 0x13F5E0, nextClick: 0x13F7D4. changeInstruction:
#   0x13EAA0 / showNextButton 0x13ECA8 are the standard +500/0.25s slide.
#
# Mechanic, as read -- a REAL tilt pour (same shape as kcPourOil, different
# constants): filtered accel x * 6 drives the bottle's rotation, clamped to
# [-2.1817, -0.2618]; water pours while the angle is <= -2.0943951 AND
# pourTime < 3.0. The stream is a plain UIImageView whose FRAME ORIGIN
# (top-left) is pinned to spoutTop = bottle.centre + (sin(a)*115 + 23,
# cos(a)*(-45) - 2) each update. The "fill" is an ALPHA RAMP, not a mask
# move: kernelTick (0.1s) adds 0.1 to pourTime and sets the water layer's
# alpha to pourTime * 0.25 (0.75 at the full 3.0s). viewWillAppear writes
# baseOrigPt (x,135) and then immediately (x,0) -- the 135 is a dead store,
# ported as the final (x,0).
#
# PORT CHOICE: the tilt becomes press-and-hold on the bottle. Held, it
# rotates to the clamp bottom -2.1817 (0x13EE10) -- past the -2.0943951 pour
# threshold -- and back to the rest clamp -0.2618 on release. Only the 0.35s
# tilt time is a port choice (kcPourOil precedent); every tick count, clamp
# and alpha step is the original's. The original's 0.5s startAccelerometer
# delay is kept as an arming delay.
#
# Soak: the button (btn_next art at the next button's frame -- as shipped)
# starts a 0.25s soakTick that adds 0.06 to `count` and mirrors it into the
# starch layer's alpha and the bubbles container's alpha; count >= 0.8 (14
# ticks, 3.5s) shows next. bubbleTick (0.4s, from entry) has a 30% chance
# (arc4random()%100 <= 29) of spawning bubble.png in the bubbles view:
# alpha 0.6, scale 0.1, centre (rand%160, 135 - h/2), animated 2.0s ease-in
# to scale 0.6 / centre-y 45, removed on completion (0x13EA34).
#
# The three bowl layers are MaskedIVs, so their masks apply upside down
# (drawRect: 0x46E68; see cffSelectSlicer.MaskedIV). The flipped
# cff_bowl_Mask is an ellipse over rows ~36-132, which is exactly where
# cff_water_layer / cff_starch_layer carry their art at baseOrigPt (x,0) --
# upright it would clip the water's top 24 rows. Corroborates the flip.
#
# Z-order, as built: the piles are addSubview:ed above every nib view
# (potato below water below starch), the skip badge after them, then
# viewWillAppear brings the stream and then the bottle to the front.
#
# Before startAccelerometer (0.5s) the bottle has no transform -- upright --
# and slides in from x+300 to (204,85) over 0.3s ease-in (0x13E2EC: literal
# double 0.3, movt #0x434C = 204; the port had (202,85) / 0.6s). The first
# accelerometer sample then clamps it to the -0.2618 rest tilt.
#
# The Skip consumable (buySkip, viewDidLoad 0x13D8E4, centre (50, 350.5);
# buyClick: 0x13F574 / consumablePurchased: 0x13F2F8) is a 3-coin
# consumable, not IAP; PORTED, see the skip block.
# isContainerAnimating (set 0x13DF78, cleared 0x13EA34) is never
# read by the pour path and is not carried.
#
# KEEP-STATE: kept alive under the push to cffPatDry.
# viewDidLoad's piles / badge / bottle pivot are built once; viewWillAppear:
# (reset of pour and soak, bottle slide-in from its current x + 300, timers)
# runs on entry and in on_resume. on_exit = viewWillDisappear: (loop off,
# accelerometer off, timers invalidated). nextClick: re-publishes this
# controller's own infoDict before the push.

extends "res://core/Screen.gd"

## Skip consumable (PORTED; the phone shows the badge):
## initWithNibName: 0x13D478 builds Consumable DM_CONSUMABLE_SKIP / Skip_30Pour,
## cost = the dead server table GameData.CoinCosts ... SkipIngredients, 3 when
## absent; first-time message below. viewDidLoad 0x13D63C builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0x13F574 ("store" sound,
## purchaseConsumable). consumablePurchased: 0x13F2F8 calls nextClick: with the badge as sender -- the same path as the next button.
## consumablePurchaseFailed:error: 0x13F4A0 (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_30Pour"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton

const cffSelectSlicer := preload("res://screens/cffSelectSlicer.gd")

## Nib: bowl UIImageView frame (0,226,320,192), centre (160,322).
## viewDidLoad: water + starch MaskedIVs centred at bowl.centre + (0,2);
## the potato pile exactly on bowl.centre (0x13D63C).
const BOWL_CENTER := Vector2(160, 322)
const LAYER_CENTER := Vector2(160, 324)
## viewWillAppear: the pour timer (0x3FB99999A0000000 = 0.1s) and the bubble
## timer (0x3FD9999A9999999A = 0.4s); startAccelerometer after 0.5s.
const KERNEL_TICK_S := 0.1
const BUBBLE_TICK_S := 0.4
const ARM_DELAY := 0.5
## accelerometer 0x13EE10: clamp [-2.1817, -0.2618]; pouring at
## angle <= -2.0943951 while pourTime < 3.0.
const REST_ROTATION := -0.2618
const POUR_ROTATION := -2.1817
const POUR_THRESHOLD := -2.0943951
const POUR_FULL := 3.0
## PORT CHOICE: hold-tilt time; the original filtered a live
## signal (k = 0.05 at 1/30s).
const TILT_SECONDS := 0.35
## spoutTop = centre + (sin(a)*115 + 23, cos(a)*(-45) - 2) (0x13EE10).
const SPOUT_SIN_K := 115.0
const SPOUT_X_OFF := 23.0
const SPOUT_COS_K := -45.0
const SPOUT_Y_OFF := -2.0
## kernelTick: alpha = (pourTime + pourTime) * 0.125 (0x13E834).
const WATER_ALPHA_K := 0.25
## Nib: waterContainer (205,29,62,128), centre (236,93); viewWillAppear
## parks it at centre.x + 300 (0x43960000) and slides to (204,85)
## (0x434C0000/0x42AA0000) over 0.3s (literal 0x13E488 =
## 0x3FD3333333333333), curve 1 ease-in.
const BOTTLE_NIB_CENTER := Vector2(236, 93)
const BOTTLE_PARK_X := 300.0
const BOTTLE_REST_CENTER := Vector2(204, 85)
const BOTTLE_SECONDS := 0.3
const BOTTLE_SIZE := Vector2(62, 128)
## soakTick (0x13E968): +0.06 per 0.25s tick, done at 0.8.
const SOAK_TICK_S := 0.25
const SOAK_STEP := 0.06
const SOAK_FULL := 0.8
## bubbleTick (0x13E594): 30% chance; alpha 0.6 (0x3F19999A), scale
## 0.1 -> 0.6 over 2.0s ease-in; x = rand%160 (0xA0), start y 135
## (0x43070000) less half the scaled height, end centre-y 45 (0x42340000).
const BUBBLE_CHANCE := 30
const BUBBLE_ALPHA := 0.6
const BUBBLE_X_MOD := 160
const BUBBLE_START_Y := 135.0
const BUBBLE_END_Y := 45.0
const BUBBLE_SECONDS := 2.0

var _water: cffSelectSlicer.MaskedIV
var _dirt: cffSelectSlicer.MaskedIV
var _potato: cffSelectSlicer.MaskedIV
var _stream: Sprite2D
var _pivot: Node2D
var _holding := false
var _armed := false
var _pouring := false            # isPouringKernels
var _pour_time := 0.0
var _filled := false             # isWaterFilled
var _count := 0.0
var _kernel_timer: Timer
var _soak_timer: Timer
var _bubble_timer: Timer
var _bottle_tween: Tween
var _info: Dictionary = {}


## UINavigationController keeps this controller alive under the push to
## cffPatDry; Nav calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## initWithInfoDict: (0x13D608) + viewDidLoad (0x13D63C) once, then
## viewWillAppear: (0x13DDF0).
func on_enter() -> void:
	_info = cffSelectSlicer.info_or_default(GameState.custom_categories)
	# viewDidLoad order: piles, stream, then the badge (addSubview: on top).
	_build_piles(_info)
	_build_skip()
	_build_bottle()
	_kernel_timer = Timer.new()
	_kernel_timer.wait_time = KERNEL_TICK_S
	_kernel_timer.timeout.connect(_kernel_tick)
	add_child(_kernel_timer)
	_bubble_timer = Timer.new()
	_bubble_timer.wait_time = BUBBLE_TICK_S
	_bubble_timer.timeout.connect(_bubble_tick)
	add_child(_bubble_timer)
	set_process(true)
	_will_appear()


## Back from cffPatDry: viewWillAppear: runs again and RESETS the step --
## pour time and soak count to 0, water / starch / bubbles to alpha 0, the
## bottle unhidden and slid in again from x + 300, next and SOAK hidden,
## both timers rescheduled. The potato pile is not touched. The bottle keeps
## whatever transform the accelerometer last gave it (viewWillAppear: never
## resets it) until the first sample after re-arming.
func on_resume() -> void:
	_will_appear()


## viewWillAppear: (0x13DDF0).
func _will_appear() -> void:
	_count = 0.0
	_pour_time = 0.0
	_filled = false
	_pouring = false
	_dirt.modulate.a = 0.0
	for outlet_name in ["nextButton", "soakButton"]:
		var n := outlet(outlet_name)
		if n != null and n != self:
			(n as CanvasItem).visible = false
	_stream.visible = false
	# startAccelerometer after 0.5s; its first sample snaps the bottle from
	# upright to the rest clamp. viewWillDisappear: does not cancel this
	# perform; the port drops it if the screen has left the tree first --
	# unreachable (next only shows after the soak).
	get_tree().create_timer(ARM_DELAY).timeout.connect(func() -> void:
		if not is_inside_tree():
			return
		_armed = true
		if not _holding:
			_pivot.rotation = REST_ROTATION)
	_kernel_timer.start()
	# setBaseOrigPt:(x,135) for water then (x,0) for the starch; the water's
	# (x,135) is overwritten by (x,0) below before a frame is drawn.
	_water.set_base_orig_pt(Vector2.ZERO)
	_dirt.set_base_orig_pt(Vector2.ZERO)
	change_instruction("inst_pour.png")
	# waterContainer: centre.x + 300 (its CURRENT centre -- the nib's on
	# entry, (204,85) on a return), unhidden, slid to (204,85) over 0.3s
	# ease-in; then stream and container to the front.
	_pivot.position = _pivot.position + Vector2(BOTTLE_PARK_X, 0)
	_pivot.visible = true
	if _bottle_tween != null and _bottle_tween.is_valid():
		_bottle_tween.kill()
	_bottle_tween = create_tween()
	_bottle_tween.tween_property(_pivot, "position", BOTTLE_REST_CENTER,
		BOTTLE_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	# bringSubviewToFront: stream, then waterContainer. (move_child to the
	# pivot's index used to land the stream ABOVE the bottle: Godot removes
	# the child before inserting, so the pivot shifted down one.)
	move_child(_stream, -1)
	move_child(_pivot, -1)
	_water.modulate.a = 0.0
	# bubbleTimer: invalidated if valid, bubbles alpha 0, rescheduled 0.4s.
	_bubble_timer.stop()
	var bub := outlet("bubbles")
	if bub != null and bub != self:
		(bub as CanvasItem).modulate.a = 0.0
	_bubble_timer.start()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## viewDidLoad (0x13D63C). Final z-order after the bringSubviewToFront
## calls: potatoPile < waterPile < dirtPile < buySkip < stream <
## waterContainer, all above the nib's views.
func _build_piles(info: Dictionary) -> void:
	_potato = cffSelectSlicer.MaskedIV.new(
		_tex(str(info.get("BowlPile_Image", ""))),
		_tex(str(info.get("BowlPile_Mask_Image", ""))))
	_potato.set_center(BOWL_CENTER)
	# setBaseOrigPt: the slicer screen's final pile origin, carried through
	# initWithInfoDict / setPotatoBaseOrig (0x145F6C -> 0x13D8D8 block).
	# Standalone default 22.4 = the slicer's deterministic finish state
	# (208 - 29 * 192/30, the first value below the 24.0 gate).
	_potato.set_base_orig_pt(Vector2(
		float(info.get("PotatoBaseOrigX", 0.0)),
		float(info.get("PotatoBaseOrigY", 22.4))))
	add_child(_potato)

	_water = cffSelectSlicer.MaskedIV.new(_tex("cff_water_layer.png"),
		_tex("cff_bowl_Mask.png"))
	_water.set_center(LAYER_CENTER)
	# viewWillAppear writes (x,135) then (x,0); the 135 never survives to a
	# frame -- dead store, ported as the surviving value.
	_water.set_base_orig_pt(Vector2.ZERO)
	add_child(_water)

	_dirt = cffSelectSlicer.MaskedIV.new(_tex("cff_starch_layer.png"),
		_tex("cff_bowl_Mask.png"))
	_dirt.set_center(LAYER_CENTER)
	_dirt.set_base_orig_pt(Vector2.ZERO)
	add_child(_dirt)

	_stream = Sprite2D.new()
	_stream.texture = _tex("cff_water_pour.png")
	_stream.centered = false                   # frame origin = spoutTop
	_stream.visible = false
	add_child(_stream)


## The nib bottle sprite is top-left anchored; the original rotates the
## UIImageView about its centre, so it is rehung on a pivot (kc precedent),
## left at the nib centre. viewWillAppear: does the park and the slide.
func _build_bottle() -> void:
	_pivot = Node2D.new()
	_pivot.rotation = 0.0                      # no transform until armed
	var s := outlet("waterContainer")
	if s is Sprite2D:
		var sp := s as Sprite2D
		var parent := sp.get_parent()
		parent.add_child(_pivot)
		parent.remove_child(sp)
		_pivot.add_child(sp)
		sp.position = -BOTTLE_SIZE * 0.5
	else:
		add_child(_pivot)
	_pivot.position = BOTTLE_NIB_CENTER


# -- input: press-and-hold on the bottle (PORT CHOICE) ------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		if _armed and not _filled \
				and Rect2(_pivot.position - BOTTLE_SIZE * 0.5, BOTTLE_SIZE) \
				.has_point(mb.position):
			_set_holding(true)
			get_viewport().set_input_as_handled()
	elif _holding:
		_set_holding(false)


func _set_holding(value: bool) -> void:
	if _holding == value:
		return
	_holding = value
	create_tween().tween_property(_pivot, "rotation",
		POUR_ROTATION if value else REST_ROTATION, TILT_SECONDS) \
		.set_trans(Tween.TRANS_SINE)


func _spout_top() -> Vector2:
	var a := _pivot.rotation
	return _pivot.position + Vector2(
		sin(a) * SPOUT_SIN_K + SPOUT_X_OFF,
		cos(a) * SPOUT_COS_K + SPOUT_Y_OFF)


## The accelerometer body (0x13EE10), run per frame: pour while the angle is
## past the threshold and the fill is not complete.
func _process(_delta: float) -> void:
	if _pivot == null:
		return
	var now := _pivot.rotation <= POUR_THRESHOLD and _pour_time < POUR_FULL
	if now:
		if not _pouring:
			Audio.loop("pouring_loop")
		_stream.visible = true
		_stream.position = _spout_top()        # setFrame: origin = spoutTop
	else:
		if _pouring:
			Audio.stop("pouring_loop")
		_stream.visible = false
	_pouring = now


## kernelTick (0x13E834).
func _kernel_tick() -> void:
	if _pour_time <= POUR_FULL and _pouring:
		_pour_time += KERNEL_TICK_S
		_water.modulate.a = _pour_time * WATER_ALPHA_K
	if _pour_time >= POUR_FULL and not _filled:
		_filled = true
		_kernel_timer.stop()
		dismiss_instruction()                  # instIV setHidden:1
		var soak := outlet("soakButton")
		if soak != null and soak != self:
			(soak as CanvasItem).visible = true
		_pivot.visible = false                 # waterContainer setHidden:1


## soakButtonClick: (0x13F5E0).
func _on_soakButtonClick() -> void:
	var soak := outlet("soakButton")
	if soak != null and soak != self:
		(soak as CanvasItem).visible = false
	if _soak_timer == null:
		_soak_timer = Timer.new()
		_soak_timer.wait_time = SOAK_TICK_S
		_soak_timer.timeout.connect(_soak_tick)
		add_child(_soak_timer)
	_soak_timer.start()
	change_instruction("inst_wait.png")


## soakTick (0x13E968).
func _soak_tick() -> void:
	_count += SOAK_STEP
	_dirt.modulate.a = minf(_count, 1.0)
	var bub := outlet("bubbles")
	if bub != null and bub != self:
		(bub as CanvasItem).modulate.a = minf(_count, 1.0)
	if _count >= SOAK_FULL:
		_soak_timer.stop()
		show_next_button()


## bubbleTick (0x13E594), coordinates in the bubbles view's (83,216) space.
func _bubble_tick() -> void:
	if randi() % 100 > BUBBLE_CHANCE - 1:
		return
	var bub := outlet("bubbles") as Node2D
	var t := _tex("bubble.png")
	if bub == null or bub == self or t == null:
		return
	var b := Sprite2D.new()
	b.texture = t
	b.modulate.a = BUBBLE_ALPHA
	b.scale = Vector2(0.1, 0.1)
	var h := t.get_size().y * 0.1              # frame height after the scale
	b.position = Vector2(float(randi() % BUBBLE_X_MOD),
		BUBBLE_START_Y - h * 0.5)
	bub.add_child(b)
	var tw := create_tween().set_parallel(true)  # "Bubble", curve 1 ease-in
	tw.tween_property(b, "scale", Vector2(0.6, 0.6), BUBBLE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_property(b, "position:y", BUBBLE_END_Y, BUBBLE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(b):
			b.queue_free())


## nextClick: (0x13F7D4): button_press, push a NEW cffPatDry
## initWithInfoDict: with this controller's own infoDict. Re-published to
## GameState.custom_categories because a later screen (cffDustSalt's bake)
## may have overwritten it while this one was covered.
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.custom_categories = _info.duplicate()
	Nav.next()


## backClick: (0x13F89C): button_press, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


## viewWillDisappear: (0x13E49C): pouring_loop off, stopAccelerometer,
## kernel / soak / bubble timers invalidated. Nothing else is torn down.
func on_exit() -> void:
	Audio.stop("pouring_loop")
	_armed = false                             # stopAccelerometer
	if _holding:
		_set_holding(false)
	for t in [_kernel_timer, _soak_timer, _bubble_timer]:
		if t != null:
			(t as Timer).stop()


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
	_skip_button = b


## buyClick: -- "store" sound, purchaseConsumable.
func _on_buyClick() -> void:
	Audio.play("store")
	_skip.call("purchase", self)


## consumablePurchased: -> nextClick: (see header).
func _on_skip_purchased(_free: bool) -> void:
	_on_nextClick()


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
