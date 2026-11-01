# Corn Dog step 4 -- roll four dogs back and forth in the flour pan.
#
# GROUNDED from initializeDogs (0x16CC0), viewWillAppear: (0x18FCC),
# draggableTouchBegan/Moved/Ended (0x18040 / 0x183E0 / 0x18898),
# didDogCrossTheCenterPoint:currentDogCenter:dogLastYPos: (0x17E04),
# changeDogCoatImage:dogCoatCount: (0x17D28), playCoatingSound: (0x17F8C),
# rotateAnimation: (0x17BE8), addGreenCheckMarkOnDog: (0x16B10), backClick:
# (0x18DE4) and nextClick: (0x18CC0).
#
# Mechanic, as read: each dog is a DraggableIV whose frame is the plain-dog
# art widened by 30pt (15pt of grab margin each side). A "roll" is the dog's
# centre CROSSING THE PAN'S CENTRE LINE (pan.center.y) between two move
# events, while horizontally inside the pan inset by 20pt. Each crossing adds
# one coat (cd_dog_coated_1..4); four coats finish a dog, sixteen crossings
# total slide the next button in. A dog released inside the pan simply stays
# there; released outside (or finished) it flies home.

extends "res://core/Screen.gd"

## initializeDogs (0x16CC0): dogNOrigin = (90/145/200/255, 55).
const DOG_ORIGINS := [Vector2(90, 55), Vector2(145, 55),
	Vector2(200, 55), Vector2(255, 55)]
## initialScale 0.8 (0x3F4CCCCD), initialAngle 30 deg (0x41F00000); the rest
## transform is scale(0.8) then rotate(initialAngle * pi / 180) -- pi/180
## doubles at 0x17748/0x17750.
const REST_SCALE := 0.8
const REST_ROTATION := 0.5235988   # 30 deg
## Dragging pose, touchBegan (0x18040): 0.2s (double 0x183C0) linear to
## scale 1/0.8 and a further (90 - 30) deg (0x183C8/0x183D0/0x183D8) -- the
## dog stands at 90 deg, full size, while held.
const PICKUP_SECONDS := 0.2
const DRAG_ROTATION := 1.5707963   # 90 deg
## DraggableIV frame: art size + 30pt of width (0x41F00000 in 0x16CC0), the
## art inset 15pt (0x41700000). cd_dog_plain.png is 25x125, so the hit frame
## is 55x125 centred on the origin.
const HIT_HALF := Vector2(27.5, 62.5)
## Pan nib frame (nib id 2); the
## crossing band is inset 20pt each side (0x17E04).
const PAN_RECT := Rect2(47, 106, 226, 316)
const PAN_X_INSET := 20.0
## Four coats per dog, sixteen total (0x10 at 0x186B6).
const COATS_PER_DOG := 4
const TOTAL_COATS := 16
## Release: home over 0.3s (0x18CA0), rescale over 0.1s (0x18CA8), both curve
## 3 = linear; then after 0.1s (0x3FB9999999999A) rotateAnimation: -60 deg
## over 0.3s (0x17D08). rotateAnimation: sets no curve, so it runs UIKit's
## default UIViewAnimationCurveEaseInOut.
const HOME_SECONDS := 0.3
const RESCALE_SECONDS := 0.1
const REROTATE_DELAY := 0.1
const REROTATE_SECONDS := 0.3
## Green check (0x16B10): ff_green_check.png in a 30x30 frame (aspect-fit of
## the 100x100 art = scale 0.3), tag 999, added to the DraggableIV with centre
## (dog.frame.size.height - 10, 0) in the dog's own coordinates (disassembly at
## 0x16BE6: frame+0xC = height, -10.0, r3 = 0). `frame` is the TRANSFORMED
## bounding box at the moment showGreenCheckMarkOnDog: runs in touchEnded --
## normally the held pose (90 deg, scale 1), whose frame is 125 wide and 55
## tall, giving local (45, 0): just right of the stick end. The check is a
## subview, so it then turns and shrinks with the dog. It used to be placed
## at a fixed (115, 0) local (unrotated height), 70pt off to the side.
const CHECK_SCALE := 0.3
## DraggableIV bounds: plain art 25x125 widened by 30 -> 55x125.
const DOG_BOUNDS := Vector2(55, 125)

var _batter := 0
var _dogs: Array = []   # {node, art, check, origin, coat, last_y, done}
var _drag_index := -1
var _grab := Vector2.ZERO
var _total := 0
var _next_shown := false


func on_enter() -> void:
	_batter = int(GameState.custom_categories.get("batter", 0))
	_view_will_appear()


## UINavigationController keeps this controller alive under StickSelect
## (Nav.gd's opt-in). On back viewWillAppear: runs again and RESETS the step:
## counts zeroed, next hidden, four brand-new dogs (initializeDogs allocs
## them) -- the old ones were taken out by viewDidDisappear:. So a return
## from StickSelect means rolling all four dogs again, as on the device.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	# instIV setHidden:NO -- no slide; it is simply back where it was parked.
	var iv := _instruction_node()
	if iv != null:
		if _instruction_home_set:
			iv.position = _instruction_home
		iv.visible = true
		iv.modulate.a = 1.0
	_view_will_appear()


## viewWillAppear: (0x18FCC): dogN coat counts, totalCoatCount and
## dogNLastYPos zeroed, hasShownNextButton = 0, nextButton disabled at alpha
## 0, initializeDogs (0x16CC0), hideGreenCheckMarkOnDog: x4 (new dogs carry
## no check, so nothing to hide).
func _view_will_appear() -> void:
	_total = 0
	_next_shown = false
	_drag_index = -1
	var next := outlet("nextButton")
	if next != null and next != self:
		(next as CanvasItem).visible = false   # setEnabled:0 setAlpha:0
	_build_dogs()


## viewDidDisappear: (0x191F0): removeFromSuperview on all four dogs.
## (viewWillDisappear: is super only.)
func on_exit() -> void:
	for d: Dictionary in _dogs:
		_kill_tweens(d)
		if is_instance_valid(d["node"]):
			(d["node"] as Node).queue_free()
	_dogs.clear()
	_drag_index = -1


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## initializeDogs: four DraggableIVs over transparent.png with the plain art
## as a subview; wrapper-Node2D + centred sprite reproduces the centre-pivot
## scale and rotation.
func _build_dogs() -> void:
	for d: Dictionary in _dogs:
		if is_instance_valid(d["node"]):
			(d["node"] as Node).queue_free()
	_dogs.clear()
	for origin: Vector2 in DOG_ORIGINS:
		var w := Node2D.new()
		w.position = origin
		w.scale = Vector2(REST_SCALE, REST_SCALE)
		w.rotation = REST_ROTATION
		add_child(w)

		var art := Sprite2D.new()
		art.texture = _tex("cd_dog_plain.png")
		w.add_child(art)

		# `check` is created on first show (addGreenCheckMarkOnDog:), when its
		# position can be read off the dog's frame at that moment.
		# `model` mirrors the UIView model centre: tweens move `node`, but
		# UIKit reports the animation's END value as soon as it is committed.
		_dogs.append({"node": w, "art": art, "check": null,
			"origin": origin, "coat": 0, "last_y": 0.0, "done": false,
			"model": origin, "model_rot": REST_ROTATION, "model_scale": REST_SCALE,
			"tweens": []})


func _pan_center_y() -> float:
	return PAN_RECT.position.y + PAN_RECT.size.y * 0.5


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and _drag_index < 0:
			# Topmost first: dogs 1..4 were added in order, so UIKit's hit
			# test reaches dog 4 first where their frames overlap.
			for i in range(_dogs.size() - 1, -1, -1):
				var d: Dictionary = _dogs[i]
				if d["done"]:
					continue   # setUserInteractionEnabled:0 after four coats
				var w := d["node"] as Node2D
				if _model_hit(d, mb.position):
					_drag_index = i
					_begin_drag(d)
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
		(d["node"] as Node2D).position = p
		d["model"] = p
		_moved(d)
		get_viewport().set_input_as_handled()


## The home / rescale / re-tilt animations (touchEnded 0x18898,
## rotateAnimation: 0x17BE8) and the stand-up (0x18040) are all
## +beginAnimations:/commitAnimations, so the dog stays touchable while they
## run (UIViewAnimationState answers _allowsUserInteraction YES, 0x3307B220)
## and UIKit hit-tests its MODEL geometry: a dog flying home answers at its
## origin, in the rest pose it is heading for, not where it is drawn. The
## port used to hit-test the drawn dog and take the drag offset from there,
## then snap the dog to its model, so it jumped off the finger and back.
func _model_hit(d: Dictionary, p: Vector2) -> bool:
	var w := d["node"] as Node2D
	var xf := Transform2D(float(d["model_rot"]),
		Vector2.ONE * float(d["model_scale"]), 0.0, d["model"] as Vector2)
	var parent := w.get_parent() as CanvasItem
	if parent != null:
		xf = parent.get_global_transform() * xf
	return Rect2(-HIT_HALF, HIT_HALF * 2.0).has_point(xf.affine_inverse() * p)


## touchBegan (0x18040): the pickup sound and stand-up animation run only for
## a dog whose centre equals its origin; a dog left in the pan drags silently.
## The test reads the MODEL centre, so a dog grabbed while still flying home
## counts as home, as on the device.
func _begin_drag(d: Dictionary) -> void:
	var w := d["node"] as Node2D
	# INFERRED: an in-flight UIView animation is superseded at its model
	# value (beginAnimations without BeginFromCurrentState), so the node is
	# snapped to the model before anything new starts.
	_kill_tweens(d)
	w.position = d["model"]
	w.rotation = d["model_rot"]
	w.scale = Vector2.ONE * float(d["model_scale"])
	if not (d["model"] as Vector2).is_equal_approx(d["origin"] as Vector2):
		return
	Audio.play("pickup")
	# Relative, as CGAffineTransformScale/Rotate on the current transform:
	# x(1/0.8) and +(90 - 30) deg -- the rest pose stands up to 90 deg, 1.0.
	var to_scale: float = float(d["model_scale"]) / REST_SCALE
	var to_rot: float = float(d["model_rot"]) + (DRAG_ROTATION - REST_ROTATION)
	d["model_scale"] = to_scale
	d["model_rot"] = to_rot
	var tw := create_tween().set_parallel(true)
	tw.tween_property(w, "scale", Vector2(to_scale, to_scale), PICKUP_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(w, "rotation", to_rot, PICKUP_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)
	(d["tweens"] as Array).append(tw)


func _kill_tweens(d: Dictionary) -> void:
	for t: Tween in d["tweens"]:
		if t != null and t.is_valid():
			t.kill()
	(d["tweens"] as Array).clear()


## touchMoved (0x183E0) + didDogCrossTheCenterPoint (0x17E04).
func _moved(d: Dictionary) -> void:
	var w := d["node"] as Node2D
	if int(d["coat"]) <= COATS_PER_DOG - 1:
		var cur := w.position
		var pan_y := _pan_center_y()
		var last: float = d["last_y"]
		# Strict on both sides (disassembly 0x17E60..0x17EA2, including the
		# first branch's curY test): above-to-below,
		# below-to-above, or the previous event sat exactly on the line.
		var crossed := (last < pan_y and cur.y > pan_y) \
			or (cur.y < pan_y and pan_y < last) or last == pan_y
		var in_band := PAN_RECT.position.x + PAN_X_INSET < cur.x \
			and cur.x < PAN_RECT.end.x - PAN_X_INSET
		if crossed and in_band:
			_total += 1
			var coat: int = int(d["coat"]) + 1
			d["coat"] = coat
			if coat < 5:   # changeDogCoatImage: guard (0x17D28)
				(d["art"] as Sprite2D).texture = \
					_tex("cd_dog_coated_%d.png" % coat)
			# playCoatingSound: (0x17F8C): counts 1..3 uncoated, 4 coated.
			Audio.play("cd_flour_uncoated" if coat < 4 else "cd_flour_coated")
		d["last_y"] = cur.y

	if _total == TOTAL_COATS and not _next_shown:
		_next_shown = true
		# Inline slide-in at 0x186B6: +500/0.25 with instIV hidden -- exactly
		# Screen.show_next_button.
		show_next_button()


## touchEnded (0x18898): a dog dropped inside the pan with coats to go stays
## put; otherwise it flies home, rescales, and re-tilts after a beat.
func _end_drag(d: Dictionary) -> void:
	var w := d["node"] as Node2D
	var finished: bool = int(d["coat"]) > COATS_PER_DOG - 1
	if not finished and PAN_RECT.has_point(d["model"] as Vector2):
		return
	d["last_y"] = 0.0
	if finished:
		d["done"] = true   # setUserInteractionEnabled:NO
		w.modulate.a = 1.0
		_show_check(d)
	d["model"] = d["origin"]
	var home := create_tween()
	home.tween_property(w, "position", d["origin"] as Vector2,
		HOME_SECONDS).set_trans(Tween.TRANS_LINEAR)
	# CGAffineTransformScale(current, 0.8): relative to the held pose.
	var to_scale: float = float(d["model_scale"]) * REST_SCALE
	d["model_scale"] = to_scale
	var rescale := create_tween()
	rescale.tween_property(w, "scale", Vector2(to_scale, to_scale),
		RESCALE_SECONDS).set_trans(Tween.TRANS_LINEAR)
	(d["tweens"] as Array).append_array([home, rescale])
	# performSelector:rotateAnimation: afterDelay:0.1 -- rotate the current
	# transform by -(90 - 30) deg over 0.3s, default ease-in-out (0x17BE8).
	get_tree().create_timer(REROTATE_DELAY).timeout.connect(func() -> void:
		if not is_instance_valid(w):
			return
		var to_rot: float = float(d["model_rot"]) - (DRAG_ROTATION - REST_ROTATION)
		d["model_rot"] = to_rot
		var rot := create_tween()
		rot.tween_property(w, "rotation", to_rot, REROTATE_SECONDS) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		(d["tweens"] as Array).append(rot))


## showGreenCheckMarkOnDog: (0x16C34) -- unhide the tag-999 check, or add it
## (addGreenCheckMarkOnDog: 0x16B10) at (frame.height - 10, 0) in the dog's
## bounds, `frame` being the dog's transformed bounding box right now (model
## pose). Node-local = bounds-local - bounds/2.
func _show_check(d: Dictionary) -> void:
	if d["check"] != null:
		(d["check"] as Sprite2D).visible = true
		return
	var r: float = d["model_rot"]
	var sc: float = d["model_scale"]
	var frame_h := (absf(sin(r)) * DOG_BOUNDS.x + absf(cos(r)) * DOG_BOUNDS.y) * sc
	var check := Sprite2D.new()
	check.texture = _tex("ff_green_check.png")
	check.scale = Vector2(CHECK_SCALE, CHECK_SCALE)
	check.position = Vector2(frame_h - 10.0, 0.0) - DOG_BOUNDS * 0.5
	(d["node"] as Node2D).add_child(check)
	d["check"] = check


## nextClick: (0x18CC0): button_press, then StickSelectViewController
## initWithClassStr:"CORN_DOG" andInfoDict:{batter: "%d"}. The carrier holds
## the same dict; StickSelect adds stickImg/packID on top of it.
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.custom_categories = {"batter": str(_batter)}
	Nav.next()


## Both skipClick: (0x18CB0) and the invisible debugSkip: button (0x18E54)
## just call nextClick:.
func _on_skipClick() -> void:
	_on_nextClick()


## backClick: (0x18DE4): button_press, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


func _on_debugSkip() -> void:
	_on_nextClick()
