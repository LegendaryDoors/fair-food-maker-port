# Lemon Shake Up step 4 -- tilt the ice bag; cubes tumble into the cup.
#
# GROUNDED from initFlavors (0x69814), accelerometer:didAccelerate: (0x6A880,
# literal pools 0x6ABB8..0x6ABE8 and 0x6AE08..0x6AE1C), startAccelerometer
# (interval 1/30 at 0x6AE80), viewDidAppear: (0x69690) and nextClick:
# (0x6A298).
#
# Same accelerometer shape as the sugar screen -- filter 0.05/0.95, rotation
# = filteredX * 6, clamp [-125 deg, -15 deg], pour past -90 deg, 30 Hz -- but
# there is no masked fill here: the cup fills with individual cube sprites
# whose landing spot is a function of the tick count. As a PORT CHOICE the
# tilt becomes press-and-hold at a fixed angle.
#
# Corrected against the original code: the juice is TintedIV's overlay bake
# (was a modulate); the pour no longer hides the instruction; the bag rests
# at the -15 deg clamp from the start; backClick: (0x6A124) plays
# button_press.
#
# Kept alive under the push.
# viewWillDisappear: (0x696DC) -> on_exit() strips the bag and the cup;
# viewWillAppear: (0x695D4, initFlavors) / viewDidAppear: -> on_resume().

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

## Skip consumable (ported; the original shows its badge):
## initWithFruit: 0x690F0 builds Consumable DM_CONSUMABLE_SKIP / Skip_50Ice,
## cost = the dead server table GameData.CoinCosts ... SkipIce, 3 when
## absent; first-time message below. viewDidLoad 0x692B8 builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0x6A0B8 ("store" sound,
## purchaseConsumable). consumablePurchased: 0x69E38 calls nextClick: with the badge as sender -- the same path as the next button.
## consumablePurchaseFailed:error: 0x69FE4 (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_50Ice"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton

const lsuSliceFruit := preload("res://screens/lsuSliceFruitViewController.gd")
const Shared := preload("res://screens/lsuShared.gd")

# -- initFlavors (0x69814): the carried-over tableau --------------------

## TintedIV(lsu_fruit_juice, fruitColor, blend 3) -- zero-frame class, so
## setCenter:(-1, 0) lands the art's TOP-LEFT there, BackCupView-local. Not
## masked here: the whole overlay-baked art (Shared.tinted_image).
const JUICE_TOP_LEFT := Vector2(-1, 0)
## Both halves reuse <prefix>half_1.png (half_2 art is not used here), as
## UIImageViews in BackCupView -- true centres -- matching where the squeeze
## screen left them: (120, 150) rot 0 x0.5, and (76, 130) rot 150 deg x0.5.
const HALF1_CENTER := Vector2(120, 150)
const HALF2_CENTER := Vector2(76, 130)
const HALF2_ROT := 2.6179938             # 0x40278D36
const HALF_SCALE := 0.5
## IceBagView: UIImageView(lsu_ice_bag) setFrame:(160, 10, 102, 146) -- the
## same frame the sugar bag used; the 130x157 art scales to fill it.
const BAG_RECT := Rect2(160, 10, 102, 146)

# -- the pour (0x6A880) ------------------------------------------------

const REST_ROTATION := -0.2617994        # -15 deg   (0x6ABC8/0x6ABD0)
const CLAMP_ROTATION := -2.1816617       # -125 deg  (0x6ABD8/0x6ABE0)
const POUR_THRESHOLD := -1.5707964       # -90 deg   (0x6ABE8)
## PORT CHOICE: fixed hold angle inside the clamp range.
const POUR_ROTATION := -2.0944
const TIP_SECONDS := 0.35

## sugarPourCount ticks at 30 Hz while pouring; complete when the
## pre-increment count reaches 0x77+1 = 120. Cubes spawn on EVEN ticks only,
## and every 16th tick plays "ice".
const POUR_TICKS := 120
const TICK_HZ := 30.0

## Cube spawn (BackCupView-local): centre (110, -100), scale x0.25, then a
## 0.5s ease-in-out "DripDrop" to scale x4 (net 1.0) and a landing point of
##   x = (1 - c/120)*30 + 40 + rand01 * ((c/120)*70 + 60)
##   y = c * (-183)/120 + 223
## (floats 30 inline, 0x6AE08=120, 0x6AE0C=-183, 0x6AE10=70, 0x6AE14=40,
## 0x6AE18=60, 0x6AE1C=223). Inserted at index 1 of BackCupView: above the
## juice, below the fruit halves.
const CUBE_SPAWN := Vector2(110, -100)
const CUBE_START_SCALE := 0.25
const CUBE_DROP_SECONDS := 0.5

var _bag: Sprite2D
var _held := false
var _hold_tween: Tween
var _pouring := false
var _ticks := 0
var _accum := 0.0
var _done := false


func on_enter() -> void:
	# viewDidLoad built the badge before any viewWillAppear content.
	_build_skip()
	_build_tableau()
	_build_bag()
	_set_next_enabled(false)
	UIKit.park_instruction(self)
	set_process(true)


## viewDidAppear: (0x69690), after the push / pop slide:
## changeInstruction:@"inst_pour.png" -- on every appearance.
func on_did_appear() -> void:
	change_instruction("inst_pour.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _back_cup() -> Node2D:
	var n := outlet("BackCupView")
	return n if n is Node2D else self


## The juice and the two spent halves, exactly as the squeeze screen left
## them, rebuilt as BackCupView subviews.
func _build_tableau() -> void:
	var back := _back_cup()

	var juice := Sprite2D.new()
	juice.texture = Shared.tinted_texture(_tex("lsu_fruit_juice.png"),
		lsuSliceFruit.fruit_color, Shared.BLEND_OVERLAY)
	juice.centered = false
	juice.position = JUICE_TOP_LEFT
	back.add_child(juice)

	var half1 := _make_half(HALF1_CENTER, 0.0)
	back.add_child(half1)
	var half2 := _make_half(HALF2_CENTER, HALF2_ROT)
	back.add_child(half2)


func _make_half(center: Vector2, rot: float) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = _tex(lsuSliceFruit.fruit_prefix + "half_1.png")
	s.centered = true
	s.position = center
	s.rotation = rot
	s.scale = Vector2(HALF_SCALE, HALF_SCALE)
	return s


func _build_bag() -> void:
	_bag = Sprite2D.new()
	var tex := _tex("lsu_ice_bag.png")
	_bag.texture = tex
	_bag.centered = true
	_bag.position = BAG_RECT.position + BAG_RECT.size * 0.5
	if tex != null:
		_bag.scale = BAG_RECT.size / tex.get_size()
	# The 30 Hz accelerometer starts in initFlavors and its first callback
	# clamps the bag to -15 deg (0x6A880) -- it never rests upright.
	_bag.rotation = REST_ROTATION
	add_child(_bag)


# -- interaction -------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_set_held(event.pressed)


func _set_held(value: bool) -> void:
	if _held == value:
		return
	_held = value
	if _bag == null:
		return
	if _hold_tween != null and _hold_tween.is_valid():
		_hold_tween.kill()
	_hold_tween = create_tween()
	_hold_tween.tween_property(_bag, "rotation",
		POUR_ROTATION if value else REST_ROTATION, TIP_SECONDS) \
		.set_trans(Tween.TRANS_SINE)


func _process(delta: float) -> void:
	if _bag == null:
		return
	_pouring = _bag.rotation <= POUR_THRESHOLD
	if not _pouring:
		return
	_accum += delta
	while _accum >= 1.0 / TICK_HZ:
		_accum -= 1.0 / TICK_HZ
		_tick()


func _tick() -> void:
	var before := _ticks
	_ticks += 1
	if before >= POUR_TICKS - 1 and not _done:
		# "SugarPourComplete" (the original reuses the sugar screen's log
		# string): hasPouredSugar = YES, showNextButton.
		_done = true
		show_next_button()
		_set_next_enabled(true)
		return
	if _ticks % 2 == 0 and not _done:
		if _ticks % 16 == 0:
			Audio.play("ice")
		_spawn_cube()


## One ice cube. The art index is int(rand01 * 3) formatted into
## "lsu_ice_cube_%i.png" (format string in __cstring; random * 2^-31 * 3
## truncated at 0x6A880) -- the shipped files are _1.._3, so index 0 loads
## nothing and roughly a third of the cubes are INVISIBLE. Original quirk,
## ported: the empty sprite still animates.
func _spawn_cube() -> void:
	var back := _back_cup()
	var cube := Sprite2D.new()
	cube.texture = _tex("lsu_ice_cube_%d.png" % (randi() % 3))
	cube.centered = true
	cube.position = CUBE_SPAWN
	cube.scale = Vector2(CUBE_START_SCALE, CUBE_START_SCALE)
	back.add_child(cube)
	# insertSubview:atIndex:1 -- above the juice, below the halves.
	back.move_child(cube, 1)

	var c := float(_ticks)
	var land := Vector2(
		(1.0 - c / 120.0) * 30.0 + 40.0 + randf() * ((c / 120.0) * 70.0 + 60.0),
		c * (-183.0) / 120.0 + 223.0)
	var t := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(cube, "position", land, CUBE_DROP_SECONDS)
	t.parallel().tween_property(cube, "scale", Vector2.ONE, CUBE_DROP_SECONDS)


func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.disabled = not on


## nextClick: (0x6A298): button_press, stopAccelerometer, push PourWater
## initWithFruit:. (The push runs on_exit() at once, which removes the bag
## the port's pour is driven by -- the accelerometer stop.)
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.next()


## viewWillDisappear: (0x696DC), on the push as well as the pop: IceBagView
## removeFromSuperview (nilled), EVERY subview of BackCupView removed (juice,
## halves, cubes), stopAccelerometer.
func on_exit() -> void:
	if _hold_tween != null and _hold_tween.is_valid():
		_hold_tween.kill()
	_held = false
	_pouring = false
	if _bag != null:
		_bag.queue_free()
		_bag = null
	var back := _back_cup()
	if back != self:
		for c in back.get_children():
			c.queue_free()


## UINavigationController keeps this controller alive under PourWater
## (nextClick: pushes), so back shows the same instance (Nav.gd opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from PourWater. viewWillAppear: (0x695D4): initFlavors (0x69814)
## again -- the juice and both halves back in BackCupView, a new ice bag at
## (160,10,102,146), the accelerometer restarted, sugarPourCount 0,
## hasPouredSugar NO, nextButton hidden -- and buySkip unhidden;
## viewDidAppear: (0x69690) changeInstruction:@"inst_pour.png". The cup is
## iced again from no cubes.
func on_resume() -> void:
	Shared.drop_coin_view(self)
	_build_tableau()
	_build_bag()
	_ticks = 0
	_accum = 0.0
	_done = false
	_set_next_enabled(false)
	if _skip_button != null:
		_skip_button.visible = true
	# viewDidAppear:'s changeInstruction: runs in on_did_appear().


## backClick: (0x6A124): button_press, stop the accelerometer, strip the
## bag and BackCupView's subviews, pop.
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
