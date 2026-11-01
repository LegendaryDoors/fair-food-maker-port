# Corn Dog step 7 -- fry the battered dogs, then hand the finished food to
# the decorate screen.
#
# GROUNDED from initWithDictionary: (0xD23A8), viewDidLoad (0xD3D08),
# viewWillAppear: (0xD469C), viewWillDisappear: (0xD4818), resetDog:/
# resetScreen (0xD2150 / 0xD2314), draggableTouchBegan/Moved/Ended
# (0xD5548 / 0xD5680 / 0xD58C8), nextImageForCorndog1..4 (0xD02A8..0xD0800),
# startBubblingForCorndog1..4 (0xD09D8..0xD16E0), startTimerForDog:/
# startTimerForDogBubbling: (0xD1B38 / 0xD1E30), vibrateDog:forDuration:
# (0xCFCB8), checkFryingSoundPlayer (0xCFE08), sendDogToOriginalLocation:
# (0xCFFD0), showNextButtonWhenAllFourAreReady (0xCF684), showRedCrossAtPoint:
# (0xCF30C), addGreenCheckMarkOnDog: (0xCEF78), startBurner/stopBurner
# (0xD486C / 0xD48F8), backClick: (0xD492C) and nextClick: (0xD4AB4).
#
# Same dog substrate as the coating screen, oil band instead of batter band.
# A soaked dog advances cd_dog_fried_*_1..4 every 3 seconds and sprouts oil
# bubbles every 0.05s; at stage 4 its fry timer stops and it vibrates until
# lifted out, which pins the green check. The next button appears only when
# all four are at stage 4 AND none is still in the oil.
#
# Dead code, left out with addresses: the burnt path. burntDog: (0xD01D0),
# the cd_dog_burnt_* art (tag 15, loaded at 0xD23A8) and
# randomTransformDegreeForDog: (0xCFC30) have NO __objc_selrefs entry -- the
# only pointer to either selector is its own method-list row (0x6FA8D4 /
# 0x6FA8AC) -- so nothing in v1.27 can burn a dog. The tag-15 sprite is still
# built, alpha 0, exactly as the original allocates it.
#
# The burner flame is the SSEmitter `fire` (nib id 6, frame (0,382,320,42),
# below instIV): configured in viewDidLoad (0xD3D08, call 0xD443E) with
# Hot_Dog_Flame_PS_1..4, started by startBurner (0xD486C) 0.5s after every
# viewWillAppear:, stopped by stopBurner (0xD48F8) from viewWillDisappear:
# (wired as read). Not ported: the AdColony interstitial (0xD4318).

extends "res://core/Screen.gd"

## DraggableIV centres, widened frame and pose -- identical construction to
## the coating screen (0xD23A8): centres (60/130/200/270, 72.5), frame
## 50x185, rest rotation 30 deg, scale 0.8 (viewDidLoad 0xD3D08).
const DOG_CENTERS := [Vector2(60, 72.5), Vector2(130, 72.5),
	Vector2(200, 72.5), Vector2(270, 72.5)]
const DOG_HALF := Vector2(25, 92.5)
const REST_SCALE := 0.8
const REST_ROTATION := 0.5235988
## touchBegan (0xD5548): 0.2s (0xD5678) linear to scale 0.9 (0x3F666666),
## rotation 0. No pickup sound on this screen. The failed-release pose goes
## back to scale 0.8 (0xD58C8), so a dog only stands at 0.9 while held or
## frying -- as read.
const PICKUP_SECONDS := 0.2
const DRAG_SCALE := 0.9
## Stick divisor (0xD2C94) and stage-art y offset (0xD2C98).
const STICK_DIV := 1.8
## Tag 10 art centre offset (+10, +55); tags 11..15 use (+7, +55) -- the
## fried art is drawn 3pt further left, an original quirk (0xD3744 block).
const STAGE10_OFFSET := Vector2(10, 55)
const STAGE_OFFSET := Vector2(7, 55)
## Oil band: drag centre clamped to y <= 290 (0xD58B0/0xD5C5C, set 290 =
## 0x43910000); x in [60, 260] (0xD58B4/0xD58B8 = 0xD5C64/0xD5D48); red cross
## past y 120 (0xD58BC/0xD5C60); soaking from y >= 275 (0xD58C0). A drop
## animates centre.y to 290 over 0.5s (0x3FE00000).
const CENTER_Y_CLAMP := 290.0
const BAND_X_MIN := 60.0
const BAND_X_MAX := 260.0
const DROP_MIN_Y := 120.0
const SOAK_MIN_Y := 275.0
const DROP_SECONDS := 0.5
## hasSpaceForDogFall: (0xCF804): 21pt horizontal spacing, as on coating.
const SPACING := 21.0
## Fry timer: 3.0s repeating (0x40080000 at 0xD3A78 block / 0xD1B38); stage
## fades 3.0s out / 0.2s in (0xD0460); four stages.
const TICK_SECONDS := 3.0
const FADE_OUT := 3.0
const FADE_IN := 0.2
const STAGES := 4
## Bubbling timer 0.05s (0xD3A78 / 0xD2148).
const BUBBLE_TICK := 0.05
## Bubbles: art / 5.4 (0xD0E20); top-left x = frame.x + rand % (frame.w - 15),
## y = frame.y + 55 (0xD0E28) + rand % (frame.h - 55); alpha 0.75; float to
## centre.y 242 (0x43720000) and alpha 0.2 over 0.5s ease-in; removed at 1s.
const BUBBLE_DIV := 5.4
const BUBBLE_ALPHA := 0.75
const BUBBLE_END_Y := 242.0
const BUBBLE_END_ALPHA := 0.2
const BUBBLE_FLOAT := 0.5
const BUBBLE_LIFE := 1.0
const BUBBLE_ART := ["cd_mixed_oil.png", "cd_mixed_oil2.png",
	"cd_mixed_oil3.png"]
## Done-vibrate (0xCFCB8): rotate a further 0.0872665 rad (0x3DB2B8C2, 5 deg)
## over 0.1s (0xCFE00), autoreversing forever.
const VIBRATE_ROT := 0.0872665
const VIBRATE_SECONDS := 0.1
## Failed release: pose and home over 0.2s each (0xD58C8 / 0xD5D40).
const SNAP_SECONDS := 0.2
## Red cross offset (0xCF30C, DAT_0xCF34C) -- same (15, -52) as coating.
const CROSS_OFFSET := Vector2(15, -52)
## Green check (0xCEF78): tag 999, 30x30 (scale 0.3), centre
## (frame.width * 0.5 - 17, frame.height * 0.5 - 40) in the dog's own
## coordinates, `frame` being the transformed bounding box when it is first
## shown: in touchEnded's failure path, right after the RotateDog block
## committed scale 0.8 / 30 deg -- frame 108.6 x 148.2 -> local (37.3, 34.1),
## i.e. (+12.3, -58.4) from the dog's centre. (It used to be a fixed
## (-17, -40) from the centre.) showGreenCheckMarkOnDog: (0xCF0F0) also sets
## userInteractionEnabled NO, so a finished dog lifted out stays put.
const CHECK_SCALE := 0.3

const STAGE_SETS := {
	0: ["cd_dog_battered_original_4.png", "cd_dog_fried_original_1.png",
		"cd_dog_fried_original_2.png", "cd_dog_fried_original_3.png",
		"cd_dog_fried_original_4.png", "cd_dog_burnt_original.png"],
	1: ["cd_dog_battered_honey_4.png", "cd_dog_fried_honey_1.png",
		"cd_dog_fried_honey_2.png", "cd_dog_fried_honey_3.png",
		"cd_dog_fried_honey_4.png", "cd_dog_burnt_honey.png"],
	2: ["cd_dog_battered_choc_4.png", "cd_dog_fried_choc_1.png",
		"cd_dog_fried_choc_2.png", "cd_dog_fried_choc_3.png",
		"cd_dog_fried_choc_4.png", "cd_dog_burnt_choc.png"],
	3: ["cd_dog_battered_spicy_4.png", "cd_dog_fried_spicy_1.png",
		"cd_dog_fried_spicy_2.png", "cd_dog_fried_spicy_3.png",
		"cd_dog_fried_spicy_4.png", "cd_dog_burnt_spicy.png"],
}

# -- the bake (nextClick: 0xD4AB4) ------------------------------------

const FINAL_ART := {0: "cd_dog_final_original.png",
	1: "cd_dog_final_honey.png", 2: "cd_dog_final_choc.png",
	3: "cd_dog_final_spicy.png"}
## CornDog layer: ViewIndex 2, edible, ItemCenter (122.5, 50) (0x42F50000 /
## 0x42480000). MakeViewController's DecorateItemViews are zero-frame, so
## these are the art's TOP-LEFT.
const DOG_HANDOFF := Vector2(122.5, 50)
## CornDogSkewer: ViewIndex 1, inedible, y 183 (0x43370000); x 145.5
## (0xD4F60) when the stick art is exactly 31pt wide, else 153.5 (0xD4F5C;
## 0xD4F64 gives the same 153.5 when there is no stick).
const SKEWER_Y := 183.0
const SKEWER_X_NARROW := 145.5
const SKEWER_X := 153.5

var _batter := 0
## {node, stages, check, origin, state, soaked, ding_done(unused here),
##  fry_timing, fry_acc, bub_timing, bub_acc, vibrate: Tween}
var _dogs: Array = []
var _drag_index := -1
var _grab := Vector2.ZERO
var _cross: Sprite2D
var _container: Node
var _oil_mask: Node
## initWithDictionary:'s infoDict (batter, stickImg, packID), kept so a
## second nextClick: after a back still bakes THIS food's skewer -- by then
## the carrier holds the dict handed to MakeViewController.
var _info: Dictionary = {}
## The burner flame.
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")
const FIRE := "cdFryDogViewController.fire"
var _fire: SSEmitter
## performSelector:startBurner afterDelay:0.5 (double 0x3FE0000000000000).
const BURNER_DELAY := 0.5


func on_enter() -> void:
	_info = GameState.custom_categories.duplicate()
	_batter = int(_info.get("batter", 0))
	var next := outlet("nextButton")
	if next != null and next != self:
		(next as CanvasItem).visible = false   # resetScreen tail
	_oil_mask = outlet("oilMask")
	_container = _oil_mask.get_parent() if _oil_mask != null else self
	_build_dogs()
	_build_cross()
	_build_fire()
	set_process(true)
	_schedule_burner()


## viewDidLoad (0xD3D08, call 0xD443E): the nib's `fire` SSEmitter.
func _build_fire() -> void:
	var host := outlet("fire")
	if host == null or host == self:
		return
	_fire = SSEmitter.attach(host, SSEmitterConfigs.frame_size(FIRE)) as SSEmitter
	SSEmitterConfigs.apply(_fire, FIRE, null)


## viewWillAppear: (0xD469C): performSelector:startBurner afterDelay:0.5.
## startBurner (0xD486C): [fire start], loop frying_lo_loop.
## PORT CHOICE: the original never cancels this perform, so leaving within
## 0.5s would start the flame and the loop on a covered (or popped)
## controller; the port drops the call once the screen is off the tree.
func _schedule_burner() -> void:
	get_tree().create_timer(BURNER_DELAY).timeout.connect(func() -> void:
		if not is_inside_tree():
			return
		if _fire != null:
			_fire.start()
		Audio.loop("frying_lo_loop"))


## UINavigationController keeps this controller alive under Make (Nav.gd's
## opt-in). viewWillDisappear: only stops the flame; the eight NSTimers keep
## running while covered (every dog is out of the oil by then, so they tick
## to no effect). On back viewWillAppear: runs again and RESETS the step.
func keeps_state_on_push() -> bool:
	return true


## viewWillAppear: (0xD469C): instIV unhidden (no slide), startBurner in
## 0.5s, resetScreen (0xD2314) -- resetDog: (0xD2150) per dog: check hidden,
## transform scale 0.8 then rotate 30 deg, setDog:Soaked:NO (the flag only,
## timers untouched), state 0, centre back to origCenter, interaction on,
## tag 10 alpha 1, tags 11..14 alpha 0 (tag 15 is left alone), dog alpha 1;
## then nextButton hidden.
func on_resume() -> void:
	var iv := _instruction_node()
	if iv != null:
		if _instruction_home_set:
			iv.position = _instruction_home
		iv.visible = true
		iv.modulate.a = 1.0
	_schedule_burner()
	_drag_index = -1
	for d: Dictionary in _dogs:
		_stop_vibrate(d)
		for t: Tween in d["fades"]:
			if t != null and t.is_valid():
				t.kill()
		(d["fades"] as Array).clear()
		if d["check"] != null:
			(d["check"] as Sprite2D).visible = false
		d["soaked"] = false
		d["state"] = 0
		_kill_tweens(d)
		d["model"] = d["origin"]
		d["model_rot"] = REST_ROTATION
		d["model_scale"] = REST_SCALE
		var w := d["node"] as Node2D
		w.position = d["origin"]
		w.rotation = REST_ROTATION
		w.scale = Vector2(REST_SCALE, REST_SCALE)
		w.modulate.a = 1.0
		var stages: Array = d["stages"]
		for i in mini(stages.size(), 5):
			(stages[i] as Sprite2D).modulate.a = 1.0 if i == 0 else 0.0
	var next := outlet("nextButton")
	if next != null and next != self:
		(next as CanvasItem).visible = false


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _build_cross() -> void:
	_cross = Sprite2D.new()
	_cross.texture = _tex("ff_red_x.png")
	_cross.scale = Vector2(0.3, 0.3)   # 30x30 frame over the 100x100 art
	_cross.position = Vector2(-100, -100)
	add_child(_cross)


## viewDidLoad inserts each dog below the oilMask (cd_oil), so a dropped dog
## sinks behind the oil surface. The port parents them into the same
## container, before the oilMask node.
func _build_dogs() -> void:
	var stick: Variant = _info.get("stickImg")
	var files: Array = STAGE_SETS.get(_batter, STAGE_SETS[0])
	for d: Dictionary in _dogs:
		if is_instance_valid(d["node"]):
			(d["node"] as Node).queue_free()
	_dogs.clear()

	for center: Vector2 in DOG_CENTERS:
		var w := Node2D.new()
		w.position = center
		w.rotation = REST_ROTATION
		w.scale = Vector2(REST_SCALE, REST_SCALE)
		_container.add_child(w)
		if _oil_mask != null and _oil_mask.get_parent() == _container:
			_container.move_child(w, _oil_mask.get_index())

		if stick is Texture2D:
			var st := Sprite2D.new()
			st.texture = stick
			st.scale = Vector2.ONE / STICK_DIV
			var sh: float = (stick as Texture2D).get_size().y / STICK_DIV
			st.position = Vector2(-3, sh * 0.5 - DOG_HALF.y - 5.0)
			w.add_child(st)

		var stages: Array = []
		for i in files.size():
			var t := _tex(files[i])
			var sp := Sprite2D.new()
			sp.texture = t
			if t != null:
				var off := STAGE10_OFFSET if i == 0 else STAGE_OFFSET
				sp.position = Vector2(t.get_size()) * 0.5 + off - DOG_HALF
			sp.modulate.a = 1.0 if i == 0 else 0.0
			w.add_child(sp)
			stages.append(sp)
		# initWithDictionary: adds tag 15 first and tag 10 LAST, so the
		# battered dog (tag 10) is the top subview and each fried stage sits
		# beneath the previous one: a stage change fades the new art in under
		# (0.2s) while the old one fades off on top (3.0s). Port order used to
		# be the reverse, popping each stage in over the last.
		for i in range(stages.size() - 1, -1, -1):
			w.move_child(stages[i] as Node, -1)

		# `check` is created on first show (addGreenCheckMarkOnDog:). `model*`
		# mirror the UIView model transform (committed end values), which the
		# check placement and the bubble frame read.
		# `model` is the model centre and `tweens` the in-flight move / pose
		# tweens (see _model_hit).
		_dogs.append({"node": w, "index": _dogs.size(), "stages": stages,
			"check": null, "origin": center, "state": 0, "soaked": false,
			"fry_timing": true, "fry_acc": 0.0,
			"bub_timing": true, "bub_acc": 0.0, "vibrate": null, "fades": [],
			"model": center, "tweens": [],
			"model_rot": REST_ROTATION, "model_scale": REST_SCALE})


# -- dragging ---------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and _drag_index < 0:
			# Topmost first (dogs 1..4 inserted in order); a dog wearing its
			# check has userInteractionEnabled NO.
			for i in range(_dogs.size() - 1, -1, -1):
				if _dogs[i]["check"] != null and (_dogs[i]["check"] as Sprite2D).visible:
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
		(d["node"] as Node2D).position = \
			(event as InputEventMouseMotion).position + _grab
		_moved(d)
		get_viewport().set_input_as_handled()


## The DropDog / SnapDog / RotateDog animations (touchEnded 0xD58C8) and the
## pickup RotateDog (touchBegan 0xD5548) are all +beginAnimations:/
## commitAnimations, so -- unlike a block-API animation -- they leave the dog
## touchable (UIViewAnimationState answers _allowsUserInteraction YES,
## 0x3307B220), and UIKit hit-tests the MODEL geometry: a dog flying home
## answers at its origin, a dog sinking into the oil at y 290, not where it
## is drawn. The port used to hit-test the drawn dog and let the drop / home
## tween run on under the finger: a dog caught while sinking and lifted out
## was pulled back to y 290 and, released without a further move, counted
## as dropped in the oil.
func _model_hit(d: Dictionary, p: Vector2) -> bool:
	var w := d["node"] as Node2D
	var xf := Transform2D(float(d["model_rot"]),
		Vector2.ONE * float(d["model_scale"]), 0.0, d["model"] as Vector2)
	var parent := w.get_parent() as CanvasItem
	if parent != null:
		xf = parent.get_global_transform() * xf
	return Rect2(-DOG_HALF, DOG_HALF * 2.0).has_point(xf.affine_inverse() * p)


## INFERRED (as on the coating and roll screens): the touch supersedes the
## in-flight animations at their model values -- the drag then owns the dog.
## PORT CHOICE: UIKit would let the drawn dog glide on to the finger for the
## rest of the animation; the port lands it on the model at once.
func _snap_to_model(d: Dictionary) -> void:
	_kill_tweens(d)
	var w := d["node"] as Node2D
	w.position = d["model"]
	w.rotation = d["model_rot"]
	w.scale = Vector2.ONE * float(d["model_scale"])


func _kill_tweens(d: Dictionary) -> void:
	for t: Tween in d["tweens"]:
		if t != null and t.is_valid():
			t.kill()
	(d["tweens"] as Array).clear()


func _begin_drag(d: Dictionary) -> void:
	_stop_vibrate(d)
	_snap_to_model(d)
	d["model_rot"] = 0.0
	d["model_scale"] = DRAG_SCALE
	var w := d["node"] as Node2D
	var tw := create_tween().set_parallel(true)
	tw.tween_property(w, "scale", Vector2(DRAG_SCALE, DRAG_SCALE),
		PICKUP_SECONDS).set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(w, "rotation", 0.0, PICKUP_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)
	(d["tweens"] as Array).append(tw)


func _has_space(d: Dictionary) -> bool:
	for other: Dictionary in _dogs:
		if other == d or not other["soaked"]:
			continue
		if absf((other["node"] as Node2D).position.x
				- (d["node"] as Node2D).position.x) < SPACING:
			return false
	return true


## touchMoved (0xD5680).
func _moved(d: Dictionary) -> void:
	var w := d["node"] as Node2D
	if w.position.y >= CENTER_Y_CLAMP:
		w.position.y = CENTER_Y_CLAMP
	d["model"] = w.position
	var c := w.position
	var in_band := c.x >= BAND_X_MIN and c.x <= BAND_X_MAX
	if _has_space(d) and in_band:
		_remove_cross()
	elif c.y > DROP_MIN_Y:
		_show_cross(c)
	else:
		_remove_cross()
	if c.y >= SOAK_MIN_Y and in_band:
		_set_soaked(d, true)
	else:
		_set_soaked(d, false)
	_check_frying_sound()


## touchEnded (0xD58C8).
func _end_drag(d: Dictionary) -> void:
	var w := d["node"] as Node2D
	if w.position.y >= CENTER_Y_CLAMP:
		w.position.y = CENTER_Y_CLAMP
	var c := w.position
	if c.y > DROP_MIN_Y and c.x >= BAND_X_MIN and c.x <= BAND_X_MAX \
			and _has_space(d):
		d["model"] = Vector2(c.x, CENTER_Y_CLAMP)
		var drop := create_tween()
		drop.tween_property(w, "position:y", CENTER_Y_CLAMP,
			DROP_SECONDS).set_trans(Tween.TRANS_LINEAR)
		(d["tweens"] as Array).append(drop)
		_set_soaked(d, true)
		Audio.play("cd_splash")   # 0x6BD654
		var next := outlet("nextButton")
		if next != null and next != self:
			(next as CanvasItem).visible = false
		_check_frying_sound()
		return
	_check_all_ready()
	_stop_vibrate(d)
	d["model_rot"] = REST_ROTATION
	d["model_scale"] = REST_SCALE
	var tw := create_tween().set_parallel(true)
	tw.tween_property(w, "scale", Vector2(REST_SCALE, REST_SCALE),
		SNAP_SECONDS).set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(w, "rotation", REST_ROTATION, SNAP_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)
	d["model"] = d["origin"]
	var home := create_tween()
	home.tween_property(w, "position", d["origin"] as Vector2,
		SNAP_SECONDS).set_trans(Tween.TRANS_LINEAR)
	(d["tweens"] as Array).append_array([tw, home])
	if int(d["state"]) == STAGES:
		_show_check(d)
	_set_soaked(d, false)
	_remove_cross()
	_check_frying_sound()


## showGreenCheckMarkOnDog: (0xCF0F0) / addGreenCheckMarkOnDog: (0xCEF78),
## placed from the model pose's bounding box. Node-local = bounds - half.
func _show_check(d: Dictionary) -> void:
	if d["check"] == null:
		var f := _frame_size(d)
		var check := Sprite2D.new()
		check.texture = _tex("ff_green_check.png")
		check.scale = Vector2(CHECK_SCALE, CHECK_SCALE)
		check.position = Vector2(f.x * 0.5 - 17.0, f.y * 0.5 - 40.0) - DOG_HALF
		(d["node"] as Node2D).add_child(check)
		d["check"] = check
	(d["check"] as Sprite2D).visible = true


## The DraggableIV's frame size: its 50x185 bounds under the model transform.
func _frame_size(d: Dictionary) -> Vector2:
	var r: float = d["model_rot"]
	var sc: float = d["model_scale"]
	var b := DOG_HALF * 2.0
	return Vector2(absf(cos(r)) * b.x + absf(sin(r)) * b.y,
		absf(sin(r)) * b.x + absf(cos(r)) * b.y) * sc


func _show_cross(dog_center: Vector2) -> void:
	_cross.position = dog_center + CROSS_OFFSET


func _remove_cross() -> void:
	_cross.position = Vector2(-100, -100)


## Timer plumbing as on coating (free-running from init, invalidated on
## unsoak, phase kept if already valid) -- for both the 3s fry timer and the
## 0.05s bubbling timer.
func _set_soaked(d: Dictionary, value: bool) -> void:
	if value:
		d["soaked"] = true
		if not d["fry_timing"]:
			d["fry_timing"] = true
			d["fry_acc"] = 0.0
		if not d["bub_timing"]:
			d["bub_timing"] = true
			d["bub_acc"] = 0.0
	else:
		d["soaked"] = false
		d["fry_timing"] = false
		d["bub_timing"] = false


func _process(delta: float) -> void:
	for d: Dictionary in _dogs:
		if d["fry_timing"]:
			d["fry_acc"] = float(d["fry_acc"]) + delta
			while float(d["fry_acc"]) >= TICK_SECONDS:
				d["fry_acc"] = float(d["fry_acc"]) - TICK_SECONDS
				_fry_tick(d)
		if d["bub_timing"]:
			d["bub_acc"] = float(d["bub_acc"]) + delta
			while float(d["bub_acc"]) >= BUBBLE_TICK:
				d["bub_acc"] = float(d["bub_acc"]) - BUBBLE_TICK
				if d["soaked"]:
					_spawn_bubble(d)


## nextImageForCorndogN (0xD02A8..): advance while soaked; at stage 4 the fry
## timer is invalidated and the dog vibrates until lifted out.
## QUIRK, as read: dogs 3 and 4 (0xD0628 / 0xD0800) make their LAST step
## (3 -> 4) instantly -- setAlpha: outside any animation block -- while dogs
## 1 and 2 (0xD02A8 / 0xD0468) crossfade every step.
func _fry_tick(d: Dictionary) -> void:
	var state: int = d["state"]
	if state < STAGES:
		if not d["soaked"]:
			return
		var stages: Array = d["stages"]
		var fading := stages[state] as Sprite2D
		d["state"] = state + 1
		var rising := stages[state + 1] as Sprite2D
		if int(d["index"]) >= 2 and state + 1 == STAGES:
			fading.modulate.a = 0.0
			rising.modulate.a = 1.0
		else:
			var out := create_tween()
			out.tween_property(fading, "modulate:a", 0.0, FADE_OUT) \
				.set_trans(Tween.TRANS_LINEAR)
			var into := create_tween()
			into.tween_property(rising, "modulate:a", 1.0, FADE_IN) \
				.set_trans(Tween.TRANS_LINEAR)
			(d["fades"] as Array).append_array([out, into])
		state = d["state"]
	if state == STAGES:
		d["fry_timing"] = false   # [dogNBatterTimer invalidate]
		_start_vibrate(d)


func _start_vibrate(d: Dictionary) -> void:
	if d["vibrate"] != null and (d["vibrate"] as Tween).is_valid():
		return
	var w := d["node"] as Node2D
	# CGAffineTransformRotate(current, 0.087266): relative to the model
	# transform, which is left 5 deg over (the animation autoreverses forever).
	var base: float = d["model_rot"]
	w.rotation = base
	d["model_rot"] = base + VIBRATE_ROT
	var tw := create_tween().set_loops()
	tw.tween_property(w, "rotation", base + VIBRATE_ROT, VIBRATE_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(w, "rotation", base, VIBRATE_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)
	d["vibrate"] = tw


func _stop_vibrate(d: Dictionary) -> void:
	if d["vibrate"] != null and (d["vibrate"] as Tween).is_valid():
		(d["vibrate"] as Tween).kill()
	d["vibrate"] = null


## startBubblingForCorndogN (0xD09D8..): one random oil blob per 0.05s tick,
## setFrame:(0, 0, w/5.4, w/5.4) -- BOTH sides from the art's WIDTH, so the
## 65x52 / 49x39 / 33x26 blobs are stretched square -- placed inside the dog's
## transformed frame (x = int(frame.x + rand % (int(frame.w) - 15)),
## y = int(frame.y + 55 + rand % (int(frame.h) - 55))), floating to centre.y
## 242 while fading 0.75 -> 0.2 over 0.5s ease-in, removed after 1s.
func _spawn_bubble(d: Dictionary) -> void:
	var t := _tex(BUBBLE_ART[randi() % BUBBLE_ART.size()])
	if t == null:
		return
	var w := d["node"] as Node2D
	# The model frame: held / parked at scale 0.9, rotation 0, or 5 deg over
	# once vibrating -- centred on the dog's centre.
	var size := _frame_size(d)
	var top_left := w.position - size * 0.5
	var bw := maxi(int(size.x) - 15, 1)
	var bh := maxi(int(size.y) - 55, 1)
	var side := float(t.get_width()) / BUBBLE_DIV
	var b := Sprite2D.new()
	b.texture = t
	b.centered = false
	b.scale = Vector2(side / float(t.get_width()), side / float(t.get_height()))
	b.position = Vector2(float(int(top_left.x + float(randi() % bw))),
		float(int(top_left.y + 55.0 + float(randi() % bh))))
	b.modulate.a = BUBBLE_ALPHA
	_container.add_child(b)
	_container.move_child(b, w.get_index() + 1)   # above the dog, below oil

	var half := Vector2(side, side) * 0.5
	var tw := create_tween().set_parallel(true)
	tw.tween_property(b, "position:y", BUBBLE_END_Y - half.y, BUBBLE_FLOAT) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(b, "modulate:a", BUBBLE_END_ALPHA, BUBBLE_FLOAT) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	get_tree().create_timer(BUBBLE_LIFE).timeout.connect(func() -> void:
		if is_instance_valid(b):
			b.queue_free())


## checkFryingSoundPlayer (0xCFE08): hi loop while any dog soaks, lo loop
## otherwise.
func _check_frying_sound() -> void:
	var any_soaked := false
	for d: Dictionary in _dogs:
		if d["soaked"]:
			any_soaked = true
			break
	if any_soaked:
		Audio.stop("frying_lo_loop")
		Audio.loop("frying_hi_loop")
	else:
		Audio.stop("frying_hi_loop")
		Audio.loop("frying_lo_loop")


## showNextButtonWhenAllFourAreReady (0xCF684): show when all four are done
## and none is still in the oil; the original's odd counter-branch -- hide the
## visible button when NOT ONE dog is at stage 4 -- is kept as read.
func _check_all_ready() -> void:
	var next := outlet("nextButton")
	var all_done := true
	var none_done := true
	var any_soaked := false
	for d: Dictionary in _dogs:
		if int(d["state"]) == STAGES:
			none_done = false
		else:
			all_done = false
		if d["soaked"]:
			any_soaked = true
	if all_done and not any_soaked \
			and next != null and next != self \
			and not (next as CanvasItem).visible:
		show_next_button()
	elif none_done and next != null and next != self \
			and (next as CanvasItem).visible:
		(next as CanvasItem).visible = false


## nextClick: (0xD4AB4): stop both frying loops, button_press, then build the
## infoDict MakeViewController consumes -- the original's own key names and
## values, ItemCenter being the art's TOP-LEFT (zero-frame DecorateItemView).
func _on_nextClick() -> void:
	Audio.stop("frying_lo_loop")
	Audio.stop("frying_hi_loop")
	Audio.play("button_press")

	var stick: Variant = _info.get("stickImg")
	var skewer_x := SKEWER_X
	if stick is Texture2D and (stick as Texture2D).get_size().x == 31.0:
		skewer_x = SKEWER_X_NARROW

	var info := {
		"CornDog": {
			"Properties": {"IsEdible": true, "ViewIndex": 2,
				"Type": "Stationary",
				"ItemCenterX": DOG_HANDOFF.x, "ItemCenterY": DOG_HANDOFF.y},
			"Image": _tex(FINAL_ART.get(_batter, FINAL_ART[0])),
		},
		"CornDogSkewer": {
			"Properties": {"IsEdible": false, "ViewIndex": 1,
				"Type": "Stationary",
				"ItemCenterX": skewer_x, "ItemCenterY": SKEWER_Y},
			"Image": stick if stick is Texture2D else null,
		},
	}
	GameState.custom_categories = info
	Nav.next()


func _on_skipClick() -> void:   # skipClick: (0xD4F68) calls nextClick:.
	_on_nextClick()


## backClick: (0xD492C): stop both frying loops, button_press, invalidate the
## eight timers, pop.
func _on_backClick() -> void:
	Audio.stop("frying_lo_loop")
	Audio.stop("frying_hi_loop")
	Audio.play("button_press")
	Nav.back()


## viewWillDisappear: (0xD4818) -> stopBurner (0xD48F8): [fire stop], and
## nothing else -- the dogs, their timers and the burner state stay for the
## return. The frying loops are stopped by nextClick:/backClick:, the only
## ways off this screen; stopping them here as well is a PORT CHOICE safety
## net (it changes nothing on those paths).
func on_exit() -> void:
	if _fire != null:
		_fire.stop()
	Audio.stop("frying_lo_loop")
	Audio.stop("frying_hi_loop")
