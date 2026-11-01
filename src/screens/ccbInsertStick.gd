# Chocolate Covered Banana step 3 -- pull the banana DOWN onto the stick.
#
# From the original binary (entry points from the ObjC method list):
#   initWithNibName: 0x1372C4 (bare super), viewDidLoad 0x1372F4,
#   viewWillAppear: 0x137454, draggableTouchBegan/Moved/Ended
#   0x13770C/0x137754/0x13791C, showNextButton 0x1379DC,
#   changeInstruction: 0x137B40, nextClick: 0x137DB8.
#
# The REVERSE of caInsertStick: there the stick was dragged into the apple;
# here the STICK is the stationary nib UIImageView (140,187,40,273) -- its
# image set to infoDict["Stick"], the 39x271 art scale-to-filled into
# 40x273 -- and the BANANA is the DraggableIV.
#
# Mechanic, as read (viewWillAppear rebuilds the banana each appearance):
#  * banana: DraggableIV(banana_for_stick.png) initial centre (171.5, 27.5)
#    (0x432B8000/0x41DC0000), then setFrame (97,-130,149,315)
#    (0x42C20000/0xC3020000/0x43150000/0x439D8000) -- same centre, art at
#    natural size, mostly off-screen above. lockXMovement YES; inserted
#    ABOVE the stick; maxY = int(stick.centre.y - 40) = 283.
#  * draggableTouchBegan (0x13770C) plays "pickup".
#  * draggableTouchMoved (0x137754): once locked, ignore. If the frame top
#    reaches y >= 120, pin it to 120 (0x42F00000) -- with a 315-tall frame
#    that is centre 277.5, looser than the lock below, so it only matters on
#    a jump; kept for fidelity. Then if centre.y > 185 the banana locks:
#    snapTime 0, interaction off, centre (171.5, 180)
#    (0x432B8000/0x43340000). Otherwise every move re-arms snapTime 0.2
#    (0x3E4CCCCD), so releasing short snaps home linearly over 0.2s
#    (DraggableIV touchesEnded 0x46860, origCenter (171.5, 27.5)).
#  * draggableTouchEnded (0x13791C): if locked, re-pin (171.5, 180) and
#    slide the next button in.
#
# nextClick: (0x137DB8): button_press, push ccbSelectChocolate with the same
# infoDict. backClick: (0x137D48): button_press, pop.
#
# Two corrections from a full re-read of the original:
#  * The nib's own banana (UIImageView id 3, banana_for_stick.png at
#    (97,-130,149,315)) is NOT an outlet and no method touches it. It ships
#    UIHidden=YES, so it is never seen; the only banana on screen is the
#    DraggableIV, inserted directly above the STICK
#    (insertSubview:aboveSubview:stick). (The port briefly made the nib copy
#    visible, believing the nib showed it; that was the swapped NIBArchive
#    bool tags, since fixed. The generated scene now hides it and this
#    script leaves it alone.)
#  * Locking (setUserInteractionEnabled:NO mid-touch) does not end the
#    touch: the phone's syslog shows draggableTouchEnded:'s NSLog of the
#    re-pinned frame origin (97, 22.5) after the lock,
#    so the rest of the touch still reaches DraggableIV. Its touchesMoved:
#    (0x46614) keeps moving the banana with the finger (x locked, centre y
#    clamped to maxY 283) while the delegate returns early (isDraggable);
#    touchesEnded: (snapTime 0) then the delegate re-pin it at (171.5, 180).
#    The port used to freeze it at (171.5, 180) for the rest of the drag.

extends "res://core/Screen.gd"

## viewWillAppear: (0x137454) constants -- see header for addresses.
const BANANA_HOME := Vector2(171.5, 27.5)     # frame (97,-130,149,315)
const BANANA_SIZE := Vector2(149, 315)
## Stick nib frame (140,187,40,273); centre (160,323.5).
const STICK_FRAME := Rect2(140, 187, 40, 273)
const BANANA_MAX_Y := 283.0                   # int(323.5 - 40)
const FRAME_TOP_PIN := 120.0                  # 0x42F00000
const LOCK_Y := 185.0                         # centre threshold (0x137796)
const LOCK_CENTER := Vector2(171.5, 180.0)    # 0x432B8000 / 0x43340000
const SNAP_SHORT := 0.2                       # 0x3E4CCCCD

var _banana: Sprite2D
var _inserted := false                        # the original's isDraggable
var _dragging := false
var _grab := Vector2.ZERO
## The SnapToOrig glide home (see _unhandled_input).
var _snap: Tween
## The shared infoDict (see ccbSelectStickViewController._info).
var _info: Dictionary = {}


func on_enter() -> void:
	_info = GameState.custom_categories
	# viewDidLoad (0x1372F4): the nib stick UIImageView takes
	# infoDict["Stick"], scale-to-filled into its 40x273 frame.
	var stick := outlet("stick") as Sprite2D
	var stick_tex := _tex(str(_info.get("Stick", "")))
	if stick != null and stick_tex != null:
		stick.texture = stick_tex
		stick.centered = false
		stick.scale = STICK_FRAME.size / Vector2(stick_tex.get_size())
	_view_will_appear()


## viewWillAppear: (0x137454) -- the first appearance and every return:
## isDraggable 0, the old banana removed, a fresh DraggableIV built at its
## home, "inst_insert_stick_in_banana" slid in, next hidden.
func _view_will_appear() -> void:
	_inserted = false
	if _banana != null and is_instance_valid(_banana):
		_banana.queue_free()                  # removeFromSuperview + release
	# The nib's own banana_for_stick image (not an outlet, UIHidden=YES) is
	# left alone, i.e. stays hidden -- see the header.
	_banana = Sprite2D.new()
	_banana.texture = _tex("banana_for_stick.png")
	_banana.position = BANANA_HOME
	add_child(_banana)
	# insertSubview:aboveSubview:stick -- directly above the stick, so under
	# the (hidden) nib banana, instIV and the buttons.
	var stick := outlet("stick") as Sprite2D
	if stick != null:
		move_child(_banana, stick.get_index() + 1)

	change_instruction("inst_insert_stick_in_banana.png")
	# The ccb changeInstruction: (0x137B40) ends with nextButton.hidden = YES.
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false


## UINavigationController keeps this controller alive under
## ccbSelectChocolate (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from ccbSelectChocolate: viewWillAppear: rebuilds the banana, so it
## has to be pushed onto the stick again before next returns. No
## viewDidAppear:, no viewWillDisappear:.
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		# CoinHUD re-adds the panel after this; drop the first appearance's.
		remove_child(old)
		old.queue_free()
	_dragging = false
	_view_will_appear()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _banana_rect() -> Rect2:
	return Rect2(_banana.position - BANANA_SIZE * 0.5, BANANA_SIZE)


func _unhandled_input(event: InputEvent) -> void:
	if _banana == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		# The 0.2 s SnapToOrig glide (DraggableIV touchesEnded: 0x46860) is
		# +beginAnimations:/commitAnimations: the banana stays touchable on
		# its way up, hit-tested at its MODEL centre (origCenter), and the
		# drag takes it over from there. The port used to hit-test the drawn
		# banana and leave the snap running: caught, pushed onto the stick and
		# let go within the 0.2 s, it was locked and next came, while the
		# snap carried the banana back up off the stick.
		# PORT CHOICE: it lands on the model at once instead of gliding on
		# toward the finger for the rest of the 0.2 s.
		var snapping := _snap != null and _snap.is_valid() and _snap.is_running()
		var hit_rect := Rect2(BANANA_HOME - BANANA_SIZE * 0.5, BANANA_SIZE) \
			if snapping else _banana_rect()
		if mb.pressed and not _dragging and not _inserted \
				and hit_rect.has_point(mb.position):
			if snapping:
				_snap.kill()
				_banana.position = BANANA_HOME
			_dragging = true
			_grab = _banana.position - mb.position
			Audio.play("pickup")          # draggableTouchBegan: 0x13770C
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			if _inserted:
				# draggableTouchEnded: (0x13791C): re-pin the locked banana
				# and slide the next button in.
				_banana.position = LOCK_CENTER
				show_next_button()
			else:
				# DraggableIV touchesEnded (0x46860) snaps home over the
				# snapTime the last move set (0.2s, curve 3 = linear).
				_snap = create_tween()
				_snap.tween_property(_banana, "position", BANANA_HOME,
					SNAP_SHORT).set_trans(Tween.TRANS_LINEAR)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		# DraggableIV touchesMoved: (0x46614) runs on every move of the touch,
		# locked or not: lockXMovement YES, centre y clamped to maxY 283.
		var p: Vector2 = (event as InputEventMouseMotion).position + _grab
		p.x = BANANA_HOME.x
		p.y = minf(p.y, BANANA_MAX_Y)
		_banana.position = p
		# The delegate (0x137754) returns early once isDraggable is set.
		if not _inserted:
			_moved()
		get_viewport().set_input_as_handled()


## draggableTouchMoved: (0x137754).
func _moved() -> void:
	# Frame-top pin at 120 (effectively dead -- see header; kept in order).
	var top := _banana.position.y - BANANA_SIZE.y * 0.5
	if top >= FRAME_TOP_PIN:
		_banana.position.y = FRAME_TOP_PIN + BANANA_SIZE.y * 0.5
	# The lock: centre past y 185 -> snapTime 0, interaction off, pinned.
	if _banana.position.y > LOCK_Y:
		_inserted = true
		_banana.position = LOCK_CENTER


## nextClick: (0x137DB8): button_press, push a NEW ccbSelectChocolate with
## the same infoDict.
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.custom_categories = _info
	Nav.next()


## backClick: (0x137D48): button_press, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
