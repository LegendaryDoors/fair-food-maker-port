# Ice Pop step 5 -- dip the mold into the flash freezer until it sets.
#
# From the original binary (disassembly at the ObjC method list's IMPs):
#   initWithDictionary: 0xF6CEC, viewDidLoad 0xF7498, viewWillAppear: 0xF76E0,
#   resetScreen 0xF6544, resetIcePop 0xF6438,
#   draggableTouchMoved:fromSender: 0xF7F3C,
#   draggableTouchEnded:fromSender: 0xF8078,
#   startIcePopFadeTimer 0xF6388 (1.5s repeating), fadeIcePop 0xF6150,
#   rotatePerfectlyFrozenIcePop 0xF65B8, animateRemoveMold 0xF66D0,
#   sendIcePopToOriginalLocation 0xF5EAC, checkFreezerSoundPlayer 0xF5DB0,
#   stopFadeTimerForIcePop 0xF5C0C, nextClick: 0xF79C0,
#   changeInstruction: 0xF6AC8.
#
# The mechanic is a DRAG-AND-SOAK, not a plain wait: the pop (a DraggableIV
# container at (160,130), rotated pi so the stick points up) is dragged down
# into the freezer; dropping it with centre.y > 210 clamps x to [110,210],
# sinks it to y=300 over 0.5s (linear) and starts a 1.5s repeating timer.
# fadeIcePop bumps the state and tests the NEW value: ticks 1-5 each fade
# the mold by 0.2, tick 4 plays "liquid freeze_03", and tick 5 (7.5s in)
# shows next, snaps the pop back to its origin (0.2s linear), rotates it to
# 5.4978 rad (0.3s) and 0.3s later cracks the mold halves away (egg_crack).
# (The port used to finish one tick late, on the sixth.) The
# "liquid freeze_04" loop is NOT stopped by the finish -- only next/back/
# disappear stop it. Dropping the pop anywhere else sends it straight home
# and restores the alphas over 1.0s.
#
# DEAD CODE, NOT PORTED, checked across the whole original binary: none of
# these selectors is sent by ipFreezerViewController or by any code that
# could reach an instance of it (the same-named sends live in
# ccbFreezer / cdBatterCoating / cdFryDog / ccMachine and dispatch to their
# own methods):
#   startChill 0xF78D8 is a 4-byte stub yet viewWillAppear still schedules it
#   (performSelector afterDelay 0.5 -- a no-op, ported as nothing);
#   overFreezeIcePop 0xF6068, shakeIcePopForDuration: 0xF5C48,
#   showRedCrossAtPoint: 0xF5AF8, removeRedCross 0xF5B3C,
#   showNextButtonWhenIcePopIsReady 0xF5B64, resizeImage:scaledToSize: 0xF5980
#   -- an over-freeze fail state that was wired out of the shipped build.
#   icePopSoaked exists and gates the fade, but nothing ever calls the
#   over-freeze path that would have punished leaving the pop in.
#
# nextClick: (0xF79C0) bakes GameState.custom_categories for
# MakeViewController (classStr "ICE_POP"):
#   "IcePop":      juiceImg + textureImg at alpha 0.5 rendered into a
#                  (0,0,320,333) container; IsEdible YES, ViewIndex 2,
#                  Type Stationary, ItemCenter (0, 50).
#   "IcePopStick": the stick art; IsEdible NO, ViewIndex 1, Type Stationary,
#                  ItemCenter (140, 183).
# DecorateItemView is the zero-frame initialiser, so those centres place the
# art's TOP-LEFT (see MakeViewController.gd's header).
#
# KEEP-STATE: Nav keeps this screen under Make. Back
# from Make runs viewWillAppear: again: freezer_02 loops again and
# resetScreen puts the pop back at the top, upside down, mold opaque, next
# hidden -- the freeze is done over. instIV is unhidden but NOT re-slid
# (changeInstruction: skips the name it already shows).

extends "res://core/Screen.gd"

const DraggableSprite := preload("res://core/DraggableSprite2D.gd")
## Keep-state helpers shared with the kc screens.
const kcKit := preload("res://screens/kcKit.gd")

const POP_HOME := Vector2(160, 130)      # initWithDictionary andCenter:
const PART_SCALE := 0.5
## Subview centres inside the 150x260 fp_transparent_icepop_background,
## expressed relative to the container centre: (75,83)-(75,130) = (0,-47)
## for mold/texture/juice, (75,160)-(75,130) = (0,30) for the stick.
const BODY_OFFSET := Vector2(0, -47)
const STICK_OFFSET := Vector2(0, 30)
const TEXTURE_REST_ALPHA := 0.2          # initWithDictionary 0xF6F66

## draggableTouchMoved (0xF7F3C): centre clamps x to [110,210], y <= 300;
## no lower bound on y (DraggableIV minY is INT_MIN).
const DRAG_BOUNDS := Rect2(110, -1.0e6, 100, 1.0e6 + 300)
## draggableTouchEnded (0xF8078): centre.y > 210 means "in the freezer".
const FREEZER_Y := 210.0
const SOAK_Y := 300.0
const DROP_SECONDS := 0.5                # "DropIcePop"
const FADE_INTERVAL := 1.5               # startIcePopFadeTimer 0xF63DC
const FADE_STEP := 0.2                   # fadeIcePop -0.2 per tick
const FADE_SECONDS := 0.5                # "FadeOutMold"
const DONE_STATE := 5
const SOUND_STATE := 4                   # "liquid freeze_03" one-shot
const SNAP_SECONDS := 0.2                # "SnapIcePop"
const DONE_ROTATION := 5.49779           # rotatePerfectlyFrozenIcePop, 0.3s
const DONE_ROTATE_SECONDS := 0.3
const REMOVE_MOLD_DELAY := 0.3           # performSelector 0x3FD333...
const RETURN_SECONDS := 1.0              # "OverFrozenIcePopFadeIn"
## animateRemoveMold (0xF66D0): two half-scale copies of the mold art fly to
## centres (375,83) / (-225,83) in container coords over 0.5s (linear), are
## removed 0.6s on, and the mold ivar drops to alpha 0.3. The right-hand copy
## (inserted above the mold, i.e. on top) is rotated by 3.1241. The left one
## (inserted below the texture) is given CGAffineTransformRotate of the RIGHT
## copy's already-updated transform by 3.159: 3.1241 + 3.159 = 6.2831, a
## whole turn short by 0.0001 rad -- INFERRED: Core Animation interpolates
## the matrices, so it slides without visibly turning.
const HALF_A_CENTER := Vector2(375, 83)
const HALF_B_CENTER := Vector2(-225, 83)
const HALF_A_SPIN := 3.1241
const HALF_B_SPIN := 3.1241 + 3.159 - TAU
const REMOVE_SECONDS := 0.5
const HALF_LIFE := 0.6
const MOLD_RESIDUE_ALPHA := 0.3
const MASK_SIZE := Vector2i(320, 333)

var _freezer_meta: Dictionary = {}
var _pop: Sprite2D                       # DraggableSprite2D container
var _mold: Sprite2D
var _texture: Sprite2D
var _juice: Sprite2D
var _stick: Sprite2D

var _state := 0
var _soaked := false
var _fade_timer: Timer
var _done := false
## previousInstImgName (changeInstruction: 0xF6AC8).
var _prev_inst := ""
## Every tween this screen starts (kcKit.track / settle, keep-state).
var _tweens: Array = []


func on_enter() -> void:
	_freezer_meta = GameState.get_meta("ip_freezer", {})
	if _freezer_meta.is_empty():
		# Defensive fallback for flow-walking tools that skip the extras
		# screen's nextClick: rebuild the three art names exactly as
		# ipSelectExtra nextClick: (0x100F90) derives them from the shared
		# infoDict. juiceImg stays absent, matching an empty pour.
		# The nib-authored placeholders (Stick_1 / FP_Pop_Shape_1) stand in
		# when even ip_info is absent, matching what the earlier ip screens
		# display before a real selection reaches them.
		var info: Dictionary = GameState.get_meta("ip_info", {})
		var mold := str(info.get("moldFileString", "FP_Pop_Shape_1.png"))
		_freezer_meta = {
			"stickImg": str(info.get("stickFileString", "Stick_1.png")),
			"moldImg": mold,
			"textureImg": mold.replace("Shape", "Real"),
		}
	_build_pop()
	_fade_timer = Timer.new()
	_fade_timer.wait_time = FADE_INTERVAL
	_fade_timer.one_shot = false
	_fade_timer.timeout.connect(_fade_tick)
	add_child(_fade_timer)
	_view_will_appear()


## UINavigationController keeps this controller under Make.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	kcKit.drop_coin_panel(self)
	_view_will_appear()


## viewWillAppear: (0xF76E0): instIV unhidden, startChill (a stub) in 0.5s,
## freezer_02 looping, resetScreen.
func _view_will_appear() -> void:
	var inst := _instruction_node()
	if inst != null:
		inst.visible = true
	Audio.loop("freezer_02")
	_reset_screen()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## initWithDictionary: (0xF6CEC): DraggableIV(fp_transparent_icepop_background)
## centred at (160,130); subviews added stick, juice, TEXTURE, MOLD (bottom
## to top -- the mold art covers the 0.2-alpha texture until it fades), each
## at half scale; the whole container rotated by -pi.
func _build_pop() -> void:
	_pop = DraggableSprite.new()
	_pop.texture = _tex("fp_transparent_icepop_background.png")
	_pop.position = POP_HOME
	_pop.rotation = PI
	_pop.set("drag_bounds", DRAG_BOUNDS)
	add_child(_pop)
	# In front of the freezer art, behind the chrome.
	var inst := outlet("instIV")
	if inst != null and inst != self:
		move_child(_pop, (inst as Node).get_index())
	_pop.connect("drag_ended", _on_pop_released)
	# draggableTouchBegan:fromSender: (0xF7F38) is empty: no sound on grab.

	_stick = _part(str(_freezer_meta.get("stickImg", "")), STICK_OFFSET)
	var juice_img: Variant = _freezer_meta.get("juiceImg")
	_juice = Sprite2D.new()
	if juice_img is Image:
		_juice.texture = ImageTexture.create_from_image(juice_img)
	_juice.position = BODY_OFFSET
	_juice.scale = Vector2(PART_SCALE, PART_SCALE)
	_pop.add_child(_juice)
	_texture = _part(str(_freezer_meta.get("textureImg", "")), BODY_OFFSET)
	_mold = _part(str(_freezer_meta.get("moldImg", "")), BODY_OFFSET)
	if _texture != null:
		_texture.modulate.a = TEXTURE_REST_ALPHA


func _part(file: String, offset: Vector2) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = _tex(file)
	s.position = offset
	s.scale = Vector2(PART_SCALE, PART_SCALE)
	_pop.add_child(s)
	return s


## resetIcePop (0xF6438) + resetScreen (0xF6544).
func _reset_screen() -> void:
	_state = 0
	_soaked = false
	_done = false
	_pop.position = POP_HOME
	_pop.call_deferred("capture_origin")
	_pop.set("enabled", true)
	_pop.rotation = PI
	_pop.modulate.a = 1.0
	if _mold != null:
		_mold.modulate.a = 1.0
	if _texture != null:
		_texture.modulate.a = TEXTURE_REST_ALPHA
	var inst := _instruction_node()
	if inst != null:
		inst.visible = true
	_change_inst("inst_flash_freezer.png")
	_set_next_visible(false)


## changeInstruction: (0xF6AC8): does nothing for the name already shown.
func _change_inst(image_name: String) -> void:
	if image_name == _prev_inst:
		return
	_prev_inst = image_name
	change_instruction(image_name)


# -- soak --------------------------------------------------------------

## draggableTouchEnded (0xF8078).
func _on_pop_released(pos: Vector2, _hit: bool) -> void:
	if _done:
		return
	if pos.y > FREEZER_Y:
		_dip(pos)
	else:
		_send_home()


func _dip(pos: Vector2) -> void:
	var x: float = clampf(pos.x, DRAG_BOUNDS.position.x, DRAG_BOUNDS.end.x)
	# "DropIcePop": curve 3, linear.
	_tween().tween_property(_pop, "position",
		Vector2(x, SOAK_Y), DROP_SECONDS)
	dismiss_instruction()
	_soaked = true
	_set_next_visible(false)
	_pop.set("enabled", false)
	_fade_timer.start()
	Audio.loop("liquid freeze_04")       # checkFreezerSoundPlayer 0xF5DB0


## sendIcePopToOriginalLocation (0xF5EAC): dropped outside the freezer --
## straight home, upside down, alphas restored over 1.0s.
func _send_home() -> void:
	_soaked = false
	_state = 0
	_fade_timer.stop()
	Audio.stop("liquid freeze_04")
	_pop.position = POP_HOME
	_pop.set("enabled", true)
	_pop.rotation = PI
	var tw := _tween()
	tw.set_parallel(true)
	tw.tween_property(_pop, "modulate:a", 1.0, RETURN_SECONDS)
	if _mold != null:
		tw.tween_property(_mold, "modulate:a", 1.0, RETURN_SECONDS)
	if _texture != null:
		tw.tween_property(_texture, "modulate:a", TEXTURE_REST_ALPHA,
			RETURN_SECONDS)
	# changeInstruction:@"inst_flash_freezer.png" here is a no-op: this
	# class's version (0xF6AC8) returns when the name equals
	# previousInstImgName, which it always does by now -- no re-slide.


## fadeIcePop (0xF6150): state++ each 1.5s tick. The fade tests the OLD
## state (<= 4, so ticks 1-5) and runs 0.5s linear ("FadeOutMold", curve 3);
## the finish / sound branches test the NEW state: 4 plays
## "liquid freeze_03", 5 finishes.
func _fade_tick() -> void:
	var prev := _state
	_state += 1
	if prev <= 4 and _soaked and _mold != null:
		_tween().tween_property(_mold, "modulate:a",
			_mold.modulate.a - FADE_STEP, FADE_SECONDS)
	if _state == DONE_STATE:
		_finish_freeze()
	elif _state == SOUND_STATE:
		Audio.play("liquid freeze_03")


## fadeIcePop's state-5 branch: stopFadeTimerForIcePop, showNextButton,
## rotatePerfectlyFrozenIcePop (0xF65B8), "SnapIcePop" back to origin.
func _finish_freeze() -> void:
	_done = true
	_fade_timer.stop()
	_set_next_visible(true)
	show_next_button()
	_pop.set("enabled", false)
	# "SnapIcePop": curve 3, linear.
	_tween().tween_property(_pop, "position", POP_HOME, SNAP_SECONDS)
	# "Rotate perfectly Frozen Ice Pop": curve 0, ease-in-out.
	_tween().tween_property(_pop, "rotation", DONE_ROTATION,
		DONE_ROTATE_SECONDS).set_trans(Tween.TRANS_SINE)
	get_tree().create_timer(REMOVE_MOLD_DELAY).timeout.connect(
		_animate_remove_mold)


## animateRemoveMold (0xF66D0): egg_crack, two half-scale copies of the mold
## art fly to (375,83) and (-225,83) spinning ~pi, vanish at 0.6s, and the
## real mold settles at alpha 0.3.
func _animate_remove_mold() -> void:
	if not is_inside_tree():
		# performSelector:afterDelay: fires while Make covers this screen
		# (next pressed within 0.3s of the finish): the crack is heard, the
		# mold drops to 0.3; the halves fly unseen. resetScreen on return
		# restores the mold.
		Audio.play("egg_crack")
		if _mold != null:
			_mold.modulate.a = MOLD_RESIDUE_ALPHA
		return
	Audio.play("egg_crack")
	var art := _tex(str(_freezer_meta.get("moldImg", "")))
	# v20 (left) insertSubview:belowSubview:texture; v10 (right)
	# insertSubview:aboveSubview:mold -- the topmost layer.
	var half_b := _fly_half(art, HALF_B_CENTER, HALF_B_SPIN, false)
	var half_a := _fly_half(art, HALF_A_CENTER, HALF_A_SPIN, true)
	for h in [half_a, half_b]:
		if h != null:
			get_tree().create_timer(HALF_LIFE).timeout.connect(h.queue_free)
	if _mold != null:
		_mold.modulate.a = MOLD_RESIDUE_ALPHA


func _fly_half(art: Texture2D, target_center: Vector2, spin: float,
		above_mold: bool) -> Sprite2D:
	if art == null or _pop == null:
		return null
	var h := Sprite2D.new()
	h.texture = art
	h.position = BODY_OFFSET
	h.scale = Vector2(PART_SCALE, PART_SCALE)
	_pop.add_child(h)
	if above_mold and _mold != null:
		_pop.move_child(h, _mold.get_index() + 1)
	elif _texture != null:
		_pop.move_child(h, _texture.get_index())
	var local := target_center - Vector2(75, 130)
	# "RemoveMold": curve 3, linear.
	var tw := _tween()
	tw.set_parallel(true)
	tw.tween_property(h, "position", local, REMOVE_SECONDS)
	tw.tween_property(h, "rotation", spin, REMOVE_SECONDS)
	return h


# -- handoff -----------------------------------------------------------

## nextClick: (0xF79C0): stop the freezer sounds and bake the two
## MakeViewController layers (values verified at 0xF7A78..0xF7E52).
func _on_nextClick() -> void:
	Audio.stop("freezer_02")
	Audio.stop("liquid freeze_04")
	Audio.play("button_press")
	GameState.custom_categories = {
		"IcePop": {
			"Properties": {
				"IsEdible": true, "ViewIndex": 2, "Type": "Stationary",
				"ItemCenterX": 0.0, "ItemCenterY": 50.0,
			},
			"Image": _bake_pop(),
		},
		"IcePopStick": {
			"Properties": {
				"IsEdible": false, "ViewIndex": 1, "Type": "Stationary",
				"ItemCenterX": 140.0, "ItemCenterY": 183.0,
			},
			"Image": _tex(str(_freezer_meta.get("stickImg", ""))),
		},
	}
	Nav.next()


## The (0,0,320,333) container render: juiceImg full strength under
## textureImg at alpha 0.5 (0xF7BFC), both at natural size.
func _bake_pop() -> Image:
	var out := Image.create(MASK_SIZE.x, MASK_SIZE.y, false, Image.FORMAT_RGBA8)
	var juice: Variant = _freezer_meta.get("juiceImg")
	if juice is Image:
		out.blit_rect(juice, Rect2i(Vector2i.ZERO, MASK_SIZE), Vector2i.ZERO)
	var real := _tex(str(_freezer_meta.get("textureImg", "")))
	if real != null:
		var img := real.get_image()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		for y in mini(img.get_height(), MASK_SIZE.y):
			for x in mini(img.get_width(), MASK_SIZE.x):
				var s := img.get_pixel(x, y)
				var a := s.a * 0.5
				if a <= 0.0:
					continue
				var d := out.get_pixel(x, y)
				var out_a := a + d.a * (1.0 - a)
				if out_a <= 0.0:
					continue
				out.set_pixel(x, y, Color(
					(s.r * a + d.r * d.a * (1.0 - a)) / out_a,
					(s.g * a + d.g * d.a * (1.0 - a)) / out_a,
					(s.b * a + d.b * d.a * (1.0 - a)) / out_a,
					out_a))
	return out


func _on_backClick() -> void:
	Audio.stop("freezer_02")
	Audio.stop("liquid freeze_04")
	Audio.play("button_press")
	Nav.back()


## viewWillDisappear: (0xF7828): both freezer sounds stopped, the fade
## timer invalidated. Animations in flight finish while covered (settled).
func on_exit() -> void:
	Audio.stop("freezer_02")
	Audio.stop("liquid freeze_04")
	if _fade_timer != null:
		_fade_timer.stop()
	kcKit.settle(_tweens)


func _tween() -> Tween:
	return kcKit.track(_tweens, create_tween())


func _set_next_visible(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.set("disabled", not on)
