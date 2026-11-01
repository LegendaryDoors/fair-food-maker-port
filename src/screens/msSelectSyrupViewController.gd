# Milkshake step 4 -- choose a syrup and pour it in (optional, repeatable).
#
# Ported from viewWillAppear: (0x50918), viewDidAppear: (0x50AB8),
# initFlavors (0x50C3C), flavorClicked: (0x52410), showBottle: (0x526A8),
# addSyrupColorToMilk: (0x52994), consumablePurchased: (0x52B90), nextClick:
# (0x52F48), changeInstruction: (0x532F4), accelerometer:didAccelerate:
# (0x53500) and touchesBegan:withEvent: (0x53D68), checked line by line
# against the original code. What that reading changed in the port:
#
#   * The jar was empty. initFlavors fills blenderContents with the six ice
#     cream balls and one 0.4-scale piece per added ingredient, and puts the
#     tinted milkView under it; the stream pours in BEHIND that milk.
#   * A finished pour brings the picker back (another syrup can be poured on
#     top -- each folds 0.2 into the milk) instead of ending the screen.
#   * A touch off the bottle is touchesBegan: it CANCELS the syrup (picker
#     back, bottle hidden, next shown). The pour is press-and-hold ON the
#     bottle (the port's click-and-hold on the vessel); it used to be anywhere,
#     which left the cancel unreachable.
#   * Next is hidden on entry (changeInstruction: hides it, 0x532F4) and shown
#     by a finished pour or a cancel touch -- not live from the start.
#   * Back is NOT locked on entry: this viewWillAppear: enables it.
#   * Pour sound "pouring" (was "pouring_loop"), thumbs at the button's (0,0)
#     (were centred), the bottle starting at the button's content-space centre
#     (no +65 scroll-frame offset), the badge hidden while a bottle is out.
#
# Kept alive under the push: on_resume() re-runs viewWillAppear: (0x50918),
# on_did_appear() viewDidAppear: (0x50AB8) including initFlavors' re-entry
# branch and its 3.0s showNextButton.
#
# viewDidAppear:'s work starts after the 0.35 s push / pop slide
# (on_did_appear), and the thumb strip is a real UIScrollView
# (UIKit.ScrollPhysics): contentSize (490, 100) in the 320x100 frame,
# horizontal indicator off, everything else the nib default.

extends "res://core/Screen.gd"

const UIKit := preload("res://screens/msUIKit.gd")
## Carries the shared TintedIV changeColor: bake (0x47304), incl. SoftLight.
const kcPourOil := preload("res://screens/kcPourOilViewController.gd")

## The eight syrups, exact UIColor values from initFlavors (0x50C3C) and
## flavorClicked: (0x52410); tag = index.
const SYRUPS := [
	Color(1.00, 1.00, 1.00),
	Color(0.35, 0.23, 0.07),
	Color(1.00, 0.30, 0.40),
	Color(0.40, 1.00, 0.60),
	Color(0.80, 0.60, 0.50),
	Color(1.00, 0.15, 0.10),
	Color(0.30, 0.30, 0.95),
	Color(1.00, 0.95, 0.50),
]

# -- picker geometry (initFlavors 0x50C3C) -----------------------------

## Eight 40x80 buttons at y=10, x = 40 + 50i. Each holds a TintedIV
## (ms_Syrup_Bottle_Flavor_Thumb, colour, blend 1) and the untinted
## ms_Syrup_Bottle_Thumb, both added at the button's (0,0) at natural size
## (24x80). contentSize (490, 100).
const BTN_SIZE := Vector2(40, 80)
const BTN_FIRST_X := 40.0
const BTN_PITCH := 50.0
const BTN_Y := 10.0
const CONTENT_W := 490.0
## viewDidAppear: setCenter:(160,-100) -> frame (0,-150,320,100), then
## setFrame:(0,65,w,100) over 0.5s. showBottle: animates (0,-100,w,100), 0.5s
## (vmov.f64 #0.5 at 0x5275E). A finished pour re-runs the viewDidAppear:
## slide; a cancel touch slides to (0,0,w,100) instead ("Show_FlavorSelect").
const PANEL_SIZE := Vector2(320, 100)
const PANEL_ENTER := Rect2(0, -150, 320, 100)
const PANEL_HOME := Rect2(0, 65, 320, 100)
const PANEL_EXIT := Rect2(0, -100, 320, 100)
const PANEL_CANCEL := Rect2(0, 0, 320, 100)
const PANEL_SLIDE := 0.5
## viewDidAppear:'s setCenter:(160,-100), re-run on every appearance.
const PANEL_ENTER_CENTER := Vector2(160, -100)
## initFlavors' re-entry branch: performSelector:showNextButton afterDelay:3.0.
const NEXT_DELAY := 3.0

## SyrupBottleView: TintedIV(ms_Syrup_Bottle_Flavor, clear, 1), setFrame:
## (180,60,103,206), the glass ms_Syrup_Bottle as a subview; both 78x259 at
## the frame's (0,0). A real frame, so a true centre.
const BOTTLE_CENTER := Vector2(231.5, 163.0)
const BOTTLE_SIZE := Vector2(103, 206)
const BOTTLE_FLY_SECONDS := 0.5

# -- the jar (initFlavors 0x50C3C) -------------------------------------

## Six UIImageViews of ms_icscoops<iceCreamNum>, true centres in
## blenderContents (nib (40,309,240,171)); second centre from registers at
## 0x50E1C..0x50E42 = (190,220).
const TABLEAU_CENTERS := [
	Vector2(50, 220), Vector2(190, 220), Vector2(120, 220),
	Vector2(120, 160), Vector2(190, 160), Vector2(50, 160),
]
## One UIImageView per added ingredient, scale 0.4 (0x3ECCCCCD), centre
## (150r + 70, 75r + 70), r = random() * 2^-31 -- floats 150/75/70 from the
## literal pool at 0x512E4/0x512E8/0x512EC (vldr at 0x50F68..0x50F72).
const PIECE_SCALE := 0.4
const PIECE_SPAN := Vector2(150, 75)
const PIECE_BASE := Vector2(70, 70)
## Art by tag (the switch from 0x50F2A). Tag 0 and any unknown tag take the
## default, ms_Strawberry -- which is tag 0's art anyway.
const PIECE_ART := {
	"1": "ms_Rasberry", "2": "ms_Orange", "3": "ms_Mango", "4": "ms_Lychees",
	"5": "ms_Yogurt", "6": "ms_banana", "7": "ms_Blueberry",
	"100": "ms_Chocolate", "101": "ms_Cinnamon_Imperials",
	"102": "ms_Gummi_Bears", "103": "ms_M_Ms", "104": "ms_Peppermints",
	"105": "ms_Spice_Drops", "106": "ms_Butter_Cups",
	"107": "ms_Chocolate_Kisses", "108": "ms_Chocolete_Candies",
	"109": "ms_chocCookies",
	"200": "ms_Chopped_Peanuts", "201": "ms_Roasted_Cashews",
	"202": "ms_Pistachios", "203": "ms_Walnuts",
}
const PIECE_ART_DEFAULT := "ms_Strawberry"
## milkView: TintedIV(ms_Blender_Top_View_Milk, milkColor, 1), art top-left
## (0,315), inserted below blenderContents.
const MILK_TOP_LEFT := Vector2(0, 315)

# -- the pour (0x53500) ------------------------------------------------

const REST_ROTATION := -0.2618        # -15 deg
const CLAMP_ROTATION := -2.5307       # -145 deg
const POUR_THRESHOLD := -1.57079633   # -90 deg
## PORT CHOICE: the fixed hold angle and tip time.
const POUR_ROTATION := -2.0944
const TIP_SECONDS := 0.35
## Stream TOP-LEFT (zero-framed TintedIV): bottle centre +
## (sin(rot)*125, cos(rot)*-95). No extra offset here (the milk screen has one).
const STREAM_SIN_K := 125.0
const STREAM_COS_K := -95.0
## startAccelerometer (0x53C58): 1/30s. SyrupPourCount counts tipped
## callbacks and completes at exactly 30.
const TICK_HZ := 30.0
const POUR_COUNT := 30

var _panel: UIKit.ScrollFrame
var _buttons: Array = []
var _physics: UIKit.ScrollPhysics
var _tracking := false               # a press on the strip is being tracked
var _press_pos := Vector2.ZERO
var _flavors_built := false          # initFlavors' first-entry branch ran

var _milk: Sprite2D                   # milkView
var _bottle: Node2D                   # SyrupBottleView
var _bottle_flavor: Sprite2D
var _stream: Sprite2D                 # SyrupStreamView
var _held := false
var _tip_tween: Tween
var _accel := false                   # accelerometer delegate set
var _pouring := false                 # isPouringSyrup
var _count := 0                       # SyrupPourCount
var _ticks := 0                       # tipped callbacks, for tests
var _accum := 0.0
var _chosen := -1                     # a bottle is out (picker index)
var _color := Color.WHITE             # currentColor
## Port-side flag for tests: at least one pour has completed.
var _done := false
var _next_home := Vector2.ZERO

## Mystery flavour:
##   initWithMilk:iceCream:iceCreamNum:fruitAve: 0x503C0  Consumable
##     DM_CONSUMABLE_MYSTERY_FLAVOR / MysteryFlavor_40Syrup, cost =
##     CoinCosts."Milkshake".MysteryFlavor, 6 when absent; first-time message.
##   viewDidLoad 0x505DC  ConsumableButton(btn_mystery_flavor, (0,-25) /
##     (65,3)) at centre (50, 350.5); buyMysteryFlavorClick:.
##   viewWillAppear: 0x50918  badge unhidden and interaction enabled.
##   showBottle: 0x526A8  badge HIDDEN and interaction disabled.
##   pour completion (0x53500) and touchesBegan: (0x53D68)  badge back.
##   buyMysteryFlavorClick: 0x52E5C  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x52B90  quantity 0, currentColor = a random colour
##     (see mystery_color), then showBottle: with [aScrollView subviews][0].
##     INFERRED: that is taken to be button 0 -- if UIKit's scroll indicators
##     were already subviews it would be an indicator instead; not verifiable
##     offline.
##   consumablePurchaseFailed:error:2 0x52D88  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_FLAVOR"
const MYSTERY_NAME := "MysteryFlavor_40Syrup"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery flavor! You never know what flavor it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_flavor.png"
const MYSTERY_CENTER := Vector2(50, 350.5)

var _mystery: RefCounted
var _mystery_button: TextureButton


## viewDidLoad (0x505DC): the mystery badge. The nib's aScrollView is at
## (0,65,320,100), empty, and the jar is empty until viewDidAppear:.
func on_enter() -> void:
	_next_home = UIKit.next_home(self)
	_build_bottle()
	_panel = UIKit.scroll_frame(self, outlet("aScrollView"),
		Rect2(PANEL_HOME.position, PANEL_SIZE))
	_build_mystery()
	UIKit.park_instruction(self)
	set_process(true)


## viewDidAppear: (0x50AB8), after the slide, on every appearance:
## initFlavors (0x50C3C) -- blenderContents emptied and refilled; first
## entry: the eight thumbs, contentSize, the milk; re-entry: showNextButton
## after 3.0s and next hidden -- then setCenter:(160,-100), a 0.5s slide to
## (0,65,w,100), and changeInstruction:@"inst_add_syrups.png" (which on this
## screen ends with nextButton setHidden:YES).
func on_did_appear() -> void:
	_fill_jar()
	if not _flavors_built:
		_flavors_built = true
		_build_picker()
		_build_milk()
		_build_stream()
	else:
		get_tree().create_timer(NEXT_DELAY).timeout.connect(_show_next_later)
		_set_next_enabled(false)
	_panel.set_center(PANEL_ENTER_CENTER)
	_panel.animate_frame(PANEL_HOME, PANEL_SLIDE)
	change_instruction("inst_add_syrups.png")


## viewWillAppear: (0x50918) ENABLES backButton (the 0.5s enableBackButton it
## also schedules is a no-op then). Unlike the other ms screens there is no
## lockout here.
func lock_back_button() -> void:
	pass


## consumablePurchased:'s colour: hue = arc4random() % 1000 / 1000,
## saturation and brightness = arc4random() % 500 / 1000 + 0.5, alpha 1.
static func mystery_color() -> Color:
	var hue := float(randi() % 1000) / 1000.0
	var sat := float(randi() % 500) / 1000.0 + 0.5
	var bri := float(randi() % 500) / 1000.0 + 0.5
	return Color.from_hsv(hue, sat, bri, 1.0)


func _build_mystery() -> void:
	_mystery = ConsumableScript.new(MYSTERY_KEY, MYSTERY_NAME, MYSTERY_COST)
	_mystery.set("first_time_message", MYSTERY_MESSAGE)
	_mystery.set("on_purchased", _on_mystery_purchased)
	_mystery.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyMysteryFlavor"
	b.call("setup", MYSTERY_ART, 0, -25, MYSTERY_COST, 65, 3)
	b.position = MYSTERY_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyMysteryFlavorClick)
	add_child(b)
	_mystery_button = b


func _set_badge(on: bool) -> void:
	if _mystery_button != null:
		_mystery_button.visible = on
		_mystery_button.disabled = not on


func _on_buyMysteryFlavorClick() -> void:
	if _chosen >= 0:
		return
	Audio.play("store")
	_mystery.call("purchase", self)


## consumablePurchased: (0x52B90): a random colour, bottle from button 0.
func _on_mystery_purchased(_free: bool) -> void:
	if _chosen >= 0:
		return
	_show_bottle(0, mystery_color())


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


# -- construction -----------------------------------------------------

func _contents() -> Node2D:
	var c := outlet("blenderContents")
	if c != null and c != self and c is Node2D:
		return c as Node2D
	return null


## initFlavors' first-entry branch: milkView below blenderContents. Built
## once -- the re-entry branch makes no new one, so a return visit keeps the
## milk with every syrup already folded into it.
func _build_milk() -> void:
	var jar := _contents()
	if jar == null:
		return
	var milk_tex := _tex("ms_Blender_Top_View_Milk.png")
	if milk_tex != null and jar.get_parent() != null:
		_milk = Sprite2D.new()
		_milk.texture = milk_tex
		_milk.centered = false
		_milk.position = MILK_TOP_LEFT
		_milk.modulate = GameState.milk_color     # blend 1 = multiply
		jar.get_parent().add_child(_milk)
		jar.get_parent().move_child(_milk, jar.get_index())


## The head of initFlavors, run on EVERY appearance: every subview of
## blenderContents removed, then the six balls and one piece per added
## ingredient (fresh random spots each time) added back.
func _fill_jar() -> void:
	var jar := _contents()
	if jar == null:
		return
	for c in jar.get_children():
		c.queue_free()

	var ball_tex := _tex(GameState.ice_cream_texture) \
		if GameState.ice_cream_texture != "" else null
	if ball_tex != null:
		for c: Vector2 in TABLEAU_CENTERS:
			var ball := Sprite2D.new()
			ball.texture = ball_tex
			ball.centered = true
			ball.position = c
			jar.add_child(ball)

	for tag in GameState.fruits:
		var tex := _tex(str(PIECE_ART.get(tag, PIECE_ART_DEFAULT)) + ".png")
		if tex == null:
			continue
		var piece := Sprite2D.new()
		piece.texture = tex
		piece.centered = true
		piece.scale = Vector2(PIECE_SCALE, PIECE_SCALE)
		piece.position = PIECE_BASE + Vector2(
			randf() * PIECE_SPAN.x, randf() * PIECE_SPAN.y)
		jar.add_child(piece)


## SyrupStreamView, created on the first tipped callback and inserted BELOW
## milkView -- the stream vanishes behind the milk. Built once here, hidden;
## its tint is baked per bottle.
func _build_stream() -> void:
	_stream = Sprite2D.new()
	_stream.texture = _tex("ms_Syrup.png")
	_stream.centered = false
	_stream.visible = false
	if _milk != null and _milk.get_parent() != null:
		_milk.get_parent().add_child(_stream)
		_milk.get_parent().move_child(_stream, _milk.get_index())
	else:
		add_child(_stream)


## SyrupBottleView: added on top of the view, hidden. TintedIV never resizes
## its subviews, so both 78x259 arts hang from the frame's top-left at
## natural size; the pivot is the frame centre.
func _build_bottle() -> void:
	_bottle = Node2D.new()
	_bottle.position = BOTTLE_CENTER
	_bottle.visible = false
	add_child(_bottle)
	_bottle_flavor = Sprite2D.new()
	_bottle_flavor.texture = _tex("ms_Syrup_Bottle_Flavor.png")
	_bottle_flavor.centered = false
	_bottle_flavor.position = -BOTTLE_SIZE * 0.5
	_bottle.add_child(_bottle_flavor)
	var glass := Sprite2D.new()
	glass.texture = _tex("ms_Syrup_Bottle.png")
	glass.centered = false
	glass.position = -BOTTLE_SIZE * 0.5
	_bottle.add_child(glass)


func _build_picker() -> void:
	var thumb := _tex("ms_Syrup_Bottle_Flavor_Thumb.png")
	var thumb_glass := _tex("ms_Syrup_Bottle_Thumb.png")
	for i in SYRUPS.size():
		var btn := Node2D.new()
		btn.position = Vector2(BTN_FIRST_X + BTN_PITCH * i, BTN_Y)
		btn.set_meta("rect", Rect2(btn.position, BTN_SIZE))
		btn.set_meta("index", i)
		_panel.content.add_child(btn)
		_buttons.append(btn)
		if thumb != null:
			var icon := Sprite2D.new()
			icon.texture = thumb
			icon.centered = false
			icon.modulate = SYRUPS[i]          # blend 1 = multiply
			btn.add_child(icon)
		if thumb_glass != null:
			var glass := Sprite2D.new()
			glass.texture = thumb_glass
			glass.centered = false
			btn.add_child(glass)
	# setContentSize:(490, 100), setShowsHorizontalScrollIndicator:NO
	# (0x50C3C); decelerationRate, bounces and the vertical indicator stay
	# the nib defaults. 100-high content in a 100-high frame: only x scrolls.
	_physics = _panel.enable_scrolling(Vector2(CONTENT_W, PANEL_SIZE.y),
		func(ph: UIKit.ScrollPhysics) -> void: ph.shows_horizontal = false)


# -- touches -----------------------------------------------------------

## A press inside the strip's MODEL frame is the UIScrollView's: a drag
## after 10 pt (UIKit.ScrollPhysics), otherwise a tap on the thumb under the
## press (flavorClicked:). Moves and the release are read in _input so a drag
## keeps tracking over the nib's buttons.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return

	if not mb.pressed:
		if _held:
			_set_held(false)
		return

	# Press. The UIScrollView swallows touches inside its frame.
	if _physics != null and _panel.model_has_point(mb.position):
		_tracking = true
		_press_pos = mb.position
		_physics.touch_began(_panel.touch_point(mb.position))
		get_viewport().set_input_as_handled()
		return
	# PORT CHOICE: the tilt is a hold ON the bottle.
	if _accel and _on_bottle(mb.position):
		_set_held(true)
		return
	_touches_began()


func _input(event: InputEvent) -> void:
	if not _tracking:
		return
	if event is InputEventMouseMotion:
		_physics.touch_moved(_panel.touch_point((event as InputEventMouseMotion).position))
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT or mb.pressed:
			return
		_tracking = false
		var tap := _physics.touch_ended(_panel.touch_point(mb.position))
		if tap and _chosen < 0:
			var i := _thumb_at(_press_pos)
			if i >= 0:
				_on_thumb_tapped(i)
		get_viewport().set_input_as_handled()


func _thumb_at(p: Vector2) -> int:
	if not _panel.model_has_point(p):
		return -1
	var local := _panel.to_content(p)
	for btn in _buttons:
		if (btn.get_meta("rect") as Rect2).has_point(local):
			return int(btn.get_meta("index"))
	return -1


## The bottle's MODEL frame (103x206 about its resting centre) at its current
## rotation -- UIKit hit-tests a transformed view through its transform.
func _on_bottle(p: Vector2) -> bool:
	if not _bottle.visible:
		return false
	var local := (p - BOTTLE_CENTER).rotated(-_bottle.rotation)
	return Rect2(-BOTTLE_SIZE * 0.5, BOTTLE_SIZE).has_point(local)


## flavorClicked: (0x52410): button_press, the tag's colour, showBottle:.
func _on_thumb_tapped(index: int) -> void:
	Audio.play("button_press")
	_show_bottle(index, SYRUPS[index])


## showBottle: (0x526A8).
func _show_bottle(index: int, c: Color) -> void:
	_chosen = index
	_color = c
	_set_badge(false)
	_bottle_flavor.modulate = c                # changeColor:, blend 1
	_stream.texture = kcPourOil.bake_tint(_tex("ms_Syrup.png"), c, 8)
	_panel.animate_frame(PANEL_EXIT, PANEL_SLIDE)
	change_instruction("inst_pour.png")        # hides next, as on the phone

	# centre = (button.center.x - contentOffset.x, button.center.y): content
	# coordinates straight into the view's space -- no scroll-frame offset.
	var btn_center := Vector2(BTN_FIRST_X + BTN_PITCH * index, BTN_Y) \
		+ BTN_SIZE * 0.5 - Vector2(_panel.get_offset_x(), 0)
	if _tip_tween != null and _tip_tween.is_valid():
		_tip_tween.kill()
	_held = false
	_bottle.rotation = 0.0
	_bottle.position = btn_center
	_bottle.visible = true
	create_tween().tween_property(_bottle, "position", BOTTLE_CENTER,
		BOTTLE_FLY_SECONDS).set_trans(UIKit.TRANS).set_ease(UIKit.EASE)

	_accel = true                              # startAccelerometer
	_accum = 0.0
	_count = 0
	_pouring = false


## PORT CHOICE: hold tips to POUR_ROTATION, release tips back.
func _set_held(value: bool) -> void:
	if _held == value:
		return
	_held = value
	if not _accel:
		return
	if _tip_tween != null and _tip_tween.is_valid():
		_tip_tween.kill()
	_tip_tween = create_tween()
	_tip_tween.tween_property(_bottle, "rotation",
		POUR_ROTATION if value else REST_ROTATION, TIP_SECONDS) \
		.set_trans(UIKit.TRANS).set_ease(UIKit.EASE)


func _process(delta: float) -> void:
	if not _accel:
		return
	if _stream.visible:
		_stream.position = _stream_position()
	_accum += delta
	var step := 1.0 / TICK_HZ
	while _accum >= step and _accel:
		_accum -= step
		_accelerometer_tick()


## Neck position for the bottle's current tilt.
func _stream_position() -> Vector2:
	var rot := _bottle.rotation
	return _bottle.position + Vector2(sin(rot) * STREAM_SIN_K, cos(rot) * STREAM_COS_K)


## One accelerometer:didAccelerate: callback (0x53500).
func _accelerometer_tick() -> void:
	# An upright device filters to x ~ 0: the first callback snaps the bottle
	# to the rest clamp.
	if not _held and (_tip_tween == null or not _tip_tween.is_valid()):
		_bottle.rotation = REST_ROTATION
	var rot: float = clampf(_bottle.rotation, CLAMP_ROTATION, REST_ROTATION)
	if rot <= POUR_THRESHOLD:
		if not _pouring:
			_pouring = true
			Audio.loop("pouring")
			_stream.visible = true
			_stream.position = _stream_position()
		_ticks += 1
		_count += 1
		if _count == POUR_COUNT:
			_finish()
	elif _pouring:
		Audio.stop("pouring")
		_stream.visible = false
		_pouring = false


## The completion branch of 0x53500: addSyrupColorToMilk:, showNextButton,
## pour stopped, accelerometer stopped, bottle hidden, the picker slid back in
## from centre (160,-100) to (0,65,320,100), the badge back. Another syrup
## can then be chosen and poured.
func _finish() -> void:
	GameState.add_syrup_color_to_milk(_color)
	if _milk != null:
		_milk.modulate = GameState.milk_color   # milkView changeColor:
	UIKit.show_next_from_home(self, _next_home)
	_done = true
	_end_bottle()
	_panel.set_frame(PANEL_ENTER)
	_panel.animate_frame(PANEL_HOME, PANEL_SLIDE)
	_set_badge(true)


## Shared tail of completion and cancel: stop pouring and the accelerometer,
## hide the bottle and reset its tilt (the original resets it to -15 RADIANS,
## invisible because the bottle is hidden first).
func _end_bottle() -> void:
	if _pouring:
		Audio.stop("pouring")
		_pouring = false
	_count = 0
	if _stream != null:
		_stream.visible = false
	_accel = false
	_held = false
	if _tip_tween != null and _tip_tween.is_valid():
		_tip_tween.kill()
	_bottle.visible = false
	_bottle.rotation = REST_ROTATION
	_chosen = -1


## touchesBegan:withEvent: (0x53D68). With the picker on screen and next
## already showing, nothing. Otherwise: "cancel", showNextButton, the pour and
## accelerometer stopped, the bottle hidden, the picker slid in from centre
## (160,-100) to (0,0,320,100), the badge back.
func _touches_began() -> void:
	if _panel.model.position.y > -1.0 and not _next_hidden():
		return
	Audio.play("cancel")
	UIKit.show_next_from_home(self, _next_home)
	_end_bottle()
	_panel.set_frame(PANEL_ENTER)
	_panel.animate_frame(PANEL_CANCEL, PANEL_SLIDE)
	_set_badge(true)


func _next_hidden() -> bool:
	var n := outlet("nextButton")
	return n != null and n != self and not (n as CanvasItem).visible


## backClick: (0x52EC8): button_press, stopAccelerometer, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	if _accel:
		_end_bottle()
	Nav.back()


## nextClick: (0x52F48): button_press, stopAccelerometer, bottle hidden, push
## msBlender(milkColor, iceCreamColor, iceCreamNum, addedFruit).
func _on_nextClick() -> void:
	Audio.play("button_press")
	if _accel:
		_end_bottle()
	Nav.next()


## No viewWillDisappear: work in the original; nextClick:/backClick: stop the
## pour through stopAccelerometer. Kept as a guard -- nothing visible changes.
func on_exit() -> void:
	Audio.stop("pouring")


## UINavigationController keeps this controller alive under msBlender
## (nextClick: pushes), so back shows the same instance (Nav.gd opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from msBlender:
##   viewWillAppear: (0x50918): backButton ENABLED (enableBackButton again at
##     +0.5s, a no-op), buyMysteryFlavor unhidden and interaction enabled.
##   viewDidAppear: (0x50AB8) -> initFlavors (0x50C3C): blenderContents
##     emptied and refilled (balls, pieces at new random spots); the
##     RE-ENTRY branch (picker already built): locks removed (none here),
##     performSelector:showNextButton afterDelay:3.0 (double
##     0x4008000000000000), nextButton hidden. Then setCenter:(160,-100),
##     a 0.5s slide to (0,65,320,100), and changeInstruction:
##     @"inst_add_syrups.png" (which hides next again).
## The milkView keeps its folded colour; nextClick: already put the bottle
## away. Another syrup can be poured on top, or next taken after 3s.
## Here only viewWillAppear: (start of the pop slide); the viewDidAppear:
## part is on_did_appear().
func on_resume() -> void:
	UIKit.drop_coin_view(self)
	var back := first_outlet(BACK_OUTLETS)
	if back != null:
		back.set("disabled", false)
	_set_badge(true)
	if _tracking and _physics != null:
		_physics.touch_cancelled()
	_tracking = false


## The re-entry branch's delayed showNextButton. Connected to this node's
## method, so it dies with a popped screen; skipped while a pushed screen
## covers this one (the next return hides next and re-arms it anyway).
func _show_next_later() -> void:
	if is_inside_tree():
		UIKit.show_next_from_home(self, _next_home)


func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.disabled = not on


## This screen's changeInstruction: hides nextButton (0x532F4 ends with
## nextButton setHidden:YES); Screen.change_instruction honours it.
func instruction_hides_next() -> bool:
	return true

# NOT PORTED, deliberately:
#
#  * Lock overlays (round_black_lock at (-12,30,43,45) on tags 2,3,4,5,6,7)
#    and lockedFlavorButtonClicked: -- everything is unlocked in the port.
#  * skipClick: (0x5308C) -- no nib or code wires it.
#  * addSyrupColorToMilk: quantises milk and syrup to 8 bits before the
#    0.8/0.2 mix; GameState.add_syrup_color_to_milk mixes the floats (<= 1/255
#    per channel).
#  * (The strip does scroll with UIKit's physics: momentum, rubber band and
#    bounce, through UIKit.ScrollPhysics.)
