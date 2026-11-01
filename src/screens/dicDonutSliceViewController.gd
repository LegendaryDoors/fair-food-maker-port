# Donut Ice Cream Sandwich step 5 -- saw the big donut in half with the
# knife.
#
# From the original binary (IMPs from the ObjC method list):
#   viewDidLoad 0x103170, viewWillAppear: 0x10331C, viewDidAppear: 0x10335C,
#   resetScreen 0x1033FC, nextClick: 0x10349C, animateDonutBeingSliced
#   0x103A60, unsliceDonut 0x103DA8, sendView:toFrontBelow: 0x103E7C,
#   draggableTouchBegan/Moved/Ended 0x103F94 / 0x103FF4 / 0x104230, blocks
#   sub_103CE8 (the slice move), sub_103D80 (showNextButton), sub_1042F8
#   (snap home).
#
# Mechanic, as read -- a saw gesture, not a swipe:
#  * The knife is a DraggableIV (nib frame (48,77,225,68), dis_knife.png
#    308x94 scaleToFill'd). Every touch-move tracks a direction with 20px of
#    hysteresis (0x103FF4): when |lastY - centerY| >= 20 (int-truncated),
#    currentDraggableDirectionUp = lastY > centerY and lastY latches.
#    lastY starts at FLT_MAX (resetScreen 0x1033FC), so the FIRST move event
#    always sets directionUp = YES -- an original quirk, kept.
#  * The slice fires when, not yet slicing, the knife's FRAME contains the
#    centre of the invisible knifeHitPoint view (nib (64,289,192,20) ->
#    (160, 299)) while the direction is up. The knife (and the dead laser)
#    are re-stacked just below donutTop, lsu_slice plays, and the halves
#    animate over 0.4s (0x3FD999999999999A, sub_103CE8): with bc = the
#    bottom half's centre before the cut, donutBottom.center -> bc + (0,20),
#    donutTop.center -> bc + (5,-30), donutTop rotated -0.17453 rad
#    (-10 deg). Completion: showNextButton.
#  * Releasing the knife animates it home over 0.25s (options 2, sub_1042F8);
#    once sliced the release also hides the knife.
#  * touchBegan on the knife plays lsu_knife_pickup.
#  * The direction latch runs once per touchesMoved: -- at most 60 a second
#    on the phone -- so it is paced by Screen.accept_touch_move().
#  * Z-order: the knife is nib view 5 -- above both halves, BELOW the
#    instruction, back and next (8..10); the built sprite takes that slot.
#
# Dead outlet, not built: laserDraggable (nib id 6 -- its art is literally a
# donut, dis_donut_fry_01). resetScreen always hides it and nothing on any
# path shows it; it only appears in the two sendView calls beside the knife.
#
# KEEP-STATE: kept alive under the push to the scoop
# screen. The knife is built once (viewDidLoad); resetScreen
# (viewWillAppear:) and the instruction (viewDidAppear:) run on entry and in
# on_resume. on_exit = viewDidDisappear:.

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

const DraggableSprite2D := preload("res://core/DraggableSprite2D.gd")

## Nib frames. Both donut halves are 247x191; their UIKit centres:
const BOTTOM_CENTER := Vector2(160.5, 244.5)   # (37,149,247,191)
const TOP_CENTER := Vector2(160.5, 248.5)      # (37,153,247,191)
const KNIFE_FRAME := Rect2(48, 77, 225, 68)
## knifeHitPoint (64,289,192,20) -> centre:
const HIT_CENTER := Vector2(160, 299)
## Direction hysteresis: 20 (int compare in 0x103FF4).
const DIR_HYSTERESIS := 20.0
## resetScreen seeds lastDraggbleYPosition with FLT_MAX (0x1033FC).
const LAST_Y_SEED := 3.4028e38
## The slice: 0.4s; top rotation -0.17453 rad; offsets (0,+20) / (+5,-30)
## (0x103A60).
const SLICE_SECONDS := 0.4
const TOP_ROTATION := -0.17453
const BOTTOM_OFFSET := Vector2(0, 20)
const TOP_OFFSET := Vector2(5, -30)
## Knife release snap: 0.25s (0x104230).
const SNAP_SECONDS := 0.25

var _knife: DraggableSprite2D
var _slicing := false
var _last_y := LAST_Y_SEED
var _dir_up := false


## changeInstruction: (0x103830) ends with nextButton setHidden:YES.
func instruction_hides_next() -> bool:
	return true


## UINavigationController keeps this controller alive under the push to
## dicScoopIceCream; Nav calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## viewDidLoad (0x103170) once, then viewWillAppear: (0x10331C ->
## resetScreen) and viewDidAppear: (0x10335C).
func on_enter() -> void:
	_recenter_halves()
	_build_knife()
	_reset_screen()
	UIKit.park_instruction(self, true)   # nib: hidden


## viewDidAppear: (0x10335C), after the push / pop slide:
## changeInstruction:@"inst_cut_donut.png" -- on every appearance.
func on_did_appear() -> void:
	change_instruction("inst_cut_donut.png")


## Back from the scoop screen: resetScreen + unsliceDonut put the donut back
## whole and the knife back (shown, not slicing, lastY FLT_MAX), next hidden;
## viewDidAppear: re-slides inst_cut_donut. resetScreen does not restack the
## knife, so after a slice it stays below donutTop -- as shipped.
func on_resume() -> void:
	_reset_screen()
	# viewDidAppear:'s changeInstruction: runs in on_did_appear().


## viewDidDisappear: (0x1033A8) hides the instruction; no viewWillDisappear:.
func on_exit() -> void:
	dismiss_instruction()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## The halves move and (the top) rotates about their UIKit centres, so the
## scene's top-left Sprite2Ds are re-anchored to centred ones.
func _recenter_halves() -> void:
	for pair: Array in [["donutBottom", BOTTOM_CENTER], ["donutTop", TOP_CENTER]]:
		var s := outlet(pair[0]) as Sprite2D
		if s != null and not s.centered:
			s.centered = true
			s.position = pair[1]


func _build_knife() -> void:
	for dead: String in ["knifeDraggable", "laserDraggable", "knifeHitPoint"]:
		var o := outlet(dead)
		if o != null and o != self and o is CanvasItem:
			(o as CanvasItem).visible = false
	_knife = DraggableSprite2D.new()
	var tex := _tex("dis_knife.png")
	_knife.texture = tex
	_knife.centered = false
	_knife.position = KNIFE_FRAME.position
	if tex != null:
		_knife.scale = KNIFE_FRAME.size / Vector2(tex.get_size())
	# Nib order: the knife draws above the donut halves until the slice, and
	# below the instruction / back / next.
	var slot := outlet("knifeDraggable")
	if slot != null and slot != self and slot.get_parent() == self:
		slot.add_sibling(_knife)
	else:
		add_child(_knife)
	_knife.drag_started.connect(func() -> void:
		Audio.play("lsu_knife_pickup"))   # 0x103F94
	_knife.drag_moved.connect(_on_knife_moved)
	_knife.drag_ended.connect(_on_knife_released)


## resetScreen (0x1033FC) + unsliceDonut (0x103DA8).
func _reset_screen() -> void:
	var next := first_outlet(NEXT_OUTLETS)
	if next != null:
		(next as CanvasItem).visible = false
	_knife.visible = true
	_knife.enabled = true
	_slicing = false
	_last_y = LAST_Y_SEED
	_dir_up = false
	var bottom := outlet("donutBottom") as Sprite2D
	if bottom != null:
		bottom.position = BOTTOM_CENTER
	var top := outlet("donutTop") as Sprite2D
	if top != null:
		top.position = TOP_CENTER
		top.rotation = 0.0


## draggableTouchMoved: (0x103FF4). Paced to the phone's move-event rate.
func _on_knife_moved(center: Vector2) -> void:
	if not accept_touch_move():
		return
	if absf(_last_y - center.y) >= DIR_HYSTERESIS:
		_dir_up = _last_y > center.y
		_last_y = center.y
	if _slicing:
		return
	var frame := Rect2(_knife.position, KNIFE_FRAME.size)
	if frame.has_point(HIT_CENTER) and _dir_up:
		# sendView knife (and laser) below donutTop, then slice.
		var top := outlet("donutTop")
		if top is Node and (top as Node).get_parent() == self:
			# sendView:toFrontBelow: (0x103E7C): directly below donutTop.
			var to := (top as Node).get_index()
			if _knife.get_index() < to:
				to -= 1
			move_child(_knife, to)
		_animate_slice()
		Audio.play("lsu_slice")


## animateDonutBeingSliced (0x103A60) + sub_103CE8 + sub_103D80.
func _animate_slice() -> void:
	_slicing = true
	var bottom := outlet("donutBottom") as Sprite2D
	var top := outlet("donutTop") as Sprite2D
	if bottom == null or top == null:
		show_next_button()
		return
	var bc := bottom.position
	var tw := create_tween().set_parallel(true)
	tw.tween_property(bottom, "position", bc + BOTTOM_OFFSET, SLICE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(top, "position", bc + TOP_OFFSET, SLICE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(top, "rotation", TOP_ROTATION, SLICE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.chain().tween_callback(show_next_button)


## draggableTouchEnded: (0x104230): 0.25s home (UIView default ease-in-out);
## hide the knife once sliced.
## The return is +animateWithDuration:delay:options:animations:completion:
## with options 2 = UIViewAnimationOptionAllowUserInteraction (0x10425E):
## the knife stays touchable on its way home, hit-tested at its MODEL frame
## (home), and the drag owns it once caught -- animate_position(). The port
## used to leave a plain tween pulling a caught knife home under the finger.
func _on_knife_released(_pos: Vector2, _hit: bool) -> void:
	_knife.animate_position(create_tween(), KNIFE_FRAME.position,
		SNAP_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _slicing:
		_knife.visible = false
		_knife.enabled = false


## nextClick: (0x10349C): button_press + push the scoop screen.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.push("dicScoopIceCreamViewController", "dic")


## backClick: (0x10354C): button_press, pop. (Without this override the
## base Screen back was silent.)
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()
