# Lemon Shake Up step 2 -- pick a fruit, then drag the knife down through it.
#
# GROUNDED from initFlavors (0x5EB70), flavorClicked: (0x5F2A0),
# viewDidAppear: (0x5E714), splitFruitSequence (0x605D8, literals 0x60B98,
# strings at 0x6BA054..0x6BA0B4), draggableTouchBegan/Moved/Ended
# (0x60BA0 / 0x60C40 / 0x60D08, thresholds at 0x60D00/0x60D04) and
# screenSetup (0x5E9F8).
#
# The knife is a DraggableIV with snapTime 0 -- released, it stays where it
# was left. The cut fires when the knife's centre has been dragged to
# y <= 100 and then back down past y >= 200.
#
# Corrected against the original code: the skip badge is hidden until a
# fruit is picked (viewDidLoad 0x5E1E8 hides it, flavorClicked: shows it);
# the picker lives in the nib's aScrollView slot instead of a top-level
# canvas layer; flavorClicked: brings back/next/instIV above the fruit and
# knife; backClick: (0x5F8E0) plays button_press.
#
# Kept alive under the push.
# viewWillDisappear: (0x5E8F4) / viewDidDisappear: (0x5E948) -> on_exit();
# viewWillAppear: (0x5E64C) / viewDidAppear: (0x5E714) -> on_resume().

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

## Skip consumable (ported; the original shows its badge):
## viewDidLoad 0x5E1E8 (the Consumable is built there) builds Consumable DM_CONSUMABLE_SKIP / Skip_20Slice,
## cost = the dead server table GameData.CoinCosts ... SkipSlice, 3 when
## absent; first-time message below. viewDidLoad 0x5E1E8 builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0x5EB04 ("store" sound,
## purchaseConsumable). consumablePurchased: 0x60004 calls nextClick: with the badge as sender -- the same path as the next button.
## consumablePurchaseFailed:error: 0x601AC (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_20Slice"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton

## Carried into the squeeze/ice/water steps, mirroring the original's
## initWithFruit: chain (each nextClick: passes &fruitType down, 0x5F950).
##
## NOTE for core/GameState.gd: this belongs there as per-food state; GameState
## currently only carries milkshake fields, so the lsu chain lives here.
static var fruit_type := 0
static var fruit_prefix := "lsu_lemon_"
static var fruit_color := Color(0.9, 1.0, 0.3)

## The five fruit buttons built in initFlavors (0x5EB70), in tag order, with
## the exact initWithFrame: rects, and the colorWithRed:green:blue:alpha:
## values from flavorClicked: (0x5F2A0). The scroll view's contentSize is
## (320, 320); locks are added on tags 1-4 when content is locked -- the port
## ships everything unlocked (FF_KEY_EVERYTHING), so they never appear.
const FRUITS := [
	{"prefix": "lsu_lemon_", "rect": Rect2(40, 80, 102, 78),
		"color": Color(0.9, 1.0, 0.3)},
	{"prefix": "lsu_lime_", "rect": Rect2(180, 85, 94, 71),
		"color": Color(0.6, 1.0, 0.4)},
	{"prefix": "lsu_orange_", "rect": Rect2(40, 180, 90, 96),
		"color": Color(1.0, 0.8, 0.2)},
	{"prefix": "lsu_grapefruit_", "rect": Rect2(170, 170, 102, 106),
		"color": Color(1.0, 0.6, 0.6)},
	{"prefix": "lsu_strawberry_", "rect": Rect2(100, 260, 102, 125),
		"color": Color(1.0, 0.3, 0.4)},
]

## viewDidAppear: parks aScrollView at (0, -height) and animates it to frame
## (0, 0, w, 428) over 0.5s; flavorClicked: slides it back out to y = -height.
const PANEL_ENTER_Y := -480.0
const PANEL_SLIDE := 0.5

## flavorClicked:: WholeFruitView (UIImageView, true centre) at (160, 180);
## knifeIV (DraggableIV, self-sizing, true centre) at (160, 240).
const FRUIT_CENTER := Vector2(160, 180)
const KNIFE_CENTER := Vector2(160, 240)

## draggableTouchMoved: -- armed when knife centre y <= 100 (0x60D00), cut
## when armed and y >= 200 (0x60D04).
const KNIFE_HIGH_Y := 100.0
const KNIFE_CUT_Y := 200.0

# -- splitFruitSequence (0x605D8) --------------------------------------

## Halves (UIImageViews, true centres): half_1 at (200, 160) rot -15 deg,
## half_2 at (140, 160) rot +15 deg, inserted below the knife.
const HALF1_START := Vector2(200, 160)
const HALF2_START := Vector2(140, 160)
const HALF1_ROT0 := -0.2617994       # 0xBE860A92
const HALF2_ROT0 := 0.2617994        # 0x3E860A92
## "Animate_Fruit_Rollout": 0.2s (0x60B98) linear, autoreverse, x3, to
## half_1 -> +10 deg (0x3E32B8C2), half_2 -> -15 deg.
const ROLL_SECONDS := 0.2
const ROLL_REPEATS := 3
const HALF1_ROT1 := 0.17449927
const HALF2_ROT1 := -0.2617994
## "Animate_Fruit_Location": 1.0s ease-in-out to (230, 160) / (80, 190).
const HALF1_END := Vector2(230, 160)
const HALF2_END := Vector2(80, 190)
const MOVE_SECONDS := 1.0

var _panel: Node2D
var _panel_tween: Tween
## The scroll view's MODEL origin (the target of the last setFrame:, animated
## or not) -- what UIKit hit-tests during the slides.
var _panel_model := Vector2(0, PANEL_ENTER_Y)
var _buttons: Array = []
var _whole: Sprite2D
var _half1: Sprite2D
var _half2: Sprite2D
var _knife: Node    # DraggableSprite2D
var _chosen := -1
var _was_high := false
var _has_cut := false

const DraggableSprite2D := preload("res://core/DraggableSprite2D.gd")
const Shared := preload("res://screens/lsuShared.gd")


func on_enter() -> void:
	# viewDidLoad built the badge before any viewWillAppear content, and hid
	# it: it only appears once a fruit is chosen (flavorClicked: 0x5F2A0).
	_build_skip()
	_skip_button.visible = false
	_panel = Node2D.new()
	var slot := outlet("aScrollView")
	if slot != null and slot != self:
		slot.add_child(_panel)
	else:
		add_child(_panel)
	UIKit.park_instruction(self)


## viewDidAppear: (0x5E714), when the push / pop slide is over:
## initFlavors (0x5EB70) -- first entry builds the five buttons
## (contentSize (320, 320)); both branches hide next -- then the scroll view
## set to (0, -480, 320, 480) and slid to (0,0,320,428) over 0.5s, and
## changeInstruction:@"inst_select_fruit.png". The 320-high content never
## exceeds the 428-high frame: the view does not scroll, its indicators
## never show, and its touches are taps.
func on_did_appear() -> void:
	if _buttons.is_empty():
		_build_picker()
	_set_next_enabled(false)
	_panel.visible = true
	_panel.position = Vector2(0, PANEL_ENTER_Y)
	if _panel_tween != null and _panel_tween.is_valid():
		_panel_tween.kill()
	_panel_model = Vector2.ZERO
	_panel_tween = create_tween()
	_panel_tween.tween_property(_panel, "position", Vector2.ZERO, PANEL_SLIDE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	change_instruction("inst_select_fruit.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## Five whole-fruit buttons in the scroll view; UIButton background images
## scale to the button frame, so each sprite is scaled into its rect. The
## nib's aScrollView sits above instIV and the back/next buttons and below
## buyAllBtn; the panel takes its slot. viewDidAppear: sets the scroll view's
## frame to (0, -view.height) and animates it to (0, 0, w, 428) over 0.5s
## with the default (ease-in-out) curve.
func _build_picker() -> void:
	for i in FRUITS.size():
		var fruit: Dictionary = FRUITS[i]
		var r: Rect2 = fruit["rect"]
		var btn := Node2D.new()
		btn.position = r.position
		btn.set_meta("rect", r)
		btn.set_meta("index", i)
		_panel.add_child(btn)
		_buttons.append(btn)

		var art := _tex(str(fruit["prefix"]) + "whole.png")
		if art != null:
			var icon := Sprite2D.new()
			icon.texture = art
			icon.centered = false
			icon.scale = r.size / art.get_size()
			btn.add_child(icon)


func _unhandled_input(event: InputEvent) -> void:
	if _chosen >= 0:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	# The 0.5s slide-in is a +beginAnimations:"Hide_FlavorSelect" block
	# (viewDidAppear: 0x5E714). Old-style blocks leave touches ON
	# (-[UIViewAnimationState _allowsUserInteraction] 0x3307B220 answers YES;
	# only the block API without AllowUserInteraction eats touches), and the
	# ordinary hit test reads the MODEL frame -- already (0,0,320,428) the
	# moment the block commits. So a fruit takes a tap during the slide, at
	# its final place. (The port used to ignore taps until the slide landed,
	# an inference from UIKit's docs that the device's UIKit contradicts.)
	var local: Vector2 = _panel.get_global_transform_with_canvas().affine_inverse() \
		* mb.position + (_panel.position - _panel_model)
	for btn in _buttons:
		if not is_instance_valid(btn):
			continue
		var r: Rect2 = btn.get_meta("rect")
		if r.has_point(local):
			_on_fruit_selected(int(btn.get_meta("index")))
			get_viewport().set_input_as_handled()
			return


## flavorClicked: (0x5F2A0): button_press, record the fruit, build the whole
## fruit and the knife, slide the picker away 0.5s, swap the instruction.
func _on_fruit_selected(index: int) -> void:
	_chosen = index
	Audio.play("button_press")
	_skip_button.visible = true
	var fruit: Dictionary = FRUITS[index]
	fruit_type = index
	fruit_prefix = str(fruit["prefix"])
	fruit_color = fruit["color"]

	_whole = Sprite2D.new()
	_whole.texture = _tex(fruit_prefix + "whole.png")
	_whole.centered = true
	_whole.position = FRUIT_CENTER
	add_child(_whole)

	_knife = DraggableSprite2D.new()
	_knife.texture = _tex("lsu_knife_1.png")
	_knife.centered = true
	_knife.position = KNIFE_CENTER
	# DraggableIV defaults: snapTime 0 (released views stay), no axis locks.
	add_child(_knife)
	_knife.drag_started.connect(_on_knife_grabbed)
	_knife.drag_moved.connect(_on_knife_moved)
	_knife.drag_ended.connect(_on_knife_released)

	# A new animation of the frame replaces a slide-in still running; without
	# setAnimationBeginsFromCurrentState: its CABasicAnimation starts from
	# the old MODEL value (UIKit actionForLayer:forKey: 0x32F34998 sets only
	# the fromValue, read from the model), i.e. from (0,0).
	if _panel_tween != null and _panel_tween.is_valid():
		_panel_tween.kill()
		_panel.position = _panel_model
	_panel_model = Vector2(0, PANEL_ENTER_Y)
	var slide := create_tween()
	_panel_tween = slide
	slide.tween_property(_panel, "position", Vector2(0, PANEL_ENTER_Y),
		PANEL_SLIDE).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	slide.tween_callback(func() -> void: _panel.visible = false)

	_was_high = false
	_has_cut = false
	change_instruction("inst_slice.png")
	# bringSubviewToFront: backButton, nextButton, instIV -- above the fruit
	# and the knife just added.
	for n: Node in [outlet("backButton"), outlet("nextButton"), outlet("instIV")]:
		if n != null and n != self and n.get_parent() == self:
			move_child(n, get_child_count() - 1)


## draggableTouchBegan: (0x60BA0): knife art swaps to lsu_knife_2, the "was
## high enough" latch resets, and lsu_knife_pickup.mp3 plays.
func _on_knife_grabbed() -> void:
	_knife.texture = _tex("lsu_knife_2.png")
	_was_high = false
	Audio.play("lsu_knife_pickup")


## draggableTouchMoved: (0x60C40): arm above y=100, cut past y=200.
func _on_knife_moved(center: Vector2) -> void:
	if _has_cut:
		return
	if center.y <= KNIFE_HIGH_Y:
		_was_high = true
	if _was_high and center.y >= KNIFE_CUT_Y:
		_split_fruit()


## draggableTouchEnded: (0x60D08): the art reverts; the knife stays put.
func _on_knife_released(_center: Vector2, _hit: bool) -> void:
	if is_instance_valid(_knife):
		_knife.texture = _tex("lsu_knife_1.png")


## splitFruitSequence (0x605D8).
func _split_fruit() -> void:
	_has_cut = true
	Audio.play("lsu_slice")

	# ORIGINAL BUG, ported: the whole fruit's image is set to
	# imageNamed:@"splat.png" (CFString 0x6BA054, no fruit prefix appended)
	# and no such file ships -- the per-fruit lsu_*_splat.png art is never
	# used. The whole fruit therefore vanishes the instant the cut lands.
	# The original also animates that now-empty view's scale (0.5, then x3);
	# there is nothing to see, so the port omits the empty-view animation.
	_whole.texture = null

	_half1 = _make_half("half_1.png", HALF1_START, HALF1_ROT0)
	_half2 = _make_half("half_2.png", HALF2_START, HALF2_ROT0)

	# "Animate_Fruit_Rollout": 0.2s linear wobble, autoreversed x3, settling
	# on the animation's model values (+10 deg / -15 deg).
	_wobble(_half1, HALF1_ROT0, HALF1_ROT1)
	_wobble(_half2, HALF2_ROT0, HALF2_ROT1)

	# "Animate_Fruit_Location": 1.0s ease-in-out slide apart.
	create_tween().tween_property(_half1, "position", HALF1_END, MOVE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	create_tween().tween_property(_half2, "position", HALF2_END, MOVE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	show_next_button()
	_set_next_enabled(true)


func _make_half(suffix: String, center: Vector2, rot: float) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = _tex(fruit_prefix + suffix)
	s.centered = true
	s.position = center
	s.rotation = rot
	# insertSubview:belowSubview:knifeIV.
	add_child(s)
	move_child(s, _knife.get_index())
	return s


func _wobble(node: Sprite2D, from_rot: float, to_rot: float) -> void:
	var t := create_tween()
	for i in ROLL_REPEATS:
		t.tween_property(node, "rotation", to_rot, ROLL_SECONDS) \
			.set_trans(Tween.TRANS_LINEAR)
		t.tween_property(node, "rotation", from_rot, ROLL_SECONDS) \
			.set_trans(Tween.TRANS_LINEAR)
	# UIKit leaves the model value at the animated target. (Guarded: next is
	# up the moment the cut lands, and viewDidDisappear: removes the halves.)
	t.tween_callback(func() -> void:
		if is_instance_valid(node):
			node.rotation = to_rot)


func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.disabled = not on


## nextClick: (0x5F950): button_press, push SqueezeFruit initWithFruit:.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.next()


## viewWillDisappear: (0x5E8F4) hides buySkip; viewDidDisappear: (0x5E948)
## removes WholeFruitView, both halves and knifeIV and nils them. Both run on
## the push as well as the pop.
func on_exit() -> void:
	if _skip_button != null:
		_skip_button.visible = false
	for n in [_whole, _half1, _half2, _knife]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_whole = null
	_half1 = null
	_half2 = null
	_knife = null


## UINavigationController keeps this controller alive under SqueezeFruit
## (nextClick: pushes), so back shows the same instance (Nav.gd opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from SqueezeFruit. viewWillAppear: (0x5E64C) -> screenSetup
## (0x5E9F8): contentLocked only. viewDidAppear: (0x5E714) -> initFlavors'
## RE-ENTRY branch (0x5EB70, the picker already built): nextButton hidden
## (locks removed -- none here); the picker set to (0, -480, 320, 480) and
## slid to (0,0,320,428) over 0.5s; changeInstruction:
## @"inst_select_fruit.png". The fruit and knife went in viewDidDisappear:,
## buySkip stays hidden until a fruit is picked: the whole step again.
## Here only viewWillAppear: (start of the pop slide); viewDidAppear:'s
## picker slide and banner are on_did_appear().
func on_resume() -> void:
	Shared.drop_coin_view(self)
	_chosen = -1
	_was_high = false
	_has_cut = false


## backClick: (0x5F8E0): button_press, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


# -- skip consumable ----------------------------------------------------

## viewDidLoad's ConsumableButton and the init's Consumable (see header).
func _build_skip() -> void:
	_skip = ConsumableScript.new(SKIP_KEY, SKIP_NAME, SKIP_COST)
	_skip.set("first_time_message", SKIP_MESSAGE)
	_skip.set("on_purchased", _on_skip_purchased)
	_skip.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buySkip"
	b.call("setup", SKIP_ART, 0, -25, SKIP_COST, 65, 3)
	b.position = SKIP_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyClick)
	add_child(b)
	_skip_button = b


## buyClick: -- "store" sound, purchaseConsumable.
func _on_buyClick() -> void:
	Audio.play("store")
	_skip.call("purchase", self)


## consumablePurchased: -> nextClick: (see header).
func _on_skip_purchased(_free: bool) -> void:
	_on_nextClick()
