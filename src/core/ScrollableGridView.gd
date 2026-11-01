# ScrollableGridView + GridItemView + GridItem, ported (the shelf grid of the
# prize, trophy-case and freezer screens).
#
# From the original binary (floats decoded):
#   ScrollableGridView (UIScrollView subclass)
#     initWithCoder:        0xB3630  scrollEnabled, directionalLock, no paging,
#                                    alwaysBounceVertical; location = frame
#                                    origin, hiddenLocation = origin - (0,100).
#     loadItems:            0xB3928  removes old item/separator views, then
#                                    lays items out left to right from
#                                    (XOffset, YOffset), cell = gridBackground
#                                    size, pitch = size + X/YSpacing. Before
#                                    the first item of every new row a
#                                    separator goes at (separatorXOffset,
#                                    rowY + separatorYOffset) and the row
#                                    advances by separator height +
#                                    separatorYOffset more. addLastSeparator
#                                    adds one more after the last row the same
#                                    way. Then the delegate's
#                                    setOverlayViewsToGridViews: (if any),
#                                    contentSize.h = y + cellH + YSpacing, and
#                                    setGridViewImage. A nil/empty list stops
#                                    after the removal.
#     addSeparatorAtPoint:  0xB3FD0  UIImageView(separator) at its natural
#                                    size, no interaction.
#     unselectGrids         0xB40D4  every item: selected NO, highlighted NO.
#     showAnimated:/hideAnimated: 0xB41B0/0xB4458  contentOffset y -> 0; slide
#                                    hiddenLocation <-> location over 0.3s
#                                    (double 0x3FD3333333333333), curve 3 =
#                                    linear; un-animated just places + hides.
#     buttonPressed:        0xB4680  delegate gridItemViewClicked:, then if
#                                    keepSelected, selectGridItemView: after a
#                                    0 delay.
#     selectGridItemView:   0xB4714  every item: selected NO, normal bg =
#                                    gridBackground; the item: selected YES,
#                                    normal bg = selectedGridBackground.
#     setGridViewImage      0xB4840  every GridItemView without dontLoadImage
#                                    gets imageNamed:(imagePath) or
#                                    imageWithContentsOfFile:.
#   GridItemView (UIButton) initWithGridItem:setGridImage:gridBackground:
#                           0xC4A6C  frame = (0,0, gridBackground size);
#                                    background (normal) = gridBackground;
#                                    image = the item's imagePath unless
#                                    dontLoadImage. loadItems also sets the
#                                    highlighted background to
#                                    selectedGridBackground and targets
#                                    touchUpInside (64) at buttonPressed:.
#   GridItem                0xC4804  {imagePath, data, category, IAPKey}.
#
# The port: GridItem is a Dictionary {image_path, data, category, iap_key};
# GridItemView is the inner class below; the delegate is any Object with
# grid_item_view_clicked(view) / set_overlay_views_to_grid_views(views).
#
# INFERRED: UIButton image layout. A UIButton's imageView is the image's size
# clamped to the button per axis and centred; the screens that care set its
# contentMode to aspect-fit (PrizeViewController loadItems 0x114DC). The
# visible result is "natural size, scaled down to fit the cell if larger,
# centred", which is what GridItemView draws. Custom subviews (overlays) draw
# above the image, in the order they were added.
#
# NOT PORTED: UIButton's adjustsImageWhenHighlighted darkening of the image
# while a cell is held down (the cells are not TextureButtons, so
# core/UIKitButtons.gd does not reach them).
#
# SCROLLING: a real iOS 6 UIScrollView. The axis is
# core/UIScrollSim.gd's ScrollAxis (UIKit's own drag / rubber-band /
# deceleration / bounce arithmetic),
# configured as initWithCoder: / initWithFrame: (0xB3630 / 0xB37C0) set it:
# alwaysBounceVertical YES, alwaysBounceHorizontal NO, paging NO, the
# default decelerationRate (Normal, 0.998) and bounces (nib / init default
# YES). contentSize.width stays the frame width, so only the vertical axis
# ever scrolls (directionalLockEnabled has nothing to lock). The vertical
# scroll indicator is UIKit's default (on) -- no caller of this class turns
# it off; MakeViewController's own grid does (shows_vertical_scroll_indicator).
# The hand-rolled slop / clamp / velocity decay that stood in for all this
# is gone. PanScroller (below) is the glue the port's other scroll views use
# as well (StandSelect, Store, CoinStore, Make).

extends Node2D

const UIScrollSim := preload("res://core/UIScrollSim.gd")
const UIScrollIndicator := preload("res://core/UIScrollIndicator.gd")

## PORT CHOICE: the mouse wheel (no iOS counterpart) scrolls this far a notch.
const WHEEL_STEP := 40.0
## showAnimated:/hideAnimated: duration (0x3FD3333333333333) and the
## hiddenLocation offset from initWithCoder: (-100.0).
const SLIDE_SECONDS := 0.3
const HIDDEN_DY := -100.0

## UIControlState values used by the original.
const STATE_NORMAL := 0
const STATE_HIGHLIGHTED := 1
const STATE_SELECTED := 4


class GridItemView extends Node2D:
	var grid_item: Dictionary = {}
	var dont_load_image := false
	var user_interaction_enabled := true
	var selected := false:
		set(v):
			selected = v
			_refresh()
	var highlighted := false:
		set(v):
			highlighted = v
			_refresh()
	var size := Vector2.ZERO
	var _bg_by_state: Dictionary = {}
	var _image_by_state: Dictionary = {}
	var _bg: Sprite2D
	var _image: Sprite2D

	func _init() -> void:
		_bg = Sprite2D.new()
		_bg.centered = false
		add_child(_bg)
		_image = Sprite2D.new()
		_image.centered = true
		add_child(_image)

	func set_background_image_for_state(tex: Texture2D, state: int) -> void:
		_bg_by_state[state] = tex
		_refresh()

	func set_image_for_state(tex: Texture2D, state: int) -> void:
		_image_by_state[state] = tex
		_refresh()

	func image_for_state(state: int) -> Texture2D:
		return _image_by_state.get(state)

	## The button's imageView -- overlays are added after it, so above it.
	func image_view() -> Sprite2D:
		return _image

	func add_subview(node: Node) -> void:
		add_child(node)

	func contains_local(p: Vector2) -> bool:
		return Rect2(Vector2.ZERO, size).has_point(p)

	## UIButton state lookup: the current state's image if one was set, else
	## the normal one.
	func _for_state(table: Dictionary) -> Texture2D:
		if highlighted and table.get(STATE_HIGHLIGHTED) != null:
			return table[STATE_HIGHLIGHTED]
		if selected and table.get(STATE_SELECTED) != null:
			return table[STATE_SELECTED]
		return table.get(STATE_NORMAL)

	func _refresh() -> void:
		if _bg == null:
			return
		_bg.texture = _for_state(_bg_by_state)
		var tex := _for_state(_image_by_state)
		_image.texture = tex
		_image.position = size * 0.5
		_image.scale = Vector2.ONE
		if tex != null:
			var ts := tex.get_size()
			if ts.x > 0 and ts.y > 0:
				var f := minf(1.0, minf(size.x / ts.x, size.y / ts.y))
				_image.scale = Vector2(f, f)


var delegate: Object = null
var grid_background: Texture2D = null
var selected_grid_background: Texture2D = null
var separator: Texture2D = null
var add_last_separator := false
var item_views: Array = []
var separator_views: Array = []
var keep_selected := false
var number_of_items_per_row := 0
var x_offset := 0.0
var y_offset := 0.0
var x_spacing := 0.0
var y_spacing := 0.0
var separator_x_offset := 0.0
var separator_y_offset := 0.0
## Relative to the nib frame's origin (the outlet node's position).
var location := Vector2.ZERO
var hidden_location := Vector2(0, HIDDEN_DY)
var frame_size := Vector2.ZERO
var content_size := Vector2.ZERO
var content_offset := 0.0
var is_animating := false
var should_hide := false
## GridItem image_path -> Texture2D. Defaults to imageNamed: (the bundled art)
## falling back to imageWithContentsOfFile: (a file path).
var image_loader: Callable

## showsVerticalScrollIndicator (UIScrollView default YES).
var shows_vertical_scroll_indicator := true:
	set(v):
		shows_vertical_scroll_indicator = v
		if _pan != null and _pan.indicator != null:
			_pan.indicator.visible = v

var _clip: Control
var _content: Node2D
## The scroll view itself (UIScrollSim.ScrollAxis + indicator), vertical.
var _pan: PanScroller
## The cell the touch went down on, while the scroll view may still hand
## the touch to it (delaysContentTouches) -- cleared when the pan claims it.
var _press_view: GridItemView = null
var _press_local := Vector2.ZERO


## initWithCoder: for a nib-placed grid: `frame` is the UIClassSwapper's
## frame from the nib; this node is added under the outlet node (which sits
## at the frame origin).
func setup(frame: Rect2) -> void:
	frame_size = frame.size
	content_size = frame.size
	location = Vector2.ZERO
	hidden_location = location + Vector2(0, HIDDEN_DY)
	position = location
	_clip = Control.new()
	_clip.name = "clip"
	_clip.size = frame_size
	_clip.clip_contents = true    # UIScrollView clipsToBounds
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clip)
	_content = Node2D.new()
	_content.name = "content"
	_clip.add_child(_content)
	_pan = PanScroller.new(true)
	_pan.axis.always_bounce = true          # setAlwaysBounceVertical:YES
	_pan.configure(frame_size.y, content_size.y)
	# Above the clipped content, pinned to the frame (UIKit adds the
	# indicator as a subview it keeps at the visible edge).
	_pan.add_indicator(self, Rect2(Vector2.ZERO, frame_size))
	_pan.indicator.visible = shows_vertical_scroll_indicator


static func default_image_loader(path: String) -> Texture2D:
	if path == "":
		return null
	if Assets.has_image(path):
		return Assets.texture(path)
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null:
			return ImageTexture.create_from_image(img)
	return null


func _load_image(path: String) -> Texture2D:
	if image_loader.is_valid():
		return image_loader.call(path)
	return default_image_loader(path)


# -- loadItems: (0xB3928) ---------------------------------------------------

func load_items(items: Variant) -> void:
	for v in item_views:
		(v as Node).queue_free()
	item_views.clear()
	for s in separator_views:
		(s as Node).queue_free()
	separator_views.clear()
	_press_view = null
	if items == null or not (items is Array) or (items as Array).is_empty():
		return

	var cell := grid_background.get_size() if grid_background != null else Vector2.ZERO
	var x := x_offset
	var y := y_offset
	var in_row := 0
	for gi: Dictionary in items:
		var view := GridItemView.new()
		_init_grid_item_view(view, gi, true, grid_background)
		view.set_background_image_for_state(selected_grid_background, STATE_HIGHLIGHTED)
		_content.add_child(view)
		item_views.append(view)
		if in_row >= number_of_items_per_row:
			x = x_offset
			y += cell.y + y_spacing
			var sep := add_separator_at_point(Vector2(x - x_offset + separator_x_offset,
				y + separator_y_offset))
			if sep != null:
				y += sep.texture.get_size().y + separator_y_offset
			in_row = 0
		view.position = Vector2(x, y)
		x += cell.x + x_spacing
		in_row += 1

	if add_last_separator:
		var sep := add_separator_at_point(Vector2(x_offset - x_offset + separator_x_offset,
			y + cell.y + y_spacing + separator_y_offset))
		if sep != null:
			y += sep.texture.get_size().y + separator_y_offset

	if delegate != null and delegate.has_method("set_overlay_views_to_grid_views"):
		delegate.call("set_overlay_views_to_grid_views", item_views)
	content_size = Vector2(content_size.x, y + cell.y + y_spacing)
	# setContentSize: leaves contentOffset where it is (UIKit never clamps
	# it there; a shrunk grid springs back on the next touch).
	if _pan != null:
		_pan.configure(frame_size.y, content_size.y)
	_apply_offset()
	set_grid_view_image()


## -[GridItemView initWithGridItem:setGridImage:gridBackground:] (0xC4A6C).
func _init_grid_item_view(view: GridItemView, gi: Dictionary, set_grid_image: bool,
		bg: Texture2D) -> void:
	view.size = bg.get_size() if bg != null else Vector2.ZERO
	view.set_background_image_for_state(bg, STATE_NORMAL)
	if set_grid_image and not view.dont_load_image:
		view.set_image_for_state(_load_image(str(gi.get("image_path", ""))), STATE_NORMAL)
	view.grid_item = gi


func add_separator_at_point(p: Vector2) -> Sprite2D:
	if separator == null:
		return null
	var s := Sprite2D.new()
	s.texture = separator
	s.centered = false
	s.position = p
	_content.add_child(s)
	separator_views.append(s)
	return s


func set_grid_view_image() -> void:
	for v: GridItemView in item_views:
		if not v.dont_load_image:
			v.set_image_for_state(_load_image(str(v.grid_item.get("image_path", ""))),
				STATE_NORMAL)


func unselect_grids() -> void:
	for v: GridItemView in item_views:
		v.selected = false
		v.highlighted = false


func select_grid_item_view(view: GridItemView) -> void:
	for v: GridItemView in item_views:
		v.selected = false
		v.set_background_image_for_state(grid_background, STATE_NORMAL)
	if view == null or not is_instance_valid(view):
		return
	view.selected = true
	if selected_grid_background != null:
		view.set_background_image_for_state(selected_grid_background, STATE_NORMAL)


func show_animated(animated: bool) -> void:
	if is_animating or item_views.is_empty():
		return
	# setContentOffset:(contentOffset.x, 0) animated:NO.
	_set_offset(0.0)
	if animated:
		visible = true
		should_hide = false
		is_animating = true
		position = hidden_location
		var tw := create_tween()
		tw.tween_property(self, "position", location, SLIDE_SECONDS)
		tw.finished.connect(_animation_did_stop)
	else:
		position = location
		visible = true


func hide_animated(animated: bool) -> void:
	if is_animating:
		return
	if animated:
		should_hide = true
		is_animating = true
		position = location
		var tw := create_tween()
		tw.tween_property(self, "position", hidden_location, SLIDE_SECONDS)
		tw.finished.connect(_animation_did_stop)
	else:
		position = hidden_location
		visible = false


func _animation_did_stop() -> void:
	visible = not should_hide
	is_animating = false


## buttonPressed: (0xB4680).
func button_pressed(view: GridItemView) -> void:
	if delegate != null and delegate.has_method("grid_item_view_clicked"):
		delegate.call("grid_item_view_clicked", view)
	if keep_selected:
		select_grid_item_view.call_deferred(view)




# -- UIScrollView ------------------------------------------------------------

func max_offset() -> float:
	return maxf(0.0, content_size.y - frame_size.y)


## setContentOffset: (not animated): any drag / deceleration stops there.
func _set_offset(y: float) -> void:
	if _pan != null:
		_pan.set_offset(y)
	else:
		content_offset = y
	_apply_offset()


## The offset the scroll view is at -> the content node (and the indicator).
func _apply_offset() -> void:
	if _pan != null:
		content_offset = _pan.offset()
	if _content != null:
		_content.position.y = -content_offset


func scroll_to(y: float) -> void:
	_set_offset(clampf(y, 0.0, max_offset()))


## The item under a point in this view's own coordinates (frame space).
func item_view_at(local: Vector2) -> GridItemView:
	if not Rect2(Vector2.ZERO, frame_size).has_point(local):
		return null
	var c := local + Vector2(0, content_offset)
	for i in range(item_views.size() - 1, -1, -1):
		var v: GridItemView = item_views[i]
		if v.contains_local(c - v.position):
			return v
	return null


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not is_visible_in_tree() or _pan == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var local := to_local(mb.position)
		var inside := Rect2(Vector2.ZERO, frame_size).has_point(local)
		if mb.pressed and inside and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			scroll_to(content_offset - WHEEL_STEP)
		elif mb.pressed and inside and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scroll_to(content_offset + WHEEL_STEP)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed and inside:
				_begin_press(local)
				get_viewport().set_input_as_handled()
			elif not mb.pressed and _pan.tracking:
				_end_press(local)
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _pan.tracking:
		_track_drag(to_local((event as InputEventMouseMotion).position))


func _begin_press(local: Vector2) -> void:
	_pan.press(local)
	_press_local = local
	_press_view = null
	# A touch that catches a moving (or out-of-bounds) scroll view never
	# reaches a cell (PanScroller.caught).
	if not _pan.caught:
		var v := item_view_at(local)
		if v != null and v.user_interaction_enabled:
			_press_view = v
	_apply_offset()


func _track_drag(local: Vector2) -> void:
	if _pan.move(local):
		_apply_offset()
	if _pan.dragging() and _press_view != null:
		# The pan claimed the touch: the cell's tracking is cancelled
		# (canCancelContentTouches YES).
		if is_instance_valid(_press_view):
			_press_view.highlighted = false
		_press_view = null


func _end_press(local: Vector2) -> void:
	var view := _press_view
	_press_view = null
	var held := _pan.held_seconds()
	var tap := _pan.release(local)
	_apply_offset()
	if not tap or view == null or not is_instance_valid(view):
		return
	# touchUpInside: released within UIControl's 70 pt of the cell's frame
	# (_UIControlMostlyInsideEdgeInsets). Only a
	# horizontal wander can get that far without the vertical pan starting.
	var r := Rect2(view.position - Vector2(0, content_offset), view.size)
	if not r.grow(PanScroller.CONTROL_SLOP).has_point(local):
		view.highlighted = false
		return
	# A tap shorter than delaysContentTouches' 0.15 s reaches the cell at
	# release; either way UIControl keeps it highlighted at least 0.12 s.
	var lit_for := maxf(0.0, held - PanScroller.CONTENT_TOUCH_DELAY)
	view.highlighted = true
	var rest := PanScroller.MIN_HIGHLIGHT - lit_for
	if rest > 0.0 and view.is_inside_tree():
		# A tween owned by the cell, not a SceneTreeTimer: a tap that rebuilds
		# the grid (freezer delete / eat, store reload) frees the cell first,
		# and a timer lambda then fired on the freed cell ("Lambda capture at
		# index 0 was freed"). The tween dies with it.
		var tw := view.create_tween()
		tw.tween_interval(rest)
		tw.tween_callback(view.set.bind("highlighted", false))
	else:
		view.highlighted = false
	button_pressed(view)


func _process(delta: float) -> void:
	if _pan == null:
		return
	if _pan.step(delta):
		_apply_offset()
	# delaysContentTouches: a resting touch reaches the cell after 0.15 s.
	if _press_view != null and is_instance_valid(_press_view) \
			and not _press_view.highlighted and _pan.content_touch_due():
		_press_view.highlighted = true


# -- PanScroller -------------------------------------------------------------

## One axis of an iOS 6 UIScrollView fed by the port's mouse events: the
## physics are UIScrollSim.ScrollAxis's (read from UIKit); this adds
## what a screen needs around them, all read from the same UIKit build
## (iOS 6.1.3, dyld_shared_cache_armv7, addresses in that cache):
##
##  * which touches reach the content -- -[UIScrollView touchesBegan:withEvent:]
##    (0x33075C04) hands a touch to a content view only when
##    -_beginTrackingWithEvent: (0x3304B928) returns NO and the "scrolling"
##    flag (0x10000) is clear. _beginTrackingWithEvent: returns YES when the
##    offset is outside the content (a bounce in progress) and clears the
##    flag only when the scroll velocity is zero, so a touch that catches a
##    moving or bouncing view only stops it (`caught`); cells never see it.
##  * delaysContentTouches: the content touch is deferred by
##    -_touchDelayForScrollDetection (0x3304DCE0) = 0.15 s, and cancelled if
##    the pan starts first (canCancelContentTouches, default YES).
##  * the indicator: -_adjustScrollerIndicators:alwaysShowingThem:
##    (0x32FA08F0) shows an axis's indicator only while bounds / content is
##    at most 0.99 -- never for content that fits, alwaysBounce or not.
##
## Positions are in any frame fixed to the scroll view (only the axis
## coordinate is used); time is the engine clock, as UIKit uses the touch
## timestamps.
class PanScroller extends RefCounted:
	const SimScript := preload("res://core/UIScrollSim.gd")
	const IndicatorScript := preload("res://core/UIScrollIndicator.gd")
	## _touchDelayForScrollDetection (0x3304DCE0): double 0x3FC3333333333333.
	const CONTENT_TOUCH_DELAY := 0.15
	## UIControl: a tap stays highlighted at least 0.12 s; touchUpInside
	## within 70 pt of the frame.
	const MIN_HIGHLIGHT := 0.12
	const CONTROL_SLOP := 70.0
	## _adjustScrollerIndicators:alwaysShowingThem: (0x32FA08F0).
	const INDICATOR_MAX_RATIO := 0.99

	## UIScrollSim.ScrollAxis.
	var axis
	var vertical := true
	var indicator: Node2D = null
	## A touch is down on the scroll view.
	var tracking := false
	## That touch caught the view moving or outside its content: it only
	## stops it, no content (button, cell) gets it.
	var caught := false
	var _press_usec := 0

	func _init(p_vertical: bool = true) -> void:
		vertical = p_vertical
		axis = SimScript.ScrollAxis.new()
		axis.will_begin_dragging.connect(_on_will_begin_dragging)
		axis.did_end_dragging.connect(_on_did_end_dragging)
		axis.did_end_decelerating.connect(_on_did_end_decelerating)

	## The scroll view's bounds length and contentSize along this axis.
	func configure(view_len: float, content_len: float) -> void:
		axis.range_ = view_len
		axis.min_offset = 0.0
		axis.max_offset = maxf(0.0, content_len - view_len)
		_update_indicator()

	## The UIScrollIndicator, a child of `parent`, for a scroll view whose
	## frame is `track` in `parent`'s coordinates.
	func add_indicator(parent: Node, track: Rect2, style: int = 0) -> void:
		indicator = IndicatorScript.new()
		indicator.set("vertical", vertical)
		indicator.set("style", style)
		indicator.set("track", track)
		indicator.name = "UIScrollIndicator"
		parent.add_child(indicator)
		_update_indicator()

	func offset() -> float:
		return float(axis.offset)

	func dragging() -> bool:
		return bool(axis.dragging)

	func moving() -> bool:
		return bool(axis.decelerating)

	func _now() -> float:
		return float(Time.get_ticks_usec()) / 1000000.0

	func _along(p: Vector2) -> float:
		return p.y if vertical else p.x

	func _outside() -> bool:
		var o := float(axis.offset)
		return o < float(axis.min_offset) \
			or o > maxf(float(axis.max_offset), float(axis.min_offset))

	func press(p: Vector2) -> void:
		caught = moving() or _outside()
		tracking = true
		_press_usec = Time.get_ticks_usec()
		axis.touch_began(_along(p), _now())

	## Returns true when the offset changed.
	func move(p: Vector2) -> bool:
		if not tracking:
			return false
		var before := offset()
		axis.touch_moved(_along(p), _now())
		if offset() != before:
			_update_indicator()
			return true
		return false

	## The touch lifted. Returns true when it was a tap the content gets
	## (no pan, nothing caught).
	func release(_p: Vector2) -> bool:
		if not tracking:
			return false
		tracking = false
		var was_dragging := dragging()
		axis.touch_ended(_now())
		if not was_dragging and not moving() and _outside():
			# INFERRED (UIKit's touchesEnded: path not read): a touch that
			# stopped a bounce, released without dragging, lets the view
			# spring back -- a scroll view never rests outside its content.
			_spring_back()
		elif caught and not was_dragging and not moving() and indicator != null:
			indicator.call("end")
		return not was_dragging and not caught

	func held_seconds() -> float:
		return float(Time.get_ticks_usec() - _press_usec) / 1000000.0

	## delaysContentTouches: a touch resting on the content for 0.15 s with
	## no pan reaches it now.
	func content_touch_due() -> bool:
		return tracking and not caught and not dragging() \
			and held_seconds() >= CONTENT_TOUCH_DELAY

	## Advance by `delta` s. Returns true when the offset changed.
	func step(delta: float) -> bool:
		var before := offset()
		axis.step(delta)
		if offset() != before:
			_update_indicator()
			return true
		return false

	## setContentOffset: (not animated): stops any drag or deceleration.
	func set_offset(o: float) -> void:
		cancel()
		axis.offset = o
		axis.velocity = 0.0
		_update_indicator()

	## Forget the touch and any motion (a re-appearing screen).
	func cancel() -> void:
		tracking = false
		caught = false
		axis.tracking = false
		axis.dragging = false
		axis.decelerating = false
		axis.velocity = 0.0

	func _spring_back() -> void:
		axis.velocity = 0.0
		axis.set("_last_offset", axis.offset)
		axis.decelerating = true

	func _indicator_wanted() -> bool:
		var content := float(axis.range_) + float(axis.max_offset) - float(axis.min_offset)
		return content > 0.0 and float(axis.range_) / content <= INDICATOR_MAX_RATIO

	func _update_indicator() -> void:
		if indicator != null and is_instance_valid(indicator):
			indicator.call("update", offset(), float(axis.min_offset),
				float(axis.max_offset), float(axis.range_))

	func _on_will_begin_dragging() -> void:
		if indicator != null and is_instance_valid(indicator) and _indicator_wanted():
			_update_indicator()
			indicator.call("begin")

	func _on_did_end_dragging(will_decelerate: bool) -> void:
		if not will_decelerate and indicator != null and is_instance_valid(indicator):
			indicator.call("end")

	func _on_did_end_decelerating() -> void:
		if indicator != null and is_instance_valid(indicator):
			indicator.call("end")
