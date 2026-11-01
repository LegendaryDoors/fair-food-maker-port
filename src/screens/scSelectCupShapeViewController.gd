# Snow Cone step 3 -- pick a cup and an ice shape, one page at a time.
#
# Read from scSelectCupShapeViewController in the original binary:
#   viewDidLoad 0x75454, viewWillAppear: 0x75778, screenSetup 0x75840,
#   applyMaskToImage:mask: 0x75B24, initCupsAndShapes 0x75D34,
#   scrollViewDidScroll: 0x779BC,
#   scrollViewWillEndDragging:withVelocity:targetContentOffset: 0x77B10,
#   nextClick: 0x76D90.
#
# initCupsAndShapes builds two paging UIScrollViews in code (this nib holds
# only the chrome):
#   shapes  frame (0,0,320,250)   -- 21 thumbs, "sc_ice_mask_%d.png" 1..21
#   cups    frame (0,237,320,243) -- 22 cups,   "sc_cup%d.png"       1..22
# One item per 320px page: item i is centred at x = 160 + 320*i (the loop's
# `i*0x140 + 0xa0`), shapes at y 125, cups at y 148 with an explicit
# (330,295) frame. Content offset then jumps to 1120 (0x448C0000, page 3.5)
# and animates back to page 0 over 2.0s; showNextButton fires 3.0s in
# (performSelector:afterDelay:), with the next button hidden until then.
#
# A shape thumb is applyMaskToImage:mask: (0x75B24): the flat ice art
# (sc_background_ice_solid.png) clipped by the shape mask, then washed with
# white at alpha 0.75 in kCGBlendModeLighten -- against a white source that
# blend collapses to a plain 75% white overlay, which is what the second
# MaskedSprite2D below is.
#
# The IAP locks (tags 1000+/2000+) are all hidden with everything unlocked
# (reloadLocks / screenSetup), so the port does not build them.
#
# Corrections from a full re-read: the strips now scroll like the
# UIScrollViews they are -- free scrolling with UIKit's deceleration, the
# release velocity projected forward and THEN rounded to a page by
# scrollViewWillEndDragging (0x77B10), so a flick can travel several pages;
# the current indices follow the live offset as scrollViewDidScroll (0x779BC)
# does on every change. The instruction banner no longer slides in: nothing
# on this screen calls changeInstruction: (instIV just sits at its nib spot
# until showNextButton hides it).
#
# KEEP STATE: kept under a push; a return finds the strips where
# they were left and next still showing (viewWillAppear: only re-runs the
# lock bookkeeping). The mystery pick's 0.8 s window lockout now also
# blocks next/back.
#
# SCROLLING: the hand-rolled
# flick (a 0.1 s velocity window and a pure exponential decay toward the
# rounded target) is gone. Each strip is now a UIKit.ScrollPhysics -- the
# iOS 6 UIScrollView arithmetic of core/UIScrollSim -- with exactly the
# original's settings: frames (0,0,320,250) / (0,237,320,243), contentSize
# (320 * count, frame height), both setShowsHorizontalScrollIndicator:NO
# (the vertical one is the default but never shows: content height = frame
# height), decelerationRate and bounces left at their defaults (Normal
# 0.998, YES). scrollViewWillEndDragging: (0x77B10) is the sim's
# will_end_dragging target snap; scrollViewDidScroll: (0x779BC) re-derives
# the indices from every offset the sim reports. The mystery pick's
# setContentOffset:animated:YES is the sim's 0.3 s UIScrollViewScrollAnimation.

extends "res://core/Screen.gd"

const MaskedSprite := preload("res://core/MaskedSprite2D.gd")
const UIKit := preload("res://screens/msUIKit.gd")
const UIScrollSim := preload("res://core/UIScrollSim.gd")

const CUP_COUNT := 22                    # loop bound 0x17 in initCupsAndShapes
const SHAPE_COUNT := 21                  # loop bound 0x16
const PAGE := 320.0                      # item pitch 0x140
const ITEM_X0 := 160.0                   # first centre 0xa0
const SHAPE_Y := 125.0                   # 0x42FA0000
const CUP_STRIP_Y := 237.0               # cup scroll view frame y 0x436D0000
const CUP_Y := 148.0                     # 0x43140000, in strip coords
const CUP_SIZE := Vector2(330, 295)      # 0x43A50000 / 0x43938000
const WASH_ALPHA := 0.75                 # CGContextSetAlpha 0x3F400000
const ENTER_OFFSET := 1120.0             # 0x448C0000
const ENTER_SECONDS := 2.0               # double via 0x40000000 high word
const NEXT_DELAY := 3.0                  # double via 0x40080000 high word
## willEndDragging (0x77B10): remainder > 160 rounds up to the next 320
## boundary, otherwise down (floats 0x77B68 / 0x77B6C).
const SNAP_HALF := 160.0
## The two code-built scroll views (initCupsAndShapes 0x75D34).
const SHAPE_FRAME := Rect2(0, 0, 320, 250)
const CUP_FRAME := Rect2(0, 237, 320, 243)

var _shape_strip: Node2D
var _cup_strip: Node2D
var _shape_offset := 0.0
var _cup_offset := 0.0
var _shape_index := 0
var _cup_index := 0

var _dragging := false
var _drag_cups := false
var _entering := true
## The two UIScrollViews' physics.
var _shape_ph: UIKit.ScrollPhysics
var _cup_ph: UIKit.ScrollPhysics

## Mystery selection:
##   initWithNibName: 0x75208  Consumable DM_CONSUMABLE_MYSTERY_SELECT /
##     MysterySelect_30SelectCupShape, cost = CoinCosts."Snow Cone".
##     MysteryShape, 6 when absent; first-time message.
##   viewDidLoad 0x75454  ConsumableButton(btn_mystery_selection, (0,-25) /
##     (65,3)) at centre (50, 350.5); buyMysterySelectClick:; buyAllBtn hidden.
##   buyMysterySelectClick: 0x76CB4  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x766E4  quantity 0, reloadLocks (0x76B7C), window
##     touches off; shape s = arc4random() % (shapes-1) + 1 until
##     s != currentShapeIndex, then cup c = arc4random() % (cups-1) + 1 until
##     c != currentCupIndex (neither ever lands on page 0); both scroll views
##     setContentOffset:(320*i) animated; lock tags 1001+s / 2000+c hidden;
##     enableTouches (0x76A60) after 0.8 s.
##   consumablePurchaseFailed:error:2 0x76AA8  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_SELECT"
const MYSTERY_NAME := "MysterySelect_30SelectCupShape"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery selection! You never know what selection it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_selection.png"
const MYSTERY_CENTER := Vector2(50, 350.5)
const MYSTERY_LOCKOUT := 0.8

var _mystery: RefCounted
var _mystery_button: TextureButton
var _locked := false      # keyWindow userInteractionEnabled NO


func on_enter() -> void:
	_build_strips()
	_build_mystery()
	_park_instruction()
	_set_next_visible(false)

	# setContentOffset:(1120,0) on both, then inside a 2.0 s UIView block
	# ("Animate_To_First_Item", default curve EaseInOut)
	# setContentOffset:(0,0) animated:NO: the MODEL offset -- and so
	# scrollViewDidScroll:'s indices -- is 0 at once; only the drawn bounds
	# glide back from 1120 (UIScrollSim.curve, the exact UIView curve).
	_shape_ph.set_content_offset(Vector2(ENTER_OFFSET, 0))
	_cup_ph.set_content_offset(Vector2(ENTER_OFFSET, 0))
	_shape_ph.set_content_offset(Vector2.ZERO)
	_cup_ph.set_content_offset(Vector2.ZERO)
	_place_strip(true, ENTER_OFFSET)
	_place_strip(false, ENTER_OFFSET)
	# The glide is a +beginAnimations: block (initCupsAndShapes 0x75D34), so
	# the strips take drags while it runs (old-style blocks leave touches on:
	# -[UIViewAnimationState _allowsUserInteraction] 0x3307B220). A drag moves
	# the MODEL offset, and the bounds animation -- a CABasicAnimation with
	# only a fromValue (UIKit 0x32F34998) -- runs from 1120 toward whatever
	# the model now is: drawn = 1120 + (model - 1120) * curve(t).
	# (The port used to refuse touches for the whole 2 s, an inferred
	# lockout the phone's UIKit does not have.)
	var tw := create_tween()
	tw.tween_method(func(t: float) -> void:
		var c := UIScrollSim.curve(t)
		_place_strip(true, lerpf(ENTER_OFFSET, _cup_ph.get_offset().x, c))
		_place_strip(false, lerpf(ENTER_OFFSET, _shape_ph.get_offset().x, c)),
		0.0, 1.0, ENTER_SECONDS)
	tw.tween_callback(func() -> void:
		_entering = false
		_place_strip(true, _cup_ph.get_offset().x)
		_place_strip(false, _shape_ph.get_offset().x))

	get_tree().create_timer(NEXT_DELAY).timeout.connect(_show_next)


## Nav keeps this controller alive under scPourSyrup, as
## the UINavigationController does. Everything on_enter builds comes from
## viewDidLoad (0x75454: initCupsAndShapes, the badge, the 3 s
## showNextButton), so a return shows the strips on the pages they were
## left on with next still up.
func keeps_state_on_push() -> bool:
	return true


## viewWillAppear: (0x75778) -> screenSetup (0x75840): with everything
## unlocked it only removes the tag-1000 lock views and runs reloadLocks
## (0x76B7C), which hides the rest -- the port never builds the locks, so
## there is nothing to show or hide. No changeInstruction:, no timers.
func on_resume() -> void:
	pass


## The class has no viewWillDisappear: / viewDidDisappear:. A strip still
## decelerating when next was tapped keeps going while covered (UIScrollView
## drives it from the run loop) and has settled on its page by the time the
## screen is seen again. INFERRED: settle it here, rather than let the decay
## resume on return.
func on_exit() -> void:
	if _dragging:
		(_cup_ph if _drag_cups else _shape_ph).touch_cancelled()
	_dragging = false
	for ph: UIKit.ScrollPhysics in [_shape_ph, _cup_ph]:
		if ph != null:
			ph.finish()


## viewDidLoad: the ConsumableButton, and initWithNibName:'s Consumable.
func _build_mystery() -> void:
	_mystery = ConsumableScript.new(MYSTERY_KEY, MYSTERY_NAME, MYSTERY_COST)
	_mystery.set("first_time_message", MYSTERY_MESSAGE)
	_mystery.set("on_purchased", _on_mystery_purchased)
	_mystery.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyMysterySelect"
	b.call("setup", MYSTERY_ART, 0, -25, MYSTERY_COST, 65, 3)
	b.position = MYSTERY_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyMysterySelectClick)
	add_child(b)
	_mystery_button = b


func _on_buyMysterySelectClick() -> void:
	if _locked:
		return
	Audio.play("store")
	_mystery.call("purchase", self)


## consumablePurchased: (0x766E4): a fresh shape and a fresh cup.
func _on_mystery_purchased(_free: bool) -> void:
	var shape := _shape_index
	while shape == _shape_index:
		shape = randi() % (SHAPE_COUNT - 1) + 1
	var cup := _cup_index
	while cup == _cup_index:
		cup = randi() % (CUP_COUNT - 1) + 1
	_locked = true
	if _dragging:
		(_cup_ph if _drag_cups else _shape_ph).touch_cancelled()
	_dragging = false
	# setContentOffset:(frame.width * i, contentOffset.y) animated:YES on
	# both: UIScrollView's own 0.3 s scroll animation; scrollViewDidScroll:
	# re-derives the indices as it runs, ending on shape / cup.
	_shape_ph.set_content_offset(Vector2(SHAPE_FRAME.size.x * shape,
		_shape_ph.get_offset().y), true)
	_cup_ph.set_content_offset(Vector2(CUP_FRAME.size.x * cup,
		_cup_ph.get_offset().y), true)
	get_tree().create_timer(MYSTERY_LOCKOUT).timeout.connect(func() -> void:
		_locked = false)


func _build_strips() -> void:
	# Strips sit where the two code-built scroll views sat. Behind the nib
	# chrome buttons, in front of the background: insert after bg (index 1).
	_shape_strip = Node2D.new()
	add_child(_shape_strip)
	move_child(_shape_strip, 1)
	_cup_strip = Node2D.new()
	_cup_strip.position = Vector2(0, CUP_STRIP_Y)
	add_child(_cup_strip)
	move_child(_cup_strip, 2)

	var ice := _tex("sc_background_ice_solid.png")
	var white: Texture2D = null
	if ice != null:
		var img := Image.create_empty(int(ice.get_size().x),
			int(ice.get_size().y), false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		white = ImageTexture.create_from_image(img)

	for i in SHAPE_COUNT:
		var mask := _tex("sc_ice_mask_%d.png" % (i + 1))
		var center := Vector2(ITEM_X0 + PAGE * i, SHAPE_Y)
		var thumb: Sprite2D = MaskedSprite.new()
		thumb.texture = ice
		thumb.set("mask", mask)
		thumb.set("mask_mode", MaskedSprite.detect_mask_mode(mask))
		# applyMaskToImage:mask: (0x75B24) clips in a UIGraphicsBeginImageContext
		# without flipping the CTM, so the shape shows upside down relative to
		# the file -- the dome the phone shows (same as scPourSyrup's columns).
		thumb.set("mask_flip_v", true)
		thumb.position = center
		_shape_strip.add_child(thumb)
		if white != null:
			var wash: Sprite2D = MaskedSprite.new()
			wash.texture = white
			wash.set("mask", mask)
			wash.set("mask_mode", MaskedSprite.detect_mask_mode(mask))
			wash.set("mask_flip_v", true)
			wash.modulate = Color(1, 1, 1, WASH_ALPHA)
			wash.position = center
			_shape_strip.add_child(wash)

	for i in CUP_COUNT:
		var art := _tex("sc_cup%d.png" % (i + 1))
		if art == null:
			continue
		var cup := Sprite2D.new()
		cup.texture = art
		cup.scale = CUP_SIZE / art.get_size()
		cup.position = Vector2(ITEM_X0 + PAGE * i, CUP_Y)
		_cup_strip.add_child(cup)

	_shape_ph = _make_physics(SHAPE_FRAME, SHAPE_COUNT, false)
	_cup_ph = _make_physics(CUP_FRAME, CUP_COUNT, true)


## One code-built UIScrollView: initWithFrame:, setContentSize:(320 * n,
## frame height), setShowsHorizontalScrollIndicator:NO, delegate self.
func _make_physics(frame: Rect2, count: int, cups: bool) -> UIKit.ScrollPhysics:
	var ph := UIKit.ScrollPhysics.new(frame.size, Vector2(PAGE * count, frame.size.y))
	ph.name = "CupScroll" if cups else "ShapeScroll"
	ph.shows_horizontal = false
	ph.h.set("will_end_dragging", _will_end_dragging)
	ph.scrolled.connect(func(o: Vector2) -> void: _apply_offset(cups, o.x))
	add_child(ph)
	return ph


## scrollViewDidScroll: (0x779BC): the current index is re-derived from
## every new offset. While the entrance glide runs, the drawn bounds are the
## glide's, not the model's (see on_enter).
func _apply_offset(cups: bool, offset: float) -> void:
	if cups:
		_cup_offset = offset
		_cup_index = _index_for(offset)
	else:
		_shape_offset = offset
		_shape_index = _index_for(offset)
	if not _entering:
		_place_strip(cups, offset)


func _place_strip(cups: bool, offset: float) -> void:
	(_cup_strip if cups else _shape_strip).position.x = -offset


## No changeInstruction: call exists on this screen, so undo the generic
## first-appearance slide Screen._place_instruction started: the banner just
## sits at its nib spot.
func _park_instruction() -> void:
	if _instruction_tween != null and _instruction_tween.is_valid():
		_instruction_tween.kill()
	var inst := _instruction_node()
	if inst != null and _instruction_home_set:
		inst.position = _instruction_home
		inst.visible = true



## scrollViewDidScroll (0x779BC): r = (int)x % 320 (C remainder, so
## negative past the left edge); r > 160 becomes r - 320; index =
## (int)(x - r) / 320.
func _index_for(offset: float) -> int:
	var r := float(int(offset) % int(PAGE))
	if r > SNAP_HALF:
		r -= PAGE
	return int(offset - r) / int(PAGE)


## scrollViewWillEndDragging:withVelocity:targetContentOffset: (0x77B10):
## the same rounding applied to the proposed target's x -- the fraction of
## the float survives, as in the original (target.x - (float)r).
func _will_end_dragging(_velocity: float, proposed: float) -> float:
	var r := float(int(proposed) % int(PAGE))
	if r > SNAP_HALF:
		r -= PAGE
	return proposed - r


## A press on a strip is that UIScrollView's (a touch also stops it if it
## is still gliding -- UIKit.ScrollPhysics). Moves and the release go
## through _input so the drag keeps tracking over the nib's buttons.
func _unhandled_input(event: InputEvent) -> void:
	if _locked:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	# The two scroll views split the screen at y 237; in the 13px overlap
	# the cup strip wins, as the later-added subview did.
	if mb.position.y >= CUP_STRIP_Y:
		_drag_cups = true
	elif mb.position.y < SHAPE_FRAME.end.y:
		_drag_cups = false
	else:
		return
	_dragging = true
	(_cup_ph if _drag_cups else _shape_ph).touch_began(mb.position)


func _input(event: InputEvent) -> void:
	if not _dragging:
		return
	var ph := _cup_ph if _drag_cups else _shape_ph
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_dragging = false
			ph.touch_ended(mb.position)
	elif event is InputEventMouseMotion:
		ph.touch_moved((event as InputEventMouseMotion).position)


func _show_next() -> void:
	if is_inside_tree():
		_set_next_visible(true)
		show_next_button()


## nextClick: (0x76D90): with everything unlocked the lock branch is dead;
## the chosen cup and mask file names ride into scPourSyrup's
## initWithCup:iceMask:. GameState has no snow-cone fields yet (it is
## milkshake-shaped), so they travel as metadata on the autoload.
func _on_nextClick() -> void:
	# consumablePurchased: turns the key window's userInteractionEnabled off
	# until enableTouches (0.8 s): no button takes a tap meanwhile, so the
	# 0.3 s mystery snap has always landed before next can push.
	if _locked:
		return
	Audio.play("button_press")
	GameState.set_meta("sc_cup_file", "sc_cup%d.png" % (_cup_index + 1))
	GameState.set_meta("sc_ice_mask_file", "sc_ice_mask_%d.png" % (_shape_index + 1))
	Nav.next()


func _on_backClick() -> void:
	if _locked:
		return                    # key window touches off (see _on_nextClick)
	Audio.play("button_press")
	Nav.back()


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
