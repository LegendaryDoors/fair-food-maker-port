# Candy Apple step 3 -- page through the candy sticks and pick one.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithNibName: 0x1522C8, viewDidLoad 0x152500, viewWillAppear: 0x15282C,
#   screenSetup 0x1528F4, initSticksAndShapes 0x152B28, nextClick: 0x1535FC,
#   scrollViewDidScroll: 0x153B7C,
#   scrollViewWillEndDragging:withVelocity:targetContentOffset: 0x153C34,
#   showNextButton 0x153A18, changeInstruction: 0x153810 (never called here).
#
# Mechanic, as read: the 20 sticks of the bundled CandyAppleSticks.plist
# (CandyStick16 does not exist; the list really skips it) each get a page
# of a code-built UIScrollView, frame
# (0,70,320,350) with clipsToBounds NO: one 117x325 stick centred at
# (160 + 320*i, 170). contentSize (320*count, 180). On entry the offset
# jumps past the end to 320*count and animates back to 0 over 2.0s; the
# next button is hidden and re-shown by a plain 3.0s performSelector delay
# (0x40080000 00000000), not by any selection.
#
# The selection is implicit: scrollViewDidScroll keeps
# currentStickIndex = round(offset/320) (via the mod-160 integer walk) and
# scrollViewWillEndDragging snaps the target offset to the nearest page --
# this screen genuinely pages, unlike StandSelect whose snap was dead code.
# nextClick stores sticks[currentStickIndex] under infoDict["Stick"].
#
# SCROLLING: stickScrollView is a real UIScrollView now
# (kcScrollView.gd over core/UIScrollSim.gd): 10 pt drag hysteresis,
# release velocity, deceleration 0.998, rubber band and bounce at both ends,
# and scrollViewWillEndDragging: (0x153C34) folding UIKit's PROPOSED resting
# offset onto the nearest page -- a flick glides several pages and lands on
# one; a slow release creeps to the nearer page (ScrollAxis.aim_at_target).
# The old 0.3 s ease-out snap tween and its clamp are gone. Nothing sets
# bounces, decelerationRate or paging; the horizontal indicator is off
# (set twice) and the vertical one can never show (contentSize height 180
# inside the 350 frame). The entrance is setContentOffset:animated:NO to 0
# inside a 2.0 s +beginAnimations: block (0x152B28): the model is at page 0 at
# once, only the drawing glides (EaseInOut), and touches stay live during
# it. The mystery pick's setContentOffset:animated:YES (0x1530E4) is UIKit's own
# 0.3 s sin^2 UIScrollAnimation, scrollViewDidScroll: (0x153B7C) on every step.
#
# Not ported (IAP, everything unlocked): reloadLocks 0x153474 and the
# round_black_lock overlays (tag 2000+i, hidden when unlocked), and the
# "Oops" store alert in nextClick (0x153664). (The mystery-stick consumable
# IS ported -- see the block below.)

extends "res://core/Screen.gd"

const ScrollView := preload("res://screens/kcScrollView.gd")

## The import cache's data/CandyAppleSticks.json (Assets).
const STICKS_JSON := "CandyAppleSticks"

## initSticksAndShapes (0x152B28): scroll frame (0,70,320,350)
## (0x428C0000 / 0x43A00000 / 0x43AF0000), clipsToBounds NO; stick centres
## (160 + 320*i, 170) (0x432A0000); page pitch 320.
const STRIP_POS := Vector2(0, 70)
const PAGE_W := 320.0
const STICK_CY := 170.0
## Entrance: offset 320*count -> 0 over 2.0s ("Animate_To_First_Item").
const ENTRANCE_SECONDS := 2.0
## showNextButton fires on a 3.0s performSelector delay.
const NEXT_DELAY := 3.0

var _sticks: Array = []
var _strip: Node2D
var _index := 0            # currentStickIndex
var _sv: Node             # kcScrollView (stickScrollView)

## Mystery selection (PORTED, same shape as ccbSelectStick):
##   initWithNibName: 0x1522C8  Consumable DM_CONSUMABLE_MYSTERY_SELECT /
##     MysterySelect_30Stick, cost = GameData.CoinCosts."Candy Apple".
##     MysteryStick, 6 when absent (the server is gone); first-time message.
##   viewDidLoad 0x152500  ConsumableButton(btn_mystery_selection, offsets
##     (0,-25) / (65,3)) at centre (50, 350.5); buyMysterySelectClick: on
##     touch-up; buyAllBtn hidden.
##   buyMysterySelectClick: 0x153520  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x1530E4  quantity 0, reloadLocks (0x153474, all
##     hidden with everything unlocked), window touches off, pick
##     i = arc4random() % (count-1) + 1 until i != currentStickIndex (never
##     page 0), setContentOffset:(320*i) animated, unhide lock tag 2001+i,
##     enableTouches (0x153358) after 0.8 s.
##   consumablePurchaseFailed:error:2 0x1533A0  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_SELECT"
const MYSTERY_NAME := "MysterySelect_30Stick"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery selection! You never know what selection it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_selection.png"
const MYSTERY_CENTER := Vector2(50, 350.5)
const MYSTERY_LOCKOUT := 0.8

var _mystery: RefCounted
var _mystery_button: TextureButton
var _locked := false      # keyWindow userInteractionEnabled NO
## infoDict: the one mutable dictionary every Candy Apple step shares
## (setInfoDict: hands the same object on). Held here so a return to this
## screen still has it after a later step replaced the global carrier.
var _info: Dictionary = {}


func on_enter() -> void:
	_info = GameState.custom_categories
	_sticks = _load_sticks()
	_build_strip()
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	# initSticksAndShapes: bringSubviewToFront instIV, backButton, nextButton
	# -- the strip (added to the view first) stays under the chrome.
	for oname: String in ["instIV", "backButton", "nextButton"]:
		var o := outlet(oname)
		if o != null and o != self:
			move_child(o as Node, get_child_count() - 1)
	# performSelector:@"showNextButton" afterDelay:3.0.
	get_tree().create_timer(NEXT_DELAY).timeout.connect(func() -> void:
		if is_inside_tree():
			show_next_button())
	# No screenSetup back-lockout and no changeInstruction on this screen.
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


## consumablePurchased: (0x1530E4).
func _on_mystery_purchased(_free: bool) -> void:
	_mystery.set("quantity", 0)
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
	push_warning("caSelectStick: CandyAppleSticks table not found")
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


## scrollViewDidScroll: (0x153B7C) -- the exact integer walk: m = off % 320,
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


## nextClick: (0x1535FC): button_press, infoDict["Stick"] = the current
## page's art, push a NEW caInsertStick with the same infoDict.
func _on_nextClick() -> void:
	Audio.play("button_press")
	if _index >= 0 and _index < _sticks.size():
		_info["Stick"] = str(_sticks[_index])
	GameState.custom_categories = _info
	Nav.next()


## UINavigationController keeps this controller alive under caInsertStick
## (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from caInsertStick: viewWillAppear: (0x15282C) -> screenSetup
## (0x1528F4) only re-checks the IAP keys and removes tag >= 2000 lock
## overlays (none: everything unlocked) -- the page, the shown next button
## and the banner stay as they were left. There is no viewDidAppear: and no
## viewWillDisappear: (so no on_exit work).
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


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true


## Nothing on this screen calls changeInstruction: (viewDidLoad 0x152500,
## viewWillAppear: 0x15282C, initSticksAndShapes 0x152B28 -- 0x153810 has no
## caller here), so the nib's inst_select_candyStick banner simply sits at
## its home. Screen._place_instruction would slide it in from +500 like a
## changeInstruction: call; record the home without the slide instead.
func _place_instruction() -> void:
	var item := _instruction_node()
	if item == null:
		return
	_instruction_home = item.position
	_instruction_home_set = true


## backClick: (0x15358C): button_press, then pop. Screen's default pops
## silently, so every original back press was missing its click.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()
