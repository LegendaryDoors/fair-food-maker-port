# Donut Ice Cream Sandwich step 3 -- roll the dough flat, then cut six
# donuts with the cutter.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithNibName: 0x90DB4, viewDidLoad 0x90EC8, viewWillAppear: 0x91134,
#   viewDidAppear: 0x91174, resetScreen 0x913F4, nextClick: 0x91214,
#   backClick: 0x912B4, didRollingPinCrossTheCenterPoint:...: 0x91640,
#   isDoughRolledAndReady 0x917C8, isDoughCut 0x91818, updateDoughImage
#   0x918F4, changeInstruction: 0x91C00, showNextButton 0x91A68, cutDough:
#   0x91E30, getClosestOutlineTo: 0x91E88, draggableTouchMoved/Ended
#   0x91FE0 / 0x92118, blocks sub_9238C (dough fade) and sub_923CC (snap
#   home); -[UIView distanceFromPoint:] 0x90D2C.
#
# Mechanic, as read:
#  * ROLL. The rolling pin is a free DraggableIV. Every touch-move runs the
#    predicate at 0x91640 against the dough's centre y (249.5): it "crosses"
#    unless the pin was previously below the centre and is still at-or-below
#    it -- i.e. every move event while the pin sits at-or-above the dough
#    centre counts, plus each upward crossing -- gated on pin.center.x being
#    strictly inside (doughFrame.x + 20, doughFrame.x + width - 20) =
#    (54, 267). Each "cross" bumps currentDough, plays cd_flour_uncoated
#    and advances the dough art dis_dough_0{1..5} every 3 counts
#    (updateDoughImage, index currentDough/3). rollingPinLastYPosition
#    starts at 0 (resetScreen), so the very first in-range move counts.
#  * The dough view is contentMode 4 (CENTER) in the nib, so each art --
#    100x97, 192x109, 213x155, 239x195, 253x249 -- sits at its natural size
#    centred on (160.5, 249.5): the dough visibly spreads as it is rolled.
#    (Corrected: the port used to scale every stage to the full
#    253x249 frame, a big blob from the first frame.)
#  * Each "cross" is counted per touchesMoved: event, so the count is gated
#    on Screen.accept_touch_move() (60 Hz, the iPhone's delivery ceiling).
#  * At currentDough/3 == 4 (fully rolled) the six dis_donut_cut_01 shapes
#    appear on the dough (updateDoughImage tail). Releasing the pin once
#    isDoughRolledAndReady (currentDough >= 12) swaps pin -> cutter and the
#    instruction to inst_drag_cut_6.png (0x92118).
#  * CUT. Releasing the cutter with centre y >= 160 unhides the nearest
#    still-hidden dis_donut_cut_02 outline (getClosestOutlineTo:, Euclidean
#    distance from each outline's CENTRE -- distanceFromPoint: 0x90D2C) and
#    plays cd_flour_uncoated. When all six are visible: showNextButton,
#    both draggables hidden, dough fades out over 0.8s
#    (double 0x3FE999999999999A, sub_9238C sets doughView alpha 0;
#    animateWithDuration:animations: = default ease-in-out curve).
#  * Every release also animates the dragged view home over 0.5s (0x92118
#    tail, sub_923CC).
#
# backClick: (0x912B4): navStack[count-3] is round-3's mix -> popTo it (two
# screens back, skipping stir round 3); a plain pop when it is not (after
# the round-3 skip consumable). See _on_backClick.
#
# This class's changeInstruction: (0x91C00) is the standard +500 slide but
# ALSO hides the next button at the end -> instruction_hides_next().
#
# Z-order: the pin and cutter are nib views 16/17, below instructionView,
# back and next; the built sprites take their placeholders' slots.
#
# KEEP-STATE: kept alive under the push to dicDonutFry.
# The pin and cutter are built once (viewDidLoad); resetScreen
# (viewWillAppear:) and the inst_roll slide (viewDidAppear:) run on entry and
# in on_resume. on_exit = viewDidDisappear:.

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

const DicMix := preload("res://screens/dicMixIngredientsViewController.gd")

const DraggableSprite2D := preload("res://core/DraggableSprite2D.gd")

## Nib: dough (34,125,253,249), contentMode 4 (center) -> every stage's art
## at natural size centred on (160.5, 249.5).
const DOUGH_RECT := Rect2(34, 125, 253, 249)
const DOUGH_IMAGES := ["dis_dough_01.png", "dis_dough_02.png",
	"dis_dough_03.png", "dis_dough_04.png", "dis_dough_05.png"]
## Pin x gate: dough.frame.x + 20 .. + width - 20 (floats in 0x91640).
const ROLL_X_MARGIN := 20.0
## Rolled-and-ready: currentDough/3 + 1 >= count(=5)  =>  currentDough >= 12.
const ROLL_STEP_DIV := 3

## Draggable nib frames (ids 16/17); both art files are native-size.
const PIN_FRAME := Rect2(-4, 52, 320, 80)
const CUTTER_FRAME := Rect2(110, 44, 96, 96)
## Cutter release threshold: center.y >= 160.0 (0x92118).
const CUT_MIN_Y := 160.0
## Release snap home: 0.5s (0x92118 tail).
const SNAP_SECONDS := 0.5
## Dough fade once cut: 0.8s (double 0x3FE999999999999A).
const DOUGH_FADE := 0.8

var _current_dough := 0
var _pin_last_y := 0.0
var _pin: DraggableSprite2D
var _cutter: DraggableSprite2D
var _dough_fade: Tween


## changeInstruction: (0x91C00) ends with nextButton setHidden:YES.
func instruction_hides_next() -> bool:
	return true


## UINavigationController keeps this controller alive under the push to
## dicDonutFry; Nav calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## initWithNibName: (0x90DB4) + viewDidLoad (0x90EC8) once, then
## viewWillAppear: (0x91134 -> resetScreen) and viewDidAppear: (0x91174).
func on_enter() -> void:
	_build_draggables()
	_reset_screen()
	UIKit.park_instruction(self, true)   # nib: hidden


## viewDidAppear: (0x91174), after the push / pop slide:
## changeInstruction:@"inst_roll.png" -- on every appearance.
func on_did_appear() -> void:
	change_instruction("inst_roll.png")


## Back from dicDonutFry: viewWillAppear: -> resetScreen RESETS the step --
## dough back to dis_dough_01 at alpha 1, pin shown, cutter hidden, every
## cut shape and outline hidden, next hidden; viewDidAppear: re-slides
## inst_roll. The dough is rolled and cut again.
func on_resume() -> void:
	_reset_screen()
	# viewDidAppear:'s changeInstruction: runs in on_did_appear().


## viewDidDisappear: (0x911C0) hides instructionView; there is no
## viewWillDisappear:. INFERRED (UIKit): a UIView animation still running
## when its view leaves the window is removed and the layer shows its model
## value, so an unfinished dough fade lands at alpha 0 here rather than
## resuming over resetScreen's alpha 1 on return.
func on_exit() -> void:
	dismiss_instruction()
	if _dough_fade != null and _dough_fade.is_valid():
		_dough_fade.kill()
		var dough := outlet("doughView")
		if dough is CanvasItem:
			(dough as CanvasItem).modulate.a = 0.0


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _build_draggables() -> void:
	for o_name: String in ["rollingPinDraggable", "cutterDraggable"]:
		var o := outlet(o_name)
		if o != null and o != self:
			(o as CanvasItem).visible = false
	_pin = _make_drag(PIN_FRAME, "dis_rolling_pin.png", "rollingPinDraggable")
	_pin.drag_moved.connect(_on_pin_moved)
	_pin.drag_ended.connect(_on_pin_released)
	_cutter = _make_drag(CUTTER_FRAME, "dis_donut_cutter.png", "cutterDraggable")
	_cutter.drag_ended.connect(_on_cutter_released)


func _make_drag(frame: Rect2, art: String, slot_name: String) -> DraggableSprite2D:
	var s := DraggableSprite2D.new()
	var tex := _tex(art)
	s.texture = tex
	s.centered = false
	s.position = frame.position
	if tex != null:
		s.scale = frame.size / Vector2(tex.get_size())
	var slot := outlet(slot_name)
	if slot != null and slot != self and slot.get_parent() == self:
		slot.add_sibling(s)   # the nib's place, below instruction/back/next
	else:
		add_child(s)
	return s


## resetScreen (0x913F4).
func _reset_screen() -> void:
	_current_dough = 0
	_pin_last_y = 0.0
	_set_dough_image(0)
	var dough := outlet("doughView") as Sprite2D
	if dough != null:
		dough.modulate.a = 1.0
	var next := first_outlet(NEXT_OUTLETS)
	if next != null:
		(next as CanvasItem).visible = false
	_pin.visible = true
	_pin.enabled = true
	_cutter.visible = false
	_cutter.enabled = false
	for i in 6:
		for stem: String in ["cutOutView%d", "cutOutView%dOutline"]:
			var v := outlet(stem % (i + 1))
			if v != null and v != self:
				(v as CanvasItem).visible = false


func _set_dough_image(index: int) -> void:
	var dough := outlet("doughView") as Sprite2D
	if dough == null:
		return
	var tex := _tex(DOUGH_IMAGES[index])
	if tex == null:
		return
	dough.texture = tex
	dough.centered = false
	# contentMode 4 (UIViewContentModeCenter): natural size, centred.
	dough.scale = Vector2.ONE
	dough.position = DOUGH_RECT.position \
		+ (DOUGH_RECT.size - Vector2(tex.get_size())) * 0.5


## didRollingPinCrossTheCenterPoint:...: (0x91640). Returns NO only when the
## pin came from below the dough centre and has not yet risen above it;
## otherwise a "cross", gated on the x range. Ported predicate verbatim.
func _pin_crossed(center: Vector2, last_y: float) -> bool:
	var dough_cy := DOUGH_RECT.position.y + DOUGH_RECT.size.y * 0.5   # 249.5
	if dough_cy < last_y and center.y >= dough_cy:
		return false
	if center.x <= DOUGH_RECT.position.x + ROLL_X_MARGIN:
		return false
	return center.x < DOUGH_RECT.end.x - ROLL_X_MARGIN


## draggableTouchMoved: (0x91FE0), rolling-pin branch. One call per
## touchesMoved: on the phone -- at most 60 a second -- so the count is paced
## by Screen.accept_touch_move(); a dropped event neither counts nor latches
## the last y, exactly as if iOS had never delivered it.
func _on_pin_moved(center: Vector2) -> void:
	if not accept_touch_move():
		return
	if _pin_crossed(center, _pin_last_y):
		_current_dough += 1
		_update_dough_image()
		Audio.play("cd_flour_uncoated")
	_pin_last_y = center.y


## updateDoughImage (0x918F4): art index currentDough/3; at the last image
## the six cut shapes appear.
func _update_dough_image() -> void:
	var idx := _current_dough / ROLL_STEP_DIV
	if idx < DOUGH_IMAGES.size():
		_set_dough_image(idx)
	if idx == DOUGH_IMAGES.size() - 1:
		for i in 6:
			var v := outlet("cutOutView%d" % (i + 1))
			if v != null and v != self:
				(v as CanvasItem).visible = true


func _is_rolled() -> bool:   # isDoughRolledAndReady (0x917C8)
	return _current_dough / ROLL_STEP_DIV + 1 >= DOUGH_IMAGES.size()


func _on_pin_released(_pos: Vector2, _hit: bool) -> void:
	if _is_rolled():
		_pin.visible = false
		_pin.enabled = false
		_cutter.visible = true
		_cutter.enabled = true
		change_instruction("inst_drag_cut_6.png")
	_snap_home(_pin)


## draggableTouchEnded: (0x92118), cutter branch.
func _on_cutter_released(pos: Vector2, _hit: bool) -> void:
	if pos.y >= CUT_MIN_Y:
		_cut_dough(pos)
		Audio.play("cd_flour_uncoated")
	if _is_cut():
		show_next_button()   # 0x91A68, the standard +500/0.25 slide
		_pin.visible = false
		_cutter.visible = false
		_cutter.enabled = false
		var dough := outlet("doughView")
		if dough is CanvasItem:
			_dough_fade = create_tween()
			_dough_fade.tween_property(dough, "modulate:a", 0.0,
				DOUGH_FADE).set_trans(Tween.TRANS_SINE) \
				.set_ease(Tween.EASE_IN_OUT)   # sub_9238C
	_snap_home(_cutter)


## Both releases end with a 0.5s animate back to origCenter (sub_923CC,
## UIView animateWithDuration default curve = ease-in-out).
## That is +animateWithDuration:animations: (0x9233A) -- the block API with
## no options, so no AllowUserInteraction: for the whole 0.5 s the pin or
## cutter EATS any touch that lands on it (UIKit _UIViewEatsTouches, see
## core/DraggableSprite2D.gd). The port used to let it be grabbed on the way
## home, the tween fighting the drag: a cutter caught mid-glide and dropped
## low on the dough stamped a cut there while the glide pulled the cutter
## off the finger. The dough's 0.8 s fade
## (0x922DA) is block API too, but doughView is a UIImageView with
## interaction off (nib id 3), so it eats nothing.
func _snap_home(d: DraggableSprite2D) -> void:
	var home := PIN_FRAME.position if d == _pin else CUTTER_FRAME.position
	var tw := create_tween()
	tw.tween_property(d, "position", home, SNAP_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	d.eat_touches_during(tw)


## cutDough: + getClosestOutlineTo: (0x91E30 / 0x91E88): unhide the hidden
## outline whose CENTRE is nearest the release point (0x90D2C).
func _cut_dough(at: Vector2) -> void:
	var best: CanvasItem = null
	var best_d := -1.0
	for i in 6:
		var v := outlet("cutOutView%dOutline" % (i + 1))
		if v == null or v == self or (v as CanvasItem).visible:
			continue
		var s := v as Sprite2D
		var center: Vector2 = s.position
		if s.texture != null and not s.centered:
			center += Vector2(s.texture.get_size()) * s.scale * 0.5
		var d := center.distance_to(at)
		if d < best_d or best_d == -1.0:
			best_d = d
			best = s
	if best != null:
		best.visible = true


func _is_cut() -> bool:   # isDoughCut (0x91818)
	for i in 6:
		var v := outlet("cutOutView%dOutline" % (i + 1))
		if v != null and v != self and not (v as CanvasItem).visible:
			return false
	return true


## nextClick: (0x91214): button_press + push the fry screen.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.push("dicDonutFryViewController", "dic")


## backClick: (0x912B4): if count-3 >= 0 and navStack[count-3] is a dicMix
## (the round-3 mix, normally), popToViewController: it -- two screens back,
## past stir round 3 -- else a plain pop. After the round-3 skip consumable
## (mix3 -> rollCut, no stir) count-3 is stir2 and the original pops one, to
## mix3; the port used to pop two unconditionally.
func _on_backClick() -> void:
	Audio.play("button_press")
	DicMix.dic_back(3)
