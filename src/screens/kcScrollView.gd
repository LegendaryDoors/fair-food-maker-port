# One UIScrollView (iOS 6.1.3) for the pickers of the ca / ccb / cff / kc /
# ip screens.
#
# Not a screen: no scene is named kcScrollView, so Nav never attaches it. It
# lives under the kc prefix only because that is where the shared screen
# helpers already were (like kcKit.gd, which the ip screens borrow too);
# nothing in it is Kettle-Corn specific. A candidate for core/.
#
# It wraps core/UIScrollSim.gd's ScrollAxis (the drag / release /
# decelerate / bounce / delegate-target arithmetic read out of iOS 6.1.3's
# UIKit) around the screen's own content
# node, and adds what a screen needs around it:
#   * the hit region (the scroll view's MODEL frame -- UIKit hit-tests the
#     model layer tree, so a picker sliding in already takes touches at its
#     destination);
#   * taps: a touch that goes up before the pan recognizer began (10 pt
#     hysteresis) is delivered to the content -- delaysContentTouches /
#     canCancelContentTouches YES, the nib defaults -- as `tapped`;
#   * the optional scroll indicator (core/UIScrollIndicator.gd);
#   * the two programmatic scrolls the game uses (below).
#
# setContentOffset:animated:YES (the stick pickers' mystery purchase), read
# in iOS 6.1.3's UIKit (the armv7 dyld shared cache):
#   -[UIScrollView setContentOffset:animated:] 0x32FA2ADC calls
#   _setContentOffset:animated:animationCurve: with curve 0, which builds a
#   UIScrollAnimation (0x32FA2B2C) of duration _contentOffsetAnimationDuration
#   (0.3 s); -[UIAnimation progressForFraction:] 0x3309F518 curve 0 is
#   sin(f * pi/2)^2, and -[UIScrollAnimation setProgress:] 0x3313AB28 sets
#   floor(start + (end - start) * p) through -setContentOffset: every frame
#   (so scrollViewDidScroll: fires on every step). Nothing returns when the
#   target equals the current offset.
#
# setContentOffset: inside a +beginAnimations: block (every picker's
# "Animate_To_First_Item" entrance): the MODEL offset changes at once --
# scrollViewDidScroll: sees it, hit tests use it -- and only the drawing
# animates. -[UIView(CALayerDelegate) actionForLayer:forKey:] 0x32F34998
# makes that implicit CABasicAnimation with setFromValue: only, so it runs
# from the old value toward the layer's CURRENT model value: a drag during
# the glide moves the end point along. And those old-style blocks do not
# block touches: -[UIViewAnimationState _allowsUserInteraction] 0x3307B220
# is YES unless the delegate answers _allowsUserInteraction NO (only the
# block API's UIViewAnimationBlockDelegate does).
#
# INFERRED (not read): a touch that lands while the view is decelerating or
# running an animated scroll only stops it -- no tap reaches the cell
# (UIKit's familiar behaviour; ScrollAxis already models the zero-hysteresis
# grab). Releasing such a catch without dragging lets a rubber-banded view
# spring back (ScrollAxis.touch_ended returns early when no drag began, which
# would leave it stranded). The indicator is
# drawn above the content.
#
#     const ScrollView := preload("res://screens/kcScrollView.gd")
#     _sv = ScrollView.new()
#     add_child(_sv)
#     _sv.configure(true, Rect2(-20, 43, 320, 366), 1100.0)
#     _sv.content = _content
#     _sv.add_indicator(_panel, Rect2(Vector2.ZERO, _panel.size))
#     _sv.tapped.connect(_on_cell_tapped)
#     ... _unhandled_input: if _sv.handle_input(event): set_input_as_handled()

extends Node

const UIScrollSim := preload("res://core/UIScrollSim.gd")
const UIScrollIndicator := preload("res://core/UIScrollIndicator.gd")

## scrollViewDidScroll: -- the model contentOffset along the axis changed.
signal did_scroll(offset: float)
## A touch went up before the pan began: UIKit hands it to the cell under
## the finger. Both points are in CONTENT coordinates (the model offset
## applied); a UIButton fires touchUpInside if `release` is still within
## its bounds grown by 70 pt (UIControl's tracking slop).
signal tapped(press: Vector2, release: Vector2)

## UIControl keeps a touch "inside" within 70 pt of its bounds.
const TAP_SLOP := 70.0

var vertical := true
## The scroll view's frame (MODEL value) in the screen's coordinates.
var frame := Rect2(0, 0, 320, 480)
## The node drawn at -contentOffset (the scroll view's subviews).
var content: Node2D:
	set(v):
		content = v
		_apply_visual()
		raise_indicator()
## Where `content` sits at offset 0, in its parent's coordinates.
var content_origin := Vector2.ZERO
var axis: RefCounted
var indicator: Node2D

var _content_len := 0.0
var _tracking := false
var _caught := false
var _press := Vector2.ZERO
var _press_offset := 0.0
var _last_emitted := NAN
# setContentOffset:animated:YES (UIScrollAnimation).
var _anim_active := false
var _anim_t := 0.0
var _anim_from := 0.0
var _anim_to := 0.0
# setContentOffset: in a UIView animation block (drawing only).
var _block_active := false
var _block_t := 0.0
var _block_duration := 0.0
var _block_from := 0.0
var _block_curve := 0


func _init() -> void:
	axis = UIScrollSim.ScrollAxis.new()
	axis.will_begin_dragging.connect(_on_will_begin_dragging)
	axis.did_end_dragging.connect(_on_did_end_dragging)
	axis.did_end_decelerating.connect(_on_did_end_decelerating)


## One scrollable axis: `content_len` is contentSize along it; the frame's
## size along it is the bounds size.
func configure(is_vertical: bool, frame_rect: Rect2, content_len: float) -> void:
	vertical = is_vertical
	set_frame(frame_rect)
	set_content_length(content_len)


## setFrame: -- the bounds size along the axis is the scroll range.
func set_frame(frame_rect: Rect2) -> void:
	frame = frame_rect
	axis.range_ = frame.size.y if vertical else frame.size.x
	_update_limits()


## setContentSize: (the offset is left alone, as UIKit does).
func set_content_length(content_len: float) -> void:
	_content_len = content_len
	_update_limits()


func _update_limits() -> void:
	axis.min_offset = 0.0
	axis.max_offset = maxf(0.0, _content_len - axis.range_)
	_apply_visual()


## The scroll indicator (showsVertical/HorizontalScrollIndicator YES): a
## child of `parent` -- the node the content is clipped by -- running along
## `track`, the scroll view's bounds in that node's coordinates.
func add_indicator(parent: Node, track: Rect2) -> void:
	indicator = UIScrollIndicator.new()
	indicator.vertical = vertical
	indicator.track = track
	parent.add_child(indicator)
	_apply_visual()


func raise_indicator() -> void:
	if indicator != null and indicator.get_parent() != null:
		indicator.get_parent().move_child(indicator, -1)


## The model contentOffset along the axis.
func get_offset() -> float:
	return axis.offset


## What is drawn (differs from the model during a UIView-block glide).
func shown_offset() -> float:
	if _block_active and _block_duration > 0.0:
		var p := UIScrollSim.curve(_block_t / _block_duration, _block_curve)
		return _block_from + (axis.offset - _block_from) * p
	return axis.offset


func is_moving() -> bool:
	return axis.decelerating or _anim_active or _block_active or axis.dragging


## setContentOffset: (not animated).
func set_offset(v: float) -> void:
	_anim_active = false
	axis.offset = v
	_apply()


## setContentOffset:animated:YES (header): 0.3 s, sin^2, whole points.
func set_offset_animated(v: float) -> void:
	if v == axis.offset:
		return
	axis.decelerating = false
	_anim_from = axis.offset
	_anim_to = v
	_anim_t = 0.0
	_anim_active = true


## setContentOffset:`to` inside +beginAnimations: with `duration` and
## UIView curve `curve` (UIScrollSim.AnimCurve; the default 0 is the block
## default, EaseInOut). The drawing glides from the offset shown now.
func set_offset_in_animation_block(to: float, duration: float, curve: int = 0) -> void:
	_block_from = shown_offset()
	_block_t = 0.0
	_block_duration = duration
	_block_curve = curve
	_block_active = duration > 0.0
	set_offset(to)


## A view the screen covers (keep-state push) leaves the tree and stops
## processing; UIKit would have finished the motion meanwhile. Land it.
func settle() -> void:
	cancel_tracking()
	if _block_active:
		_block_active = false
	if _anim_active:
		_anim_active = false
		axis.offset = _anim_to
	var guard := 0
	while axis.decelerating and guard < 3600:
		axis.step(1.0 / 60.0)
		guard += 1
	_apply()
	if indicator != null:
		indicator.modulate.a = 0.0


## End a touch without a tap (the screen locks input, or leaves).
func cancel_tracking() -> void:
	if not _tracking:
		return
	_tracking = false
	axis.touch_ended(_now())
	_spring_back_if_stranded()
	_apply()


## Feed the screen's input events. Returns true when this scroll view took
## the event (the caller marks it handled).
func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			if _tracking or not frame.has_point(mb.position):
				return false
			_tracking = true
			_caught = axis.decelerating or _anim_active
			_anim_active = false
			_press = mb.position
			_press_offset = axis.offset
			axis.touch_began(_along(mb.position), _now())
			return true
		if not _tracking:
			return false
		_tracking = false
		var dragged: bool = axis.dragging
		axis.touch_ended(_now())
		if not dragged:
			_spring_back_if_stranded()
			if indicator != null and not axis.decelerating:
				indicator.end()
			if not _caught:
				tapped.emit(_to_content(_press, _press_offset),
					_to_content(mb.position, axis.offset))
		_apply()
		return true
	if event is InputEventMouseMotion and _tracking:
		axis.touch_moved(_along((event as InputEventMouseMotion).position), _now())
		_apply()
		return true
	return false


## For a tap handler: was the release still "inside" `cell` (content
## coordinates) by UIControl's rule?
static func release_inside(cell: Rect2, release: Vector2) -> bool:
	return cell.grow(TAP_SLOP).has_point(release)


func _process(delta: float) -> void:
	var before: float = axis.offset
	var redraw := false
	if _block_active:
		_block_t += delta
		if _block_t >= _block_duration:
			_block_active = false
		redraw = true
	if _anim_active:
		_anim_t += delta
		var f := minf(_anim_t / UIScrollSim.CONTENT_OFFSET_ANIMATION_DURATION, 1.0)
		var s := sin(f * PI * 0.5)
		axis.offset = floorf(_anim_from + (_anim_to - _anim_from) * s * s)
		if f >= 1.0:
			_anim_active = false
	if axis.decelerating:
		axis.step(delta)
	if redraw or axis.offset != before:
		_apply()


func _apply() -> void:
	_apply_visual()
	if axis.offset != _last_emitted:
		_last_emitted = axis.offset
		did_scroll.emit(axis.offset)


func _apply_visual() -> void:
	if content != null and is_instance_valid(content):
		var s := shown_offset()
		content.position = content_origin - (Vector2(0, s) if vertical else Vector2(s, 0))
	if indicator != null and is_instance_valid(indicator):
		indicator.update(axis.offset, axis.min_offset, axis.max_offset, axis.range_)


func _along(p: Vector2) -> float:
	return p.y if vertical else p.x


func _to_content(p: Vector2, offset: float) -> Vector2:
	var local := p - frame.position
	return local + (Vector2(0, offset) if vertical else Vector2(offset, 0))


static func _now() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0


## Caught while bouncing, released without a drag: ScrollAxis would leave
## the offset past the edge; let the bounce run it back (INFERRED, header).
func _spring_back_if_stranded() -> void:
	var hi: float = maxf(axis.max_offset, axis.min_offset)
	if axis.decelerating or (axis.offset >= axis.min_offset and axis.offset <= hi):
		return
	axis.velocity = 0.0
	axis.set("_last_offset", axis.offset)
	axis.decelerating = true


func _on_will_begin_dragging() -> void:
	if indicator != null:
		indicator.begin()


func _on_did_end_dragging(will_decelerate: bool) -> void:
	if indicator != null and not will_decelerate:
		indicator.end()


func _on_did_end_decelerating() -> void:
	if indicator != null:
		indicator.end()
