# Kettle Corn step 3 -- pick a sugar flavour from the drop-down grid, then
# tilt the sugar packet to pour it into the pot.
#
# GROUNDED from initWithNibName:bundle: (0x10BFA8, colour table verified
# against the raw disassembly -- see COLORS), viewDidLoad (0x10C6E0),
# viewWillAppear: (0x10CD20), screenSetup (0x10CFE8), showSugarBag: (0x10D608),
# selectFlavorButtonClick: (0x10DA10), categoryButtonClick: (0x10DBC0),
# showScrollView (0x10DDE0), hideScrollView (0x10E65C),
# accelerometer:didAccelerate: (0x10E7C8), sugarTick (0x10F784),
# animationDidStop:finished:context: (0x10FB8C), nextClick: (0x110070),
# backClick: (0x110000) and viewWillDisappear: (0x10CE18).
#
# THE POUR IS ACCELEROMETER TILT here, and the accelerometer is genuinely
# live: screenSetup and selectFlavorButtonClick: both reference the
# startAccelerometer selref (0x7872D0). The filtered device x (k = 0.05 at
# 1/30s, 0x10EB60 interval 0x3FA1111120000000) drives the packet's baseIV
# rotation, clamped to [-2.1817, -0.2618]; sugar pours while the angle is at
# the clamp bottom, a colour is selected and pourTime < 4. In the port that
# becomes press-and-hold on the packet, exactly as kcPourOil's box: the
# packet animates to the clamp-bottom angle and the same 0.1s sugarTick
# accumulator runs. Only the 0.35s tilt-in/out time is a port choice.
#
# The accelerometer is stopped by showScrollView and restarted ONLY by
# selectFlavorButtonClick: (and screenSetup) -- closing the picker with the
# tab, or buying a mystery flavour after doing so, leaves the packet unable
# to pour until a flavour cell is picked. _accel_on mirrors that.
#
# NEXT: this class's changeInstruction: (0x11088C) ends
# with `nextButton setHidden:YES`, and screenSetup and every showSugarBag:
# call it. So next is hidden on appearance, hidden again by every selection
# (and by re-opening the picker, whose showSugarBag:clearColor resets
# pourTime and donePouringSugar), and sugarTick's tail shows it once a pour
# completes (donePouringSugar && nextButton.isHidden -> showNextButton).
#
# DEAD CODE, not ported, with addresses:
#  * popcornTick (0x10EFCC) and the pop_01..pop_04 players screenSetup builds:
#    the popcornTick selref (0x788AB4) is referenced ONLY by kcShakeToColor's
#    viewWillAppear (0x111778). This screen's popcornTimer is invalidated in
#    viewWillDisappear but never scheduled -- no corn pops here.
#  * The mystery-flavour consumable (viewDidLoad 0x10C6E0 builds it at centre
#    (50, 349)) and the locked-flavour path (contentLocked, lockedFlavor-
#    ButtonClicked: 0x10DC1C): under FF_KEY_EVERYTHING -- the port's permanent
#    state -- contentLocked is false and IAP is suppressed (Screen policy).
#  * startBurner (0x10DA0C) is `bx lr`.

extends "res://core/Screen.gd"

const kcPourOil := preload("res://screens/kcPourOilViewController.gd")
const kcKit := preload("res://screens/kcKit.gd")
## The picker's UIScrollView: UIKit's own drag / deceleration /
## bounce physics and scroll indicator (kcScrollView.gd header).
const ScrollView := preload("res://screens/kcScrollView.gd")

## What the last making step hands kcShakeToColor initWithColor: (the original
## threads it through the initialiser; the port parks it here, the same
## pattern as lsuSliceFruitViewController's statics). Alpha 0 stands for the
## original's nil UIColor -- showScrollView resets to nil, and a nil tint
## leaves art unchanged, which is also what bake_tint does with alpha 0.
static var selected_color := Color(0, 0, 0, 0)


## The 33 colours of initWithNibName:bundle: (0x10BFA8), in order, built with
## colorWithHue:saturation:brightness:alpha:. The CGFloat args of three of
## the calls were read from the raw Thumb disassembly:
##   index 11 at 0x10C368  movt r2,#0x3E90 -> (0.28125, 0.3, 1, 1)
##   index 17 at 0x10C446  movt r2,#0x3EF0 -> (0.46875, 0.3, 1, 1)
##   index 28 at 0x10C5FA  movt r2,#0x3F58 -> (0.84375, 0.3, 1, 1)
## Hue steps are 0.09375 = 3/32 (0x3DC00000 and multiples); the recurring
## triple per hue is (s=0.3, v=1) light / (1, 1) full / (1, 0.7, a=0.7) dark.
## Index 1 is +[UIColor brownColor] = (0.6, 0.4, 0.2, 1).
static var COLORS: Array[Color] = _build_colors()

static func _build_colors() -> Array[Color]:
	var out: Array[Color] = [
		Color.from_hsv(0.0, 1.0, 1.0),        # 0  red
		Color(0.6, 0.4, 0.2),                 # 1  brownColor
		Color.from_hsv(0.65625, 1.0, 1.0),    # 2  blue, out of sequence
		Color.from_hsv(0.0, 0.3, 1.0),
		Color.from_hsv(0.0, 1.0, 0.7, 0.7),
	]
	# Hues 0.09375 .. 0.84375 in 3/32 steps, light / full / dark -- except
	# 0.65625, whose full entry already sits at index 2.
	for i in range(1, 10):
		var h := i * 0.09375
		out.append(Color.from_hsv(h, 0.3, 1.0))
		if not is_equal_approx(h, 0.65625):
			out.append(Color.from_hsv(h, 1.0, 1.0))
		out.append(Color.from_hsv(h, 1.0, 0.7, 0.7))
	out.append(Color(1, 1, 1))                # 31 whiteColor
	out.append(Color(0, 0, 0))                # 32 blackColor
	return out


# -- construction (viewDidLoad 0x10C6E0) --------------------------------

## sugarBag: TintedIV(kc_sugar_packet, clear, blend 5=Lighten), setCenter
## (240, 60) -- ZERO-FRAME TintedIV, so that places the 78x93 art's TOP-LEFT.
## The kc_sugar_packet_text overlay is a subview of baseIV centred at the
## art's centre; the accelerometer transform rotates baseIV about that same
## centre, so bag + text pivot together at home + (39, 46.5).
const BAG_HOME := Vector2(240, 60)            # 0x43700000 / 0x42700000
## showSugarBag: parks the bag +300 px right (VLDR S0, =300.0 at 0x10D682;
## was 299 here) and slides it home, "MoveSugar", 0.3s (0x3FD3333333333333),
## curve 1 (ease-in). Its completion (0x10FB8C) clears isSugarBagAnimating.
const BAG_PARK_OFFSET_X := 300.0
const BAG_SECONDS := 0.3
## sugarPile: MaskedIV(kc_sugar_pile, kc_mask), centre (160, 293) -- a true
## centre, the same pot window as kcPourOil. showSugarBag: rebases it at
## (95, 148) (MOVT R2,#0x42BE / MOVT R3,#0x4314 at 0x10D7D4; was 148.5 here)
## with a ColorBurn-baked pile. With the mask applied upside down (see
## kcPourOil.MaskedIV) the window's paint rows are 0..138, so the pile starts
## hidden and climbs into view as sugar lands.
const PILE_CENTER := Vector2(160, 293)        # 0x43200000 / 0x43928000
const PILE_ORIG := Vector2(95, 148)
## Each sugarTick raises the pile by baseImg.height * 0.025 (0x3CCCCCCD).
const PILE_RISE_FRACTION := 0.025

# -- the picker (showScrollView 0x10DDE0) --------------------------------

## 3 columns: button frames (100*col + 24, 100*row + 62, 80, 80)
## (0x42A00000 = 80). Inside each: the Lighten-baked Flavor_Mix_Back at
## (10, 10, 60, 60) and kc_sugar_packet_text at 50x50 centred on (40, 40).
const CELL_X0 := 24.0
const CELL_Y0 := 62.0
const CELL_PITCH := 100.0
const CELL_SIZE := 80.0
const SWATCH_RECT := Rect2(10, 10, 60, 60)    # 0x41200000 / 0x42700000
const CELL_TEXT_SIZE := 50.0                  # 0x42480000, centred at 40,40
## contentSize = (320, 100 * (rows) + 124), from the running
## setContentSize:(320, 100*(row+1)+124) in the build loop.
const CONTENT_EXTRA := 124.0
## The scroll view slides between centre offset -500 (0xC3FA0000) and home,
## 0.25s, curve 2 (ease-out).
const PANEL_OFFSET_Y := -500.0
const PANEL_SLIDE := 0.25
## Nib aScrollView frame (0,0,320,480); no indicator / bounce / rate keys,
## so the nib defaults hold: bounces YES, decelerationRate 0.998, both
## indicators on (the vertical one shows: 1224 of content in 480).
const PANEL_FRAME := Rect2(0, 0, 320, 480)
## PORT CHOICE (pre-existing): the mouse wheel steps the list half a row;
## iOS has no wheel. Clamped, no physics.
const WHEEL_STEP := 50.0

# -- the pour (accelerometer:didAccelerate: 0x10E7C8) --------------------

## angle = clamp(filteredX * 6, -2.1817, -0.2618); pours while
## angle <= -2.18166156 && pourTime < 4 && selectedColor != nil -- only at
## the clamp bottom itself.
const REST_ROTATION := -0.2618                # assignment literal
const POUR_ROTATION := -2.1817                # assignment literal (clamp bottom)
const POUR_THRESHOLD := -2.18166156
## PORT CHOICE: the 0.35s tilt animation time, as kcPourOil.
const TILT_SECONDS := 0.35
## spoutTop = sugarBag.center + (sin(a)*115 + 80, cos(a)*(-45) + 60), where
## "center" of the zero-frame TintedIV is its top-left, BAG_HOME.
const SPOUT_SIN_K := 115.0
const SPOUT_X_OFF := 80.0
const SPOUT_COS_K := -45.0
const SPOUT_Y_OFF := 60.0

# -- sugarTick (0x10F784), every 0.1s (0x3FB99999A0000000) ---------------

const SUGAR_TICK := 0.1
const POUR_TIME_STEP := 0.1                   # 0x3DCCCCCD
const POUR_TIME_FULL := 4.0
## Powder: UIImageView(sugarPowder) at half size; its layer position rides a
## CAKeyframeAnimation along MoveTo(spoutTop) + QuadCurveTo(cp (200, 196),
## end (160, 320)), 0.5s, removed 0.5s later. Calculation mode is
## kCAAnimationCubic; on a single quad segment the port evaluates the quad
## bezier with uniform parameter, which is the same curve.
const POWDER_SCALE := 0.5
const POWDER_CP := Vector2(200, 196)
const POWDER_END := Vector2(160, 320)
const POWDER_SECONDS := 0.5

var _bag_root: Node2D
var _bag_pivot: Node2D
var _bag_sprite: Sprite2D
var _pile: kcPourOil.MaskedIV
var _powder_tex: Texture2D
var _panel: Node2D                            # the outlet, kept for clarity
var _clip: Sprite2D                           # the scroll view's bounds clip
var _content: Node2D
var _cells: Array = []                        # {rect: Rect2, index: int}
var _content_h := 0.0
var _sv: Node                                 # kcScrollView (aScrollView)
var _picker_open := false
var _bag_animating := false
## The accelerometer delegate: set by screenSetup / selectFlavorButtonClick:,
## cleared by showScrollView (stopAccelerometer).
var _accel_on := false
var _holding := false
var _tilt_tween: Tween
var _was_pouring := false
var _pour_time := 0.0
var _done := false
var _tick_accum := 0.0

## Mystery flavour (ported):
##   initWithNibName: 0x10BFA8  Consumable DM_CONSUMABLE_MYSTERY_FLAVOR /
##     MysteryFlavor_30Flavor, cost = CoinCosts."Kettle Corn".MysteryFlavor,
##     6 when absent; first-time message.
##   viewDidLoad 0x10C6E0  ConsumableButton(btn_mystery_flavor, (0,-25) /
##     (65,3)) at centre (50, 350.5); buyMysteryFlavorClick:; buyAllBtn hidden.
##   buyMysteryFlavorClick: 0x10FF94  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x10FCE4  quantity 0, setSelectedColor: a random
##     colour (see mystery_color), showSugarBag:. The picker is NOT hidden.
##   consumablePurchaseFailed:error:2 0x10FEC0  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_FLAVOR"
const MYSTERY_NAME := "MysteryFlavor_30Flavor"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery flavor! You never know what flavor it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_flavor.png"
const MYSTERY_CENTER := Vector2(50, 350.5)

var _mystery: RefCounted
var _mystery_button: TextureButton
var _lid_home := Vector2.ZERO
var _bubbler: kcPourOil.OilBubbler
## Every tween this screen starts (kcKit.track / settle, keep-state).
var _tweens: Array = []
## Cell swatches are per-pixel bakes; 33 of them are slow in GDScript, so the
## first build is cached. The colour list is fixed, so this changes nothing.
static var _swatch_cache: Array = []


func on_enter() -> void:
	_build_bag()
	_build_pile()
	_panel = outlet("aScrollView") as Node2D
	if _panel != null:
		_panel.visible = false
		# UIScrollView clips to its (0, 0, 320, 480) bounds, which ride along
		# with the slide -- without this the 1224px-tall grid's lower half
		# stays on screen at offset -500. Same idiom as lsu's stream box.
		var img := Image.create(320, 480, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_clip = Sprite2D.new()
		_clip.texture = ImageTexture.create_from_image(img)
		_clip.centered = false
		_clip.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
		_panel.add_child(_clip)
		_sv = ScrollView.new()
		_sv.name = "aScrollViewSim"
		add_child(_sv)
		_sv.call("configure", true, PANEL_FRAME, 0.0)
		_sv.call("add_indicator", _clip, Rect2(Vector2.ZERO, PANEL_FRAME.size))
		_sv.connect("tapped", _on_cell_tapped)
	_build_mystery()
	# lidOriginalCenter (viewDidLoad): screenSetup puts the lid back here
	# before every MoveLid.
	var lid := outlet("lid") as Sprite2D
	if lid != null:
		_lid_home = lid.position
	_bubbler = kcPourOil.OilBubbler.new(outlet("oil") as Sprite2D)
	add_child(_bubbler)
	# viewWillAppear: (0x10CD20): startBurner (a no-op) after 0.5s, then
	# screenSetup.
	_screen_setup()
	set_process(true)


## Back from kcShakeToColor: the same instance; viewWillAppear: runs
## screenSetup again -- selection cleared, packet hidden, pile reset by
## showSugarBag:clearColor, next hidden, the lid back on and lifted off.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	kcKit.drop_coin_panel(self)
	_screen_setup()


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


## consumablePurchased: (0x10FCE4): setSelectedColor: + showSugarBag:.
func _on_mystery_purchased(_free: bool) -> void:
	var color := mystery_color()
	_show_sugar_bag(color)
	selected_color = color


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## viewDidLoad: TintedIV bag + text overlay, inserted below aScrollView.
func _build_bag() -> void:
	var bag_tex := _tex("kc_sugar_packet.png")
	if bag_tex == null:
		return
	_bag_root = Node2D.new()
	_bag_root.position = BAG_HOME
	_bag_pivot = Node2D.new()
	_bag_pivot.position = bag_tex.get_size() * 0.5      # baseIV centre
	_bag_pivot.rotation = REST_ROTATION                 # accel clamp at rest
	_bag_root.add_child(_bag_pivot)
	_bag_sprite = Sprite2D.new()
	_bag_sprite.texture = bag_tex
	_bag_sprite.centered = true
	_bag_pivot.add_child(_bag_sprite)
	var text := Sprite2D.new()
	text.texture = _tex("kc_sugar_packet_text.png")
	text.centered = true                                # centred on baseIV
	_bag_pivot.add_child(text)
	add_child(_bag_root)
	var scroll := outlet("aScrollView")
	if scroll != null and scroll != self:
		move_child(_bag_root, scroll.get_index())       # belowSubview:
	_bag_root.visible = false


func _build_pile() -> void:
	_pile = kcPourOil.MaskedIV.new(_tex("kc_sugar_pile.png"), _tex("kc_mask.png"),
		true)
	_pile.set_center(PILE_CENTER)
	add_child(_pile)
	var oil := outlet("oil")
	if oil != null and oil != self:
		move_child(_pile, oil.get_index())              # belowSubview:oil


## screenSetup (0x10CFE8).
func _screen_setup() -> void:
	_accel_on = true                                    # startAccelerometer
	_show_sugar_bag(Color(0, 0, 0, 0))
	selected_color = Color(0, 0, 0, 0)
	if _bag_root != null:
		_bag_root.visible = false
	_pour_time = 0.0
	_done = false
	_set_holding(false)
	_was_pouring = false
	change_instruction("inst_select_sugar_kc.png")
	# bubbleTimer 0.2s and sugarTimer 0.1s: fresh timers.
	if _bubbler != null:
		_bubbler.restart()
	_tick_accum = 0.0
	# nextButton: hidden by the two changeInstruction: calls above.
	# MoveLid: the lid jumps to lidOriginalCenter and flies up and off to
	# centre (160, -height), 0.5s ease-in, lid_05 alongside; no completion
	# branch exists for it here.
	var lid := outlet("lid") as Sprite2D
	if lid != null:
		lid.position = _lid_home
		var size: Vector2 = lid.texture.get_size() * lid.scale
		_tween().tween_property(lid, "position",
			Vector2(160.0, -size.y) - size * 0.5, 0.5) \
			.set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_IN))
	Audio.play("lid_05")
	Audio.loop("frying_lo_loop", linear_to_db(0.5))     # volume 0x3F000000
	if _mystery_button != null:
		_mystery_button.visible = true                  # setHidden:NO


# -- showSugarBag: (0x10D608) -------------------------------------------

func _show_sugar_bag(color: Color) -> void:
	if _bag_root == null:
		return
	_bag_animating = true
	_bag_root.position.x += BAG_PARK_OFFSET_X
	_bag_root.visible = true
	var t := _tween()
	t.tween_property(_bag_root, "position", BAG_HOME, BAG_SECONDS) \
		.set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_IN))
	t.tween_callback(func() -> void: _bag_animating = false)   # "MoveSugar"
	# changeColor: -- the Lighten-5 bake from init. Alpha 0 leaves the art
	# unchanged, which is also the original's clearColor result.
	_bag_sprite.texture = kcPourOil.bake_tint(_tex("kc_sugar_packet.png"), color, 5)
	# The pile becomes the ColorBurn-baked art at (95, 148).
	_pile.set_base_orig_pt(PILE_ORIG)
	_pile.set_base_texture(kcPourOil.bake_tint(_tex("kc_sugar_pile.png"), color, 7))
	# sugarPowder: ColorBurn-baked sugar2.png, used by every tick's spawn.
	_powder_tex = kcPourOil.bake_tint(_tex("sugar2.png"), color, 7)
	_done = false
	_pour_time = 0.0
	change_instruction("inst_pour.png")


# -- the picker ---------------------------------------------------------

## categoryButtonClick: (0x10DBC0) -- the invisible tab at (104, -1, 112, 61).
func _on_categoryButtonClick() -> void:
	Audio.play("button_press")
	_show_scroll_view()


## showScrollView (0x10DDE0); doubles as the toggle.
func _show_scroll_view() -> void:
	if _picker_open:
		_hide_scroll_view()
		return
	if _panel == null:
		return
	_accel_on = false                         # stopAccelerometer
	_set_holding(false)
	_set_nav_dimmed(true)
	_show_sugar_bag(Color(0, 0, 0, 0))
	selected_color = Color(0, 0, 0, 0)
	if _bag_root != null:
		_bag_root.visible = true              # setHidden:NO comes first ...
		_bag_root.visible = false             # ... then setHidden:YES
	Audio.stop("sugar_03")
	_build_cells()
	# The scroll view snaps to centre offset -500 and eases home; its
	# contentOffset is NOT reset, matching the original.
	_panel.position = Vector2(0, PANEL_OFFSET_Y)
	_panel.visible = true
	_tween().tween_property(_panel, "position", Vector2.ZERO, PANEL_SLIDE) \
		.set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_OUT))
	_picker_open = true


## hideScrollView (0x10E65C).
func _hide_scroll_view() -> void:
	if not _picker_open:
		return
	_set_nav_dimmed(false)
	_panel.position = Vector2.ZERO
	_tween().tween_property(_panel, "position",
		Vector2(0, PANEL_OFFSET_Y), PANEL_SLIDE) \
		.set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_OUT))
	_picker_open = false


## showScrollView zeroes next/back/buyMystery alphas; hideScrollView restores
## them. Alpha-0 UIViews take no touches, so the port disables alongside.
## (A hidden next stays hidden: alpha and hidden are separate properties.)
func _set_nav_dimmed(dimmed: bool) -> void:
	var views: Array = [outlet("nextButton"), outlet("backButton"),
		_mystery_button]
	for n in views:
		if n != null and n != self and n is CanvasItem:
			(n as CanvasItem).modulate.a = 0.0 if dimmed else 1.0
			n.set("disabled", dimmed)


## The cell grid, rebuilt on every open exactly as the original does (it
## strips the scroll view's subviews first). Swatch bakes are cached.
func _build_cells() -> void:
	if _content != null:
		_content.queue_free()
	_content = Node2D.new()
	_clip.add_child(_content)
	_cells.clear()

	if _swatch_cache.size() != COLORS.size():
		_swatch_cache.clear()
		var mix := _tex("Flavor_Mix_Back.png")
		for c: Color in COLORS:
			_swatch_cache.append(kcPourOil.bake_tint(mix, c, 5))

	var bg_tex := _tex("Sub_Button_Background.png")
	var text_tex := _tex("kc_sugar_packet_text.png")
	var row := 0
	for i in COLORS.size():
		var col := i % 3
		var origin := Vector2(CELL_PITCH * col + CELL_X0, CELL_PITCH * row + CELL_Y0)
		if bg_tex != null:
			var bg := Sprite2D.new()
			bg.texture = bg_tex
			bg.centered = false
			bg.position = origin
			bg.scale = Vector2(CELL_SIZE, CELL_SIZE) / Vector2(bg_tex.get_size())
			_content.add_child(bg)
		var swatch: Texture2D = _swatch_cache[i]
		if swatch != null:
			var s := Sprite2D.new()
			s.texture = swatch
			s.centered = false
			s.position = origin + SWATCH_RECT.position
			s.scale = SWATCH_RECT.size / Vector2(swatch.get_size())
			_content.add_child(s)
		if text_tex != null:
			var t := Sprite2D.new()
			t.texture = text_tex
			t.centered = true
			t.position = origin + Vector2(CELL_SIZE, CELL_SIZE) * 0.5
			t.scale = Vector2(CELL_TEXT_SIZE, CELL_TEXT_SIZE) \
				/ Vector2(text_tex.get_size())
			_content.add_child(t)
		_cells.append({"rect": Rect2(origin, Vector2(CELL_SIZE, CELL_SIZE)),
			"index": i})
		_content_h = CELL_PITCH * (row + 1) + CONTENT_EXTRA
		if col == 2:
			row += 1
	# setContentSize: in the loop; the offset is kept from the last opening.
	if _sv != null:
		_sv.call("set_content_length", _content_h)
		_sv.set("content", _content)


## selectFlavorButtonClick: (0x10DA10). (Its startAccelerometer becomes the
## hold arm being available; the locked branch is unreachable in the port.)
func _flavor_clicked(index: int) -> void:
	_accel_on = true                          # startAccelerometer
	Audio.play("button_press")
	_hide_scroll_view()
	var color: Color = COLORS[index]
	_show_sugar_bag(color)
	selected_color = color


# -- input: picker scroll/tap, and the press-and-hold -------------------

func _unhandled_input(event: InputEvent) -> void:
	if _picker_open:
		_picker_input(event)
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		if _accel_on and _bag_root != null and _bag_root.visible \
				and _bag_hit_rect().has_point(mb.position):
			_set_holding(true)
			get_viewport().set_input_as_handled()
	elif _holding:
		_set_holding(false)


## The packet's unrotated art frame -- (240, 60, 78, 93). The original had no
## touch here at all (tilt); the port makes the visible packet the target.
func _bag_hit_rect() -> Rect2:
	return Rect2(BAG_HOME, _bag_sprite.texture.get_size())


## The open picker: the scroll view takes the touches (drag, flick, tap).
func _picker_input(event: InputEvent) -> void:
	if _sv == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP
				or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var step := -WHEEL_STEP if mb.button_index == MOUSE_BUTTON_WHEEL_UP \
				else WHEEL_STEP
			var hi: float = maxf(_content_h - PANEL_FRAME.size.y, 0.0)
			_sv.call("set_offset", clampf(float(_sv.call("get_offset")) + step, 0.0, hi))
			return
	if _sv.call("handle_input", event):
		get_viewport().set_input_as_handled()


## A touch that never became a drag reaches the cell under it (the button's
## touchUpInside: the release must stay within its bounds + 70 pt).
func _on_cell_tapped(press: Vector2, release: Vector2) -> void:
	for cell in _cells:
		var r: Rect2 = cell["rect"]
		if r.has_point(press):
			if ScrollView.release_inside(r, release):
				_flavor_clicked(int(cell["index"]))
			return


func _set_holding(value: bool) -> void:
	if _holding == value:
		return
	_holding = value
	if _bag_pivot != null:
		# One tilt tween at a time: a press during the return swing restarts
		# from the current angle instead of fighting the old tween.
		if _tilt_tween != null and _tilt_tween.is_valid():
			_tilt_tween.kill()
		_tilt_tween = _tween()
		_tilt_tween.tween_property(_bag_pivot, "rotation",
			POUR_ROTATION if value else REST_ROTATION, TILT_SECONDS) \
			.set_trans(Tween.TRANS_SINE)


func _has_selection() -> bool:
	return selected_color.a > 0.0


## 0x10E7C8's gate: angle at the clamp bottom, a colour picked, time left.
## (isSugarBagAnimating is sugarTick's own extra guard, not part of this.)
func _is_pouring() -> bool:
	return _accel_on and _has_selection() and _pour_time < POUR_TIME_FULL \
		and _bag_pivot != null and _bag_pivot.rotation <= POUR_THRESHOLD


## spoutTop (0x10E7C8): of the TintedIV "center", i.e. the art's top-left.
func _spout_top() -> Vector2:
	var a: float = _bag_pivot.rotation
	return _bag_root.position + Vector2(
		sin(a) * SPOUT_SIN_K + SPOUT_X_OFF,
		cos(a) * SPOUT_COS_K + SPOUT_Y_OFF)


# -- sugarTick (0x10F784) -----------------------------------------------

func _process(delta: float) -> void:
	var pouring := _is_pouring()
	if pouring != _was_pouring:            # the accel handler's sound edges
		_was_pouring = pouring
		if pouring:
			Audio.loop("sugar_03")
		else:
			Audio.stop("sugar_03")
	_tick_accum += delta
	while _tick_accum >= SUGAR_TICK:
		_tick_accum -= SUGAR_TICK
		_sugar_tick()


func _sugar_tick() -> void:
	if _is_pouring() and not _bag_animating:
		_spawn_powder()
		_pour_time = kcKit.f32(_pour_time + kcKit.f32(POUR_TIME_STEP))
		if _pour_time >= POUR_TIME_FULL:
			_done = true
		else:
			var rise: float = _pile.base_size().y * PILE_RISE_FRACTION
			_pile.set_base_orig_pt(_pile.get_base_orig_pt() - Vector2(0, rise))
	# The tail: donePouringSugar && nextButton hidden -> showNextButton.
	if _done:
		var n := outlet("nextButton")
		if n != null and n != self and not (n as CanvasItem).visible:
			show_next_button()
			n.set("disabled", false)


func _spawn_powder() -> void:
	if _powder_tex == null:
		return
	var p := Sprite2D.new()
	p.texture = _powder_tex
	p.centered = true
	p.scale = Vector2(POWDER_SCALE, POWDER_SCALE)
	var p0 := _spout_top()
	p.position = p0
	add_child(p)                              # addSubview to the root view
	var t := _tween()
	t.tween_method(func(u: float) -> void:
		if is_instance_valid(p):
			var v := 1.0 - u
			p.position = p0 * v * v + POWDER_CP * 2.0 * v * u \
				+ POWDER_END * u * u,
		0.0, 1.0, POWDER_SECONDS)
	t.tween_callback(p.queue_free)            # removeFromSuperview at 0.5s


# -- navigation ---------------------------------------------------------

## nextClick: (0x110070): button_press, push kcShakeToColor initWithColor:
## selectedColor -- carried by the static above.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.next()


## backClick: (0x110000).
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


func on_exit() -> void:
	# viewWillDisappear: (0x10CE18): stopAccelerometer; bubbleTimer,
	# popcornTimer and sugarTimer invalidated (the port's accumulator stops
	# with the node out of the tree; screenSetup resets it); frying_lo_loop
	# and sugar_03 stopped; the five pop players stopped (never played here).
	# Powder and slides in flight complete while covered (settled).
	_accel_on = false
	_holding = false
	kcKit.settle(_tweens)
	if _sv != null:
		_sv.call("settle")            # a flick in flight lands while covered
	if _bubbler != null:
		_bubbler.restart()
	Audio.stop("frying_lo_loop")
	Audio.stop("sugar_03")


func _tween() -> Tween:
	return kcKit.track(_tweens, create_tween())


## This screen's changeInstruction: hides nextButton (read from the
## binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
