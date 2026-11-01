# Port of LillyView, the lily pad of the frog toss (ffTossFrogVC).
#
# From the original binary (IMPs from the ObjC method list):
#   initWithFrame:  0x12C2B0  baseIV = UIImageView(FF_lily_1.png) with frame
#                             (0,0,w,h) -- the 123x116 art stretched to the
#                             square the caller asks for; user interaction off.
#   bob             0x12C544  "Bob": curve 3 (linear), repeat FLT_MAX,
#                             autoreverses, 1.0s; baseIV.transform set to
#                             scale 0.9 then scale 1.1 inside the one block.
#   pauseLayer      0x12C410  layer.speed = 0, timeOffset = now  (freezes the
#                             layer's own animations AND its sublayers', so the
#                             path and the bob stop together)
#   resumeLayer     0x12C47C  speed 1, beginTime shifted by the paused time --
#                             the classic CA pause/resume, resuming exactly
#                             where it froze.
#   stopBobbing     0x12C698  empty.
#
# The movement itself is not LillyView's: ffTossFrogVC resetLillies:
# (0x126C68) adds two CAKeyframeAnimations to the lily's layer, "MoveXLilly"
# (position.x) and "MoveYLilly" (position.y), kCAAnimationLinear, uniform key
# times, 30.0s, repeatCount FLT_MAX, fillMode forwards, never removed. The
# screen hands the keyframes to set_path(); both axes share duration and key
# times, so they are sampled together here.
#
# One clock (`_t`, the layer's local time) drives both the path and the bob,
# because in the original both live under this layer and pause/resume
# together.
#
# INFERRED (UIKit semantics, not this binary): bob sets the transform twice in
# one animation block. UIKit keeps one animation per key -- the last -- and
# its fromValue is the model value the first set left behind, so the
# effective animation is 0.9 -> 1.1, autoreversing.

extends Node2D

const IMAGE := "FF_lily_1.png"

## bob (0x12C544)
const BOB_DURATION := 1.0
const BOB_FROM := 0.9
const BOB_TO := 1.1

## initWithFrame: size (the frame is square in every caller).
var frame_size := Vector2.ZERO

var _base: Sprite2D
var _base_fit := Vector2.ONE          # art -> frame stretch (scale-to-fill)
var _t := 0.0                         # layer local time
var _paused := false
var _bobbing := false

var _path: PackedVector2Array = PackedVector2Array()
var _path_duration := 0.0


## initWithFrame:(0,0,w,h). `center` is the setCenter: that follows.
func setup(size: Vector2) -> void:
	frame_size = size
	_base = Sprite2D.new()
	_base.centered = true
	if Assets.has_image(IMAGE):
		_base.texture = Assets.texture(IMAGE)
		var art: Vector2 = _base.texture.get_size()
		_base_fit = Vector2(size.x / art.x, size.y / art.y)
	_base.scale = _base_fit
	add_child(_base)


## The keyframe values of MoveXLilly/MoveYLilly, in pool coordinates, and
## their shared duration. Animations start at the layer's current time.
func set_path(points: PackedVector2Array, duration: float) -> void:
	_path = points
	_path_duration = duration
	_t = 0.0
	_apply()


func bob() -> void:
	_bobbing = true
	_apply()


func stop_bobbing() -> void:
	pass   # 0x12C698 is empty


func pause_layer() -> void:
	_paused = true


func resume_layer() -> void:
	_paused = false


func is_paused() -> bool:
	return _paused


## The presentation layer's frame (what resetLillies'/animationDidStop's
## CGRectIntersection reads). The bob scales baseIV, not this view, so the
## frame is the unscaled square at the animated centre.
func presentation_frame() -> Rect2:
	return Rect2(position - frame_size * 0.5, frame_size)


func _process(delta: float) -> void:
	if _paused:
		return
	_t += delta
	_apply()


func _apply() -> void:
	if _path.size() >= 2 and _path_duration > 0.0:
		position = _sample_path(fmod(_t, _path_duration) / _path_duration)
	if _base != null and _bobbing:
		# Linear, autoreversing, 1.0s each way.
		var phase := fmod(_t, BOB_DURATION * 2.0) / BOB_DURATION
		var k := phase if phase <= 1.0 else 2.0 - phase
		var s := lerpf(BOB_FROM, BOB_TO, k)
		_base.scale = _base_fit * s


## kCAAnimationLinear with no keyTimes: N values at uniform times 0..1.
func _sample_path(u: float) -> Vector2:
	var segs := _path.size() - 1
	var f := u * segs
	var i := mini(int(floor(f)), segs - 1)
	return _path[i].lerp(_path[i + 1], f - i)
