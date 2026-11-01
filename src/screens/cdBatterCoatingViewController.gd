# Corn Dog step 6 -- dip the four skewered dogs in the batter jar.
#
# GROUNDED from initWithDictionary: (0xCB6D0), viewDidLoad (0xCCD38),
# viewWillAppear: (0xCD52C), resetDog:/resetScreen (0xCB44C / 0xCB5F4),
# draggableTouchBegan/Moved/Ended (0xCDE78 / 0xCDFE8 / 0xCE328),
# hasSpaceForDogFall: (0xCA6C0), startTimerForDog:/stopTimerForDog:
# (0xCB078 / 0xCB36C), nextImageForCorndog1..4 (0xCA8B8..0xCAE88),
# showNextButtonWhenAllFourAreReady (0xCA2A4), showNextButton (0xCA12C),
# showRedCrossAtPoint: (0xCA348), addGreenCheckMarkOnDog: (0xC9EE8),
# checkSnapDog: (0xCE758), backClick: (0xCD700) and nextClick: (0xCD7DC).
#
# Mechanic, as read: each dog is a DraggableIV built over
# cd_transparent_dog_bg.png at centre (50/120/190/260, 45), its frame widened
# by (+20, +55) to 50x185; the roll screen's finished dog (cd_dog_coated_4,
# tag 10) and the four battered stages (tags 11..14) are stacked inside at
# alpha 0, with the stick from StickSelect -- resized by 1/1.8 (float
# 0xCC004) -- behind them. Holding a dog with its centre below y = 335 and
# x in [93, 227] "soaks" it; a 1-second repeating timer advances the battered
# stage (fade out 2.0s / fade in 0.2s) while soaked. Dropping it there parks
# it in the jar (frame.y -> 259.5 over 0.5s). Dogs must keep 21pt of
# horizontal spacing from any soaked dog or a red cross appears. At stage 4 a
# ding plays and a green check appears; all four at stage 4 slide the next
# button in after 2 seconds.

extends "res://core/Screen.gd"

## DraggableIV centres after the +20/+55 widening (0xCB6D0): the init centre
## (50/120/190/260, 45) with frame (x-15, -20, 50, 185) -> (x+10, 72.5).
const DOG_CENTERS := [Vector2(60, 72.5), Vector2(130, 72.5),
	Vector2(200, 72.5), Vector2(270, 72.5)]
const DOG_HALF := Vector2(25, 92.5)
## viewDidLoad: rotate 30 deg (0x3F060A92), scale 0.8 (0x3F4CCCCD).
const REST_SCALE := 0.8
const REST_ROTATION := 0.5235988
## touchBegan (0xCDE78): 0.2s (0xCDFE0) linear to scale 0.8 / rotation 0.
const PICKUP_SECONDS := 0.2
## Stick resize divisor (float 0xCC004; also 0xD2C94 on the fry screen).
const STICK_DIV := 1.8
## Stage art centre inside the DraggableIV: subview centre + (10, 55)
## (0x4120000041200000 and DAT_0xCC008 = 55.0), i.e. art top-left (10, 55).
const STAGE_ART_OFFSET := Vector2(10, 55)
## Batter band (0xCDFE8/0xCE328): soak below y 335 (0xCE324), drop accepted
## below y 110 (0xCE748), x within [93, 227] (0xCE318/0xCE31C == 0xCE74C/
## 0xCE750). The drag may not push the frame's top past y 280 (0xCE320/
## 0xCE73C); a successful drop animates frame.y to 259.5 (0x4381C000) over
## 0.5s (0x3FE00000).
const SOAK_MIN_Y := 335.0
const DROP_MIN_Y := 110.0
const BAND_X_MIN := 93.0
const BAND_X_MAX := 227.0
const FRAME_Y_CLAMP := 280.0
const DROP_FRAME_Y := 259.5
const DROP_SECONDS := 0.5
## hasSpaceForDogFall: (0xCA6C0): |centre.x delta| < 21 (0x15) from a soaked
## dog means no room.
const SPACING := 21.0
## Batter timer: 1.0s repeating (0xCB6D0/0xCB078); stage fades 2.0s out
## (0x40000000) / 0.2s in (0xCAAA0); four stages.
const TICK_SECONDS := 1.0
const FADE_OUT := 2.0
const FADE_IN := 0.2
const STAGES := 4
## Failed release: checkSnapDog: 0.3s later (0x3FD3333340000000), home over
## 0.2s (0xCE890) -- but only if the dog is not already home. Usually it is:
## draggableTouchMoved: sets the DraggableIV's snapTime to 0.2 whenever the
## dog is outside the drop band or a red cross shows (0 inside the band), and
## DraggableIV's own touchesEnded: (0x46860) runs BEFORE this delegate --
## snapTime != 0 -> it animates the centre to origCenter over snapTime,
## linear, at once. So a dog let go outside the band flies home immediately;
## the delayed checkSnapDog: only moves a dog whose last move left snapTime 0.
## Pose restored over 0.2s (0xCE740).
const SNAP_DELAY := 0.3
const SNAP_SECONDS := 0.2
## Red cross: redCross.center = dog.centre + (15, -52) (0xCA348, DAT_0xCA388).
const CROSS_OFFSET := Vector2(15, -52)
## Green check (0xC9EE8): tag 999, 30x30 frame (scale 0.3 of the 100x100 art),
## centre (frame.width * 0.5 + 17, frame.height * 0.5 - 43) in the dog's own
## coordinates (disassembly 0xC9FD2..0xC9FFE; -43.0 is the double at 0xCA058).
## `frame` is the dog's transformed bounding box when the check is first
## shown -- on a ding tick, so the dog is in the jar at its held pose
## (rotation 0, scale 0.8): frame 40x148 -> local (37, 31), i.e. (+12, -61.5)
## from the dog's centre. (It used to be a fixed (+17, -135.5), which floated
## the check 74pt above the dog.) showGreenCheckMarkOnDog: (0xCA060) also
## sets userInteractionEnabled NO: a finished dog can no longer be picked up.
const CHECK_SCALE := 0.3
## All-ready: next slides in 2.0s after the fourth ding (0xCA2A4).
const NEXT_DELAY := 2.0

const BATTER_SIDE := {0: "cd_batter_normal_side.png",
	1: "cd_batter_honey_side.png", 2: "cd_batter_choc_side.png",
	3: "cd_batter_spicy_side.png"}
const STAGE_ART := {0: "cd_dog_battered_original_%d.png",
	1: "cd_dog_battered_honey_%d.png", 2: "cd_dog_battered_choc_%d.png",
	3: "cd_dog_battered_spicy_%d.png"}

var _batter := 0
## {node, stages: Array[Sprite2D] (index 0 = tag 10), check, origin, state,
##  soaked, ding, timing, acc, model, model_rot, model_scale, snap, tweens}
var _dogs: Array = []
var _drag_index := -1
var _grab := Vector2.ZERO
var _cross: Sprite2D
var _next_shown := false
## initWithDictionary:'s infoDict (batter, stickImg, packID from StickSelect),
## kept so nextClick: hands cdFry THIS dict even when next is pressed again
## after a back -- by then the carrier holds a later screen's dict.
var _info: Dictionary = {}


func on_enter() -> void:
	_info = GameState.custom_categories.duplicate()
	_batter = int(GameState.custom_categories.get("batter", 0))
	var b := outlet("batter")
	if b is Sprite2D:
		var t := _tex(BATTER_SIDE.get(_batter, BATTER_SIDE[0]))
		if t != null:
			(b as Sprite2D).texture = t
	var next := outlet("nextButton")
	if next != null and next != self:
		(next as CanvasItem).visible = false   # resetScreen (0xCB5F4) tail
	_build_dogs()
	# viewDidLoad adds the red cross after the dogs, so it draws above them.
	_build_cross()
	set_process(true)


## UINavigationController keeps this controller alive under cdFry (Nav.gd's
## opt-in). viewWillDisappear: is super only, so nothing stops on push -- the
## four 1s batter NSTimers keep running while covered (see on_resume). On
## back viewWillAppear: runs again and RESETS the step via resetScreen.
func keeps_state_on_push() -> bool:
	return true


## viewWillAppear: (0xCD52C): isDogNDingPlayed = NO x4, instIV unhidden (no
## slide), resetScreen (0xCB5F4) -- resetDog: (0xCB44C) per dog: transform
## scale 0.8 then rotate 30 deg, setDog:Soaked:NO (the flag only; the
## timers are not touched), state 0, centre back to origCenter,
## userInteractionEnabled YES, tag 10 alpha 1 and tags 11..14 alpha 0;
## then the checks hidden and nextButton hidden.
## INFERRED/port limit: the original's timers free-run while covered; the
## port's _process pauses out of the tree, so each dog's tick phase resumes
## where it stopped (a sub-second phase difference, nothing visible --
## every dog is unsoaked after the reset).
func on_resume() -> void:
	var iv := _instruction_node()
	if iv != null:
		if _instruction_home_set:
			iv.position = _instruction_home
		iv.visible = true
		iv.modulate.a = 1.0
	_drag_index = -1
	_next_shown = false
	for d: Dictionary in _dogs:
		_kill_dog_tweens(d)
		d["ding"] = false
		d["soaked"] = false
		d["state"] = 0
		d["model"] = d["origin"]
		d["model_rot"] = REST_ROTATION
		d["model_scale"] = REST_SCALE
		var w := d["node"] as Node2D
		w.position = d["origin"]
		w.rotation = REST_ROTATION
		w.scale = Vector2(REST_SCALE, REST_SCALE)
		var stages: Array = d["stages"]
		for i in stages.size():
			(stages[i] as Sprite2D).modulate.a = 1.0 if i == 0 else 0.0
		if d["check"] != null:
			(d["check"] as Sprite2D).visible = false
	var next := outlet("nextButton")
	if next != null and next != self:
		(next as CanvasItem).visible = false


func _kill_dog_tweens(d: Dictionary) -> void:
	for key: String in ["tweens", "fades"]:
		for t: Tween in d[key]:
			if t != null and t.is_valid():
				t.kill()
		(d[key] as Array).clear()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## ff_red_x.png in a 30x30 frame (0xCB6D0 tail), parked at (-100, -100).
func _build_cross() -> void:
	_cross = Sprite2D.new()
	_cross.texture = _tex("ff_red_x.png")
	_cross.scale = Vector2(0.3, 0.3)
	_cross.position = Vector2(-100, -100)
	add_child(_cross)


func _build_dogs() -> void:
	var stick: Variant = GameState.custom_categories.get("stickImg")
	for d: Dictionary in _dogs:
		if is_instance_valid(d["node"]):
			(d["node"] as Node).queue_free()
	_dogs.clear()

	for center: Vector2 in DOG_CENTERS:
		var w := Node2D.new()
		w.position = center
		w.rotation = REST_ROTATION
		w.scale = Vector2(REST_SCALE, REST_SCALE)
		add_child(w)

		# The stick, behind everything (insertSubview:atIndex:0), scaled by
		# 1/1.8, its top-left at ((dogW/2 - stickW/2) - 3, -5) -> centred at
		# (-3, stickH/2 - 97.5) from the dog centre. Absent if StickSelect
		# has not supplied one (dev entry), not substituted.
		if stick is Texture2D:
			var st := Sprite2D.new()
			st.texture = stick
			st.scale = Vector2.ONE / STICK_DIV
			var sh: float = (stick as Texture2D).get_size().y / STICK_DIV
			st.position = Vector2(-3, sh * 0.5 - DOG_HALF.y - 5.0)
			w.add_child(st)

		# Stage stack: tag 10 = cd_dog_coated_4 (the roll screen's output),
		# tags 11..14 = battered stages 1..4. resetDog: (0xCB44C) leaves
		# tag 10 at alpha 1 and the rest at 0.
		var stages: Array = []
		for i in range(0, 5):
			var file: String = "cd_dog_coated_4.png" if i == 0 \
				else (str(STAGE_ART[_batter]) % i)
			var t2 := _tex(file)
			var sp := Sprite2D.new()
			sp.texture = t2
			if t2 != null:
				sp.position = Vector2(t2.get_size()) * 0.5 \
					+ STAGE_ART_OFFSET - DOG_HALF
			sp.modulate.a = 1.0 if i == 0 else 0.0
			w.add_child(sp)
			stages.append(sp)
		# initWithDictionary: adds the stage views from tag 14 DOWN to tag 10,
		# so tag 10 (the floured dog) is the TOP subview and each battered
		# stage sits under the one before it: a stage change shows the new art
		# fading in beneath (0.2s) while the old one fades off above it (2.0s).
		# They were stacked the other way, so each new stage popped in on top.
		for i in range(stages.size() - 1, -1, -1):
			w.move_child(stages[i] as Node, -1)

		# `check` is created on first show (addGreenCheckMarkOnDog:).
		# `model*` mirror the UIView model values (UIKit reports an animation's
		# end value as soon as it is committed); `snap` is the DraggableIV's
		# snapTime, which DraggableIV init sets to 0.
		_dogs.append({"node": w, "stages": stages, "check": null,
			"origin": center, "state": 0, "soaked": false, "ding": false,
			"timing": true, "acc": 0.0, "model": center,
			"model_rot": REST_ROTATION, "model_scale": REST_SCALE,
			"snap": 0.0, "tweens": [], "fades": []})


# -- dragging ---------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and _drag_index < 0:
			# Topmost first (dogs 1..4 were added in order); a dog wearing its
			# green check has userInteractionEnabled NO.
			for i in range(_dogs.size() - 1, -1, -1):
				if _check_visible(_dogs[i]):
					continue
				var w := _dogs[i]["node"] as Node2D
				if _model_hit(_dogs[i], mb.position):
					_drag_index = i
					_begin_drag(_dogs[i])
					_grab = w.position - mb.position   # from the model centre
					get_viewport().set_input_as_handled()
					return
		elif not mb.pressed and _drag_index >= 0:
			_end_drag(_dogs[_drag_index])
			_drag_index = -1
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _drag_index >= 0:
		var d: Dictionary = _dogs[_drag_index]
		var p: Vector2 = (event as InputEventMouseMotion).position + _grab
		# DraggableIV touchesMoved: setCenter: moves the model under any
		# running SnapToOrig (checkSnapDog: can fire on a dog picked up again
		# within 0.3 s), so the dog follows the finger; a home tween left
		# running would pull it away between moves.
		var mt: Variant = d.get("move_tw")
		if mt is Tween and (mt as Tween).is_valid():
			(mt as Tween).kill()
		(d["node"] as Node2D).position = p
		d["model"] = p
		_moved(d)
		get_viewport().set_input_as_handled()


## touchBegan (0xCDE78): pickup sound, stand the dog upright at scale 0.8.
func _begin_drag(d: Dictionary) -> void:
	Audio.play("pickup")
	var w := d["node"] as Node2D
	_snap_to_model(d)
	d["model_rot"] = 0.0
	d["model_scale"] = REST_SCALE
	var tw := create_tween().set_parallel(true)
	tw.tween_property(w, "scale", Vector2(REST_SCALE, REST_SCALE),
		PICKUP_SECONDS).set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(w, "rotation", 0.0, PICKUP_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)
	(d["tweens"] as Array).append(tw)


## RotateDog / DropDog / SnapToOrig (0xCDE78, 0xCE328, 0xCE758, and the
## DraggableIV's own 0x46860) are all +beginAnimations:/commitAnimations: the
## dog stays touchable while they run (UIViewAnimationState answers
## _allowsUserInteraction YES, 0x3307B220), and UIKit hit-tests its MODEL
## geometry -- a dog flying home answers at its origin, not where it is
## drawn. The port used to hit-test the drawn dog, take the drag offset from
## there and then snap the dog to its model, so it jumped away from the
## finger and back.
func _model_hit(d: Dictionary, p: Vector2) -> bool:
	var w := d["node"] as Node2D
	var xf := Transform2D(float(d["model_rot"]),
		Vector2.ONE * float(d["model_scale"]), 0.0, d["model"] as Vector2)
	var parent := w.get_parent() as CanvasItem
	if parent != null:
		xf = parent.get_global_transform() * xf
	return Rect2(-DOG_HALF, DOG_HALF * 2.0).has_point(xf.affine_inverse() * p)


## INFERRED: a new touch supersedes in-flight UIView animations at their model
## values (old-style animations without BeginFromCurrentState).
## PORT CHOICE: UIKit's drawn dog would glide on to the finger for the rest
## of a position animation; the port lands it on the model at once.
func _snap_to_model(d: Dictionary) -> void:
	for t: Tween in d["tweens"]:
		if t != null and t.is_valid():
			t.kill()
	(d["tweens"] as Array).clear()
	var w := d["node"] as Node2D
	w.position = d["model"]
	w.rotation = d["model_rot"]
	w.scale = Vector2.ONE * float(d["model_scale"])


func _check_visible(d: Dictionary) -> bool:
	return d["check"] != null and (d["check"] as Sprite2D).visible


## The frame-top clamp: at the dragging pose (rotation 0, scale 0.8) the
## 185pt frame is 148pt tall, so frame.y = centre.y - 74; frame.y <= 280
## means centre.y <= 354. (Mid-pickup-tween the original's transformed frame
## is briefly taller; the settled pose is used here.)
func _clamp_drag_y(w: Node2D) -> void:
	var max_y := FRAME_Y_CLAMP + DOG_HALF.y * REST_SCALE
	if w.position.y > max_y:
		w.position.y = max_y


func _has_space(d: Dictionary) -> bool:
	for other: Dictionary in _dogs:
		if other == d or not other["soaked"]:
			continue
		if absf((other["node"] as Node2D).position.x
				- (d["node"] as Node2D).position.x) < SPACING:
			return false
	return true


## touchMoved (0xCDFE8).
func _moved(d: Dictionary) -> void:
	var w := d["node"] as Node2D
	# snapTime first, from the unclamped centre: 0 inside the drop band
	# (y > 110, x in [93, 227]), else 0.2.
	var c0 := w.position
	d["snap"] = 0.0 if (c0.y > DROP_MIN_Y and c0.x >= BAND_X_MIN
		and c0.x <= BAND_X_MAX) else SNAP_SECONDS
	_clamp_drag_y(w)
	d["model"] = w.position
	var c := w.position
	var in_band := c.x >= BAND_X_MIN and c.x <= BAND_X_MAX
	var space := _has_space(d)
	if space and in_band:
		_remove_cross()
	elif c.y > DROP_MIN_Y:
		d["snap"] = SNAP_SECONDS   # setSnapTime:0.2 on the cross path
		if not _check_visible(d):
			_show_cross(c)
	else:
		_remove_cross()
	if c.y > SOAK_MIN_Y and in_band:
		_set_soaked(d, true)
	else:
		_set_soaked(d, false)


## touchEnded: DraggableIV's own handler (0x46860) first, then the
## delegate's (0xCE328).
func _end_drag(d: Dictionary) -> void:
	var w := d["node"] as Node2D
	# DraggableIV: snapTime != 0 -> centre to origCenter over snapTime,
	# linear, now; the delegate below then sees the model centre = origin.
	if float(d["snap"]) > 0.0:
		_tween_home(d, float(d["snap"]))
	else:
		_clamp_drag_y(w)
		d["model"] = w.position
	var c: Vector2 = d["model"]
	if c.y > DROP_MIN_Y and c.x >= BAND_X_MIN and c.x <= BAND_X_MAX \
			and _has_space(d):
		# DropDog: frame.y -> 259.5 over 0.5s linear; the dog parks in the
		# jar, upright, and keeps soaking.
		var target_y := DROP_FRAME_Y + DOG_HALF.y * REST_SCALE
		d["model"] = Vector2(c.x, target_y)
		var drop := create_tween()
		drop.tween_property(w, "position:y", target_y,
			DROP_SECONDS).set_trans(Tween.TRANS_LINEAR)
		(d["tweens"] as Array).append(drop)
		_set_soaked(d, true)
		Audio.play("cd_batter_dip")
		return
	# Failed drop: snapTime 0.2; checkSnapDog: 0.3s later; pose back to
	# scale 0.8 / 30 deg over 0.2s linear now.
	d["snap"] = SNAP_SECONDS
	d["model_rot"] = REST_ROTATION
	d["model_scale"] = REST_SCALE
	var tw := create_tween().set_parallel(true)
	tw.tween_property(w, "scale", Vector2(REST_SCALE, REST_SCALE),
		SNAP_SECONDS).set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(w, "rotation", REST_ROTATION, SNAP_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)
	(d["tweens"] as Array).append(tw)
	get_tree().create_timer(SNAP_DELAY).timeout.connect(func() -> void:
		# checkSnapDog: (0xCE758): home over 0.2s only if not already there.
		# Off the tree (pushed within 0.3s) the return's resetDog: puts the
		# dog home anyway, so the late call is dropped.
		if is_inside_tree() and is_instance_valid(w) \
				and not (d["model"] as Vector2).is_equal_approx(d["origin"] as Vector2):
			_tween_home(d, SNAP_SECONDS))
	_set_soaked(d, false)
	_remove_cross()


func _tween_home(d: Dictionary, seconds: float) -> void:
	d["model"] = d["origin"]
	var home := create_tween()
	home.tween_property(d["node"] as Node2D, "position", d["origin"] as Vector2,
		seconds).set_trans(Tween.TRANS_LINEAR)
	(d["tweens"] as Array).append(home)
	d["move_tw"] = home


func _show_cross(dog_center: Vector2) -> void:
	_cross.position = dog_center + CROSS_OFFSET


func _remove_cross() -> void:
	_cross.position = Vector2(-100, -100)   # removeRedCross (0xCA38C)


## setDog:Soaked: plus start/stopTimerForDog:. The original's four 1s timers
## free-run from init and no-op while unsoaked; stopTimerForDog: invalidates
## and startTimerForDog: only rebuilds an invalidated one, so a re-soak
## restarts the phase while the very first soak inherits the free-running
## phase. `timing`/`acc` reproduce that exactly.
func _set_soaked(d: Dictionary, value: bool) -> void:
	if value:
		d["soaked"] = true
		if not d["timing"]:
			d["timing"] = true
			d["acc"] = 0.0
	else:
		d["soaked"] = false
		d["timing"] = false


func _process(delta: float) -> void:
	for d: Dictionary in _dogs:
		if not d["timing"]:
			continue
		d["acc"] = float(d["acc"]) + delta
		while float(d["acc"]) >= TICK_SECONDS:
			d["acc"] = float(d["acc"]) - TICK_SECONDS
			_tick(d)


## nextImageForCorndogN (0xCA8B8..): advance the battered stage while soaked;
## at stage 4, one ding and the green check; then the all-ready test.
func _tick(d: Dictionary) -> void:
	var state: int = d["state"]
	if state < STAGES and d["soaked"]:
		var stages: Array = d["stages"]
		var fading := stages[state] as Sprite2D
		d["state"] = state + 1
		var rising := stages[state + 1] as Sprite2D
		var out := create_tween()
		out.tween_property(fading, "modulate:a", 0.0, FADE_OUT) \
			.set_trans(Tween.TRANS_LINEAR)
		var into := create_tween()
		into.tween_property(rising, "modulate:a", 1.0, FADE_IN) \
			.set_trans(Tween.TRANS_LINEAR)
		(d["fades"] as Array).append_array([out, into])
	elif state == STAGES and not d["ding"]:
		Audio.play("cc_sugar_ding")   # 0x6BACF4
		_show_check(d)
		d["ding"] = true
	_check_all_ready()


## showGreenCheckMarkOnDog: (0xCA060): unhide the check or add it
## (addGreenCheckMarkOnDog: 0xC9EE8) from the dog's transformed frame at this
## moment (model pose), and lock the dog. Node-local = bounds-local - bounds/2.
func _show_check(d: Dictionary) -> void:
	if d["check"] == null:
		var r: float = d["model_rot"]
		var sc: float = d["model_scale"]
		var b := DOG_HALF * 2.0
		var fw := (absf(cos(r)) * b.x + absf(sin(r)) * b.y) * sc
		var fh := (absf(sin(r)) * b.x + absf(cos(r)) * b.y) * sc
		var check := Sprite2D.new()
		check.texture = _tex("ff_green_check.png")
		check.scale = Vector2(CHECK_SCALE, CHECK_SCALE)
		check.position = Vector2(fw * 0.5 + 17.0, fh * 0.5 - 43.0) - DOG_HALF
		(d["node"] as Node2D).add_child(check)
		d["check"] = check
	(d["check"] as Sprite2D).visible = true
	# userInteractionEnabled NO: the hit test in _unhandled_input skips the
	# dog from now on. INFERRED: a touch already under way keeps its view
	# (UIKit does not re-hit-test an in-flight touch), so a current drag runs on.


func _check_all_ready() -> void:
	if _next_shown:
		return
	for d: Dictionary in _dogs:
		if int(d["state"]) != STAGES:
			return
	_next_shown = true
	get_tree().create_timer(NEXT_DELAY).timeout.connect(func() -> void:
		# showNextButton (0xCA12C) bails if instIV is already hidden.
		if is_inside_tree():
			show_next_button())


## nextClick: (0xCD7DC): button_press, push cdFryDogViewController
## initWithDictionary: with the same infoDict. The carrier travels untouched.
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.custom_categories = _info.duplicate()
	Nav.next()


func _on_skipClick() -> void:   # skipClick: (0xCD89C) calls nextClick:.
	_on_nextClick()


## backClick: (0xCD700): button_press, invalidate the four timers, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()
