# Candy Apple step 4 -- push the stick down into the apple.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithNibName: 0x154528 (bare super), viewDidLoad 0x154558,
#   viewWillAppear: 0x1546BC, draggableTouchBegan/Moved/Ended
#   0x154BC0/0x154C08/0x154E00, showNextButton 0x154E54,
#   changeInstruction: 0x154FB8 (hides next at its tail), nextClick: 0x155230.
#
# Mechanic, as read (viewWillAppear rebuilds everything on each appearance):
#  * appleBack: UIImageView frame (25,170,269,258), image infoDict[Image_bg],
#    transform scale 0.6 -- scales about the centre, so it stays at
#    (159.5, 299).
#  * appleFront: initWithImage (self-sizing), same centre, same 0.6 scale.
#  * stick: DraggableIV(infoDict[Stick]) centre (160,100), scale 0.5,
#    lockXMovement YES, inserted BELOW appleFront; maxY = appleBack.centre.y
#    - 40 = 259 (integer setter).
#  * draggableTouchMoved (0x154C08): if the stick's frame top >= 185, pin it
#    to 185; then, when the centre passes y > 185 (x 145..175 is trivially
#    satisfied -- x is locked at 160), the stick locks: snapTime 0,
#    interaction off, centre (160,180). Otherwise every move re-arms
#    snapTime 0.2, so releasing short snaps home over 0.2s (linear,
#    DraggableIV touchesEnded 0x46860).
#  * draggableTouchEnded (0x154E00): if locked, re-pin (160,180) and slide
#    the next button in.
#  * After the lock the touch is still live. setUserInteractionEnabled:NO
#    only stops NEW touches from hit-testing to the stick; UIKit keeps
#    delivering the current one to the view it began on -- it must, or
#    draggableTouchEnded: would never run and next would never appear. So
#    DraggableIV touchesMoved: (0x46614) keeps moving the stick with the
#    finger (x locked, centre y <= 259) and the delegate returns early
#    (isDraggable); release snaps it to (160,180). INFERRED from UIKit's
#    delivery rule; the port used to freeze it at (160,180) the moment
#    it locked.
#  * touchBegan plays "pickup".
#
# The 185-frame pin is looser than the 259 centre clamp (frame top 185 =
# centre 266 at 0.5 scale), so the centre clamp governs; both are kept.
#
# Not ported: BuyAllClick:/productPurchased: 0x155340/0x155478 (IAP).

extends "res://core/Screen.gd"

## viewWillAppear (0x1546BC) constants -- see header for addresses.
const APPLE_CENTER := Vector2(159.5, 299.0)   # frame (25,170,269,258)
const APPLE_SCALE := 0.6
const STICK_HOME := Vector2(160, 100)         # 0x43200000 / 0x42C80000
const STICK_SCALE := 0.5
const STICK_MAX_Y := 259.0                    # appleBack.centre.y - 40
const FRAME_TOP_PIN := 185.0                  # 0x14C654: setFrame y = 185
const LOCK_Y := 185.0                         # centre threshold
const LOCK_CENTER := Vector2(160, 180)        # 0x43200000 / 0x43340000
const SNAP_SHORT := 0.2                       # 0x3E4CCCCD

var _stick: Sprite2D
var _stick_size := Vector2.ZERO               # scaled art size
var _inserted := false
var _dragging := false
var _grab := Vector2.ZERO
## The SnapToOrig glide home, while it runs (see _unhandled_input).
var _snap: Tween
## appleBack / appleFront: removed and rebuilt by every viewWillAppear:.
var _apple_back: Sprite2D
var _apple_front: Sprite2D
## The shared infoDict (see caSelectStick._info).
var _info: Dictionary = {}


func on_enter() -> void:
	_info = GameState.custom_categories
	_view_will_appear()


## UINavigationController keeps this controller alive under
## caSelectChocolate (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from caSelectChocolate: viewWillAppear: (0x1546BC) runs again and
## REBUILDS the step -- isDraggable 0, appleBack/appleFront/stick removed and
## made anew (stick back at (160,100), not inserted), "inst_insert_stick"
## slid in and next hidden. The stick has to be pushed in again. No
## viewDidAppear:, no viewWillDisappear:.
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		# CoinHUD re-adds the panel after this; drop the first appearance's.
		remove_child(old)
		old.queue_free()
	_dragging = false
	_view_will_appear()


## viewWillAppear: (0x1546BC).
func _view_will_appear() -> void:
	_inserted = false                         # isDraggable = 0
	if _snapping():
		_snap.kill()                          # its stick is being replaced
	for old: Node in [_apple_back, _apple_front, _stick]:
		if old != null and is_instance_valid(old):
			old.queue_free()                  # removeFromSuperview + release
	_apple_back = null
	_apple_front = null
	_stick = null
	var back_tex := _tex(str(_info.get("Image_bg", "")))
	var front_tex := _tex(str(_info.get("Image_fg", "")))
	var stick_tex := _tex(str(_info.get("Stick", "")))

	if back_tex != null:
		_apple_back = Sprite2D.new()
		_apple_back.texture = back_tex
		_apple_back.position = APPLE_CENTER
		_apple_back.scale = Vector2(APPLE_SCALE, APPLE_SCALE)
		add_child(_apple_back)

	# Stick between back and front, as insertSubview:belowSubview: orders it.
	if stick_tex != null:
		_stick = Sprite2D.new()
		_stick.texture = stick_tex
		_stick.position = STICK_HOME
		_stick.scale = Vector2(STICK_SCALE, STICK_SCALE)
		add_child(_stick)
		_stick_size = stick_tex.get_size() * STICK_SCALE

	if front_tex != null:
		_apple_front = Sprite2D.new()
		_apple_front.texture = front_tex
		_apple_front.position = APPLE_CENTER
		_apple_front.scale = Vector2(APPLE_SCALE, APPLE_SCALE)
		add_child(_apple_front)

	change_instruction("inst_insert_stick.png")
	# The ca changeInstruction: variant ends with nextButton.hidden = YES.
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _stick_rect() -> Rect2:
	return Rect2(_stick.position - _stick_size * 0.5, _stick_size)


func _snapping() -> bool:
	return _snap != null and _snap.is_valid()


## Where a touch finds the stick. SnapToOrig (DraggableIV touchesEnded:
## 0x46860) is +beginAnimations:/commitAnimations, so the stick stays
## touchable on its 0.2 s way home -- hit-tested at origCenter, its model,
## not where it is drawn (UIKit, see core/DraggableSprite2D.gd).
func _stick_hit_rect() -> Rect2:
	if _snapping():
		return Rect2(STICK_HOME - _stick_size * 0.5, _stick_size)
	return _stick_rect()


func _unhandled_input(event: InputEvent) -> void:
	if _stick == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and not _dragging and not _inserted \
				and _stick_hit_rect().has_point(mb.position):
			if _snapping():
				# Grabbed on the way home: the drag takes over from the model.
				# The port used to leave the snap running: a quick grab-push-
				# release inside the 0.2 s locked the stick (next shown) and
				# re-pinned it at (160,180), then the rest of the snap carried
				# it back up to the top.
				# PORT CHOICE: UIKit's presentation would glide on toward
				# the finger for the rest of the snap; the port lands it.
				_snap.kill()
				_stick.position = STICK_HOME
			_dragging = true
			_grab = _stick.position - mb.position
			Audio.play("pickup")          # draggableTouchBegan: 0x154BC0
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			if _inserted:
				# draggableTouchEnded: (0x154E00): re-pin the locked stick
				# and slide the next button in.
				_stick.position = LOCK_CENTER
				show_next_button()
			else:
				# DraggableIV touchesEnded snaps home over the snapTime the
				# last move set (0.2s, linear).
				_snap = create_tween()
				_snap.tween_property(_stick, "position", STICK_HOME,
					SNAP_SHORT).set_trans(Tween.TRANS_LINEAR)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		var p: Vector2 = (event as InputEventMouseMotion).position + _grab
		# lockXMovement YES; DraggableIV clamps the centre to maxY 259.
		p.x = STICK_HOME.x
		p.y = minf(p.y, STICK_MAX_Y)
		_stick.position = p
		# draggableTouchMoved: returns at once when isDraggable (locked).
		if not _inserted:
			_moved()
		get_viewport().set_input_as_handled()


## draggableTouchMoved: (0x154C08).
func _moved() -> void:
	# Frame-top pin at 185.
	var top := _stick.position.y - _stick_size.y * 0.5
	if top >= FRAME_TOP_PIN:
		_stick.position.y = FRAME_TOP_PIN + _stick_size.y * 0.5
	# The lock: centre past y 185 (x is pinned to 160, inside 145..175).
	# snapTime -> 0, interaction off, centre pinned; next arrives on release.
	if _stick.position.y > LOCK_Y:
		_inserted = true
		_stick.position = LOCK_CENTER


## nextClick: (0x155230): button_press, push a NEW caSelectChocolate with
## the same infoDict.
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.custom_categories = _info
	Nav.next()


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true


## backClick: (0x1551C0): button_press, then pop. Screen's default pops
## silently, so every original back press was missing its click.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()
