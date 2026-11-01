# Donut Ice Cream Sandwich step 4 -- fry all six donuts, then lay them back
# on the pan.
#
# From the original binary (IMPs from the ObjC method list):
#   viewDidLoad 0x92858, viewWillAppear: 0x92A5C, resetScreen 0x92A9C,
#   viewDidAppear: 0x92AE8, viewDidDisappear: 0x92B78, nextClick: 0x92C1C,
#   backClick: 0x92CBC, sendDonut:toFrontBelow: 0x92E6C, areAllDonutsCooked
#   0x9334C, areAllDonutsCookedAndReady 0x9341C, resetAllDonuts 0x93758,
#   disableUserInteractionOnAllDonuts 0x93800, donutDidFinishedCooking:
#   0x938B4, draggableTouchBegan/Ended 0x938F4 / 0x93968, blocks sub_93CF8 /
#   sub_93D50 (home), sub_93DA8 (last pickup spot), sub_93E18 (re-sink under
#   the oil). DonutView (DraggableIV subclass): initWithCoder: 0xC804C,
#   startCooking 0xC809C, stopCooking 0xC80CC, reset 0xC80F4,
#   startCookingTimer 0xC81C4, transitionDonutCookingStage 0xC81F8,
#   startVibration 0xC83B8, image-swap block sub_C8338.
#
# Mechanic, as read:
#  * Six DonutView draggables sit on the pan sheet (nib slots 68x68 at
#    x 35/67/107/140/179/212, y 358 -- they overlap). Raw art
#    dis_donut_fry_01 (85x84) is scaleToFill'd into the frame.
#  * Drop a raw donut with its CENTRE inside fryerDropZone (57,120,200,153):
#    startCooking -- interaction off, the donut sinks below the translucent
#    oilLayer (sendDonut:toFrontBelow:), frying_hi_loop starts if not
#    already playing. Cooking advances currentCookingState 1->4 through
#    dis_donut_fry_01..04: first transition after 1.5s (double
#    0x3FF8000000000000), then every 3.0s (0x4008000000000000); the swap is
#    wrapped in a 0.5s UIView animation but UIImageView.image is not
#    animatable, so it lands instantly (quirk kept as an instant swap). The
#    timer's 4th firing (10.5s in) marks it cooked, re-enables interaction
#    and starts the wiggle: rotation 0 <-> +0.087266 rad, 0.1s,
#    autoreverse+repeat (startVibration 0xC83B8 / sub_C8448).
#  * Drop a COOKED donut with its centre inside panDropZone (35,351,245,97):
#    stopCooking (removeAllAnimations -- which freezes the view at the
#    MODEL transform, i.e. tilted +5 deg; quirk kept) and 0.4s
#    (0x3FD999999999999A) back to origCenter. Released anywhere else it
#    returns to where it was picked up (_lastDonutLocation, set in
#    touchBegan) and then re-sinks below the oil.
#  * A raw donut released outside the fryer snaps home over 0.4s.
#  * touchBegan raises the donut to just below the back button (above the
#    oil) so it is visible while dragged.
#  * All six cooked -> instruction inst_drag_pan.png. All six cooked AND at
#    origCenter (the model value, i.e. the release target) -> interaction
#    off everywhere, next button slides in, frying_hi_loop stops.
#  * viewDidAppear loops frying_lo_loop; viewDidDisappear stops both loops.
#
# Dead code, not ported: _atLeastOneDonutIsCooked is written (resetScreen)
# and never read; draggableTouchMoved: (0x93AA4) is an empty stub.
#
# KEEP-STATE: kept alive under the push to the slice
# screen. Donuts are built once (viewDidLoad); resetScreen (viewWillAppear:)
# and the instruction + frying_lo_loop (viewDidAppear:) run on entry and in
# on_resume. on_exit = viewDidDisappear:.

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

const DraggableSprite2D := preload("res://core/DraggableSprite2D.gd")

## Nib slot frames: (x, 358, 68, 68) -> centres (x+34, 392).
const SLOT_X := [35.0, 67.0, 107.0, 140.0, 179.0, 212.0]
const SLOT_Y := 358.0
const SLOT_SIZE := Vector2(68, 68)
## Drop zones (nib ids 4 / 12), tested with CGRectContainsPoint(centre).
const PAN_RECT := Rect2(35, 351, 245, 97)
const FRYER_RECT := Rect2(57, 120, 200, 153)

## DonutView cooking clock: 1.5s to the first transition, 3.0s between the
## rest (0xC81C4 / 0xC81F8); cooked on the 4th firing.
const COOK_FIRST_DELAY := 1.5
const COOK_STAGE_DELAY := 3.0
const STAGES := 4
## Wiggle: 0.1s (0x3FB999999999999A), autoreverse+repeat, +0.087266 rad.
const WIGGLE_SECONDS := 0.1
const WIGGLE_RAD := 0.087266
## Release animations: 0.4s (0x3FD999999999999A).
const MOVE_SECONDS := 0.4

var _donuts: Array = []   # of Dictionary, see _build_donuts
var _gen := 0             # invalidates pending cook timers on reset
var _done := false        # disableUserInteractionOnAllDonuts has run


## changeInstruction: (0x9311C) ends with nextButton setHidden:YES.
func instruction_hides_next() -> bool:
	return true


## UINavigationController keeps this controller alive under the push to
## dicDonutSlice; Nav calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## viewDidLoad (0x92858) once, then viewWillAppear: (0x92A5C -> resetScreen)
## and viewDidAppear: (0x92AE8).
func on_enter() -> void:
	_build_donuts()
	_reset_screen()
	UIKit.park_instruction(self, true)   # nib: hidden


## viewDidAppear: runs when the push / pop slide is over: the
## banner and frying_lo_loop start after the slide, as on the phone.
func on_did_appear() -> void:
	_did_appear()


## Back from dicDonutSlice: resetScreen puts all six donuts back RAW on the
## pan (DonutView reset: dis_donut_fry_01, origCenter, interaction on, not
## cooked) with next hidden; viewDidAppear: re-slides inst_drag_fryer and
## restarts frying_lo_loop. DonutView reset does not touch the transform or
## the stacking, so each donut keeps the +5 deg tilt it was parked with and
## stays above the oil until it is fried again -- as shipped.
func on_resume() -> void:
	_reset_screen()
	# _did_appear() follows from on_did_appear(), after the slide.


## viewDidAppear: (0x92AE8).
func _did_appear() -> void:
	change_instruction("inst_drag_fryer.png")
	Audio.loop("frying_lo_loop")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _build_donuts() -> void:
	var oil := outlet("oilLayer")
	for i in SLOT_X.size():
		var placeholder := outlet("donutDraggable%d" % (i + 1))
		if placeholder != null and placeholder != self:
			(placeholder as CanvasItem).visible = false
		var s := DraggableSprite2D.new()
		s.texture = _tex("dis_donut_fry_01.png")
		s.centered = true   # UIKit centre semantics; the wiggle needs it
		if s.texture != null:
			s.scale = SLOT_SIZE / Vector2(s.texture.get_size())
		var home := Vector2(SLOT_X[i] + SLOT_SIZE.x * 0.5,
			SLOT_Y + SLOT_SIZE.y * 0.5)
		s.position = home
		s.name = "donut%d" % (i + 1)
		add_child(s)
		# Nib order: donuts sit between panDropZone and the oil layer.
		if oil is Node:
			_place_below(s, oil as Node)
		var d := {"node": s, "home": home, "stage": 1, "cooked": false,
			"target": home, "last_pickup": home, "wiggle": null}
		s.drag_started.connect(_on_began.bind(d))
		s.drag_ended.connect(_on_ended.bind(d))
		_donuts.append(d)


## resetScreen (0x92A9C) + resetAllDonuts (0x93758) + DonutView reset 0xC80F4.
func _reset_screen() -> void:
	_gen += 1
	_done = false
	var next := first_outlet(NEXT_OUTLETS)
	if next != null:
		(next as CanvasItem).visible = false
	for d: Dictionary in _donuts:
		var s: DraggableSprite2D = d["node"]
		d["stage"] = 1
		d["cooked"] = false
		d["target"] = d["home"]
		s.texture = _tex("dis_donut_fry_01.png")
		if s.texture != null:   # scaleToFill: the frame stays 68x68
			s.scale = SLOT_SIZE / Vector2(s.texture.get_size())
		s.position = d["home"]
		s.enabled = true
		# No transform reset and no removeAllAnimations in DonutView reset
		# (0xC80F4): rotation stays as it is (0 on entry).


# -- cooking (DonutView) ----------------------------------------------

## startCooking (0xC809C): interaction off, then the timer chain.
func _start_cooking(d: Dictionary) -> void:
	(d["node"] as DraggableSprite2D).enabled = false
	_schedule_stage(d, COOK_FIRST_DELAY)


func _schedule_stage(d: Dictionary, delay: float) -> void:
	var my_gen := _gen
	get_tree().create_timer(delay).timeout.connect(func() -> void:
		if my_gen != _gen or not is_inside_tree():
			return
		_transition_stage(d))


## transitionDonutCookingStage (0xC81F8). The 0.5s "animation" around the
## image swap animates nothing (UIImageView.image is not animatable) -- the
## swap is instant, as shipped.
func _transition_stage(d: Dictionary) -> void:
	if int(d["stage"]) < STAGES:
		d["stage"] = int(d["stage"]) + 1
		var s: DraggableSprite2D = d["node"]
		var tex := _tex("dis_donut_fry_0%d.png" % int(d["stage"]))
		if tex != null:
			s.texture = tex
			s.scale = SLOT_SIZE / Vector2(tex.get_size())
		_schedule_stage(d, COOK_STAGE_DELAY)
	else:
		d["cooked"] = true
		d["stage"] = STAGES
		(d["node"] as DraggableSprite2D).enabled = true
		_start_wiggle(d)
		_on_donut_finished()   # donutDelegate donutDidFinishedCooking:


## startVibration (0xC83B8): 0.1s autoreverse+repeat from the current
## transform to CGAffineTransformRotate(transform, +0.087266) (sub_C8448 --
## relative, read from the disassembly). First time through that is 0 <-> +5
## deg; a donut re-fried after a return (still tilted +5) wiggles +5 <-> +10.
func _start_wiggle(d: Dictionary) -> void:
	var s: DraggableSprite2D = d["node"]
	var base := s.rotation
	_stop_wiggle(d, base)
	d["wiggle_base"] = base
	var tw := create_tween().set_loops()
	tw.tween_property(s, "rotation", base + WIGGLE_RAD, WIGGLE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(s, "rotation", base, WIGGLE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	d["wiggle"] = tw


## stopCooking (0xC80CC): removeAllAnimations snaps the view to its MODEL
## transform -- the rotated one -- so a parked donut keeps the tilt.
func _stop_wiggle(d: Dictionary, freeze_rotation: float) -> void:
	var tw: Variant = d["wiggle"]
	if tw is Tween and (tw as Tween).is_valid():
		(tw as Tween).kill()
	d["wiggle"] = null
	(d["node"] as DraggableSprite2D).rotation = freeze_rotation


## donutDidFinishedCooking: (0x938B4).
func _on_donut_finished() -> void:
	if _all_cooked():
		change_instruction("inst_drag_pan.png")


func _all_cooked() -> bool:   # areAllDonutsCooked (0x9334C)
	for d: Dictionary in _donuts:
		if not d["cooked"]:
			return false
	return true


## areAllDonutsCookedAndReady (0x9341C): all cooked and every centre at
## origCenter. UIKit reads the animation's MODEL value, i.e. the release
## target, so the port compares targets.
func _all_cooked_and_ready() -> bool:
	if not _all_cooked():
		return false
	for d: Dictionary in _donuts:
		if d["target"] != d["home"]:
			return false
	return true


# -- dragging ---------------------------------------------------------

## draggableTouchBegan: (0x938F4): remember the pickup spot, raise the donut
## to just below the back button (above the oil).
func _on_began(d: Dictionary) -> void:
	d["last_pickup"] = (d["node"] as DraggableSprite2D).position
	var back := first_outlet(BACK_OUTLETS)
	if back != null:
		_place_below(d["node"], back)


## draggableTouchEnded: (0x93968).
func _on_ended(center: Vector2, _hit: bool, d: Dictionary) -> void:
	var s: DraggableSprite2D = d["node"]
	if d["cooked"]:
		if PAN_RECT.has_point(center):
			# stopCooking freezes the wiggle at the model value (+5 deg on
			# top of wherever the wiggle started).
			_stop_wiggle(d, float(d.get("wiggle_base", 0.0)) + WIGGLE_RAD)
			_move(s, d, d["home"])           # sub_93D50
		else:
			_move(s, d, d["last_pickup"], true)   # sub_93DA8 + sub_93E18
		if _all_cooked_and_ready():
			_done = true
			for e: Dictionary in _donuts:    # 0x93800
				(e["node"] as DraggableSprite2D).enabled = false
			show_next_button()
			Audio.stop("frying_hi_loop")
	else:
		if FRYER_RECT.has_point(center):
			# The donut stays where it was released; its centre is now away
			# from origCenter, which is what areAllDonutsCookedAndReady reads.
			d["target"] = s.position
			_start_cooking(d)
			_sink_below_oil(s)
			Audio.loop("frying_hi_loop")     # no-op if already looping
		else:
			_move(s, d, d["home"])           # sub_93CF8


## The 0.4 s release animations are +animateWithDuration:animations:
## [completion:] (no options: 0x93A4A / 0x93AE8 / 0x93CA8), and while a
## block-API animation without AllowUserInteraction runs, UIKit's hitTest:
## lets the view EAT any touch that lands on it (_UIViewEatsTouches, see
## core/DraggableSprite2D.gd) -- only the wiggle (startVibration, options
## 27 = 1|2|8|16) allows interaction. So a donut gliding home cannot be
## grabbed until it lands, and a touch on it does not reach the donut under
## it either. The port used to let it be grabbed mid-glide: dropped in the
## fryer, it started cooking while the still-running glide carried it back
## onto the pan, where it fried "without being dragged in" and -- its target
## being the fryer spot -- never counted as parked: next never came
## (a soft lock). The first fix toggled `enabled`,
## which let the touch fall through to a donut underneath; eating it is the
## phone's behaviour and leaves the screen's own enable logic alone.
func _move(s: DraggableSprite2D, d: Dictionary, to: Vector2,
		sink_after := false) -> void:
	d["target"] = to
	var tw := create_tween()
	tw.tween_property(s, "position", to, MOVE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if sink_after:
		tw.tween_callback(_sink_below_oil.bind(s))
	s.eat_touches_during(tw)


## sendDonut:toFrontBelow:oilLayer (0x92E6C / sub_93E18).
func _sink_below_oil(s: Node) -> void:
	var oil := outlet("oilLayer")
	if oil is Node:
		_place_below(s, oil as Node)


## sendDonut:toFrontBelow: (0x92E6C): a zero-size placeholder is inserted
## below `ref`, its index exchanged with the donut's, then removed -- the
## donut lands DIRECTLY below `ref` whichever side of it it started on, and
## nothing else moves. Godot's move_child(n, ref.get_index()) only does that
## when n starts ABOVE ref; from below it lands one ABOVE ref (the removal
## shifts ref down first). That put a picked-up donut over the back button,
## where the original keeps it under back / next / instruction.
func _place_below(n: Node, ref: Node) -> void:
	if n.get_parent() != self or ref.get_parent() != self:
		return
	var to := ref.get_index()
	if n.get_index() < to:
		to -= 1
	move_child(n, to)


## nextClick: (0x92C1C): button_press + push the slice screen.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.push("dicDonutSliceViewController", "dic")


## backClick: (0x92CBC): plain pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


## viewDidDisappear: (0x92B78): instruction hidden, both fry loops off.
## (There is no viewWillDisappear:, and nothing cancels a DonutView's cooking
## performs -- none can be pending here anyway: next only shows once every
## donut is cooked and parked.)
func on_exit() -> void:
	dismiss_instruction()
	Audio.stop("frying_lo_loop")
	Audio.stop("frying_hi_loop")
