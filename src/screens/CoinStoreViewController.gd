# Coin store -- where GET COINS leads.
#
# From the v1.27 binary. The nib gives bg_store, btn_back
# (11,22,82,54), a UIClassSwapper -> ScrollableGridView at (0,92,320,388) and
# Coin_Store_Logo (100,10,194,79); the nib's bindings wire back:.
#
#   initWithNibName:bundle:  0x124C28  CoinIAP.plist entries sorted by "Index";
#                                      an entry is kept only if IAPlistManager
#                                      retrieveAmount:(AppStoreID) is non-nil
#                                      -- i.e. the price server knew it -- or
#                                      its AppStoreID is "Flurry" / "Tapjoy"
#                                      (the ad-network free-coin rows).
#   viewDidLoad              0x124F74  grid: 1 per row, no spacing, a CLEAR
#                                      320x80 grid background (the rows are the
#                                      320x80 coins_*.png themselves);
#                                      showAnimated:NO.
#   gridItemViewClicked:     0x1259A0  "store" sound; Tapjoy -> nothing,
#                                      Flurry -> flurry:, else purchaseItem:
#                                      0x125514 -> StoreKit.
#   productPurchased:        0x125800  addCoins:(retrieveAmount: AppStoreID),
#                                      syncCoins, loadItems.
#   back:                    0x125404  button_press, syncCoins, pop.
#
# The price server is gone, so on the phone today retrieveAmount: is nil for
# every pack and the store shows only the Flurry row. PORT CHOICES, stated:
# the port treats coin packs like every other pack -- owned -- so it lists
# the nine packs from the bundled table with their "Coins" values and tapping
# one grants that many coins with no payment; the Flurry and Tapjoy ad rows
# are left out, as every ad network is. The coins panel is hidden on this
# screen in the original (app delegate list), so the balance shows on return.
#
# The grant goes through CoinManager addCoins: +
# syncCoins:YES exactly as productPurchased: does, so it persists in the
# "TEMPORARY_COINS" default; back: calls syncCoins:YES as the original does.
#
# Scrolling: the grid is the nib's UIClassSwapper ->
# ScrollableGridView, a UIScrollView set up by initWithCoder: (0xB3630):
# alwaysBounceVertical YES, no paging, Normal (0.998) deceleration, bounces
# and the vertical indicator at the UIKit defaults (nib object 38 has no
# UIBounceEnabled / UIShows*ScrollIndicator keys). It runs on
# ScrollableGridView.PanScroller (core/UIScrollSim.gd's UIKit physics + the
# indicator). A row is a GridItemView (UIButton): it gets the tap only when
# the pan did not claim the touch (10 pt) and the touch did not catch the
# list moving; touchUpInside reaches 70 pt past the row the finger went
# down on.

extends "res://core/Screen.gd"

const ScrollableGridView := preload("res://core/ScrollableGridView.gd")
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const GRID_POS := Vector2(0, 92)
const GRID_SIZE := Vector2(320, 388)
const ROW_HEIGHT := 80.0                         # createImageWithFillColor:size: 320x80
## The import cache's data/CoinIAP.json (Assets).
const COIN_IAP_JSON := "CoinIAP"
const AD_ROWS := ["Flurry", "Tapjoy"]

var _packs: Array = []
var _content: Node2D
var _max_offset := 0.0
var _offset := 0.0
## The grid's UIScrollView (vertical).
var _pan: ScrollableGridView.PanScroller
## The row the touch went down on (-1: none / the touch is the scroll view's).
var _press_row := -1


func on_enter() -> void:
	_packs = _load_packs()
	_build_grid()


## Opted in. Nothing in the original pushes over the
## coin store (gridItemViewClicked: buys in place or opens an ad-network
## offer wall, back: pops). If something did, viewWillAppear: (0x12509C) /
## viewDidDisappear: (0x1251C0) only set and clear IAPlistManager's
## storeDelegate -- no port counterpart; the rows and scroll position are
## viewDidLoad state and stay.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	if _pan != null:
		_pan.cancel()
	_press_row = -1


func _load_packs() -> Array:
	var out: Array = []
	if not Assets.has_json(COIN_IAP_JSON):
		push_error("CoinStoreViewController: cannot open data/%s.json" % COIN_IAP_JSON)
		return out
	var table: Variant = Assets.json(COIN_IAP_JSON)
	if not (table is Dictionary):
		return out
	for key in (table as Dictionary).keys():
		var entry: Variant = table[key]
		if entry is Dictionary and not AD_ROWS.has(str(entry.get("AppStoreID", ""))):
			out.append(entry)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("Index", 0)) < int(b.get("Index", 0)))
	return out


func _build_grid() -> void:
	var grid := outlet("scrollableGridView")
	if grid == null or grid == self:
		return
	for c in grid.get_children():
		c.queue_free()
	var clip := Control.new()
	clip.name = "clip"
	clip.size = GRID_SIZE
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_child(clip)
	_content = Node2D.new()
	clip.add_child(_content)
	var y := 0.0
	for entry: Dictionary in _packs:
		var image := str(entry.get("Image", ""))
		if Assets.has_image(image):
			var s := Sprite2D.new()
			s.texture = Assets.texture(image)
			s.centered = false
			s.position = Vector2(0, y)
			_content.add_child(s)
		_add_overlay_labels(entry, y)
		y += ROW_HEIGHT
	_max_offset = maxf(0.0, y - GRID_SIZE.y)
	_pan = ScrollableGridView.PanScroller.new(true)
	_pan.axis.always_bounce = true
	_pan.configure(GRID_SIZE.y, y)
	_pan.add_indicator(grid, Rect2(Vector2.ZERO, GRID_SIZE))
	_set_offset(clampf(_offset, 0.0, _max_offset))


## setOverlayViewsToGridViews: (0x125A94) puts three UILabels on every pack
## row (the art leaves the COST and COINS bursts and the bar empty for them).
## Each is initWithFrame: then setCenter:, text centred, clear background,
## UILabel's default font (Helvetica 17, black):
##   amount       64x25 centre (282,37)  "%d"    IAPlistManager retrieveAmount:
##   price        67x25 centre (38,37)   "$%.2f" UnityExternals retrievePrice:
##   description 100x25 centre (160,55)  IAPlist[AppStoreID]["Description"]
## The amount shown is what the port grants: the bundled CoinIAP "Coins".
## PORT CHOICE: the price reads FREE -- nothing is sold, and the App Store
## price it showed no longer exists. The description came only from the
## price server (no copy ships in the app), so that label is left out rather
## than invented; the bar stays empty.
const OVERLAY_FONT_SIZE := 17
const OVERLAY_FONTS := ["Helvetica", "Helvetica Neue", "Nimbus Sans", "Liberation Sans", "Arial"]
const AMOUNT_FRAME := Rect2(282 - 32, 37 - 12.5, 64, 25)
const PRICE_FRAME := Rect2(38 - 33.5, 37 - 12.5, 67, 25)
const PRICE_TEXT := "FREE"


func _add_overlay_labels(entry: Dictionary, row_y: float) -> void:
	_add_label(str(int(entry.get("Coins", 0))), AMOUNT_FRAME, row_y)
	_add_label(PRICE_TEXT, PRICE_FRAME, row_y)


func _add_label(text: String, frame: Rect2, row_y: float) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER     # setTextAlignment:1
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS  # tail truncation
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := SystemFont.new()
	font.font_names = PackedStringArray(OVERLAY_FONTS)
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", OVERLAY_FONT_SIZE)
	l.add_theme_color_override("font_color", Color.BLACK)
	UILabelFrame.set_frame(l, Rect2(frame.position + Vector2(0, row_y), frame.size))
	_content.add_child(l)


# -- scrolling and taps ---------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _pan == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# PORT CHOICE: the mouse wheel, which iOS does not have.
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_set_offset(clampf(_offset - ROW_HEIGHT * 0.5, 0.0, _max_offset))
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_set_offset(clampf(_offset + ROW_HEIGHT * 0.5, 0.0, _max_offset))
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if Rect2(GRID_POS, GRID_SIZE).has_point(mb.position):
					_begin_press(mb.position - GRID_POS)
			elif _pan.tracking:
				_end_press(mb.position - GRID_POS)
	elif event is InputEventMouseMotion and _pan.tracking:
		if _pan.move((event as InputEventMouseMotion).position - GRID_POS):
			_apply_offset()
		if _pan.dragging():
			_press_row = -1


func _row_at(local_y: float) -> int:
	var row := int(floorf((local_y + _offset) / ROW_HEIGHT))
	return row if row >= 0 and row < _packs.size() else -1


func _begin_press(local: Vector2) -> void:
	_pan.press(local)
	_press_row = -1 if _pan.caught else _row_at(local.y)


func _end_press(local: Vector2) -> void:
	var row := _press_row
	_press_row = -1
	var tap := _pan.release(local)
	_apply_offset()
	if not tap or row < 0:
		return
	# touchUpInside: within 70 pt of the row's frame (0..320 x row band).
	var r := Rect2(0, row * ROW_HEIGHT - _offset, GRID_SIZE.x, ROW_HEIGHT)
	if r.grow(ScrollableGridView.PanScroller.CONTROL_SLOP).has_point(local):
		# GridItemView touchUpInside -> buttonPressed: -> gridItemViewClicked:.
		_grid_item_clicked(_packs[row])


func _process(delta: float) -> void:
	if _pan != null and _pan.step(delta):
		_apply_offset()


## setContentOffset: (not animated).
func _set_offset(y: float) -> void:
	if _pan != null:
		_pan.set_offset(y)
	_apply_offset()


func _apply_offset() -> void:
	if _pan != null:
		_offset = _pan.offset()
	if _content != null:
		_content.position.y = -_offset


## gridItemViewClicked: (0x1259A0) + productPurchased: (0x125800), with the
## payment step removed (port choice, header). PORT CHOICE: the App Store's
## purchase sheet was the original's only feedback here and the coins panel
## is hidden on this screen, so a plain alert stands in for that sheet.
func _grid_item_clicked(entry: Dictionary) -> void:
	Audio.play("store")
	var coins := int(entry.get("Coins", 0))
	if coins <= 0:
		return
	CoinManager.add_coins(coins)
	CoinManager.sync_coins(true)
	show_alert("%s\n+%d coins (now %d)" % [str(entry.get("PackName", "Coins")), coins, CoinManager.total_coins()],
		["OK"], Callable())


## back: (0x125404).
func _on_back() -> void:
	Audio.play("button_press")
	CoinManager.sync_coins(true)
	Nav.back()
