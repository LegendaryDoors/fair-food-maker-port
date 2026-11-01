# Port of DraggableIV, the substrate under roughly half the game's steps.
#
# The original held a delegate, an origCenter, a touchOffset, a snapTime and
# per-axis movement locks. Dragging moved the view; releasing either left it
# where it was or tweened it back to origCenter. Screens detected success by
# testing the dragged centre against a rect authored in the nib
# (msScoopViewController's blenderDetectionRect is the canonical case).
#
# Signals mirror the original's delegate callbacks so screen scripts read
# roughly like the Objective-C did.

extends Sprite2D

signal drag_started
signal drag_moved(pos: Vector2)
signal drag_ended(pos: Vector2, on_target: bool)
## Emitted only when released with the centre inside `drop_target`.
signal dropped_on_target(pos: Vector2)

## Return to the starting position when released off-target.
##
## Both defaults are the original's, not the port's earlier guesses. DraggableIV
## initialises snapTime to 0.0 in both of its inits (0x4638C, 0x46284), and
## -[DraggableIV touchesEnded:withEvent:] (0x46860) treats 0 as "never snap" --
## a released view simply stays where it was left, clamped to its min/max. No
## `ms` class ever calls setSnapTime:; the only callers are the ccb/cd/fc/dic/
## ca/cff/ws classes. Snapping back was an invention.
@export var snap_back := false
@export var snap_time := 0.0
@export var lock_x := false
@export var lock_y := false
## Optional clamp on where the sprite may be dragged. Zero size means no clamp.
@export var drag_bounds := Rect2()
## Success region, in the parent's coordinate space.
@export var drop_target := Rect2()
@export var enabled := true

var _dragging := false
var _touch_offset := Vector2.ZERO
var _origin := Vector2.ZERO
var _origin_captured := false

# -- touches during UIView animations -------------------------------------
#
# Read in the iPhone 4's own UIKit (iOS 6.1.3):
#  * -[UIView hitTest:withEvent:] 0x32F42838 asks _UIViewEatsTouches
#    0x32F42B58 first. A view EATS a touch when it is visible, its
#    presentation opacity is >= 0.01, and one of its layer's animations has a
#    delegate whose _allowsUserInteraction is NO. Only the block API's
#    UIViewAnimationBlockDelegate (0x3307E258, the options' bit 2) answers
#    NO; -[UIViewAnimationState _allowsUserInteraction] 0x3307B220 is YES for
#    every +beginAnimations:/commitAnimations block. An eating view is
#    tested against its PRESENTATION layer, and on a hit hitTest: returns it
#    (so nothing under it is hit) and calls -[UIApplication _eatCurrentTouch]
#    0x3307E268. INFERRED from that name and the documented "interactions
#    are disabled for the views being animated": the view gets no touch
#    either -- nobody does.
#    The app is linked against SDK 8.1, so the _UIApplicationLinkedOnOrAfter
#    gate in hitTest: is on.
#  * Every other animation leaves the view on the ordinary path, which
#    hit-tests the MODEL geometry: during SnapToOrig the view answers at
#    origCenter, not where it is drawn, and -center reads the model too.
#
## Block-API animations (no AllowUserInteraction) running on this sprite.
var _eat_tweens: Array[Tween] = []
## The touch now in progress was eaten: swallow its moves and release.
var _eaten := false
## A begin/commit-style move of `position` (animate_position()).
var _anim_tween: Tween = null
var _anim_model := Vector2.ZERO
var _anim_live := false
var _anim_seq := 0


func _ready() -> void:
	capture_origin()


## Remember the current position as the snap-back point. Call again if the
## sprite is repositioned after _ready.
func capture_origin() -> void:
	_origin = position
	_origin_captured = true


func _hit(global_pos: Vector2) -> bool:
	if texture == null:
		return false
	var local := to_local(global_pos)
	var size := texture.get_size()
	var rect := Rect2(Vector2.ZERO, size) if not centered \
		else Rect2(-size * 0.5, size)
	return rect.has_point(local)


## UIKit's ordinary hit test reads the MODEL frame: while animate_position()
## is moving the sprite, test where it is going, not where it is drawn.
func _hit_model(global_pos: Vector2) -> bool:
	if not is_animating_position():
		return _hit(global_pos)
	var drawn := position
	position = _anim_model
	var hit := _hit(global_pos)
	position = drawn
	return hit


## Port of a block-API animation WITHOUT UIViewAnimationOptionAllowUserInteraction
## (+animateWithDuration:animations:[completion:], or :delay:options: with bit
## 2 clear) running on this view: until `tw` finishes (or is killed), a touch
## that lands on the sprite where it is drawn is eaten -- it starts no drag
## and reaches nothing underneath. Leaves `enabled` alone, so a screen's own
## enable/disable logic and its reset paths are unaffected.
func eat_touches_during(tw: Tween) -> void:
	if tw != null and tw.is_valid():
		_eat_tweens.append(tw)


## True while a block-API animation registered with eat_touches_during() runs.
func eats_touches() -> bool:
	var live: Array[Tween] = []
	for tw in _eat_tweens:
		if tw != null and tw.is_valid() and tw.is_running():
			live.append(tw)
	_eat_tweens = live
	return not live.is_empty()


## Port of a +beginAnimations:/commitAnimations move of the view's centre (or
## a block one WITH AllowUserInteraction): appends to `tw` a tweener that
## moves the sprite from its current position to `to` and returns it, so the
## caller can set the curve. Touches stay on, as in UIKit, with UIKit's
## semantics: the sprite is hit-tested at `to` (the model), and a touch that
## grabs it mid-flight lands it on the model and stops this tweener moving it,
## so the drag owns the sprite and the drop is where it is drawn. The rest of
## `tw` (completions etc.) still runs on schedule -- a CAAnimation is not
## removed when the model changes under it, so animationDidStop: still fires.
## A later animate_position() supersedes this one, as a new animation of the
## same key replaces the old.
## PORT CHOICE: UIKit's presentation would glide on toward the finger for the
## rest of the duration (the action's CABasicAnimation has only a fromValue,
## 0x32F34998); the port puts the sprite on the model at once, so the picture
## and the model never disagree.
func animate_position(tw: Tween, to: Vector2, seconds: float) -> MethodTweener:
	_anim_seq += 1
	var seq := _anim_seq
	_anim_tween = tw
	_anim_model = to
	_anim_live = true
	return tw.tween_method(func(p: Vector2) -> void:
		if seq != _anim_seq:
			return
		position = p
		if p == to:
			_anim_live = false, position, to, seconds)


## True while an animate_position() move is still under way.
func is_animating_position() -> bool:
	return _anim_live and _anim_tween != null and _anim_tween.is_valid()


## UIKit's -center/-frame origin: the model value. While animate_position()
## runs that is its target; otherwise the current position.
func model_position() -> Vector2:
	return _anim_model if is_animating_position() else position


## Stop an animate_position() move without moving the sprite (e.g. a screen
## placing it directly, as a setCenter: outside an animation block would).
func cancel_position_animation() -> void:
	_anim_seq += 1
	_anim_live = false


## Centre of the sprite in the parent's space, which is what the original
## compared against its detection rect.
func center() -> Vector2:
	if texture == null:
		return position
	var half := texture.get_size() * scale * 0.5
	return position if centered else position + half


func _unhandled_input(event: InputEvent) -> void:
	if _eaten:
		# The rest of an eaten touch -- its moves and its release -- reaches
		# nobody (see the header). A new press means it is over.
		if event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_eaten = false
			if not event.pressed:
				if get_viewport() != null:
					get_viewport().set_input_as_handled()
				return
		elif event is InputEventMouseMotion:
			if get_viewport() != null:
				get_viewport().set_input_as_handled()
			return

	if not enabled:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# A block-API animation without AllowUserInteraction: the touch is
		# hit-tested where the sprite is drawn and, on a hit, eaten.
		if event.pressed and not _dragging and is_visible_in_tree() \
				and modulate.a >= 0.01 and eats_touches() \
				and _hit(event.global_position):
			_eaten = true
			if get_viewport() != null:
				get_viewport().set_input_as_handled()
			return
		# UIKit hit-testing skips hidden views and views with alpha < 0.01,
		# so a hidden draggable cannot be picked up (it used to be). A touch
		# already in progress stays with the view, as in UIKit.
		if event.pressed and not _dragging and is_visible_in_tree() \
				and modulate.a >= 0.01 and _hit_model(event.global_position):
			if not _origin_captured:
				capture_origin()
			if is_animating_position():
				# Grabbed mid-flight: the drag takes over from the model.
				position = _anim_model
				cancel_position_animation()
			_dragging = true
			_touch_offset = position - get_parent().to_local(event.global_position)
			drag_started.emit()
			if get_viewport() != null:
				get_viewport().set_input_as_handled()
		elif not event.pressed and _dragging:
			_end_drag()
			if get_viewport() != null:
				get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion and _dragging:
		# get_parent() is untyped, so to_local()'s return type cannot be
		# inferred -- annotate rather than use :=.
		var target: Vector2 = get_parent().to_local(event.global_position) + _touch_offset
		if lock_x:
			target.x = position.x
		if lock_y:
			target.y = position.y
		if drag_bounds.size != Vector2.ZERO:
			target.x = clampf(target.x, drag_bounds.position.x, drag_bounds.end.x)
			target.y = clampf(target.y, drag_bounds.position.y, drag_bounds.end.y)
		position = target
		drag_moved.emit(center())


func _end_drag() -> void:
	_dragging = false
	var c := center()
	var hit: bool = drop_target.size != Vector2.ZERO and drop_target.has_point(c)
	drag_ended.emit(c, hit)
	if hit:
		dropped_on_target.emit(c)
	if snap_back and not hit:
		return_to_origin()


func return_to_origin(duration := -1.0) -> void:
	var t: float = snap_time if duration < 0.0 else duration
	if t <= 0.0:
		cancel_position_animation()
		position = _origin
		return
	# UIViewAnimationCurve 3 is linear (0x46860), not the eased quad the port
	# used to apply. SnapToOrig is +beginAnimations:/commitAnimations with
	# the DraggableIV as delegate, so the view stays touchable on the way
	# home (UIViewAnimationState answers _allowsUserInteraction YES,
	# 0x3307B220) -- at origCenter, its model. animate_position() gives
	# exactly that; the old plain property tween kept pulling a sprite that
	# had been grabbed mid-snap back home under the finger.
	animate_position(create_tween(), _origin, t) \
		.set_trans(Tween.TRANS_LINEAR)


func is_dragging() -> bool:
	return _dragging
