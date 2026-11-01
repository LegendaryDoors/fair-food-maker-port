# The trophy case -- dead code in v1.27, ported for completeness.
#
# UNREACHABLE: the binary holds no classref, CFString or nib reference to
# tcTrophyCaseViewController anywhere in the binary (the only xrefs to its
# class object are its own methods' super calls and the class list). The
# trophy case a player actually sees is MakeViewController in "TROPHY_CASE"
# mode, pushed by PrizeViewController next: (0x119D0). Its data source,
# tcDecorationItems.plist "TrophyCase_Prizes", ships with an EMPTY Items
# array, so even if pushed this shows an empty fridge.
#
# From the original binary and its nib:
#   nib: bg_fridge (0,0), btn_back (0,424,90,56) -> back:, btn_next
#        (230,424,90,56) -> next:, scrollableGridView (0,0,320,413).
#   viewDidLoad          0x121DD8  grid: XOffset 9, YOffset 0, XSpacing 8,
#                                  YSpacing 0, 3 per row; clear 95x138 cells;
#                                  separator bg_fridge_shelf.png at
#                                  separatorYOffset -22; addLastSeparator;
#                                  showAnimated:NO.
#   viewWillAppear:      0x121F7C  loadItems.
#   viewDidDisappear:    0x121FBC  unloadItems.
#   loadItems            0x121FFC  Category "TrophyCase_Prizes" from
#                                  tcDecorationItems.plist; one GridItem per
#                                  item: imagePath = the bundle path of its
#                                  Image, data = the item, IAPKey, category =
#                                  the category name.
#   gridItemViewClicked: 0x1224BC  button_press; a locked item (boolForKey
#                                  IAPKey NO) shows "Trophy Locked" with its
#                                  LockMessage.
#   setOverlayViewsToGridViews: 0x122610  a locked item gets its Silhouette
#                                  image centred on the cell.
#   back:                0x122380  button_press, pop.
#   next:                0x1223F0  button_press; push MakeViewController with
#                                  classStr "TROPHY_CASE" and nothing else.

extends "res://core/Screen.gd"

const ScrollableGridView := preload("res://core/ScrollableGridView.gd")

const GRID_FRAME := Rect2(0, 0, 320, 413)
const X_OFFSET := 9.0
const Y_OFFSET := 0.0
const X_SPACING := 8.0
const Y_SPACING := 0.0
const ITEMS_PER_ROW := 3
const CELL_SIZE := Vector2i(95, 138)
const SEPARATOR := "bg_fridge_shelf.png"
const SEPARATOR_Y_OFFSET := -22.0
## The import cache's data/tcDecorationItems.json (Assets).
const PLIST := "tcDecorationItems"
const CATEGORY := "TrophyCase_Prizes"

var _grid: ScrollableGridView


func on_enter() -> void:
	var host := outlet("scrollableGridView")
	if host == null or host == self:
		push_error("tcTrophyCaseViewController: scrollableGridView outlet missing")
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
	var clear := Image.create(CELL_SIZE.x, CELL_SIZE.y, false, Image.FORMAT_RGBA8)
	_grid.grid_background = ImageTexture.create_from_image(clear)
	_grid.separator = _tex(SEPARATOR)
	_grid.separator_y_offset = SEPARATOR_Y_OFFSET
	_grid.add_last_separator = true
	_grid.show_animated(false)
	# viewWillAppear: (0x121F7C).
	load_items()


## viewDidDisappear: (0x121FBC) -> unloadItems -- also on next:'s push, since
## the controller stays alive under the TROPHY_CASE MakeViewController.
func on_exit() -> void:
	if _grid != null:
		_grid.load_items(null)


## Kept under the MakeViewController next: pushes, as the
## UINavigationController kept it; back re-runs viewWillAppear: (0x121F7C),
## i.e. loadItems. The grid's scroll offset is left alone by the unload /
## reload pair, as UIScrollView leaves contentOffset alone.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	if _grid != null:
		load_items()


## loadItems (0x121FFC).
func load_items() -> void:
	var items: Array = []
	var table: Variant = Assets.json(PLIST)
	if table is Dictionary:
		var cat: Dictionary = (table as Dictionary).get(CATEGORY, {})
		for item: Dictionary in cat.get("Items", []):
			if item.get("IAPKey") == null:
				push_error("tcTrophyCaseViewController: IAPKey must not be nil.")
			items.append({
				"image_path": str(item.get("Image", "")),
				"data": item,
				"iap_key": item.get("IAPKey"),
				"category": CATEGORY,
			})
	_grid.load_items(items)


## setOverlayViewsToGridViews: (0x122610).
func set_overlay_views_to_grid_views(views: Array) -> void:
	for view in views:
		if Defaults.bool_for_key(str(view.grid_item.get("iap_key", ""))):
			continue
		var data: Dictionary = view.grid_item.get("data", {})
		var s := Sprite2D.new()
		s.texture = _tex(str(data.get("Silhouette", "")))
		s.centered = true
		s.position = (view.size as Vector2) * 0.5
		view.add_subview(s)


## gridItemViewClicked: (0x1224BC).
func grid_item_view_clicked(view) -> void:
	Audio.play("button_press")
	if not Defaults.bool_for_key(str(view.grid_item.get("iap_key", ""))):
		var data: Dictionary = view.grid_item.get("data", {})
		# UIAlertView title "Trophy Locked", message LockMessage, delegate nil.
		show_alert(str(data.get("LockMessage", "")), ["OK"], Callable(), false, "Trophy Locked")


## back: (0x122380).
func _on_back() -> void:
	Audio.play("button_press")
	Nav.back()


## next: (0x1223F0).
func _on_next() -> void:
	Audio.play("button_press")
	GameState.screen_args["MakeViewController"] = {"class_str": "TROPHY_CASE"}
	Nav.push("MakeViewController")


func _tex(file: String) -> Texture2D:
	if file == "":
		return null
	return Assets.texture(file)
