# Chocolate Covered Banana step 2 -- page through the sticks and pick one.
#
# From the original binary (entry points from the ObjC method list):
#   initWithNibName: 0x132C38 (fresh sticks array + fresh infoDict -- the
#   ccb carrier is BORN here; the peel screen contributes nothing),
#   viewDidLoad 0x132E98, viewWillAppear: 0x133154,
#   initSticksAndShapes 0x1333AC, nextClick: 0x133E80,
#   changeInstruction: 0x1340A8 (never called -- the nib art stands),
#   showNextButton 0x1342B0, scrollViewDidScroll: 0x134414,
#   scrollViewWillEndDragging:withVelocity:targetContentOffset: 0x1344CC,
#   backClick: 0x133E10.
#   A full re-read decoded the delays from their double halves
#   (showNextButton 3.0 s, enableTouches 0.8 s) and found only backClick:'s
#   button_press missing.
#
# Mechanic, as read: the 20 sticks of the bundled
# ChocoDippedBananaSticks.plist (BC_Stick_1..20, no gaps, unlike Candy
# Apple's list, which skips 16) each get a page of a code-built
# UIScrollView, frame (0,70,320,350)
# (0x428C0000/0x43A00000/0x43AF0000) with clipsToBounds NO: one 39x271 stick
# centred at (160 + 320*i, 170) (0x432A0000). contentSize (320*count, 180)
# (0x43340000). On entry the offset jumps to 320*count and animates back to
# 0 over 2.0s ("Animate_To_First_Item"); showNextButton runs on a plain 3.0s
# performSelector delay (double 0x4008000000000000).
#
# scrollViewDidScroll: keeps currentStickIndex via the mod-320 integer walk
# and scrollViewWillEndDragging: folds the target offset to the nearest
# page. Same geometry as caSelectStick (0x152B28/0x153B7C/0x153C34) to the
# digit, verified independently here -- only the stick table differs.
#
# nextClick: (0x133E80) stores sticks[currentStickIndex] under
# infoDict["Stick"] and pushes ccbInsertStick with that dict.
#
# SCROLLING: stickScrollView is a real UIScrollView now
# (kcScrollView.gd over core/UIScrollSim.gd): 10 pt drag hysteresis,
# release velocity, deceleration 0.998, rubber band and bounce at both ends,
# and scrollViewWillEndDragging: (0x1344CC) folding UIKit's PROPOSED resting
# offset onto the nearest page -- a flick glides several pages and lands on
# one; a slow release creeps to the nearer page (ScrollAxis.aim_at_target).
# The old 0.3 s ease-out snap tween and its clamp are gone. Nothing sets
# bounces, decelerationRate or paging; the horizontal indicator is off
# (set twice) and the vertical one can never show (contentSize height 180
# inside the 350 frame). The entrance is setContentOffset:animated:NO to 0
# inside a 2.0 s +beginAnimations: block (0x1333AC): the model is at page 0 at
# once, only the drawing glides (EaseInOut), and touches stay live during
# it. The mystery pick's setContentOffset:animated:YES (0x133968) is UIKit's own
# 0.3 s sin^2 UIScrollAnimation, scrollViewDidScroll: (0x134414) on every step.
#
# Mystery selection (ported; the original shows it on the phone):
#   initWithNibName: 0x132C38  Consumable key DM_CONSUMABLE_MYSTERY_SELECT,
#     name MysterySelect_20Stick, cost = server table
#     GameData.CoinCosts."Chocolate Dipped Banana".MysteryStick, 6 when
#     absent (the server is gone, so 6); first-time message "Try out a
#     mystery selection! ...".
#   viewDidLoad 0x132E98  ConsumableButton(btn_IAP_background, btn_IAP_mask,
#     btn_mystery_selection, btn_IAP_border, btn_IAP_lable, label offset
#     (0,-25), cost, cost offset (65,3)), centre (50, 350.5),
#     buyMysterySelectClick: on touch-up.
#   buyMysterySelectClick: 0x133DA4  "store" sound, purchaseConsumable.
#   consumablePurchased: 0x133968  quantity 0, reloadLocks, window touches
#     off, pick i = arc4random() % (count-1) + 1 until i != current (never
#     page 0), setContentOffset:(320*i) animated, unhide lock tag 2001+i,
#     enableTouches after 0.8 s.
#   consumablePurchaseFailed:error:2 0x133C24  alert "You do not have enough
#     coins."
# Still not ported: reloadLocks' round_black_lock overlays (everything is
# unlocked, so they are always hidden) and the "Oops" store alert in
# nextClick (0x133EA6).

extends "res://core/Screen.gd"

const ScrollView := preload("res://screens/kcScrollView.gd")

## The import cache's data/ChocoDippedBananaSticks.json (Assets).
const STICKS_JSON := "ChocoDippedBananaSticks"

## initSticksAndShapes (0x1333AC): scroll frame (0,70,320,350), clips NO;
## stick centres (160 + 320*i, 170); page pitch 320; content height 180.
const STRIP_POS := Vector2(0, 70)
const STRIP_SIZE := Vector2(320, 350)
const PAGE_W := 320.0
const STICK_CY := 170.0
## Entrance: offset 320*count -> 0 over 2.0s ("Animate_To_First_Item").
const ENTRANCE_SECONDS := 2.0
## showNextButton on a 3.0s performSelector delay (initSticksAndShapes tail).
const NEXT_DELAY := 3.0

## Mystery selection (see header).
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_SELECT"
const MYSTERY_NAME := "MysterySelect_20Stick"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery selection! You never know what selection it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_selection.png"
const MYSTERY_CENTER := Vector2(50, 350.5)
const MYSTERY_LOCKOUT := 0.8

const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")

var _mystery: RefCounted
var _mystery_button: TextureButton
var _locked := false      # keyWindow userInteractionEnabled NO

var _sticks: Array = []
var _strip: Node2D
var _index := 0            # currentStickIndex
var _sv: Node             # kcScrollView (stickScrollView)
## infoDict: created ONCE by initWithNibName: (0x132C38) and handed to every
## later ccb step by reference (setInfoDict:); nextClick: writes Stick into
## it. Kept here so a return to this screen pushes the same dictionary.
var _info: Dictionary = {}


func on_enter() -> void:
	_info = {}                 # initWithNibName: [[NSMutableDictionary alloc] init]
	_sticks = _load_sticks()
	_build_strip()
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	# performSelector:@"showNextButton" afterDelay:3.0.
	get_tree().create_timer(NEXT_DELAY).timeout.connect(func() -> void:
		if is_inside_tree():
			show_next_button())
	_build_mystery()


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


## consumablePurchased: (0x133968).
func _on_mystery_purchased(_free: bool) -> void:
	var count := _sticks.size()
	if count < 2:
		return
	var pick := _index
	while pick == _index:
		pick = randi() % (count - 1) + 1
	_locked = true
	_sv.call("cancel_tracking")
	# setContentOffset:(frame.width * pick, offset.y) animated:YES.
	_sv.call("set_offset_animated", PAGE_W * pick)
	get_tree().create_timer(MYSTERY_LOCKOUT).timeout.connect(func() -> void:
		_locked = false)


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _load_sticks() -> Array:
	var parsed: Variant = Assets.json(STICKS_JSON)
	if parsed is Array:
		return parsed
	push_warning("ccbSelectStick: ChocoDippedBananaSticks table not found")
	return []


func _build_strip() -> void:
	# clipsToBounds NO in the original -- no clipping container.
	_strip = Node2D.new()
	_strip.position = STRIP_POS
	add_child(_strip)
	for i in _sticks.size():
		var t := _tex(str(_sticks[i]))
		if t == null:
			continue
		var s := Sprite2D.new()
		s.texture = t
		s.position = Vector2(160.0 + PAGE_W * i, STICK_CY)
		_strip.add_child(s)
	# instIV / back / next brought to the front over the code-built strip.
	for oname in ["instIV", "backButton", "nextButton"]:
		var o := outlet(oname)
		if o != null and o != self:
			move_child(o as Node, get_child_count() - 1)
	# contentSize (320 * count, 180); setShowsHorizontalScrollIndicator:NO.
	_sv = ScrollView.new()
	_sv.name = "stickScrollViewSim"
	add_child(_sv)
	_sv.call("configure", false, Rect2(STRIP_POS, Vector2(320, 350)),
		PAGE_W * _sticks.size())
	_sv.set("content_origin", STRIP_POS)
	_sv.set("content", _strip)
	var axis: RefCounted = _sv.get("axis")
	axis.set("will_end_dragging", func(_v: float, proposed: float) -> float:
		return will_end_dragging(proposed))
	_sv.connect("did_scroll", _did_scroll)
	# "Animate_To_First_Item": setContentOffset:(320 * count, 0), then
	# setContentOffset:animated:NO to 0 inside the 2.0 s block.
	_sv.call("set_offset", PAGE_W * _sticks.size())
	_sv.call("set_offset_in_animation_block", 0.0, ENTRANCE_SECONDS)


## scrollViewDidScroll: (0x134414) -- the exact integer walk: m = off % 320,
## fold past the halfway point, index = (off - m) / 320.
func _did_scroll(offset: float) -> void:
	var m := int(offset) % 320
	var mf := float(m)
	if mf > 160.0:
		mf = mf - PAGE_W
	_index = int((offset - mf) / PAGE_W)


## scrollViewWillEndDragging:withVelocity:targetContentOffset: -- the same
## fold applied to targetContentOffset->x: onto the nearest 320 multiple.
static func will_end_dragging(proposed: float) -> float:
	var m := int(proposed) % 320
	var mf := float(m)
	if mf > 160.0:
		mf = mf - PAGE_W
	return proposed - mf


## The scroll view's frame (0,70,320,350) takes the touches (window
## interaction is off while a mystery pick scrolls).
func _unhandled_input(event: InputEvent) -> void:
	if _locked or _sv == null:
		return
	if _sv.call("handle_input", event):
		get_viewport().set_input_as_handled()


## nextClick: (0x133E80): button_press, this controller's infoDict
## (initWithNibName: 0x132C38 creates it; nothing earlier in the ccb flow
## writes the carrier) gets ["Stick"], push a NEW ccbInsertStick with it.
func _on_nextClick() -> void:
	Audio.play("button_press")
	if _index >= 0 and _index < _sticks.size():
		_info["Stick"] = str(_sticks[_index])
	GameState.custom_categories = _info
	Nav.next()


## UINavigationController keeps this controller alive under ccbInsertStick
## (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from ccbInsertStick: viewWillAppear: (0x133154) only re-checks the
## IAP keys and removes tag >= 2000 lock overlays (none: everything
## unlocked); the page and the shown next button stay as they were left.
## No viewDidAppear:, no viewWillDisappear: (no on_exit work).
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		# CoinHUD re-adds the panel after this; drop the first appearance's.
		remove_child(old)
		old.queue_free()
	if _sv != null:
		_sv.call("cancel_tracking")


## Covered by the next step (kept alive): UIKit would finish a glide in
## flight meanwhile; the port's node stops processing out of the tree.
func on_exit() -> void:
	if _sv != null:
		_sv.call("settle")


## backClick: (0x133E10): button_press, pop. Screen's default pops without
## the sound.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
