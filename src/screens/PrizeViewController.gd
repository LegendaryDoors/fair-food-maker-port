# The prize shelf a midway game opens from its prize button.
#
# From the original binary and nib:
#   nib: bg_prizes (0,0), bg_prizes_frame (0,0), btn_back (0,424,90,56) ->
#        back:, btn_next (230,424,90,56) -> next:, scrollableGridView
#        (0,73,320,340) -- last subview, so above the frame art.
#   callers (bpTossDartVC prizeClick: 0x116508 and the six others): alloc/init,
#        setBackgroundFile:, setPrizes:[PrizeManager getPrizesForGame:<game>],
#        push, play "trophy_door" (fish toss: "trophy_water"). The port's
#        callers fill GameState.screen_args["PrizeViewController"] =
#        {"prizes": [IAPKey...], "background_file": "..."} instead.
#   viewDidLoad           0x11278  grid: XOffset 9, YOffset 0, XSpacing 8,
#                                  YSpacing 0, 3 per row; gridBackground = a
#                                  CLEAR 95x138 image; separator
#                                  bg_prizes_shelf.png at separatorXOffset 13,
#                                  separatorYOffset -10; addLastSeparator;
#                                  showAnimated:NO.
#   viewWillAppear:       0x11434  selectedGridItemView nil; loadItems.
#   viewDidDisappear:     0x11488  unloadItems (loadItems: nil).
#   loadItems             0x114DC  one GridItem per PrizeManager prize, in
#                                  table order, whose IAPKey is in `prizes`
#                                  -- or every prize when `prizes` is nil;
#                                  imagePath = Image, data = the dict,
#                                  category = Game. Then contentMode 1
#                                  (aspect fit) on every cell and its image.
#   setOverlayViewsToGridViews: 0x121B8  per cell: dontLoadImage YES,
#                                  userInteractionEnabled NO; prize_label.png
#                                  centred at (w/2, h - labelH/2) with a 74x14
#                                  UILabel at (labelW/2, 16): system font 12,
#                                  minimumFontSize 6, adjustsFontSizeToFitWidth,
#                                  centred, the prize Name. Unlocked
#                                  (boolForKey:IAPKey): the prize Image as the
#                                  cell image. Locked: prize_unknown.png added
#                                  at centre (its own centre x, 80) and the
#                                  cell image cleared.
#   back:                 0x11960  button_press, pop.
#   next:                 0x119D0  button_press; push MakeViewController with
#                                  classStr "TROPHY_CASE", customCategories
#                                  {"Prize_Background": {Properties:
#                                  {IsEdible NO, ViewIndex 1, Type
#                                  "Stationary", ItemCenterX 0, ItemCenterY 0},
#                                  Image: imageNamed:(backgroundFile)}} and
#                                  infoDict {"Items": [the PrizeManager dict
#                                  of every key in `prizes`]}.
#
# Unreachable, so not ported: gridItemViewClicked: (0x11FC8),
# selectGridItemView: (0x12084) and share: (0x11D80). Every cell has user
# interaction disabled by the overlay pass, and share: has no button in this
# nib.
#
# PORT CHOICE: the TROPHY_CASE push hands its arguments over through
# GameState.screen_args["MakeViewController"] = {"class_str", "custom_categories",
# "info_dict"}; MakeViewController reads them on entry.

extends "res://core/Screen.gd"
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const ScrollableGridView := preload("res://core/ScrollableGridView.gd")

## nib object 5, the UIClassSwapper -> ScrollableGridView.
const GRID_FRAME := Rect2(0, 73, 320, 340)
## viewDidLoad (floats decoded: 9.0, 0.0, 8.0, 0.0; 95x138; 13.0, -10.0).
const X_OFFSET := 9.0
const Y_OFFSET := 0.0
const X_SPACING := 8.0
const Y_SPACING := 0.0
const ITEMS_PER_ROW := 3
const CELL_SIZE := Vector2i(95, 138)
const SEPARATOR := "bg_prizes_shelf.png"
const SEPARATOR_X_OFFSET := 13.0
const SEPARATOR_Y_OFFSET := -10.0

## setOverlayViewsToGridViews: 0x121B8.
const LABEL_ART := "prize_label.png"
const UNKNOWN_ART := "prize_unknown.png"
const LABEL_SIZE := Vector2(74, 14)
const LABEL_CENTER_Y := 16.0
const LABEL_FONT_SIZE := 12
## minimumFontSize 6 with adjustsFontSizeToFitWidth.
const LABEL_MIN_FONT_SIZE := 6
const UNKNOWN_CENTER_Y := 80.0
## iOS 6's system font is Helvetica; the same fallback list as CoinHUD.
const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans", "Liberation Sans", "Arial"]

## next: 0x119D0.
const TROPHY_CLASS_STR := "TROPHY_CASE"
const PRIZE_BACKGROUND := "Prize_Background"

## setPrizes: / setBackgroundFile: -- nil until the caller sets them.
var prizes: Variant = null
var background_file: String = ""

var _grid: ScrollableGridView


func on_enter() -> void:
	var args: Dictionary = GameState.screen_args.get("PrizeViewController", {})
	prizes = args.get("prizes", null)
	if prizes is PackedStringArray:
		prizes = Array(prizes)
	background_file = str(args.get("background_file", ""))
	_view_did_load()
	_view_will_appear()


func on_exit() -> void:
	# viewDidDisappear: -> unloadItems (also on a push: the controller stays
	# alive under MakeViewController).
	if _grid != null:
		_grid.load_items(null)


## UINavigationController keeps this controller -- and the shelf's scroll
## position -- under the TROPHY_CASE screen; back runs viewWillAppear: again.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	_view_will_appear()


func _view_did_load() -> void:
	var host := outlet("scrollableGridView")
	if host == null or host == self:
		push_error("PrizeViewController: scrollableGridView outlet missing")
		return
	_grid = ScrollableGridView.new()
	_grid.name = "ScrollableGridView"
	host.add_child(_grid)
	_grid.setup(Rect2(Vector2.ZERO, GRID_FRAME.size))
	_grid.delegate = self
	_grid.x_offset = X_OFFSET
	_grid.y_offset = Y_OFFSET
	_grid.x_spacing = X_SPACING
	_grid.y_spacing = Y_SPACING
	_grid.number_of_items_per_row = ITEMS_PER_ROW
	# createImageWithFillColor:clearColor size:95x138.
	var clear := Image.create(CELL_SIZE.x, CELL_SIZE.y, false, Image.FORMAT_RGBA8)
	_grid.grid_background = ImageTexture.create_from_image(clear)
	_grid.separator = _tex(SEPARATOR)
	_grid.separator_x_offset = SEPARATOR_X_OFFSET
	_grid.separator_y_offset = SEPARATOR_Y_OFFSET
	_grid.add_last_separator = true
	_grid.show_animated(false)


func _view_will_appear() -> void:
	if _grid != null:
		load_items()


## loadItems (0x114DC).
func load_items() -> void:
	var items: Array = []
	for p: Dictionary in PrizeManager.prizes:
		var key: Variant = p.get("IAPKey")
		var wanted := prizes == null
		if not wanted and prizes is Array:
			for k: Variant in prizes:
				if str(k) == str(key):
					wanted = true
					break
		if not wanted:
			continue
		if key == null:
			push_error("PrizeViewController: IAPKey must not be nil.")
		items.append({
			"image_path": str(p.get("Image", "")),
			"data": p,
			"iap_key": key,
			"category": p.get("Game"),
		})
	_grid.load_items(items)


## setOverlayViewsToGridViews: (0x121B8), called back by loadItems:.
func set_overlay_views_to_grid_views(views: Array) -> void:
	var label_tex := _tex(LABEL_ART)
	var unknown_tex := _tex(UNKNOWN_ART)
	for view in views:
		var cell_size: Vector2 = view.size
		var data: Dictionary = view.grid_item.get("data", {})
		view.dont_load_image = true
		view.user_interaction_enabled = false

		var label_iv := Sprite2D.new()
		label_iv.texture = label_tex
		label_iv.centered = true
		var lh := label_tex.get_size().y if label_tex != null else 0.0
		var lw := label_tex.get_size().x if label_tex != null else 0.0
		label_iv.position = Vector2(cell_size.x * 0.5, cell_size.y - lh * 0.5)
		view.add_subview(label_iv)

		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# Sprite2D is centred, so the label image's (0,0) is at -size/2.
		UILabelFrame.set_frame(label, Rect2(Vector2(lw * 0.5, LABEL_CENTER_Y)
			- LABEL_SIZE * 0.5 - Vector2(lw, lh) * 0.5, LABEL_SIZE))
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		# UILabel's default lineBreakMode is tail truncation, once the
		# shrink-to-fit has reached minimumFontSize.
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var font := SystemFont.new()
		font.font_names = PackedStringArray(FONT_NAMES)
		label.add_theme_font_override("font", font)
		label.add_theme_color_override("font_color", Color.BLACK)   # UILabel default
		label.text = str(data.get("Name", ""))
		label.add_theme_font_size_override("font_size",
			_fit_font_size(font, label.text, LABEL_SIZE.x))
		label_iv.add_child(label)

		if Defaults.bool_for_key(str(view.grid_item.get("iap_key", ""))):
			view.set_image_for_state(_tex(str(data.get("Image", ""))),
				ScrollableGridView.STATE_NORMAL)
		else:
			var unknown := Sprite2D.new()
			unknown.texture = unknown_tex
			unknown.centered = true
			# setCenter:(its own centre x, 80) -- a fresh UIImageView's centre
			# is half its image size.
			var ux := unknown_tex.get_size().x * 0.5 if unknown_tex != null else 0.0
			unknown.position = Vector2(ux, UNKNOWN_CENTER_Y)
			view.add_subview(unknown)
			view.set_image_for_state(null, ScrollableGridView.STATE_NORMAL)


## adjustsFontSizeToFitWidth: shrink from 12 toward minimumFontSize 6 until
## the single line fits the label's width.
func _fit_font_size(font: Font, text: String, width: float) -> int:
	var size := LABEL_FONT_SIZE
	while size > LABEL_MIN_FONT_SIZE \
			and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > width:
		size -= 1
	return size


## back: (0x11960).
func _on_back() -> void:
	Audio.play("button_press")
	Nav.back()


## next: (0x119D0).
func _on_next() -> void:
	Audio.play("button_press")
	var props := {
		"IsEdible": false,
		"ViewIndex": 1,
		"Type": "Stationary",
		"ItemCenterX": 0.0,
		"ItemCenterY": 0.0,
	}
	var background := {"Properties": props}
	var bg_tex := _tex(background_file)
	if bg_tex != null:
		background["Image"] = bg_tex
	var custom := {PRIZE_BACKGROUND: background}
	var items: Array = []
	if prizes is Array:
		for k: Variant in prizes:
			# addObject: of getPrizeDictionary: -- a nil would throw; the
			# callers only ever pass keys from the table.
			var d: Variant = PrizeManager.get_prize_dictionary(k)
			if d != null:
				items.append(d)
	GameState.screen_args["MakeViewController"] = {
		"class_str": TROPHY_CLASS_STR,
		"custom_categories": custom,
		"info_dict": {"Items": items},
	}
	Nav.push("MakeViewController")


func _tex(file: String) -> Texture2D:
	if file == "":
		return null
	return Assets.texture(file)
