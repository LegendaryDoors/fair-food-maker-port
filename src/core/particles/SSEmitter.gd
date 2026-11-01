# Port of SSEmitter -- the only particle system v1.27 actually runs.
#
# SSEmitter is a UIView subclass (superclass read from the class object in
# the binary). Every "particle" is a UIImageView added as a subview of the emitter
# and moved with one +[UIView animateWithDuration:delay:options:animations:
# completion:]. There is no update loop of its own: UIKit/Core Animation
# interpolate and the completion block removes the view. An NSTimer paces the
# spawns. Methods ported (IMPs from the ObjC method list):
#
#   init                                              0xB2728 readyToEmit = NO
#   setParticles:tint:random:interval:duration:repeat:finalCenter:startAlpha:
#     finalAlpha:startScale:finalScale:startXVariance:startYVariance:
#     endXVariance:endYVariance:options:              0xB2768 set_particles()
#   ...finalOffset:... (same, _center = offset + frame.size/2)
#                                                     0xB294C set_particles_final_offset()
#   start                                             0xB2C80 start()
#   stop                                              0xB2D14 stop()
#   emit (the NSTimer's selector)                     0xB2D54 _emit()
#     animations block                                0xB334C
#     completion block (removeFromSuperview if done)  0xB3498
#   getNextFrameIndex                                 0xB34C8 _get_next_frame_index()
#   setTint: (synthesized setter, ivar +124)          0xB3580 set_tint()
#
# ivar offsets (instance size 132): _currentFrameIndex 52, _options 56,
# _interval 60, _duration 64, _repeat 68, _random 69, _center 72,
# _startAlpha 80, _endAlpha 84, _startScale 88, _endScale 92,
# _start/_end X/Y variance 96..108, totalFramePlayed 112, readyToEmit 116,
# particles 120, tint 124, emitTimer 128. (The animation block reads +84,
# +88 and +92, which pins those three.)
#
# The GL engine (ParticleEmitter + the eleven *GLFXView classes) is NOT
# ported: no nib, class reference, property type or NSClassFromString string
# reaches any GLFXView in v1.27.
#
# Coordinates: this node's origin is the emitter view's bounds origin (UIKit
# top-left). `view_size` is the emitter's frame size; the original reads
# `self.frame.size` at each emit. Attach it as a child of the screen's nib
# outlet node (generated scenes place that Node2D at the frame origin), or of
# whatever view the original added it to.

extends Node2D

const TintOverlay := preload("res://core/particles/TintOverlay.gd")
const _SELF_PATH := "res://core/particles/SSEmitter.gd"

## +[NSTimer scheduledTimerWithTimeInterval:...]: "If seconds is less than or
## equal to 0.0, this method chooses the nonnegative value of 0.1
## milliseconds instead." (Foundation reference.) Reached by an emitter that
## is started before it was ever configured (the stir screens' spoon tip
## without a mixer): interval 0.
const NSTIMER_MIN_INTERVAL := 0.0001

## UIViewAnimationOptions curve field, bits 16..19 (UIKit enum):
## 0 EaseInOut, 1 EaseIn, 2 EaseOut, 3 Linear. Every call site in v1.27
## passes options 1, 2 or 3 -- LayoutSubviews / AllowUserInteraction bits
## only -- so every particle animates ease-in-out.
const CURVE_EASE_IN_OUT := 0
const CURVE_EASE_IN := 1
const CURVE_EASE_OUT := 2
const CURVE_LINEAR := 3

# -- the ivars --------------------------------------------------------------

## The emitter view's frame size (UIKit points). emit centres each new
## particle on view_size / 2; set_particles_final_offset adds it too.
var view_size := Vector2.ZERO

var particles: Array = []           # image names, e.g. "Grinding_Snow_PS_1.png"
var tint: Variant = null            # Color, or null for a plain UIImageView
var random := false
var interval := 0.0
var duration := 0.0
var repeat := false
var center := Vector2.ZERO          # _center: where particles fly TO (local)
var start_alpha := 0.0
var end_alpha := 0.0
var start_scale := 0.0
var end_scale := 0.0
var start_x_variance := 0
var start_y_variance := 0
var end_x_variance := 0
var end_y_variance := 0
var options := 0
var current_frame_index := -1
var total_frame_played := 0
var ready_to_emit := false

## arc4random() stand-in. Seed it for reproducible tests.
var rng := RandomNumberGenerator.new()

## When false, _process does nothing and the owner calls advance() itself
## (a test can step emitters deterministically this way).
var auto_advance := true

# -- NSTimer emulation --------------------------------------------------------
# A repeating NSTimer fires at origin + k * interval. On the device the main
# run loop wakes for each firing (iOS 6 has no timer coalescing), so a 0.01 s
# emitter really spawns at 100 Hz even though the screen refreshes at 60.
# INFERRED: the port therefore fires once per elapsed scheduled time -- not
# once per PC frame -- and back-dates each particle to its firing time, so a
# frame that covers two firings yields two particles at the right ages. If
# the device's main thread fell behind, NSTimer would skip missed firings;
# that load-dependent case is not reproduced.
var _timer_running := false
var _timer_origin := 0.0
var _timer_interval := 0.0
var _fire_index := 0
var _clock := 0.0

## Live particles in subview order (oldest first, newest drawn on top).
var _live: Array[Dictionary] = []

## Port-only diagnostics for tests: total particles ever emitted, and the
## firing times of the timer.
var emitted_total := 0

static var _textures := {}


# -- construction ---------------------------------------------------------------

## Create an emitter as a child of `host`, at `at` in host-local coordinates,
## for an emitter view of frame size `size`. For a nib SSEmitter pass the
## outlet node (already at the frame origin) and the nib frame size; for the
## stir screens' spoon tip, see core/StirTool.gd (tip_emitter).
static func attach(host: Node, size: Vector2, at := Vector2.ZERO) -> Node2D:
	var e: Node2D = load(_SELF_PATH).new()
	e.set("view_size", size)
	e.position = at
	e.name = "SSEmitter"
	host.add_child(e)
	return e


func _init() -> void:
	ready_to_emit = false             # -[SSEmitter init] 0xB2728


# -- configuration ----------------------------------------------------------------

## setParticles:...finalCenter:... (0xB2768). `final_center` is in the
## emitter's own coordinates.
func set_particles(p_particles: Array, p_tint: Variant, p_random: bool,
		p_interval: float, p_duration: float, p_repeat: bool,
		final_center: Vector2, p_start_alpha: float, final_alpha: float,
		p_start_scale: float, final_scale: float, p_start_x_variance: int,
		p_start_y_variance: int, p_end_x_variance: int, p_end_y_variance: int,
		p_options: int) -> void:
	particles = p_particles.duplicate()
	tint = p_tint
	interval = p_interval
	duration = p_duration
	repeat = p_repeat
	random = p_random
	center = final_center
	_finish_setup(p_start_alpha, final_alpha, p_start_scale, final_scale,
		p_start_x_variance, p_start_y_variance, p_end_x_variance,
		p_end_y_variance, p_options)


## setParticles:...finalOffset:... (0xB294C): _center = offset + frame.size/2,
## read from the frame at configuration time.
func set_particles_final_offset(p_particles: Array, p_tint: Variant,
		p_random: bool, p_interval: float, p_duration: float, p_repeat: bool,
		final_offset: Vector2, p_start_alpha: float, final_alpha: float,
		p_start_scale: float, final_scale: float, p_start_x_variance: int,
		p_start_y_variance: int, p_end_x_variance: int, p_end_y_variance: int,
		p_options: int) -> void:
	particles = p_particles.duplicate()
	tint = p_tint
	interval = p_interval
	duration = p_duration
	repeat = p_repeat
	random = p_random
	center = final_offset + view_size * 0.5
	_finish_setup(p_start_alpha, final_alpha, p_start_scale, final_scale,
		p_start_x_variance, p_start_y_variance, p_end_x_variance,
		p_end_y_variance, p_options)


func _finish_setup(a0: float, a1: float, s0: float, s1: float, sxv: int,
		syv: int, exv: int, eyv: int, opts: int) -> void:
	start_alpha = a0
	end_alpha = a1
	start_scale = s0
	end_scale = s1
	start_x_variance = sxv
	start_y_variance = syv
	end_x_variance = exv
	end_y_variance = eyv
	options = opts
	# (systemVersion < "5.0" forces options = 3 -- the target is iOS 6.)
	current_frame_index = -1
	total_frame_played = 0
	if start_scale < 0.01:
		start_scale = 0.01
	ready_to_emit = true


## setTint: -- the next emitted particles use it; live ones keep theirs.
func set_tint(p_tint: Variant) -> void:
	tint = p_tint


# -- start / stop ---------------------------------------------------------------

## start (0xB2C80): schedule a repeating timer unless one is running. The
## first firing is one interval from now.
func start() -> void:
	if _timer_running:
		return
	_timer_running = true
	_timer_interval = interval if interval > 0.0 else NSTIMER_MIN_INTERVAL
	_timer_origin = _clock
	_fire_index = 0


## stop (0xB2D14): invalidate the timer. Live particles finish their
## animations; totalFramePlayed and _currentFrameIndex are NOT reset.
func stop() -> void:
	_timer_running = false


func is_emitting() -> bool:
	return _timer_running


# -- time ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if auto_advance:
		advance(delta)


## Advance the emitter's clock by `dt` seconds: fire the timer for every
## scheduled time passed, then retire particles whose animation completed.
func advance(dt: float) -> void:
	var target := _clock + dt
	while _timer_running:
		var fire_at := _timer_origin + _timer_interval * float(_fire_index + 1)
		if fire_at > target + 1e-9:
			break
		_clock = maxf(_clock, fire_at)
		_fire_index += 1
		_emit()
	_clock = target
	var i := 0
	while i < _live.size():
		var p: Dictionary = _live[i]
		if _clock - float(p.born) >= float(p.dur) - 1e-9:
			_live.remove_at(i)       # completion: removeFromSuperview (0xB3498)
		else:
			i += 1
	queue_redraw()


func clock() -> float:
	return _clock


# -- emit (0xB2D54) -------------------------------------------------------------

func _emit() -> void:
	# Non-repeating: play each image once, then the timer kills itself.
	if not repeat:
		if total_frame_played >= particles.size():
			if _timer_running:
				_timer_running = false
				total_frame_played = 0
				return
		else:
			total_frame_played += 1

	var index: int
	if random:
		if particles.is_empty():
			return                    # arc4random() % 0 -- unreachable in v1.27
		index = int(rng.randi() % particles.size())
	else:
		index = _get_next_frame_index()
		if index < 0:
			return                    # objectAtIndex:-1 -- unreachable in v1.27
	var image_name: String = str(particles[index])

	var tex := _texture(image_name)
	if tint is Color and tex != null:
		tex = TintOverlay.bake(tex, tint)

	# setCenter:(frame.w/2, frame.h/2), then the variances (each draws an
	# arc4random only when its variance >= 1, in this order).
	var from := view_size * 0.5
	var to := center
	if start_x_variance >= 1:
		from.x += float(start_x_variance) * 0.5 \
			- float(rng.randi() % start_x_variance + 1)
	if start_y_variance >= 1:
		from.y += float(start_y_variance) * 0.5 \
			- float(rng.randi() % start_y_variance + 1)
	if end_x_variance >= 1:
		to.x += float(end_x_variance) * 0.5 \
			- float(rng.randi() % end_x_variance + 1)
	if end_y_variance >= 1:
		to.y += float(end_y_variance) * 0.5 \
			- float(rng.randi() % end_y_variance + 1)
	if end_y_variance == -1:
		to.y = from.y
	if end_x_variance == -1:
		to.x = from.x

	# setAlpha:startAlpha, transform = scale(startScale), addSubview: (on top),
	# then animateWithDuration:_duration options:_options -- the block (0xB334C)
	# sets transform *= scale(endScale / startScale), alpha endAlpha, centre
	# `to`. All endpoints are captured now, as the block runs synchronously.
	_live.append({
		"tex": tex,
		"name": image_name,
		"frame": index,
		"born": _clock,
		"dur": duration,
		"from": from,
		"to": to,
		"a0": start_alpha,
		"a1": end_alpha,
		"s0": start_scale,
		"s1": start_scale * (end_scale / start_scale),
		"curve": (options >> 16) & 0xF,
	})
	emitted_total += 1


## getNextFrameIndex (0xB34C8): 0, 1, ..., n-1, 0, ...; -1 with no particles.
func _get_next_frame_index() -> int:
	if particles.is_empty():
		return -1
	var r := 0
	if current_frame_index > -1 and current_frame_index + 1 < particles.size():
		r = current_frame_index + 1
	current_frame_index = r
	return r


static func _texture(file: String) -> Texture2D:
	if _textures.has(file):
		return _textures[file]
	var t: Texture2D = Assets.texture(file)
	_textures[file] = t
	return t


# -- drawing --------------------------------------------------------------------

## Core Animation's named timing curves (cubic beziers through (0,0) and
## (1,1)); UIViewAnimationCurveEaseInOut is (0.42,0)-(0.58,1).
static func ui_ease(t: float, curve: int) -> float:
	match curve:
		CURVE_EASE_IN:
			return _media_timing(t, 0.42, 0.0, 1.0, 1.0)
		CURVE_EASE_OUT:
			return _media_timing(t, 0.0, 0.0, 0.58, 1.0)
		CURVE_LINEAR:
			return clampf(t, 0.0, 1.0)
		_:
			return _media_timing(t, 0.42, 0.0, 0.58, 1.0)


static func _media_timing(t: float, x1: float, y1: float, x2: float,
		y2: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	var lo := 0.0
	var hi := 1.0
	for i in 32:
		var mid := (lo + hi) * 0.5
		if _bezier1d(mid, x1, x2) < t:
			lo = mid
		else:
			hi = mid
	return _bezier1d((lo + hi) * 0.5, y1, y2)


static func _bezier1d(s: float, a: float, b: float) -> float:
	var v := 1.0 - s
	return 3.0 * v * v * s * a + 3.0 * v * s * s * b + s * s * s


## Presentation state of live particle `i` at the current clock.
func particle_state(i: int) -> Dictionary:
	var p: Dictionary = _live[i]
	var dur := float(p.dur)
	var age := _clock - float(p.born)
	var u := 1.0 if dur <= 0.0 else ui_ease(age / dur, int(p.curve))
	return {
		"position": (p.from as Vector2).lerp(p.to, u),
		"alpha": lerpf(p.a0, p.a1, u),
		"scale": lerpf(p.s0, p.s1, u),
		"texture": p.tex,
		"name": p.name,
		"frame": p.frame,
		"born": p.born,
		"from": p.from,
		"to": p.to,
		"age": age,
	}


func live_count() -> int:
	return _live.size()


func _draw() -> void:
	for i in _live.size():
		var st := particle_state(i)
		var tex: Texture2D = st.texture
		if tex == null:
			continue                  # imageNamed: nil -> an empty image view
		var s: float = st.scale
		draw_set_transform(st.position, 0.0, Vector2(s, s))
		draw_texture(tex, -tex.get_size() * 0.5,
			Color(1, 1, 1, clampf(st.alpha, 0.0, 1.0)))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
