# UIKit / Core Animation stand-ins shared by the five milkshake screens.
#
# Not a screen: Nav only attaches res://screens/<Class>.gd to a scene of the
# same name, and there is no msUIKit scene. Preload it:
#
#   const UIKit := preload("res://screens/msUIKit.gd")
#
# Three things the ms screens all need and that core/ does not provide:
#
#   * ScrollFrame  -- the picker UIScrollViews. They CLIP their content and
#     their frames are animated (origin AND size) by every slide-in/out. A bare
#     Node2D does neither, so pickers drew over the whole screen and had to be
#     hidden by hand when they "left". Hit tests use the MODEL frame, as UIKit
#     does during a UIView animation (the target frame is set immediately).
#   * PacedQuad    -- CAKeyframeAnimation with calculationMode
#     kCAAnimationPaced along a CGPathAddQuadCurveToPoint path: constant speed
#     along the curve, not a linear walk of the Bezier parameter (scoop balls
#     0x44F50, fruit pieces 0x4F6B8).
#   * MaskedIV     -- -[MaskedIV initWithBaseImg:andMaskImg:] (0x46CE0) /
#     drawRect: (0x46E68): a view the size of the MASK, the base image drawn
#     at baseOrigPt inside it, clipped by a CGImageMask (black paints). The
#     clip is applied inside UIKit's flipped drawRect context without a CTM
#     flip, so the mask lands upside down (the project's MaskedIV quirk,
#     MaskedSprite2D.mask_flip_v). core/MaskedSprite2D has no baseOrigPt --
#     it reveals a fixed image -- while msSelectFlavor's pour MOVES the image
#     (setBaseOrigPt: 0x46EE4), so the milk's curved surface rises.

#   * ScrollPhysics: a UIScrollView's touch tracking and physics, made of
#     one core/UIScrollSim ScrollAxis per axis, the scroll indicators
#     (core/UIScrollIndicator) and setContentOffset:animated:. ScrollFrame
#     carries one after enable_scrolling(); the pickers of the lsu, sc, cc,
#     dic and fc screens use it directly.

extends RefCounted

const UIScrollSim := preload("res://core/UIScrollSim.gd")
const UIScrollIndicator := preload("res://core/UIScrollIndicator.gd")

## UIViewAnimationCurveEaseInOut, the default curve of every beginAnimations:
## block in these screens. The project renders it as SINE / IN_OUT throughout.
const TRANS := Tween.TRANS_SINE
const EASE := Tween.EASE_IN_OUT


## A UIScrollView's touches and motion (as in iOS 6.1.3's UIKit), for a
## view the screen draws itself. Feed it the finger in any fixed screen
## space (only differences matter); read the offset from `scrolled`
## (scrollViewDidScroll:) and apply it to the content.
##
##   * a drag starts after 10 pt along a scrollable axis; until then the
##     touch belongs to the cell under it, and touch_ended() returns true:
##     deliver it as a tap (delaysContentTouches / canCancelContentTouches
##     YES, the nib defaults). A drag cancels the cell's touch.
##   * an axis scrolls only when its content is larger than the bounds
##     (_canScrollX/Y) or alwaysBounce is set; rubber band 0.55, release
##     velocity, deceleration (Normal 0.998 / Fast 0.99), bounce -- all in
##     UIScrollSim.ScrollAxis.
##   * INFERRED (UIKit behaviour, not read): a touch that lands while the view
##     is still moving stops it and is not delivered to the cell as a tap.
##   * setContentOffset:animated:YES: UIScrollViewScrollAnimation, 0.3 s
##     (_contentOffsetAnimationDuration), driven by UIAnimation with curve 0:
##     -[UIAnimation progressForFraction:] (UIKit 0x3309F518) case 0 is
##     sin(t * pi/2)^2 = (1 - cos(pi t)) / 2 -- Godot's TRANS_SINE ease-in-out
##     exactly. (-[UIScrollView setContentOffset:animated:] 0x32FA2ADC ->
##     _setContentOffset:animated:animationCurve:0 ...)
##   * indicators: an axis' indicator is shown only while that axis' visible
##     fraction (bounds / content) is at most 0.99 (_adjustScrollerIndicators:
##     alwaysShowingThem: 0x32FA08F0); shown on drag / animated scroll, fading
##     0.5 s after the view stops (UIScrollIndicator.end()).
class ScrollPhysics:
	extends Node

	## scrollViewDidScroll: -- every change of contentOffset.
	signal scrolled(offset: Vector2)
	## scrollViewWillBeginDragging:
	signal drag_began
	## The view came to rest (drag ended without deceleration, deceleration
	## or bounce over, animated offset done).
	signal stopped

	var h: RefCounted = UIScrollSim.ScrollAxis.new()
	var v: RefCounted = UIScrollSim.ScrollAxis.new()
	var bounds_size := Vector2(320, 480)
	var content_size := Vector2.ZERO
	var shows_horizontal := true
	var shows_vertical := true

	var _ind_h: Node2D
	var _ind_v: Node2D
	var _track := Rect2()
	var _touching := false
	var _dragged := false
	var _caught := false
	var _anim_from := Vector2.ZERO
	var _anim_to := Vector2.ZERO
	var _anim_t := -1.0
	var _last := Vector2.ZERO
	var _active := false          # indicators up / motion in progress

	## Seconds, for the sim's velocity samples (touch timestamps).
	static func now_s() -> float:
		return Time.get_ticks_usec() / 1000000.0

	func _init(bounds: Vector2 = Vector2(320, 480), content: Vector2 = Vector2.ZERO) -> void:
		bounds_size = bounds
		content_size = content
		_limits()
		for a: RefCounted in [h, v]:
			a.connect("will_begin_dragging", _on_will_begin_dragging)
			a.connect("did_end_dragging", _on_did_end_dragging)
			a.connect("did_end_decelerating", _on_did_end_decelerating)

	func _limits() -> void:
		h.set("range_", bounds_size.x)
		v.set("range_", bounds_size.y)
		h.set("min_offset", 0.0)
		v.set("min_offset", 0.0)
		h.set("max_offset", content_size.x - bounds_size.x)
		v.set("max_offset", content_size.y - bounds_size.y)

	## setContentSize:
	func set_content_size(size: Vector2) -> void:
		content_size = size
		_limits()
		_update_indicators()

	## The bounds size (the frame size: none of these views is transformed).
	func set_bounds_size(size: Vector2) -> void:
		bounds_size = size
		_limits()
		_update_indicators()

	## setDecelerationRate: (both axes; UIKit snaps it to 0.99 or 0.998).
	func set_deceleration_rate(rate: float) -> void:
		h.call("set_deceleration_rate", rate)
		v.call("set_deceleration_rate", rate)

	func set_bounces(on: bool) -> void:
		h.set("bounces", on)
		v.set("bounces", on)

	func set_always_bounce_vertical(on: bool) -> void:
		v.set("always_bounce", on)

	func set_always_bounce_horizontal(on: bool) -> void:
		h.set("always_bounce", on)

	## Build the indicators (those still switched on) under `host`, whose
	## local space has the scroll view's frame at `track`. Call after the
	## shows_* flags are set; the art is the default style.
	func attach_indicators(host: Node, track: Rect2) -> void:
		_track = track
		if shows_horizontal and _ind_h == null:
			_ind_h = UIScrollIndicator.new()
			_ind_h.set("vertical", false)
			_ind_h.set("track", track)
			host.add_child(_ind_h)
		if shows_vertical and _ind_v == null:
			_ind_v = UIScrollIndicator.new()
			_ind_v.set("vertical", true)
			_ind_v.set("track", track)
			host.add_child(_ind_v)
		_update_indicators()

	## The scroll view's frame in the indicator host's space (it moves with a
	## frame animation).
	func set_track(track: Rect2) -> void:
		if track == _track:
			return
		_track = track
		for ind: Node2D in [_ind_h, _ind_v]:
			if ind != null:
				ind.set("track", track)
		_update_indicators()

	func get_offset() -> Vector2:
		return Vector2(h.get("offset"), v.get("offset"))

	func is_dragging() -> bool:
		return bool(h.get("dragging")) or bool(v.get("dragging"))

	func is_tracking() -> bool:
		return _touching

	func is_decelerating() -> bool:
		return bool(h.get("decelerating")) or bool(v.get("decelerating"))

	## Anything moving the content right now (drag, glide, bounce, animation).
	func is_scrolling() -> bool:
		return is_dragging() or is_decelerating() or _anim_t >= 0.0

	## Run any glide / bounce / offset animation to its end at once, in
	## 1/60 s steps (UIKit keeps a covered view moving on the run loop; a
	## port node out of the tree does not -- see the callers).
	func finish() -> void:
		var guard := 0
		while is_scrolling() and not is_dragging() and guard < 60 * 30:
			_process(1.0 / 60.0)
			guard += 1

	## Halt where it is (no event).
	func halt() -> void:
		_anim_t = -1.0
		for a: RefCounted in [h, v]:
			a.set("decelerating", false)
			a.set("velocity", 0.0)

	## setContentOffset: / setContentOffset:animated:.
	func set_content_offset(o: Vector2, animated: bool = false) -> void:
		halt()
		if animated and o != get_offset():
			_anim_from = get_offset()
			_anim_to = o
			_anim_t = 0.0
			_show()
			return
		h.set("offset", o.x)
		v.set("offset", o.y)
		_emit_if_moved()

	func touch_began(p: Vector2) -> void:
		_touching = true
		_dragged = false
		_caught = is_scrolling()
		if _anim_t >= 0.0:
			_anim_t = -1.0          # a touch stops an offset animation
		var t := now_s()
		h.call("touch_began", p.x, t)
		v.call("touch_began", p.y, t)

	func touch_moved(p: Vector2) -> void:
		if not _touching:
			return
		var t := now_s()
		h.call("touch_moved", p.x, t)
		v.call("touch_moved", p.y, t)
		_emit_if_moved()

	## Returns true when the touch never became a drag: the cell under the
	## press gets it as a tap (touchUpInside).
	func touch_ended(_p: Vector2 = Vector2.ZERO) -> bool:
		if not _touching:
			return false
		_touching = false
		var t := now_s()
		h.call("touch_ended", t)
		v.call("touch_ended", t)
		# INFERRED (UIKit not read for this case): a touch that caught the
		# view mid-bounce and lifted without dragging leaves the offset past
		# an edge; UIKit never rests there, so let it bounce back from rest.
		for a: RefCounted in [h, v]:
			var off: float = a.get("offset")
			var hi := maxf(float(a.get("max_offset")), float(a.get("min_offset")))
			if bool(a.get("bounces")) and not bool(a.get("decelerating")) \
					and (off < float(a.get("min_offset")) or off > hi):
				a.set("velocity", 0.0)
				a.set("_last_offset", off)
				a.set("decelerating", true)
		_emit_if_moved()
		if not is_scrolling() and _active:
			_end()
		return not _dragged and not _caught

	## touchesCancelled: (the view went away under the finger).
	func touch_cancelled() -> void:
		if _touching:
			touch_ended()

	func _process(delta: float) -> void:
		if _anim_t >= 0.0:
			_anim_t = minf(_anim_t + delta / UIScrollSim.CONTENT_OFFSET_ANIMATION_DURATION, 1.0)
			var k := (1.0 - cos(PI * _anim_t)) * 0.5
			var o := _anim_from.lerp(_anim_to, k)
			h.set("offset", o.x)
			v.set("offset", o.y)
			_emit_if_moved()
			if _anim_t >= 1.0:
				_anim_t = -1.0
				_end()
			return
		var moving := false
		if bool(h.get("decelerating")):
			moving = bool(h.call("step", delta)) or moving
		if bool(v.get("decelerating")):
			moving = bool(v.call("step", delta)) or moving
		_emit_if_moved()

	func _emit_if_moved() -> void:
		var o := get_offset()
		if o == _last:
			return
		_last = o
		_update_indicators()
		scrolled.emit(o)

	func _on_will_begin_dragging() -> void:
		_dragged = true
		_show()
		drag_began.emit()

	func _on_did_end_dragging(will_decelerate: bool) -> void:
		if not will_decelerate and not is_decelerating() and not is_dragging():
			call_deferred("_end_if_idle")

	func _on_did_end_decelerating() -> void:
		if not is_decelerating() and not is_dragging():
			_end()

	func _end_if_idle() -> void:
		if _active and not is_scrolling() and not _touching:
			_end()

	func _show() -> void:
		_active = true
		_update_indicators()
		for ind: Node2D in [_ind_h, _ind_v]:
			if ind != null and ind.visible:
				ind.call("begin")

	func _end() -> void:
		if not _active:
			return
		_active = false
		for ind: Node2D in [_ind_h, _ind_v]:
			if ind != null:
				ind.call("end")
		stopped.emit()

	func _update_indicators() -> void:
		var o := get_offset()
		if _ind_h != null:
			var frac_h := bounds_size.x / maxf(content_size.x, 0.001)
			_ind_h.visible = frac_h <= 0.99
			_ind_h.call("update", o.x, 0.0, maxf(content_size.x - bounds_size.x, 0.0),
				bounds_size.x)
		if _ind_v != null:
			var frac_v := bounds_size.y / maxf(content_size.y, 0.001)
			_ind_v.visible = frac_v <= 0.99
			_ind_v.call("update", o.y, 0.0, maxf(content_size.y - bounds_size.y, 0.0),
				bounds_size.y)


## A UIScrollView: a clipping Control whose single child `content` is offset
## by -contentOffset. `model` is the frame UIKit would report (the target of
## the last setFrame:, animated or not).
class ScrollFrame:
	extends Control

	var content: Node2D
	var model := Rect2()
	var _tween: Tween
	## The UIScrollView's touches and motion, once enable_scrolling()
	## has run (null before -- a frame that never scrolls has none).
	var physics: ScrollPhysics

	func _init(frame: Rect2) -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		content = Node2D.new()
		add_child(content)
		set_frame(frame)

	## Give this frame UIScrollView physics for `content_size`. Set the
	## physics' shows_* / rate / bounce before the first touch; indicators
	## are attached here from the shows_* flags, so set those first via
	## `configure` (called with the fresh ScrollPhysics) when needed.
	func enable_scrolling(content_size: Vector2, configure: Callable = Callable()) -> ScrollPhysics:
		physics = ScrollPhysics.new(model.size, content_size)
		physics.name = "UIScrollPhysics"
		if configure.is_valid():
			configure.call(physics)
		add_child(physics)
		physics.scrolled.connect(func(o: Vector2) -> void: content.position = -o)
		physics.attach_indicators(self, Rect2(Vector2.ZERO, size))
		set_process(true)
		return physics

	func _process(_delta: float) -> void:
		if physics != null:
			physics.set_track(Rect2(Vector2.ZERO, size))

	## Screen point -> the scroll physics' touch space (the model frame).
	func touch_point(p: Vector2) -> Vector2:
		return p - model.position

	## setFrame: / setCenter: outside an animation block.
	func set_frame(frame: Rect2) -> void:
		if _tween != null and _tween.is_valid():
			_tween.kill()
		model = frame
		position = frame.position
		size = frame.size
		if physics != null:
			physics.set_bounds_size(frame.size)

	## setCenter: outside an animation block: moves the frame, keeps its size
	## (the size the last setFrame: left, which a return visit inherits).
	func set_center(c: Vector2) -> void:
		set_frame(Rect2(c - model.size * 0.5, model.size))

	## setFrame: inside beginAnimations ... commitAnimations, default curve.
	func animate_frame(frame: Rect2, secs: float) -> void:
		if _tween != null and _tween.is_valid():
			_tween.kill()
		model = frame
		if physics != null:
			physics.set_bounds_size(frame.size)
		_tween = create_tween().set_parallel(true)
		_tween.tween_property(self, "position", frame.position, secs) \
			.set_trans(TRANS).set_ease(EASE)
		_tween.tween_property(self, "size", frame.size, secs) \
			.set_trans(TRANS).set_ease(EASE)

	## contentOffset.x, as a positive number.
	func get_offset_x() -> float:
		return -content.position.x

	func set_offset_x(x: float) -> void:
		if physics != null:
			physics.set_content_offset(Vector2(x, physics.get_offset().y))
		else:
			content.position.x = -x

	## Screen point -> content point, through the MODEL frame.
	func to_content(p: Vector2) -> Vector2:
		return p - model.position - content.position

	## Whether a screen point lies inside the scroll view's model frame.
	func model_has_point(p: Vector2) -> bool:
		return model.has_point(p)


## Create a ScrollFrame and insert it directly above `anchor` (the nib's
## aScrollView outlet), so it keeps the nib's z-order.
static func scroll_frame(screen: Node, anchor: Node, frame: Rect2) -> ScrollFrame:
	var sf := ScrollFrame.new(frame)
	if anchor != null and anchor != screen and anchor.get_parent() != null:
		var p := anchor.get_parent()
		p.add_child(sf)
		p.move_child(sf, anchor.get_index() + 1)
	else:
		screen.add_child(sf)
	return sf


## Constant-speed position along a quadratic Bezier (kCAAnimationPaced).
class PacedQuad:
	extends RefCounted

	const SAMPLES := 64
	var _p0: Vector2
	var _c: Vector2
	var _p1: Vector2
	var _len := PackedFloat32Array()

	func _init(p0: Vector2, c: Vector2, p1: Vector2) -> void:
		_p0 = p0
		_c = c
		_p1 = p1
		var acc := 0.0
		var prev := p0
		_len.append(0.0)
		for i in range(1, SAMPLES + 1):
			var p := quad(float(i) / SAMPLES)
			acc += prev.distance_to(p)
			_len.append(acc)
			prev = p

	func quad(t: float) -> Vector2:
		var u := 1.0 - t
		return u * u * _p0 + 2.0 * u * t * _c + t * t * _p1

	## Point at fraction `u` (0..1) of the path's arc length.
	func at(u: float) -> Vector2:
		var total: float = _len[SAMPLES]
		if total <= 0.0:
			return _p1
		var target := clampf(u, 0.0, 1.0) * total
		var lo := 0
		var hi := SAMPLES
		while hi - lo > 1:
			var mid := (lo + hi) / 2
			if _len[mid] < target:
				lo = mid
			else:
				hi = mid
		var seg: float = _len[hi] - _len[lo]
		var f := 0.0 if seg <= 0.0 else (target - _len[lo]) / seg
		return quad((float(lo) + f) / SAMPLES)


## Animate `node.position` along a paced quad over `secs` (linear in time:
## a paced keyframe animation ignores timing functions). The final point is
## kept, as fillMode forwards + removedOnCompletion NO do.
static func fly_paced(node: Node2D, p0: Vector2, c: Vector2, p1: Vector2,
		secs: float) -> Tween:
	var path := PacedQuad.new(p0, c, p1)
	node.position = p0
	var tw := node.create_tween()
	tw.tween_method(func(u: float) -> void:
		if is_instance_valid(node):
			node.position = path.at(u), 0.0, 1.0, secs)
	return tw


const MASKED_SHADER := "
shader_type canvas_item;
uniform sampler2D base_tex : filter_nearest;
uniform vec2 base_size = vec2(1.0);
uniform vec2 view_size = vec2(1.0);
uniform vec2 base_orig = vec2(0.0);
uniform vec4 tint : source_color = vec4(1.0);
uniform bool mask_flip_v = true;
void fragment() {
	vec2 b = (UV * view_size - base_orig) / base_size;
	vec4 base = vec4(0.0);
	if (b.x >= 0.0 && b.x < 1.0 && b.y >= 0.0 && b.y < 1.0) {
		base = texture(base_tex, b);
	}
	vec2 muv = mask_flip_v ? vec2(UV.x, 1.0 - UV.y) : UV;
	vec4 m = texture(TEXTURE, muv);
	float cov = (1.0 - dot(m.rgb, vec3(0.299, 0.587, 0.114))) * m.a;
	COLOR = vec4(base.rgb * tint.rgb, base.a * cov * tint.a);
}"


## MaskedIV with a movable baseOrigPt. The node's texture IS the mask (the
## view is the mask's size, 0x46CE0); the base image rides in a uniform.
## `tint` multiplies the base, which is what a blend-1 TintedIV's baked
## changeColor: image amounts to for opaque pixels (0x47304).
class MaskedIV:
	extends Sprite2D

	## Pour progress 0..1, for tests.
	## It does NOT drive the drawing -- base_orig_pt does, as in the original.
	var fill := 0.0

	var _mat: ShaderMaterial

	func _init(base_tex: Texture2D, mask_tex: Texture2D) -> void:
		centered = false
		texture = mask_tex
		var sh := Shader.new()
		sh.code = MASKED_SHADER
		_mat = ShaderMaterial.new()
		_mat.shader = sh
		material = _mat
		_mat.set_shader_parameter("base_tex", base_tex)
		if base_tex != null:
			_mat.set_shader_parameter("base_size", base_tex.get_size())
		if mask_tex != null:
			_mat.set_shader_parameter("view_size", mask_tex.get_size())

	## -[MaskedIV setBaseOrigPt:] (0x46EE4).
	func set_base_orig_pt(p: Vector2) -> void:
		_mat.set_shader_parameter("base_orig", p)

	func get_base_orig_pt() -> Vector2:
		return _mat.get_shader_parameter("base_orig")

	func set_tint(c: Color) -> void:
		_mat.set_shader_parameter("tint", c)

	func set_mask_flip_v(on: bool) -> void:
		_mat.set_shader_parameter("mask_flip_v", on)


## Remember the next button's nib home so repeated showNextButton calls slide
## to the same place. Screen.show_next_button() reads the CURRENT position as
## home; a second call while the first slide is still running would park the
## button 500px short of home. The original reads the model centre, which is
## always home.
static func show_next_from_home(screen: Node, home: Vector2) -> void:
	var nb: Node = screen.call("first_outlet", ["nextButton", "btn_next", "nextBtn"])
	if nb != null and nb is CanvasItem:
		nb.set("position", home)
	screen.call("show_next_button")


## Back from a pushed screen (Nav keeps_state_on_push / on_resume). The app
## delegate's coins panel is ONE view that navigationController:
## didShowViewController:animated: (0x1AC3C) takes off the old screen before
## adding it to the new one; core/CoinHUD builds a fresh one on every
## screen_changed and never removes the last, so a kept screen would come back
## carrying two. Nav emits screen_changed right after on_resume(), so dropping
## the old panel here leaves exactly the one CoinHUD adds -- the same fix
## MakeViewController.on_resume() makes.
static func drop_coin_view(screen: Node) -> void:
	var old := screen.get_node_or_null("CoinInfoView")
	if old != null:
		screen.remove_child(old)
		old.queue_free()


## For a screen whose first changeInstruction: runs in viewDidAppear:
## (now on_did_appear(), after the 0.35 s push slide). Screen._ready() starts
## a generic re-slide of the banner at load time -- the start of the push --
## which on the phone does not exist: during the slide instIV simply sits at
## its nib spot with its nib art, and the real slide-in starts when
## viewDidAppear: calls changeInstruction:. Stop the load-time slide and leave
## the banner parked at home. `nib_hidden`: the nib ships the banner hidden
## (the dic screens), so it stays hidden until changeInstruction: unhides it
## -- Screen._place_instruction() had made it visible.
static func park_instruction(screen: Node, nib_hidden: bool = false) -> void:
	var tw: Variant = screen.get("_instruction_tween")
	if tw is Tween and (tw as Tween).is_valid():
		(tw as Tween).kill()
	var item: Variant = screen.call("_instruction_node")
	if item is Node2D and bool(screen.get("_instruction_home_set")):
		(item as Node2D).position = screen.get("_instruction_home")
	if item is Node2D and nib_hidden:
		(item as Node2D).visible = false


static func next_home(screen: Node) -> Vector2:
	var nb: Node = screen.call("first_outlet", ["nextButton", "btn_next", "nextBtn"])
	if nb != null and nb is CanvasItem:
		return nb.get("position")
	return Vector2.ZERO


## UIButton setImage: with an image larger than the button. INFERRED UIKit
## rule, the same one SceneBuilder applies to nib buttons
## (stretch_mode 5): natural size centred, shrunk to fit keeping aspect only
## when larger. Returns (position, scale) for a non-centred Sprite2D.
static func fit_button_image(img_size: Vector2, button_size: Vector2) -> Array:
	var k := 1.0
	if img_size.x > button_size.x or img_size.y > button_size.y:
		k = minf(button_size.x / img_size.x, button_size.y / img_size.y)
	var drawn := img_size * k
	return [(button_size - drawn) * 0.5, Vector2(k, k)]
