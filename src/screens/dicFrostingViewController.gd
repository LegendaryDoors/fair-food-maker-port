# Donut Ice Cream Sandwich step 7 -- choose the icing, then hand the
# finished sandwich to MakeViewController.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithColors: 0xD95C4 (the same 33-colour table as the scoop screen),
#   viewDidLoad 0xD9A14, viewWillAppear: 0xD9B84, resetScreen 0xD9BC4,
#   icingClick: 0xD9C9C, nextClick: 0xD9D68 (the bake), showScrollView
#   0xDAC68, tintIceCreamOnDonutWithColors: 0xDB284, showFrostingWithColor:
#   0xDB3A8, hideScrollView 0xDB458, selectIcingButtonClick: 0xDB590,
#   panel-fade blocks sub_DB240 / sub_DB550;
#   -[UIImage tintedImageWithColor:] 0x144204 (TintedIV ALTERNATE path,
#   CGBlendMode 3 / Overlay -> caSelectChocolate.bake_alt_tint).
#
# Mechanic, as read:
#  * viewDidLoad re-tints iceCream1..3 with the colours the scoop screen
#    chose (initWithColors: receives them from sub_BC338; the port reads
#    GameState.custom_categories["iceCreamColors"]). Entered standalone with
#    no colours the port leaves the scoops plain -- absent, not invented.
#  * The frostingButton toggles the same picker as the scoop screen (80x80
#    cells, x 24+100*(i%3), y 95*row, icon (15,15,50,50), 0.1s fade, chrome
#    to alpha 0) but tints dis_donut_icing_select_01.png. Closing it by
#    toggle re-shows the next button IF an icing was already chosen.
#  * selectIcingButtonClick: tints dis_donut_icing_01.png with the picked
#    colour into `frosting`, shows it plus the untinted dis_donut_icing_02
#    gloss, hides the picker AND the instruction, and slides the next
#    button in. hideScrollView itself always re-slides inst_choose_icing --
#    ordering kept (the subsequent hide wins).
#
# nextClick: (0xD9D68) bakes eight layers into MakeViewController's
# customCategories (the port's GameState.custom_categories), each
# {Properties, Image}. ItemCenterX/Y are the art's TOP-LEFT (zero-frame
# DecorateItemView). Floats read from the MOVS R2 / MOVT R2 immediates at
# the numberWithFloat: call sites (disassembly 0xD9EA0..0xDA6CC; the port's
# earlier table was 1pt too low on five rows):
#   DonutPlate      dis_plate.png            inedible VI 2  (0,163)
#   DonutBottom     donutBottom.image        edible  VI 5  (37,162)   L2
#   DonutIceCream1  iceCream1.image (tinted) edible  VI 6  (40,164)   L2
#   DonutIceCream2  iceCream2.image (tinted) edible  VI 7  (115,164)  L2
#   DonutIceCream3  iceCream3.image (tinted) edible  VI 8  (77,196)   L2
#   DonutTop        donutTop.image           edible  VI 9  (37,110)   L2
#   Frosting        frosting.image (tinted)  edible  VI 10 (37,110)   L2
#   FrostingGloss   frostingGloss.image      edible  VI 11 (37,110)   L2
# (0x43230000=163, 0x43220000=162, 0x42200000=40, 0x43240000=164,
# 0x42E60000=115, 0x429A0000=77, 0x43440000=196, 0x42140000=37,
# 0x42DC0000=110.) Every row is its nib frame on this screen moved up by
# exactly 50pt (plate 213, bottom 212, scoops 214/214/246, top 160), so
# the sandwich keeps its on-screen shape on Make. classStr "Donut Ice
# Cream Sandwich" is set by MakeViewController's own mapping from
# GameState.food.
#
# KEEP-STATE: kept alive under the push to Make. The
# scoop tints and the picker are built once (viewDidLoad); resetScreen
# (viewWillAppear:) runs on entry and in on_resume. No on_exit: the class
# has no disappear methods. The bake reads the live views, so a second
# nextClick: after a return bakes what is on screen then.

extends "res://core/Screen.gd"

const UIKit := preload("res://screens/msUIKit.gd")

const caSelectChocolate := preload("res://screens/caSelectChocolate.gd")

## Panel geometry (showScrollView 0xDAC68) -- identical to the scoop
## screen's, icing art instead of scoop art.
const PANEL_RECT := Rect2(0, 55, 320, 365)
const CELL_X0 := 24.0
const CELL_X_PITCH := 100.0
const CELL_Y_PITCH := 95.0
const CELL_SIZE := 80.0
const ICON_RECT := Rect2(15, 15, 50, 50)
const CONTENT_ROW_H := 100.0
const PANEL_FADE := 0.1

## The bake table (nextClick: 0xD9D68); see header for the raw floats.
const BAKE := [
	{"key": "DonutPlate", "src": "plate", "edible": false, "vi": 2,
		"at": Vector2(0, 163), "layer": -1},
	{"key": "DonutBottom", "src": "donutBottom", "edible": true, "vi": 5,
		"at": Vector2(37, 162), "layer": 2},
	{"key": "DonutIceCream1", "src": "iceCream1", "edible": true, "vi": 6,
		"at": Vector2(40, 164), "layer": 2},
	{"key": "DonutIceCream2", "src": "iceCream2", "edible": true, "vi": 7,
		"at": Vector2(115, 164), "layer": 2},
	{"key": "DonutIceCream3", "src": "iceCream3", "edible": true, "vi": 8,
		"at": Vector2(77, 196), "layer": 2},
	{"key": "DonutTop", "src": "donutTop", "edible": true, "vi": 9,
		"at": Vector2(37, 110), "layer": 2},
	{"key": "Frosting", "src": "frosting", "edible": true, "vi": 10,
		"at": Vector2(37, 110), "layer": 2},
	{"key": "FrostingGloss", "src": "frostingGloss", "edible": true, "vi": 11,
		"at": Vector2(37, 110), "layer": 2},
]

var _colors: Array[Color] = []
var _panel: Control
var _content: Node2D
var _content_h := 0.0
var _panel_shown := false
## contentOffset.y, fed by the scroll physics.
var _panel_scroll := 0.0
## The scrollView's UIScrollView touches and motion, and the press
## it is tracking.
var _physics: UIKit.ScrollPhysics
var _tracking := false
var _press := Vector2.ZERO
var _frosted := false


## changeInstruction: (0xDAA38) ends with nextButton setHidden:YES.
func instruction_hides_next() -> bool:
	return true


## UINavigationController keeps this controller alive under the push to
## MakeViewController; Nav calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## initWithColors: (0xD95C4) + viewDidLoad (0xD9A14) once, then
## viewWillAppear: (0xD9B84 -> resetScreen).
func on_enter() -> void:
	_colors = caSelectChocolate.colors()   # 0xD95C4, same 33 entries
	_tint_scoops()
	_build_panel()
	_reset_screen()


## Back from Make: resetScreen hides the frosting and gloss and the picker,
## hides next and re-slides inst_choose_icing -- the icing is chosen again.
## The scoop tints from viewDidLoad stay. No disappear methods in the class.
func on_resume() -> void:
	_reset_screen()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## tintIceCreamOnDonutWithColors: (0xDB284), fed from viewDidLoad (0xD9A14).
func _tint_scoops() -> void:
	var carried: Variant = GameState.custom_categories.get("iceCreamColors")
	if not (carried is Array) or (carried as Array).size() < 3:
		return   # standalone entry: scoops stay plain rather than invented
	for i in 3:
		var s := outlet("iceCream%d" % (i + 1)) as Sprite2D
		var c: Variant = (carried as Array)[i]
		if s == null or not (c is Color):
			continue
		var tinted := caSelectChocolate.bake_alt_tint(
			_tex("dis_icecream_scoop.png"), c, 3)
		if tinted != null:
			s.texture = tinted


## resetScreen (0xD9BC4).
func _reset_screen() -> void:
	_hide_panel_now()
	var next := first_outlet(NEXT_OUTLETS)
	if next != null:
		(next as CanvasItem).visible = false
	for n: String in ["frosting", "frostingGloss"]:
		var v := outlet(n)
		if v != null and v != self:
			(v as CanvasItem).visible = false
	_frosted = false
	change_instruction("inst_choose_icing.png")


# -- the icing picker -------------------------------------------------

func _build_panel() -> void:
	_panel = Control.new()
	_panel.clip_contents = true
	_panel.position = PANEL_RECT.position
	_panel.size = PANEL_RECT.size
	_panel.modulate.a = 0.0
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	_content = Node2D.new()
	_panel.add_child(_content)

	var bg := _tex("Sub_Button_Background.png")
	var art := _tex("dis_donut_icing_select_01.png")
	var row := 0
	for i in _colors.size():
		var cell := Node2D.new()
		cell.position = Vector2(CELL_X0 + CELL_X_PITCH * (i % 3),
			CELL_Y_PITCH * row)
		_content.add_child(cell)
		if bg != null:
			var b := Sprite2D.new()
			b.texture = bg
			b.centered = false
			b.scale = Vector2(CELL_SIZE, CELL_SIZE) / bg.get_size()
			cell.add_child(b)
		var icon_tex := caSelectChocolate.bake_alt_tint(art, _colors[i], 3)
		if icon_tex != null:
			var icon := Sprite2D.new()
			icon.texture = icon_tex
			icon.position = ICON_RECT.position + ICON_RECT.size * 0.5
			icon.scale = ICON_RECT.size / Vector2(icon_tex.get_size())
			cell.add_child(icon)
		if i % 3 == 2:
			row += 1
	_content_h = CONTENT_ROW_H * (row + (0 if _colors.size() % 3 == 0 else 1))
	# showScrollView (0xDAC68): setContentSize:(320, 100 * rows); everything else
	# is the nib's default (bounces, Normal deceleration, both indicators on
	# -- only the vertical can show: 320 of 320 across). contentOffset is
	# never reset, so a re-opened picker shows where it was left.
	_physics = UIKit.ScrollPhysics.new(PANEL_RECT.size,
		Vector2(PANEL_RECT.size.x, _content_h))
	_physics.name = "UIScrollPhysics"
	add_child(_physics)
	_physics.scrolled.connect(func(o: Vector2) -> void:
		_panel_scroll = o.y
		_content.position.y = -o.y)
	_physics.attach_indicators(_panel, Rect2(Vector2.ZERO, PANEL_RECT.size))


## icingClick: (0xD9C9C) -> showScrollView (0xDAC68), a toggle. Toggling it
## closed re-shows the next button if an icing was already chosen.
func _on_icingClick() -> void:
	Audio.play("button_press")
	if _panel_shown:
		_hide_panel()
		if _frosted:
			show_next_button()
		return
	move_child(_panel, get_child_count() - 1)   # bringSubviewToFront: (0xDAC68)
	var inst := _instruction_node()
	if inst == null or not inst.visible:
		change_instruction("inst_choose_icing.png")
	_set_chrome_alpha(0.0)
	_panel.visible = true
	create_tween().tween_property(_panel, "modulate:a", 1.0, PANEL_FADE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_panel_shown = true


## hideScrollView (0xDB458): always re-slides inst_choose_icing.
func _hide_panel() -> void:
	if not _panel_shown:
		return
	_cancel_panel_touch()
	change_instruction("inst_choose_icing.png")
	_set_chrome_alpha(1.0)
	create_tween().tween_property(_panel, "modulate:a", 0.0, PANEL_FADE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_panel_shown = false


func _hide_panel_now() -> void:
	_cancel_panel_touch()
	_panel.modulate.a = 0.0
	_panel.visible = false
	_panel_shown = false
	_set_chrome_alpha(1.0)


func _set_chrome_alpha(a: float) -> void:
	for oname: Array in [NEXT_OUTLETS, BACK_OUTLETS]:
		var o := first_outlet(oname)
		if o != null and o is CanvasItem:
			var ci := o as CanvasItem
			ci.modulate.a = a
			if ci.has_method("set_disabled"):
				ci.set("disabled", a <= 0.0)


## selectIcingButtonClick: (0xDB590).
func _select_icing(i: int) -> void:
	Audio.play("button_press")
	if i < 0 or i >= _colors.size():
		return
	_show_frosting(_colors[i])
	_hide_panel()
	dismiss_instruction()
	show_next_button()


## showFrostingWithColor: (0xDB3A8).
func _show_frosting(c: Color) -> void:
	var frosting := outlet("frosting") as Sprite2D
	if frosting != null:
		var tinted := caSelectChocolate.bake_alt_tint(
			_tex("dis_donut_icing_01.png"), c, 3)
		if tinted != null:
			frosting.texture = tinted
		frosting.visible = true
	var gloss := outlet("frostingGloss")
	if gloss != null and gloss != self:
		(gloss as CanvasItem).visible = true
	_frosted = true


# -- the bake (nextClick: 0xD9D68) ------------------------------------

func _on_nextClick() -> void:
	Audio.play("button_press")
	var out := {}
	for entry: Dictionary in BAKE:
		var img := _layer_image(entry["src"])
		if img == null:
			continue
		var props := {
			"IsEdible": entry["edible"], "ViewIndex": entry["vi"],
			"Type": "Stationary",
			"ItemCenterX": (entry["at"] as Vector2).x,
			"ItemCenterY": (entry["at"] as Vector2).y,
		}
		if int(entry["layer"]) >= 0:
			props["Layer"] = int(entry["layer"])
		out[entry["key"]] = {"Properties": props, "Image": img}
	GameState.custom_categories = out
	Nav.next()   # falls off the dic step list into MakeViewController


## The original reads each UIImageView's live image -- tinted where tinted.
func _layer_image(src: String) -> Image:
	var tex: Texture2D = null
	if src == "plate":
		tex = _tex("dis_plate.png")
	else:
		var s := outlet(src) as Sprite2D
		if s != null:
			tex = s.texture
	if tex == null:
		return null
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	return img


# -- panel scrolling / tapping (same idiom as the scoop screen) --------

## A press inside the scroll view's frame is the UIScrollView's
## (UIKit.ScrollPhysics: a drag after 10 pt with UIKit's momentum and
## bounce); released before that it is a tap on the cell under the press.
## Moves and the release are read in _input so a drag keeps tracking
## wherever the finger goes.
func _unhandled_input(event: InputEvent) -> void:
	if not _panel_shown or not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if not PANEL_RECT.has_point(mb.position):
		return
	_tracking = true
	_press = mb.position
	_physics.touch_began(mb.position)
	get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not _tracking:
		return
	if event is InputEventMouseMotion:
		_physics.touch_moved((event as InputEventMouseMotion).position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT or mb.pressed:
			return
		_tracking = false
		if _physics.touch_ended(mb.position) and _panel_shown:
			_panel_tap(_press)
		get_viewport().set_input_as_handled()


func _cancel_panel_touch() -> void:
	if _tracking and _physics != null:
		_physics.touch_cancelled()
	_tracking = false


func _panel_tap(pos: Vector2) -> void:
	var local := pos - _panel.position + Vector2(0, _panel_scroll)
	for i in _colors.size():
		var rect := Rect2(Vector2(CELL_X0 + CELL_X_PITCH * (i % 3),
			CELL_Y_PITCH * int(float(i) / 3.0)), Vector2(CELL_SIZE, CELL_SIZE))
		if rect.has_point(local):
			_select_icing(i)
			return


## backClick: (0xD9CF8): button_press, pop. (Without this override the
## base Screen back was silent.)
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()
