# The freezer: every food the player stored from the eat screen, on shelves.
# Entered from the main menu's freezer button (MainMenuViewController
# FreezerClick: 0x1FF18 -- "freezer" sound, ambience loop, push).
#
# From the original binary and nib:
#   nib: bg_fridge (0,0); btn_trash (0,426,83,55) -> delete:; btn_share
#        (119,426,83,55) -> share:; btn_save (237,426,83,55) -> eat:;
#        btn_back (6,6,90,56) -> back:; btn_collage (220,2,94,63) ->
#        collage:; scrollableGridView (0,79,320,334), last subview.
#   viewDidLoad          0xA3CE4  grid: XOffset 9, YOffset 0, XSpacing 8,
#                                 YSpacing 0, 3 per row; gridBackground
#                                 Screen_Shot_Frame.png (95x138),
#                                 selectedGridBackground
#                                 Screen_Shot_Frame_highlight.png, separator
#                                 bg_fridge_shelf.png at separatorYOffset -22
#                                 (x offset left 0), addLastSeparator,
#                                 keepSelected, showAnimated:NO.
#   viewWillAppear:      0xA3EE0  loadItems, unless a ShareView is up.
#   viewDidDisappear:    0xA3EA0  unloadItems.
#   loadItems            0xA4024  selection cleared; one GridItem per
#                                 savePath/*.plist: imagePath = the EatItem's
#                                 thumbnailPath, data = its data.
#   gridItemViewClicked: 0xA5254  button_press; that cell is the selection
#                                 (the grid then shows it with the highlight
#                                 frame, keepSelected).
#   back:                0xA42E4  button_press, pop.
#   delete:              0xA4354  "trash" (always); with a selection: load
#                                 savePath/<FilePath's name>, deleteFile,
#                                 loadItems; without: alert "Error" / "You do
#                                 not have an item selected." / OK.
#   eat:                 0xA489C  button_press; with a selection: an
#                                 EatViewController (no classStr) given the
#                                 EatItem -- or, when data.Class is
#                                 "DrinkItem", a DrinkItem whose liquid mask is
#                                 re-pointed by ItemName (Milkshake /
#                                 Lemon Shake-Up) -- fromFreezer YES,
#                                 previousViewControllerClass
#                                 "FreezerViewController", push; selection
#                                 cleared. Without: the same alert.
#   share:               0xA44FC  button_press; without a selection the
#                                 alert; with one, a ShareView (Facebook /
#                                 email / photo album) over an EatView.
#   collage:             0xA4C7C  "Loading..." spinner, then on a thread
#                                 goToDecorateScreen 0xA4CC8: for each saved
#                                 item, createCollageImage if its .collage
#                                 file is missing; push MakeViewController
#                                 initWithClassStr:"FOOD_COLLAGE" andInfoDict:
#                                 {"Items": [{Image: <.collage path>,
#                                 Thumbnail: <.collage_thumbnail path>}]},
#                                 customCategories {"Collage_Background":
#                                 {Properties {IsEdible NO, ViewIndex 0, Type
#                                 "Stationary", ItemCenterX 0, ItemCenterY 0},
#                                 Image viewscreen_bg.png}}.
#
# PORT CHOICES / NOT PORTED:
#   * ShareView (Facebook, e-mail, save to the photo album) has no desktop
#     counterpart and is not ported. share: keeps its grounded no-selection
#     alert; with a selection it says sharing is not ported, as the eat
#     screen already does.
#   * The "Loading..." activity spinner (UnityExternals) is not shown; the
#     collage images are built synchronously.
#   * The alerts are UIAlertViews with no delegate: their OK is silent.
#   * The eat and collage pushes hand their arguments over through the
#     EatViewController pending dict and GameState.screen_args
#     ["MakeViewController"]; both receivers read them on entry.

extends "res://core/Screen.gd"

const ScrollableGridView := preload("res://core/ScrollableGridView.gd")
const EatItem := preload("res://core/EatItem.gd")

const GRID_FRAME := Rect2(0, 79, 320, 334)
const X_OFFSET := 9.0
const Y_OFFSET := 0.0
const X_SPACING := 8.0
const Y_SPACING := 0.0
const ITEMS_PER_ROW := 3
const GRID_BACKGROUND := "Screen_Shot_Frame.png"
const SELECTED_GRID_BACKGROUND := "Screen_Shot_Frame_highlight.png"
const SEPARATOR := "bg_fridge_shelf.png"
const SEPARATOR_Y_OFFSET := -22.0

## delete: / eat: / share: (0xA4354 / 0xA489C / 0xA44FC): UIAlertView title
## "Error", this message, "OK", delegate nil.
const NO_SELECTION_TITLE := "Error"
const NO_SELECTION_MESSAGE := "You do not have an item selected."
const SHARE_NOT_PORTED := "Sharing by email isn't available in this version."

## goToDecorateScreen 0xA4CC8.
const COLLAGE_CLASS_STR := "FOOD_COLLAGE"
const COLLAGE_BACKGROUND := "Collage_Background"
const COLLAGE_BACKGROUND_ART := "viewscreen_bg.png"

var selected_grid_item_view = null
var _grid: ScrollableGridView


func on_enter() -> void:
	_view_did_load()
	_view_will_appear()


## viewDidDisappear: (0xA3EA0) -- also on a push, since the controller stays
## alive under the pushed one.
func on_exit() -> void:
	_unload_items()


## UINavigationController keeps this controller (and its scroll position)
## under the eat / collage screens; back runs viewWillAppear: again.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	_view_will_appear()


func _view_did_load() -> void:
	var host := outlet("scrollableGridView")
	if host == null or host == self:
		push_error("FreezerViewController: scrollableGridView outlet missing")
		return
	_grid = ScrollableGridView.new()
	_grid.name = "ScrollableGridView"
	host.add_child(_grid)
	_grid.setup(Rect2(Vector2.ZERO, GRID_FRAME.size))
	_grid.delegate = self
	_grid.image_loader = _load_cell_image
	_grid.x_offset = X_OFFSET
	_grid.y_offset = Y_OFFSET
	_grid.x_spacing = X_SPACING
	_grid.y_spacing = Y_SPACING
	_grid.number_of_items_per_row = ITEMS_PER_ROW
	_grid.grid_background = _tex(GRID_BACKGROUND)
	_grid.selected_grid_background = _tex(SELECTED_GRID_BACKGROUND)
	_grid.separator = _tex(SEPARATOR)
	_grid.separator_y_offset = SEPARATOR_Y_OFFSET
	_grid.add_last_separator = true
	_grid.keep_selected = true
	_grid.show_animated(false)


## viewWillAppear: 0xA3EE0 -- a ShareView never exists in the port.
func _view_will_appear() -> void:
	if _grid != null:
		load_items()


## GridItemView's imageNamed: / imageWithContentsOfFile: for a thumbnail.
func _load_cell_image(path: String) -> Texture2D:
	if path == "":
		return null
	var t := EatItem.load_texture(path)
	return t if t != null else ScrollableGridView.default_image_loader(path)


## loadItems (0xA4024).
func load_items() -> void:
	selected_grid_item_view = null
	var root := EatItem.save_path()
	var items: Array = []
	for file: String in EatItem.list_saved():
		var item = EatItem.init_with_contents_of_file_load_images(root.path_join(file), false)
		items.append({
			"image_path": item.thumbnail_path,
			"data": item.data,
		})
	_grid.load_items(items)


func _unload_items() -> void:
	selected_grid_item_view = null
	if _grid != null:
		_grid.load_items(null)


## gridItemViewClicked: (0xA5254).
func grid_item_view_clicked(view) -> void:
	Audio.play("button_press")
	selected_grid_item_view = view


func _selected_path() -> String:
	var data: Dictionary = selected_grid_item_view.grid_item.get("data", {})
	return EatItem.save_path().path_join(str(data.get("FilePath", "")).get_file())


## back: (0xA42E4).
func _on_back() -> void:
	Audio.play("button_press")
	Nav.back()


## delete: (0xA4354).
func _on_delete() -> void:
	Audio.play("trash")
	if selected_grid_item_view == null:
		show_alert(NO_SELECTION_MESSAGE, ["OK"], Callable(), false, NO_SELECTION_TITLE)
		return
	var item = EatItem.init_with_contents_of_file_load_images(_selected_path(), true)
	item.delete_file()
	load_items()


## eat: (0xA489C).
func _on_eat() -> void:
	Audio.play("button_press")
	if selected_grid_item_view == null:
		show_alert(NO_SELECTION_MESSAGE, ["OK"], Callable(), false, NO_SELECTION_TITLE)
		return
	var path := _selected_path()
	var item = EatItem.init_with_contents_of_file_load_images(path, true)
	if str(item.data.get("Class", "")) == EatItem.CLASS_DRINK:
		item = EatItem.init_with_contents_of_file_load_images(path, true, true)
	var eat_script: GDScript = load("res://screens/EatViewController.gd")
	eat_script.set_pending(item.to_pending())
	Nav.push("EatViewController")
	selected_grid_item_view = null


## share: (0xA44FC).
func _on_share() -> void:
	Audio.play("button_press")
	if selected_grid_item_view == null:
		show_alert(NO_SELECTION_MESSAGE, ["OK"], Callable(), false, NO_SELECTION_TITLE)
		return
	show_alert(SHARE_NOT_PORTED, ["OK"], Callable(), false)


## collage: (0xA4C7C) -> goToDecorateScreen (0xA4CC8).
func _on_collage() -> void:
	var root := EatItem.save_path()
	var items: Array = []
	for file: String in EatItem.list_saved():
		var path := root.path_join(file)
		var collage := EatItem.get_collage_image_path(path)
		var thumb := EatItem.get_collage_thumbnail_image_path(path)
		var item = EatItem.init_with_contents_of_file_load_images(path, false)
		if not EatItem.fs_exists(collage):
			item.create_collage_image()
		items.append({"Image": collage, "Thumbnail": thumb})
	var props := {
		"IsEdible": false,
		"ViewIndex": 0,
		"Type": "Stationary",
		"ItemCenterX": 0.0,
		"ItemCenterY": 0.0,
	}
	var custom := {COLLAGE_BACKGROUND: {"Properties": props,
		"Image": _tex(COLLAGE_BACKGROUND_ART)}}
	GameState.screen_args["MakeViewController"] = {
		"class_str": COLLAGE_CLASS_STR,
		"custom_categories": custom,
		"info_dict": {"Items": items},
	}
	Nav.push("MakeViewController")


func _tex(file: String) -> Texture2D:
	if file == "":
		return null
	return Assets.texture(file)
