# Lemon Shake Up step 3 -- squeeze the fruit halves; juice fills the cup.
#
# GROUNDED from initFlavors (0x676D8, SqueezeIV init disasm at 0x67B80..
# 0x67BC4), squeezeTick (0x684F0, literals 0x688D0/D4/D8), squeezeTouchBegan/
# Moved:withScale:/Ended (0x68C58 / 0x68C84, threshold 0x68DBC / 0x68DC0),
# viewDidLoad (0x670F0, the SSEmitter config), viewDidAppear: (0x67688),
# restoreFruitSize: (0x67E64) and viewWillAppear: (0x674C0).
#
# The original mechanic is a PINCH on a SqueezeIV: two-finger distance drives
# currentScale, applied as CGAffineTransformMakeScale(scale, 1.0) -- the fruit
# squashes horizontally only -- and while scale <= 0.9 (0x68DBC) squeezeTick
# self-schedules every 0.05s (20 Hz). A desktop mouse has no pinch, so in the
# spirit of the tilt remaps, holding squeezes to one fixed scale below the
# grounded 0.9 threshold; everything the pinch fed (the 20 Hz counter, the
# 40/80 tick half-drops, the every-5th-tick fill) is kept exactly.
#
# Corrected against the original code: the juice is TintedIV's overlay bake
# under an upside-down cup mask, a BackCupView subview below the dropped
# halves; the tutorial pulse is gone (it never shows on the device, see
# TUTORIAL below); release snaps the fruit back at once (pinch: 0xACF48);
# the fruit sits under next/back/the skip badge; the drips are untinted and
# drawn in the emitter's slot; backClick: (0x68034) plays button_press.
#
# The drips are the real SSEmitter (core/particles), not a stand-in, and the
# screen is kept alive under the push: viewWillDisappear: (0x67604) ->
# on_exit(), viewWillAppear: (0x674C0, initFlavors) / viewDidAppear:
# (0x67688) -> on_resume().

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

## Skip consumable (ported; the original shows its badge):
## initWithFruit: 0x66F28 builds Consumable DM_CONSUMABLE_SKIP / Skip_40Squeeze,
## cost = the dead server table GameData.CoinCosts ... SkipSqueeze, 3 when
## absent; first-time message below. viewDidLoad 0x670F0 builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0x67FC8 ("store" sound,
## purchaseConsumable). consumablePurchased: 0x67EC4 calls nextClick: with the badge as sender -- the same path as the next button.
## consumablePurchaseFailed:error: 0x67EF4 (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_40Squeeze"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton

const Shared := preload("res://screens/lsuShared.gd")
const lsuSliceFruit := preload("res://screens/lsuSliceFruitViewController.gd")
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")

# -- initFlavors (0x676D8) ---------------------------------------------

## The juice fill: TintedIV(lsu_fruit_juice, fruitColor, blend 3), whose
## baseIV.image (the overlay bake, Shared.tinted_image) is fed to
## MaskedIV(_, lsu_cup_mask), added as a subview of BackCupView at its origin,
## baseOrigPt (0, 273).
const FILL_ORIG_Y0 := 273.0

## topFruit: SqueezeIV(<prefix>half_for_Squeeze, centre (160, 100), self)
## with setFrameMultiplier:4.0 (mov.w r2,#0x40800000 at 0x67BC0). On iOS >=
## 3.2 the init and setFrameMultiplier: both run resetFrame (0xAD12C): the
## frame becomes 4x the art (1280x1280) about the same centre, contentMode 4
## (UIViewContentModeCenter -- the art stays natural size). That frame covers
## the whole screen, so any press below next/back/the badge squeezes.
const FRUIT_CENTER := Vector2(160, 100)

## TUTORIAL: initFlavors then animates topFruit.frame to (x+30, y, w-60, h)
## -- 0.3s legs, linear, autoreversing, repeat 8 -- and restoreFruitSize:
## puts the frame back 2.4s later. On the 1280-wide, contentMode-Center frame
## that only trims the view's invisible margin: the art is never scaled, so
## "Tutorial_Fruit_Squeeze" draws nothing on the device. ORIGINAL QUIRK,
## ported as no animation. (The port used to pulse the art 30px a side.)

# -- the squeeze (0x68C84 / 0x684F0) -----------------------------------

## Pours while currentScale <= 0.9 (0x68DBC).
const POUR_SCALE := 0.9
## PORT CHOICE: the fixed held-squeeze scale, past the
## grounded threshold. X only -- the original's transform is (scale, 1.0).
const SQUEEZE_SCALE := 0.8
const SQUEEZE_SECONDS := 0.2

## squeezeTick reschedules itself every 0.05s (0x3FA99999A0000000) while
## pouring and the second half hasn't dropped.
const TICK_HZ := 20.0
## First half drops when the count reaches 40.0 (0x688D0); second at 0x50=80.
const HALF1_TICKS := 40
const HALF2_TICKS := 80
## Every 5th tick: baseOrigPt.y = (count / -80) * 110 + 110 (0x688D4/0x688D8).
const FILL_DIV := -80.0
const FILL_MUL := 110.0

## The drop-in animation "DropFruitInGlass": 0.75s (0x3FE80000) ease-in-out.
## All half coordinates are BackCupView-local (the halves are its subviews;
## UIImageViews, true centres).
const DROP_SECONDS := 0.75
const HALF_SPAWN := Vector2(110, -100)
const HALF_SPAWN_ROT := 1.5707964          # 0x3FC90FDB, pi/2
const HALF1_END := Vector2(120, 150)       # rot 0, scale 0.5
const HALF2_END := Vector2(76, 130)        # rot 150 deg (0x40278D36), scale 0.5
const HALF2_END_ROT := 2.6179938
const HALF_END_SCALE := 0.5
## topFruit jumps to (360, 100) and animates back to (160, 100) for the
## second squeeze; it is removed outright at the end.
const FRUIT_JUMP := Vector2(360, 100)

# -- the drip emitter (viewDidLoad 0x670F0, call 0x6738E) ----------------

## freshJuice: the nib's SSEmitter (id 4, frame (107,145,107,42), above
## lsu_sugar_pile, below TopCupView). setParticles:[lsu_juice_drop_two]
## tint:fruitColor random:NO interval:0.2 duration:1.0 repeat:YES
## finalOffset:(0,250) alpha 1->1 scale 1->1 variance [0,0,20,0] options:1.
## UNTINTED: fruitColor is only set by initFlavors in viewWillAppear:, after
## viewDidLoad -- the emitter keeps nil and emits plain UIImageViews, on
## every visit (viewDidLoad does not run again). Drops fall from (160.5,166)
## to x 150.5..169.5, y 416. Started when the squeeze starts pouring
## (squeezeTouchMoved:fromSender:withScale: 0x68C84); stopped when it stops
## (same method, and squeezeTouchEnded: 0x68DC0), at the second half
## (squeezeTick 0x684F0), and by backClick:, nextClick: and
## viewWillDisappear:.
const JUICE := "lsuSqueezeFruitViewController.freshJuice"

var _fill: Shared.MaskedIV
var _fruit: Sprite2D
var _half1: Sprite2D
var _half2: Sprite2D
var _squeeze_tween: Tween
var _held := false
var _pouring := false
var _ticks := 0
var _accum := 0.0
var _poured1 := false
var _poured2 := false
var _juice: SSEmitter


func on_enter() -> void:
	# viewDidLoad built the badge and configured the emitter before any
	# viewWillAppear content.
	_build_skip()
	_build_emitter()
	_build_fill()
	_build_fruit()
	_set_next_enabled(false)
	UIKit.park_instruction(self)
	set_process(true)


## viewDidAppear: (0x67688), after the push / pop slide:
## changeInstruction:@"inst_squeeze.png" -- on every appearance.
func on_did_appear() -> void:
	change_instruction("inst_squeeze.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _back_cup() -> Node2D:
	var n := outlet("BackCupView")
	return n if n is Node2D else self


## A subview of BackCupView, at its origin -- drawn over the cup back and
## under the halves that later drop in (also BackCupView subviews), the nib's
## static sugar pile, the emitter and the cup front.
func _build_fill() -> void:
	_fill = Shared.MaskedIV.new(
		Shared.tinted_texture(_tex("lsu_fruit_juice.png"), lsuSliceFruit.fruit_color,
			Shared.BLEND_OVERLAY),
		_tex("lsu_cup_mask.png"))
	_fill.set_base_orig_pt(Vector2(0, FILL_ORIG_Y0))
	_back_cup().add_child(_fill)


## addSubview: puts topFruit over everything, then viewWillAppear: brings
## nextButton, backButton and buySkip back above it.
func _build_fruit() -> void:
	_fruit = Sprite2D.new()
	_fruit.texture = _tex(lsuSliceFruit.fruit_prefix + "half_for_Squeeze.png")
	_fruit.centered = true
	_fruit.position = FRUIT_CENTER
	add_child(_fruit)
	for n: Node in [outlet("nextButton"), outlet("backButton"), _skip_button]:
		if n != null and n != self and n.get_parent() == self:
			move_child(n, get_child_count() - 1)


# -- interaction -------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		if _fruit == null or _poured2:
			return
		# squeezeTouchBegan: (0x68C58) removes the layer's animations -- the
		# invisible tutorial (see TUTORIAL); nothing to undo here.
		_set_held(true)
		get_viewport().set_input_as_handled()
	else:
		_set_held(false)


func _set_held(value: bool) -> void:
	if _held == value:
		return
	_held = value
	if _fruit == null:
		return
	if _squeeze_tween != null and _squeeze_tween.is_valid():
		_squeeze_tween.kill()
	if value:
		# The original's pinch squashes x only: MakeScale(scale, 1.0).
		_squeeze_tween = create_tween()
		_squeeze_tween.tween_property(_fruit, "scale:x", SQUEEZE_SCALE,
			SQUEEZE_SECONDS).set_trans(Tween.TRANS_SINE)
	else:
		# pinch: (0xACF48), any state but Changed: transform = identity and
		# resetFrame, no animation -- the fruit snaps back.
		_fruit.scale = Vector2.ONE


## viewDidLoad (0x670F0): the nib's freshJuice view gets its SSEmitter
## configuration, tint nil (see JUICE above).
func _build_emitter() -> void:
	var host := outlet("freshJuice")
	if host == null or host == self:
		return
	_juice = SSEmitter.attach(host, SSEmitterConfigs.frame_size(JUICE)) as SSEmitter
	SSEmitterConfigs.apply(_juice, JUICE, null)


func _stop_juice() -> void:
	if _juice != null:
		_juice.stop()


## squeezeTouchMoved:withScale: (0x68C84): pouring exactly while the scale
## sits at or below 0.9; entering plays lsu_squeeze and starts the emitter,
## leaving stops it (0x68C84 else-branch, squeezeTouchEnded: 0x68DC0).
func _set_pouring(value: bool) -> void:
	if _pouring == value:
		return
	_pouring = value
	if value:
		# performSelector:squeezeTick afterDelay:0.05 (double
		# 0x3FA99999A0000000) -- leaving the pour cancels it
		# (cancelPreviousPerformRequestsWithTarget:), so each pour starts a
		# fresh 0.05s wait.
		_accum = 0.0
		if _juice != null:
			_juice.start()
		Audio.play("lsu_squeeze")
	else:
		_stop_juice()


func _process(delta: float) -> void:
	if _fruit != null:
		_set_pouring(_held and _fruit.scale.x <= POUR_SCALE and not _poured2)
	else:
		_set_pouring(false)
	if not _pouring:
		return

	_accum += delta
	while _accum >= 1.0 / TICK_HZ:
		_accum -= 1.0 / TICK_HZ
		_tick()
		if not _pouring:
			break


## squeezeTick (0x684F0).
func _tick() -> void:
	_ticks += 1
	if _ticks >= HALF1_TICKS and not _poured1:
		_poured1 = true
		_drop_first_half()
		Audio.play("lsu_juice_drip")
	elif _ticks >= HALF2_TICKS and not _poured2:
		_poured2 = true
		_drop_second_half()
		_stop_juice()
		Audio.play("lsu_juice_drip")
		show_next_button()
		_set_next_enabled(true)
	elif _ticks % 5 == 0 and (not _poured1 or not _poured2):
		var y := (float(_ticks) / FILL_DIV) * FILL_MUL + FILL_MUL
		_fill.set_base_orig_pt(Vector2(0, y))


## First branch of squeezeTick: the spent half drops into the glass while the
## fruit leaps off right and slides back in as the second half.
func _drop_first_half() -> void:
	_half1 = _spawn_half()
	_fruit.position = FRUIT_JUMP
	var t := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(_half1, "position", HALF1_END, DROP_SECONDS)
	t.parallel().tween_property(_half1, "rotation", 0.0, DROP_SECONDS)
	t.parallel().tween_property(_half1, "scale",
		Vector2(HALF_END_SCALE, HALF_END_SCALE), DROP_SECONDS)
	t.parallel().tween_property(_fruit, "position", FRUIT_CENTER, DROP_SECONDS)


## Second branch: another half_1 drops (the original loads half_1 again, not
## half_2) and topFruit is removed outright.
func _drop_second_half() -> void:
	_half2 = _spawn_half()
	if _fruit != null:
		_fruit.queue_free()
		_fruit = null
	var t := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(_half2, "position", HALF2_END, DROP_SECONDS)
	t.parallel().tween_property(_half2, "rotation", HALF2_END_ROT, DROP_SECONDS)
	t.parallel().tween_property(_half2, "scale",
		Vector2(HALF_END_SCALE, HALF_END_SCALE), DROP_SECONDS)


func _spawn_half() -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = _tex(lsuSliceFruit.fruit_prefix + "half_1.png")
	s.centered = true
	s.position = HALF_SPAWN
	s.rotation = HALF_SPAWN_ROT
	_back_cup().add_child(s)
	return s


func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.disabled = not on


## nextClick: (0x680C0): button_press, stop the emitter, push PourIce
## initWithFruit:.
func _on_nextClick() -> void:
	Audio.play("button_press")
	_stop_juice()
	Nav.next()


## backClick: (0x68034): button_press, stop the emitter, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	_stop_juice()
	Nav.back()


## viewWillDisappear: (0x67604), on the push as well as the pop: freshJuice
## stop, buySkip hidden, topFruit removed (released, nilled) if still there.
## The juice and dropped halves stay in the cup.
func on_exit() -> void:
	_stop_juice()
	if _skip_button != null:
		_skip_button.visible = false
	_held = false
	_pouring = false
	if _squeeze_tween != null and _squeeze_tween.is_valid():
		_squeeze_tween.kill()
	if _fruit != null:
		_fruit.queue_free()
		_fruit = null


## UINavigationController keeps this controller alive under PourIce
## (nextClick: pushes), so back shows the same instance (Nav.gd opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from PourIce. viewWillAppear: (0x674C0): nextButton hidden, then
## initFlavors (0x676D8): ONLY if both halves were poured are the juice fill
## and the two dropped halves removed -- a step left early through the skip
## badge keeps them, and the new fill is simply added on top (kept as read);
## hasPoured1/2 and juicePourCount reset; a new empty juice fill
## (baseOrigPt (0,273)) and a new topFruit at (160,100); the invisible
## tutorial pulse (see TUTORIAL). Then buySkip unhidden and next, back and
## buySkip brought to the front; viewDidAppear: (0x67688)
## changeInstruction:@"inst_squeeze.png". The squeeze starts over.
func on_resume() -> void:
	Shared.drop_coin_view(self)
	_set_next_enabled(false)
	if _poured1 and _poured2:
		for n in [_fill, _half1, _half2]:
			if n != null and is_instance_valid(n):
				n.queue_free()
	_fill = null
	_half1 = null
	_half2 = null
	_poured1 = false
	_poured2 = false
	_ticks = 0
	_accum = 0.0
	_build_fill()
	if _skip_button != null:
		_skip_button.visible = true
	_build_fruit()
	# viewDidAppear:'s changeInstruction: runs in on_did_appear().


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
