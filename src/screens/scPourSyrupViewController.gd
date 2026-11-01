# Snow Cone step 4 -- drip syrup onto the shaved ice, column by column.
#
# Read from scPourSyrupViewController in the original binary (entry points
# are the ObjC method-list IMPs):
#   initWithCup:iceMask: 0x77EB8, viewDidLoad 0x780B8,
#   viewWillAppear: 0x78720, viewDidAppear: 0x78878, initSyrups 0x788CC,
#   loop 0x79660, resetColors: 0x7A230, flavorClicked: 0x7A390,
#   showBottle: 0x7A5C8, showSyrups 0x7A734, hideSyrups 0x7A7E8,
#   backClick: 0x7ABDC, nextClick: 0x7ADB4, touchesBegan/Moved/Ended
#   0x7B870 / 0x7BA8C / 0x7BB58, animationDidStop 0x7BCCC.
# Plus the ice model: IceView initWithFrame:iceMask: 0x165E8,
# createColumns: 0x16810, IceColumnView init 0x15E98, rebuildView 0x1613C,
# changeColor: 0x15F7C.
#
# NOT accelerometer-driven. The bottle is dragged: while a finger holds it
# the bottle art tips -2.2689 rad; a 10Hz timer watches how still it is
# held, and after three still ticks releases a single tinted drop that
# falls to y=320 in 0.5s. While the drop is falling, the ice column under
# its landing point blends toward the syrup colour, and a fading echo of
# that colour spreads outward across the neighbouring columns.
#
# The ice is IceView (10,124,300,250): 31 IceColumnView strips,
# scmask_%d.png (20x250) at x = -10 + 10*(i-1), each masked by its own
# 20px slice of the chosen sc_ice_mask_%d.png and tinted by multiply
# (changeColor: fills the colour clipped to the base image, then draws the
# base with kCGBlendModeMultiply -- exactly Godot's modulate).
#
# Corrections from a full re-read of the original:
#  * The tint distance is HORIZONTAL only: distanceBetweenPt:andPt: (0x7B4BC)
#    is called with (column centre x, 0) and (drop x + 15.5, 0) -- movs r3,#0
#    / str r5(=0) at 0x79D3C..0x79D62. The port measured a 2-D distance to
#    the column's mid-height, which was always > 56.57, so every drop mixed
#    at the far weight 0.9377 instead of ~0.90: too faint.
#  * The stillness counter is the loop's exact arithmetic (floor -1, cap
#    oscillating 10/11), not a clamp to [0,10].
#  * IceColumnView (0x1613C / 0x16368) draws BOTH the column art and its mask
#    slice with CGContextDrawImage / ClipToMask in an unflipped UIKit context,
#    so the whole column comes out upside down, not just the mask.
#  * The bottle is a 32x100 frame until showBottle:/touchesBegan: make it
#    103x206; showBottle: centres the CURRENT frame on the tapped button.
#    Releasing hides it where it was let go -- and pointInside: ignores
#    `hidden`, so touching that spot again grabs the invisible bottle and
#    pours (an original quirk, reproduced).
#  * Touches inside the shown flavour strip (0,0,320,120) belong to the
#    UIScrollView; the port used to start a scrub from a press anywhere.
#  * Layering: the strip lives in the nib's aScrollView slot; the mystery
#    badge is above the nib views, the bottle above it; drops go in just
#    below the badge, and every grab brings the badge to the front.
#
# KEEP STATE: kept under Make. A return re-runs initSyrups (which resets
# every column to white) and showSyrups; there is no viewWillDisappear:.
#
# viewDidAppear: (initSyrups +
# showSyrups) runs in on_did_appear(), after the 0.35 s push / pop slide; the
# flavour strip is a real UIScrollView (UIKit.ScrollPhysics): contentSize
# (490, 100), horizontal indicator off, deceleration / bounce the nib
# defaults. The 100-high content never exceeds the 100 / 120-high frame, so
# only x scrolls and the vertical indicator never shows.

extends "res://core/Screen.gd"

const UIKit := preload("res://screens/msUIKit.gd")

## initSyrups (0x788CC): the eight tag colours as exact
## colorWithRed:green:blue:alpha: arguments.
const SYRUPS := [
	Color(1.00, 1.00, 1.00),
	Color(1.00, 0.00, 1.00),
	Color(0.00, 0.30, 1.00),   # 0x3E99999A
	Color(0.00, 1.00, 0.00),
	Color(1.00, 0.50, 0.00),
	Color(1.00, 0.00, 0.00),
	Color(1.00, 1.00, 0.00),
	Color(0.50, 0.00, 1.00),
]

# -- flavour strip (initSyrups 0x788CC, showSyrups 0x7A734) ------------
## Buttons are (40+50i, 10, 32, 100); contentSize (490,100). Each is the
## grayscale bottle tinted multiply + the sc_syrup.png art on top.
const BTN_SIZE := Vector2(32, 100)
const BTN_FIRST_X := 40.0
const BTN_PITCH := 50.0
const BTN_Y := 10.0
const CONTENT_W := 490.0
const PANEL_W := 320.0
## showSyrups parks the strip at centre (160,-120) with its CURRENT frame
## size -- origin (0,-170) the first time (the nib's 320x100), (0,-180) after
## (its own (320,120)) -- and slides it to (0,0,320,120); hideSyrups slides
## it to (0,-120). Both 0.5s.
const STRIP_ENTER_CENTER_Y := -120.0
const NIB_STRIP_SIZE := Vector2(320, 100)
const STRIP_SIZE := Vector2(320, 120)
const STRIP_HOME := Vector2.ZERO
const STRIP_EXIT := Vector2(0, -120)
const STRIP_SLIDE := 0.5

# -- the bottle ---------------------------------------------------------
## initSyrups gives the bottle TintedIV an explicit frame (180,0,32,100);
## showBottle: (0x7A5C8) animates the frame to (180,0,103,206) over 0.5s.
## TintedIV never resizes its subviews (0x46FEC), so the 32x100 art stays
## at the frame's top-left -- the larger frame is a bigger grab target,
## not a bigger bottle.
const BOTTLE_HOME := Vector2(180, 0)
const BOTTLE_GRAB_SIZE := Vector2(103, 206)
const BOTTLE_FLY := 0.5
## touchesBegan/Moved (0x7B870/0x7BA8C): frame origin = touch + (-5, +10).
const GRAB_OFFSET := Vector2(-5, 10)
## While held, every bottle subview rotates -2.2689 rad (0xC011361E) about
## its own centre.
const TIP_ROTATION := -2.2689

# -- the pour (loop 0x79660, timer 0.1s dbl 0x784E8) --------------------
const TICK := 0.1
## Stillness (disasm 0x79692..0x79764): while held and the bottle centre
## moved <= 5 px since the last tick, deltaTouchX = old > 10 ? 10 : old + 1;
## otherwise deltaTouchX = old < 0 ? 0 : old - 1 (so it idles between -1
## and 0). A drop needs >= 3.
const STILL_MOVE_LIMIT := 5.0
const STILL_NEEDED := 3.0
const STILL_CAP := 10.0
## The flavour UIScrollView's frame once showSyrups has run (0x7A734):
## touches inside it are the scroll view's and never reach the controller.
const STRIP_FRAME := Rect2(0, 0, 320, 120)
## The bottle TintedIV's frame size before (initSyrups) and after
## (showBottle: / touchesBegan:) it is enlarged.
const BOTTLE_START_SIZE := Vector2(32, 100)
## No pour below centre y 320 (float 0x79A54).
const POUR_MAX_CENTER_Y := 320.0
## Drop: lsu_juice_drop_two.png tinted multiply, top-left spawned at
## bottle centre + (-80, -20) (floats 0x79A58 / 0xC1A00000), falling to
## y=320 (0x43A00000) in 0.5s, curve 1 = ease-in.
const DROP_OFFSET := Vector2(-80, -20)
const DROP_LAND_Y := 320.0
const DROP_SECONDS := 0.5
## Column blend: t = (d/1500 if d < 56.57 else 0.0377133) + 0.9
## (floats 0x79A60 / 0x79A74 / dbl 0x79A68 / 0x79A70), d the HORIZONTAL
## distance from the column's centre to the probe; the hit column becomes
## t*current + (1-t)*syrup. The outward spread re-mixes each next column
## against the running colour with w growing by w += (1-w)*0.4 (double
## 0x7A228) per column.
const DIST_NEAR := 56.57
const DIST_DIV := 1500.0
const T_FAR := 0.03771333
const T_BASE := 0.9
const SPREAD_GROW := 0.4

# -- the ice (IceView 0x165E8 / createColumns 0x16810) ------------------
const ICE_ORIGIN := Vector2(10, 124)
const ICE_SIZE := Vector2(300, 250)
const COLUMN_COUNT := 31
const COLUMN_W := 20.0
const COLUMN_PITCH := 10.0
const COLUMN_X0 := -10.0

## Cup art (nib id2 UIImageView (-5,362,330,295), image set in viewDidLoad
## from the cupFile passed by initWithCup:iceMask:).
const CUP_SIZE := Vector2(330, 295)

var _cup_file := "sc_cup1.png"
var _mask_file := "sc_ice_mask_1.png"

var _strip: Node2D
var _content: Node2D
var _buttons: Array = []
## -contentOffset.x (the content's x), fed by the scroll physics.
var _scroll := 0.0
var _physics: UIKit.ScrollPhysics
var _tracking := false               # a press on the strip is being tracked
var _press_pos := Vector2.ZERO
var _strip_shown := false
## The strip's frame size (showSyrups' setCenter: keeps it).
var _strip_size := NIB_STRIP_SIZE

var _columns: Array[Sprite2D] = []
var _ice_root: Node2D

var _bottle: Node2D
var _bottle_arts: Array[Sprite2D] = []
var _bottle_size := BOTTLE_START_SIZE
var _bottle_tween: Tween
var _color := Color.WHITE
var _held := false

var _accum := 0.0
var _still := 0.0
var _last_x := 0.0
var _drop: Sprite2D
var _drop_animating := false
var _drop_tween: Tween

## Mystery flavour:
##   initWithCup:iceMask: 0x77EB8  Consumable DM_CONSUMABLE_MYSTERY_FLAVOR /
##     MysteryFlavor_40Design, cost = CoinCosts."Snow Cone".MysteryFlavor, 6
##     when absent; first-time message.
##   viewDidLoad 0x780B8  ConsumableButton(btn_mystery_flavor, (0,-25) /
##     (65,3)) at centre (270, 280.5) -- this screen's own placement.
##   viewWillAppear: 0x78720  badge unhidden.
##   buyMysteryFlavorClick: 0x7AB70  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x7A880  quantity 0, currentColor = a random colour
##     (see mystery_color), syrupBottle changeColor:, then showBottle: with
##     the strip's FIRST button as sender.
##   consumablePurchaseFailed:error:2 0x7AA9C  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_FLAVOR"
const MYSTERY_NAME := "MysteryFlavor_40Design"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery flavor! You never know what flavor it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_flavor.png"
const MYSTERY_CENTER := Vector2(270, 280.5)

var _mystery: RefCounted
var _mystery_button: TextureButton


func on_enter() -> void:
	# initWithCup:iceMask: -- the previous screen's selection. GameState is
	# still milkshake-shaped, so it arrives as autoload metadata.
	_cup_file = GameState.get_meta("sc_cup_file", _cup_file)
	_mask_file = GameState.get_meta("sc_ice_mask_file", _mask_file)

	dismiss_instruction()          # viewDidLoad hides instIV outright
	_setup_cup()
	_build_ice()
	_build_mystery()               # viewDidLoad: addSubview -> above the nib
	set_process(true)


## viewDidAppear: (0x78878), after the push / pop slide: initSyrups
## (0x788CC) -- first entry builds the strip into the nib's aScrollView slot
## and the bottle above the badge; a re-entry only runs resetColors: (every
## column back to white) -- then showSyrups.
func on_did_appear() -> void:
	if _strip == null:
		_build_strip()
		_build_bottle()
	else:
		_reset_colors()
	_show_strip()


## Nav keeps this controller alive under
## MakeViewController, as the UINavigationController does.
func keeps_state_on_push() -> bool:
	return true


## Back from Make. viewWillAppear: (0x78720) unhides the mystery badge;
## viewDidAppear: (0x78878) runs initSyrups and showSyrups again. The
## second initSyrups (0x788CC) finds the strip already built (>= 4
## subviews), so it only drops the lock badges and calls resetColors: with
## itself as sender -- silently, but every ice column goes back to white:
## the syrup the player poured is gone when they come back. showSyrups
## parks the strip at (0,-180) and slides it in again over 0.5 s.
func on_resume() -> void:
	if _mystery_button != null:
		_mystery_button.visible = true
	# initSyrups' resetColors: and showSyrups follow in on_did_appear().


## The class has no viewWillDisappear: / viewDidDisappear: and never stops
## its 0.1 s `loop` timer, so a drop falling when next was tapped lands and
## is removed while Make is up (and whatever it tinted is reset on return).
## INFERRED: the port's loop and tweens pause out of the tree, so the drop
## is finished here instead of resuming mid-air on return.
func on_exit() -> void:
	if _tracking and _physics != null:
		_physics.touch_cancelled()
	_tracking = false
	if _drop_animating:
		if _drop_tween != null and _drop_tween.is_valid():
			_drop_tween.kill()
		_drop_landed()


## consumablePurchased:'s colour: hue = arc4random() % 1000 / 1000,
## saturation and brightness = arc4random() % 500 / 1000 + 0.5, alpha 1.
static func mystery_color() -> Color:
	var hue := float(randi() % 1000) / 1000.0
	var sat := float(randi() % 500) / 1000.0 + 0.5
	var bri := float(randi() % 500) / 1000.0 + 0.5
	return Color.from_hsv(hue, sat, bri, 1.0)


## viewDidLoad: the ConsumableButton, and init's Consumable.
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


func _on_buyMysteryFlavorClick() -> void:
	Audio.play("store")
	_mystery.call("purchase", self)


## consumablePurchased: (0x7A880): a random colour, bottle from button 0.
func _on_mystery_purchased(_free: bool) -> void:
	if _bottle == null:
		return                # no strip / bottle before viewDidAppear:
	_select_flavor(0, mystery_color())


func _setup_cup() -> void:
	var cup := outlet("cup")
	if cup is Sprite2D:
		var s := cup as Sprite2D
		s.texture = _tex(_cup_file)
		s.centered = false
		if s.texture != null:
			s.scale = CUP_SIZE / s.texture.get_size()


# -- ice columns --------------------------------------------------------

## createColumns: (0x16810) + rebuildView (0x1613C): column i's base image
## is scmask_%d.png with its alpha cut to the [x, x+20] slice of the shape
## mask. sc_ice_mask_*.png are gray8 CG image masks: black paints, white
## blocks, so visibility scales with (1 - gray). Slice pixels outside the
## 300px mask painted in the original but were then clipped by the
## IceView's clipsToBounds; the mask is exactly as wide as the view, so
## dropping them here is the same picture.
##
## CORRECTED: the slice is applied UPSIDE DOWN. applyMaskToImage:
## mask: (0x16368) opens a UIGraphicsBeginImageContext (UIKit's flipped
## context) and calls CGContextClipToMask without flipping the CTM -- the
## MaskedIV quirk again -- so the half-disc drawn at the TOP of every
## sc_ice_mask_N.png shows as a dome with its flat edge at the bottom. The
## recorded gameplay of the original shows exactly that dome in the cup;
## the port used to draw it as an upside-down bowl.
##
## The same method then draws the column art with
## CGContextDrawImage in that same unflipped context, so the scmask_N.png
## texture is upside down too: the column image is the vertical flip of
## (art x mask slice). Built that way here. (The clip rect is the slice
## stretched to (-1,-1,22,252); that sub-pixel stretch is not reproduced.)
func _build_ice() -> void:
	_ice_root = Node2D.new()
	_ice_root.position = ICE_ORIGIN
	# insertSubview:belowSubview:cup (viewDidLoad 0x780B8)
	var cup := outlet("cup")
	if cup is Node2D and (cup as Node2D).get_parent() != null:
		var parent := (cup as Node2D).get_parent()
		parent.add_child(_ice_root)
		parent.move_child(_ice_root, (cup as Node2D).get_index())
	else:
		add_child(_ice_root)

	var mask_tex := _tex(_mask_file)
	var mask_img: Image = mask_tex.get_image() if mask_tex != null else null
	_columns.clear()
	for i in COLUMN_COUNT:
		var x := COLUMN_X0 + COLUMN_PITCH * i
		var art := _tex("scmask_%d.png" % (i + 1))
		if art == null:
			continue
		var img := art.get_image()
		img.convert(Image.FORMAT_RGBA8)
		if mask_img != null:
			# art x upright slice, then the whole column flipped (above).
			for py in img.get_height():
				for px in img.get_width():
					var mx := int(x) + px
					var show := 0.0
					if mx >= 0 and mx < mask_img.get_width() \
							and py < mask_img.get_height():
						show = 1.0 - mask_img.get_pixel(mx, py).r
					if show < 1.0:
						var c := img.get_pixel(px, py)
						c.a *= show
						img.set_pixel(px, py, c)
		img.flip_y()
		var col := Sprite2D.new()
		col.texture = ImageTexture.create_from_image(img)
		col.centered = false
		col.position = Vector2(x, 0)
		col.modulate = Color.WHITE          # resetColors: at initSyrups' end
		_ice_root.add_child(col)
		_columns.append(col)


func _column_rect(i: int) -> Rect2:
	return Rect2(ICE_ORIGIN + Vector2(COLUMN_X0 + COLUMN_PITCH * i, 0),
		Vector2(COLUMN_W, ICE_SIZE.y))


# -- flavour strip ------------------------------------------------------

func _build_strip() -> void:
	_strip = Node2D.new()
	_strip.position = Vector2.ZERO
	# The nib's aScrollView (id3, right above the cup) is where the strip
	# sits in the view order.
	var slot := outlet("aScrollView")
	if slot != null and slot != self:
		slot.add_child(_strip)
	else:
		add_child(_strip)
	_content = Node2D.new()
	_strip.add_child(_content)

	var gray := _tex("sc_syrup_grayscale.png")
	var over := _tex("sc_syrup.png")
	for i in SYRUPS.size():
		var origin := Vector2(BTN_FIRST_X + BTN_PITCH * i, BTN_Y)
		var btn := Node2D.new()
		btn.position = origin
		btn.set_meta("rect", Rect2(origin, BTN_SIZE))
		btn.set_meta("index", i)
		_content.add_child(btn)
		_buttons.append(btn)
		# TintedIV(grayscale, colour, multiply) under the sc_syrup art.
		if gray != null:
			var tint := Sprite2D.new()
			tint.texture = gray
			tint.centered = false
			tint.modulate = SYRUPS[i]
			btn.add_child(tint)
		if over != null:
			var top := Sprite2D.new()
			top.texture = over
			top.centered = false
			btn.add_child(top)
	# setContentSize:(490, 100), setShowsHorizontalScrollIndicator:NO
	# (initSyrups 0x788CC). The vertical indicator (nib default on) never
	# shows -- 100 of content in a 100 / 120-high frame -- so none is built.
	_physics = UIKit.ScrollPhysics.new(_strip_size, Vector2(CONTENT_W, BTN_SIZE.y))
	_physics.name = "UIScrollPhysics"
	_physics.shows_horizontal = false
	add_child(_physics)
	_physics.scrolled.connect(func(o: Vector2) -> void:
		_scroll = -o.x
		_content.position.x = _scroll)


func _show_strip() -> void:
	_strip_shown = true
	_strip.visible = true
	# setCenter:(160,-120) at the current size, then setFrame:(0,0,320,120).
	_strip.position = Vector2(0, STRIP_ENTER_CENTER_Y - _strip_size.y * 0.5)
	_strip_size = STRIP_SIZE
	if _physics != null:
		_physics.set_bounds_size(_strip_size)
	create_tween().tween_property(_strip, "position", STRIP_HOME,
		STRIP_SLIDE).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _hide_strip() -> void:
	_strip_shown = false
	create_tween().tween_property(_strip, "position", STRIP_EXIT,
		STRIP_SLIDE).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# -- the bottle ---------------------------------------------------------

func _build_bottle() -> void:
	_bottle = Node2D.new()
	_bottle.position = BOTTLE_HOME
	_bottle.visible = false
	_bottle_size = BOTTLE_START_SIZE
	add_child(_bottle)
	_bottle_arts.clear()
	for file in ["sc_syrup_grayscale.png", "sc_syrup.png"]:
		var tex := _tex(file)
		if tex == null:
			continue
		var s := Sprite2D.new()
		s.texture = tex
		# Anchored so `rotation` spins about the art's centre, the way the
		# original's per-subview CGAffineTransform does.
		s.centered = true
		s.position = tex.get_size() * 0.5
		_bottle.add_child(s)
		_bottle_arts.append(s)
	if _bottle_arts.size() > 0:
		_bottle_arts[0].modulate = _color


## The bottle's MODEL origin. showBottle:'s fly home (0x7A5C8) is a
## +beginAnimations: block: the bottle stays touchable on the way (touches are
## only eaten by block-API animations, UIKit 0x3307B220), and
## -[TintedIV pointInside:withEvent:] in touchesBegan: (0x7B870) tests the
## model frame -- already (180,0) -- not the drawn one. A grab then kills the
## fly (_set_held), so the drag owns the bottle.
func _bottle_model() -> Vector2:
	if _bottle_tween != null and _bottle_tween.is_running():
		return BOTTLE_HOME
	return _bottle.position


## The TintedIV's frame centre (the art sits at the frame's top-left).
func _bottle_center() -> Vector2:
	return _bottle.position + _bottle_size * 0.5


## flavorClicked: (0x7A390) + showBottle: (0x7A5C8).
## `override` is consumablePurchased:'s currentColor; the normal path takes
## the button's own colour.
func _select_flavor(index: int, override: Color = Color(0, 0, 0, 0)) -> void:
	_color = SYRUPS[index] if override.a == 0.0 else override
	if _bottle_arts.size() > 0:
		_bottle_arts[0].modulate = _color
	_hide_strip()
	_bottle.visible = true
	# setCenter: the button's centre (content coords minus contentOffset)
	# with the bottle's CURRENT frame size -- 32x100 the first time, so the
	# art starts right over the button; 103x206 after that, so it starts
	# up and to the left of it -- then the frame animates to (180,0,103,206).
	var btn_center := STRIP_HOME + Vector2(_scroll, 0) \
		+ Vector2(BTN_FIRST_X + BTN_PITCH * index, BTN_Y) + BTN_SIZE * 0.5
	_bottle.position = btn_center - _bottle_size * 0.5
	_bottle_size = BOTTLE_GRAB_SIZE
	if _bottle_tween != null and _bottle_tween.is_valid():
		_bottle_tween.kill()
	_bottle_tween = create_tween()
	_bottle_tween.tween_property(_bottle, "position", BOTTLE_HOME, BOTTLE_FLY) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## touchesBegan: (0x7B870) / touchesEnded: (0x7BB58).
func _set_held(value: bool) -> void:
	if _held == value:
		return
	_held = value
	for s in _bottle_arts:
		s.rotation = TIP_ROTATION if value else 0.0
	if value:
		# The frame becomes (touch-5, touch+10, 103, 206) -- no unhide, so a
		# grab of the hidden bottle pours invisibly, as on the phone -- and
		# the mystery badge is brought to the front.
		if _bottle_tween != null and _bottle_tween.is_valid():
			_bottle_tween.kill()
		_bottle_size = BOTTLE_GRAB_SIZE
		if _mystery_button != null and _mystery_button.get_parent() == self:
			move_child(_mystery_button, get_child_count() - 1)
	else:
		# Strip returns, bottle hidden WHERE IT WAS LET GO (its frame is not
		# reset; bottlePreviousLocation is written but never read).
		_bottle.visible = false
		_show_strip()


# -- input --------------------------------------------------------------

## A press the GUI did not take: inside the shown strip it is the scroll
## view's (UIKit.ScrollPhysics: a drag after 10 pt, else a tap on the thumb
## under the press); otherwise touchesBegan: grabs the bottle if the press is
## inside its frame -- pointInside: does not care whether the bottle is
## hidden.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if _strip_shown and _physics != null and STRIP_FRAME.has_point(mb.position):
		_tracking = true
		_press_pos = mb.position
		_physics.touch_began(mb.position)
		get_viewport().set_input_as_handled()
	elif _bottle != null \
			and Rect2(_bottle_model(), _bottle_size).has_point(mb.position):
		_set_held(true)
		_bottle.position = mb.position + GRAB_OFFSET
		get_viewport().set_input_as_handled()


## Moves and releases follow the touch wherever it goes (UIKit keeps it on
## the view it began in), so they are read before the GUI can eat them.
func _input(event: InputEvent) -> void:
	if not (_held or _tracking):
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT or mb.pressed:
			return
		if _held:
			_set_held(false)
		elif _tracking:
			_tracking = false
			if _physics.touch_ended(mb.position) and _strip_shown:
				_strip_tap(_press_pos)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _held:
			_bottle.position = mm.position + GRAB_OFFSET
		elif _tracking:
			_physics.touch_moved(mm.position)


## The strip's taps resolve against its MODEL frame: a tap during the 0.5 s
## showSyrups slide (+beginAnimations:"Hide_FlavorSelect" 0x7A734 -- touches
## stay on) lands on the thumb at its final place, as UIKit's hit test reads
## the model. The port used to subtract the drawn, still-sliding position.
func _strip_tap(pos: Vector2) -> void:
	var local: Vector2 = pos - STRIP_HOME - Vector2(_scroll, 0)
	for btn in _buttons:
		var r: Rect2 = btn.get_meta("rect")
		if r.has_point(local):
			_select_flavor(int(btn.get_meta("index")))
			return


# -- the 10Hz loop (0x79660) -------------------------------------------

func _process(delta: float) -> void:
	_accum += delta
	while _accum >= TICK:
		_accum -= TICK
		_loop_tick()


func _loop_tick() -> void:
	if _bottle == null:
		return                # initSyrups (viewDidAppear:) has not run yet
	# deltaTouchX, exactly as 0x79692..0x79764 computes it.
	var cx := _bottle_center().x
	if _held and absf(cx - _last_x) <= STILL_MOVE_LIMIT:
		_still = STILL_CAP if _still > STILL_CAP else _still + 1.0
	else:
		_still = 0.0 if _still < 0.0 else _still - 1.0
	_last_x = cx

	if _held and not _drop_animating and _still >= STILL_NEEDED \
			and _bottle_center().y <= POUR_MAX_CENTER_Y:
		_spawn_drop()
	if _drop_animating and _drop != null and is_instance_valid(_drop) \
			and _drop.visible:
		_tint_columns()


func _spawn_drop() -> void:
	var tex := _tex("lsu_juice_drop_two.png")
	if tex == null:
		return
	_drop = Sprite2D.new()
	_drop.texture = tex
	# TintedIV with no frame ever set: zero-sized, so setCenter: placed its
	# TOP-LEFT. centered=false matches that anchoring.
	_drop.centered = false
	_drop.modulate = _color            # multiply tint (the bottle's tintColor)
	var start := _bottle_center() + DROP_OFFSET
	_drop.position = start
	add_child(_drop)
	# insertSubview:belowSubview:buyMysteryFlavor
	if _mystery_button != null and _mystery_button.get_parent() == self:
		move_child(_drop, _mystery_button.get_index())
	_drop_animating = true
	Audio.play("sc_syrup")
	_drop_tween = create_tween()
	_drop_tween.tween_property(_drop, "position", Vector2(start.x, DROP_LAND_Y),
		DROP_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_drop_tween.tween_callback(_drop_landed)


## animationDidStop "Drop" (0x7BCCC).
func _drop_landed() -> void:
	if _drop != null and is_instance_valid(_drop):
		_drop.queue_free()
	_drop = null
	_drop_animating = false


## The tint pass. UIKit reads a view's model geometry during an animation,
## so the original's hit point is the drop's LANDING spot from the moment
## the fall starts: top-left (spawn.x, 320), probed at +(15,15)+(0.5,0.5).
func _tint_columns() -> void:
	# The 1x1 probe rect at drop centre + (15,15), tested with
	# CGRectIntersectsRect against each column's frame in view coords.
	var probe := Rect2(Vector2(_drop.position.x, DROP_LAND_Y) + Vector2(15, 15),
		Vector2(1, 1))
	# (While falling, _drop.position animates; its x never changes, so the
	# model x is the live x. y is pinned to the landing value.)
	var px := probe.position.x + 0.5
	for i in _columns.size():
		var rect := _column_rect(i)
		if not rect.intersects(probe):
			continue
		var col_x := rect.position.x + rect.size.x * 0.5
		# distanceBetweenPt:(col_x, 0) andPt:(px, 0) -- x only.
		var d := absf(col_x - px)
		var t := (d / DIST_DIV if d < DIST_NEAR else T_FAR) + T_BASE
		var mixed := _mix(_quantise(_columns[i].modulate), _color, t)
		_columns[i].modulate = mixed
		# Spread outward, on the side of the drop the column sits.
		if col_x < px:
			_spread(mixed, t, i, -1)
		elif px < col_x:
			_spread(mixed, t, i, +1)


## The neighbour loops of 0x79660: walk outward from the hit column,
## re-mixing each column against the running colour, with the column's own
## share w growing by w += (1-w)*0.4 each step. (Both loops start at the
## hit column itself, where the mix is a no-op.)
func _spread(carried: Color, w: float, from: int, step: int) -> void:
	var j := from
	while j >= 0 and j < _columns.size():
		var cur := _quantise(_columns[j].modulate)
		var mixed := _mix(cur, carried, w)
		_columns[j].modulate = mixed
		carried = mixed
		w = w + (1.0 - w) * SPREAD_GROW
		j += step


## t of the current colour, (1-t) of the target.
static func _mix(current: Color, target: Color, t: float) -> Color:
	return Color(
		t * current.r + (1.0 - t) * target.r,
		t * current.g + (1.0 - t) * target.g,
		t * current.b + (1.0 - t) * target.b)


## The original reads the current colour back through a 1x1 RGBA8 bitmap,
## so it arrives on 1/255 steps; reproduced for fidelity.
static func _quantise(c: Color) -> Color:
	return Color(roundi(c.r * 255.0) / 255.0, roundi(c.g * 255.0) / 255.0,
		roundi(c.b * 255.0) / 255.0)


# -- actions ------------------------------------------------------------

## resetColors: (0x7A230): every real column back to white; the button
## sound only when it came from the btn_new_design button (the self-call at
## initSyrups' end is silent).
func _on_resetColors() -> void:
	Audio.play("button_press")
	_reset_colors()


## resetColors:'s loop: changeColor:whiteColor on columns 1..31 (index 0 of
## IceView.columns is a placeholder the loop skips; the port has no such
## slot).
func _reset_colors() -> void:
	for col in _columns:
		col.modulate = Color.WHITE


## nextClick: (0x7ADB4): bakes the coloured columns + cup into the
## MakeViewController info dict (classStr "SNOW_CONE" 0x6BAC04). The make
## screen gets everything it needs to rebuild those two
## images as GameState metadata.
func _on_nextClick() -> void:
	Audio.play("button_press")
	if _held:
		_set_held(false)
	if _tracking and _physics != null:
		_physics.touch_cancelled()
	_tracking = false
	if _bottle != null:
		_bottle.visible = false
	# The two baked items, exactly as nextClick: (0x7ADB4) fills the
	# customCategories dict the Make screen reads (the port used to send
	# only the properties, so the decorate and eat
	# screens showed nothing):
	#   SnowCone: a mask-sized (300x250) context, CTM flipped so
	#     CGContextDrawImage comes out upright, each column's image (its
	#     colour already multiplied in by changeColor: 0x15F7C) drawn at
	#     ((i-1)*10-10, 0, 20, 250) for i = 1..31; IsEdible, ViewIndex 2,
	#     Type Stationary, ItemCenter (10, 100).
	#   snowConeCup: the cup art drawn into a 330x295 context at
	#     (0,0,330,295); not edible, ViewIndex 5, ItemCenter (-5, 332).
	var out := {}
	var ice_img := Image.create(int(ICE_SIZE.x), int(ICE_SIZE.y), false, Image.FORMAT_RGBA8)
	ice_img.fill(Color(0, 0, 0, 0))
	for i in _columns.size():
		var col: Sprite2D = _columns[i]
		if col.texture == null:
			continue
		var cimg: Image = col.texture.get_image()
		cimg.convert(Image.FORMAT_RGBA8)
		var tint: Color = col.modulate
		if tint != Color.WHITE:
			for py in cimg.get_height():
				for px in cimg.get_width():
					var c := cimg.get_pixel(px, py)
					cimg.set_pixel(px, py, Color(c.r * tint.r, c.g * tint.g, c.b * tint.b, c.a * tint.a))
		var x := int(COLUMN_X0 + COLUMN_PITCH * i)
		ice_img.blend_rect(cimg, Rect2i(0, 0, cimg.get_width(), cimg.get_height()), Vector2i(x, 0))
	out["SnowCone"] = {
		"Properties": {"IsEdible": true, "ViewIndex": 2, "Type": "Stationary",
			"ItemCenterX": 10.0, "ItemCenterY": 100.0},
		"Image": ImageTexture.create_from_image(ice_img),
	}
	var cup_tex := _tex(_cup_file)
	if cup_tex != null:
		var cup_img: Image = cup_tex.get_image()
		cup_img.convert(Image.FORMAT_RGBA8)
		cup_img.resize(330, 295, Image.INTERPOLATE_BILINEAR)   # drawn into (0,0,330,295)
		out["snowConeCup"] = {
			"Properties": {"IsEdible": false, "ViewIndex": 5, "Type": "Stationary",
				"ItemCenterX": -5.0, "ItemCenterY": 332.0},
			"Image": ImageTexture.create_from_image(cup_img),
		}
	GameState.custom_categories = out
	Nav.next()


## backClick: (0x7ABDC): same bottle cleanup, then pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	if _held:
		_set_held(false)
	Nav.back()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
