# Port of Animator (0x16FD24..0x170ACC): one whack-a-mole hole. A
# UIImageView subclass driven entirely by its own timers.
#
# Life cycle (all read from the class):
#
#   startSleeping (0x1703A4) -- only if awake, not asleep, not hit:
#       awake = NO, stopAnimating, asleep = YES, image = Wm_Empty_Mole.png,
#       then startAnimation: after a random WHOLE number of seconds in
#       [(int)sleepMinTime, (int)sleepMaxTime] (1..5 from startGame:).
#   startAnimation: (0x170158) -- always stopAnimating first; then only if
#       not awake, asleep, not hit: awake = YES, asleep = NO,
#       d = random int in [(int)animationMinTime, (int)animationMaxTime]
#       (1..5), setImagesIndexArray: (index 0, repeating NSTimer every
#       d * 0.125 s advancing currentImageIndex mod 8), UIImageView
#       animation of the 8 pop-up frames over d seconds, repeating forever,
#       and startSleeping after d seconds.
#   touchesBegan: (0x1706D0) -- tells the delegate where the mole is
#       (didAnimatorTouchBegan: with the view's centre: the hammer swings
#       there). Then, if awake and not hit: a hit only while
#       currentImageIndex is 2..6 (the frames where the mole is up) ->
#       wm_hit_mole.mp3, delegate didAnimatorHit, hit = YES, awake = asleep =
#       NO, hitAnimation after 0.3 s; outside that window falls through to
#       wm_hit_board.mp3. Not awake and not hit -> wm_hit_board.mp3. Already
#       hit -> silence.
#   hitAnimation (0x1705F4) -- if hit: the 6 frames of
#       Wm_Mole_Animation_SpriteSheet.png (3x2 of 114x114) once over 1.0 s,
#       then againStartAnimation after 2.0 s.
#   againStartAnimation (0x16FF2C) -- stopAnimating, image = empty mole,
#       awake = NO, asleep = YES, hit = NO, startAnimation: at once.
#
# None of the performSelector:afterDelay: requests is cancelled by the state
# changes above (only wm_hitmole resetGame cancels them), so stale ones fire
# later and act on whatever state the mole is in by then -- e.g. the
# startSleeping queued before a hit can cut short the next pop-up. That is
# the original's behaviour and is kept: every request is an independent timer.
#
# Delays given to performSelector:afterDelay: are doubles; the binary
# passes hitAnimation's as {0x33333333, 0x3FD33333} = 0.3 and
# againStartAnimation's as {0, 0x40000000} = 2.0 (reading only the high
# word as a float gives a misleading 1.65).
#
# Geometry: initwithCenter: (0x16FD5C) is initWithImage:nil + frame
# (0,0,70,70); contentMode stays scaleToFill, so the 114x114 frames are
# squeezed into 70x70, then wm_hitmole scales the whole view by its row
# scale with setTransform:. Touches hit-test the transformed 70x70 bounds.
#
# Not ported: setImageCenter: / setImageSize: / setActiveImage: (no selRef
# anywhere in the binary -- never called) and the dealloc NSLog.
#
# Loaded by path (class_name does not work in this project).

extends Sprite2D

const EMPTY_MOLE := "Wm_Empty_Mole.png"
const HIT_SHEET := "Wm_Mole_Animation_SpriteSheet.png"
const FRAME_SIZE := Vector2(70, 70)      # initwithCenter: setFrame:
const HIT_FRAME := 0.3                    # touchesBegan: -> hitAnimation
const AGAIN_DELAY := 2.0                  # hitAnimation -> againStartAnimation
const HIT_ANIM_SECONDS := 1.0             # hitAnimation setAnimationDuration:
const INDEX_TICK := 0.125                 # setImagesIndexArray: d * 0.125
const INDEX_WRAP := 8                     # displayNextImage wraps at 8
const HIT_FIRST := 2                      # touchesBegan: hit window
const HIT_LAST := 6

# -- Animator ivars -------------------------------------------------------
var delegate: Object = null
var sleep_min_time := 0.0
var sleep_max_time := 0.0
var current_image_index := 0
var animation_random_duration := 0
var is_awake := false
var is_sleep := false
var is_hit := false
var image_array: Array = []
var banner_images_array: Array = []
var timer: Timer = null
var animation_min_time := 0.0
var animation_max_time := 0.0

# -- UIView / UIImageView state the class relies on ------------------------
var tag := 0
var user_interaction_enabled := false
var image: Texture2D = null
var animation_images: Array = []
var animation_duration := 0.0
var animation_repeat_count := 0

var _animating := false
var _anim_elapsed := 0.0
var _frame_size := Vector2.ZERO
var _transform_scale := 1.0
## performSelector:withObject:afterDelay: requests not yet fired.
var _pending: Array[Timer] = []


func _init() -> void:
	centered = true


## -[Animator initwithCenter:] -- the centre argument is unused by the
## original (it only sets a 70x70 frame at the origin; wm_hitmole then calls
## setCenter: itself).
func initwith_center(_center: Vector2) -> Node:
	_frame_size = FRAME_SIZE
	position = FRAME_SIZE * 0.5
	_refresh()
	return self


func set_center(p: Vector2) -> void:
	position = p


## setTransform: with a uniform CGAffineTransformScale (the only transform
## wm_hitmole ever gives a mole).
func set_transform_scale(s: float) -> void:
	_transform_scale = s
	_refresh()


## UIView pointInside: through the transform: the scaled 70x70 square around
## the centre (CGRectContainsPoint: min edge inclusive, max edge exclusive).
func point_inside(p: Vector2) -> bool:
	if _frame_size == Vector2.ZERO or _transform_scale == 0.0:
		return false
	var local: Vector2 = (p - position) / _transform_scale + _frame_size * 0.5
	return local.x >= 0.0 and local.y >= 0.0 \
		and local.x < _frame_size.x and local.y < _frame_size.y


# -- image helpers ----------------------------------------------------------

## -[Animator cropingImage:img:] -- CGImageCreateWithImageInRect, which clips
## the rect to the image.
func croping_image_img(rect: Rect2, img: Texture2D) -> Texture2D:
	if img == null:
		return null
	var r := rect.intersection(Rect2(Vector2.ZERO, img.get_size()))
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return null
	var at := AtlasTexture.new()
	at.atlas = img
	at.region = r
	return at


## -[Animator getImageArray:colums:rows:imgWidth:imgHeight:] (0x16FE08).
## Cuts rows*cols frames, row by row. After a full row the y offset is SET to
## imgHeight (not advanced by it) -- identical for the two-row sheets the
## game uses, kept literal.
func get_image_array_colums_rows_img_width_img_height(
		image_name: String, cols: int, rows: int, w: int, h: int) -> Array:
	var arr: Array = []
	var remaining := rows * cols
	if remaining >= 1:
		var col := 0
		var y := 0
		while remaining != 0:
			var img := _load(image_name)
			arr.append(croping_image_img(
				Rect2(float(col * w), float(y), float(w), float(h)), img))
			col += 1
			if col == cols:
				y = h
				col = 0
			remaining -= 1
	return arr


func _load(image_name: String) -> Texture2D:
	return Assets.texture(image_name)


# -- the mole state machine -------------------------------------------------

## -[Animator againStartAnimation] (0x16FF2C).
func again_start_animation() -> void:
	stop_animating()
	set_inactive_image(_load(EMPTY_MOLE))
	is_awake = false
	is_sleep = true
	is_hit = false
	start_animation(image_array)


## -[Animator setImagesIndexArray:] (0x16FFE4).
func set_images_index_array(arr: Array) -> void:
	banner_images_array = arr
	if timer != null:
		_invalidate(timer)
		timer = null
	current_image_index = 0
	timer = Timer.new()
	timer.one_shot = false
	timer.wait_time = float(animation_random_duration) * INDEX_TICK
	add_child(timer)
	timer.timeout.connect(display_next_image)
	timer.start()


## -[Animator displayNextImage] (0x1700E8).
func display_next_image() -> void:
	current_image_index += 1
	if current_image_index >= INDEX_WRAP:
		current_image_index = 0


## -[Animator getRandomNumber:to:] (0x17013C): inclusive a..b.
func get_random_number_to(a: int, b: int) -> int:
	return randi() % (1 - a + b) + a


## -[Animator startAnimation:] (0x170158).
func start_animation(arr: Array) -> void:
	stop_animating()
	if not is_awake and is_sleep and not is_hit:
		image_array = arr
		is_awake = true
		is_sleep = false
		animation_random_duration = get_random_number_to(
			int(animation_min_time), int(animation_max_time))
		set_images_index_array(arr)
		animation_duration = float(animation_random_duration) * INDEX_TICK * 8.0
		animation_repeat_count = 0
		animation_images = image_array
		start_animating()
		_perform_after(float(animation_random_duration), &"start_sleeping")


## -[Animator startSleeping] (0x1703A4).
func start_sleeping() -> void:
	if is_awake and not is_sleep and not is_hit:
		is_awake = false
		stop_animating()
		is_sleep = true
		set_inactive_image(_load(EMPTY_MOLE))
		var secs := get_random_number_to(int(sleep_min_time), int(sleep_max_time))
		_perform_after(float(secs), &"start_animation", image_array)


## -[Animator setInactiveImage:] (0x170510): setImage:.
func set_inactive_image(img: Texture2D) -> void:
	image = img
	_refresh()


## -[Animator hitAnimation] (0x1705F4).
func hit_animation() -> void:
	if is_hit:
		stop_animating()
		animation_images = get_image_array_colums_rows_img_width_img_height(
			HIT_SHEET, 3, 2, 114, 114)
		animation_duration = HIT_ANIM_SECONDS
		animation_repeat_count = 1
		start_animating()
		_perform_after(AGAIN_DELAY, &"again_start_animation")


## -[Animator touchesBegan:withEvent:] (0x1706D0).
func touches_began() -> void:
	if delegate != null:
		delegate.call("did_animator_touch_began", position)
	if is_awake and not is_hit:
		if current_image_index >= HIT_FIRST and current_image_index <= HIT_LAST:
			Audio.play("wm_hit_mole")
			if delegate != null:
				delegate.call("did_animator_hit")
			is_hit = true
			is_awake = false
			is_sleep = false
			_perform_after(HIT_FRAME, &"hit_animation")
			return
	elif is_hit:
		return
	Audio.play("wm_hit_board")


# -- UIImageView animation ----------------------------------------------------

func start_animating() -> void:
	_animating = not animation_images.is_empty()
	_anim_elapsed = 0.0
	_refresh()


func stop_animating() -> void:
	_animating = false
	_refresh()


func is_animating() -> bool:
	return _animating


func _process(delta: float) -> void:
	if not _animating:
		return
	_anim_elapsed += delta
	if animation_repeat_count > 0 \
			and _anim_elapsed >= animation_duration * animation_repeat_count:
		# A finite animation ends on the view's `image`, as UIImageView does.
		_animating = false
	_refresh()


## What a UIImageView shows: the current animation frame while animating,
## else `image`, scaled to fill the frame, then by the view transform.
func _refresh() -> void:
	var tex: Texture2D = image
	if _animating and not animation_images.is_empty():
		var n := animation_images.size()
		var i := 0
		if animation_duration > 0.0:
			i = int(fmod(_anim_elapsed, animation_duration) / animation_duration * n)
		tex = animation_images[clampi(i, 0, n - 1)]
	texture = tex
	if tex != null and _frame_size != Vector2.ZERO:
		scale = _frame_size / tex.get_size() * _transform_scale
	else:
		scale = Vector2.ONE * _transform_scale


# -- performSelector:withObject:afterDelay: / NSTimer -------------------------

func _perform_after(delay: float, method: StringName, arg: Variant = null) -> void:
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = delay
	add_child(t)
	_pending.append(t)
	t.timeout.connect(_fire.bind(t, method, arg))
	t.start()


func _fire(t: Timer, method: StringName, arg: Variant) -> void:
	_pending.erase(t)
	t.queue_free()
	if arg == null:
		call(method)
	else:
		call(method, arg)


## +[NSObject cancelPreviousPerformRequestsWithTarget:].
func cancel_previous_perform_requests() -> void:
	for t in _pending:
		if is_instance_valid(t):
			t.stop()
			t.queue_free()
	_pending.clear()


## -[NSTimer invalidate] on the index timer (wm_hitmole resetGame).
func invalidate_timer() -> void:
	if timer != null:
		_invalidate(timer)
		timer = null


func _invalidate(t: Timer) -> void:
	if is_instance_valid(t):
		t.stop()
		t.queue_free()
