# ClownView, ported for wsRaceVC -- a clown head with a balloon on top.
#
# From the original binary (IMPs from the ObjC method list):
#   -initWithBalloonImage:clownImage:  0x12C700
#       initWithFrame: (0,0,80,100). Subviews, back to front:
#         balloon  BalloonView(balloon image), centre
#                  (frame.w * 0.5 - 2, -balloon.frame.h * 0.5 + 21) = (38,-9)
#                  for the 60x60 art; that centre is originalBalloonCenter.
#         clown    UIImageView(clown image) whose frame is then set to the
#                  ClownView's own frame (0,0,80,100) -- the receiver of that
#                  -frame is the ClownView (R1 = self at 0x12C928, checked in
#                  the disassembly), so the 158x260 head art is SCALED TO FILL
#                  80x100 (UIImageView's default content mode), squashed.
#         mouth    UIView (0,0,15,15), centre (w * 0.5, h * 0.5 + 10) =
#                  (40,60), yellow, HIDDEN -- used only as the hit box.
#   -pauseLayer   0x12CA64  layer.speed 0, timeOffset = the current layer time:
#                           any running animation freezes where it is.
#   -resumeLayer  0x12CAD0  speed 1, beginTime shifted by the paused time:
#                           the animation continues from where it froze.
#
# Geometry: this node's `position` is the layer's position (the view's
# centre) as currently PRESENTED -- the CAKeyframeAnimation wsRaceVC adds on
# "position" moves it. `center` is the model value (-center), which an
# animation does not change. Subviews hang off `bounds_node`, whose origin is
# the bounds' top-left, so they keep their UIKit coordinates.

extends Node2D

const BalloonView := preload("res://midway/ws_BalloonView.gd")

const FRAME_SIZE := Vector2(80, 100)
const BALLOON_X_SHIFT := -2.0
const BALLOON_BOTTOM := 21.0
const MOUTH_SIZE := Vector2(15, 15)
const MOUTH_DROP := 10.0

var balloon: BalloonView
var clown: Sprite2D
var mouth: ColorRect
var original_balloon_center := Vector2.ZERO
var bounds_node: Node2D

## -center: the model position.
var center := Vector2.ZERO

## The single position animation wsRaceVC adds (moveClown 0xD9F8): keyframe
## points, duration, and the layer time that has elapsed in it.
var _anim_points := PackedVector2Array()
var _anim_duration := 0.0
var _anim_autoreverses := false
var _anim_time := 0.0
var _speed := 1.0


## -initWithBalloonImage:clownImage: (0x12C700).
func init_with_balloon_image_clown_image(balloon_img: Texture2D,
		clown_img: Texture2D) -> void:
	bounds_node = Node2D.new()
	bounds_node.position = -FRAME_SIZE * 0.5
	add_child(bounds_node)

	balloon = BalloonView.new()
	balloon.init_with_balloon_image(balloon_img)
	bounds_node.add_child(balloon)
	balloon.position = Vector2(FRAME_SIZE.x * 0.5 + BALLOON_X_SHIFT,
		-balloon.frame_height() * 0.5 + BALLOON_BOTTOM)
	original_balloon_center = balloon.position

	clown = Sprite2D.new()
	clown.centered = false
	clown.texture = clown_img
	if clown_img != null:
		clown.scale = FRAME_SIZE / clown_img.get_size()
	bounds_node.add_child(clown)

	mouth = ColorRect.new()
	mouth.size = MOUTH_SIZE
	mouth.position = Vector2(FRAME_SIZE.x * 0.5, FRAME_SIZE.y * 0.5 + MOUTH_DROP) \
		- MOUTH_SIZE * 0.5
	mouth.color = Color(1, 1, 0)                       # yellowColor
	mouth.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouth.visible = false
	bounds_node.add_child(mouth)


## -setCenter: (no animation running changes what is presented).
func set_center(c: Vector2) -> void:
	center = c
	if _anim_points.is_empty():
		position = c


## [layer removeAllAnimations]: the presentation snaps back to the model.
func remove_all_animations() -> void:
	_anim_points = PackedVector2Array()
	_anim_time = 0.0
	position = center


## [layer addAnimation:forKey:] for a CAKeyframeAnimation on "position" along
## a polyline (MoveTo + AddLineTo), linear timing function, repeatCount
## HUGE (FLT_MAX), autoreverses as given, fill forwards.
## INFERRED (Core Animation): with no keyTimes and calculationMode linear the
## keyframes are spaced evenly in time -- each line segment takes duration /
## segments -- and a MoveTo that ends the path defines no keyframe.
func add_position_animation(points: PackedVector2Array, duration: float,
		autoreverses: bool) -> void:
	_anim_points = points
	_anim_duration = duration
	_anim_autoreverses = autoreverses
	_anim_time = 0.0
	position = _sample(0.0)


## -pauseLayer (0x12CA64).
func pause_layer() -> void:
	_speed = 0.0


## -resumeLayer (0x12CAD0).
func resume_layer() -> void:
	_speed = 1.0


func is_paused() -> bool:
	return _speed == 0.0


func _process(delta: float) -> void:
	if _anim_points.is_empty() or _speed == 0.0:
		return
	_anim_time += delta * _speed
	position = _sample(_anim_time)


func _sample(t: float) -> Vector2:
	var n := _anim_points.size()
	if n == 0:
		return center
	if n == 1 or _anim_duration <= 0.0:
		return _anim_points[0]
	var d := _anim_duration
	var u: float
	if _anim_autoreverses:
		var phase := fmod(t, 2.0 * d)
		u = phase / d if phase <= d else (2.0 * d - phase) / d
	else:
		u = fmod(t, d) / d
	var segs := n - 1
	var f := clampf(u, 0.0, 1.0) * float(segs)
	var i := mini(int(floor(f)), segs - 1)
	return _anim_points[i].lerp(_anim_points[i + 1], f - float(i))


## The presentation layer's frame, in the superview's coordinates.
func presentation_frame() -> Rect2:
	return Rect2(position - FRAME_SIZE * 0.5, FRAME_SIZE)


## [view.layer convertRect:mouth.frame fromLayer:clown.layer.presentationLayer]
## for a superview whose bounds origin is (0,0).
func presented_mouth_rect() -> Rect2:
	return Rect2(presentation_frame().position + mouth.position, mouth.size)
