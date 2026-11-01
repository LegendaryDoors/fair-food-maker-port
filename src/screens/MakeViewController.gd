# The shared decorate screen. All 12 food chains terminate here. The finished
# food arrives as "custom categories" and the player dresses it with
# decorations from <prefix>DecorationItems.plist.
#
# Read from the original binary:
#   MakeViewController   viewDidLoad 0xA56A4, next: 0xA9294, back: 0xA907C,
#                        undo: 0xA91B8, categoryButtonClicked: 0xA9E24,
#                        gridItemViewClicked: 0xAA120,
#                        loadCategoryToGridView: 0xA6FE4,
#                        gridItemFromDictionary:category: 0xA76C8,
#                        viewWillAppear: 0xA5638, emitAtLocation: 0xAAA44 (a no-op)
#   DecorateView         addCategory: 0xB021C, addCustomView:category: 0xB04B0,
#                        processCustomView:category: 0xB0780,
#                        processGridItem: 0xB0B10, rearrangeViews 0xB1A3C,
#                        redraw 0xB1A98, removeDecorateView: 0xB0618,
#                        hitTest: 0xB258C, createEatItem 0xB1CE4,
#                        createDrinkItem 0xB2138
#   DecorateItemView     initWithImage:andTintColor:andBlendMode: 0xBC914
#                        (plain [super init] -> ZERO frame -> setCenter: places
#                        the art's TOP-LEFT, per the TintedIV rule),
#                        initWithGridItem: 0xBCC60 (initWithImage: -> self-sizing
#                        -> true centres), moveSelfToNewPoint: 0xBCD70,
#                        touchesBegan/Moved 0xBCE1C / 0xBD0E0 (drag + paint)
#   CategoryButtonsView  initWithFrame: 0xB8E58, rebuildPages 0xB8FD0,
#                        addButton:... 0xB9CC0, setCurrentPage:animated: 0xB9640
#   ScrollableGridView   initWithFrame: 0xB37C0, loadItems: 0xB3928,
#                        showAnimated: 0xB41B0, hideAnimated: 0xB4458,
#                        buttonPressed: 0xB4680
#   Category             initWithName:dictionary: 0xB50E4 (keys: Type,
#                        ButtonImage, ItemLimit, ViewIndex, IsEdible, IAPKey,
#                        Items), compare: 0xB5564 (ascending viewIndex)
#   msBlenderViewController nextClick: 0x56608 (the milkshake bake-out and the
#                        info dict it hands forward)
#   StickSelectViewController nextClick: 0x646A0 (adds the Straw entry, then
#                        MakeViewController setCustomCategories: / setClassStr:)
#
# How the finished food really flows in: each food's last screen bakes its
# layers into a dict {name: {"Image", "Properties": {IsEdible, ViewIndex,
# Type, ItemCenterX, ItemCenterY, Rotation?}}} and hands it over as
# customCategories (milkshake / lemon shake-up via StickSelect, which adds
# "Straw"). The port carries it in GameState.custom_categories. Every entry is
# a DecorateItemView built with the zero-frame initialiser, so its
# ItemCenterX/Y is the art's TOP-LEFT, and only Type "Stationary" is drawn.
#
# Checked against every food's bake-out:
# classStr spellings, custom-before-plist insertion order, the Type gate, the
# untouchable finished paint canvas, the empty touch-down stamp, rotated drag
# hit-testing, the grid's isAnimating gate, the badge/coins alpha while the
# grid is open, the badge's z-order and its donut hiding, the bar's ease-in-out
# page slide. If nothing arrives (a dev harness entering directly), the
# milkshake's layers are rebuilt by msBlender's 0x56608 recipe, with the
# starting straw -- a stand-in path, not a flow the game takes.

extends "res://core/Screen.gd"

# -- which food this is ------------------------------------------------

## Flow prefix -> classStr: the literal each food's last screen passes to
## setClassStr: / initWithClassStr: (scPourSyrup 0x7ADB4 "SNOW_CONE",
## caDipApple 0x15E6F4 "Candy Apple", cffDustSalt 0x172248 "French Fries",
## ccbFreezer 0xFAEA8 "Chocolate Dipped Banana", dicFrosting 0xD9D68
## "Donut Ice Cream Sandwich", StickSelect 0x646A0 MILK_SHAKE /
## LEMON_SHAKE_UP, ...). The four newer foods use spaced, mixed-case strings;
## the port used to spell them "CandyApple" etc., which no comparison in the
## binary matches -- so the mystery badge was never hidden for the donut
## (viewDidLoad 0xA56A4 hides it for "Donut Ice Cream Sandwich").
const CLASS_STR := {
	"ms": "MILK_SHAKE", "lsu": "LEMON_SHAKE_UP", "sc": "SNOW_CONE",
	"cc": "COTTON_CANDY", "cd": "CORN_DOG", "fc": "FUNNEL_CAKE",
	"ip": "ICE_POP", "kc": "KETTLE_CORN", "ca": "Candy Apple",
	"ccb": "Chocolate Dipped Banana", "cff": "French Fries",
	"dic": "Donut Ice Cream Sandwich",
}

## classStr -> decoration plist prefix (viewDidLoad 0xA56A4 chain; its final
## else picks dicDecorationItems for anything unmatched). TROPHY_CASE -> tc and
## FOOD_COLLAGE -> co are the prize shelf's and the freezer's decorate screens
## (see TROPHY_CASE / FOOD_COLLAGE below).
const PLIST_PREFIX := {
	"MILK_SHAKE": "ms", "LEMON_SHAKE_UP": "lsu", "SNOW_CONE": "sc",
	"COTTON_CANDY": "cc", "CORN_DOG": "cd", "FUNNEL_CAKE": "fc",
	"ICE_POP": "ip", "KETTLE_CORN": "kc", "Candy Apple": "ca",
	"Chocolate Dipped Banana": "ccb", "French Fries": "cff",
	"Donut Ice Cream Sandwich": "dic",
	"TROPHY_CASE": "tc", "FOOD_COLLAGE": "co",
}

# -- TROPHY_CASE / FOOD_COLLAGE ----------------------------------------
#
# PrizeViewController next: (0x119D0) pushes this screen with classStr
# "TROPHY_CASE", customCategories {Prize_Background} and infoDict {Items:
# [prize dicts]}; FreezerViewController goToDecorateScreen (0xA4CC8) with
# "FOOD_COLLAGE", {Collage_Background} and {Items: [{Image, Thumbnail} paths
# of each saved food's collage art]}. The port carries those three through
# GameState.screen_args[SCREEN_KEY] (PORT CHOICE: Nav.push takes only a name).
# What changes, as read:
#  * viewDidLoad 0xA56A4: tc/coDecorationItems (one Drag category each, no
#    Items of its own); the bar's setXOffset: is 103.0 instead of -3.0 (v26
#    is set to 103.0 before the TROPHY_CASE / FOOD_COLLAGE tests, which jump
#    past the -3.0); the mystery badge is hidden.
#  * viewDidAppear: 0xA54D4 hides the coins panel for TROPHY_CASE, and the
#    app delegate never adds it for FOOD_COLLAGE (CoinHUD header).
#  * loadCategoryToGridView: 0xA6FE4 takes TrophyCase_Prizes' items from
#    infoDict["Items"]; categoryButtonClicked: 0xA9E24 routes Collage_Items to
#    loadCollageItemsToGridView 0xA7820 (imagePath = the Thumbnail PATH,
#    category Collage_Items, image view contentMode 4 = centre).
#  * setOverlayViewsToGridViews: 0xAA634: a TrophyCase_Prizes cell whose
#    IAPKey user default is NO (the prize not yet won) gets
#    Sub_Button_Background_Locked.png, prize_unknown_thumb.png in place of its
#    thumbnail, and an empty overlay tagged 1000; gridItemViewClicked: 0xAA120
#    on a tag-1000 TrophyCase_Prizes cell only shows a delegate-less alert
#    "<Name> is locked." (title "", OK).
#  * processGridItem: 0xB0B10 loads Image with imageNamed: and falls back to
#    imageWithContentsOfFile: -- the collage art lives in the save folder.
#  * next: 0xA9294: createEatItem, itemName "Prizes" / "Collage", and the
#    EatViewController gets this classStr (its viewWillAppear: hides
#    eat-again / save / instIV for both).
const SCREEN_KEY := "MakeViewController"
const TROPHY_CASE := "TROPHY_CASE"
const FOOD_COLLAGE := "FOOD_COLLAGE"
const PRIZES_CATEGORY := "TrophyCase_Prizes"
const COLLAGE_CATEGORY := "Collage_Items"
const BAR_X_OFFSET_SHELF := 103.0
const CELL_BG_LOCKED := "Sub_Button_Background_Locked.png"
const PRIZE_UNKNOWN_THUMB := "prize_unknown_thumb.png"
const EatItemScript := preload("res://core/EatItem.gd")

## viewDidLoad 0xA56A4: the mystery badge is hidden for these classStrs.
const MYSTERY_HIDDEN_FOR := ["TROPHY_CASE", "FOOD_COLLAGE", "Donut Ice Cream Sandwich"]

## classStr -> the itemName next: (0xA9294) writes into the EatItem. Read as
## cfstrings from the branch bodies -- note most carry spaces.
const ITEM_NAME := {
	"MILK_SHAKE": "Milkshake", "LEMON_SHAKE_UP": "Lemon Shake-Up",
	"SNOW_CONE": "Snow Cone", "COTTON_CANDY": "Cotton Candy",
	"CORN_DOG": "Corn Dog", "FUNNEL_CAKE": "Funnel Cake",
	"ICE_POP": "QuickFreeze Ice Pop", "KETTLE_CORN": "Kettle Corn",
	"Candy Apple": "Candy Apple", "Chocolate Dipped Banana": "Chocolate Dipped Banana",
	"French Fries": "French Fries", "Donut Ice Cream Sandwich": "Donut Ice Cream Sandwich",
	"TROPHY_CASE": "Prizes", "FOOD_COLLAGE": "Collage",
}

## The two drink foods (next: 0xA9294 calls createDrinkItem for these and sets
## the liquid mask + category by name).
const DRINK_INFO := {
	"MILK_SHAKE": {"mask": "Ice_Cream_Glass_Mask_Full.png", "category": "MilkShake"},
	"LEMON_SHAKE_UP": {"mask": "lsu_cup_mask_full.png", "category": "LemonShakeup"},
}

# -- category button bar (viewDidLoad 0xA56A4) -------------------------

## initWithFrame:(0, 0, view.width, 50), read from the instructions at
## 0xA5ECC..0xA5EEA.
const BAR_HEIGHT := 50.0
## setXOffset: -3.0 (vmov.f32 d10,#-3 at 0xA5CAC, food path); setXSpacing: -6.0
## (0xC0C00000 at 0xA5F8E). Buttons overlap by 6px.
const BAR_X_OFFSET := -3.0
const BAR_X_SPACING := -6.0
const BUTTONS_PER_PAGE := 3
## setCurrentPage:animated: (0xB9640) slide: setAnimationDuration: double
## 0x3FE999999999999A = 0.8 s, no setAnimationCurve: -> UIKit's default
## ease-in-out. The incoming page starts one page width beyond the outgoing
## one and both move together.
const PAGE_SLIDE := 0.8

# -- item grid (viewDidLoad 0xA56A4 + ScrollableGridView) --------------

## initWithFrame:(25, 55, 270, 340) -- asm 0xA6306..0xA6322.
const GRID_FRAME := Rect2(25, 55, 270, 340)
## setHiddenLocation:(frame.x, -frame.height) -> (25, -340) (0xA644A eor with
## 0x80000000); setLocation:(frame.x, barHeight + 10) -> (25, 60) (0xA6498).
const GRID_HIDDEN_Y := -340.0
const GRID_SHOWN_Y := 60.0
## show/hide animation (showAnimated: 0xB41B0 / hideAnimated: 0xB4458):
## setAnimationDuration: double 0x3FD3333333333333 = 0.3 s, curve 3 = linear.
## Both are ignored while one is already running (isAnimating, cleared by
## animationDidStop:finished:context: 0xB4A00), and showAnimated: also does
## nothing when the grid holds no items.
const GRID_SLIDE := 0.3
## setXSpacing: 0.0 (r2=0 at 0xA632A), setYSpacing: 10.0 (0x41200000 at
## 0xA634E), 3 per row. XOffset/YOffset stay at their zero ivar defaults.
const GRID_X_SPACING := 0.0
const GRID_Y_SPACING := 10.0
const GRID_PER_ROW := 3
## Cell = Sub_Button_Background.png, 91x90 at 1x; the thumbnail is centred in
## it (UIButton image behaviour, GridItemView 0xC4A6C).
const CELL_BG := "Sub_Button_Background.png"

# -- decorate-view placement (processGridItem: 0xB0B10) ----------------

## Background items: self-sizing, centred on the view centre (w/2, h/2).
const BG_CENTER := Vector2(160, 240)
## Paint canvas: clear 320x480 (0x43A00000 x 0x43F00000).
const PAINT_SIZE := Vector2i(320, 480)

# -- the milkshake bake (msBlender nextClick: 0x56608) -----------------

## The baked shake and the glass are both placed with setCenter:(58, 180)
## (0x42680000, 0x43340000) on ZERO-FRAME DecorateItemViews -> TOP-LEFT.
## ViewIndexes 4 and 5; the shake is the only edible layer.
const SHAKE_TOP_LEFT := Vector2(58, 180)
const SHAKE_VIEW_INDEX := 4
const GLASS_VIEW_INDEX := 5
## Fruit FX: 3 stamps per stored tag, each 20x20 (0x41A00000), multiply blend
## (CGContextSetBlendMode 1) at alpha 0.3 (0x3E99999A), at
## x = rand%0x50 + 0x32 = 50..129, y = rand%0xA5 + 0x6E = 110..274, read as
## top-left offsets inside the 204x318 bake (the context CTM at 0x566F0 flips
## into top-left coordinates; the residual image-flip of each 20px stamp is
## not modelled).
const FX_STAMP := 20
const FX_X_BASE := 50
const FX_X_SPAN := 80
const FX_Y_BASE := 110
const FX_Y_SPAN := 165
const FX_ALPHA := 0.3
## Tag -> FX art (0x56608 switch). Tags 0/2/3 pick variant 1 or 2 at 50/50.
## Every unlisted tag (5, 7, 106..109, anything else) falls through to
## ms_FX_Strawberry_2 -- the original's own default case.
const FX_ART := {
	"1": ["ms_FX_Fruit_One"], "4": ["ms_FX_Lychees"], "6": ["ms_FX_Banana"],
	"0": ["ms_FX_Strawberry_1", "ms_FX_Strawberry_2"],
	"2": ["ms_FX_Orange_1", "ms_FX_Orange_2"],
	"3": ["ms_FX_Mango_1", "ms_FX_Mango_2"],
	"100": ["ms_FX_Chocolate"], "101": ["ms_FX_Cinnamon_Imperials"],
	"102": ["ms_FX_Gummi_Bears"], "103": ["ms_FX_M_Ms"],
	"104": ["ms_FX_Peppermints"], "105": ["ms_FX_Spice_Drops"],
	"200": ["ms_FX_Chopped_Peanuts"], "201": ["ms_FX_Roasted_Cashews"],
	"202": ["ms_FX_Pistachios"], "203": ["ms_FX_Walnuts"],
}
const FX_DEFAULT := "ms_FX_Strawberry_2"

var _class_str := ""
## setCustomCategories: / the infoDict of initWithClassStr:andInfoDict:. A
## food's come from GameState.custom_categories; the shelf / collage pushes
## bring their own (SCREEN_KEY).
var _custom_categories: Dictionary = {}
var _info_dict: Dictionary = {}
var _decorate: Node2D
## Sorted ascending by view_index (Category compare: 0xB5564); each entry:
## {name, props, items, type, view_index, item_limit, replace_last, edible,
##  button_image, button_index, layer: Node2D, views: Array}
var _categories: Array = []
var _undo_stack: Array = []
var _paint_current: Dictionary = {}

var _bar: Node2D
var _pages: Array = []
var _current_page := 0
var _page_animating := false
var _bar_buttons: Dictionary = {}      # button id (category name) -> TextureButton
var _selected_button := ""

var _grid: Control
var _grid_content: Node2D
var _grid_cells: Array = []
var _grid_visible := false
var _grid_content_h := 0.0
## The grid's UIScrollView (ScrollableGridView: alwaysBounceVertical, Normal
## deceleration, bounces; viewDidLoad hides both indicators, so none).
var _grid_pan: ScrollableGridViewScript.PanScroller
var _grid_press_cell: Node2D = null
var _grid_tween: Tween
## ScrollableGridView isAnimating: show/hide requests are dropped while set.
var _grid_animating := false

var _drag_record: Dictionary = {}
var _drag_node_start := Vector2.ZERO
var _drag_mouse_start := Vector2.ZERO
var _paint_last := Vector2.ZERO

## Mystery decoration:
##   initWithNibName: 0xA53D4  Consumable DM_CONSUMABLE_MYSTERY_DECORATE_
##     ITEM_SELECT / MysterySelect_Decorate; first-time message.
##   viewDidLoad 0xA56A4  cost = CoinCosts.<food>.MysteryDecoration, 6 when
##     absent; ConsumableButton(btn_mystery_selection, (0,-25) / (65,3)) at
##     centre (50, 350.5), added before the grid and the bar are brought to
##     the front.
##   buyMysteryFlavorClick: 0xA9010  "store" sound, purchaseConsumable.
##   consumablePurchased: 0xA7A5C  quantity 0; a random CategoryButtonsView
##     button -> its category -> that category's ButtonIndex -> every
##     category sharing the ButtonIndex contributes its items -> a random
##     item -> gridItemFromDictionary:category: (the BUTTON's category) ->
##     DecorateView processGridItem:. If that category's type is "Paint", an
##     alert "Awesome!" / "You've received a Draw-on item!  Drag your finger
##     on  the food to use it!" [OK].
##   consumablePurchaseFailed:error:2 0xA881C  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const ScrollableGridViewScript := preload("res://core/ScrollableGridView.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_DECORATE_ITEM_SELECT"
const MYSTERY_NAME := "MysterySelect_Decorate"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery selection! Get a random item from one of the decoration categories! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_selection.png"
const MYSTERY_CENTER := Vector2(50, 350.5)
## The "Awesome!" alert's title and message (0xA7A5C), delegate nil.
const PAINT_ALERT_TITLE := "Awesome!"
const PAINT_ALERT := "You've received a Draw-on item!  Drag your finger on  the food to use it!"
## consumablePurchaseFailed:error: 2 (0xA881C): title @"", delegate self,
## Cancel / Get Coins; alertView:clickedButtonAtIndex: (0xA8C70) pushes a
## CoinStoreViewController (animated) for "Get Coins" -- and plays nothing.
const NO_COINS_BUTTONS := ["Cancel", "Get Coins"]
const GET_COINS := "Get Coins"

var _mystery: RefCounted
var _mystery_button: TextureButton


func on_enter() -> void:
	# The TROPHY_CASE / FOOD_COLLAGE pushes hand their init arguments over in
	# screen_args; erase them at once so they can never leak into a food.
	var args: Variant = GameState.screen_args.get(SCREEN_KEY, {})
	GameState.screen_args.erase(SCREEN_KEY)
	if args is Dictionary and (args as Dictionary).has("class_str"):
		_class_str = str(args["class_str"])
		var cc: Variant = args.get("custom_categories", {})
		_custom_categories = cc if cc is Dictionary else {}
		var info: Variant = args.get("info_dict", {})
		_info_dict = info if info is Dictionary else {}
	else:
		_class_str = CLASS_STR.get(GameState.food, "")
		_custom_categories = GameState.custom_categories
	if _class_str == "":
		# Original asserts "Unrecognized class given in MakeViewController.m".
		push_warning("[Make] no classStr for food prefix '%s'" % GameState.food)

	_decorate = Node2D.new()
	_decorate.name = "DecorateView"
	add_child(_decorate)
	# sendSubviewToBack: -- behind the nib's undo/back/next buttons.
	move_child(_decorate, 0)

	# viewDidLoad 0xA56A4, in its order: the custom categories go into the
	# DecorateView FIRST (addCustomView:category:), then the plist categories
	# (addCategory:, which rejects a name already present); every addCategory:
	# re-sorts by ViewIndex (rearrangeViews 0xB1A3C). The bar, then the grid,
	# then the grid and bar are brought to the front, then each Background
	# category's first item is applied, and only then is the mystery badge
	# added -- so the badge sits above the grid and the bar.
	_add_custom_categories()
	_load_categories()
	_sort_categories()
	_build_layers()
	_build_bar()
	_build_grid()
	_apply_default_backgrounds()
	_build_mystery()


## viewDidAppear: (0xA54D4): [coinsView setHidden:(classStr is TROPHY_CASE)]
## -- every other Make un-hides it. It runs before the app delegate's
## didShow puts the one panel on this screen (CoinHUD, which honours the
## flag); for FOOD_COLLAGE didShow never adds it (CoinHUD too).
func on_did_appear() -> void:
	CoinHUD.set_hidden(_class_str == TROPHY_CASE)


## viewDidDisappear: (0xA556C): setHidden:NO -- recorded for the next screen;
## the panel still on this one slides out as it is.
func on_exit() -> void:
	CoinHUD.set_hidden(false, false)


## Navigation keeps this screen alive while Eat is pushed over it, as the
## UINavigationController did: back from Eat shows the same decorated food
## (Nav.gd's opt-in, see keeps_state_on_push there).
func keeps_state_on_push() -> bool:
	return true


## Back from Eat: viewWillAppear: (0xA5638) parks the grid -- showAnimated:NO
## then hideAnimated:NO. The coins panel CoinHUD re-adds on every appearance
## replaces the one left from the first.
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		remove_child(old)
		old.queue_free()
	_kill_grid_tween()
	_grid_animating = false
	_grid_visible = false
	_grid.position = Vector2(GRID_FRAME.position.x, GRID_HIDDEN_Y)
	_grid.visible = false
	_grid_pan.cancel()


## viewDidLoad: the ConsumableButton, and initWithNibName:'s Consumable.
func _build_mystery() -> void:
	_mystery = ConsumableScript.new(MYSTERY_KEY, MYSTERY_NAME, MYSTERY_COST)
	_mystery.set("first_time_message", MYSTERY_MESSAGE)
	_mystery.set("on_purchased", _on_mystery_purchased)
	_mystery.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, NO_COINS_BUTTONS,
			_on_no_coins_choice, false))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyMysterySelect"
	b.call("setup", MYSTERY_ART, 0, -25, MYSTERY_COST, 65, 3)
	b.position = MYSTERY_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyMysteryFlavorClick)
	add_child(b)
	_mystery_button = b
	if MYSTERY_HIDDEN_FOR.has(_class_str):
		b.visible = false


## The badge and the coins panel fade out while the grid is open and back in
## when it closes: setAlpha: 0 / 1 on both in categoryButtonClicked: (0xA9E24),
## gridItemViewClicked: (0xAA120), back: (0xA907C) and next: (0xA9294).
## Instant -- these setAlpha: calls are outside any animation block.
func _set_chrome_alpha(a: float) -> void:
	if _mystery_button != null:
		_mystery_button.modulate.a = a
	var coins := get_node_or_null("CoinInfoView")
	if coins is CanvasItem:
		(coins as CanvasItem).modulate.a = a


func _on_buyMysteryFlavorClick() -> void:
	Audio.play("store")
	_mystery.call("purchase", self)


## consumablePurchased: (0xA7A5C).
func _on_mystery_purchased(_free: bool) -> void:
	var names: Array = _bar_buttons.keys()
	if names.is_empty():
		return
	var cat := _category_named(str(names[randi() % names.size()]))
	if cat.is_empty():
		return
	var button_index := int(cat.get("button_index", 0))
	var items: Array = []
	for c in _categories:
		if int(c.get("button_index", 0)) == button_index:
			for it in c.get("items", []):
				items.append(it)
	if items.is_empty():
		return
	var item: Variant = items[randi() % items.size()]
	if not (item is Dictionary):
		return
	_process_grid_item(item, cat)
	if str(cat.get("type", "")) == "Paint":
		show_alert(PAINT_ALERT, ["OK"], Callable(), false, PAINT_ALERT_TITLE)


## alertView:clickedButtonAtIndex: (0xA8C70) for the no-coins alert.
func _on_no_coins_choice(title: String) -> void:
	if title == GET_COINS:
		Nav.push("CoinStoreViewController")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## Decompressed RGBA8 image for an art file, or null.
func _img(file: String) -> Image:
	var t := _tex(file)
	if t == null:
		return null
	var im := t.get_image()
	if im == null:
		return null
	if im.is_compressed():
		im.decompress()
	if im.get_format() != Image.FORMAT_RGBA8:
		im.convert(Image.FORMAT_RGBA8)
	return im


## processGridItem: (0xB0B10), Background / Drag / Stationary: imageNamed:,
## then imageWithContentsOfFile: -- the collage art is a file in the save
## folder, loaded through EatItem (the port's save folder reader).
func _item_img(file: String) -> Image:
	var im := _img(file)
	if im != null or file == "":
		return im
	var t: Texture2D = EatItemScript.load_texture(file)
	if t == null:
		return null
	im = t.get_image()
	if im != null and im.is_compressed():
		im.decompress()
	if im != null and im.get_format() != Image.FORMAT_RGBA8:
		im.convert(Image.FORMAT_RGBA8)
	return im


# -- category construction --------------------------------------------

## The decoration tables ship as plists in the app bundle; the importer
## converts them to <prefix>DecorationItems.json, read here through Assets.
func _load_decoration_data() -> Dictionary:
	var prefix: String = PLIST_PREFIX.get(_class_str, "")
	if prefix == "":
		return {}
	var parsed: Variant = Assets.json("%sDecorationItems" % prefix)
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	push_warning("[Make] no decoration data for %s" % _class_str)
	return {}


## Category initWithName:dictionary: (0xB50E4): type is
## [NSString stringWithFormat:@"%@", Type], so a missing Type reads "(null)";
## ItemLimit / ViewIndex / ButtonIndex go through integerValue (nil -> 0).
func _category_from(cat_name: String, props: Dictionary) -> Dictionary:
	return {
		"name": cat_name,
		"props": props,
		"items": props.get("Items", []) if props.get("Items") is Array else [],
		"type": str(props.get("Type", "(null)")),
		"view_index": int(float(str(props.get("ViewIndex", 0)))),
		"item_limit": int(float(str(props.get("ItemLimit", 0)))),
		"replace_last": _truthy(props.get("ReplaceLastItem", false)),
		"edible": _truthy(props.get("IsEdible", false)),
		"button_image": str(props.get("ButtonImage", "")),
		"button_index": int(float(str(props.get("ButtonIndex", 0)))),
		"layer": null,
		"views": [],
	}


## NSNumber / NSString boolValue.
func _truthy(v: Variant) -> bool:
	if v is bool:
		return v
	if v is String:
		return (v as String).to_lower() in ["yes", "true", "1"] \
			or (v as String).to_int() != 0
	return v != null and float(v) != 0.0


## The plist categories. addCategory: (0xB021C) skips a category whose name
## the DecorateView already holds (a custom one), but viewDidLoad still keeps
## it in its own list for the button bar -- kept here with `in_view` false.
func _load_categories() -> void:
	var data := _load_decoration_data()
	for name: String in data.keys():
		var cat := _category_from(name, data[name])
		cat["in_view"] = _category_named(name).is_empty()
		_categories.append(cat)


## viewDidLoad 0xA56A4: each customCategories entry {Image, Properties} becomes
## a zero-frame DecorateItemView placed by its TOP-LEFT, non-interactive,
## rotated (degrees) about that same point (processCustomView 0xB0780).
##
## The port reads GameState.custom_categories: an Array of
##   {name: String, image: Image, view_index: int, edible: bool,
##    top_left: Vector2, rotation_deg: float}
## `GameState.custom_categories` carries the finished food: the making screen
## bakes its layers, StickSelect adds the straw, and this reads the result. The
## shape is the original's own infoDict -- see the field's doc comment.
##
## The fallback below only runs if that arrives empty, which now means the food
## reached here without a making step (a direct Nav.replace in a dev harness,
## say). It rebuilds the milkshake's two layers by the grounded 0x56608 recipe.
func _add_custom_categories() -> void:
	var customs: Dictionary = _custom_categories
	if not customs.is_empty():
		var appended := 0
		for key in customs:
			var raw: Variant = customs[key]
			# Not every entry is a layer: cotton candy also passes stickImg
			# and packID through this dict (0x646A0).
			if not (raw is Dictionary):
				continue
			var entry: Dictionary = raw
			if not entry.has("Properties"):
				continue
			_append_custom(str(key), entry.get("Image"), entry["Properties"])
			appended += 1
		if appended > 0:
			return

	if _class_str != "MILK_SHAKE":
		return   # nothing grounded to stand in for other foods yet
	var shake := _bake_milkshake()
	if shake != null:
		_append_custom("MilkShake", shake, {"IsEdible": true,
			"ViewIndex": SHAKE_VIEW_INDEX, "Type": "Stationary",
			"ItemCenterX": SHAKE_TOP_LEFT.x, "ItemCenterY": SHAKE_TOP_LEFT.y})
	var glass := _img("ms_Ice_Cream_Glass.png")
	if glass != null:
		_append_custom("MilkShakeGlass", glass, {"IsEdible": false,
			"ViewIndex": GLASS_VIEW_INDEX, "Type": "Stationary",
			"ItemCenterX": SHAKE_TOP_LEFT.x, "ItemCenterY": SHAKE_TOP_LEFT.y})
	_append_fallback_straw()


## The Straw StickSelect nextClick: (0x646A0) adds for the milkshake, for the
## stand-in path only (nothing came through StickSelect). INFERRED: the stick a
## player gets by pressing next on arrival -- the starting pack's first stick
## (StickSelect.FOODS / PACKS, currentStickIdx 0); placement is 0x646A0's own:
## top-left x 250 - width/2, y 30, Rotation 15, ViewIndex 2, not edible.
func _append_fallback_straw() -> void:
	var stick_script: GDScript = load("res://screens/StickSelectViewController.gd")
	if stick_script == null:
		return
	var consts := stick_script.get_script_constant_map()
	var foods: Dictionary = consts.get("FOODS", {})
	var packs: Dictionary = consts.get("PACKS", {})
	if not foods.has(_class_str):
		return
	var pack: int = int((foods[_class_str]["packs"] as Array)[0])
	var art := str((packs[pack] as Array)[0]) + ".png"
	var straw := _img(art)
	if straw == null:
		return
	_append_custom("Straw", straw, {"IsEdible": false, "ViewIndex": 2,
		"Type": "Stationary",
		"ItemCenterX": 250.0 - straw.get_width() * 0.5,
		"ItemCenterY": 30.0 if _class_str == "MILK_SHAKE" else 70.0,
		"Rotation": 15.0})


## addCustomView:category: (0xB04B0) = addCategory: + processCustomView:
## category: (0xB0780). The view is a DecorateItemView built with
## initWithImage:andTintColor:andBlendMode: -- a ZERO frame with the art as a
## subview at (0,0) -- so setCenter:(ItemCenterX, ItemCenterY) puts the art's
## TOP-LEFT there, and setTransform: rotates it about that same point. Only a
## category whose Type is "Stationary" gets its view placed at all; any other
## Type leaves the category empty (every food's bake-out passes Stationary).
## The view is non-interactive. ItemLimit / ReplaceLastItem apply as for grid
## items.
func _append_custom(cat_name: String, image: Variant, props: Dictionary) -> void:
	# Accept either an Image or a Texture2D. Baking screens legitimately
	# produce both -- ccMachine and kcShakeToColor hand over an Image, while
	# msBlender and cdFryDog hand over a Texture2D -- and this used to `return`
	# on anything that was not an Image, dropping those layers *silently*. Corn
	# Dog reached this screen with nothing to draw; the milkshake only looked
	# fine because the fallback below re-baked it. Convert rather than reject.
	if image is Texture2D:
		image = (image as Texture2D).get_image()
	if image is Image and (image as Image).is_compressed():
		image = (image as Image).duplicate()
		(image as Image).decompress()
	var cat := _category_named(cat_name)
	if cat.is_empty():
		cat = _category_from(cat_name, props)
		cat["in_view"] = true
		_categories.append(cat)
	if cat["type"] != "Stationary" or not _limit_allows(cat):
		return
	_replace_if_needed(cat)
	if not (image is Image):
		return   # initWithImage:nil -- an empty view; nothing to draw
	cat["views"].append({
		"kind": "custom", "category": cat_name, "image": image,
		"top_left": Vector2(float(str(props.get("ItemCenterX", 0.0))),
			float(str(props.get("ItemCenterY", 0.0)))),
		"rot_deg": float(str(props.get("Rotation", 0.0))), "node": null,
	})


## msBlender nextClick: 0x56608. ms_Ice_Cream_For_Glass.png clipped to its own
## alpha, filled with finalColor, the art multiplied back over it, then three
## 20x20 multiply stamps at alpha 0.3 per stored ingredient tag.
##
## CG's non-premultiplied edge algebra is approximated: interior pixels get the
## exact art*finalColor product; only 1px antialiased edges differ.
func _bake_milkshake() -> Image:
	var art := _img("ms_Ice_Cream_For_Glass.png")
	if art == null:
		return null
	var fc: Color = GameState.final_color()
	var w := art.get_width()
	var h := art.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var s := art.get_pixel(x, y)
			if s.a > 0.0:
				out.set_pixel(x, y, Color(s.r * fc.r, s.g * fc.g, s.b * fc.b, s.a))
	for tag: String in GameState.fruits:
		var choices: Array = FX_ART.get(tag, [FX_DEFAULT])
		for i in 3:
			var pick: String = choices[0]
			if choices.size() > 1:
				pick = choices[0] if randf() >= 0.5 else choices[1]
			var fx := _img(pick + ".png")
			if fx == null:
				continue
			fx = fx.duplicate()
			fx.resize(FX_STAMP, FX_STAMP)
			var ox := FX_X_BASE + randi() % FX_X_SPAN
			var oy := FX_Y_BASE + randi() % FX_Y_SPAN
			for fy in FX_STAMP:
				for fx_x in FX_STAMP:
					var px := ox + fx_x
					var py := oy + fy
					if px >= w or py >= h:
						continue
					var s := fx.get_pixel(fx_x, fy)
					var f := FX_ALPHA * s.a
					if f <= 0.0:
						continue
					var d := out.get_pixel(px, py)
					out.set_pixel(px, py, Color(
						d.r * (1.0 - f) + s.r * d.r * f,
						d.g * (1.0 - f) + s.g * d.g * f,
						d.b * (1.0 - f) + s.b * d.b * f, d.a))
	return out


## rearrangeViews 0xB1A3C / Category compare: 0xB5564 -- ascending viewIndex,
## equal indexes left in insertion order (custom categories before the plist
## ones). INFERRED: NSArray's sortedArrayUsingSelector: keeps equal elements in
## order (Godot's sort_custom does not, hence the explicit tie-break). The one
## tie in the shipped data is the snow cone's cup (5) and its Draw-ons (5):
## the paint canvas lands above the cup.
func _sort_categories() -> void:
	for i in _categories.size():
		_categories[i]["order"] = i
	_categories.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["view_index"]) != int(b["view_index"]):
			return int(a["view_index"]) < int(b["view_index"])
		return int(a["order"]) < int(b["order"]))


func _build_layers() -> void:
	for cat: Dictionary in _categories:
		if not bool(cat.get("in_view", true)):
			continue
		var layer := Node2D.new()
		layer.name = str(cat["name"]).validate_node_name()
		_decorate.add_child(layer)
		cat["layer"] = layer
		# Custom views recorded before the layer existed get nodes now.
		for view: Dictionary in cat["views"]:
			_make_view_node(view, cat)


## viewDidLoad 0xA56A4 tail: every category of Type Background has its first
## item applied immediately (that is why the screen never opens on a blank
## backdrop).
func _apply_default_backgrounds() -> void:
	for cat: Dictionary in _categories:
		if cat["type"] == "Background" and not (cat["items"] as Array).is_empty():
			_process_grid_item(cat["items"][0], cat)


# -- placing items (processGridItem: 0xB0B10) --------------------------

func _limit_allows(cat: Dictionary) -> bool:
	var limit: int = cat["item_limit"]
	return limit == 0 or cat["replace_last"] or (cat["views"] as Array).size() < limit


## ReplaceLastItem at the limit removes the OLDEST view (objectAtIndex:0).
func _replace_if_needed(cat: Dictionary) -> void:
	var views: Array = cat["views"]
	if cat["replace_last"] and cat["item_limit"] > 0 \
			and views.size() >= cat["item_limit"]:
		var old: Dictionary = views[0]
		views.remove_at(0)
		_undo_stack.erase(old)
		if old["node"] != null and is_instance_valid(old["node"]):
			(old["node"] as Node).queue_free()


func _process_grid_item(item: Dictionary, cat: Dictionary) -> void:
	# Selecting any item ends the active paint session (top of 0xB0B10).
	_end_paint_session()
	if not bool(cat.get("in_view", true)) or cat["layer"] == null:
		return   # "GridItem with unknown category" (NSLog only)
	if not _limit_allows(cat):
		return

	var view := {}
	match str(cat["type"]):
		"Background":
			var image := _item_img(str(item.get("Image", "")))
			if image == null:
				return
			view = {"kind": "bg", "category": cat["name"], "image": image,
				"center": BG_CENTER, "rot_deg": 0.0, "node": null}
			_replace_if_needed(cat)
			cat["views"].append(view)
			# Backgrounds are NOT pushed on the undo stack.
		"Drag":
			var image := _item_img(str(item.get("Image", "")))
			if image == null:
				return
			view = {"kind": "drag", "category": cat["name"], "image": image,
				"center": _item_center(item, cat), "rot_deg": _item_rot(item),
				"node": null}
			_replace_if_needed(cat)
			cat["views"].append(view)
			_undo_stack.append(view)
		"Stationary":
			var image := _item_img(str(item.get("Image", "")))
			if image == null:
				return
			view = {"kind": "stationary", "category": cat["name"],
				"image": image, "center": _item_center(item, cat),
				"rot_deg": _item_rot(item), "node": null}
			_replace_if_needed(cat)
			cat["views"].append(view)
			_undo_stack.append(view)
		"Paint":
			_replace_if_needed(cat)
			var brush := _img(str(item.get("Image", "")))
			if brush == null:
				return
			var canvas := Image.create(PAINT_SIZE.x, PAINT_SIZE.y, false,
				Image.FORMAT_RGBA8)
			view = {"kind": "paint", "category": cat["name"], "image": canvas,
				"brush": brush, "has_drawing": false,
				"pixels_between": float(str(_prop(item, cat, "PixelsBetween", 0.0))),
				"random_rotation": bool(_prop(item, cat, "RandomRotation", false)),
				"top_left": Vector2.ZERO, "rot_deg": 0.0, "node": null}
			cat["views"].append(view)
			_undo_stack.append(view)
			_paint_current = view
		_:
			return
	_make_view_node(view, cat)


## Item value with category-property fallback (0xB0B10 reads ItemCenterX from
## the item dict first, then the category).
func _prop(item: Dictionary, cat: Dictionary, key: String, fallback: Variant) -> Variant:
	if item.has(key):
		return item[key]
	return (cat["props"] as Dictionary).get(key, fallback)


func _item_center(item: Dictionary, cat: Dictionary) -> Vector2:
	# Plist values are a mix of strings and numbers; the original goes through
	# floatValue either way.
	return Vector2(
		float(str(_prop(item, cat, "ItemCenterX", 160.0))),
		float(str(_prop(item, cat, "ItemCenterY", 240.0))))


func _item_rot(item: Dictionary) -> float:
	return float(str(item.get("Rotation", 0.0)))


func _make_view_node(view: Dictionary, cat: Dictionary) -> void:
	var layer: Node2D = cat["layer"]
	if layer == null:
		return
	var sprite := Sprite2D.new()
	var itex := ImageTexture.create_from_image(view["image"])
	sprite.texture = itex
	match str(view["kind"]):
		"custom":
			# Zero-frame class: the recorded point is the TOP-LEFT and any
			# rotation happens about that same point (anchor of a zero rect).
			sprite.centered = false
			var holder := Node2D.new()
			holder.position = view["top_left"]
			holder.rotation_degrees = view["rot_deg"]
			holder.add_child(sprite)
			layer.add_child(holder)
			view["node"] = holder
		"paint":
			sprite.centered = false
			sprite.position = Vector2.ZERO
			layer.add_child(sprite)
			view["node"] = sprite
			view["texture"] = itex
		_:
			# Self-sizing UIImageView: true centre; rotation about the centre.
			sprite.centered = true
			sprite.position = view["center"]
			sprite.rotation_degrees = view["rot_deg"]
			layer.add_child(sprite)
			view["node"] = sprite


func _end_paint_session() -> void:
	# The canvas stays as an ordinary (draggable!) full-screen view -- the
	# original only clears currentPaintView/paint/delegate (0xB0B10 head), and
	# an interactive non-paint DecorateItemView drags itself (0xBCE1C).
	_paint_current = {}


## removeDecorateView: 0xB0618.
func _remove_view(view: Dictionary) -> void:
	if view["node"] != null and is_instance_valid(view["node"]):
		(view["node"] as Node).queue_free()
	_undo_stack.erase(view)
	for cat: Dictionary in _categories:
		(cat["views"] as Array).erase(view)
	if _paint_current == view:
		_paint_current = {}


# -- the nib buttons ---------------------------------------------------

## undo: 0xA91B8 -- a paint view with drawing gets cleared; anything else on
## the stack is removed outright.
func _on_undo() -> void:
	Audio.play("button_press")
	if _undo_stack.is_empty():
		return
	var last: Dictionary = _undo_stack.back()
	if str(last["kind"]) == "paint" and bool(last.get("has_drawing", false)):
		(last["image"] as Image).fill(Color(0, 0, 0, 0))
		last["has_drawing"] = false
		if last.has("texture"):
			(last["texture"] as ImageTexture).update(last["image"])
	else:
		_remove_view(last)


## back: 0xA907C -- pages the category bar backwards first; only pops the
## screen from the first page. Either way the badge and coins come back and
## the grid slides away (hideAnimated:YES). The bar buttons' selected state is
## left alone (only categoryButtonClicked: / gridItemViewClicked: touch it).
func _on_back() -> void:
	Audio.play("button_press")
	if _page_animating:
		return
	if not _set_page(_current_page - 1, true):
		Nav.back()
	_set_chrome_alpha(1.0)
	_hide_grid(true)


## next: 0xA9294 -- pages the bar forwards; off the end, bakes the EatItem /
## DrinkItem and pushes the eat screen. Then, as back:, chrome alpha 1 and
## hideAnimated:YES.
func _on_next() -> void:
	Audio.play("button_press")
	if _page_animating:
		return
	if not _set_page(_current_page + 1, true):
		if _class_str == "":
			return   # NSAssert "Unrecognized class given in MakeViewController.m"
		# The slide-away would run behind Eat (this node leaves the tree on
		# the push), and viewWillAppear: parks the grid on the way back.
		_set_chrome_alpha(1.0)
		_hide_grid(false)
		_push_eat_screen()
		return
	_set_chrome_alpha(1.0)
	_hide_grid(true)


func _push_eat_screen() -> void:
	var layers: Array = []
	for cat: Dictionary in _categories:
		if (cat["views"] as Array).is_empty():
			continue   # createEatItem 0xB1CE4 skips empty categories
		# CategoryProperties carries each category's own properties; EatSubview
		# (0xBE41C) reads IsEdible from them, EatView (0xC1830) orders by
		# ViewIndex.
		layers.append({
			"name": cat["name"],
			"edible": bool(cat["edible"]),
			"view_index": int(cat["view_index"]),
			"image": _compose_category(cat),
			# createEatItem's CategoryProperties[name] = category.properties
			# (0xB1CE4); EatItem stores it verbatim.
			"properties": (cat["props"] as Dictionary).duplicate(),
		})
	var item := {
		"class_str": _class_str,
		"item_name": ITEM_NAME.get(_class_str, _class_str),
		"drink": DRINK_INFO.has(_class_str),
		"liquid_mask": "", "liquid_category": "",
		"layers": layers,
	}
	if item["drink"]:
		item["liquid_mask"] = DRINK_INFO[_class_str]["mask"]
		item["liquid_category"] = DRINK_INFO[_class_str]["category"]
	var eat_script: GDScript = load("res://screens/EatViewController.gd")
	eat_script.set_pending(item)
	Nav.push("EatViewController")


## createEatItem 0xB1CE4: each category's views rendered into one full-screen
## image, in view order.
func _compose_category(cat: Dictionary) -> Image:
	var out := Image.create(320, 480, false, Image.FORMAT_RGBA8)
	for view: Dictionary in cat["views"]:
		var src: Image = view["image"]
		# Image.blend_rect refuses mismatched formats. Layers arrive straight
		# from textures (an RGB8 plate, a compressed import), so normalise.
		if src.get_format() != Image.FORMAT_RGBA8 or src.is_compressed():
			src = src.duplicate()
			if src.is_compressed():
				src.decompress()
			src.convert(Image.FORMAT_RGBA8)
		match str(view["kind"]):
			"paint":
				out.blend_rect(src, Rect2i(0, 0, src.get_width(), src.get_height()),
					Vector2i.ZERO)
			"custom":
				var live := _live_top_left(view)
				if float(view["rot_deg"]) == 0.0:
					out.blend_rect(src,
						Rect2i(0, 0, src.get_width(), src.get_height()),
						Vector2i(live.round()))
				else:
					_blend_rotated(out, src, live, float(view["rot_deg"]), false)
			_:
				var center := _live_center(view)
				if float(view["rot_deg"]) == 0.0:
					var tl := center - Vector2(src.get_width(), src.get_height()) * 0.5
					out.blend_rect(src,
						Rect2i(0, 0, src.get_width(), src.get_height()),
						Vector2i(tl.round()))
				else:
					_blend_rotated(out, src, center, float(view["rot_deg"]), true)
	return out


func _live_center(view: Dictionary) -> Vector2:
	var n: Node = view.get("node")
	if n is Node2D and is_instance_valid(n):
		return (n as Node2D).position
	return view.get("center", Vector2.ZERO)


func _live_top_left(view: Dictionary) -> Vector2:
	var n: Node = view.get("node")
	if n is Node2D and is_instance_valid(n):
		return (n as Node2D).position
	return view.get("top_left", Vector2.ZERO)


## Rotated alpha blit, pivot at `pivot` (art centre when centered, else the
## art's top-left). Nearest-neighbour inverse mapping.
func _blend_rotated(dst: Image, src: Image, pivot: Vector2, deg: float,
		centered: bool) -> void:
	var rad := deg_to_rad(deg)
	var c := cos(rad)
	var s := sin(rad)
	var sw := src.get_width()
	var sh := src.get_height()
	var anchor := Vector2(sw, sh) * 0.5 if centered else Vector2.ZERO
	# AABB of the rotated art.
	var r := maxf(float(sw), float(sh)) * 1.5
	var x0 := maxi(0, int(pivot.x - r))
	var y0 := maxi(0, int(pivot.y - r))
	var x1 := mini(dst.get_width(), int(pivot.x + r) + 1)
	var y1 := mini(dst.get_height(), int(pivot.y + r) + 1)
	for y in range(y0, y1):
		for x in range(x0, x1):
			var v := Vector2(x, y) - pivot
			var sx := int(roundf(v.x * c + v.y * s + anchor.x))
			var sy := int(roundf(-v.x * s + v.y * c + anchor.y))
			if sx < 0 or sy < 0 or sx >= sw or sy >= sh:
				continue
			var sp := src.get_pixel(sx, sy)
			if sp.a <= 0.0:
				continue
			var dp := dst.get_pixel(x, y)
			dst.set_pixel(x, y, dp.blend(sp))


# -- category button bar ----------------------------------------------

## rebuildPages 0xB8FD0 + the viewDidLoad button assembly: one button per
## distinct ButtonIndex (first category wins), sorted by index, laid out at
## x starting BAR_X_OFFSET advancing width + BAR_X_SPACING, 3 per page.
## Buttons have no selected-state art (only setImage:forState:normal), so
## selection is tracked logically with no visual change -- as shipped.
func _build_bar() -> void:
	_bar = Node2D.new()
	_bar.name = "CategoryButtonsView"
	add_child(_bar)

	var by_index := {}
	for cat: Dictionary in _categories:
		if str(cat["button_image"]) == "" \
				or (_grid_items(cat).is_empty() and not _items_from_info(cat)):
			continue
		var idx: int = cat["button_index"]
		if not by_index.has(idx):
			by_index[idx] = cat
	var indexes: Array = by_index.keys()
	indexes.sort()

	var page: Node2D = null
	var on_page := 0
	var x_offset := BAR_X_OFFSET_SHELF \
		if _class_str == TROPHY_CASE or _class_str == FOOD_COLLAGE else BAR_X_OFFSET
	var x := x_offset
	for idx: int in indexes:
		if page == null or on_page >= BUTTONS_PER_PAGE:
			page = Node2D.new()
			page.visible = _pages.is_empty()
			_bar.add_child(page)
			_pages.append(page)
			on_page = 0
			x = x_offset
		var cat: Dictionary = by_index[idx]
		var tex := _tex(str(cat["button_image"]))
		var btn := TextureButton.new()
		btn.texture_normal = tex
		btn.position = Vector2(x, 0)
		if tex != null:
			btn.size = tex.get_size()
			x += tex.get_size().x + BAR_X_SPACING
		var cat_name := str(cat["name"])
		btn.pressed.connect(_on_category_button.bind(cat_name))
		page.add_child(btn)
		_bar_buttons[cat_name] = btn
		on_page += 1


## setCurrentPage:animated: 0xB9640. Returns false when the page is out of
## range (which is what lets next:/back: fall through to navigation).
func _set_page(page: int, animated: bool) -> bool:
	if page < 0 or page >= _pages.size():
		return false
	if _page_animating:
		return true
	if page == _current_page or not animated:
		for i in _pages.size():
			(_pages[i] as Node2D).visible = i == page
			(_pages[i] as Node2D).position = Vector2.ZERO
		_current_page = page
		return true
	var incoming: Node2D = _pages[page]
	var outgoing: Node2D = _pages[_current_page]
	var dir := 1.0 if page > _current_page else -1.0
	incoming.position = Vector2(320.0 * dir, 0)
	incoming.visible = true
	outgoing.visible = true
	_page_animating = true
	var tw := create_tween()
	tw.set_parallel(true)
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(incoming, "position", Vector2.ZERO, PAGE_SLIDE)
	tw.tween_property(outgoing, "position", Vector2(-320.0 * dir, 0), PAGE_SLIDE)
	tw.chain().tween_callback(func() -> void:
		outgoing.visible = false
		_page_animating = false)
	_current_page = page
	return true


## categoryButtonClicked: 0xA9E24 -- every other button is deselected; a tap
## on the already-selected button deselects it, restores the badge and coins
## and slides the grid away; otherwise the button is selected, that
## ButtonIndex's items load, the badge and coins go to alpha 0 and the grid
## slides in. (The buttons have no selected-state art, so selection is
## invisible -- as shipped.)
func _on_category_button(cat_name: String) -> void:
	Audio.play("button_press")
	if _selected_button == cat_name:
		_selected_button = ""
		_set_chrome_alpha(1.0)
		_hide_grid(true)
		return
	_selected_button = cat_name
	_load_grid_for(cat_name)
	_set_chrome_alpha(0.0)
	_show_grid(true)


# -- the item grid -----------------------------------------------------

func _build_grid() -> void:
	_grid = Control.new()
	_grid.name = "ScrollableGridView"
	_grid.position = Vector2(GRID_FRAME.position.x, GRID_HIDDEN_Y)
	_grid.size = GRID_FRAME.size
	_grid.clip_contents = true
	_grid.mouse_filter = Control.MOUSE_FILTER_STOP
	_grid.visible = false
	_grid.gui_input.connect(_on_grid_input)
	add_child(_grid)
	# bringSubviewToFront: grid, then the bar (0xA64E0..0xA6520).
	move_child(_grid, get_child_count() - 1)
	if _bar != null:
		move_child(_bar, get_child_count() - 1)
	_grid_content = Node2D.new()
	_grid.add_child(_grid_content)
	_grid_pan = ScrollableGridViewScript.PanScroller.new(true)
	_grid_pan.axis.always_bounce = true      # ScrollableGridView initWithFrame:
	_grid_pan.configure(GRID_FRAME.size.y, GRID_FRAME.size.y)


## loadCategoryToGridView: 0xA6FE4 -- every category sharing the clicked
## ButtonIndex contributes its items, unlocked before locked. The port ships
## everything unlocked, so that is plain category order.
func _load_grid_for(cat_name: String) -> void:
	for c in _grid_cells:
		if is_instance_valid(c):
			(c as Node).queue_free()
	_grid_cells.clear()

	var clicked := _category_named(cat_name)
	if clicked.is_empty():
		return
	var wanted: int = clicked["button_index"]
	var bg := _tex(CELL_BG)
	var cell_size := bg.get_size() if bg != null else Vector2(91, 90)

	var col := 0
	var pos := Vector2.ZERO
	# DecorateView's categories (ViewIndex order), every one whose ButtonIndex
	# matches -- whether or not it has a button image of its own.
	for cat: Dictionary in _categories:
		if int(cat["button_index"]) != wanted or not bool(cat.get("in_view", true)):
			continue
		for item: Dictionary in _grid_items(cat):
			if col >= GRID_PER_ROW:
				col = 0
				pos.x = 0
				pos.y += cell_size.y + GRID_Y_SPACING
			var cell := Node2D.new()
			cell.position = pos
			cell.set_meta("rect", Rect2(pos, cell_size))
			cell.set_meta("item", item)
			cell.set_meta("cat", cat)
			_grid_content.add_child(cell)
			_grid_cells.append(cell)
			# setOverlayViewsToGridViews: (0xAA634): a prize not yet won.
			var locked := _prize_locked(item, cat)
			cell.set_meta("locked", locked)
			var cell_bg := _tex(CELL_BG_LOCKED) if locked else bg
			if cell_bg != null:
				var back := Sprite2D.new()
				back.texture = cell_bg
				back.centered = false
				cell.add_child(back)
			var thumb := _tex(PRIZE_UNKNOWN_THUMB) if locked \
				else _thumb_texture(str(item.get("Thumbnail", "")))
			if thumb != null:
				var icon := Sprite2D.new()
				icon.texture = thumb
				icon.centered = true
				icon.position = cell_size * 0.5
				cell.add_child(icon)
			pos.x += cell_size.x + GRID_X_SPACING
			col += 1
	_grid_content_h = pos.y + cell_size.y + GRID_Y_SPACING
	# loadItems: setContentSize: (the offset is left where it was; showAnimated:
	# zeroes it before the grid comes down).
	_grid_pan.configure(GRID_FRAME.size.y, _grid_content_h)


## The items a category's grid shows: TrophyCase_Prizes and Collage_Items
## take infoDict["Items"] (loadCategoryToGridView: 0xA6FE4,
## loadCollageItemsToGridView 0xA7820); every other category its plist Items.
func _grid_items(cat: Dictionary) -> Array:
	if _items_from_info(cat):
		var items: Variant = _info_dict.get("Items", [])
		return items if items is Array else []
	return cat["items"]


func _items_from_info(cat: Dictionary) -> bool:
	var n := str(cat["name"])
	return n == PRIZES_CATEGORY or n == COLLAGE_CATEGORY


## setOverlayViewsToGridViews: (0xAA634): TrophyCase_Prizes and the prize's
## IAPKey user default is NO (PrizeManager unlock_prize sets it on a win).
func _prize_locked(item: Dictionary, cat: Dictionary) -> bool:
	if str(cat["name"]) != PRIZES_CATEGORY:
		return false
	return not Defaults.bool_for_key(str(item.get("IAPKey", "")))


## GridItemView's image: a bundle file (imageNamed:) or, for the collage, the
## Thumbnail PATH in the save folder (loadCollageItemsToGridView sets
## imagePath to it directly).
func _thumb_texture(file: String) -> Texture2D:
	var t := _tex(file)
	if t == null and file != "":
		t = EatItemScript.load_texture(file)
	return t


func _category_named(cat_name: String) -> Dictionary:
	for cat: Dictionary in _categories:
		if str(cat["name"]) == cat_name:
			return cat
	return {}


## showAnimated: 0xB41B0 -- scroll to top, park at hiddenLocation, slide to
## location. Linear (UIViewAnimationCurve 3), 0.3s.
func _show_grid(animated: bool) -> void:
	if _grid_animating or _grid_cells.is_empty():
		return
	_kill_grid_tween()
	# setContentOffset:(x, 0) animated:NO.
	_grid_pan.set_offset(0.0)
	_grid_content.position = Vector2.ZERO
	_grid.visible = true
	_grid_visible = true
	_grid.mouse_filter = Control.MOUSE_FILTER_STOP
	if animated:
		_grid.position = Vector2(GRID_FRAME.position.x, GRID_HIDDEN_Y)
		_grid_animating = true
		_grid_tween = create_tween()
		_grid_tween.tween_property(_grid, "position",
			Vector2(GRID_FRAME.position.x, GRID_SHOWN_Y), GRID_SLIDE) \
			.set_trans(Tween.TRANS_LINEAR)
		_grid_tween.tween_callback(func() -> void: _grid_animating = false)
	else:
		_grid.position = Vector2(GRID_FRAME.position.x, GRID_SHOWN_Y)


## hideAnimated: snaps to the shown location and slides up from there, so on
## an already-hidden grid it plays unseen; the port skips that invisible run.
func _hide_grid(animated: bool) -> void:
	if _grid_animating:
		return
	_kill_grid_tween()
	if not _grid_visible:
		_grid.visible = false
		return
	_grid_visible = false
	if animated:
		_grid.position = Vector2(GRID_FRAME.position.x, GRID_SHOWN_Y)
		_grid_animating = true
		# The model is already off the top: touches on the departing grid go
		# to whatever lies under it (see _on_grid_input).
		_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_grid_tween = create_tween()
		_grid_tween.tween_property(_grid, "position",
			Vector2(GRID_FRAME.position.x, GRID_HIDDEN_Y), GRID_SLIDE) \
			.set_trans(Tween.TRANS_LINEAR)
		_grid_tween.tween_callback(func() -> void:
			_grid.visible = false
			_grid_animating = false)
	else:
		_grid.position = Vector2(GRID_FRAME.position.x, GRID_HIDDEN_Y)
		_grid.visible = false


func _kill_grid_tween() -> void:
	if _grid_tween != null and _grid_tween.is_valid():
		_grid_tween.kill()


## The grid is a UIScrollView (ScrollableGridView.PanScroller): a touch on a
## cell is a tap unless the pan claims it (10 pt vertically) or it caught
## the grid still moving; the wheel is a PORT CHOICE with no iOS counterpart.
func _on_grid_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := (event as InputEventMouseButton).duplicate() as InputEventMouseButton
		# showAnimated: / hideAnimated: (0xB41B0 / 0xB4458) slide the grid with
		# +beginAnimations:/commitAnimations, which leaves it touchable but
		# hit-tested at its MODEL frame: already shown while it slides in,
		# already at hiddenLocation -- off the top of the screen -- while it
		# slides away. So a touch on the departing grid reaches no cell (the
		# port used to place a second item from it), and a touch during the
		# slide-in picks the cell at its final place.
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed \
				and _grid_animating and not _grid_visible:
			return
		mb.position = _grid_to_model(mb.position)
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if mb.pressed:
				_scroll_grid(30.0)
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_scroll_grid(-30.0)
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_grid_pan.press(mb.position)
			_grid_press_cell = null if _grid_pan.caught else _grid_cell_at(mb.position)
			_apply_grid_offset()
		elif _grid_pan.tracking:
			var cell := _grid_press_cell
			_grid_press_cell = null
			var tap := _grid_pan.release(mb.position)
			_apply_grid_offset()
			# touchUpInside: the cell the touch went down on, released within
			# UIControl's 70 pt of it.
			if tap and cell != null and is_instance_valid(cell):
				var r: Rect2 = cell.get_meta("rect")
				r.position += _grid_content.position
				if r.grow(ScrollableGridViewScript.PanScroller.CONTROL_SLOP).has_point(mb.position):
					_grid_cell_clicked(cell)
	elif event is InputEventMouseMotion and _grid_pan.tracking:
		if _grid_pan.move(_grid_to_model((event as InputEventMouseMotion).position)):
			_apply_grid_offset()
		if _grid_pan.dragging():
			_grid_press_cell = null


## A point in the grid's drawn frame, in its model frame (see _on_grid_input).
func _grid_to_model(local: Vector2) -> Vector2:
	if not _grid_animating:
		return local
	var model := Vector2(GRID_FRAME.position.x,
		GRID_SHOWN_Y if _grid_visible else GRID_HIDDEN_Y)
	return local + (_grid.position - model)


func _scroll_grid(dy: float) -> void:
	var lo := maxf(0.0, _grid_content_h - GRID_FRAME.size.y)
	_grid_pan.set_offset(clampf(_grid_pan.offset() - dy, 0.0, lo))
	_apply_grid_offset()


func _apply_grid_offset() -> void:
	_grid_content.position.y = -_grid_pan.offset()


func _process(delta: float) -> void:
	if _grid_pan != null and _grid_pan.step(delta):
		_apply_grid_offset()


## The cell under a point in the grid's own (frame) coordinates.
func _grid_cell_at(local: Vector2) -> Node2D:
	var content_local := local - _grid_content.position
	for cell in _grid_cells:
		if is_instance_valid(cell) and (cell.get_meta("rect") as Rect2).has_point(content_local):
			return cell
	return null


## gridItemViewClicked: 0xAA120 (unlocked path -- the port ships everything
## unlocked): place the item, hide the grid, deselect every category button.
func _grid_cell_clicked(cell: Node2D) -> void:
	Audio.play("button_press")
	if bool(cell.get_meta("locked", false)):
		# gridItemViewClicked: (0xAA120), tag-1000 TrophyCase_Prizes
		# cell: the alert only (no delegate -> a silent OK).
		var item: Dictionary = cell.get_meta("item")
		show_alert("%s is locked." % str(item.get("Name", "")), ["OK"],
			Callable(), false)
		return
	_set_chrome_alpha(1.0)
	_process_grid_item(cell.get_meta("item"), cell.get_meta("cat"))
	_hide_grid(true)
	_selected_button = ""


# -- decorate interaction (drag + paint) -------------------------------

func _unhandled_input(event: InputEvent) -> void:
	# hitTest 0xB258C: while a paint session is live, EVERY touch on the
	# decorate view goes to the canvas.
	if not _paint_current.is_empty():
		_paint_input(event)
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			var hit := _topmost_draggable(mb.position)
			if not hit.is_empty():
				_drag_record = hit
				_drag_node_start = (hit["node"] as Node2D).position
				_drag_mouse_start = mb.position
				get_viewport().set_input_as_handled()
		else:
			_drag_record = {}
	elif event is InputEventMouseMotion and not _drag_record.is_empty():
		var mm := event as InputEventMouseMotion
		var n: Node2D = _drag_record["node"]
		if is_instance_valid(n):
			# moveSelfToNewPoint: 0xBCD70 -- origin += (touch - grab).
			n.position = _drag_node_start + (mm.position - _drag_mouse_start)


## UIKit hit-testing: topmost interactive view whose bounds contain the point.
## Interactive = Drag items only (setUserInteractionEnabled:YES in 0xB0B10).
## A Drag item is a self-sizing DecorateItemView whose rotation is a view
## transform, so the test happens in its own (rotated) bounds.
##
## A paint canvas is interactive too, but it is a ZERO-frame view (built with
## initWithImage:andTintColor:andBlendMode:, never given a frame), so UIKit's
## pointInside: never accepts it; it only receives touches through
## DecorateView hitTest: (0xB258C) while it is the current paint view. Once the
## session ends (any other grid item), a finished canvas is untouchable. The
## port used to treat it as a full-screen draggable view, so the first drag
## after a paint session slid the whole drawing around.
func _topmost_draggable(point: Vector2) -> Dictionary:
	for ci in range(_categories.size() - 1, -1, -1):
		var cat: Dictionary = _categories[ci]
		var views: Array = cat["views"]
		for vi in range(views.size() - 1, -1, -1):
			var view: Dictionary = views[vi]
			if str(view["kind"]) != "drag":
				continue
			var n: Node2D = view["node"]
			if n == null or not is_instance_valid(n):
				continue
			var img: Image = view["image"]
			var half := Vector2(img.get_width(), img.get_height()) * 0.5
			var local := (point - n.position).rotated(-n.rotation)
			if Rect2(-half, half * 2.0).has_point(local):
				return view
	return {}


func _paint_input(event: InputEvent) -> void:
	var view := _paint_current
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			# touchesBegan 0xBCE1C (paint): startingPoint = the touch. It also
			# redraws the canvas, but with nothing new on it: without
			# RandomRotation it draws no brush at all, and with it the stamp
			# position is (0/0)*touch -- NaN -- so CoreGraphics draws nothing.
			# A tap without a drag leaves no mark and hasDrawing stays NO.
			_paint_last = mb.position
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			return
		# touchesMoved 0xBD0E0: once the finger is more than pixelsBetween
		# from startingPoint, stamp from the current point back toward it,
		# advancing hypot(w/2, h/2) + pixelsBetween + 1 per stamp, where w,h
		# are the stamp actually drawn (the rotated image when RandomRotation).
		var dist := _paint_last.distance_to(mm.position)
		var between := float(view["pixels_between"])
		if dist <= between:
			return
		view["has_drawing"] = true
		var dir := (_paint_last - mm.position) / dist
		var t := 0.0
		while t < dist:
			var size := _stamp(view, mm.position + dir * t)
			t += size.length() * 0.5 + between + 1.0
		_paint_last = mm.position
		if view.has("texture"):
			(view["texture"] as ImageTexture).update(view["image"])


## One brush stamp centred at `at`; returns the stamped image's size.
## RandomRotation: a fresh arc4random() % 360 degrees per stamp, drawn centred
## from rotatedImage:. INFERRED: that UIImage category method (not among the
## binary's ObjC classes) returns the rotated art in its bounding box, so the
## box is what the stamp step measures.
func _stamp(view: Dictionary, at: Vector2) -> Vector2:
	var canvas: Image = view["image"]
	var brush: Image = view["brush"]
	var size := Vector2(brush.get_width(), brush.get_height())
	if bool(view["random_rotation"]):
		var deg := float(randi() % 360)
		_blend_rotated(canvas, brush, at, deg, true)
		var r := deg_to_rad(deg)
		size = Vector2(absf(size.x * cos(r)) + absf(size.y * sin(r)),
			absf(size.x * sin(r)) + absf(size.y * cos(r)))
	else:
		var tl := at - size * 0.5
		canvas.blend_rect(brush,
			Rect2i(0, 0, brush.get_width(), brush.get_height()),
			Vector2i(tl.round()))
	return size

# NOT PORTED, deliberately, rather than guessed:
#
#  * The IAP lock overlays (setOverlayViewsToGridViews: 0xAA634, the
#    Sub_Button_Lock_Overlay branch) and the "Oops!" store alert in
#    gridItemViewClicked: -- IAP surface; the port ships FF_KEY_EVERYTHING
#    unlocked, so no such overlay is ever added. (The TrophyCase_Prizes
#    "not won yet" lock IS ported -- it is not IAP.)
#  * The 73x110 thumbnail createEatItem draws from the decorate view: EatItem
#    composites the same layers when the pending dict brings none.
#  * The Interstitial ad in viewDidLoad and the endMkrDate / DataLogging
#    bookkeeping -- ads and analytics.
#  * emitAtLocation: particles -- the original method body is literally
#    `bx lr` (0xAAA44): a no-op even on the device.
#  * The transient setCenter:(240,160) a Drag item gets for one runloop turn
#    before its real centre (0xB0B10) -- invisible on screen.
#  * UIScrollView feel on the item grid: alwaysBounceVertical and flick
#    deceleration are UIKit internals with no number in the binary; the grid
#    drags 1:1 and clamps.
#  * UIButton's darkened highlight while a bar button or grid cell is held.
