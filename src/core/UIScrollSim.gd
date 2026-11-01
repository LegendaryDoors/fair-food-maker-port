# iOS 6 UIScrollView physics, read out of UIKit itself (iPhone 4, iOS 6.1.3,
# dyld_shared_cache_armv7, UIKit image at 0x32F2F000). Every constant below
# names the method it was read from.
#
# Units are UIKit's: offsets in points, velocities in points per MILLISECOND
# (the scroll view divides the pan recognizer's points/second by 1000), and
# deceleration factors per millisecond.
#
# This file is a library for the port's scroll views. Load it with
# preload(); `class_name` does not work in this project.
#
#     const UIScrollSim := preload("res://core/UIScrollSim.gd")
#     var axis := UIScrollSim.ScrollAxis.new()
#
# It also carries the UIView animation curves (cubic beziers read from UIKit's
# GetAnimationCurveSpline table), which Screen.gd and Nav.gd use.

extends RefCounted

# -- UIView animation curves --------------------------------------------
# GetAnimationCurveSpline (0x32FB67D0) builds a CAMediaTimingFunction from
# GetAnimationCurveSpline.__cubicCurveControlPoints (0x33481244), indexed by
# UIViewAnimationCurve. +[UIViewAnimationState pushViewAnimationState:context:]
# (0x32F46FD8) leaves the curve 0 (EaseInOut) and the duration 0.2 s unless
# the caller sets them.
enum AnimCurve { EASE_IN_OUT, EASE_IN, EASE_OUT, LINEAR }
const CURVE_POINTS := {
	AnimCurve.EASE_IN_OUT: [0.42, 0.0, 0.58, 1.0],
	AnimCurve.EASE_IN: [0.42, 0.0, 1.0, 1.0],
	AnimCurve.EASE_OUT: [0.0, 0.0, 0.58, 1.0],
	AnimCurve.LINEAR: [0.0, 0.0, 1.0, 1.0],
}
const DEFAULT_ANIMATION_DURATION := 0.2


## Progress (0..1) of a UIView animation `t` (0..1) of the way through.
static func curve(t: float, which: int = AnimCurve.EASE_IN_OUT) -> float:
	var p: Array = CURVE_POINTS[which]
	return cubic_bezier(clampf(t, 0.0, 1.0), p[0], p[1], p[2], p[3])


## CAMediaTimingFunction evaluation: solve x(s) = t, return y(s).
static func cubic_bezier(t: float, x1: float, y1: float, x2: float, y2: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	# Newton, falling back to bisection; x(s) is monotonic for these points.
	var s := t
	for i in 8:
		var x := _bez(s, x1, x2) - t
		if absf(x) < 1e-6:
			return _bez(s, y1, y2)
		var d := _bez_d(s, x1, x2)
		if absf(d) < 1e-6:
			break
		s -= x / d
	var lo := 0.0
	var hi := 1.0
	s = t
	for i in 40:
		var x := _bez(s, x1, x2)
		if absf(x - t) < 1e-7:
			break
		if x < t:
			lo = s
		else:
			hi = s
		s = (lo + hi) * 0.5
	return _bez(s, y1, y2)


static func _bez(s: float, a: float, b: float) -> float:
	var u := 1.0 - s
	return 3.0 * u * u * s * a + 3.0 * u * s * s * b + s * s * s


static func _bez_d(s: float, a: float, b: float) -> float:
	var u := 1.0 - s
	return 3.0 * u * u * a + 6.0 * u * s * (b - a) + 3.0 * s * s * (1.0 - b)


# -- constants ----------------------------------------------------------

## UIScrollViewDecelerationRateNormal / Fast (exported floats 0x33481294 /
## 0x33481298). -setDecelerationRate: (0x33007EA4) snaps any rate below
## 0.994 to 0.99 and everything else to 0.998, for both axes.
const DECELERATION_RATE_NORMAL := 0.998
const DECELERATION_RATE_FAST := 0.99
const DECELERATION_RATE_SPLIT := 0.994

## _rubberBandOffsetForOffset:maxOffset:minOffset:range:outside: (0x3306FF98).
const RUBBER_BAND_COEFFICIENT := 0.55

## _getBouncingDecelerationOffset:... (0x33070AF0): outside the content the
## offset relaxes toward the edge by exp(-0.01005 * ms) (= 0.99 per ms) and
## the velocity is damped by the same factor on top of the deceleration.
const BOUNCE_LN_PER_MS := -0.01005
## ...and it is "back" once within half a point of the edge.
const OUTSIDE_TOLERANCE := 0.5

## _endPanWithEvent: (0x330543E0): below 0.25 pt/ms (|v|^2 < 0.0625) a
## release does not decelerate at all; 0.6 pt/ms (0.36) counts as a fast
## flick. Release velocity = 0.25 * current + 0.75 * previous update's.
const MIN_DECELERATION_SPEED_SQ := 0.0625
const FAST_FLICK_SPEED_SQ := 0.36
const RELEASE_VELOCITY_CURRENT_WEIGHT := 0.25

## _smoothScrollWithUpdateTime: (0x331214B0): steps shorter than 1 ms are
## skipped; deceleration ends when not bouncing and |v|^2 < 0.0001.
const MIN_STEP_MS := 1.0
const STOP_SPEED_SQ := 0.0001

## _getStandardDecelerationOffset:... (0x331213A8) and the bouncing variant
## use exp(x) only below -0.5 and 1 + x + x^2/2 above it.
const EXP_APPROX_LIMIT := -0.5

## The drag starts once the finger has moved 10 pt along a scrollable axis
## (_UIPanGestureRecognizerCommonInit 0x32F9CFF4 sets _hysteresis 10; the
## scroll view's own _hysteresis is 10 too, -initWithFrame: 0x32F9C250).
## -[UIScrollViewPanGestureRecognizer _hysteresis] (0x3306DB8C) returns 0
## when the touch caught a decelerating scroll view, so a grab is immediate.
## _removeHysteresisFromTranslation (0x3306DCAC) then takes the 10 pt back
## off the translation so the content does not jump.
const DRAG_HYSTERESIS := 10.0

## UIPanGestureRecognizer velocity (_centroidMovedTo:atTime: 0x3306CBA8):
## a new sample is taken only when more than 8 ms have passed since the last
## touch; velocityInView: (0x33009398) = 0.25 * newest + 0.75 * previous.
const VELOCITY_SAMPLE_MIN_DT := 0.008
const VELOCITY_SAMPLE_CURRENT_WEIGHT := 0.25

## Paging (_prepareToPageWithHorizontalVelocity:verticalVelocity: 0x33053CE8,
## _getPagingDecelerationOffset:forTimeInterval: 0x330C3788): a release faster
## than 0.3 pt/ms turns the page that way; slower rounds to the nearest page.
## The page then springs in, integrated once per millisecond:
##     v += (target - offset) * pull;  v *= friction;  offset += v
## with pull / friction depending on the page size (-initWithFrame:
## 0x32F9C250, -_defaultPagingFriction 0x3311E628). It snaps to the target
## once |v| < 0.01 and the rounded offset is within 5 pt and the last step
## moved at most 1 pt; a stall on the same pixel is nudged 1 pt along.
const PAGE_FLICK_SPEED := 0.3
const PAGE_SNAP_SPEED := 0.01
const PAGE_SNAP_DISTANCE := 5.0


static func paging_spring_pull(page_size: float) -> float:
	return page_size * -0.000000184659091 + 0.000359090909


static func paging_friction(page_size: float) -> float:
	return page_size * 0.00000994318182 + 0.966818182


## -setContentOffset:animated: duration (_contentOffsetAnimationDuration,
## initialised to 0.3 s in -initWithFrame: / -initWithCoder:).
const CONTENT_OFFSET_ANIMATION_DURATION := 0.3

## Scroll indicators (_adjustScrollerIndicators:alwaysShowingThem: 0x32FA08F0,
## CreateScrollIndicator 0x32FA1EA0, _hideScrollIndicators 0x32FB62CC):
## UIScrollerIndicatorDefault/Black/White.png, stretchable at half their
## size; length = max(36, visible fraction * track); 1 pt (default style) or
## 2 pt (black / white) in from the edge; fade out over 0.5 s.
const INDICATOR_MIN_LENGTH := 36.0
const INDICATOR_INSET_DEFAULT := 1.0
const INDICATOR_INSET_STYLED := 2.0
const INDICATOR_FADE := 0.5
const INDICATOR_FLASH_HOLD := 1.0


# -- equations ----------------------------------------------------------

static func normalized_deceleration_rate(rate: float) -> float:
	return DECELERATION_RATE_FAST if rate < DECELERATION_RATE_SPLIT else DECELERATION_RATE_NORMAL


## UIKit's exp(): exact below -0.5, second-order Taylor above.
static func uikit_exp(x: float) -> float:
	if x >= EXP_APPROX_LIMIT:
		return x * (x * 0.5 + 1.0) + 1.0
	return exp(x)


## Offset shown while dragging past an edge. `range` is the scroll view's
## size along the axis (bounds width or height).
static func rubber_band(offset: float, min_offset: float, max_offset: float, range_: float) -> float:
	var hi := maxf(max_offset, min_offset)
	if offset > hi:
		var f := 1.0 - 1.0 / ((offset - hi) / range_ * RUBBER_BAND_COEFFICIENT + 1.0)
		return hi + f * range_
	if offset < min_offset:
		var f := 1.0 - 1.0 / ((min_offset - offset) / range_ * RUBBER_BAND_COEFFICIENT + 1.0)
		return min_offset - f * range_
	return offset


## Inverse of rubber_band (_offsetForRubberBandOffset:maxOffset:minOffset:range:
## 0x33072148): the finger offset that produces a given shown offset.
static func offset_for_rubber_band(shown: float, min_offset: float, max_offset: float, range_: float) -> float:
	var hi := maxf(max_offset, min_offset)
	if shown > hi:
		var f := (shown - hi) / range_
		return hi + ((-1.0 / (f - 1.0)) - 1.0) / RUBBER_BAND_COEFFICIENT * range_
	if shown < min_offset:
		var f := (min_offset - shown) / range_
		return min_offset - ((-1.0 / (f - 1.0)) - 1.0) / RUBBER_BAND_COEFFICIENT * range_
	return shown


## Deceleration with bounce off (_getStandardDecelerationOffset:... 0x331213A8).
## Returns [offset, velocity]; hitting an edge clamps and zeroes the velocity.
static func standard_decelerate(offset: float, velocity: float, dt_ms: float,
		min_offset: float, max_offset: float, factor: float) -> Array:
	var hi := maxf(max_offset, min_offset)
	var ln := log(factor)
	var k := uikit_exp(ln * dt_ms)
	offset += velocity * ((1.0 - k) / (1.0 - factor) * factor)
	velocity *= k
	if offset < min_offset:
		return [min_offset, 0.0]
	if offset > hi:
		return [hi, 0.0]
	return [offset, velocity]


## Deceleration with bounce on (_getBouncingDecelerationOffset:... 0x33070AF0).
## `last_offset` is the offset at the previous step. Returns
## [offset, velocity, still_outside].
static func bouncing_decelerate(offset: float, last_offset: float, velocity: float,
		dt_ms: float, min_offset: float, max_offset: float, factor: float) -> Array:
	var hi := maxf(max_offset, min_offset)
	var ln := log(factor)
	var outside_ms := dt_ms
	if last_offset >= min_offset and last_offset <= hi:
		if absf(velocity) <= 0.0:
			outside_ms = 0.0
		else:
			var k := uikit_exp(ln * dt_ms)
			var travel := (1.0 - k) / (1.0 - factor) * factor
			var moved := offset + velocity * travel
			var inside_ms := dt_ms
			outside_ms = 0.0
			if moved < min_offset or moved > hi:
				# Linear estimate of when the edge was crossed.
				if moved >= min_offset:
					inside_ms = (hi - last_offset) * dt_ms / (moved - last_offset)
				else:
					inside_ms = (last_offset - min_offset) * dt_ms / (last_offset - moved)
				outside_ms = dt_ms - inside_ms
			offset = moved
			if inside_ms > 0.0:
				if inside_ms != dt_ms:
					k = uikit_exp(inside_ms * ln)
					travel = (1.0 - k) / (1.0 - factor) * factor
				offset = velocity * travel + last_offset
				velocity *= k
	if outside_ms > 0.0:
		var kd := uikit_exp(outside_ms * ln)
		var ks := uikit_exp(outside_ms * BOUNCE_LN_PER_MS)
		if offset >= min_offset:
			offset = hi + (offset - hi) * ks
		else:
			offset = (offset - min_offset) * ks + min_offset
		offset += ks * factor * velocity * (1.0 - kd) / (1.0 - factor)
		velocity *= kd * ks
	var outside := offset <= min_offset - OUTSIDE_TOLERANCE \
		or offset >= hi + OUTSIDE_TOLERANCE
	return [offset, velocity, outside]


## Where a free deceleration from `velocity` comes to rest (the target
## -_endPanWithEvent: hands to scrollViewWillEndDragging:withVelocity:
## targetContentOffset:): integrate until |v| reaches 0.01 pt/ms.
static func deceleration_target(offset: float, velocity: float, factor: float) -> float:
	var floor_v := 0.01 if velocity >= 0.0 else -0.01
	return offset - (velocity - floor_v) / log(factor)


## A delegate moved the target in scrollViewWillEndDragging:withVelocity:
## targetContentOffset: (the stick / cup pickers snap to an item there).
## -_endPanWithEvent: (0x330543E0) then re-aims the deceleration, per axis:
##  * target ahead of the motion (or v = 0): a new velocity that the normal
##    factor carries exactly there, v = s - ln(f) * d, with s = +-0.01; if
##    that is under 0.25 pt/ms the factor becomes 0.985 and v is recomputed;
##  * target behind the motion: keep v, factor = exp(-(v - s) / d), at most
##    0.999.
## d = target - offset. Returns [velocity, factor]; the run is then clamped
## with target_clamp_step() until it reaches the target.
static func aim_at_target(offset: float, velocity: float, target: float, factor: float) -> Array:
	var d := target - offset
	if absf(d) < 0.00000011920929:
		return [0.0, factor]
	var s := -0.01 if velocity < 0.0 else 0.01
	var behind: bool
	if velocity <= 0.0 and target < offset:
		behind = false
	elif velocity >= 0.0:
		behind = target <= offset
	else:
		behind = true
	if behind:
		return [velocity, minf(exp(-(velocity - s) / d), 0.999)]
	var v := s - log(factor) * d
	if absf(v) < 0.25:
		factor = 0.985
		v = s - log(factor) * d
	return [v, factor]


## _smoothScrollWithUpdateTime: (0x331214B0) with an aimed target: passing
## it snaps there and stops the axis; creeping slower than 0.01 pt/ms short
## of it keeps 0.01 pt/ms toward it (the doubles at 0x33122200/08).
## Returns [offset, velocity, reached].
static func target_clamp_step(offset: float, velocity: float, target: float) -> Array:
	if (velocity > 0.0 and offset >= target) or (velocity < 0.0 and offset <= target):
		return [target, 0.0, true]
	if absf(velocity) < 0.01 and offset != target:
		return [offset, -0.01 if offset >= target else 0.01, false]
	return [offset, velocity, offset == target]


## The page a release lands on (_prepareToPageWithHorizontalVelocity:...).
## `velocity` is the un-smoothed drag velocity (pt/ms, positive = toward
## larger offsets). `previous_target` (or NAN) is the page already being
## animated to: a second flick the same way adds a page to it.
static func page_target(offset: float, page_size: float, velocity: float,
		min_offset: float, max_offset: float, previous_target: float = NAN) -> float:
	if fmod(offset, page_size) == 0.0:
		return offset
	var t: float
	if velocity > PAGE_FLICK_SPEED:
		var base := previous_target + page_size if not is_nan(previous_target) else offset
		t = ceilf(base / page_size) * page_size
	elif velocity < -PAGE_FLICK_SPEED:
		var base := previous_target - page_size if not is_nan(previous_target) else offset
		t = floorf(base / page_size) * page_size
	else:
		t = page_size * floor(offset / page_size + 0.5)
	return maxf(min_offset, minf(max_offset, t))


## One paging step of `dt_ms` (integrated 1 ms at a time, as UIKit does).
## Returns [offset, velocity, done] -- `offset` already rounded to the pixel
## grid (`accuracy` 1 = whole points, UIKit's _accuracy).
static func paging_step(offset: float, velocity: float, target: float, dt_ms: float,
		page_size: float, accuracy: float = 1.0) -> Array:
	var pull := paging_spring_pull(page_size)
	var friction := paging_friction(page_size)
	var start := offset
	var last_delta := 0.0
	var n := int(dt_ms)
	if n <= 0:
		return [offset, velocity, false]
	for i in n:
		last_delta = target - offset
		velocity = (velocity + pull * last_delta) * friction
		offset += velocity
	var rounded := _round_to(offset, accuracy)
	if rounded != target and start == rounded and velocity < 0.5:
		rounded -= -1.0 if last_delta >= 0.0 else 1.0
	if absf(velocity) < PAGE_SNAP_SPEED and absf(last_delta) <= 1.0 \
			and absf(rounded - target) < PAGE_SNAP_DISTANCE:
		return [target, 0.0, true]
	# Passed the page while slower than 0.1 pt/ms: snap (the 0x400/0x800
	# direction flags in the same method).
	if signf(target - start) != 0.0 and signf(target - rounded) != signf(target - start) \
			and absf(velocity) < 0.1:
		return [target, 0.0, true]
	return [rounded, velocity, false]


static func _round_to(v: float, accuracy: float) -> float:
	if accuracy == 1.0:
		return roundf(v)
	var f := floorf(v)
	return f + roundf((v - f) * accuracy) / accuracy


# -- a one-axis scroll view ---------------------------------------------

## Drag -> release -> decelerate / bounce / page, for one axis, stepped by
## the caller. Feed it touch positions (in the scroll view's coordinates,
## along the axis) with timestamps in seconds; read `offset` every frame.
class ScrollAxis extends RefCounted:
	## The outer script, loaded at run time: an inner class cannot call the
	## outer static functions directly, and preloading its own file is a cycle.
	var _S: GDScript = load("res://core/UIScrollSim.gd")

	var offset := 0.0
	var min_offset := 0.0
	var max_offset := 0.0            ## contentSize - bounds size (+ insets)
	var range_ := 320.0              ## bounds size along the axis
	var bounces := true
	## alwaysBounceHorizontal/Vertical: drag (and rubber-band) even when the
	## content fits (ScrollableGridView sets the vertical one).
	var always_bounce := false
	var paging := false
	var page_size := 320.0
	var deceleration_rate := 0.998

	var dragging := false
	var decelerating := false
	var tracking := false
	## Emitted the moment UIKit would call scrollViewDidEndDecelerating:.
	signal did_end_decelerating
	signal will_begin_dragging
	signal did_end_dragging(will_decelerate: bool)

	var velocity := 0.0              ## pt/ms, + = offset increasing
	var _prev_velocity := 0.0
	var _start_touch := 0.0
	var _start_offset := 0.0
	var _hysteresis := 10.0
	var _last_touch := 0.0
	var _last_touch_time := -1.0
	var _sample := 0.0               ## pt/s, newest velocity sample
	var _prev_sample := 0.0
	var _prev_sample_valid := false
	var _last_offset := 0.0
	var _bouncing := false
	var _page_target := NAN
	## scrollViewWillEndDragging:withVelocity:targetContentOffset: --
	## func(velocity: float, proposed: float) -> float returning the target
	## (the stick / cup pickers snap to an item). Not used when paging.
	var will_end_dragging: Callable
	var _aim := NAN
	var _aim_factor := 0.0

	func set_deceleration_rate(rate: float) -> void:
		deceleration_rate = _S.normalized_deceleration_rate(rate)

	func touch_began(pos: float, t: float) -> void:
		tracking = true
		dragging = false
		_hysteresis = 0.0 if decelerating else _S.DRAG_HYSTERESIS
		if decelerating:
			decelerating = false
			_bouncing = false
		_start_touch = pos
		_last_touch = pos
		_last_touch_time = t
		_sample = 0.0
		_prev_sample = 0.0
		_prev_sample_valid = false
		velocity = 0.0
		_prev_velocity = 0.0

	func touch_moved(pos: float, t: float) -> void:
		if not tracking:
			return
		if t - _last_touch_time > _S.VELOCITY_SAMPLE_MIN_DT:
			_prev_sample = _sample
			_prev_sample_valid = true
			_sample = (pos - _last_touch) / (t - _last_touch_time)
			_last_touch = pos
			_last_touch_time = t
		var translation := pos - _start_touch
		if not dragging:
			# _canScrollX/Y: content larger than the view, or alwaysBounce.
			var can_scroll := max_offset > min_offset or always_bounce
			if absf(translation) < _hysteresis or not can_scroll:
				return
			dragging = true
			_start_offset = offset
			# Caught mid-bounce: the shown offset is rubber-banded, so start
			# the drag from the offset that maps to it (the inverse,
			# _offsetForRubberBandOffset: 0x33072148) -- else the view jumps
			# by the band's compression on the first move.
			var hi_now := maxf(max_offset, min_offset)
			if bounces and (offset < min_offset or offset > hi_now):
				_start_offset = _S.offset_for_rubber_band(offset, min_offset, max_offset, range_)
			# _removeHysteresisFromTranslation: start from where the finger
			# crossed the threshold, not where it went down.
			_start_touch += _hysteresis * signf(translation)
			translation = pos - _start_touch
			will_begin_dragging.emit()
		var pan_velocity := _sample
		if _prev_sample_valid:
			pan_velocity = _sample * _S.VELOCITY_SAMPLE_CURRENT_WEIGHT \
				+ _prev_sample * (1.0 - _S.VELOCITY_SAMPLE_CURRENT_WEIGHT)
		_prev_velocity = velocity
		velocity = -pan_velocity / 1000.0
		var want := _start_offset - translation
		if bounces:
			offset = _S.rubber_band(want, min_offset, max_offset, range_)
		else:
			offset = clampf(want, min_offset, maxf(max_offset, min_offset))

	func touch_ended(t: float) -> void:
		if not tracking:
			return
		tracking = false
		if not dragging:
			# A touch that caught a bouncing view and lifted without dragging
			# must not leave it parked past the edge: it springs back with the
			# bounce run (INFERRED: UIKit's touch-up path re-runs the snap-back;
			# the exact call was not read). Inside the bounds a tap just stops it.
			var hi_e := maxf(max_offset, min_offset)
			if bounces and (offset < min_offset or offset > hi_e):
				velocity = 0.0
				decelerating = true
				_last_offset = offset
			return
		dragging = false
		var raw_velocity := velocity
		if _prev_velocity != 0.0:
			velocity = velocity * _S.RELEASE_VELOCITY_CURRENT_WEIGHT \
				+ _prev_velocity * (1.0 - _S.RELEASE_VELOCITY_CURRENT_WEIGHT)
		var hi := maxf(max_offset, min_offset)
		var outside := offset < min_offset or offset > hi
		var will := false
		if paging:
			_page_target = _S.page_target(offset, page_size, raw_velocity, min_offset, hi,
				_page_target if decelerating else NAN)
			will = offset != _page_target
		elif outside:
			will = true
		elif velocity * velocity < _S.MIN_DECELERATION_SPEED_SQ:
			velocity = 0.0
		else:
			will = true
		_aim = NAN
		if not paging and not outside and will_end_dragging.is_valid():
			# The proposed target: where a free run stops, inside the content.
			var proposed := offset
			if will:
				proposed = roundf(clampf(_S.deceleration_target(offset, velocity,
					deceleration_rate), min_offset, hi))
			var target: float = will_end_dragging.call(velocity, proposed)
			# Re-aimed only when the delegate MOVED the target: -_endPanWithEvent:
			# (0x330543E0) compares it with the proposed one (v123) and leaves
			# the free (bouncing) run alone when it is unchanged -- an empty
			# delegate (StandSelect's 0x2FFD0) changes nothing. (Fixed;
			# this used to aim every decelerating release, which also stopped a
			# flick dead at the content edge instead of bouncing.)
			if target != proposed:
				var r: Array = _S.aim_at_target(offset, velocity, target, deceleration_rate)
				velocity = r[0]
				_aim_factor = r[1]
				_aim = target
				will = offset != target
		did_end_dragging.emit(will)
		if will:
			decelerating = true
			_last_offset = offset
		elif paging:
			_page_target = NAN

	## Advance by `dt` seconds. Returns true while still moving.
	func step(dt: float) -> bool:
		if not decelerating:
			return false
		var ms := dt * 1000.0
		if ms < _S.MIN_STEP_MS:
			return true
		var done := false
		if paging:
			var r: Array = _S.paging_step(offset, velocity, _page_target, ms, page_size)
			offset = r[0]
			velocity = r[1]
			done = r[2]
			if done:
				_page_target = NAN
		else:
			var hi := maxf(max_offset, min_offset)
			var factor := deceleration_rate if is_nan(_aim) else _aim_factor
			if bounces:
				var r: Array = _S.bouncing_decelerate(offset, _last_offset, velocity, ms,
					min_offset, hi, factor)
				offset = r[0]
				velocity = r[1]
				_bouncing = r[2]
			elif absf(velocity) > 0.0:
				var r: Array = _S.standard_decelerate(offset, velocity, ms, min_offset, hi,
					factor)
				offset = r[0]
				velocity = r[1]
			if not is_nan(_aim) and not _bouncing:
				var r: Array = _S.target_clamp_step(offset, velocity, _aim)
				offset = r[0]
				velocity = r[1]
				if r[2]:
					_aim = NAN
			done = not _bouncing and velocity * velocity < _S.STOP_SPEED_SQ \
				and is_nan(_aim)
			if done and bounces:
				offset = clampf(offset, min_offset, hi)
		_last_offset = offset
		if done:
			decelerating = false
			velocity = 0.0
			did_end_decelerating.emit()
		return not done
