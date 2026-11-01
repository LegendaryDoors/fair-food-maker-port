# Milkshake step 1 -- choose a milk, then pour it into the blender.
#
# Ported from viewDidAppear: (0x47F30), screenSetup (0x480E0), initFlavors
# (0x48240), flavorClicked: (0x48B14), backClick: (0x490CC), nextClick:
# (0x4918C), showNextButton (0x498A0), changeInstruction: (0x49A38) and
# accelerometer:didAccelerate: (0x49C50), checked line by line against the
# original code. Kept alive under the push: viewWillAppear: (0x47E68) re-runs
# in on_resume(), viewDidAppear: (0x47F30) in on_did_appear(), after the
# 0.35 s push / pop slide, as on the phone. The picker's UIScrollView
# never scrolls: its contentSize (320, 250) equals the 320x250 frame it is
# given, so neither axis can (_canScrollX/Y), and viewDidAppear: turns both
# indicators off -- taps go straight to the three buttons.
#
# As everywhere in the port, the accelerometer tilt becomes press-and-hold:
# holding tips the bottle to a fixed angle and releasing tips it back.
# Everything the tilt fed is kept as read: the -90 deg pour threshold, the
# 1/30 s callback that counts the pour, the 120-count fill, the trig stream
# position.

extends "res://core/Screen.gd"

const UIKit := preload("res://screens/msUIKit.gd")
## Carries the shared TintedIV changeColor: bake (0x47304), incl. SoftLight.
const kcPourOil := preload("res://screens/kcPourOilViewController.gd")

## Flavour art plus the exact UIColor each one tints the milk and shake with
## (flavorClicked: 0x48B14; tag 0 white, 1 chocolate, 2 strawberry).
const MILKS := [
	{"id": "plain", "jug": "ms_Milk_Jug", "icon": "", "color": Color(1.00, 1.00, 1.00)},
	{"id": "chocolate", "jug": "ms_Chocolate_Jug", "icon": "ms_Chocolate_Icon",
		"color": Color(0.35, 0.23, 0.07)},
	{"id": "strawberry", "jug": "ms_Strawberry_Jug", "icon": "ms_Strawberry_Icon",
		"color": Color(1.00, 0.50, 0.60)},
]

# -- picker: initFlavors 0x48240 ----------------------------------------

## Buttons initWithFrame:(x, 50, 82, 164), x = 20/120/220. The jug is
## UIImageView initWithImage: added at the button's (0,0) -- its TOP-LEFT, at
## natural size (82x164, i.e. it fills the button). The flavour icon is a
## second UIImageView centred (60,140). (The port used to centre the JUG on
## (60,140) and drop the icons.)
const BTN_SIZE := Vector2(82, 164)
const BTN_Y := 50.0
const BTN_X := [20.0, 120.0, 220.0]
const ICON_CENTER := Vector2(60, 140)
## viewDidAppear: setCenter:(160,-250) on the nib's 320x100 scroll view, then
## animates setFrame:(0, 0, w, 250) over 0.5s. flavorClicked: animates it to
## (0, -250, w, 250), 0.5s (vmov.f64 #0.5 at 0x48CDA).
const NIB_SCROLL_SIZE := Vector2(320, 100)
const PANEL_ENTER_CENTER := Vector2(160, -250)
const PANEL_HOME := Rect2(0, 0, 320, 250)
const PANEL_EXIT := Rect2(0, -250, 320, 250)
const PANEL_SLIDE := 0.5

# -- the bottle ---------------------------------------------------------

## MilkBottleView setFrame:(180, 60, 103, 206): a real frame, so a true centre.
const BOTTLE_RECT := Rect2(180, 60, 103, 206)
const BOTTLE_FLY_SECONDS := 0.5

# -- the pour (0x49C50) -------------------------------------------------

## Clamps the filtered tilt is held between, and the angle past which it pours.
const REST_ROTATION := -0.2618      # -15 deg
const CLAMP_ROTATION := -2.5307     # -145 deg
const POUR_THRESHOLD := -1.57079633 # -90 deg
## PORT CHOICE: hold-to-pour needs one fixed angle and a tip time.
## Any angle past POUR_THRESHOLD pours; this sits inside the grounded clamp.
const POUR_ROTATION := -2.0944
const TIP_SECONDS := 0.35

## Stream TOP-LEFT (zero-framed TintedIV) from the bottle centre:
## (sin(rot)*115 - 20, cos(rot)*-85 - 10). The syrup screen uses 125 / -95
## and no offset -- same shape of formula, different numbers.
const STREAM_SIN_K := 115.0
const STREAM_COS_K := -85.0
const STREAM_OFFSET := Vector2(-20, -10)

## startAccelerometer (0x4A1C8): setUpdateInterval: 1/30 (double
## 0x3FA1111120000000). One pour count per callback while tipped.
const TICK_HZ := 30.0
const POUR_COUNT := 120
## pouredMilk: MaskedIV(TintedIV(ms_Blender_Top_View_Milk, colour, 1).image,
## ms_Blender_Top_View_mask), setCenter:(160, 397.5) -> top-left (0, 315) for
## the 320x165 view. baseOrigPt starts (160, 215) -- below the view, nothing
## drawn -- and every EVEN count becomes (0, 215 - 215*count/120).
const FILL_VIEW_ORIGIN := Vector2(0, 315)
const FILL_START := Vector2(160, 215)
const FILL_FROM_Y := 215.0

var _panel: UIKit.ScrollFrame
var _buttons: Array = []
var _pressed_button := -1
var _milk_fill: UIKit.MaskedIV        # pouredMilk
var _bottle: Node2D                   # MilkBottleView
var _bottle_milk: Sprite2D
var _stream: Sprite2D                 # MilkStreamView
var _held := false
var _tip_tween: Tween
var _pouring := false                 # isPouringMilk
var _count := 0                       # milkPourCount
var _ticks := 0                       # pour callbacks, for tests
var _accum := 0.0
var _accel := false                   # accelerometer delegate set
var _chosen := -1
var _done := false                    # hasPouredMilk
var _color := Color.WHITE             # currentColor
var _next_home := Vector2.ZERO
## initFlavors' first-entry branch has run (the buttons exist).
var _flavors_built := false


## viewDidLoad: the nib's aScrollView at (0,0,320,100), still empty; next
## shows as the nib has it and the banner sits at its nib spot until
## viewDidAppear: (on_did_appear).
func on_enter() -> void:
	GameState.begin("ms")
	_next_home = UIKit.next_home(self)
	_build_bottle()
	_panel = UIKit.scroll_frame(self, outlet("aScrollView"),
		Rect2(Vector2.ZERO, NIB_SCROLL_SIZE))
	UIKit.park_instruction(self)
	set_process(true)


## viewDidAppear: (0x47F30), after the slide, on every appearance:
## initFlavors (0x48240) -- first entry builds the three buttons and hides
## next; re-entry puts every button back to alpha 1 (the tapped one was 0),
## hides next and zeroes milkPourCount -- then setCenter:(160,-250), a 0.5s
## slide to (0,0,w,250), both indicators off (nothing to show: see header),
## changeInstruction:@"inst_select_milk.png".
func on_did_appear() -> void:
	if not _flavors_built:
		_flavors_built = true
		_build_picker()
	else:
		for b: Node2D in _buttons:
			b.modulate.a = 1.0
		_count = 0
	_set_next_enabled(false)          # initFlavors: nextButton setHidden:YES
	_panel.set_center(PANEL_ENTER_CENTER)
	_panel.animate_frame(PANEL_HOME, PANEL_SLIDE)
	change_instruction("inst_select_milk.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _insert_below(node: Node, anchor: Node) -> void:
	if anchor != null and anchor != self and anchor.get_parent() != null:
		anchor.get_parent().add_child(node)
		anchor.get_parent().move_child(node, anchor.get_index())
	else:
		add_child(node)


# -- construction -----------------------------------------------------

## MilkBottleView: TintedIV(ms_Milk_For_Jar, clearColor, 1) with
## ms_Milk_Jar.png as a subview on top, both 103x206 at the frame's (0,0).
## insertSubview:belowSubview:TopBlenderView -- under the blender rim, the
## instruction and the buttons. (The port used to add it on top of everything.)
func _build_bottle() -> void:
	_bottle = Node2D.new()
	_bottle.position = BOTTLE_RECT.get_center()
	_bottle.visible = false
	_insert_below(_bottle, outlet("TopBlenderView"))

	_bottle_milk = Sprite2D.new()
	_bottle_milk.texture = _tex("ms_Milk_For_Jar.png")
	_bottle_milk.centered = false
	_bottle_milk.position = -BOTTLE_RECT.size * 0.5
	_bottle.add_child(_bottle_milk)

	var glass := Sprite2D.new()
	glass.texture = _tex("ms_Milk_Jar.png")
	glass.centered = false
	glass.position = -BOTTLE_RECT.size * 0.5
	_bottle.add_child(glass)


## Three buttons in a clipping scroll view that slides in from centre
## (160,-250) to (0,0,320,250) -- the frame's size animates too, 100 -> 250.
func _build_picker() -> void:
	for i in MILKS.size():
		var milk: Dictionary = MILKS[i]
		var btn := Node2D.new()
		btn.position = Vector2(BTN_X[i], BTN_Y)
		btn.set_meta("rect", Rect2(btn.position, BTN_SIZE))
		btn.set_meta("index", i)
		_panel.content.add_child(btn)
		_buttons.append(btn)

		var jug := Sprite2D.new()
		jug.texture = _tex(milk["jug"] + ".png")
		jug.centered = false
		btn.add_child(jug)
		if str(milk["icon"]) != "":
			var icon := Sprite2D.new()
			icon.texture = _tex(milk["icon"] + ".png")
			icon.centered = true
			icon.position = ICON_CENTER
			btn.add_child(icon)


# -- interaction ------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return

	if _chosen < 0:
		# UIButton touchUpInside (64): fire on release inside the button the
		# press began on. Hit tests run against the scroll view's MODEL frame.
		var hit := _button_at(mb.position)
		if mb.pressed:
			_pressed_button = hit
		elif _pressed_button >= 0 and hit == _pressed_button:
			_pressed_button = -1
			_on_milk_selected(hit)
			get_viewport().set_input_as_handled()
		else:
			_pressed_button = -1
		return

	# PORT CHOICE: the tilt is a hold. Nothing else on this screen takes touches
	# (no touchesBegan:), so the hold may start anywhere off the buttons.
	_set_held(mb.pressed)


func _button_at(p: Vector2) -> int:
	if not _panel.model_has_point(p):
		return -1
	var local := _panel.to_content(p)
	for btn in _buttons:
		var r: Rect2 = btn.get_meta("rect")
		if r.has_point(local):
			return int(btn.get_meta("index"))
	return -1


## flavorClicked: (0x48B14).
func _on_milk_selected(index: int) -> void:
	Audio.play("button_press")
	_chosen = index
	var milk: Dictionary = MILKS[index]
	_color = milk["color"]
	GameState.milk_color = _color
	GameState.milk_texture = str(milk["id"])

	# The tapped button goes alpha 0 at once (setAlpha:0), the picker slides
	# away, the instruction changes.
	(_buttons[index] as Node2D).modulate.a = 0.0
	# Bottle milk: changeColor: on a blend-1 TintedIV = multiply = modulate.
	_bottle_milk.modulate = _color
	_panel.animate_frame(PANEL_EXIT, PANEL_SLIDE)
	change_instruction("inst_pour.png")

	# The bottle appears at the tapped button's centre (minus contentOffset;
	# the scroll view sits at y 0, so no frame offset either), rotation 0, and
	# animates into its frame.
	var btn_center := Vector2(BTN_X[index], BTN_Y) + BTN_SIZE * 0.5 \
		- Vector2(_panel.get_offset_x(), 0)
	_bottle.rotation = 0.0
	_bottle.position = btn_center
	_bottle.visible = true
	create_tween().tween_property(_bottle, "position", BOTTLE_RECT.get_center(),
		BOTTLE_FLY_SECONDS).set_trans(UIKit.TRANS).set_ease(UIKit.EASE)

	# pouredMilk, inserted below the bottle.
	var base := _tex("ms_Blender_Top_View_Milk.png")
	var mask := _tex("ms_Blender_Top_View_mask.png")
	_milk_fill = UIKit.MaskedIV.new(base, mask)
	_milk_fill.position = FILL_VIEW_ORIGIN
	_milk_fill.set_tint(_color)
	_milk_fill.set_base_orig_pt(FILL_START)
	_milk_fill.set_mask_flip_v(true)   # MaskedIV quirk; the mask art is drawn
	                                   # upside down to compensate (its wide,
	                                   # rounded end is at the BOTTOM of the file)
	_insert_below(_milk_fill, _bottle)

	# MilkStreamView: TintedIV(ms_Milk.png, colour, blend 8 = SoftLight), made
	# on the first tipped callback and inserted below pouredMilk. Built here,
	# hidden, with the same bake.
	_stream = Sprite2D.new()
	_stream.texture = kcPourOil.bake_tint(_tex("ms_Milk.png"), _color, 8)
	_stream.centered = false
	_stream.visible = false
	_insert_below(_stream, _milk_fill)

	_count = 1                         # milkPourCount = 1
	_done = false
	_accel = true                      # startAccelerometer
	_accum = 0.0


## PORT CHOICE: press tips the bottle to POUR_ROTATION, release
## tips it back to the rest clamp. Pouring itself is decided per callback by
## the angle, exactly as the original decides it.
func _set_held(value: bool) -> void:
	if _held == value or not _accel:
		return
	_held = value
	if _tip_tween != null and _tip_tween.is_valid():
		_tip_tween.kill()
	_tip_tween = create_tween()
	_tip_tween.tween_property(_bottle, "rotation",
		POUR_ROTATION if value else REST_ROTATION, TIP_SECONDS) \
		.set_trans(UIKit.TRANS).set_ease(UIKit.EASE)


func _process(delta: float) -> void:
	if _bottle == null or not _accel:
		return
	if _stream != null and _stream.visible:
		_stream.position = _stream_position()
	_accum += delta
	var step := 1.0 / TICK_HZ
	while _accum >= step:
		_accum -= step
		_accelerometer_tick()


## bottle.center + (sin(rot)*115 - 20, cos(rot)*-85 - 10).
func _stream_position() -> Vector2:
	var rot: float = _bottle.rotation
	return _bottle.position + Vector2(
		sin(rot) * STREAM_SIN_K, cos(rot) * STREAM_COS_K) + STREAM_OFFSET


## One accelerometer:didAccelerate: callback (0x49C50).
func _accelerometer_tick() -> void:
	# The first callback snaps the bottle to the rest clamp: an upright device
	# filters to x ~ 0, and 6*x > -0.2618 clamps to -0.2618.
	if not _held and (_tip_tween == null or not _tip_tween.is_valid()):
		_bottle.rotation = REST_ROTATION
	var rot: float = clampf(_bottle.rotation, CLAMP_ROTATION, REST_ROTATION)

	var back := first_outlet(BACK_OUTLETS)
	if rot <= POUR_THRESHOLD:
		if back != null:
			back.set("disabled", true)
		if not _pouring:
			# Nothing here hides instIV (the port used to): inst_pour stays up
			# until showNextButton hides it.
			_pouring = true
			Audio.loop("pouring")
			_stream.visible = true
			_stream.position = _stream_position()
		_ticks += 1
		var c := _count
		var counted := false
		if c <= POUR_COUNT:
			_count = c + 1
			c = _count
			counted = c < POUR_COUNT
		if counted or _done:
			if c % 2 == 0 and not _done:
				_milk_fill.set_base_orig_pt(Vector2(0,
					FILL_FROM_Y - FILL_FROM_Y * float(c) / float(POUR_COUNT)))
				_milk_fill.fill = float(c) / float(POUR_COUNT)
		else:
			# "Milk pour complete": hasPouredMilk, showNextButton. The pour
			# itself goes on while the bottle stays tipped (no fill), as on
			# the phone.
			_done = true
			_milk_fill.fill = 1.0
			UIKit.show_next_from_home(self, _next_home)
	elif _pouring:
		if back != null:
			back.set("disabled", false)
		Audio.stop("pouring")
		_stream.visible = false
		_pouring = false


## stopAccelerometer (0x4A230).
func _stop_accelerometer() -> void:
	_accel = false
	if _pouring:
		Audio.stop("pouring")
		if _stream != null:
			_stream.visible = false
		_pouring = false


func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.disabled = not on


## backClick: (0x490CC): button_press; with a pour under way, stop the
## accelerometer and remove pouredMilk; pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	_stop_accelerometer()
	Nav.back()


## nextClick: (0x4918C): button_press, pouredMilk removeFromSuperview,
## stopAccelerometer (which removes MilkStreamView if a pour is running),
## bottle hidden, push msScoop with currentColor. This controller stays alive
## under the push, so the removals are real: back shows no milk in the jar.
func _on_nextClick() -> void:
	Audio.play("button_press")
	if _milk_fill != null:
		_milk_fill.queue_free()
		_milk_fill = null
	_stop_accelerometer()
	# PORT: the port builds the stream at pick time, hidden, where the
	# original creates MilkStreamView on the first tipped callback; it goes
	# with the accelerometer here so a re-pick builds a fresh one.
	if _stream != null:
		_stream.queue_free()
		_stream = null
	if _bottle != null:
		_bottle.visible = false
	Nav.next()


## Nothing here in the original (no viewWillDisappear:); nextClick: and
## backClick: already stop the pour through stopAccelerometer. Kept as a
## guard -- it changes nothing the player can see.
func on_exit() -> void:
	Audio.stop("pouring")


## UINavigationController keeps this controller alive under msScoop
## (nextClick: pushes), so back shows the same instance (Nav.gd opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from msScoop -- what viewWillAppear: and viewDidAppear: do on a
## controller whose view is already loaded:
##   viewWillAppear: (0x47E68) -> screenSetup (0x480E0): backButton disabled,
##     enableBackButton 0.5s later (double 0x3FE00000).
##   viewDidAppear: (0x47F30) -> initFlavors (0x48240), the RE-ENTRY branch
##     (the scroll view already holds the three buttons): every button back to
##     alpha 1 -- the tapped one was set to 0 -- nextButton hidden,
##     milkPourCount 0. Then the picker is re-parked with setCenter:(160,-250)
##     at the 320x250 size flavorClicked: left it, slides to (0,0,320,250)
##     over 0.5s, and changeInstruction:@"inst_select_milk.png".
## The milk, stream and bottle were already removed by nextClick:. A new
## milk is chosen and poured from scratch (flavorClicked: resets the counts).
## Here only viewWillAppear: (start of the pop slide); the viewDidAppear:
## part is on_did_appear().
func on_resume() -> void:
	UIKit.drop_coin_view(self)
	lock_back_button()
	_chosen = -1
	_pressed_button = -1
	_held = false

# NOT PORTED, deliberately:
#
#  * Lock overlays (round_black_lock.png at (16,70,43,45), tag 1000, on the
#    chocolate and strawberry buttons) and lockedFlavorButtonClicked: -- the
#    port ships everything unlocked (FF_KEY_EVERYTHING), so contentLocked is 0.
#  * BuyAllClick: / productPurchased: -- the IAP path; buyAllBtn is hidden by
#    Screen._hide_upsells as the original hides it under FF_KEY_EVERYTHING.
#  * NSUserDefaults analytics keys (uniqueMilk, dateMkrFlag, startMkrDate,
#    endMkrDate, previousGame, previousScreen) and DataLogging calls -- they
#    feed analytics only; nothing a player sees reads them back.
#  * The edge-pixel algebra of TintedIV blend 1 (multiply over a clipped fill)
#    is rendered as a plain multiply; ~2% of the milk art's pixels are
#    partially transparent and differ slightly.
