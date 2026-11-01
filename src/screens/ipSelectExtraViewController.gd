# Ice Pop step 4 -- drop extras into the filled mold.
#
# From the original binary (disassembly at the ObjC method list's IMPs):
#   initWithDictionary: 0xFF68C, viewDidLoad 0xFF8E8, viewWillAppear: 0xFFC48,
#   screenSetup 0xFFE40, initFreezePop 0x1007C8,
#   loadFruitItemsToScrollview: 0x100110 (item loop 0x100592..0x1007A0),
#   flavorItemClicked: 0x101E58, addExtra:point: 0x102108,
#   sendSplash: 0x102328, addExtraToIcePop: 0x1023E4,
#   addExtraToIcePop:point: 0x10240C, touchesBegan:withEvent: 0x101B30,
#   getAverageUIColorFromUIImage: 0x100E28, nextClick: 0x100F90,
#   clearScrollViewItems 0x101D78, showNextButton 0x102694.
#
# This is TAP-TO-ADD, like msFruit: tapping an item closes the panel, flies
# the art along a quadratic CAKeyframe path onto the pop, and lands it as a
# DraggableIV the player can then slide around. The draggableTouch delegate
# methods are 4-byte stubs (0x101E4C/50/54) -- placed extras drag freely.
#
# PORTED QUIRK: addExtra:point:'s flight starts at the tapped button's
# frame.origin in scroll-CONTENT coordinates, not converted through the
# scroll offset -- scroll down far enough in the original and the flight
# starts below where you tapped. The port keeps content coordinates.
#
# addExtraToIcePop: (0x1023E4) lands EVERY extra at the fixed centre
# (160, 280); there is no randomness. Extras live in extraDetectionView,
# which the nib stacks BELOW PopsicleShapeView, so they sit under the glossy
# mold art; the flying copy is inserted just above extraDetectionView.
#
# The bake list (addExtraToIcePop:point: 0x10240C): extrasCount is bumped
# first; at 19 or less the new extra is appended, past that it REPLACES
# entry extrasCount % 20 -- the old view stays on screen but is no longer
# baked, and the list never grows past 19. ORIGINAL BUG: the 39th extra asks
# for index 19 of a 19-entry array (NSRangeException -- the app dies); the
# port keeps the extra on screen and simply does not list it (PORT CHOICE).
#
# KEEP-STATE: Nav keeps this screen under the freezer.
# Back from there runs viewWillAppear: -> screenSetup -> initFreezePop again,
# which REMOVES every placed extra and empties the bake list: the step comes
# back as on first entry (next hidden, shown again by the 3.0s timer or a
# touch). viewWillDisappear: forces the item list shut through
# loadFruitItemsToScrollview:, which plays "button_press" -- so leaving this
# screen (next, back, the coin store) always clicks once more.

extends "res://core/Screen.gd"

const DraggableSprite := preload("res://core/DraggableSprite2D.gd")
const ImageUtil := preload("res://core/ImageUtil.gd")
## Keep-state helpers shared with the kc screens.
const kcKit := preload("res://screens/kcKit.gd")
## The item list's UIScrollView: UIKit's own drag / deceleration /
## bounce physics and scroll indicator (kcScrollView.gd header). Nib
## aScrollView: no indicator / bounce / rate keys -- defaults (bounces YES,
## 0.998, indicators on). Open, its frame is (0,0,320,480) and its content
## (320, 80 * 5 + 124 = 524): 44 pt of vertical scroll.
const ScrollView := preload("res://screens/kcScrollView.gd")

const MASK_SIZE := Vector2i(320, 333)
## PopsicleJuice/Shape nib frames (0,121,320,333); stick (140,0,40,273).
const POP_FRAME := Rect2(0, 121, 320, 333)
const STICK_FRAME := Rect2(140, 0, 40, 273)

# -- item panel (loadFruitItemsToScrollview: 0x100110) -------------------

const ITEM_COUNT := 20                # loop bound 0x15 exclusive, 1..20
const ITEM_COLS := 4
const ITEM_X_PITCH := 80.0            # x = 80*((i-1)%4)
const ITEM_Y0 := 62.0                 # y = 62 + 80*row
const ITEM_Y_PITCH := 80.0
const ITEM_SIZE := 80.0
const ITEM_ICON_RECT := Rect2(10, 10, 60, 60)
## contentSize height = 124 + 80*(rows) (constant 0x7C in the loop tail).
const PANEL_EXTRA_H := 124.0
## Open: park at (0,-280,320,280), animate to (0,0,320,480) over 0.5s.
const PANEL_PARK_Y := -280.0
const PANEL_OPEN := Rect2(0, 0, 320, 480)
const PANEL_SLIDE := 0.5
## Category-button close target (0x1002AC): (0, -300, w, 280).
const PANEL_CLOSED_CATEGORY := Rect2(0, -300, 320, 280)
## Item-tap / outside-tap close target (0x10205C, 0x101CCA): (0,-200,w,200).
const PANEL_CLOSED_PICK := Rect2(0, -200, 320, 200)

# -- the flight (addExtra:point: 0x102108) -------------------------------

const FLIGHT_CONTROL := Vector2(120, -120)
const FLIGHT_END := Vector2(160, 280)
const FLIGHT_SECONDS := 0.75          # setDuration: double 0x3FE8...
## kCAAnimationPaced: constant speed along the curve, not uniform in the
## Bezier parameter. Arc length is tabulated over this many chords.
const FLIGHT_SAMPLES := 64
const SPLASH_DELAY := 0.8             # performSelector sendSplash: 0x3FE999...
const EXTRA_CAP := 20
const EXTRA_APPEND_MAX := 19          # extrasCount > 19 -> replace branch
const NEXT_DELAY := 3.0               # screenSetup showNextButton, 0x40080000
## nextClick: bake constants (0x100F90): an extra's frame origin maps to
## (x + 2, 333 - y + 121 - h) in a context flipped on both axes, i.e. its
## centre lands at (318 - cx, 454 - cy) in mold space. D12 = 2.0 at 0x101248.
const BAKE_X := 318.0
const BAKE_Y := 454.0
const BAKE_EXTRA_ALPHA := 0.8         # CGContextSetAlpha 0.8
## After the extras, the juice (moldLiquidImage, var_134) is drawn AGAIN at
## 0.1 (0x3DCCCCCD at 0x10136A) -- the 10% veil is the juice, not the mask.
const BAKE_VEIL_ALPHA := 0.1

static var _mask_cache: Dictionary = {}

var _info: Dictionary = {}
var _panel: Control
var _panel_content: Node2D
var _panel_open := false
var _panel_content_h := 0.0
var _sv: Node                         # kcScrollView (aScrollView)

var _drop_active := false
var _extras: Array = []               # the addedExtras bake list (<= 19)
var _extras_count := 0
var _next_shown := false              # !nextButton.isHidden
var _extra_layer: Node2D              # extraDetectionView
## viewWillAppear: disables next as well as back until enableBackButton.
var _next_locked := false
## Where the nib puts the next button; showNextButton slides from +500 to
## the model centre, which UIKit reads correctly even mid-slide.
var _next_home := Vector2.ZERO
## Every tween this screen starts (kcKit.track / settle, keep-state).
var _tweens: Array = []

## Mystery extras (ported):
##   initWithDictionary: 0xFF68C  Consumable DM_CONSUMABLE_MYSTERY_EXTRA /
##     MysteryExtra_40Ingredients, cost = CoinCosts."QuickFreeze Ice Pops".
##     MysteryExtras, 11 when absent; first-time message.
##   viewDidLoad 0xFF8E8  ConsumableButton(btn_mystery_extras, (0,-25) /
##     (65,3)) at centre (50, 350.5); buyMysteryExtraClick:.
##   buyMysteryExtraClick: 0x100D4C  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x100A90  addedExtras emptied, extraDetectionView's
##     subviews removed, quantity 0, extrasCount 0; five times a random
##     FP_Drop_Item_%d (1..20) goes straight to addExtraToIcePop: -- no
##     flight, no splash, and the next button is NOT shown here.
##   consumablePurchaseFailed:error:2 0x100C78  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_EXTRA"
const MYSTERY_NAME := "MysteryExtra_40Ingredients"
const MYSTERY_COST := 11
const MYSTERY_MESSAGE := "Try out mystery extras! A random combo of who knows what! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_extras.png"
const MYSTERY_CENTER := Vector2(50, 350.5)

var _mystery: RefCounted
var _mystery_button: TextureButton
const MYSTERY_EXTRAS := 5
const DROP_ITEM_KINDS := 20


func on_enter() -> void:
	# initWithDictionary: (0xFF68C) keeps its own copy of the pour's dict.
	_info = (GameState.get_meta("ip_info", {}) as Dictionary).duplicate()
	var edv := outlet("extraDetectionView")
	if edv is Node2D and edv != self:
		_extra_layer = edv as Node2D
	else:
		_extra_layer = Node2D.new()
		add_child(_extra_layer)
	var nb := outlet("nextButton")
	if nb != null and nb != self:
		_next_home = nb.get("position")
	# viewDidLoad (0xFF8E8): the badge; the item list is the port's panel.
	_build_mystery()
	_build_panel()
	_view_will_appear()


## UINavigationController keeps this controller under the freezer.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	kcKit.drop_coin_panel(self)
	_view_will_appear()


## viewWillDisappear: (0xFFDA8): LoadedSection = 1, then
## loadFruitItemsToScrollview: -- which therefore always takes its CLOSE
## branch: "button_press", the list slides to (0,-300,w,280) over 0.5s,
## badge alpha 1. A flight in progress lands while covered (settled; its
## sendSplash: timer still fires).
func on_exit() -> void:
	Audio.play("button_press")
	_close_panel(PANEL_CLOSED_CATEGORY)
	kcKit.settle(_tweens)
	if _sv != null:
		_sv.call("settle")


## viewWillAppear: (0xFFC48): back AND next disabled, enableBackButton
## (0xFFDFC) re-enables both 0.5s later (double 0x3FE0000000000000); then
## screenSetup (0xFFE40).
func _view_will_appear() -> void:
	_lock_nav()
	_screen_setup()


func _lock_nav() -> void:
	lock_back_button()
	_next_locked = true
	var n := outlet("nextButton")
	if n != null and n != self:
		n.set("disabled", true)
	await get_tree().create_timer(BACK_LOCKOUT).timeout
	_next_locked = false
	if is_instance_valid(n) and n != self and (n as CanvasItem).visible:
		n.set("disabled", false)


## screenSetup (0xFFE40): initFreezePop, next hidden, the list parked
## off the top, showNextButton in 3.0s, badge unhidden, the banner.
func _screen_setup() -> void:
	_init_freeze_pop()
	_set_next_visible(false)
	if _mystery_button != null:
		_mystery_button.visible = true
	change_instruction("inst_add_to_blender.png")   # screenSetup 0x1000FE
	get_tree().create_timer(NEXT_DELAY).timeout.connect(_show_next_timed)


func _tween() -> Tween:
	return kcKit.track(_tweens, create_tween())


## viewDidLoad: the ConsumableButton, and init's Consumable.
func _build_mystery() -> void:
	_mystery = ConsumableScript.new(MYSTERY_KEY, MYSTERY_NAME, MYSTERY_COST)
	_mystery.set("first_time_message", MYSTERY_MESSAGE)
	_mystery.set("on_purchased", _on_mystery_purchased)
	_mystery.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyMysteryExtra"
	b.call("setup", MYSTERY_ART, 0, -25, MYSTERY_COST, 65, 3)
	b.position = MYSTERY_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyMysteryExtraClick)
	add_child(b)
	_mystery_button = b


func _on_buyMysteryExtraClick() -> void:
	Audio.play("store")
	_mystery.call("purchase", self)


## consumablePurchased: (0x100A90).
func _on_mystery_purchased(_free: bool) -> void:
	# extraDetectionView's subviews all go, listed or not.
	for extra in _extra_layer.get_children():
		if extra is Sprite2D:
			extra.queue_free()
	_extras.clear()
	_extras_count = 0
	for i in MYSTERY_EXTRAS:
		var art := _tex("FP_Drop_Item_%d.png" % (randi() % DROP_ITEM_KINDS + 1))
		if art != null:
			_add_extra_to_pop(art)


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


# -- the pop tableau (initFreezePop 0x1007C8) ---------------------------

## initFreezePop: addedExtras emptied, extrasCount 0, every subview of
## extraDetectionView removed; then the stick, mold and juice art from the
## infoDict, each rotated pi.
func _init_freeze_pop() -> void:
	_extras.clear()
	_extras_count = 0
	for extra in _extra_layer.get_children():
		_extra_layer.remove_child(extra)
		extra.queue_free()
	var stick := outlet("PopsicleStickView")
	if stick is Sprite2D:
		var s := stick as Sprite2D
		var t := _tex(str(_info.get("stickFileString", "")))
		if t != null:
			s.texture = t
		_flip_about_center(s, STICK_FRAME)
	var shape := outlet("PopsicleShapeView")
	if shape is Sprite2D:
		var s2 := shape as Sprite2D
		var t2 := _tex(str(_info.get("moldFileString", "")))
		if t2 != null:
			s2.texture = t2
		_flip_about_center(s2, POP_FRAME)
	var juice := outlet("PopsicleJuiceView")
	if juice is Sprite2D:
		var j := juice as Sprite2D
		var img: Variant = _info.get("moldLiquidImage")
		if img is Image:
			j.texture = ImageTexture.create_from_image(img)
			# getAverageUIColorFromUIImage: (0x100E28) is byte-for-byte the
			# ImageUtil.average_color algorithm; stored to infoDict only.
			_info["juiceColor"] = ImageUtil.average_color(j.texture)
		else:
			j.texture = null
		_flip_about_center(j, POP_FRAME)


func _flip_about_center(s: Sprite2D, frame: Rect2) -> void:
	if not s.centered:
		s.centered = true
		s.position = frame.position + frame.size * 0.5
	s.rotation = PI


# -- the panel ---------------------------------------------------------

func _build_panel() -> void:
	_panel = Control.new()
	_panel.clip_contents = true
	_panel.position = Vector2(0, PANEL_PARK_Y)
	_panel.size = Vector2(320, 280)
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	# In front of the tableau, behind the chrome: where the nib scroll view
	# sat (below CategoryView and the nav buttons).
	var cat := outlet("CategoryView")
	if cat != null and cat != self:
		move_child(_panel, (cat as Node).get_index())

	_panel_content = Node2D.new()
	_panel.add_child(_panel_content)

	var bg := _tex("Sub_Button_Background.png")
	var rows := 0
	for i in ITEM_COUNT:
		var n := i + 1
		var col := i % ITEM_COLS
		var origin := Vector2(ITEM_X_PITCH * col, ITEM_Y0 + ITEM_Y_PITCH * rows)
		var item := Node2D.new()
		item.position = origin
		_panel_content.add_child(item)
		if bg != null:
			var b := Sprite2D.new()
			b.texture = bg
			b.centered = false
			b.scale = Vector2(ITEM_SIZE, ITEM_SIZE) / bg.get_size()
			item.add_child(b)
		var art := _tex("FP_Drop_Item_%d.png" % n)
		if art != null:
			# UIImageView (10,10,60,60) rotated pi -- the items hang
			# upside-down to match the upside-down mold.
			var icon := Sprite2D.new()
			icon.texture = art
			icon.position = ITEM_ICON_RECT.position + ITEM_ICON_RECT.size * 0.5
			icon.scale = ITEM_ICON_RECT.size / art.get_size()
			icon.rotation = PI
			item.add_child(icon)
		if n % ITEM_COLS == 0:
			rows += 1
	if ITEM_COUNT % ITEM_COLS != 0:
		rows += 1
	_panel_content_h = PANEL_EXTRA_H + ITEM_Y_PITCH * rows
	# The hit frame is the MODEL frame: open, (0,0,320,480) from the moment
	# the 0.5 s frame animation starts.
	_sv = ScrollView.new()
	_sv.name = "aScrollViewSim"
	add_child(_sv)
	_sv.call("configure", true, PANEL_OPEN, _panel_content_h)
	_sv.set("content", _panel_content)
	_sv.call("add_indicator", _panel, Rect2(Vector2.ZERO, PANEL_OPEN.size))
	_sv.connect("tapped", _on_panel_tapped)


## loadFruitItemsToScrollview: (0x100110) -- the category button toggle.
func _on_loadFruitItemsToScrollview() -> void:
	Audio.play("button_press")
	if _panel_open:
		_close_panel(PANEL_CLOSED_CATEGORY)
	else:
		_open_panel()


func _open_panel() -> void:
	_panel_open = true
	# buyMysteryExtra / buyAllBtn alpha 0 while the list is open.
	_set_mystery_alpha(0.0)
	_set_extras_enabled(false)
	_panel.visible = true
	_panel.position = Vector2(0, PANEL_PARK_Y)
	_panel.size = Vector2(320, 280)
	var tw := _tween()
	tw.set_parallel(true)
	tw.tween_property(_panel, "position", PANEL_OPEN.position, PANEL_SLIDE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(_panel, "size", PANEL_OPEN.size, PANEL_SLIDE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _close_panel(target: Rect2) -> void:
	if not _panel_open:
		return
	_panel_open = false
	_set_mystery_alpha(1.0)
	_set_extras_enabled(true)
	var tw := _tween()
	tw.set_parallel(true)
	tw.tween_property(_panel, "position", target.position, PANEL_SLIDE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(_panel, "size", target.size, PANEL_SLIDE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.chain().tween_callback(func() -> void:
		if not _panel_open:
			_panel.visible = false)


## Alpha 0 also means "not tappable" to UIKit's hit test.
func _set_mystery_alpha(a: float) -> void:
	if _mystery_button == null:
		return
	_mystery_button.modulate.a = a
	_mystery_button.mouse_filter = Control.MOUSE_FILTER_STOP if a > 0.0 \
		else Control.MOUSE_FILTER_IGNORE


## The open list is a full-screen scroll view above extraDetectionView, so
## placed extras cannot be grabbed through it.
func _set_extras_enabled(on: bool) -> void:
	for extra in _extra_layer.get_children():
		if extra is Sprite2D and extra.has_method("is_dragging"):
			extra.set("enabled", on)


# -- input -------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _panel_open:
		_panel_input(event)
		return
	## touchesBegan:withEvent: (0x101B30): a bare screen touch shows the
	## next button ("cancel" sound) and closes the panel if it is up.
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_touch_shows_next()


## touchesBegan:'s first half: while next is still hidden, any bare touch
## plays "cancel" and shows it.
func _touch_shows_next() -> void:
	if not _next_shown:
		Audio.play("cancel")
		_show_next()


## The open list: the scroll view takes the touches (drag, flick, tap).
func _panel_input(event: InputEvent) -> void:
	if _sv != null and _sv.call("handle_input", event):
		get_viewport().set_input_as_handled()


## A touch that never became a drag reaches what is under it: an item
## button (touchUpInside: the release must stay within its bounds + 70 pt),
## or the scroll view itself, which passes it up to touchesBegan:.
## INFERRED: the original's touchesBegan: runs at touch-DOWN (after UIKit's
## delaysContentTouches hold, ~0.15 s); the port runs it with the tap.
func _on_panel_tapped(press: Vector2, release: Vector2) -> void:
	for i in ITEM_COUNT:
		var col := i % ITEM_COLS
		var row := int(float(i) / ITEM_COLS)
		var rect := Rect2(ITEM_X_PITCH * col, ITEM_Y0 + ITEM_Y_PITCH * row,
			ITEM_SIZE, ITEM_SIZE)
		if rect.has_point(press):
			if ScrollView.release_inside(rect, release):
				_item_clicked(i, rect.position)
			return
	# A tap on the open panel's dead space reaches touchesBegan: its
	# next-button half first, then (list open: frame.origin.y >= -1) a
	# second "cancel" and the close to (0,-200,320,200).
	_touch_shows_next()
	Audio.play("cancel")
	_close_panel(PANEL_CLOSED_PICK)


## flavorItemClicked: (0x101E58).
func _item_clicked(index: int, content_origin: Vector2) -> void:
	if _drop_active:
		return
	if not _next_shown:
		_show_next()
	Audio.play("button_press")
	_close_panel(PANEL_CLOSED_PICK)
	var art := _tex("FP_Drop_Item_%d.png" % (index + 1))
	if art == null:
		return
	_fly_extra(art, content_origin)


## addExtra:point: (0x102108): a quadratic CAKeyframe flight from the
## tapped item's frame.origin (content coords -- see header) through
## control (120,-120) to (160,280) over 0.75s; the splash and the landed
## extra follow at the 0.8s mark (sendSplash: 0x102328).
func _fly_extra(art: Texture2D, start: Vector2) -> void:
	_drop_active = true
	var drop := Sprite2D.new()
	drop.texture = art
	drop.position = start
	# insertSubview:aboveSubview:extraDetectionView -- under the mold art.
	add_child(drop)
	move_child(drop, _extra_layer.get_index() + 1)
	var table := _arc_table(start)
	var tw := _tween()
	tw.tween_method(_flight_step.bind(start, drop, table), 0.0, 1.0,
		FLIGHT_SECONDS)
	get_tree().create_timer(SPLASH_DELAY).timeout.connect(
		_splash.bind(drop, art))


static func _bezier(start: Vector2, u: float) -> Vector2:
	var a := start.lerp(FLIGHT_CONTROL, u)
	var b := FLIGHT_CONTROL.lerp(FLIGHT_END, u)
	return a.lerp(b, u)


## Cumulative chord lengths along the quadratic, FLIGHT_SAMPLES + 1 entries.
static func _arc_table(start: Vector2) -> PackedFloat32Array:
	var table := PackedFloat32Array()
	table.append(0.0)
	var prev := start
	for i in range(1, FLIGHT_SAMPLES + 1):
		var p := _bezier(start, float(i) / FLIGHT_SAMPLES)
		table.append(table[i - 1] + prev.distance_to(p))
		prev = p
	return table


## Paced: time fraction t is a fraction of the path LENGTH.
func _flight_step(t: float, start: Vector2, drop: Sprite2D,
		table: PackedFloat32Array) -> void:
	if not is_instance_valid(drop):
		return
	var target := t * table[FLIGHT_SAMPLES]
	var i := 1
	while i < FLIGHT_SAMPLES and table[i] < target:
		i += 1
	var seg := table[i] - table[i - 1]
	var f := 0.0 if seg <= 0.0 else (target - table[i - 1]) / seg
	drop.position = _bezier(start, (float(i - 1) + clampf(f, 0.0, 1.0))
		/ FLIGHT_SAMPLES)


## sendSplash: (0x102328). A performSelector:afterDelay: -- it fires even
## while a pushed screen covers this one, as here.
func _splash(drop: Sprite2D, art: Texture2D) -> void:
	Audio.play("ms_splash")
	if is_instance_valid(drop):
		drop.queue_free()
	_drop_active = false
	_add_extra_to_pop(art)


## addExtraToIcePop:point: (0x10240C): a DraggableIV at the fixed (160,280)
## in extraDetectionView, freely draggable; bake list per the header.
func _add_extra_to_pop(art: Texture2D) -> void:
	_extras_count += 1
	var extra: Sprite2D = DraggableSprite.new()
	extra.texture = art
	extra.position = FLIGHT_END
	_extra_layer.add_child(extra)
	if _panel_open:
		extra.set("enabled", false)
	if _extras_count > EXTRA_APPEND_MAX:
		var slot := _extras_count % EXTRA_CAP
		# PORT CHOICE: index 19 crashed the original (see header).
		if slot < _extras.size():
			_extras[slot] = extra
	else:
		_extras.append(extra)


# -- next --------------------------------------------------------------

## screenSetup's performSelector:@selector(showNextButton) afterDelay:3.0.
## Unconditional: if a touch already showed next, it slides in AGAIN.
## Fired while covered, it is undone by the next viewWillAppear: anyway.
func _show_next_timed() -> void:
	if is_inside_tree():
		_show_next()


## showNextButton (0x102694): instIV hidden, next jumps +500 right of its
## model centre and slides home, 0.25s.
func _show_next() -> void:
	_next_shown = true
	var n := outlet("nextButton")
	if n != null and n != self:
		n.set("position", _next_home)
	_set_next_visible(true)
	show_next_button()
	if _next_locked and n != null and n != self:
		n.set("disabled", true)


## CG image mask -> alpha image (black paints). Cached per file.
static func _mask_image(file: String) -> Image:
	if _mask_cache.has(file):
		return _mask_cache[file]
	if not Assets.has_image(file):
		return null
	var tex: Texture2D = Assets.texture(file)
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var out := Image.create(img.get_width(), img.get_height(), false,
		Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			out.set_pixel(x, y, Color(1, 1, 1, (1.0 - lum) * c.a))
	_mask_cache[file] = out
	return out


## nextClick: (0x100F90): bake the finished juice -- the poured liquid
## screenshot, each listed extra at alpha 0.8, then the liquid again at 10%
## over them, all clipped to FP_Pop_Mask_N -- and hand the freezer its four
## images. The clip is set in the raw UIKit context BEFORE the CTM flip, so
## the mask lands vertically flipped (the MaskedIV quirk; it matches the
## pour screen, whose liquid already carries the same flipped coverage).
## Extra centres map into mold space as (318 - cx, 454 - cy): the mold view
## sits at (0,121,320,333) rotated pi, 454 = 333 + 121, and the original
## nudges every extra 2 px (constants at 0x101248..0x101300).
func _on_nextClick() -> void:
	Audio.play("button_press")
	var mold_file := str(_info.get("moldFileString", ""))
	var mask_file := mold_file.replace("Shape", "Mask")
	var mask := _mask_image(mask_file)
	var juice := Image.create(MASK_SIZE.x, MASK_SIZE.y, false,
		Image.FORMAT_RGBA8)

	var prev: Variant = _info.get("moldLiquidImage")
	var liquid: Image = null
	if prev is Image:
		liquid = (prev as Image).duplicate()
		if liquid.is_compressed():
			liquid.decompress()
		liquid.convert(Image.FORMAT_RGBA8)
		_blend_masked(juice, liquid, Vector2i.ZERO, mask, 1.0)

	for e in _extras:
		if not is_instance_valid(e):
			continue
		var s := e as Sprite2D
		if s.texture == null:
			continue
		var img := s.texture.get_image()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		# The bake context is flipped in both axes (CGContextScaleCTM -1,-1
		# at 0x1011D6), so the art rotates 180 degrees on its way into
		# upright mask space -- the upside-down-authored extras land upright
		# on the finished pop.
		img.rotate_180()
		var c := Vector2(BAKE_X - s.position.x, BAKE_Y - s.position.y)
		var tl := c - img.get_size() * 0.5
		_blend_masked(juice, img, Vector2i(tl.round()), mask,
			BAKE_EXTRA_ALPHA)

	# RestoreGState, alpha 0.1, the juice image once more (see BAKE_VEIL).
	if liquid != null:
		_blend_masked(juice, liquid, Vector2i.ZERO, mask, BAKE_VEIL_ALPHA)

	GameState.set_meta("ip_freezer", {
		"stickImg": str(_info.get("stickFileString", "")),
		"moldImg": mold_file,
		"textureImg": mold_file.replace("Shape", "Real"),
		"juiceImg": juice,
	})
	GameState.set_meta("ip_info", _info.duplicate())
	Nav.next()


## src over dst at `alpha`, clipped by the mask's alpha read with its rows
## flipped (CGContextClipToMask in the unflipped UIKit context), at an
## integer offset.
static func _blend_masked(dst: Image, src: Image, at: Vector2i,
		mask: Image, alpha: float) -> void:
	var mask_h := 0 if mask == null else mask.get_height()
	for sy in src.get_height():
		var dy := at.y + sy
		if dy < 0 or dy >= dst.get_height():
			continue
		for sx in src.get_width():
			var dx := at.x + sx
			if dx < 0 or dx >= dst.get_width():
				continue
			var m := 1.0 if mask == null \
				else mask.get_pixel(dx, mask_h - 1 - dy).a
			if m <= 0.0:
				continue
			var s := src.get_pixel(sx, sy)
			var a := s.a * alpha * m
			if a <= 0.0:
				continue
			var d := dst.get_pixel(dx, dy)
			var out_a := a + d.a * (1.0 - a)
			if out_a <= 0.0:
				continue
			dst.set_pixel(dx, dy, Color(
				(s.r * a + d.r * d.a * (1.0 - a)) / out_a,
				(s.g * a + d.g * d.a * (1.0 - a)) / out_a,
				(s.b * a + d.b * d.a * (1.0 - a)) / out_a,
				out_a))


## backClick: (0x100DB8): button_press, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


func _set_next_visible(on: bool) -> void:
	if not on:
		_next_shown = false
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.set("disabled", not on or _next_locked)
