# Cotton candy step 1 -- pick up to four sugar flavours, then hold the big
# red button to spray them into the machine until the gauge fills.
#
# GROUNDED from initWithNibName:bundle: (0x81BCC), initializeSugarPicker
# (0x81220), viewDidLoad (0x83020), viewWillAppear: (0x834D4), resetScreen
# (0x804C8), sugarButtonClicked: (0x836B8), open/closeSugarPickerSlider
# (0x80DF8 / 0x81068), sugarPickerDidSlideUp (0x837B4), flavorButtonClicked:
# (0x837EC), addSugar:color: (0x83ABC), spraySugarTouchDownInside: (0x83C00),
# spraySugarReleased: (0x83BC4), startSugarFall: (0x80AE8), stopSugarFall
# (0x80898), progressBarIncrease (0x80948), showNextButton (0x806D0),
# -[ccSugarFall initWithFlavor:] (0x84D30), -[TintedIV changeColor:]
# (0x47304), -[MaskedIV initWithBaseImg:andMaskImg:] / drawRect: (0x46CE0 /
# 0x46E68), unlockIAPIfNeed (0x81A28), consumablePurchased: (0x8402C),
# skipClick: (0x846B8), backClick: (0x84520) and nextClick: (0x845C4).
# Kept under a push, with the viewWillAppear: reset on return and no
# instruction slide.
#
# Port policy notes:
#  * unlockIAPIfNeed (0x81A28): under FF_KEY_EVERYTHING -- the port's
#    permanent state -- lockedFlavors is emptied and the picker rebuilt, so
#    every flavour is unlocked and the locked-cell art path
#    (Sub_Button_Background_Locked + black_lock, lockedFlavorButtonClicked:
#    0x80D34) can never build. It is therefore not ported.
#  * The mystery-flavour consumable is a coin consumable, not an IAP, and is
#    ported (see the block below).
#  * Nothing here counts touchesMoved: events. The only drag is the picker's
#    scroll, which tracks the absolute offset from the press, so it needs no
#    Screen.accept_touch_move() gate.
#  * The picker is a real
#    UIScrollView (UIKit.ScrollPhysics): 300x377 bounds, the content view's
#    300x584 as contentSize, setBounces:YES and setAlwaysBounceVertical:YES
#    (viewDidLoad 0x83020), deceleration and indicators the defaults (the
#    vertical one shows; the horizontal never does: 300 of 300). The
#    "Oops!" alert is Screen.show_alert with its title, and silent (its
#    delegate, 0x847EC, plays nothing).
#  * Every tinted view on this screen is a TintedIV with blend mode 3
#    (overlay). They are baked with ccSugarTint, the port of changeColor:.

extends "res://core/Screen.gd"

const MaskedSprite2D := preload("res://core/MaskedSprite2D.gd")
const ccSugarTint := preload("res://screens/ccSugarTint.gd")
const UIKit := preload("res://screens/msUIKit.gd")

## All 32 flavours: name (the status-dict key list, initWithNibName: 0x81BCC)
## and the exact UIColor built beside it, alpha included, in the same order.
## Component values are 8-bit steps: 0.392157 = 100/255, 0.784314 = 200/255,
## 0.686275 = 175/255, 0.490196 = 125/255, 0.294118 = 75/255, 0.098039 =
## 25/255, 0.588235 = 150/255, 0.196078 = 50/255. Lime and pink were checked
## in the disassembly (0x81F0A / 0x81F78).
const FLAVORS := [
	{"name": "classic pink", "color": Color(1.0, 0.392157, 0.686275, 0.392157)},
	{"name": "classic blue", "color": Color(0.0, 0.490196, 1.0, 0.392157)},
	{"name": "yellow", "color": Color(1.0, 1.0, 0.0, 0.392157)},
	{"name": "brown", "color": Color(0.490196, 0.294118, 0.098039, 0.392157)},
	{"name": "lime", "color": Color(0.588235, 1.0, 0.0, 0.392157)},
	{"name": "green", "color": Color(0.0, 1.0, 0.0, 0.392157)},
	{"name": "turqoise", "color": Color(0.0, 1.0, 0.588235, 0.392157)},
	{"name": "blue", "color": Color(0.0, 0.0, 1.0, 0.392157)},
	{"name": "purple", "color": Color(0.686275, 0.0, 1.0, 0.392157)},
	{"name": "pink", "color": Color(1.0, 0.196078, 0.392157, 0.392157)},
	{"name": "red", "color": Color(0.784314, 0.0, 0.0, 0.392157)},
	{"name": "orange", "color": Color(0.784314, 0.196078, 0.0, 0.392157)},
	{"name": "light orange", "color": Color(1.0, 0.588235, 0.196078, 0.392157)},
	{"name": "light yellow", "color": Color(1.0, 1.0, 0.294118, 0.392157)},
	{"name": "light green", "color": Color(0.392157, 1.0, 0.392157, 0.392157)},
	{"name": "light blue", "color": Color(0.392157, 0.392157, 1.0, 0.392157)},
	{"name": "light purple", "color": Color(1.0, 0.392157, 1.0, 0.392157)},
	{"name": "light red", "color": Color(1.0, 0.392157, 0.392157, 0.392157)},
	{"name": "saturated light orange", "color": Color(1.0, 0.588235, 0.196078, 1.0)},
	{"name": "saturated light yellow", "color": Color(1.0, 1.0, 0.294118, 1.0)},
	{"name": "saturated light green", "color": Color(0.392157, 1.0, 0.392157, 1.0)},
	{"name": "saturated light blue", "color": Color(0.392157, 0.392157, 1.0, 1.0)},
	{"name": "saturated light purple", "color": Color(1.0, 0.392157, 1.0, 1.0)},
	{"name": "saturated light red", "color": Color(1.0, 0.392157, 0.392157, 1.0)},
	{"name": "saturated orange", "color": Color(0.784314, 0.392157, 0.0, 0.784314)},
	{"name": "saturated yellow", "color": Color(0.784314, 0.784314, 0.0, 0.784314)},
	{"name": "saturated green", "color": Color(0.0, 0.784314, 0.0, 0.784314)},
	{"name": "saturated blue", "color": Color(0.0, 0.0, 0.784314, 0.784314)},
	{"name": "saturated purple", "color": Color(0.784314, 0.0, 0.784314, 0.784314)},
	{"name": "saturated red", "color": Color(0.784314, 0.0, 0.0, 0.784314)},
	{"name": "white", "color": Color(1.0, 1.0, 1.0, 0.392157)},
	{"name": "black", "color": Color(0.0, 0.0, 0.0, 0.392157)},
]

# -- picker geometry (initWithNibName: 0x81BCC, initializeSugarPicker 0x81220)

## UIScrollView initWithFrame:(10, 103, 300, 377).
const PICKER_RECT := Rect2(10, 103, 300, 377)
## 4 columns x 73pt pitch both axes (0x49 increments; row pitch DAT_00081664
## = 73.0). Content height = ceil(count * 0.25) * 73 = 8 * 73 = 584.
const CELL_PITCH := 73.0
const CELL_COLS := 4
## Sub_Button_Background UIImageView initWithFrame:(x, y, 80, 80) (the
## 0x42a00000 pair at 0x81552, read from the disassembly) and the 80x80 button.
const CELL_SIZE := 80.0
## TintedIV(cc_sugar_icon.png, flavour, blend 3) setFrame:(x+11, y, 60, 60).
## x+11 but y+0 -- the icon is left-inset only, exactly as the code does it.
## (The TintedIV's art subview keeps its natural size; the icon is 60x60.)
const ICON_INSET_X := 11.0
const ICON_SIZE := 60.0
## Content slides between y = -480 (0xc3f00000, parked above the screen) and
## y = 0, 0.4s (doubles at 0x81060 / 0x81218), UIViewAnimationCurve 3 = linear.
## The same animation blocks fade the app's coinsView to alpha 0 (open) and
## back to 1 (close).
const PANEL_HIDDEN_Y := -480.0
const PANEL_SLIDE := 0.4
## sugarButtonClicked: -- switching canisters while open closes the picker and
## re-opens it after 0.45s (performSelector:afterDelay: 0x3fdccccccccccccd).
const REOPEN_DELAY := 0.45

# -- the spray (initWithNibName: 0x81BCC ivar block) ---------------------

## startX/startY = (126, 230), endX/endY = (126, 400).
const STREAM_START := Vector2(126, 230)
const STREAM_END_Y := 400.0
## sugarFallPixelPerSecond = 200; fall duration = (400-230)/200 = 0.85s and
## the repeat timer fires every (sugarStreamHeight - 20)/200 = (64-20)/200 =
## 0.22s (spraySugarTouchDownInside: 0x83C00, vadd -20.0 = 0xc1a00000).
## sugarFallDuration (3.0) is initialised but never read on any path here.
const FALL_PX_PER_SECOND := 200.0
const STREAM_HEIGHT := 64.0
const STREAM_SPAWN_MARGIN := 20.0
## ccSugarFall (0x84D30): a 64x64 view stacking sugar_fall_0%d.png TintedIVs,
## one per selected flavour, each at (0,0) (zero-frame TintedIV = top-left).
const STREAM_LAYER_ART := "sugar_fall_0%d.png"

# -- the gauge (viewDidLoad 0x83020, progressBarIncrease 0x80948) --------

## MaskedIV(sugar_guage_filler.png, cc_gauge_back.png). initWithBaseImg:
## sizes the view to the mask (45x176); viewDidLoad sets its frame to the
## sugarGauge (cc_gauge_front) nib frame (258,180,45,176) moved up 5, and
## inserts it below sugarGauge -- i.e. cc_gauge_back < filler < front.
const GAUGE_RECT := Rect2(258, 180, 45, 176)
const FILLER_OFFSET_Y := -5.0
## baseOrigPt.y -- where drawRect: draws the filler art's top-left (natural
## size, x 0): 180 in viewDidLoad, 178 in resetScreen, and each spray step
## h + h * pct / -100 with h = sugarGauge.frame.size.height = 176.
const BASE_Y_LOAD := 180.0
const BASE_Y_RESET := 178.0
## progressBarPercentage += 5 per stream spawned (vadd 0x40a00000); >= 100
## stops the spray, enables reset, slides next in and plays cc_sugar_ding --
## without updating baseOrigPt, so the gauge shows its 95% state at the end.
const PROGRESS_STEP := 5
const PROGRESS_FULL := 100

var _selected := [-1, -1, -1, -1]     # selectedFlavorIndex1..4
var _last_canister := -1              # lastSugarButtonClicked (0-based)
var _picker_open := false             # sugarPickerIsOpened
var _panel: Control
var _content: Node2D
var _cells: Array = []                # {rect: Rect2, index: int}
## contentOffset.y, fed by the scroll physics.
var _scroll := 0.0
var _slide_y := PANEL_HIDDEN_Y
## The content view's MODEL y: where the current slide is heading (see _tap).
var _slide_model_y := PANEL_HIDDEN_Y
var _slide_tween: Tween
var _press_pos := Vector2.ZERO
var _press_active := false
## The sugarPicker UIScrollView's touches and motion.
var _physics: UIKit.ScrollPhysics
var _spray_colors: Array = []         # selectedFlavors, rebuilt per touchdown
var _spraying := false
var _spawn_accum := 0.0
var _progress := 0
var _done := false
var _random_flavors: Array[Color] = []   # randomFlavors
var _from_random := [false, false, false, false]   # flavorFromRandomFlavorsArray1..4
var _tint_cache := {}                 # ccSugarTint bakes, by art + colour

# The gauge: a MaskedIV composite redrawn on each baseOrigPt change.
var _gauge: Sprite2D
var _gauge_tex: ImageTexture
var _gauge_img: Image
var _filler_img: Image
var _mask_cov := PackedFloat32Array()
var _mask_size := Vector2i.ZERO
var _gauge_base_y := BASE_Y_LOAD

## Mystery flavour:
##   initWithNibName: 0x81BCC  Consumable DM_CONSUMABLE_MYSTERY_FLAVOR /
##     MysteryFlavor_10Fill, cost = GameData.CoinCosts.COTTON_CANDY.
##     MysterySugar (a server table the bundle does not ship), 11 when
##     absent; first-time message.
##   viewDidLoad 0x83020  ConsumableButton(btn_mystery_flavor, (0,-25) /
##     (65,3)) at centre (50, 310.5) -- this screen's own placement.
##   viewWillAppear: 0x834D4 and resetScreen 0x804C8 unhide the badge;
##     spraySugarTouchDownInside: 0x83C00 hides it.
##   buyMysteryFlavorClick: 0x844B4  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x8402C  quantity 0; randomFlavors emptied, all four
##     flavorFromRandomFlavorsArrayN = YES; for each of the four canisters a
##     random colour (see mystery_color) is appended to randomFlavors,
##     addSugar:color: dresses the canister, selectedFlavorIndexN = its index
##     in randomFlavors.
##   consumablePurchaseFailed:error:2 0x843E0  "You do not have enough coins."
##   flavorButtonClicked: 0x837EC clears the tapped canister's from-random
##     flag (the byte store of 0 at the ivar offset it selects).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_FLAVOR"
const MYSTERY_NAME := "MysteryFlavor_10Fill"
const MYSTERY_COST := 11
const MYSTERY_MESSAGE := "Try out a mystery flavor! You never know what flavor it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_flavor.png"
const MYSTERY_CENTER := Vector2(50, 310.5)

var _mystery: RefCounted
var _mystery_button: TextureButton


func on_enter() -> void:
	GameState.begin("cc")
	# initWithNibName: (0x81BCC) + viewDidLoad (0x83020): once per instance.
	_build_filler()
	_build_picker()
	_wire_canisters()
	_wire_spray()
	_build_mystery()
	set_process(true)
	# viewWillAppear: -- again on every return (on_resume).
	_view_will_appear()


## Nav keeps this controller alive under StickSelect, as
## the UINavigationController does.
func keeps_state_on_push() -> bool:
	return true


## Back from StickSelect: viewWillAppear: (0x834D4) again -- which runs
## resetScreen, so the step starts over: gauge empty, canisters cleared and
## enabled, spray enabled, next hidden, instruction and badge shown.
## (lastSugarButtonClicked, the selectedFlavors array and randomFlavors are
## not touched by it and carry over, as here.)
func on_resume() -> void:
	_view_will_appear()


## viewWillAppear: (0x834D4): instIV setHidden:NO, unlockIAPIfNeed,
## resetScreen, buyMysteryFlavor setHidden:NO. unlockIAPIfNeed (0x81A28)
## rebuilds the picker's content view under FF_KEY_EVERYTHING; the picker is
## closed whenever this runs and openSugarPickerSlider resets its offset, so
## nothing visible changes and the port keeps its one build.
func _view_will_appear() -> void:
	_show_instruction_in_place()
	_reset_screen()
	if _mystery_button != null:
		_mystery_button.visible = true


## This class has no changeInstruction: -- viewWillAppear: just unhides
## instIV where the nib put it. Undo the generic first-appearance slide
## Screen._place_instruction starts (as scSelectCupShape does).
func _show_instruction_in_place() -> void:
	if _instruction_tween != null and _instruction_tween.is_valid():
		_instruction_tween.kill()
	var inst := _instruction_node()
	if inst == null:
		return
	if _instruction_home_set:
		inst.position = _instruction_home
	inst.visible = true


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


## consumablePurchased: (0x8402C): four random colours, one per canister.
func _on_mystery_purchased(_free: bool) -> void:
	_random_flavors.clear()
	for i in 4:
		_from_random[i] = true
		var color := mystery_color()
		_random_flavors.append(color)
		_add_sugar_swatch(i, color)
		_selected[i] = _random_flavors.size() - 1


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## TintedIV(art, colour, blend 3): the art with changeColor:'s overlay bake.
func _tinted(file: String, color: Color) -> Texture2D:
	return ccSugarTint.overlay_texture(_tex(file), color, _tint_cache)


# -- construction -----------------------------------------------------

## The gauge filler, as MaskedIV draws it. drawRect: (0x46E68) clips to the
## mask over the view's bounds, then draws the filler art at baseOrigPt at
## natural size -- so as the gauge rises the art itself slides up into the
## pill (it is not a fixed image revealed from the bottom), and only its left
## 45px of 64 ever show. Redrawn on the CPU per step (45x176, twenty times a
## fill), which keeps the mask in the view's own coordinates.
##
## The mask is applied UPSIDE DOWN: drawRect: hands CGContextClipToMask the
## CGImageMask built in initWithBaseImg:andMaskImg: (0x46CE0) inside UIKit's
## flipped context and never flips the CTM -- the MaskedIV quirk the device
## showed on ccbSelectChocolate (MaskedSprite2D.mask_flip_v). cc_gauge_back's
## pill is NOT vertically symmetric (18px clear above it, 26px below), so the
## flip moves the visible pill 8px down (not yet confirmed on a device).
## cc_gauge_back.png is 8-bit grayscale with no alpha, so it reads as a Core
## Graphics image mask (black paints) -- MaskedSprite2D.detect_mask_mode's
## LUMINANCE rule, same weights as its shader.
func _build_filler() -> void:
	var base := _tex("sugar_guage_filler.png")
	var mask := _tex("cc_gauge_back.png")
	if base == null or mask == null:
		return
	_filler_img = base.get_image().duplicate()
	if _filler_img.is_compressed():
		_filler_img.decompress()
	_filler_img.convert(Image.FORMAT_RGBA8)
	var mimg: Image = mask.get_image().duplicate()
	if mimg.is_compressed():
		mimg.decompress()
	var lum := MaskedSprite2D.detect_mask_mode(mask) == MaskedSprite2D.MaskMode.LUMINANCE
	_mask_size = mimg.get_size()
	_mask_cov.resize(_mask_size.x * _mask_size.y)
	for y in _mask_size.y:
		for x in _mask_size.x:
			var p := mimg.get_pixel(x, y)
			_mask_cov[y * _mask_size.x + x] = \
				(1.0 - (p.r * 0.299 + p.g * 0.587 + p.b * 0.114)) if lum else p.a
	_gauge_img = Image.create(int(GAUGE_RECT.size.x), int(GAUGE_RECT.size.y),
		false, Image.FORMAT_RGBA8)
	_gauge_tex = ImageTexture.create_from_image(_gauge_img)
	_gauge = Sprite2D.new()
	_gauge.name = "sugarGaugeFiller"
	_gauge.texture = _gauge_tex
	_gauge.centered = false
	_gauge.position = GAUGE_RECT.position + Vector2(0, FILLER_OFFSET_Y)
	var front := outlet("sugarGauge")
	if front != null and front != self and front.get_parent() != null:
		front.get_parent().add_child(_gauge)
		front.get_parent().move_child(_gauge, front.get_index())
	else:
		add_child(_gauge)
	_set_gauge_base(BASE_Y_LOAD)


## setBaseOrigPt:(0, y) + drawRect:.
func _set_gauge_base(y: float) -> void:
	_gauge_base_y = y
	if _gauge_img == null:
		return
	_gauge_img.fill(Color(0, 0, 0, 0))
	var vw := _gauge_img.get_width()
	var vh := _gauge_img.get_height()
	# PORT CHOICE: the 1x port snaps drawAtPoint:'s fractional y to a pixel.
	var oy := int(roundf(y))
	var fw := mini(_filler_img.get_width(), vw)
	var fh := _filler_img.get_height()
	for row in vh:
		var sy := row - oy
		if sy < 0 or sy >= fh:
			continue
		# The view is the mask's size (45x176), so mask and view pixels are
		# 1:1; the upside-down clip reads mask row (h-1-row) for view row.
		var my := int(float(vh - 1 - row) * _mask_size.y / vh)
		for x in fw:
			var mx := int(float(x) * _mask_size.x / vw)
			var cov := _mask_cov[my * _mask_size.x + mx]
			if cov <= 0.0:
				continue
			var p := _filler_img.get_pixel(x, sy)
			_gauge_img.set_pixel(x, row, Color(p.r, p.g, p.b, p.a * cov))
	_gauge_tex.update(_gauge_img)


## initializeSugarPicker (0x81220): a 300x377 scroll view at (10,103) whose
## 300x584 content holds 32 cells -- Sub_Button_Background.png (80x80) plus a
## tinted cc_sugar_icon (60x60 at x+11) plus an invisible 80x80 button, laid
## out 4 to a row on a 73pt pitch. The scroll view clips; the content view is
## what the open/close animations move.
##
## openSugarPickerSlider adds the scroll view as the view's last subview, so
## while it is up (until sugarPickerDidSlideUp removes it) it sits over --
## and swallows touches for -- everything under its 300x377 frame: the spray
## button, reset, back, next and the mystery badge. Only the canisters, above
## y 103, stay reachable. The panel below is a STOP control for that reason.
func _build_picker() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)

	_panel = Control.new()
	_panel.position = PICKER_RECT.position
	_panel.size = PICKER_RECT.size
	_panel.clip_contents = true
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.gui_input.connect(_on_panel_input)
	layer.add_child(_panel)

	_content = Node2D.new()
	_content.position = Vector2(0, PANEL_HIDDEN_Y)
	_panel.add_child(_content)

	# viewDidLoad: initWithFrame:(10,103,300,377), setBounces:YES,
	# setAlwaysBounceVertical:YES; initializeSugarPicker: contentSize = the
	# content view's frame size (300, 584).
	_physics = UIKit.ScrollPhysics.new(PICKER_RECT.size,
		Vector2(PICKER_RECT.size.x, _content_height()))
	_physics.name = "UIScrollPhysics"
	_physics.set_bounces(true)
	_physics.set_always_bounce_vertical(true)
	add_child(_physics)
	_physics.scrolled.connect(func(o: Vector2) -> void:
		_scroll = o.y
		_apply_content_pos())
	# The indicators belong to the scroll view, not to the sliding content
	# view: they stay put while the content slides in.
	_physics.attach_indicators(_panel, Rect2(Vector2.ZERO, PICKER_RECT.size))

	var bg_tex := _tex("Sub_Button_Background.png")
	_cells.clear()
	var x := 0.0
	var y := 0.0
	var col := 0
	for i in FLAVORS.size():
		var origin := Vector2(x, y)
		if bg_tex != null:
			var bg := Sprite2D.new()
			bg.texture = bg_tex
			bg.centered = false
			bg.position = origin
			# The art is 91x90 drawn into an 80x80 UIImageView (scale to fill).
			bg.scale = Vector2(CELL_SIZE, CELL_SIZE) / Vector2(bg_tex.get_size())
			_content.add_child(bg)
		var icon_tex := _tinted("cc_sugar_icon.png", FLAVORS[i]["color"])
		if icon_tex != null:
			var icon := Sprite2D.new()
			icon.texture = icon_tex
			icon.centered = false
			icon.position = origin + Vector2(ICON_INSET_X, 0)
			_content.add_child(icon)
		_cells.append({"rect": Rect2(origin, Vector2(CELL_SIZE, CELL_SIZE)),
			"index": i})
		# The 0x81220 layout counter: 4 columns of 73, then wrap.
		if col < CELL_COLS - 1:
			col += 1
			x += CELL_PITCH
		else:
			col = 0
			x = 0.0
			y += CELL_PITCH


func _content_height() -> float:
	return ceilf(FLAVORS.size() * 0.25) * CELL_PITCH   # 8 * 73 = 584


## The four canister buttons all fire sugarButtonClicked:; Screen's automatic
## wiring cannot tell them apart, so they are bound here by index.
func _wire_canisters() -> void:
	for i in 4:
		var b := outlet("sugarButton%d" % (i + 1))
		if b != null and b is BaseButton:
			(b as BaseButton).pressed.connect(_canister_clicked.bind(i))


## The original distinguishes touchDown from touchUpInside/Outside on the
## spray button; Godot's `pressed` fires on release only, so the real
## handlers hang off button_down / button_up here.
func _wire_spray() -> void:
	var b := outlet("sprayButton")
	if b != null and b is BaseButton:
		(b as BaseButton).button_down.connect(_spray_down)
		(b as BaseButton).button_up.connect(_spray_up)


# Absorb Screen's automatic `pressed` wiring for selectors whose real
# behaviour lives on other signals (or per-button bindings) above.
func _on_sugarButtonClicked() -> void:
	pass


func _on_spraySugarTouchDownInside() -> void:
	pass


func _on_spraySugarReleased() -> void:
	pass


# -- resetScreen (0x804C8) --------------------------------------------

func _reset_screen() -> void:
	_progress = 0
	_done = false
	_set_gauge_base(BASE_Y_RESET)
	for i in 4:
		_set_button_enabled("sugarButton%d" % (i + 1), true)
	_set_button_enabled("sprayButton", true)
	for i in 4:
		var holder := outlet("selectedSugarForButton%d" % (i + 1))
		if holder != null:
			var old := holder.get_node_or_null("sugar30")
			if old != null:
				old.queue_free()
	_selected = [-1, -1, -1, -1]
	_from_random = [false, false, false, false]
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = false             # setHidden:YES (enabled is untouched)
	if _mystery_button != null:
		_mystery_button.visible = true


func _set_button_enabled(outlet_name: String, on: bool) -> void:
	var b := outlet(outlet_name)
	if b != null and b != self:
		b.set("disabled", not on)


# -- canisters and the slider (0x836B8 / 0x80DF8 / 0x81068) ------------

func _canister_clicked(idx: int) -> void:
	Audio.play("button_press")
	if _last_canister != idx:
		_last_canister = idx
		if not _picker_open:
			_open_picker()
		else:
			_close_picker()
			get_tree().create_timer(REOPEN_DELAY).timeout.connect(_open_picker)
	else:
		if _picker_open:
			_close_picker()
		else:
			_open_picker()


func _open_picker() -> void:
	if _panel == null or not is_instance_valid(_panel):
		return                    # the 0.45s reopen timer can outlive the screen
	_slide_y = PANEL_HIDDEN_Y
	if _press_active:
		_physics.touch_cancelled()
	_press_active = false
	_physics.set_content_offset(Vector2.ZERO)   # setContentOffset:(0,0) animated:NO
	_scroll = 0.0
	_panel.visible = true
	_apply_content_pos()
	_kill_slide()
	_slide_model_y = 0.0
	_slide_tween = create_tween()
	_slide_tween.tween_method(_set_slide, _slide_y, 0.0, PANEL_SLIDE)
	_fade_coins(0.0)
	_picker_open = true


func _close_picker() -> void:
	if not _panel.visible:
		return
	_kill_slide()
	_slide_model_y = PANEL_HIDDEN_Y
	_slide_tween = create_tween()
	_slide_tween.tween_method(_set_slide, _slide_y, PANEL_HIDDEN_Y, PANEL_SLIDE)
	# sugarPickerDidSlideUp (0x837B4) runs when the animation stops.
	_slide_tween.tween_callback(func() -> void:
		_panel.visible = false
		if _press_active:
			_physics.touch_cancelled()
		_press_active = false
		_picker_open = false)
	_fade_coins(1.0)


func _kill_slide() -> void:
	if _slide_tween != null and _slide_tween.is_valid():
		_slide_tween.kill()


## The open/close animation blocks also set the app delegate's coinsView
## alpha (0 open, 1 close) on the same 0.4s linear curve. CoinHUD parents
## that view to the screen as "CoinInfoView".
func _fade_coins(to: float) -> void:
	var hud := get_node_or_null("CoinInfoView")
	if hud is CanvasItem:
		create_tween().tween_property(hud, "modulate:a", to, PANEL_SLIDE)


func _set_slide(y: float) -> void:
	_slide_y = y
	_apply_content_pos()


func _apply_content_pos() -> void:
	_content.position = Vector2(0, _slide_y - _scroll)


# -- picker input: scroll + tap ---------------------------------------

## The scroll view's own touches (panel-local positions). The drag is
## UIKit's (UIKit.ScrollPhysics: 10 pt hysteresis, rubber band, momentum,
## bounce); a press released before it became a drag is a tap on the cell
## under the press. The wheel is a PORT CHOICE for the desktop (instant
## half-row steps, clamped to the content).
func _on_panel_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_set_scroll(_scroll - CELL_PITCH * 0.5)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_set_scroll(_scroll + CELL_PITCH * 0.5)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press_pos = mb.position
				_press_active = true
				_physics.touch_began(mb.position)
			elif _press_active:
				_press_active = false
				if _physics.touch_ended(mb.position):
					_tap(_press_pos)
		_panel.accept_event()
	elif event is InputEventMouseMotion and _press_active:
		_physics.touch_moved((event as InputEventMouseMotion).position)
		_panel.accept_event()


func _set_scroll(v: float) -> void:
	_physics.set_content_offset(Vector2(0,
		clampf(v, 0.0, maxf(_content_height() - PICKER_RECT.size.y, 0.0))))


## The 80x80 cell buttons overlap by 7pt on the 73pt pitch; UIKit hit-tests
## the last-added subview first, so in an overlap the LATER cell wins.
## The slides are +beginAnimations:"FadeOutBackButton" / "HideSugarPicker"
## (0x80DF8 / 0x81068, 0.4 s linear): the cells stay touchable while the
## content view moves (0x3307B220), and UIKit hit-tests its MODEL frame --
## y 0 from the moment the slide-in commits, y -480 from the moment the
## slide-out does. So a tap mid-slide picks the cell that will be / was
## under the finger, not the one drawn there, and while the picker slides
## away only its bottom rows (content y 480..584) still sit under the
## scroll view's top 104 pt. The port used to test the drawn content.
func _tap(local_pos: Vector2) -> void:
	var p := local_pos - Vector2(0, _slide_model_y - _scroll)
	for k in range(_cells.size() - 1, -1, -1):
		var cell: Dictionary = _cells[k]
		if (cell["rect"] as Rect2).has_point(p):
			_flavor_clicked(int(cell["index"]))
			return


## flavorButtonClicked: (0x837EC) -- assign the flavour to whichever canister
## was tapped last, drop the swatch in, close the slider.
func _flavor_clicked(index: int) -> void:
	Audio.play("button_press")
	if _last_canister < 0:
		return                    # original bails when no canister matches
	_selected[_last_canister] = index
	_from_random[_last_canister] = false
	_add_sugar_swatch(_last_canister, FLAVORS[index]["color"])
	_close_picker()


## addSugar:color: (0x83ABC): TintedIV(sugar_tileable.png, clearColor, 3),
## changeColor:(colour), tag 30, replacing any previous one, added to the
## canister's 64x64 window. Zero-frame TintedIV: the 64x64 art's top-left
## lands at (0,0).
func _add_sugar_swatch(canister: int, color: Color) -> void:
	var holder := outlet("selectedSugarForButton%d" % (canister + 1))
	if holder == null:
		return
	var old := holder.get_node_or_null("sugar30")
	if old != null:
		holder.remove_child(old)
		old.queue_free()
	var s := Sprite2D.new()
	s.name = "sugar30"
	s.texture = _tinted("sugar_tileable.png", color)
	s.centered = false
	holder.add_child(s)


# -- the spray (0x83C00 / 0x83BC4 / 0x80AE8 / 0x80898) -----------------

func _spray_down() -> void:
	if _done:
		return
	_set_button_enabled("resetButton", false)
	_spray_colors.clear()
	for i in 4:
		if _selected[i] != -1:
			_spray_colors.append(_random_flavors[_selected[i]] if _from_random[i]
				else FLAVORS[_selected[i]]["color"])
	if _spray_colors.is_empty():
		# UIAlertView("Oops!", ..., delegate self, "Ok"): the delegate
		# (0x847EC) only acts on "Go to Store" / "Not Now" -- silent.
		show_alert("Please select at least one flavor of sugar to continue!",
			["Ok"], Callable(), false, "Oops!")
		return
	if _mystery_button != null:
		_mystery_button.visible = false      # spraySugarTouchDownInside: 0x83C00
	for i in 4:
		_set_button_enabled("sugarButton%d" % (i + 1), false)
	_show_glow(true)
	_spraying = true
	_spawn_accum = 0.0
	_spawn_stream()               # startSugarFall: fires once immediately
	Audio.play("big_red_button")
	Audio.loop("cc_sugar_pour")


func _spray_up() -> void:
	_set_button_enabled("resetButton", true)
	_stop_sugar_fall()


func _stop_sugar_fall() -> void:
	_spraying = false
	_show_glow(false)
	Audio.stop("cc_sugar_pour")


## touchDown shows greenGlow + nozzleShadow (setHidden:NO); stopSugarFall
## hides both. The nib ships both UIHidden=YES, so they are off until the
## first spray (an earlier note here said the nib showed them; that was the
## swapped NIBArchive bool tags, since fixed).
func _show_glow(on: bool) -> void:
	for outlet_name in ["greenGlow", "nozzleShadow"]:
		var n := outlet(outlet_name)
		if n != null and n != self:
			n.visible = on


## The NSTimer: (64 - 20) / 200 = 0.22s, repeating, until stopSugarFall
## invalidates it.
func _process(delta: float) -> void:
	if not _spraying:
		return
	_spawn_accum += delta
	var interval := (STREAM_HEIGHT - STREAM_SPAWN_MARGIN) / FALL_PX_PER_SECOND
	while _spawn_accum >= interval:
		_spawn_accum -= interval
		_spawn_stream()
		if not _spraying:
			break


## startSugarFall: (0x80AE8) -- a ccSugarFall stack at (126, 230), inserted
## below cottonCandyMachine, sliding linearly (curve 3) to y = 400 at
## 200 px/s (0.85s). Each spawn bumps the gauge.
##
## PORT CHOICE: the original never removes a finished stream -- they pile up
## at (126, 400). cc_machine_top.png is fully opaque over x 100..220 from
## y 356 down, so every one of them sits hidden behind the tub; the port
## frees each at the end of its slide instead of keeping ~20 hidden nodes.
func _spawn_stream() -> void:
	var fall := Node2D.new()
	fall.position = STREAM_START
	for i in _spray_colors.size():
		var tex := _tinted(STREAM_LAYER_ART % i, _spray_colors[i])
		if tex == null:
			continue
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		fall.add_child(s)
	var machine := outlet("cottonCandyMachine")
	if machine != null and machine != self and machine.get_parent() != null:
		machine.get_parent().add_child(fall)
		machine.get_parent().move_child(fall, machine.get_index())
	else:
		add_child(fall)
	var seconds := (STREAM_END_Y - STREAM_START.y) / FALL_PX_PER_SECOND
	var tw := create_tween()
	tw.tween_property(fall, "position:y", STREAM_END_Y, seconds)
	tw.tween_callback(fall.queue_free)
	_progress_increase()


## progressBarIncrease (0x80948).
func _progress_increase() -> void:
	_progress += PROGRESS_STEP
	if _progress >= PROGRESS_FULL:
		_stop_sugar_fall()
		_set_button_enabled("sprayButton", false)
		_set_button_enabled("resetButton", true)
		_done = true
		_show_next()
		Audio.play("cc_sugar_ding")
		return
	var h := GAUGE_RECT.size.y
	_set_gauge_base(h + h * float(_progress) / -100.0)


## showNextButton (0x806D0): instIV hidden, then the standard +500px 0.25s
## ease-in-out slide-in. It sets no enabled state -- resetScreen never
## disabled the button, it only hid it.
func _show_next() -> void:
	show_next_button()


# -- navigation --------------------------------------------------------

## unlockSugarPickerAndResetGauge: (0x84790), the RESET button.
func _on_unlockSugarPickerAndResetGauge() -> void:
	Audio.play("button_press")
	_reset_screen()


## nextClick: (0x845C4) pushes StickSelect("COTTON_CANDY", {colors:
## selectedFlavors}). GameState.custom_categories is the port's carrier for
## that infoDict chain; this screen starts it, StickSelect adds stickImg and
## packID, ccMachine consumes and replaces it.
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.custom_categories = {"colors": _spray_colors.duplicate()}
	Nav.next()


## backClick: (0x84520): stop any fall, click, pop.
func _on_backClick() -> void:
	_stop_sugar_fall()
	Audio.play("button_press")
	Nav.back()


## skipClick: (0x846B8), the invisible dev button the nib wires at
## (186, 369, 120, 40): APPENDS flavour 0, 1, 2 and purpleColor to whatever
## selectedFlavors already holds (addObject:, never cleared here), then next.
func _on_skipClick() -> void:
	_spray_colors.append_array([
		FLAVORS[0]["color"], FLAVORS[1]["color"], FLAVORS[2]["color"],
		Color(0.5, 0.0, 0.5, 1.0),   # +[UIColor purpleColor]
	])
	_on_nextClick()


## viewWillDisappear: (0x835DC): stopPlayerForFile cc_sugar_pour, nothing
## else.
func on_exit() -> void:
	Audio.stop("cc_sugar_pour")
