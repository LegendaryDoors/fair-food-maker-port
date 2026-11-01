# Snow Cone step 2 -- scoop crushed ice from the machine into the cup.
#
# Read from scScoopIceViewController in the original binary:
#   viewDidLoad 0x72204, viewWillAppear: 0x725B0, viewDidAppear: 0x727BC,
#   showMachine 0x728A8 / hideMachine 0x729A8, showScooper 0x72AE8 /
#   hideScooper 0x72C74, showCup 0x72E08 / hideCup 0x72FA0,
#   addIceToScooper 0x73170, addIceToCup 0x73268,
#   removeIceFromScooper 0x735B4, touchesBegan/Moved/Ended 0x7409C /
#   0x74184 / 0x74508, animationDidStop 0x74610, backClick: 0x73604,
#   nextClick: 0x736A4.
#
# Mechanic (drag, verified -- not tap): grab the scooper, carry it to the
# crushed-ice pile at the top, a scoop of ice sticks to it; carry it down to
# the cup zone and the scoop bakes into a pyramid, one fixed slot per scoop,
# ten in all. CORRECTED against the original code (the port showed no ice in
# the cup): addIceToCup (0x73268) creates a CGImageMask from
# sc_ice_mask_1.png and then releases it WITHOUT ever clipping to it -- the
# composite is simply the previous ice image with the new rotated scoop
# drawn underneath it (new scoop first, old image on top). The port used to
# show the composite through that mask, whose visible region excludes the
# bottom rows where the first row of scoops lands, so the first four scoops
# were invisible. Now unmasked, as shipped. A SubViewport collects the scoop
# sprites; older scoops are kept above newer ones.
#
# Entry choreography (viewWillAppear + animationDidStop): the machine starts
# fully on screen at centre (160,283) and slides up to its nib home
# (centre (160,-27.5)) over 0.8s; when that lands, the cup slides up from
# +100 and the scooper slides in from the right, both 0.5s.
#
# Corrections from a full re-read: each baked scoop is now clipped to the
# 111x96 context it was rotated in (UIGraphicsBeginImageContext(scoop size));
# the nib's "Debug Skip" button (id11) is wired to skipClick: -> nextClick:
# but ships UIHidden=YES and is never unhidden, so it is dead (corrected
# after it was first read as live because of the swapped
# NIBArchive bool tags); the drag follows the touch over buttons (UIKit
# keeps a touch on the view it began in); back clears the ice, removes the
# machine's ice pile and snaps cup/scooper home before sliding them out, as
# hideCup / hideScooper / hideMachine do.
#
# KEEP STATE: kept under a push; viewWillAppear: restarts the step on
# a return (on_resume), viewWillDisappear: hides scooper/cup/machine
# (on_exit).

extends "res://core/Screen.gd"

## For park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

const MaskedSprite := preload("res://core/MaskedSprite2D.gd")

# -- entry / exit choreography -----------------------------------------
## showMachine (0x728A8): park centre (160,283) (0x43200000/0x438D8000),
## animate to the nib centre, 0.8s (double 0x729A0), curve 0 = ease-in-out.
## For the origin-based scene node that is (10, 106.5) -> (10, -204).
const MACHINE_SHOWN_ORIGIN := Vector2(10, 106.5)
const MACHINE_SLIDE := 0.8
## showScooper/showCup/hideScooper/hideCup all run 0.5s (0x3FE00000).
const PIECE_SLIDE := 0.5
## touchesEnded (0x74508): scooper returns home over 0.4s (double 0x74608).
const SCOOPER_RETURN := 0.4

# -- the drag (touchesMoved: 0x74184) ----------------------------------
## Pickup: the touch, taken in machine-view coords with +70 added to y
## (float 0x744F4), must fall inside the machine view's (0,0,300,353).
const PICKUP_Y_OFFSET := 70.0
const MACHINE_BOUNDS := Rect2(0, 0, 300, 353)
## Drop: the touch, in ice-view coords (view (10,208,300,200), nib id8),
## must be below a threshold that rises as the pyramid grows:
## h*0.5 + {0, -55, -110, -165} (floats 0x74500/0x744FC/0x744F8) for
## scoopCount <4 / <7 / <9 / >=9.
const ICE_VIEW := Rect2(10, 208, 300, 200)

## addIceToCup (0x73268): the composited context is sc_ice_mask_1.png's
## size (300x250); the ice UIImageView is 300x200, so it shows squashed to
## 0.8 vertical -- reproduced with the display scale below. (The nib stores
## no UIContentMode for it, i.e. the default scale-to-fill.)
const COMPOSITE_SIZE := Vector2i(300, 250)
const DISPLAY_SCALE := Vector2(1.0, 0.8)
## The rotated scoop is rendered into UIGraphicsBeginImageContext(frame.size
## of the held scoop) -- the scoop art's natural 111x96 -- so everything the
## 30 degree turn pushes outside that box is cut off before the stamp.
const SCOOP_CONTEXT := Vector2(111, 96)

## Each baked scoop is the sc_ice_scoop art drawn in a context whose CTM is
## rotated +0.5236 rad (0x3F060A92, 30 deg) at point (30,-10) (0x41F00000 /
## 0xC1200000), then stamped at one of ten fixed positions -- the switch
## table in addIceToCup, decoded float-by-float:
const SCOOP_ROT := 0.5236
const SCOOP_DRAW_OFF := Vector2(30, -10)
const SCOOP_SLOTS := [
	Vector2(0, 155), Vector2(63, 155), Vector2(127, 155), Vector2(189, 155),
	Vector2(31, 100), Vector2(94, 100), Vector2(158, 100),
	Vector2(63, 45), Vector2(126, 45),
	Vector2(94, -10),
]
const SCOOPS_REQUIRED := 10

## machineLid hinge (8, h-16) = (8,67), rotated -pi at viewDidLoad
## (0x72204) -- the lid arrives closed and never moves on this screen.
const LID_HINGE := Vector2(8, 67)

var _machine: Node2D
var _cup: Sprite2D
var _scooper: Sprite2D
var _cup_home := Vector2.ZERO
var _scooper_home := Vector2.ZERO
var _scooper_size := Vector2(147, 88)

var _viewport: SubViewport
var _entered := false
var _dragging := false
var _drag_prev := Vector2.ZERO
var _has_ice := false
var _held_scoop: Sprite2D
var _scoop_count := 0
var _done := false
var _leaving := false
## The scooper's running slide (Show_Scooper or Reset_Scooper), if any.
var _return_tween: Tween
## The machine view's model origin, which UIKit's locationInView: /
## pointInside: use even mid-animation: the nib home once showMachine has
## been committed.
var _machine_model := Vector2(10, -204)
var _machine_tween: Tween


func on_enter() -> void:
	# viewDidLoad (0x72204): once per instance.
	_machine = outlet("machine") as Node2D
	_cup = outlet("cup") as Sprite2D
	_scooper = outlet("scooper") as Sprite2D
	_close_lid()
	_build_composite_target()
	if _cup != null:
		_cup_home = _cup.position
	if _scooper != null:
		_scooper_home = _scooper.position
		if _scooper.texture != null:
			_scooper_size = _scooper.texture.get_size() * _scooper.scale
	# viewWillAppear: here and on every return (on_resume); viewDidAppear:
	# in on_did_appear(), when the push / pop slide is over.
	_view_will_appear()
	UIKit.park_instruction(self)


func on_did_appear() -> void:
	_view_did_appear()


## Nav keeps this controller alive under scSelectCupShape, as the
## UINavigationController does.
func keeps_state_on_push() -> bool:
	return true


## Back from scSelectCupShape. viewWillAppear: (0x725B0) runs again and
## restarts the step: scoopCount, scooperHasIce, isScooperBeingTouched and
## doneScooping go back to 0, the ice image is set to nil, next is hidden and
## the machine slides up once more (showMachine), cup and scooper following
## when it lands -- the player scoops ten again. viewDidAppear: (0x727BC)
## re-runs changeInstruction:.
func on_resume() -> void:
	# A Reset_Scooper glide still running when next was tapped would have
	# finished while covered; showScooper starts from the model frame.
	if _return_tween != null and _return_tween.is_valid():
		_return_tween.kill()
		if _scooper != null:
			_scooper.position = _scooper_home
	_view_will_appear()
	# viewDidAppear: follows in on_did_appear(), after the pop slide.


## viewWillDisappear: (0x72828): scooper, cup and machine hidden. Nothing
## else -- the scoops in the cup and the machine's pile stay as they are.
func on_exit() -> void:
	_dragging = false
	if _scooper != null:
		_scooper.visible = false
	if _cup != null:
		_cup.visible = false
	if _machine != null:
		_machine.visible = false


## viewWillAppear: (0x725B0): scooper and cup hidden, machine unhidden,
## next hidden, showMachine, and the scoop state reset.
func _view_will_appear() -> void:
	_entered = false
	_dragging = false
	if _cup != null:
		_cup.visible = false
	if _scooper != null:
		_scooper.visible = false
	if _machine != null:
		_machine.visible = true
	_set_next_visible(false)
	_show_machine()
	_scoop_count = 0                    # scoopCount
	_has_ice = false                    # scooperHasIce (the tag-1 view stays)
	_done = false                       # doneScooping
	_clear_ice()                        # [ice setImage:nil]


## viewDidAppear: (0x727BC): instIV unhidden, changeInstruction:.
func _view_did_appear() -> void:
	change_instruction("inst_scoop_ice.png")


## showMachine (0x728A8): park the centre at (160,283), animate to the nib
## centre over 0.8 s ease-in-out; Show_Machine's stop runs showCup and
## showScooper.
func _show_machine() -> void:
	if _machine == null:
		_show_pieces()
		return
	if _machine_tween != null and _machine_tween.is_valid():
		_machine_tween.kill()
	_machine.position = MACHINE_SHOWN_ORIGIN
	_machine_model = Vector2(10, -204)
	_machine_tween = create_tween()
	_machine_tween.tween_property(_machine, "position", _machine_model,
		MACHINE_SLIDE).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_machine_tween.tween_callback(_show_pieces)


## viewDidLoad (0x72204): anchor (8/w,(h-16)/h) then rotate -pi.
func _close_lid() -> void:
	var lid := outlet("machineLid")
	if lid is Sprite2D:
		var l := lid as Sprite2D
		if not l.centered and l.offset == Vector2.ZERO:
			l.offset = -LID_HINGE
			l.position += LID_HINGE * l.scale
		l.rotation = -PI


## The scoop pyramid: clipped scoop stamps land in a SubViewport the size of
## the composite context; a plain Sprite2D under the nib `ice` node shows it
## (no mask -- see the header).
func _build_composite_target() -> void:
	_viewport = SubViewport.new()
	_viewport.size = COMPOSITE_SIZE
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	var ice := outlet("ice")
	# No mask: addIceToCup builds one and never uses it (header).
	var display := Sprite2D.new()
	display.texture = _viewport.get_texture()
	display.centered = false
	display.scale = DISPLAY_SCALE
	if ice is Node2D:
		(ice as Node2D).add_child(display)   # inherits the nib z-order
	else:
		display.position = ICE_VIEW.position
		add_child(display)


## animationDidStop "Show_Machine" (0x74610) -> showCup + showScooper.
func _show_pieces() -> void:
	if _cup != null:
		_cup.visible = true
		_cup.position = _cup_home + Vector2(0, 100)   # + h*0.5
		create_tween().tween_property(_cup, "position", _cup_home,
			PIECE_SLIDE).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if _scooper != null:
		_scooper.visible = true
		_scooper.position = _scooper_home + Vector2(_scooper_size.x, 0)
		# The model frame is home from here on, so a grab mid-slide is
		# handled like a grab mid-return (see _unhandled_input).
		_return_tween = create_tween()
		_return_tween.tween_property(_scooper, "position", _scooper_home,
			PIECE_SLIDE).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_entered = true


# -- the drag -----------------------------------------------------------

## touchesBegan (0x7409C): gated on !doneScooping only; a touch inside the
## scooper's (model) frame grabs it. PORT CHOICE: presses are also ignored
## until the pieces have entered -- in the original, pointInside: ignores
## `hidden`, so a touch during the 0.8 s machine slide could grab the
## still-hidden scooper and then fight showScooper's animation.
func _unhandled_input(event: InputEvent) -> void:
	if _done or _leaving or not _entered or _scooper == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
			return
		# The model frame: home while the Show_Scooper slide or the 0.4 s
		# Reset_Scooper glide is still running.
		var returning := _return_tween != null and _return_tween.is_valid()
		var origin := _scooper_home if returning else _scooper.position
		if Rect2(origin, _scooper_size).has_point(mb.position):
			if returning:
				_return_tween.kill()
				_scooper.position = _scooper_home
			_dragging = true
			_drag_prev = mb.position
			get_viewport().set_input_as_handled()


## Moves and the release are taken in _input: UIKit keeps delivering a touch
## to the view it began in, so the drag must not stall when the cursor
## crosses a button (back / next).
func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_release()
	elif event is InputEventMouseMotion:
		_drag_to((event as InputEventMouseMotion).position)


func _drag_to(pos: Vector2) -> void:
	# touchesMoved (0x74184): the scooper's frame moves by the touch delta.
	_scooper.position += pos - _drag_prev
	_drag_prev = pos

	# Pickup zone: touch in machine coords, +70 on y, inside (0,0,300,353).
	if _machine != null:
		var local := pos - _machine_model + Vector2(0, PICKUP_Y_OFFSET)
		if MACHINE_BOUNDS.has_point(local) and not _has_ice \
				and _scoop_count < SCOOPS_REQUIRED:
			_add_ice_to_scooper()
			return

	# Drop zone: touch inside the ice view, below the row threshold.
	if not ICE_VIEW.has_point(pos):
		return
	var local_y := pos.y - ICE_VIEW.position.y
	var threshold := 100.0                       # h*0.5
	if _scoop_count >= 9:
		threshold = -65.0
	elif _scoop_count >= 7:
		threshold = -10.0
	elif _scoop_count >= 4:
		threshold = 45.0
	if local_y > threshold:
		_add_ice_to_cup()


## addIceToScooper (0x73170): scoop.mp3, sc_ice_scoop.png added at the
## scooper view's origin, natural size, tag 1 -- no frame is ever set.
func _add_ice_to_scooper() -> void:
	Audio.play("scoop")
	_has_ice = true
	var tex := _tex("sc_ice_scoop.png")
	if tex == null:
		return
	_held_scoop = Sprite2D.new()
	_held_scoop.texture = tex
	_held_scoop.centered = false
	_scooper.add_child(_held_scoop)


## addIceToCup (0x73268): guarded on scooperHasIce; sc_snow_pack.mp3; the
## rotated scoop tile is stamped at its fixed slot; at ten scoops
## doneScooping + showNextButton; the held scoop is removed either way.
func _add_ice_to_cup() -> void:
	if not _has_ice:
		return
	Audio.play("sc_snow_pack")
	var tex := _tex("sc_ice_scoop.png")
	if tex != null and _viewport != null and _scoop_count < SCOOP_SLOTS.size():
		# The scoop-sized context the rotation was drawn into, stamped at
		# the slot: a clipping box holding the rotated art.
		var box := Control.new()
		box.position = SCOOP_SLOTS[_scoop_count]
		box.size = SCOOP_CONTEXT
		box.clip_contents = true
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tile := Sprite2D.new()
		tile.texture = tex
		tile.centered = false
		tile.rotation = SCOOP_ROT
		tile.offset = SCOOP_DRAW_OFF
		box.add_child(tile)
		_viewport.add_child(box)
		# drawAtPoint: new scoop first, then the previous image over it.
		_viewport.move_child(box, 0)
	_scoop_count += 1
	if _scoop_count >= SCOOPS_REQUIRED:
		_done = true
		show_next_button()
	_remove_ice_from_scooper()


func _remove_ice_from_scooper() -> void:
	if _held_scoop != null and is_instance_valid(_held_scoop):
		_held_scoop.queue_free()
	_held_scoop = null
	_has_ice = false


## touchesEnded (0x74508): any held scoop is discarded and the scooper
## glides home over 0.4s.
func _release() -> void:
	_dragging = false
	_remove_ice_from_scooper()
	_return_tween = create_tween()
	_return_tween.tween_property(_scooper, "position", _scooper_home,
		SCOOPER_RETURN).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# -- navigation ---------------------------------------------------------

## backClick: (0x73604): click sound, next hidden, cup and scooper slide
## out (0.5s), the machine slides back down (0.8s), then the screen pops
## on the Hide_Machine callback (0x74610).
func _on_backClick() -> void:
	if _leaving:
		return
	_leaving = true
	_dragging = false
	Audio.play("button_press")
	_set_next_visible(false)
	# hideCup (0x72FA0): unhidden, snapped to its home centre, the ice image
	# cleared, then slid down by half its height.
	if _cup != null:
		_cup.visible = true
		_cup.position = _cup_home
		create_tween().tween_property(_cup, "position",
			_cup_home + Vector2(0, 100), PIECE_SLIDE) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_clear_ice()
	# hideScooper (0x72C74): likewise snapped home first, then out to the
	# right by its own width.
	if _scooper != null:
		if _return_tween != null and _return_tween.is_valid():
			_return_tween.kill()
		_scooper.visible = true
		_scooper.position = _scooper_home
		create_tween().tween_property(_scooper, "position",
			_scooper_home + Vector2(_scooper_size.x, 0), PIECE_SLIDE) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# hideMachine (0x729A8): the slide back down, and the machine view's last
	# subview -- the nib's sc_ice_pile -- removed as the slide starts.
	_remove_machine_pile()
	if _machine != null:
		if _machine_tween != null and _machine_tween.is_valid():
			_machine_tween.kill()
		_machine_model = MACHINE_SHOWN_ORIGIN
		_machine.position = Vector2(10, -204)
		var tw := create_tween()
		tw.tween_property(_machine, "position", MACHINE_SHOWN_ORIGIN,
			MACHINE_SLIDE).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_callback(Nav.back)
	else:
		Nav.back()


func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.next()


## skipClick: (0x73754) -> nextClick:. The nib's id11 (skipButton outlet)
## is a RoundedRect "Debug Skip" at (190,381,120,40), alpha 0.3, that ships
## UIHidden=YES; nothing in the class unhides it (the outlet is only
## released), so it can never be tapped -- the generated scene hides it too.
## (Corrected: this used to say "NOT hidden ... tapping there skips the
## scooping", because of the swapped NIBArchive bool tags.)
func _on_skipClick() -> void:
	_on_nextClick()


## hideCup: [ice setImage:nil].
func _clear_ice() -> void:
	if _viewport == null:
		return
	for c in _viewport.get_children():
		c.queue_free()


## hideMachine: [[machine.subviews lastObject] removeFromSuperview] -- the
## last of the machine view's nib subviews is the sc_ice_pile image.
func _remove_machine_pile() -> void:
	if _machine == null or _machine.get_child_count() == 0:
		return
	var last := _machine.get_child(_machine.get_child_count() - 1)
	last.queue_free()


func _set_next_visible(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.set("disabled", not on)


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
