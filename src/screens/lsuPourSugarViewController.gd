# Lemon Shake Up step 1 -- tilt the sugar bag to pour sugar into the cup.
#
# GROUNDED from initFlavors (0x5B94C), accelerometer:didAccelerate: (0x5C978,
# literal pools 0x5CD18..0x5CD58 and 0x5CFB8..0x5CFD4), startAccelerometer
# (0x5CFD8, interval 1/30 at 0x5D038), viewDidAppear: (0x5B854) and
# viewWillAppear: (0x5B720).
#
# The pour is the same *shape* as the milkshake screens but shares none of
# their numbers: the tilt clamp here is [-125 deg, -15 deg] (the milk screen's
# is [-145, -15]), the stream constants are 115/45 and -45/156, and the fill
# is a rising sugar-pile art, not a boundary fill.
#
# As a PORT CHOICE, tilt becomes press-and-hold: the bag animates to one fixed
# angle inside the grounded clamp range, and everything the tilt fed -- the
# 120-tick counter, the trig stream position, the every-6th-tick fill -- is
# kept exactly.
#
# Corrected against the original code: the pour no longer hides the
# instruction (only showNextButton 0x5C620 does); the bag sits above every
# view until the first pouring tick runs the bringSubviewToFront chain; the
# cup mask is applied upside down, as MaskedIV does on the device; backClick:
# (0x5BE50) plays button_press.
#
# Kept alive under the push.
# viewWillDisappear: (0x5B8A0) -> on_exit() strips the bag and the sugar;
# viewWillAppear: (0x5B720, initFlavors) / viewDidAppear: -> on_resume().

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

## Skip consumable (ported; the original shows its badge):
## initWithNibName: 0x5B0E8 builds Consumable DM_CONSUMABLE_SKIP / Skip_10Pour,
## cost = the dead server table GameData.CoinCosts ... LEMON_SHAKE_UP.SkipIngredients, 3 when
## absent; first-time message below. viewDidLoad 0x5B270 builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0x5BDE4 ("store" sound,
## purchaseConsumable). consumablePurchased: 0x5BB68 calls nextClick: with the badge as sender -- the same path as the next button.
## consumablePurchaseFailed:error: 0x5BD10 (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_10Pour"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton

const Shared := preload("res://screens/lsuShared.gd")


# -- initFlavors (0x5B94C) ---------------------------------------------

## SugarBagView: UIImageView(lsu_sugar_bag) setFrame:(160, 10, 102, 146) --
## the art is exactly 102x146, so the frame is natural size, centre (211, 83).
const BAG_RECT := Rect2(160, 10, 102, 146)
## MaskedIV(lsu_sugar_pile, lsu_cup_mask), frame = BackCupView.frame,
## baseOrigPt (44, 273): the 110x82 pile starts fully below the 211x273 mask.
const FILL_ORIG_X := 44.0
const FILL_ORIG_Y0 := 273.0

# -- the pour (0x5C978) ------------------------------------------------

## Low-pass filter 0.05/0.95 (0x5CD18/0x5CD20), rotation = filteredX * 6.0.
## Clamps (0x5CD28..0x5CD40) and threshold (0x5CD48):
const REST_ROTATION := -0.2617994    # -15 deg
const CLAMP_ROTATION := -2.1816617   # -125 deg -- NOT the milk screen's -145
const POUR_THRESHOLD := -1.5707964   # -90 deg
## PORT CHOICE: hold-to-pour needs one fixed angle past the
## threshold, inside the grounded clamp range. Same value the ms screens use.
const POUR_ROTATION := -2.0944
const TIP_SECONDS := 0.35

## Stream centre = bag.center + (sin(rot)*115 + 45, cos(rot)*(-45) + 161 - 5).
## (0x5CD50/0x5CD58, 0x5CFB8/0x5CFC0; the -5 is a vadd.f32 #-5.0 at 0x5CEB4
## applied to y only -- x is passed unmodified, read from the disassembly.)
const STREAM_SIN_K := 115.0
const STREAM_X_OFF := 45.0
const STREAM_COS_K := -45.0
const STREAM_Y_OFF := 156.0
## The stream view's frame is (0, 0, art.w, art.h - 50) (0x5CFC8) -- the
## 90x322 art is drawn scale-to-fill into 90x272.
const STREAM_H_TRIM := 50.0

## sugarPourCount: +1 per tick at 30 Hz (interval 1/30, double at 0x5D038);
## complete when the pre-increment count reaches 0x77+1 = 120; the fill moves
## every 6th tick: baseOrigPt.y = (count / -120) * 90 + 273  (0x5CFCC/D0/D4).
const POUR_TICKS := 120
const TICK_HZ := 30.0
const FILL_DIV := -120.0
const FILL_MUL := 90.0

var _fill: Shared.MaskedIV
var _bag: Sprite2D
var _stream: Sprite2D
var _held := false
var _hold_tween: Tween
var _pouring := false
var _ticks := 0
var _accum := 0.0
var _done := false


func on_enter() -> void:
	# viewDidLoad built the badge before any viewWillAppear content.
	_build_skip()
	GameState.begin("lsu")
	_build_fill()
	_build_bag()
	# initFlavors: sugarPourCount = 0, hasPouredSugar = NO, next hidden.
	_set_next_enabled(false)
	UIKit.park_instruction(self)
	set_process(true)


## viewDidAppear: (0x5B854), after the push / pop slide:
## changeInstruction:@"inst_pour.png" -- on every appearance.
func on_did_appear() -> void:
	change_instruction("inst_pour.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## initFlavors adds the masked pile, then the bag, with addSubview: -- both
## land above every nib view (TopCupView, instIV and the buttons included).
## The pile cannot show yet (baseOrigPt.y 273 is the mask's full height); the
## bag does, over everything, until the first pouring tick reorders.
func _build_fill() -> void:
	_fill = Shared.MaskedIV.new(_tex("lsu_sugar_pile.png"), _tex("lsu_cup_mask.png"))
	var back := outlet("BackCupView")
	_fill.position = back.position if back is Node2D else Vector2(54, 150)
	_fill.set_base_orig_pt(Vector2(FILL_ORIG_X, FILL_ORIG_Y0))
	add_child(_fill)


func _build_bag() -> void:
	_bag = Sprite2D.new()
	_bag.texture = _tex("lsu_sugar_bag.png")
	_bag.centered = true                      # rotates about the frame centre
	_bag.position = BAG_RECT.position + BAG_RECT.size * 0.5
	# initFlavors starts the 30 Hz accelerometer straight away, and its first
	# callback clamps any rotation above -15 deg down to -0.2618 -- so a phone
	# held level shows the bag at -15 deg from the start, not upright.
	_bag.rotation = REST_ROTATION
	add_child(_bag)


## The stream is created on the first pouring tick and removed when the tilt
## comes back up (0x5C978, both branches), not merely hidden. Creating it runs
## addSubview:stream, then bringSubviewToFront: on the pile, TopCupView,
## backButton, nextButton, skipButton (a nil outlet) and instIV -- leaving
## bag < stream < pile < TopCup < back < next < instIV.
func _make_stream() -> void:
	var tex := _tex("lsu_sugar_stream1.png")
	if tex == null:
		return
	_stream = Sprite2D.new()
	_stream.texture = tex
	_stream.centered = true
	_stream.scale = Vector2(1.0, (tex.get_size().y - STREAM_H_TRIM) / tex.get_size().y)
	add_child(_stream)
	_stream.position = _stream_center()
	for n: Node in [_fill, outlet("TopCupView"), outlet("backButton"),
			outlet("nextButton"), outlet("instIV")]:
		if n != null and n != self and n.get_parent() == self:
			move_child(n, get_child_count() - 1)


func _free_stream() -> void:
	if _stream != null:
		_stream.queue_free()
		_stream = null


func _stream_center() -> Vector2:
	var rot := _bag.rotation
	return _bag.position + Vector2(
		sin(rot) * STREAM_SIN_K + STREAM_X_OFF,
		cos(rot) * STREAM_COS_K + STREAM_Y_OFF)


# -- interaction -------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_set_held(event.pressed)


## PORT CHOICE: press tips the bag to the fixed pour angle, release returns it to
## the rest clamp. Pouring itself keys off the angle crossing -90 deg, exactly
## as the original's tilt branch does.
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


func _set_pouring(value: bool) -> void:
	if _pouring == value:
		return
	_pouring = value
	if value:
		# First pouring tick: loop cc_sugar_pour.m4a, create the stream.
		Audio.loop("cc_sugar_pour")
		_make_stream()
	else:
		# Tilt-up branch: stop the loop, remove the stream.
		Audio.stop("cc_sugar_pour")
		_free_stream()


func _process(delta: float) -> void:
	if _bag == null:
		return
	_set_pouring(_bag.rotation <= POUR_THRESHOLD)
	if _stream != null:
		_stream.position = _stream_center()
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
		# "SugarPourComplete": hasPouredSugar = YES, showNextButton. The pour
		# can keep running; the fill just stops moving.
		_done = true
		show_next_button()
		_set_next_enabled(true)
		return
	if _ticks % 6 == 0 and not _done:
		var y := (float(_ticks) / FILL_DIV) * FILL_MUL + FILL_ORIG_Y0
		_fill.set_base_orig_pt(Vector2(FILL_ORIG_X, y))


func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.disabled = not on


## nextClick: (0x5BED0): button_press, stop the accelerometer, push SliceFruit.
func _on_nextClick() -> void:
	Audio.play("button_press")
	_stop_accelerometer()
	Nav.next()


## stopAccelerometer (0x5D040): delegate cleared; if a pour is running,
## cc_sugar_pour stops, the stream is removed, isPouringSugar = NO.
func _stop_accelerometer() -> void:
	if _pouring:
		Audio.stop("cc_sugar_pour")
		_free_stream()
		_pouring = false


## backClick: (0x5BE50): button_press, stopAccelerometer (which stops the
## pour loop and drops the stream), pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Audio.stop("cc_sugar_pour")
	Nav.back()


## viewWillDisappear: (0x5B8A0), on the push as well as the pop:
## SugarBagView and SugarPourMaskedView removeFromSuperview (released,
## nilled), then stopAccelerometer.
func on_exit() -> void:
	Audio.stop("cc_sugar_pour")
	_stop_accelerometer()
	_free_stream()
	if _hold_tween != null and _hold_tween.is_valid():
		_hold_tween.kill()
	_held = false
	if _bag != null:
		_bag.queue_free()
		_bag = null
	if _fill != null:
		_fill.queue_free()
		_fill = null


## UINavigationController keeps this controller alive under SliceFruit
## (nextClick: pushes), so back shows the same instance (Nav.gd opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from SliceFruit. viewWillAppear: (0x5B720) runs initFlavors
## (0x5B94C) again -- a new masked sugar pile (empty, baseOrigPt (44,273)),
## a new bag at (160,10,102,146), the accelerometer restarted,
## sugarPourCount 0, hasPouredSugar NO, nextButton hidden -- and unhides
## buySkip; viewDidAppear: (0x5B854) changeInstruction:@"inst_pour.png".
## The sugar is poured again from an empty cup.
func on_resume() -> void:
	Shared.drop_coin_view(self)
	_build_fill()
	_build_bag()
	_ticks = 0
	_accum = 0.0
	_done = false
	_set_next_enabled(false)
	if _skip_button != null:
		_skip_button.visible = true
	# viewDidAppear:'s changeInstruction: runs in on_did_appear().


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
