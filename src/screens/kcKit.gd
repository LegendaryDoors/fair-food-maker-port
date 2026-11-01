# Kettle Corn shared timing / path / sound helpers.
#
# Not a screen: no scene is named kcKit, so Nav never attaches it. The four
# kc screens preload it (kcPourOilViewController.gd keeps the older shared
# helpers -- MaskedIV, bake_tint, OilBubbler -- that other foods borrow).
# Every helper here stands for a platform behaviour the kc screens rely on;
# the reading behind each is in its block.

extends RefCounted


# ======================================================================
# UIViewAnimationCurve timing.
#
# +[UIView setAnimationCurve:] takes 0 EaseInOut, 1 EaseIn, 2 EaseOut,
# 3 Linear. They are Core Animation's named media timing functions, cubic
# beziers through (0,0) and (1,1) with control points (0.42,0)-(0.58,1),
# (0.42,0)-(1,1) and (0,0)-(0.58,1). The kc screens used to approximate them
# with Tween.TRANS_SINE; ui_curve() gives a PropertyTweener interpolator
# with the real curve:
#     t.tween_property(n, "position", to, 0.5) \
#         .set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_IN))
# ======================================================================

const UI_EASE_IN_OUT := 0
const UI_EASE_IN := 1
const UI_EASE_OUT := 2
const UI_LINEAR := 3


static func ui_ease(t: float, curve: int) -> float:
	match curve:
		UI_EASE_IN:
			return _media_timing(t, 0.42, 0.0, 1.0, 1.0)
		UI_EASE_OUT:
			return _media_timing(t, 0.0, 0.0, 0.58, 1.0)
		UI_LINEAR:
			return clampf(t, 0.0, 1.0)
		_:
			return _media_timing(t, 0.42, 0.0, 0.58, 1.0)


static func ui_curve(curve: int) -> Callable:
	return func(t: float) -> float: return ui_ease(t, curve)


## Solve x(s) = t on the timing bezier by bisection, return y(s).
static func _media_timing(t: float, x1: float, y1: float, x2: float,
		y2: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	var lo := 0.0
	var hi := 1.0
	var s := t
	for i in 24:
		s = (lo + hi) * 0.5
		if _bezier1d(s, x1, x2) < t:
			lo = s
		else:
			hi = s
	return _bezier1d(s, y1, y2)


static func _bezier1d(s: float, a: float, b: float) -> float:
	var v := 1.0 - s
	return 3.0 * v * v * s * a + 3.0 * v * s * s * b + s * s * s


# ======================================================================
# kCAAnimationPaced along one bezier segment.
#
# A CAKeyframeAnimation with a path and calculationMode kCAAnimationPaced
# moves at constant speed along the path: the time fraction maps to a
# fraction of ARC LENGTH, not of the curve parameter. kcPourOil's kernelTick
# (0x105724) and kcShakeToColor's popcornTick (0x113A44) both use it, so the
# port walks a cumulative-length table instead of the raw parameter it used
# before (the timing function is the keyframe default, linear).
# ======================================================================

class PacedCubic:
	extends RefCounted

	const SAMPLES := 64

	var p0: Vector2
	var c1: Vector2
	var c2: Vector2
	var p3: Vector2
	var _len := PackedFloat32Array()

	func _init(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> void:
		p0 = a
		c1 = b
		c2 = c
		p3 = d
		_len.resize(SAMPLES + 1)
		_len[0] = 0.0
		var prev := p0
		for i in range(1, SAMPLES + 1):
			var q := point(float(i) / SAMPLES)
			_len[i] = _len[i - 1] + prev.distance_to(q)
			prev = q

	## The curve at parameter s.
	func point(s: float) -> Vector2:
		var v := 1.0 - s
		return p0 * v * v * v + c1 * 3.0 * v * v * s + c2 * 3.0 * v * s * s \
			+ p3 * s * s * s

	## The point a fraction u of the way along the curve's LENGTH.
	func at(u: float) -> Vector2:
		var total: float = _len[SAMPLES]
		if total <= 0.0:
			return p3 if u >= 1.0 else p0
		var target := clampf(u, 0.0, 1.0) * total
		var i := 1
		while i < SAMPLES and _len[i] < target:
			i += 1
		var seg: float = _len[i] - _len[i - 1]
		var f := 0.0 if seg <= 0.0 else (target - _len[i - 1]) / seg
		return point((float(i - 1) + f) / SAMPLES)


## CGPathAddQuadCurveToPoint as the equivalent cubic.
static func paced_quad(a: Vector2, cp: Vector2, b: Vector2) -> PacedCubic:
	return PacedCubic.new(a, a + (cp - a) * (2.0 / 3.0),
		b + (cp - b) * (2.0 / 3.0), b)


# ======================================================================
# float32 accumulators.
#
# pourTime is an ObjC `float` ivar and the step 0.1f is not exact. Summed in
# float32, forty steps reach 3.9999983 -- still < 4.0 -- so the original
# needs FORTY-ONE kernels / sugar ticks before `>= 4.0` holds, and the pile
# rises on forty of them (kcPourOil 0x105BC8, kcSelectSugar 0x10F784). In
# GDScript's doubles forty steps reach 4.000000000000002, which ended the
# pour one tick early and dropped the pile's last rise. f32() rounds a value
# to float32 like the original's arithmetic.
# ======================================================================

static func f32(x: float) -> float:
	var a := PackedFloat32Array([x])
	return a[0]


# ======================================================================
# Sounds the original screens own.
#
# The kc screens keep their own AVAudioPlayers next to AudioManager:
#   * five pre-loaded players (kcPourOil viewWillAppear 0x104B88: kernel_01..
#     04 + kernels_02; kcShakeToColor 0x111778: pop_01..04 + pop_01). Each
#     landing / pop plays the FIRST player that is not playing; when all five
#     are busy it calls play on player1, a no-op on a playing AVAudioPlayer;
#     skipped while AudioManager is muted (0x105BC8, 0x113A44). SoundBank.
#   * AudioManager's own semantics (0xE873C): playFile/loopFile make a NEW
#     player per call and file it under the name, stopPlayerForFile: stops
#     that newest one, and loopFile returns nil (no player at all) while
#     muted. kcShakeToColor reaches into playerDict to pause / resume its
#     popcorn_01 loop and stops shake_01 mid-sound; the flatten screen stops
#     and restarts slide_02. The shared Audio autoload has no pause and
#     cannot stop a one-shot, so those screens hold a player of their own
#     (make_player) for those files.
# ======================================================================

## Audio._find's lookup (Assets.audio).
static func find_stream(basename: String) -> AudioStream:
	return SoundBank.stream_for(basename)


## An AudioStreamPlayer owned by `owner`; `looped` duplicates the stream so
## the loop flag never leaks into other users of the shared resource.
static func make_player(owner: Node, basename: String, looped := false,
		volume := 1.0) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	var s := find_stream(basename)
	if s != null and looped:
		s = s.duplicate()
		Assets.enable_loop(s)
	p.stream = s
	p.volume_db = linear_to_db(volume)
	owner.add_child(p)
	return p


class SoundBank:
	extends Node

	var _players: Array[AudioStreamPlayer] = []

	static func stream_for(basename: String) -> AudioStream:
		return Assets.audio(basename)

	func _init(names: Array) -> void:
		for n in names:
			var p := AudioStreamPlayer.new()
			p.stream = stream_for(str(n))
			_players.append(p)
			add_child(p)

	func play_first_idle() -> void:
		if Audio.muted:
			return
		for p in _players:
			if not p.playing:
				p.play()
				return

	func stop_all() -> void:
		for p in _players:
			p.stop()


# ======================================================================
# Keep-state under a push. Shared by the four kc
# screens AND the five ip screens (both foods preload this file).
#
# UINavigationController keeps a covered controller alive; the port's Nav
# does the same for a screen whose keeps_state_on_push() is true: on_exit()
# on the push, the same instance re-added and on_resume() on the pop. Two
# platform differences need bridging, and these helpers do it:
#
#   * Core Animation applies a UIView animation's MODEL values when the
#     block is committed and finishes the presentation on its own, covered
#     or not -- a view pushed under mid-animation is found at its end values
#     on return, completion handlers run. Godot pauses node-bound tweens
#     while the node is out of the tree and resumes them on return, where
#     they would fight the viewWillAppear: resets. Screens create their
#     tweens through track() and call settle() from on_exit().
#   * AppDelegate navigationController:didShowViewController:animated:
#     (0x1AC3C) MOVES the one coins panel onto each shown screen. CoinHUD
#     builds a new one per appearance, so a resumed screen would show two
#     stacked panels; drop_coin_panel() removes the old one first (on_resume
#     runs before Nav emits screen_changed). Harmless if CoinHUD ever dedupes
#     itself.
# ======================================================================

## Register `tw` in `list` (dropping finished ones) and return it.
static func track(list: Array, tw: Tween) -> Tween:
	var i := 0
	while i < list.size():
		var t: Variant = list[i]
		if t is Tween and (t as Tween).is_valid():
			i += 1
		else:
			list.remove_at(i)
	list.append(tw)
	return tw


## Run every tracked tween to its end (callbacks included, so flights land
## and their views are removed), then drop them. A callback may start a new
## tracked tween (a chained UIView animation); those are settled too.
static func settle(list: Array) -> void:
	for _pass in 8:
		if list.is_empty():
			return
		var batch := list.duplicate()
		list.clear()
		for t: Variant in batch:
			if t is Tween and (t as Tween).is_valid():
				(t as Tween).custom_step(1.0e6)
				(t as Tween).kill()


## A +beginAnimations:/commitAnimations move of a DraggableSprite2D's centre
## on one of the UIView curves above, tracked like any other tween.
## DraggableSprite2D.animate_position()
## carries UIKit's touch semantics for such a move -- the view stays
## touchable, hit-tested at its MODEL (destination) position, and a grab
## lands it there and hands it to the drag -- but its MethodTweener takes
## only Godot's trans/ease, not a custom interpolator. So it runs linearly
## over 1 s inside a PAUSED tween, and a tracked outer tween steps that one
## along the real curve. settle() finishes the outer tween, which finishes
## the inner one.
static func animate_draggable(list: Array, host: Node, s: Node2D, to: Vector2,
		seconds: float, curve: int) -> Tween:
	var inner := host.create_tween()
	inner.pause()
	s.call("animate_position", inner, to, 1.0)
	var at := [0.0]
	var outer := track(list, host.create_tween())
	outer.tween_method(func(u: float) -> void:
		if not inner.is_valid():
			return
		if u >= 1.0:
			inner.custom_step(2.0)        # past the end: lands exactly on `to`
			return
		var t := ui_ease(u, curve)
		if t > at[0]:
			inner.custom_step(t - at[0])
			at[0] = t, 0.0, 1.0, seconds)
	return outer


## The coins panel CoinHUD added on the previous appearance.
static func drop_coin_panel(screen: Node) -> void:
	var old := screen.get_node_or_null("CoinInfoView")
	if old != null:
		screen.remove_child(old)
		old.queue_free()
