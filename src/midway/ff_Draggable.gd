# Port of DraggableIV for the frog toss -- a UIImageView subclass that follows
# the touch, clamped per axis, and reports to a delegate.
#
# Why not core/DraggableSprite2D: the frog is rotated and scaled by the game
# while it is draggable, it is animated with UIView animations whose MODEL
# value (what hit-testing, touches and the landing test read) differs from
# what is on screen, its layer is paused and resumed, and it plays a
# UIImageView flipbook. DraggableSprite2D is a plain Sprite2D with a
# Rect2 clamp and no delegate; this mirrors the original instead.
#
# From the original binary:
#   initWithCoder:            0x46284  snapTime 0, origCenter = centre,
#                                      minX/minY = INT_MIN, maxX/maxY =
#                                      INT_MAX, interaction on, single touch.
#   touchesBegan:withEvent:   0x464F4  touchOffset = centre - touch (in the
#                                      superview); delegate
#                                      draggableTouchBegan:fromSender:.
#   touchesMoved:withEvent:   0x46614  per unlocked axis: v = touch +
#                                      offset, clamped to [min, max] (int
#                                      bounds compared as float); setCenter;
#                                      delegate draggableTouchMoved:.
#   touchesEnded:withEvent:   0x46860  snapTime == 0: the same placement as
#                                      a move; else "SnapToOrig", curve 3
#                                      (linear), snapTime seconds, to
#                                      origCenter. Then delegate
#                                      draggableTouchEnded:.
#   touchesCancelled:         0x46B70  = touchesEnded.
#
# UIView emulation (what UIKit does underneath, needed by ffTossFrogVC):
#  * `center`, `rot`, `scl`, `alpha` are the MODEL values. Setting one
#    outside an animation changes the model at once; the screen only follows
#    when no animation of that property is running (CA keeps rendering a
#    running animation and the view lands on the model value when it ends).
#  * animate(): a UIView animation block on this view. The model jumps to the
#    target immediately; the presentation tweens there.
#  * hit_test() uses the model geometry, like -[UIView hitTest:withEvent:]:
#    hidden, interaction disabled or alpha < 0.01 views are skipped.
#  * pause_layer()/resume_layer(): layer.speed 0 / the beginTime resume.
#  * UIImageView animationImages / animationDuration / animationRepeatCount /
#    startAnimating / stopAnimating (frames evenly spaced; when the run ends
#    or is stopped the view shows `image` again).

extends Node2D

const INT_MIN := -2147483648
const INT_MAX := 2147483647

## UIViewAnimationCurve values used by the callers.
const CURVE_EASE_IN_OUT := 0
const CURVE_EASE_IN := 1
const CURVE_EASE_OUT := 2
const CURVE_LINEAR := 3

## Delegate: any object with draggable_touch_began/moved/ended(pos, sender).
var del: Object = null
var snap_time := 0.0
var orig_center := Vector2.ZERO
var touch_offset := Vector2.ZERO
var lock_x_movement := false
var lock_y_movement := false
var min_x := INT_MIN
var max_x := INT_MAX
var min_y := INT_MIN
var max_y := INT_MAX
var user_interaction_enabled := true

## bounds.size -- the nib frame of the view.
var bounds_size := Vector2.ZERO

## Model values (UIView center / transform / alpha).
var center := Vector2.ZERO
var rot := 0.0
var scl := 1.0
var alpha := 1.0

## UIImageView.
var image: Texture2D
var animation_images: Array[Texture2D] = []
var animation_duration := 0.0
var animation_repeat_count := 0

var _sprite: Sprite2D
var _anims: Dictionary = {}          # "center"/"transform"/"alpha" -> Tween
var _layer_paused := false
var _flip_running := false
var _flip_t := 0.0


## initWithCoder: from the nib frame; `img` is the nib's image.
func setup(frame: Rect2, img: Texture2D) -> void:
	bounds_size = frame.size
	image = img
	_sprite = Sprite2D.new()
	_sprite.centered = true
	add_child(_sprite)
	_show_image(image)
	snap_time = 0.0
	set_center(frame.get_center())
	orig_center = center


# -- model setters (outside an animation block) ------------------------

func set_center(p: Vector2) -> void:
	center = p
	if not _animating("center"):
		position = p


func set_transform_rs(r: float, s: float) -> void:
	rot = r
	scl = s
	if not _animating("transform"):
		rotation = r
		scale = Vector2(s, s)


func set_alpha(a: float) -> void:
	alpha = clampf(a, 0.0, 1.0)      # UIView clamps alpha to 0..1
	if not _animating("alpha"):
		modulate.a = alpha


## UIView frame of the transformed view: the bounding box of the model.
func frame() -> Rect2:
	return _aabb(Rect2(-bounds_size * 0.5, bounds_size))


## A rect given in this view's bounds coordinates (origin top-left), mapped
## into the superview -- [superview convertRect:r fromView:self].
func convert_rect_to_superview(r: Rect2) -> Rect2:
	return _aabb(Rect2(r.position - bounds_size * 0.5, r.size))


func _aabb(local: Rect2) -> Rect2:
	var xf := Transform2D(rot, Vector2(scl, scl), 0.0, center)
	var pts := [local.position, Vector2(local.end.x, local.position.y),
		local.end, Vector2(local.position.x, local.end.y)]
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p: Vector2 in pts:
		var q := xf * p
		lo = lo.min(q)
		hi = hi.max(q)
	return Rect2(lo, hi - lo)


# -- UIView animations ----------------------------------------------------

## One UIView animation block on this view. `props` may hold "center"
## (Vector2), "transform" ([rot, scale]) or "alpha" (float) -- every caller
## animates exactly one of them per block, which is what lets a later block
## replace an earlier one per key the way CA does. The model takes the target
## now; `on_stop` runs when the animation completes
## (animationDidStop:finished:context:). An animation replaced or removed
## before it completes does not call `on_stop` (see ffTossFrogVC.gd for why
## that is equivalent here).
func animate(props: Dictionary, duration: float, curve: int, on_stop: Callable = Callable()) -> void:
	assert(props.size() == 1, "one property per animation block")
	var key: String = props.keys()[0]
	_kill_anim(key)
	var tw := create_tween()
	# The presentation runs from where the view is drawn now toward the LIVE
	# model value, not a target frozen at commit: UIKit's action for a
	# begin/commit block is a CABasicAnimation with only a fromValue
	# (-[UIView(CALayerDelegate) actionForLayer:forKey:] 0x32F34998, iOS 6),
	# so a setCenter: during it -- the frog dragged while "ResetFrog" still
	# slides it in -- is followed, reaching the finger when the animation
	# ends. With a constant model this is the same motion as before.
	match key:
		"center":
			center = props["center"]
			var from_c := position
			_apply_curve(tw.tween_method(func(u: float) -> void:
				position = from_c.lerp(center, u), 0.0, 1.0, duration), curve)
		"transform":
			var t: Array = props["transform"]
			rot = float(t[0])
			scl = float(t[1])
			var from_r := rotation
			var from_s := scale
			_apply_curve(tw.tween_method(func(u: float) -> void:
				rotation = lerpf(from_r, rot, u)
				scale = from_s.lerp(Vector2(scl, scl), u), 0.0, 1.0, duration), curve)
		"alpha":
			alpha = clampf(float(props["alpha"]), 0.0, 1.0)
			var from_a := modulate.a
			_apply_curve(tw.tween_method(func(u: float) -> void:
				modulate.a = lerpf(from_a, alpha, u), 0.0, 1.0, duration), curve)
	tw.tween_callback(func() -> void:
		if _anims.get(key) == tw:
			_anims.erase(key)
		_sync_model()
		if on_stop.is_valid():
			on_stop.call())
	_anims[key] = tw
	if _layer_paused:
		tw.pause()


## -[CALayer removeAllAnimations]: the presentation snaps to the model.
func remove_all_animations() -> void:
	for k: String in _anims.keys():
		var tw: Tween = _anims[k]
		if tw != null and tw.is_valid():
			tw.kill()
	_anims.clear()
	_flip_running = false
	_show_image(image)
	_sync_model()


func pause_layer() -> void:
	_layer_paused = true
	for tw: Tween in _anims.values():
		if tw != null and tw.is_valid():
			tw.pause()


func resume_layer() -> void:
	_layer_paused = false
	for tw: Tween in _anims.values():
		if tw != null and tw.is_valid():
			tw.play()


func is_layer_paused() -> bool:
	return _layer_paused


func _animating(key: String) -> bool:
	var tw: Tween = _anims.get(key)
	return tw != null and tw.is_valid()


func _kill_anim(key: String) -> void:
	var tw: Tween = _anims.get(key)
	if tw != null and tw.is_valid():
		tw.kill()
	_anims.erase(key)
	_sync_model()


func _sync_model() -> void:
	if not _animating("center"):
		position = center
	if not _animating("transform"):
		rotation = rot
		scale = Vector2(scl, scl)
	if not _animating("alpha"):
		modulate.a = alpha


func _apply_curve(pt, curve: int) -> void:   # a PropertyTweener or MethodTweener
	match curve:
		CURVE_LINEAR:
			pt.set_trans(Tween.TRANS_LINEAR)
		CURVE_EASE_IN:
			pt.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		CURVE_EASE_OUT:
			pt.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_:
			pt.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# -- UIImageView flipbook ---------------------------------------------------

func start_animating() -> void:
	if animation_images.is_empty() or animation_duration <= 0.0:
		return
	_flip_running = true
	_flip_t = 0.0
	_show_image(animation_images[0])


func stop_animating() -> void:
	_flip_running = false
	_show_image(image)


func is_animating() -> bool:
	return _flip_running


func _process(delta: float) -> void:
	if not _flip_running or _layer_paused:
		return
	_flip_t += delta
	var n := animation_images.size()
	var runs := animation_repeat_count if animation_repeat_count > 0 else 0
	if runs > 0 and _flip_t >= animation_duration * runs:
		stop_animating()
		return
	var frame_i := int(floor(fmod(_flip_t, animation_duration) / animation_duration * n))
	_show_image(animation_images[clampi(frame_i, 0, n - 1)])


func _show_image(tex: Texture2D) -> void:
	if _sprite == null:
		return
	_sprite.texture = tex
	if tex != null:
		var art := tex.get_size()
		# UIImageView default content mode: scale-to-fill the bounds.
		_sprite.scale = Vector2(bounds_size.x / art.x, bounds_size.y / art.y)


# -- touches ------------------------------------------------------------------

## -[UIView hitTest:withEvent:] against the model geometry.
func hit_test(p: Vector2) -> bool:
	if not visible or not user_interaction_enabled or alpha < 0.01:
		return false
	var xf := Transform2D(rot, Vector2(scl, scl), 0.0, center)
	var local: Vector2 = xf.affine_inverse() * p
	return Rect2(-bounds_size * 0.5, bounds_size).has_point(local)


func touches_began(p: Vector2) -> void:
	touch_offset = center - p
	if del != null and del.has_method("draggable_touch_began"):
		del.call("draggable_touch_began", p, self)


func touches_moved(p: Vector2) -> void:
	_place(p)
	if del != null and del.has_method("draggable_touch_moved"):
		del.call("draggable_touch_moved", p, self)


func touches_ended(p: Vector2) -> void:
	if snap_time == 0.0:
		_place(p)
	else:
		animate({"center": orig_center}, snap_time, CURVE_LINEAR)
	if del != null and del.has_method("draggable_touch_ended"):
		del.call("draggable_touch_ended", p, self)


func _place(p: Vector2) -> void:
	var c := center
	if not lock_x_movement:
		var x := p.x + touch_offset.x
		if x < float(min_x):
			x = float(min_x)
		if x > float(max_x):
			x = float(max_x)
		c.x = x
		set_center(c)
	if not lock_y_movement:
		var y := p.y + touch_offset.y
		if y < float(min_y):
			y = float(min_y)
		if y > float(max_y):
			y = float(max_y)
		c.y = y
		set_center(c)
