# Candy Apple step 5 -- pick a chocolate colour, then grate the bar into
# the pot.
#
# From the original binary (IMPs from the ObjC method list; the 33-colour
# array's CGFloat arguments read from the instructions):
#   initWithNibName: 0x155A98 (color_arr build 0x155C40..0x156138),
#   viewDidLoad 0x156174, viewWillAppear: 0x1566C8, viewWillDisappear:
#   0x156790, screenSetup 0x156818, grateTick 0x156AE0,
#   draggableTouchMoved/Ended 0x156D20/0x156E60, selectFlavorButtonClick:
#   0x157338, showSugarBag: 0x157424, chocolateClick: 0x1578F0, nextClick:
#   0x1579BC, skipClick: 0x157B30, showScrollView 0x157EE4, hideScrollView
#   0x158610, setColors: 0x157ECC (an NSLog stub).
#
# Mechanic, as read: the colour picker (aScrollView, nib frame
# (-20,43,320,366)). screenSetup calls showScrollView then hideScrollView
# back to back; hideScrollView first puts the panel back at its home
# (setCenter: orig, outside any animation block) and then animates it to
# orig.y - 500 over 0.25 s ease-out -- so on entry the panel is seen at home
# sliding up out of view (the port used to start it already hidden).
# showScrollView also brings aScrollView and then selectChocolateButton to
# the front, so the hotspot sits above the panel and toggles it. Picking a colour bakes "Candy Bar.png" through TintedIV's
# ALTERNATE path -- art drawn first, then the tint filled over it through
# CGBlendMode 3 (Overlay), clipped to the art (initWithAlternateImage:
# 0x4711C, changeAlternateColor: 0x474FC) -- and drops the bar in from
# +(-500) over 0.25s. Dragging the bar over the grater (nib (104,55,113,149))
# sets isGrating; a 0.1s timer then raises the pile's baseOrigPt.y by
# baseImg.height/30 per tick and accumulates grateTime; at 3.0s the next
# button slides in.
#
# The pile is a MaskedIV (0x46CE0): its frame is the MASK's size
# (chgum_pot_mask.png, 302x200 -- so setCenter (160,318) is a true centre)
# and drawRect clips to the mask and draws the base at baseOrigPt
# ((pileW-baseW)/2, 138) = (53,138). The port re-expresses that as a 302x200
# canvas the tinted pile art is blitted into at baseOrigPt, shown through
# core/MaskedSprite2D with the same mask -- applied UPSIDE DOWN
# (mask_flip_v), because MaskedIV drawRect: (0x46E68) clips with a
# CGImageMask inside UIKit's flipped context without flipping the CTM. This
# is the identical code path ccbSelectChocolate takes (same class, same
# chgum_pot_mask.png, same baseOrigPt 138), verified there on an iPhone 4
# running iOS 6.1.3: the pile starts hidden under the flipped bowl and rises
# into view while grating. The port used to show the whole pile at once
# below the pot here, the same bug the banana screen had.
#
# grateTime is a float ivar: 0.1f added in float32 reaches >= 3.0 on the
# 31st tick (2.9999993 after 30), so the step takes 3.1 s, not 3.0 -- the
# port accumulates through _f32() to match.
#
# PORT NOTES:
#  * The grate-fleck SSEmitter (nib `emitter`, (159,162,1,1)) is wired as
#    the original configures it in viewDidLoad
#    (0x156174, call 0x15664C) with tint nil -- selectedColor is still nil
#    there -- and re-tinted by setTint: in showSugarBag: (0x157424);
#    started when the bar first overlaps the grater and stopped on leaving
#    it (draggableTouchMoved: 0x156D20) or on release (draggableTouchEnded:
#    0x156E60). Unlike ccbSelectChocolate, nothing else stops it here:
#    grateTick's finish, nextClick: and viewWillDisappear: leave it alone.
#  * KEEP STATE: the controller survives under caStirIngredients;
#    viewWillAppear: (0x1566C8) re-runs screenSetup (0x156818), which RESETS
#    the step: "inst_select_chocolate" slid in (next hidden), a new 0.1 s
#    grateTimer, the pile's baseOrigPt back to y 138 (its tinted art stays,
#    now below the flipped bowl), isGrating/grateTime 0, the bar's image nil
#    and selectedColor nil (the emitter keeps its last tint), the mystery
#    badge unhidden, and showScrollView + hideScrollView (the panel slides
#    away again). A colour must be picked and grated again.
#  * PORT CHOICE: the nib's chocolate DraggableIV is imageless until a colour
#    is picked (screenSetup does setImage:nil), but it IS touchable --
#    initWithCoder: (0x46284) sets userInteractionEnabled YES -- and its
#    75x75 frame already overlaps the grater. On the phone, wiggling that
#    empty spot grates the untinted pile and brings next up; nextClick: then
#    does infoDict setObject:nil forKey:"Color" (selectedColor is nil), which
#    raises NSInvalidArgumentException. The port keeps the drag disabled
#    until a colour is chosen rather than ship that crash path.
#  * skipClick: (0x157B30) forwards to nextClick:, but no nib action targets
#    it -- dead here, kept as the same forward.
#
# Not ported (IAP, everything unlocked): contentLocked /
# lockedFlavorButtonClicked: 0x157774 / the locked button art and black_lock
# overlays in showScrollView (0x158158). (The mystery-flavour consumable IS
# ported -- see the block below.)

extends "res://core/Screen.gd"

## The colour picker's UIScrollView: UIKit's own drag /
## deceleration / bounce physics and its vertical scroll indicator
## (kcScrollView.gd header). Nib aScrollView (-20,43,320,366): no indicator, bounce or
## rate keys, so the defaults hold -- bounces YES, decelerationRate 0.998,
## indicators on; showScrollView (0x157EE4) sets contentSize (320, 100 * 11 =
## 1100) and never touches the offset, so a re-opened list is where it was
## left.
const ScrollView := preload("res://screens/kcScrollView.gd")

const MaskedSprite := preload("res://core/MaskedSprite2D.gd")
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")
const EMITTER_KEY := "caSelectChocolate.emitter"

## color_arr (0x155C40..0x156138): 33 UIColors, exactly as built. Entries
## 0..1 and 3..30 are colorWithHue:saturation:brightness:alpha:; entry 2 is
## +[UIColor brownColor] (0.6,0.4,0.2); 31..32 are colorWithRed:...
## Hue ladder 0.09375..0.84375 in steps of 3/32, each with a pale
## (s 0.3), a pure (s 1) and a dark translucent (b 0.7, a 0.7) variant.
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


## Port of -[TintedIV changeAlternateColor:] (0x474FC), the ALTERNATE tint:
## the art is the BACKDROP, the tint colour is filled over it as the SOURCE
## through the CGBlendMode, clipped to the art. That operand order is the
## reverse of changeColor: (0x47304, kcPourOil.bake_tint), so it gets its
## own bake. Blend modes are load-bearing -- never approximate with
## modulate.
static func bake_alt_tint(tex: Texture2D, tint: Color, mode: int) -> ImageTexture:
	if tex == null:
		return null
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var b := img.get_pixel(x, y)          # backdrop: the art
			var ab := b.a
			if ab <= 0.0:
				continue
			# The clip to the art softens the fill by the art's alpha.
			var as_ := tint.a * ab
			var bl := Color(
				_alt_blend(b.r, tint.r, mode),
				_alt_blend(b.g, tint.g, mode),
				_alt_blend(b.b, tint.b, mode))
			var ao := ab + as_ * (1.0 - ab)
			var co := Color(
				as_ * (1.0 - ab) * tint.r + as_ * ab * bl.r + (1.0 - as_) * ab * b.r,
				as_ * (1.0 - ab) * tint.g + as_ * ab * bl.g + (1.0 - as_) * ab * b.g,
				as_ * (1.0 - ab) * tint.b + as_ * ab * bl.b + (1.0 - as_) * ab * b.b)
			if ao > 0.0:
				img.set_pixel(x, y, Color(co.r / ao, co.g / ao, co.b / ao, ao))
			else:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)


## Cb = backdrop (art), Cs = source (the tint fill).
static func _alt_blend(cb: float, cs: float, mode: int) -> float:
	match mode:
		3:                                        # Overlay
			if cb <= 0.5:
				return 2.0 * cb * cs
			return 1.0 - 2.0 * (1.0 - cb) * (1.0 - cs)
		_:
			return cs                             # Normal: the fill wins


# -- geometry (nib caSelectChocolate + the addresses above) --------------

const PILE_CENTER := Vector2(160, 318)        # 0x43200000 / 0x439F0000
const PILE_SIZE := Vector2i(302, 200)         # chgum_pot_mask.png
const PILE_BASE_X := 53.0                     # (302 - 196)/2
const PILE_ORIG_Y0 := 138.0                   # 0x430A0000
const CHOC_FRAME := Rect2(123, 175, 75, 75)   # nib id 6 (DraggableIV)
const GRATER_RECT := Rect2(104, 55, 113, 149) # nib id 5
const PANEL_RECT := Rect2(-20, 43, 320, 366)  # nib id 7 (aScrollView)
const PANEL_SLIDE_DY := -500.0                # 0xC3FA0000
const PANEL_SLIDE_S := 0.25
## showScrollView button grid: (24 + 100*(i%3), 100*row, 80, 80)
## (0x42A00000); icon frame (15,15,50,50) (0x41700000 / 0x42480000).
const CELL_X0 := 24.0
const CELL_PITCH := 100.0
const CELL_SIZE := 80.0
const ICON_RECT := Rect2(15, 15, 50, 50)
## grateTick: 0.1s timer (0x3FB99999...), step = baseImg.h * 0.0333333
## (0x3D088889), done at grateTime >= 3.0.
const GRATE_TICK_S := 0.1
const GRATE_STEP_FRAC := 0.0333333351
const GRATE_DONE_S := 3.0
const CHOC_SNAP_S := 0.25

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
## The bar's "MoveChocolate" glide home, while it runs (_move_choc_home).
var _choc_tween: Tween
var _panel_tween: Tween
var _emitter: SSEmitter                        # nib `emitter`
## The shared infoDict (see caSelectStick._info).
var _info: Dictionary = {}

## Mystery flavour (PORTED):
##   initWithNibName: 0x155A98  Consumable DM_CONSUMABLE_MYSTERY_FLAVOR /
##     MysteryFlavor_50Chocolate, cost = CoinCosts."Candy Apple".
##     MysteryChocolate, 6 when absent; first-time message.
##   viewDidLoad 0x156174  ConsumableButton(btn_mystery_flavor, (0,-25) /
##     (65,3)) at centre (50, 350.5); buyMysteryFlavorClick:.
##   buyMysteryFlavorClick: 0x1572CC  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x156F80  quantity 0, a random colour (see
##     mystery_color) -> showSugarBag: (0x157424).
##   consumablePurchaseFailed:error:2 0x1571F8  "You do not have enough coins."
##   showScrollView (0x157EE4) zeroes the badge's alpha with next/back/
##   buyAll while the picker is up; hideScrollView (0x158610) restores it.
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_FLAVOR"
const MYSTERY_NAME := "MysteryFlavor_50Chocolate"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery flavor! You never know what flavor it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_flavor.png"
const MYSTERY_CENTER := Vector2(50, 350.5)

var _mystery: RefCounted
var _mystery_button: TextureButton


func on_enter() -> void:
	_info = GameState.custom_categories
	_build_pile()
	_build_chocolate()
	_restack_pot()
	_build_emitter()
	_build_mystery()
	_build_panel()
	_timer = Timer.new()
	_timer.wait_time = GRATE_TICK_S
	_timer.timeout.connect(_grate_tick)
	add_child(_timer)
	# viewWillAppear: -> screenSetup.
	_screen_setup()


## screenSetup (0x156818), run by every viewWillAppear: (0x1566C8):
## instruction, grate timer, pile reset, no selection, then showScrollView +
## hideScrollView back to back -- the panel is seen at home and slides up
## out of view (see header).
func _screen_setup() -> void:
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
## caStirIngredients (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from caStirIngredients: viewWillAppear: -> screenSetup (see header).
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		# CoinHUD re-adds the panel after this; drop the first appearance's.
		remove_child(old)
		old.queue_free()
	if _sv != null:
		_sv.call("cancel_tracking")
	_screen_setup()


## viewDidLoad (0x156174): the nib SSEmitter `emitter`, frame (159,162,1,1),
## configured with tint nil (call 0x15664C). Its nib slot is above chgum_pot
## and below the grater, so the flecks fall behind the grater and the pile.
func _build_emitter() -> void:
	var host := outlet("emitter")
	if host == null or host == self:
		return
	_emitter = SSEmitter.attach(host, SSEmitterConfigs.frame_size(EMITTER_KEY)) as SSEmitter
	SSEmitterConfigs.apply(_emitter, EMITTER_KEY, null)


## The pile is inserted below the nib's chocolate view (0x156174), i.e.
## above the grater and below back/next/buyAll; the bar is the nib view
## itself. Both are code-built here, so slot them under the back button.
func _restack_pot() -> void:
	var b := outlet("backButton")
	if b == null or b == self:
		return
	for node: Node in [_pile, _choc]:
		if node != null:
			move_child(node, (b as Node).get_index())


## grateTime and baseOrigPt are float32 in the original; GDScript floats are
## doubles. Round through a float32 store so tick counts match (31, not 30).
static func _f32(x: float) -> float:
	var a := PackedFloat32Array([x])
	return a[0]


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


## consumablePurchased: (0x156F80): quantity 0, a random colour, then
## showSugarBag:.
func _on_mystery_purchased(_free: bool) -> void:
	_mystery.set("quantity", 0)
	_show_sugar_bag(mystery_color())


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## MaskedIV(choc_pile, chgum_pot_mask) re-expressed: a mask-sized canvas the
## base art is blitted into at baseOrigPt, drawn through the mask.
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
	# MaskedIV applies the mask upside down (MaskedSprite2D.mask_flip_v;
	# header): the bowl lands at the TOP of the 302x200 view, so the pile at
	# baseOrigPt.y 138 starts hidden and rises into it while grating.
	_pile.mask_flip_v = true
	_pile.position = PILE_CENTER
	# Below the chocolate bar (insertSubview:belowSubview:, 0x156298); adding
	# it before _choc keeps that order.
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


func _choc_rect() -> Rect2:
	return Rect2(_choc.position - CHOC_FRAME.size * 0.5, CHOC_FRAME.size)


func _choc_moving() -> bool:
	return _choc_tween != null and _choc_tween.is_valid()


## Where a touch finds the bar. Both "MoveChocolate" blocks (showSugarBag:
## 0x157424, draggableTouchEnded: 0x156E60) are +beginAnimations:/
## commitAnimations, so the bar stays touchable while it glides -- hit-
## tested at its model centre (home), not where it is drawn (UIKit, see
## core/DraggableSprite2D.gd).
func _choc_hit_rect() -> Rect2:
	if _choc_moving():
		return Rect2(_choc_home - CHOC_FRAME.size * 0.5, CHOC_FRAME.size)
	return _choc_rect()


## "MoveChocolate": 0.25 s, curve 0 (ease-in-out), to the bar's home. A new
## UIView position animation replaces the one in flight.
func _move_choc_home() -> void:
	if _choc_moving():
		_choc_tween.kill()
	_choc_tween = create_tween()
	_choc_tween.tween_property(_choc, "position", _choc_home, CHOC_SNAP_S) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# -- the colour picker (showScrollView 0x157EE4) -------------------------

func _build_panel() -> void:
	_panel = Control.new()
	_panel.clip_contents = true
	_panel.position = PANEL_RECT.position + Vector2(0, PANEL_SLIDE_DY)
	_panel.size = PANEL_RECT.size
	_panel.visible = true
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
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
		var icon_tex := bake_alt_tint(bar, cols[i], 3)
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


## showScrollView (0x157EE4): bring aScrollView, then selectChocolateButton,
## to the front; toggle if already shown; else zero the chrome, park the
## panel 500 up and animate it home (0.25 s, curve 2 = ease-out).
func _show_panel() -> void:
	move_child(_panel, get_child_count() - 1)
	var sel := outlet("selectChocolateButton")
	if sel != null and sel != self:
		move_child(sel as Node, get_child_count() - 1)
	if _panel_shown:
		_hide_panel()      # showScrollView toggles (0x157F1A)
		return
	_panel_shown = true
	_set_chrome_alpha(0.0)
	_panel.position = PANEL_RECT.position + Vector2(0, PANEL_SLIDE_DY)
	_slide_panel(PANEL_RECT.position)


## hideScrollView (0x158610): restore the chrome, snap the panel to its home
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


## showScrollView zeroes the alpha of next/back/buyAll while the picker is
## up; hideScrollView restores them. An alpha-0 UIView also stops receiving
## touches, which Godot's modulate does not -- mirror that with disabled.
func _set_chrome_alpha(a: float) -> void:
	var nodes: Array = []
	for oname in ["nextButton", "backButton", "buyAllBtn"]:
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


## chocolateClick: (0x1578F0) -- the selectChocolateButton hotspot.
func _on_chocolateClick() -> void:
	Audio.play("button_press")
	_show_panel()


## selectFlavorButtonClick: (0x157338).
func _select_flavor(i: int) -> void:
	Audio.play("button_press")
	_hide_panel()
	var cols := colors()
	if i >= 0 and i < cols.size():
		_show_sugar_bag(cols[i])


## showSugarBag: (0x157424).
func _show_sugar_bag(color: Color) -> void:
	_pile_orig_y = PILE_ORIG_Y0
	var bar := _tex("Candy Bar.png")
	var bar_tinted := bake_alt_tint(bar, color, 3)
	if bar_tinted != null:
		_choc.texture = bar_tinted
		# The nib DraggableIV frame is 75x75; UIImageView scale-to-fill
		# squashes the 231x215 bar into it.
		_choc.scale = CHOC_FRAME.size / Vector2(bar_tinted.get_size())
		_choc.visible = true
	var pile_tinted := bake_alt_tint(_tex("choc_pile.png"), color, 3)
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
		_emitter.set_tint(color)               # [emitter setTint:]
	# The bar drops in from 500 above over 0.25s (curve 0, ease-in-out).
	if _choc_moving():
		_choc_tween.kill()
	_choc.position = _choc_home + Vector2(0, PANEL_SLIDE_DY)
	_move_choc_home()


# -- grating -------------------------------------------------------------

## grateTick (0x156AE0), on the 0.1s timer.
func _grate_tick() -> void:
	var n := outlet("nextButton")
	var next_hidden: bool = n == null or n == self or not (n as CanvasItem).visible
	if _grating and next_hidden:
		# float32 arithmetic, as the ivars are (header): 31 ticks to 3.0.
		_grate_time = _f32(_grate_time + _f32(GRATE_TICK_S))
		if _pile_base != null:
			_pile_orig_y = _f32(_pile_orig_y
				- _f32(float(_pile_base.get_height()) * _f32(GRATE_STEP_FRAC)))
		_redraw_pile()
		Audio.loop("grating")     # loopFile: is a no-op if already looping
	if _grate_time >= GRATE_DONE_S and next_hidden:
		Audio.stop("grating")
		show_next_button()


func _unhandled_input(event: InputEvent) -> void:
	if _panel_shown:
		_panel_input(event)
		return
	if _choc == null or not _choc.visible:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and not _dragging and _choc_hit_rect().has_point(mb.position):
			if _choc_moving():
				# Grabbed mid-glide: the drag takes over from the model. The
				# port used to hit-test the drawn bar and leave the glide
				# running, so a bar caught on its way home slid on home out
				# from under the finger, and draggableTouchMoved:'s grating
				# verdict described a spot the bar had left.
				# PORT CHOICE: UIKit's presentation would glide on toward
				# the finger for the rest of the 0.25 s; the port lands it.
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


## draggableTouchMoved: (0x156D20): grater.frame vs chocolate.frame.
func _choc_moved() -> void:
	if GRATER_RECT.intersects(_choc_rect()):
		if not _grating and _emitter != null:
			_emitter.start()
		_grating = true
	else:
		if _grating:
			if _emitter != null:
				_emitter.stop()
			Audio.stop("grating")
		_grating = false


## draggableTouchEnded: (0x156E60): stop grating, animate the bar home over
## 0.25s (curve 0), stop the sound.
func _choc_released() -> void:
	_grating = false
	if _emitter != null:
		_emitter.stop()
	_move_choc_home()
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


## nextClick: (0x1579BC): button_press, infoDict["Color"] = selectedColor,
## the pile's baseOrigPt handed on via setGratedBaseOrig:, push
## caStirIngredients (animated:NO in the original).
func _on_nextClick() -> void:
	Audio.play("button_press")
	if _has_color:
		_info["Color"] = _selected
	_info["GratedOrigY"] = _pile_orig_y
	GameState.custom_categories = _info
	Nav.next()


## skipClick: (0x157B30) forwards to nextClick: -- no nib action reaches it.
func _on_skipClick() -> void:
	_on_nextClick()


## viewWillDisappear: (0x156790): invalidate the timer, stop the sound.
func on_exit() -> void:
	if _sv != null:
		_sv.call("settle")                     # a flick in flight lands
	if _timer != null:
		_timer.stop()
	Audio.stop("grating")


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true


## backClick: (0x15794C): button_press, then pop. Screen's default pops
## silently, so every original back press was missing its click.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()
