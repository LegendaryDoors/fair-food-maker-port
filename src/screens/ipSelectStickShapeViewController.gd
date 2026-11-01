# Ice Pop step 1 -- pick a stick and a mold shape, one page at a time.
#
# GROUNDED from the binary (disassembly at the ObjC method list's IMPs):
#   viewDidLoad 0xFC9CC, initSticksAndShapes 0xFD424, viewWillAppear: 0xFCE2C,
#   screenSetup 0xFCEF4, scrollViewDidScroll: 0xFF190,
#   scrollViewWillEndDragging:withVelocity:targetContentOffset: 0xFF2E4,
#   nextClick: 0xFE4B8, showNextButton 0xFF02C, changeInstruction: 0xFEE24.
#
# initSticksAndShapes builds two paging UIScrollViews in code (the nib holds
# only chrome):
#   sticks  frame (0,300,320,180) -- 17 items, "Stick_%d.png"        1..17
#   shapes  frame (0,0,320,300)   -- 22 items, "FP_Pop_Shape_%d.png" 1..22
#           (contentSize height 250; the FRAME, which bounds hit testing, is
#           300 tall; initSticksAndShapes 0xFD424)
# One item per 320px page at x = 160 + 320*i. A stick is a UIImageView given
# an explicit (0,0,40,273) frame and centre (x, 25) in strip coords; a shape
# is a self-sizing UIImageView centred at (x, 190). Both scroll views have
# clipsToBounds NO, so the 273px stick art overflows its 180px strip freely.
# Content offset parks at 1120 (0x44900000, page 3.5) and animates to page 0
# over 2.0s; showNextButton fires 3.0s in (performSelector:afterDelay:, double
# 0x40080000...) with the next button hidden until then.
#
# NOTE: this is the ip food's own picker -- it shares nothing with the
# StickSelectViewController wheel.
#
# SCROLLING: both strips are real UIScrollViews
# (kcScrollView.gd over core/UIScrollSim.gd): finger drag with the 10 pt
# hysteresis, release velocity, deceleration 0.998, bounce at the ends, and
# scrollViewWillEndDragging:withVelocity:targetContentOffset: (0xFF2E4)
# folding UIKit's PROPOSED resting offset onto the nearest page -- so a
# flick glides several pages and lands on one, a slow release creeps to the
# nearer page. The old 0.3 s ease-out snap tween and its clamp are gone.
# Neither scroll view sets bounces, decelerationRate or paging, so the
# defaults hold; both turn the horizontal indicator off (the shape one the
# vertical too, which could never show anyway: contentSize heights 180 /
# 250 do not exceed the 180 / 300 frames). The entrance is a
# setContentOffset: inside a 2.0 s +beginAnimations: block -- the model is
# at page 0 at once (scrollViewDidScroll: says so) and only the drawing
# glides; old-style blocks leave touches on (kcScrollView.gd header), so
# the port no longer locks drags out for those 2 s (the old INFERRED lock
# was wrong). The mystery pick's setContentOffset:animated:YES is UIKit's
# 0.3 s sin^2 UIScrollAnimation.
#
# The IAP lock overlays (round_black_lock, tags 1000+/2000+) are all hidden
# with everything unlocked (screenSetup 0xFCEF4 removes them outright), so the
# port does not build them. This screen's nib has no skipButton despite the
# ivar.

extends "res://core/Screen.gd"

## Keep-state helpers (track / settle / drop_coin_panel) shared by the kc
## and ip screens -- see the last block of kcKit.gd.
const kcKit := preload("res://screens/kcKit.gd")
const ScrollView := preload("res://screens/kcScrollView.gd")

const STICK_COUNT := 17                  # loop bound 23 exclusive... see below
const SHAPE_COUNT := 22                  # "FP_Pop_Shape_%d" for 1..22 (bound 23)
# STICK loop runs 1..17 (bound 18 at 0xFD46C); SHAPE loop 1..22 (bound 23).
const PAGE := 320.0                      # item pitch
const ITEM_X0 := 160.0                   # first centre
const STICK_STRIP_Y := 300.0             # 0x43960000 in initWithFrame:
## shapeScrollView initWithFrame:(0,0,320,300) -- its frame height, not the
## 250 contentSize height, decides which strip a touch lands in.
const SHAPE_STRIP_H := 300.0
const STICK_Y := 25.0                    # 0x41C80000, strip-local centre
const SHAPE_Y := 190.0                   # 0x433E0000
const ENTER_OFFSET := 1120.0             # 0x44900000
const ENTER_SECONDS := 2.0               # double 0x40000000 high word
const NEXT_DELAY := 3.0                  # double 0x40080000 high word
## willEndDragging (0xFF2E4): remainder > 160 rounds up to the next 320
## boundary, otherwise down.
const SNAP_HALF := 160.0
## The two code-built scroll views (initSticksAndShapes 0xFD424).
const STICK_FRAME := Rect2(0, 300, 320, 180)
const SHAPE_FRAME := Rect2(0, 0, 320, 300)

var _stick_strip: Node2D
var _shape_strip: Node2D
var _stick_index := 0
var _shape_index := 0
## stickScrollView / shapeScrollView.
var _stick_sv: Node
var _shape_sv: Node

## Mystery selection (ported):
##   initWithNibName: 0xFC778  Consumable DM_CONSUMABLE_MYSTERY_SELECT /
##     MysterySelect_10Shape, cost = CoinCosts."QuickFreeze Ice Pops".
##     MysteryShape, 6 when absent; first-time message.
##   viewDidLoad 0xFC9CC  ConsumableButton(btn_mystery_selection, (0,-25) /
##     (65,3)) at centre (50, 350.5); buyMysterySelectClick:; buyAllBtn hidden.
##   buyMysterySelectClick: 0xFE3DC  "store" sound, purchaseConsumable.
##   consumablePurchased: 0xFDDBC  quantity 0, reloadLocks (0xFE254), window
##     touches off; shape s = arc4random() % (shapes-1) + 1 until
##     s != currentShapeIndex, then stick t = arc4random() % (sticks-1) + 1
##     until t != currentStickIndex (neither ever page 0); both scroll views
##     setContentOffset:(320*i) animated; lock tags 1001+s / 2000+t hidden;
##     enableTouches (0xFE138) after 0.8 s.
##   consumablePurchaseFailed:error:2 0xFE180  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_SELECT"
const MYSTERY_NAME := "MysterySelect_10Shape"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery selection! You never know what selection it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_selection.png"
const MYSTERY_CENTER := Vector2(50, 350.5)
const MYSTERY_LOCKOUT := 0.8

var _mystery: RefCounted
var _mystery_button: TextureButton
var _locked := false      # keyWindow userInteractionEnabled NO
## Every tween this screen starts (kcKit.track / settle, keep-state).
var _tweens: Array = []
## showNextButton fired while a pushed screen covered this one (the 3.0s
## performSelector runs regardless); on_resume shows its end state.
var _next_pending := false


func on_enter() -> void:
	GameState.begin("ip")
	_build_strips()
	_build_mystery()
	# No changeInstruction: call anywhere on this screen: instIV keeps its nib
	# art (Screen._ready already ran the shared first-appearance slide).
	_set_next_visible(false)

	# "Animate_To_First_Item": setContentOffset:(1120,0) on both, then
	# setContentOffset:animated:NO to 0 inside a 2.0 s block (default
	# curve, EaseInOut).
	for sv: Node in [_stick_sv, _shape_sv]:
		sv.call("set_offset", ENTER_OFFSET)
		sv.call("set_offset_in_animation_block", 0.0, ENTER_SECONDS)

	get_tree().create_timer(NEXT_DELAY).timeout.connect(_show_next)


## UINavigationController keeps this controller under ipFlavor (and under
## the coin store): back shows the strips exactly where they were left.
func keeps_state_on_push() -> bool:
	return true


## viewWillAppear: (0xFCE2C) -> screenSetup (0xFCEF4), which only strips the
## IAP lock overlays (never built in the port). No viewWillDisappear: /
## viewDidAppear: exist in this class.
func on_resume() -> void:
	kcKit.drop_coin_panel(self)
	if _next_pending:
		_next_pending = false
		# The slide ran to its end while covered: instIV hidden, next home.
		dismiss_instruction()
		_set_next_visible(true)


## No viewWillDisappear: here; only the port's paused tweens need settling
## (the entry glide, a snap, a mystery scroll -- UIKit finishes them while
## covered).
func on_exit() -> void:
	kcKit.settle(_tweens)
	for sv: Node in [_stick_sv, _shape_sv]:
		if sv != null:
			sv.call("settle")


func _tween() -> Tween:
	return kcKit.track(_tweens, create_tween())


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


## consumablePurchased: (0xFDDBC): a fresh shape and a fresh stick.
func _on_mystery_purchased(_free: bool) -> void:
	var shape := _shape_index
	while shape == _shape_index:
		shape = randi() % (SHAPE_COUNT - 1) + 1
	var stick := _stick_index
	while stick == _stick_index:
		stick = randi() % (STICK_COUNT - 1) + 1
	_locked = true
	for sv: Node in [_stick_sv, _shape_sv]:
		sv.call("cancel_tracking")
	# setContentOffset:(frame.width * i, current y) animated:YES on both --
	# UIKit's 0.3 s UIScrollAnimation; scrollViewDidScroll: on every step
	# moves the indices along.
	_shape_sv.call("set_offset_animated", PAGE * shape)
	_stick_sv.call("set_offset_animated", PAGE * stick)
	get_tree().create_timer(MYSTERY_LOCKOUT).timeout.connect(func() -> void:
		_locked = false)


func _build_strips() -> void:
	# The strips sit where the code-built scroll views sat: in front of the
	# background, behind the nib chrome. Shapes were added second in the
	# original, so they draw above the sticks.
	_stick_strip = Node2D.new()
	_stick_strip.position = Vector2(0, STICK_STRIP_Y)
	add_child(_stick_strip)
	move_child(_stick_strip, 1)
	_shape_strip = Node2D.new()
	add_child(_shape_strip)
	move_child(_shape_strip, 2)

	for i in STICK_COUNT:
		var art := _tex("Stick_%d.png" % (i + 1))
		if art == null:
			continue
		var stick := Sprite2D.new()
		stick.texture = art
		# Explicit (0,0,40,273) frame; the art is 40x273, so natural size.
		stick.position = Vector2(ITEM_X0 + PAGE * i, STICK_Y)
		_stick_strip.add_child(stick)

	for i in SHAPE_COUNT:
		var art := _tex("FP_Pop_Shape_%d.png" % (i + 1))
		if art == null:
			continue
		var shape := Sprite2D.new()
		shape.texture = art
		shape.position = Vector2(ITEM_X0 + PAGE * i, SHAPE_Y)
		_shape_strip.add_child(shape)

	# contentSize (320 * count, 180) and (320 * count, 250); horizontal
	# indicators off, clipsToBounds NO (no clip node), no other settings.
	_stick_sv = _make_scroll_view(STICK_FRAME, PAGE * STICK_COUNT, _stick_strip, true)
	_shape_sv = _make_scroll_view(SHAPE_FRAME, PAGE * SHAPE_COUNT, _shape_strip, false)


func _make_scroll_view(frame: Rect2, content_w: float, strip: Node2D,
		sticks: bool) -> Node:
	var sv: Node = ScrollView.new()
	sv.name = "stickScrollViewSim" if sticks else "shapeScrollViewSim"
	add_child(sv)
	sv.call("configure", false, frame, content_w)
	sv.set("content_origin", frame.position)
	sv.set("content", strip)
	var axis: RefCounted = sv.get("axis")
	axis.set("will_end_dragging", func(_v: float, proposed: float) -> float:
		return _will_end_dragging(proposed))
	sv.connect("did_scroll", func(offset: float) -> void:
		_did_scroll(sticks, offset))
	return sv


## scrollViewDidScroll: (0xFF190): the exact integer walk -- m = (int)x %
## 320, folded to m - 320 past 160; index = (int)(x - m) / 320, both scroll
## views alike.
static func index_for(offset: float) -> int:
	var m := float(int(offset) % 320)
	if m > SNAP_HALF:
		m = m - PAGE
	return int(offset - m) / 320


func _did_scroll(sticks: bool, offset: float) -> void:
	if sticks:
		_stick_index = index_for(offset)
	else:
		_shape_index = index_for(offset)


## scrollViewWillEndDragging:withVelocity:targetContentOffset: (0xFF2E4):
## targetContentOffset.x -= the same fold, i.e. onto the nearest page.
static func _will_end_dragging(proposed: float) -> float:
	var m := float(int(proposed) % 320)
	if m > SNAP_HALF:
		m = m - PAGE
	return proposed - m


func _unhandled_input(event: InputEvent) -> void:
	if _locked:
		return
	# The stick scroll view spans y 300..480, the shape one y 0..300 (frames
	# from initSticksAndShapes); a touch belongs to the one it lands in.
	for sv: Node in [_stick_sv, _shape_sv]:
		if sv != null and sv.call("handle_input", event):
			get_viewport().set_input_as_handled()
			return


func _show_next() -> void:
	if is_inside_tree():
		_set_next_visible(true)
		show_next_button()
	else:
		_next_pending = true


## nextClick: (0xFE4B8): with everything unlocked the alert branch is dead.
## The dict this builds is the original's exact infoDict for
## ipFlavorViewController initWithDictionary: -- stickFileString,
## moldFileString, moldMaskFileString ("FP_Pop_Mask_%d" is index+1) and
## moldIndex (currentShapeIndex as a string). The port carries it as
## GameState metadata; every later ip screen reads and extends "ip_info".
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.set_meta("ip_info", {
		"stickFileString": "Stick_%d.png" % (_stick_index + 1),
		"moldFileString": "FP_Pop_Shape_%d.png" % (_shape_index + 1),
		"moldMaskFileString": "FP_Pop_Mask_%d.png" % (_shape_index + 1),
		"moldIndex": _shape_index,
	})
	Nav.next()


func _on_backClick() -> void:
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
## binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
