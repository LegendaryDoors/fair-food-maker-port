# Store.
#
# From the v1.27 binary. The nib gives bg_store, btn_back
# (11,22,82,54), a UIClassSwapper -> ScrollableGridView at (0,94,320,386),
# btn_restore (228,25,75,47) and the logo; the nib's bindings wire back: and
# restorePurchases:.
#
#   initWithNibName:bundle:  0x2812C  IAP.plist entries sorted by "Index".
#   viewDidLoad              0x283BC  grid: delegate self, XSpacing 0,
#                                     YSpacing 0, 1 item per row,
#                                     gridBackground store_item_panel.png
#                                     (320x125, fully transparent); loadItems;
#                                     showAnimated:NO.
#   loadItems                0x28548  one GridItem per entry whose IAPKey does
#                                     not contain "FF_KEY_CRATE_GAME", image =
#                                     the entry's "Image".
#   -[ScrollableGridView loadItems:] 0xB3928  each item is a GridItemView
#                                     (UIButton) sized to the grid background,
#                                     background = grid background, foreground
#                                     image = the item's art at natural size;
#                                     rows stack at y += 125 + YSpacing from
#                                     (XOffset, YOffset) = (0,0); contentSize
#                                     height = last y + 125.
#   setOverlayViewsToGridViews: 0x28C5C  the "SPACER" item's frame height is
#                                     doubled (its art, Unlock_Everything.png,
#                                     is 320x250; the next row draws over its
#                                     bottom half). Every other item gets a
#                                     UIButton at (220,50,94,72): btn_i_have_it
#                                     when the key is owned or FF_KEY_EVERYTHING
#                                     is set (no action), else btn_get_it ->
#                                     purchaseItem:.
#   buttonPressed: (grid)    0xB4680  forwards gridItemViewClicked: -- the store
#                                     does not implement it, so tapping a
#                                     banner does nothing.
#   back:                    0x28788  button_press, pop.
#   restorePurchases:        0x287F8  button_press, StoreKit restore.
#
# The port ships everything unlocked, so every banner carries "I HAVE IT" and
# nothing is purchasable. PORT CHOICE: Restore shows the unlock notice instead
# of talking to StoreKit.
#
# Scrolling: the grid is the nib's UIClassSwapper ->
# ScrollableGridView, i.e. a UIScrollView configured by initWithCoder:
# (0xB3630): alwaysBounceVertical YES, no paging, the default (Normal, 0.998)
# deceleration, bounces and the vertical indicator at their UIKit defaults
# (the raw nib object 16 carries neither UIBounceEnabled nor
# UIShows*ScrollIndicator, so both are YES). It runs on
# ScrollableGridView.PanScroller -- core/UIScrollSim.gd's UIKit physics plus
# the scroll indicator -- instead of the old slop / clamp / decay. The rows
# keep this screen's own layout code (they are display-only: the store does
# not implement gridItemViewClicked:, and the "I HAVE IT" badge button has
# no action).

extends "res://core/Screen.gd"

const ScrollableGridView := preload("res://core/ScrollableGridView.gd")

const GRID_SIZE := Vector2(320, 386)            # nib frame of the grid view
const ROW_HEIGHT := 125.0                        # store_item_panel.png height
const OVERLAY_RECT := Rect2(220, 50, 94, 72)     # 0x28C5C initWithFrame:
const OVERLAY_ART := "btn_i_have_it.png"
const SPACER_KEY := "SPACER"
const CRATE_PREFIX := "FF_KEY_CRATE_GAME"

var _content: Node2D
var _max_offset := 0.0
var _offset := 0.0
## The grid's UIScrollView (vertical).
var _pan: ScrollableGridView.PanScroller


func on_enter() -> void:
	_build_grid()
	# PORT CHOICE (no purchases in this port): Restore
	# Purchases can only ever say "already unlocked" -- hidden.
	var restore := get_node_or_null("btn_restore")
	if restore is CanvasItem:
		(restore as CanvasItem).visible = false


## Opted in. Nothing in the original pushes over the
## store (its only exits are back: and StoreKit's own sheets), so this never
## comes back from under another screen in practice. If it did, the only
## appearance work is viewWillAppear: (0x28490) / viewWillDisappear: (0x284EC)
## setting and clearing IAPlistManager's storeDelegate -- no port
## counterpart. The banners and the scroll position are viewDidLoad state and
## stay as they are.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	if _pan != null:
		_pan.cancel()


# -- viewDidLoad / loadItems --------------------------------------------

## The import cache's data/IAP.json (Assets).
const IAP_JSON := "IAP"


func _items() -> Array:
	var entries: Array = []
	if not Assets.has_json(IAP_JSON):
		push_error("StoreViewController: cannot open data/%s.json" % IAP_JSON)
		return entries
	var table: Variant = Assets.json(IAP_JSON)
	if not (table is Dictionary):
		push_error("StoreViewController: data/%s.json is not a dictionary" % IAP_JSON)
		return entries
	for key in (table as Dictionary).keys():
		var entry: Variant = table[key]
		if entry is Dictionary:
			entries.append(entry)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("Index", 0)) < int(b.get("Index", 0)))
	var out: Array = []
	for entry: Dictionary in entries:
		var iap_key := str(entry.get("IAPKey", ""))
		if iap_key.contains(CRATE_PREFIX):
			continue
		out.append(entry)
	return out


func _build_grid() -> void:
	var grid := outlet("scrollableGridView")
	if grid == null or grid == self:
		return

	# UIScrollView clips to its bounds; the nib frame is (0,94,320,386).
	var clip := Control.new()
	clip.name = "clip"
	clip.size = GRID_SIZE
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_child(clip)
	_content = Node2D.new()
	_content.name = "content"
	clip.add_child(_content)

	var y := 0.0
	var index := 0
	for entry: Dictionary in _items():
		var iap_key := str(entry.get("IAPKey", ""))
		var item := Node2D.new()
		item.name = "item_%d" % index
		item.position = Vector2(0, y)
		_content.add_child(item)

		# GridItemView: background image (transparent panel) then the art.
		var panel := _sprite("store_item_panel.png", Vector2.ZERO)
		if panel != null:
			item.add_child(panel)
		var art_name := str(entry.get("Image", ""))
		var frame := Vector2(GRID_SIZE.x, ROW_HEIGHT)
		if iap_key == SPACER_KEY:
			frame.y *= 2.0
		var art := _sprite(art_name, Vector2.ZERO)
		if art != null:
			# UIButton foreground image: natural size, centred in the frame.
			art.position = (frame - art.texture.get_size()) * 0.5
			item.add_child(art)

		if iap_key != SPACER_KEY:
			var badge := _sprite(OVERLAY_ART, Vector2.ZERO)
			if badge != null:
				badge.position = OVERLAY_RECT.position \
					+ (OVERLAY_RECT.size - badge.texture.get_size()) * 0.5
				item.add_child(badge)

		y += ROW_HEIGHT
		index += 1

	_max_offset = maxf(0.0, y - GRID_SIZE.y)
	# loadItems: contentSize.height = last row y + 125 + YSpacing (0).
	_pan = ScrollableGridView.PanScroller.new(true)
	_pan.axis.always_bounce = true
	_pan.configure(GRID_SIZE.y, y)
	_pan.add_indicator(grid, Rect2(Vector2.ZERO, GRID_SIZE))
	_set_offset(0.0)


func _sprite(image_name: String, pos: Vector2) -> Sprite2D:
	if not Assets.has_image(image_name):
		return null
	var s := Sprite2D.new()
	s.texture = Assets.texture(image_name)
	s.centered = false
	s.position = pos
	return s


# -- scrolling ------------------------------------------------------------

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
				if _grid_rect().has_point(mb.position):
					_pan.press(mb.position - _grid_rect().position)
			elif _pan.tracking:
				_pan.release(mb.position - _grid_rect().position)
				_apply_offset()
	elif event is InputEventMouseMotion and _pan.tracking:
		if _pan.move((event as InputEventMouseMotion).position - _grid_rect().position):
			_apply_offset()


func _grid_rect() -> Rect2:
	var grid := outlet("scrollableGridView")
	var origin: Vector2 = grid.get("position") if grid != null and grid != self else Vector2.ZERO
	return Rect2(origin, GRID_SIZE)


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


# -- buttons --------------------------------------------------------------

func _on_back() -> void:
	Audio.play("button_press")
	Nav.back()


func _on_restorePurchases() -> void:
	show_unlock_notice()
