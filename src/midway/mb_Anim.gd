# Core Animation timing helpers for the Milk Bottle midway game.
#
# The game drives everything through UIView animation blocks and
# CAKeyframeAnimations on CGPaths, so the port needs the exact UIKit timing
# curves and path evaluation those use. Static functions only; preload this
# file (class_name does not work in this project).
#
#   UIViewAnimationCurve      CAMediaTimingFunction control points
#   0 EaseInOut               (0.42, 0, 0.58, 1)
#   1 EaseIn                  (0.42, 0, 1, 1)
#   2 EaseOut                 (0, 0, 0.58, 1)
#   3 Linear                  --
#
# These are Core Animation's published constants, not read from this binary.

extends RefCounted

const CURVE_EASE_IN_OUT := 0
const CURVE_EASE_IN := 1
const CURVE_EASE_OUT := 2
const CURVE_LINEAR := 3

const _CONTROL := {
	0: Vector4(0.42, 0.0, 0.58, 1.0),
	1: Vector4(0.42, 0.0, 1.0, 1.0),
	2: Vector4(0.0, 0.0, 0.58, 1.0),
}

## Samples used to build a kCAAnimationPaced arc-length table.
const PACED_SAMPLES := 64


## Progress (0..1) of a UIView animation with curve `kind` at linear time `u`.
static func curve(u: float, kind: int) -> float:
	u = clampf(u, 0.0, 1.0)
	if not _CONTROL.has(kind):
		return u
	var p: Vector4 = _CONTROL[kind]
	# Solve x(t) = u on the cubic Bezier by bisection, then return y(t).
	var lo := 0.0
	var hi := 1.0
	var t := u
	for i in 40:
		var x := _bez(t, p.x, p.z)
		if absf(x - u) < 1e-6:
			break
		if x < u:
			lo = t
		else:
			hi = t
		t = (lo + hi) * 0.5
	return _bez(t, p.y, p.w)


static func _bez(t: float, a: float, b: float) -> float:
	var mt := 1.0 - t
	return 3.0 * mt * mt * t * a + 3.0 * mt * t * t * b + t * t * t


## CGPathMoveToPoint(p0) + CGPathAddQuadCurveToPoint(c, p1), at parameter t.
static func quad(p0: Vector2, c: Vector2, p1: Vector2, t: float) -> Vector2:
	var mt := 1.0 - t
	return p0 * (mt * mt) + c * (2.0 * mt * t) + p1 * (t * t)


## Cumulative arc length at PACED_SAMPLES + 1 evenly spaced parameters.
static func paced_table(p0: Vector2, c: Vector2, p1: Vector2) -> PackedFloat32Array:
	var table := PackedFloat32Array()
	table.resize(PACED_SAMPLES + 1)
	var prev := p0
	var acc := 0.0
	table[0] = 0.0
	for i in range(1, PACED_SAMPLES + 1):
		var pt := quad(p0, c, p1, float(i) / PACED_SAMPLES)
		acc += prev.distance_to(pt)
		table[i] = acc
		prev = pt
	return table


## kCAAnimationPaced: the curve parameter at which a fraction `u` of the
## path's length has been travelled (constant speed along the path).
static func paced_t(table: PackedFloat32Array, u: float) -> float:
	var total: float = table[table.size() - 1]
	if total <= 0.0:
		return clampf(u, 0.0, 1.0)
	var target := clampf(u, 0.0, 1.0) * total
	for i in range(1, table.size()):
		if table[i] >= target:
			var seg := table[i] - table[i - 1]
			var f := 0.0 if seg <= 0.0 else (target - table[i - 1]) / seg
			return (float(i - 1) + f) / (table.size() - 1)
	return 1.0


## CGPathGetBoundingBox of move-to + one quad curve: unlike
## CGPathGetPathBoundingBox it includes the control point.
static func quad_control_box(p0: Vector2, c: Vector2, p1: Vector2) -> Rect2:
	var r := Rect2(p0, Vector2.ZERO)
	r = r.expand(c)
	r = r.expand(p1)
	return r
