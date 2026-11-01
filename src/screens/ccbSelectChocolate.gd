# Chocolate Covered Banana step 4 -- pick a chocolate colour, then grate the
# bar into the pot.
#
# From the original binary (entry points from the ObjC method list; the
# 33-colour array's carried-over CGFloat args read from the disassembly of
# 0xBE94C..0xBED7C: the recovered hue/sat/alpha constants 0.09375..0.84375,
# 0.3, 0.7 match caSelectChocolate's verified array exactly):
#   initWithNibName: 0xBE760 (color_arr build 0xBE8E0..0xBEE00),
#   viewDidLoad 0xBEE3C, viewWillAppear: 0xBF348, viewWillDisappear: 0xBF638,
#   grateTick 0xBF6DC, draggableTouchMoved/Ended 0xBF938/0xBFA78,
#   selectFlavorButtonClick: 0xBFF50, showSugarBag: 0xC003C,
#   chocolateClick: 0xC0524, backClick: 0xC0580, nextClick: 0xC060C,
#   skipClick: 0xC0788 (forwards to nextClick:, no nib action reaches it),
#   changeInstruction: 0xC08FC, showScrollView 0xC0B3C, hideScrollView 0xC1250,
#   setColors: 0xC0B24 (an NSLog stub), enableBackButton 0xC0B04 (no caller).
#
# Mechanic, as read: same shape as caSelectChocolate, all numbers read
# independently here. The colour picker (nib aScrollView (0,57,320,366) --
# Candy Apple's sits at (-20,43)): viewWillAppear: calls showScrollView then
# hideScrollView back to back, and hideScrollView (0xC1250) first puts the
# panel at its home (setCenter:, outside any animation) and then animates it
# 500 up over 0.25 s (curve 2, ease-out) -- so on entry the panel is seen at
# home sliding away (the port used to start it already
# parked, as caSelectChocolate did before its own fix). Tapping
# selectChocolateButton (nib hotspot (104,0,112,61)) toggles it. Picking a colour bakes "Candy Bar.png" through
# TintedIV's ALTERNATE path -- art as backdrop, tint filled over it with
# CGBlendMode 3 / Overlay, clipped to the art (initWithAlternateImage:
# 0x4711C, changeAlternateColor: 0x474FC) -- and drops the bar in from
# +(-500) over 0.25s. Dragging the bar over the grater (nib (104,55,113,149))
# sets isGrating; a 0.1s timer raises the pile's baseOrigPt.y by
# baseImg.height/30 per tick and accumulates grateTime; at 3.0s the next
# button slides in.
#
# The pile is a MaskedIV (0x46CE0): its frame is the MASK's size
# (chgum_pot_mask.png, 302x200 -- so setCenter (160,318) is a true centre)
# and drawRect clips to the mask and draws the base at baseOrigPt
# ((302-196)/2, 138) = (53,138). Re-expressed as a 302x200 canvas blitted at
# baseOrigPt, shown through core/MaskedSprite2D.
#
# PORT NOTES:
#  * bake_alt_tint reused from caSelectChocolate.gd (house precedent); the
#    colour table is this screen's own (0xBE760) even though it comes out
#    identical to Candy Apple's 33.
#  * The grate-fleck SSEmitter (nib grateEmitter (80,167,160,37)) is wired:
#    configured in
#    viewDidLoad (0xBEE3C, call 0xBF268) with tint nil, re-tinted by setTint:
#    in showSugarBag: (0xC003C); started when the bar first overlaps the
#    grater (draggableTouchMoved: 0xBF938); stopped on leaving it, on release
#    (0xBFA78), at grateTick's finish (0xBF6DC), by backClick: (0xC0580),
#    nextClick: (0xC060C) and viewWillDisappear: (0xBF638). (The "Go to
#    Store" alert stop, 0xC041C, belongs to the unported lock alert.)
#  * KEEP STATE: the controller survives under ccbStirIngredients;
#    viewWillAppear: (0xBF348) RESETS the step on return exactly as on entry
#    -- "inst_select_chocolate" slid in (next hidden), a new 0.1 s
#    grateTimer, the pile's baseOrigPt back to y 138 (tinted art kept, now
#    below the flipped bowl), isGrating/grateTime 0, the bar's image nil,
#    selectedColor nil (the emitter keeps its last tint), the mystery badge
#    unhidden, showScrollView + hideScrollView.
#  * PORT CHOICE: the nib's chocolate DraggableIV is imageless until a
#    colour is picked (viewWillAppear does setImage:nil) but it is NOT inert
#    on the phone: DraggableIV initWithCoder: (0x46284) forces
#    userInteractionEnabled YES, and its home frame (123,175,75,75) already
#    overlaps the grater (104,55,113,149), so wiggling the empty spot grates
#    an invisible bar and raises the UNTINTED pile; after 3 s next appears,
#    and nextClick: then does setObject:nil forKey:@"Color" -- an
#    NSInvalidArgumentException, i.e. the original crashes. The port enables
#    the drag only once a colour is chosen, which removes the crash path and
#    nothing else. (Earlier note blamed a nib flag; there is none.)
#
# Corrections from a full re-read of the original:
#  * grateTime is a float accumulating 0.1f per tick; in float32 thirty
#    ticks sum to 2.9999993, so the >= 3.0 test first passes on tick 31
#    (3.1 s, pile raised 31 steps). The port summed in double and finished
#    on tick 30. Both now accumulate in float32.
#  * The colour panel only takes taps inside its own frame; the
#    selectChocolateButton sits above it (bringSubviewToFront: in
#    showScrollView 0xC0B3C); backClick: (0xC0580) plays button_press.
#
# Mystery flavour (ported; the original shows it on the phone): Consumable
# DM_CONSUMABLE_MYSTERY_FLAVOR / MysteryFlavor_40Chocolate, cost from the
# dead server table GameData.CoinCosts."Chocolate Dipped Banana".
# MysteryChocolate, 6 when absent (initWithNibName: 0xBE79A); the
# ConsumableButton (btn_mystery_flavor, offsets (0,-25) / (65,3)) at centre
# (50, 350.5) (viewDidLoad 0xBEF9C); buyMysteryFlavorClick: 0xBFEE4 ("store"
# sound, purchase); consumablePurchased: 0xBFB98 -> a random colour
# hue = rand%1000/1000, sat = rand%500/1000 + 0.5, bri = rand%500/1000 + 0.5
# -> showSugarBag:. showScrollView zeroes its alpha while the picker is up.
#
# Not ported: contentLocked / lockedFlavorButtonClicked: 0xC038C / the
# Sub_Button_Background_Locked art and black_lock overlays in showScrollView
# (0xC0DF0), and the AdColony hooks.

extends "res://core/Screen.gd"

## The colour picker's UIScrollView: UIKit's own drag /
## deceleration / bounce physics and its vertical scroll indicator
## (kcScrollView.gd header). Nib aScrollView (0,57,320,366): no indicator, bounce or
## rate keys, so the defaults hold -- bounces YES, decelerationRate 0.998,
## indicators on; showScrollView (0xC0B3C) sets contentSize (320, 100 * 11 =
## 1100) and never touches the offset, so a re-opened list is where it was
## left.
const ScrollView := preload("res://screens/kcScrollView.gd")

const MaskedSprite := preload("res://core/MaskedSprite2D.gd")
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")
const EMITTER_KEY := "ccbSelectChocolate.grateEmitter"
const caSelectChocolate := preload("res://screens/caSelectChocolate.gd")

## color_arr (0xBE8E0..0xBEE00): 33 UIColors, exactly as built. Entries 0..1
## and 3..30 are colorWithHue:saturation:brightness:alpha:; entry 2 is
## +[UIColor brownColor] (0.6,0.4,0.2); 31..32 are colorWithRed:...
## Hue ladder 0.09375..0.84375 in steps of 3/32, each with a pale (s 0.3),
## a pure (s 1) and a dark translucent (b 0.7, a 0.7) variant. Identical to
## Candy Apple's table (0x155C40) -- verified, not assumed.
static func colors() -> Array[Color]:
	var out: Array[Color] = [
		Color.from_hsv(0.0, 1.0, 1.0),
		Color.from_hsv(0.65625, 1.0, 1.0),
		Color(0.6, 0.4, 0.2),
		Color.from_hsv(0.0, 0.3, 1.0),
		Color.from_hsv(0.0, 1.0, 0.7, 0.7),
	]
	for h: float in [0.09375, 0.1875, 0.28125, 0.375, 0.46875, 0.5625]:
		out.append(Color.from_hsv(h, 0.3, 1.0))
		out.append(Color.from_hsv(h, 1.0, 1.0))
		out.append(Color.from_hsv(h, 1.0, 0.7, 0.7))
	out.append(Color.from_hsv(0.65625, 0.3, 1.0))
	out.append(Color.from_hsv(0.65625, 1.0, 0.7, 0.7))
	for h: float in [0.75, 0.84375]:
		out.append(Color.from_hsv(h, 0.3, 1.0))
		out.append(Color.from_hsv(h, 1.0, 1.0))
		out.append(Color.from_hsv(h, 1.0, 0.7, 0.7))
	out.append(Color(1, 1, 1, 0.7))
	out.append(Color(0, 0, 0, 0.7))
	return out


# -- geometry (nib ccbSelectChocolate + the addresses above) --------------

const PILE_CENTER := Vector2(160, 318)        # 0x43200000 / 0x439F0000
const PILE_SIZE := Vector2i(302, 200)         # chgum_pot_mask.png
const PILE_BASE_X := 53.0                     # (302 - 196)/2, viewWillAppear
const PILE_ORIG_Y0 := 138.0                   # 0x430A0000
const CHOC_FRAME := Rect2(123, 175, 75, 75)   # nib id 6 (DraggableIV)
const GRATER_RECT := Rect2(104, 55, 113, 149) # nib id 5
const PANEL_RECT := Rect2(0, 57, 320, 366)    # nib id 7 (aScrollView)
const PANEL_SLIDE_DY := -500.0                # 0xC3FA0000
const PANEL_SLIDE_S := 0.25
## showScrollView button grid (0xC0B3C): (24 + 100*(i%3), 100*row, 80, 80)
## (0x42A00000); icon frame (15,15,50,50) (0x41700000 / 0x42480000).
const CELL_X0 := 24.0
const CELL_PITCH := 100.0
const CELL_SIZE := 80.0
const ICON_RECT := Rect2(15, 15, 50, 50)
## grateTick (0xBF6DC): 0.1s timer (double 0x3FB999999999999A), step =
## baseImg.h * 0.0333333351 (0x3D088889), done at grateTime >= 3.0.
const GRATE_TICK_S := 0.1
const GRATE_STEP_FRAC := 0.0333333351
const GRATE_DONE_S := 3.0
const CHOC_SNAP_S := 0.25

## Mystery flavour (see header).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_FLAVOR"
const MYSTERY_NAME := "MysteryFlavor_40Chocolate"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery flavor! You never know what flavor it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_flavor.png"
const MYSTERY_CENTER := Vector2(50, 350.5)

var _mystery: RefCounted
var _mystery_button: TextureButton

var _pile: MaskedSprite
var _pile_canvas: Image
var _pile_tex: ImageTexture
var _pile_base: Image                          # tinted choc_pile pixels
var _pile_orig_y := PILE_ORIG_Y0
var _choc: Sprite2D
var _choc_home := CHOC_FRAME.position + CHOC_FRAME.size * 0.5   # (160.5,212.5)
var _selected := Color(0, 0, 0, 0)
var _has_color := false
var _grating := false
var _grate_time := 0.0
var _timer: Timer
var _panel: Control
var _content: Node2D
var _panel_shown := false
var _content_h := 0.0
var _sv: Node                                  # kcScrollView (aScrollView)
var _dragging := false
var _grab := Vector2.ZERO
## The bar's "MoveChocolate" glide home (see _glide_choc_home).
var _choc_tween: Tween
var _panel_tween: Tween
var _emitter: SSEmitter                        # nib grateEmitter
## The shared infoDict (see ccbSelectStickViewController._info).
var _info: Dictionary = {}


func on_enter() -> void:
	_info = GameState.custom_categories
	_build_pile()
	_build_chocolate()
	_build_emitter()
	_build_mystery()
	_build_panel()
	_timer = Timer.new()
	_timer.wait_time = GRATE_TICK_S
	_timer.timeout.connect(_grate_tick)
	add_child(_timer)
	_view_will_appear()


## viewWillAppear: (0xBF348) -- the first appearance and every return:
## instruction, grate timer, pile reset, no selection, badge shown, and the
## picker shown-then-hidden (seen sliding away).
func _view_will_appear() -> void:
	change_instruction("inst_select_chocolate.png")
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	_timer.start()                             # a new 0.1 s grateTimer
	# setBaseOrigPt:((frame.w - baseImg.w)/2, 138): the art stays as tinted.
	_pile_orig_y = PILE_ORIG_Y0
	_redraw_pile()
	_grating = false
	_grate_time = 0.0
	# chocolate setImage:nil, setSelectedColor:nil.
	_dragging = false
	if _choc != null:
		_choc.texture = null
		_choc.visible = false
	_has_color = false
	_selected = Color(0, 0, 0, 0)
	if _mystery_button != null:
		_mystery_button.visible = true         # buyMysteryFlavor setHidden:NO
	_show_panel()
	_hide_panel()


## UINavigationController keeps this controller alive under
## ccbStirIngredients (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from ccbStirIngredients: viewWillAppear: again (see header).
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		# CoinHUD re-adds the panel after this; drop the first appearance's.
		remove_child(old)
		old.queue_free()
	if _sv != null:
		_sv.call("cancel_tracking")
	_view_will_appear()


## viewDidLoad (0xBEE3C): the nib SSEmitter grateEmitter, frame
## (80,167,160,37), configured with tint nil (call 0xBF268). Its nib slot is
## above chgum_pot and below the grater.
func _build_emitter() -> void:
	var host := outlet("grateEmitter")
	if host == null or host == self:
		return
	_emitter = SSEmitter.attach(host, SSEmitterConfigs.frame_size(EMITTER_KEY)) as SSEmitter
	SSEmitterConfigs.apply(_emitter, EMITTER_KEY, null)


func _emitter_stop() -> void:
	if _emitter != null:
		_emitter.stop()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## viewDidLoad (0xBEF9C): the mystery-flavour ConsumableButton.
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


## buyMysteryFlavorClick: (0xBFEE4).
func _on_buyMysteryFlavorClick() -> void:
	Audio.play("store")
	_mystery.call("purchase", self)


## consumablePurchased: (0xBFB98): a random colour, then showSugarBag:.
func _on_mystery_purchased(_free: bool) -> void:
	var hue := float(randi() % 1000) / 1000.0
	var sat := float(randi() % 500) / 1000.0 + 0.5
	var bri := float(randi() % 500) / 1000.0 + 0.5
	_show_sugar_bag(Color.from_hsv(hue, sat, bri, 1.0))


## MaskedIV(choc_pile, chgum_pot_mask) (viewDidLoad 0xBEE3C) re-expressed:
## a mask-sized canvas the base art is blitted into at baseOrigPt, drawn
## through the mask.
func _build_pile() -> void:
	var base := _tex("choc_pile.png")
	if base != null:
		_pile_base = base.get_image()
		if _pile_base.is_compressed():
			_pile_base.decompress()
		_pile_base.convert(Image.FORMAT_RGBA8)
	_pile_canvas = Image.create(PILE_SIZE.x, PILE_SIZE.y, false, Image.FORMAT_RGBA8)
	_pile_tex = ImageTexture.create_from_image(_pile_canvas)
	_pile = MaskedSprite.new()
	_pile.texture = _pile_tex
	var mask := _tex("chgum_pot_mask.png")
	_pile.mask = mask
	_pile.mask_mode = MaskedSprite.detect_mask_mode(mask)
	# MaskedIV applies the mask upside down (see MaskedSprite2D.mask_flip_v):
	# the bowl shape lands at the TOP of the 302x200 view, so the pile at
	# baseOrigPt.y 138 starts hidden and rises into it -- verified against a
	# phone frame. Without the flip the whole pile showed at once
	# below the pot.
	_pile.mask_flip_v = true
	_pile.position = PILE_CENTER
	# insertSubview:belowSubview:chocolate (0xBEEE6); adding before _choc
	# keeps that order.
	add_child(_pile)
	_redraw_pile()


func _redraw_pile() -> void:
	if _pile_canvas == null or _pile_base == null:
		return
	_pile_canvas.fill(Color(0, 0, 0, 0))
	_pile_canvas.blend_rect(_pile_base,
		Rect2i(0, 0, _pile_base.get_width(), _pile_base.get_height()),
		Vector2i(int(PILE_BASE_X), int(round(_pile_orig_y))))
	_pile_tex.update(_pile_canvas)


func _build_chocolate() -> void:
	_choc = Sprite2D.new()
	_choc.position = _choc_home
	_choc.visible = false
	add_child(_choc)
	# Take the nib DraggableIV's slot (id 6: above pot, emitter and grater,
	# below aScrollView, selectChocolateButton, back and next), with the
	# pile directly under it (insertSubview:belowSubview:chocolate).
	var nib_choc := outlet("chocolate")
	if nib_choc != null and nib_choc != self:
		var i := (nib_choc as Node).get_index()
		move_child(_pile, i)
		move_child(_choc, i + 1)


func _choc_rect() -> Rect2:
	return Rect2(_choc.position - CHOC_FRAME.size * 0.5, CHOC_FRAME.size)


## Both "MoveChocolate" glides (showSugarBag: 0xC003C, draggableTouchEnded:
## 0xBFA78) are +beginAnimations:/commitAnimations, 0.25 s, curve 0, and
## nothing in this class turns the bar's interaction off: it can be caught
## on the way, hit-tested at its MODEL centre (home), and the drag owns it
## from there. The port used to hit-test the drawn bar and leave the glide
## running under the finger, so a bar caught and held on the grater was
## pulled home while grating went on.
func _glide_choc_home() -> void:
	if _choc_tween != null and _choc_tween.is_valid():
		_choc_tween.kill()    # a new position animation replaces the old
	_choc_tween = create_tween()
	_choc_tween.tween_property(_choc, "position", _choc_home, CHOC_SNAP_S) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _choc_gliding() -> bool:
	return _choc_tween != null and _choc_tween.is_valid() \
		and _choc_tween.is_running()


# -- the colour picker (showScrollView 0xC0B3C) --------------------------

func _build_panel() -> void:
	_panel = Control.new()
	_panel.clip_contents = true
	_panel.position = PANEL_RECT.position + Vector2(0, PANEL_SLIDE_DY)
	_panel.size = PANEL_RECT.size
	_panel.visible = true
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	# showScrollView (run once from viewWillAppear) brings aScrollView and
	# then selectChocolateButton to the front: the button stays above the
	# panel from then on.
	var sel := outlet("selectChocolateButton")
	if sel != null and sel != self:
		move_child(sel, get_child_count() - 1)
	_content = Node2D.new()
	_panel.add_child(_content)

	var bg := _tex("Sub_Button_Background.png")
	var bar := _tex("Candy Bar.png")
	var cols := colors()
	var row := 0
	for i in cols.size():
		var cell := Node2D.new()
		cell.position = Vector2(CELL_X0 + CELL_PITCH * (i % 3), CELL_PITCH * row)
		_content.add_child(cell)
		if bg != null:
			var b := Sprite2D.new()
			b.texture = bg
			b.centered = false
			b.scale = Vector2(CELL_SIZE, CELL_SIZE) / bg.get_size()
			cell.add_child(b)
		var icon_tex := caSelectChocolate.bake_alt_tint(bar, cols[i], 3)
		if icon_tex != null:
			var icon := Sprite2D.new()
			icon.texture = icon_tex
			icon.position = ICON_RECT.position + ICON_RECT.size * 0.5
			icon.scale = ICON_RECT.size / Vector2(icon_tex.get_size())
			cell.add_child(icon)
		if i % 3 == 2:
			row += 1
	_content_h = CELL_PITCH * (row + (0 if cols.size() % 3 == 0 else 1))
	_sv = ScrollView.new()
	_sv.name = "aScrollViewSim"
	add_child(_sv)
	_sv.call("configure", true, PANEL_RECT, _content_h)
	_sv.set("content", _content)
	_sv.call("add_indicator", _panel, Rect2(Vector2.ZERO, PANEL_RECT.size))
	_sv.connect("tapped", _panel_tapped)


## showScrollView (0xC0B3C): bring aScrollView, then selectChocolateButton,
## to the front; toggle if already shown; else zero the chrome, park the
## panel 500 up and animate it home (0.25 s, curve 2 = ease-out).
func _show_panel() -> void:
	move_child(_panel, get_child_count() - 1)
	var sel := outlet("selectChocolateButton")
	if sel != null and sel != self:
		move_child(sel as Node, get_child_count() - 1)
	if _panel_shown:
		_hide_panel()      # showScrollView toggles (0xC0B96)
		return
	_panel_shown = true
	_set_chrome_alpha(0.0)
	_panel.position = PANEL_RECT.position + Vector2(0, PANEL_SLIDE_DY)
	_slide_panel(PANEL_RECT.position)


## hideScrollView (0xC1250): restore the chrome, snap the panel to its home
## (non-animated), then animate it 500 up (0.25 s, ease-out).
func _hide_panel() -> void:
	if not _panel_shown:
		return
	_panel_shown = false
	_set_chrome_alpha(1.0)
	_panel.position = PANEL_RECT.position
	_slide_panel(PANEL_RECT.position + Vector2(0, PANEL_SLIDE_DY))


## A new UIView position animation replaces the one in flight; kill ours too
## so two tweens never fight over the panel.
func _slide_panel(to: Vector2) -> void:
	if _panel_tween != null and _panel_tween.is_valid():
		_panel_tween.kill()
	_panel_tween = create_tween()
	_panel_tween.tween_property(_panel, "position", to, PANEL_SLIDE_S) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## showScrollView zeroes the alpha of next/back and the buyMysteryFlavor
## button while the picker is up; hideScrollView restores them.
## An alpha-0 UIView also stops receiving touches; mirror with disabled.
func _set_chrome_alpha(a: float) -> void:
	var nodes: Array = []
	for oname in ["nextButton", "backButton"]:
		var o := outlet(oname)
		if o != null and o != self:
			nodes.append(o)
	if _mystery_button != null:
		nodes.append(_mystery_button)
	for o in nodes:
		if o is CanvasItem:
			var ci := o as CanvasItem
			ci.modulate.a = a
			if ci.has_method("set_disabled"):
				ci.set("disabled", a <= 0.0)


## chocolateClick: (0xC0524) -- the selectChocolateButton hotspot.
func _on_chocolateClick() -> void:
	Audio.play("button_press")
	_show_panel()


## selectFlavorButtonClick: (0xBFF50).
func _select_flavor(i: int) -> void:
	Audio.play("button_press")
	_hide_panel()
	var cols := colors()
	if i >= 0 and i < cols.size():
		_show_sugar_bag(cols[i])


## showSugarBag: (0xC003C).
func _show_sugar_bag(color: Color) -> void:
	_pile_orig_y = PILE_ORIG_Y0
	var bar := _tex("Candy Bar.png")
	var bar_tinted := caSelectChocolate.bake_alt_tint(bar, color, 3)
	if bar_tinted != null:
		_choc.texture = bar_tinted
		# The nib DraggableIV frame is 75x75; UIImageView scale-to-fill
		# squashes the 231x215 bar into it.
		_choc.scale = CHOC_FRAME.size / Vector2(bar_tinted.get_size())
		_choc.visible = true
	var pile_tinted := caSelectChocolate.bake_alt_tint(
		_tex("choc_pile.png"), color, 3)
	if pile_tinted != null:
		_pile_base = pile_tinted.get_image()
	_redraw_pile()
	_grating = false
	_grate_time = 0.0
	change_instruction("inst_grate.png")
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false     # changeInstruction: tail
	_selected = color
	_has_color = true
	if _emitter != null:
		_emitter.set_tint(color)               # [grateEmitter setTint:]
	# "MoveChocolate": the bar drops in from 500 above over 0.25s (curve 0).
	_choc.position = _choc_home + Vector2(0, PANEL_SLIDE_DY)
	_glide_choc_home()


# -- grating -------------------------------------------------------------

## grateTick (0xBF6DC), on the 0.1s timer. grateTime and baseOrigPt are
## 32-bit floats on the phone; accumulate them that way (see header).
func _grate_tick() -> void:
	var n := outlet("nextButton")
	var next_hidden: bool = n == null or n == self or not (n as CanvasItem).visible
	if _grating and next_hidden:
		_grate_time = _f32(_grate_time + _f32(GRATE_TICK_S))
		if _pile_base != null:
			_pile_orig_y = _f32(_pile_orig_y - _f32(
				float(_pile_base.get_height()) * _f32(GRATE_STEP_FRAC)))
		_redraw_pile()
		Audio.loop("grating")     # loopFile: is a no-op if already looping
	if _grate_time >= GRATE_DONE_S and next_hidden:
		_emitter_stop()
		Audio.stop("grating")
		show_next_button()


## Round to IEEE single precision, as the original's CGFloat/float ivars.
static func _f32(v: float) -> float:
	return PackedFloat32Array([v])[0]


func _unhandled_input(event: InputEvent) -> void:
	if _panel_shown:
		_panel_input(event)
		return
	if _choc == null or not _choc.visible:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		# Mid-glide the bar answers at its model (home); see _glide_choc_home.
		# PORT CHOICE: it lands on the model at once instead of gliding on
		# toward the finger for the rest of the 0.25 s.
		var gliding := _choc_gliding()
		var hit_rect := Rect2(_choc_home - CHOC_FRAME.size * 0.5,
			CHOC_FRAME.size) if gliding else _choc_rect()
		if mb.pressed and not _dragging and hit_rect.has_point(mb.position):
			if gliding:
				_choc_tween.kill()
				_choc.position = _choc_home
			_dragging = true
			_grab = _choc.position - mb.position
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			_choc_released()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		_choc.position = (event as InputEventMouseMotion).position + _grab
		_choc_moved()
		get_viewport().set_input_as_handled()


## draggableTouchMoved: (0xBF938): grater.frame vs chocolate.frame.
func _choc_moved() -> void:
	if GRATER_RECT.intersects(_choc_rect()):
		if not _grating and _emitter != null:
			_emitter.start()
		_grating = true
	else:
		if _grating:
			_emitter_stop()
			Audio.stop("grating")
		_grating = false


## draggableTouchEnded: (0xBFA78): stop grating, "MoveChocolate" home over
## 0.25s (curve 0), stop the sound.
func _choc_released() -> void:
	_grating = false
	_emitter_stop()
	_glide_choc_home()
	Audio.stop("grating")


## The shown picker: touches inside its (model) frame go to the scroll
## view -- drag / flick, or a tap on a colour.
func _panel_input(event: InputEvent) -> void:
	if _sv != null and _sv.call("handle_input", event):
		get_viewport().set_input_as_handled()


## A touch that never became a drag reaches the button under it
## (touchUpInside: the release must stay within its bounds + 70 pt).
func _panel_tapped(press: Vector2, release: Vector2) -> void:
	for i in colors().size():
		var rect := Rect2(Vector2(CELL_X0 + CELL_PITCH * (i % 3),
			CELL_PITCH * int(float(i) / 3.0)), Vector2(CELL_SIZE, CELL_SIZE))
		if rect.has_point(press):
			if ScrollView.release_inside(rect, release):
				_select_flavor(i)
			return


## nextClick: (0xC060C): stop the emitter, button_press,
## infoDict["Color"] = selectedColor, the pile's baseOrigPt handed on via
## setGratedBaseOrig:, push ccbStirIngredients (animated:NO).
func _on_nextClick() -> void:
	_emitter_stop()
	Audio.play("button_press")
	if _has_color:
		_info["Color"] = _selected
	_info["GratedOrigY"] = _pile_orig_y
	GameState.custom_categories = _info
	Nav.next()


## skipClick: (0xC0788) forwards to nextClick: -- no nib action reaches it.
func _on_skipClick() -> void:
	_on_nextClick()


## backClick: (0xC0580): stop the emitter, button_press, pop.
func _on_backClick() -> void:
	_emitter_stop()
	Audio.play("button_press")
	Nav.back()


## viewWillDisappear: (0xBF638): stop the emitter, invalidate the timer,
## stop the sound.
func on_exit() -> void:
	if _sv != null:
		_sv.call("settle")                     # a flick in flight lands
	_emitter_stop()
	if _timer != null:
		_timer.stop()
	Audio.stop("grating")


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
