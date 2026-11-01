# Port of mb_BottleBaseView -- the six milk bottles of the Milk Bottle midway
# game, their hit test and their fall.
#
# From the original binary (IMPs checked against the ObjC method list):
#   initWithBaseImage:            0x15FD94
#   initPositions                 0x15FEF4
#   resetView                     0x160094
#   detectCollisionWithBall:      0x16046C
#   showAnimation                 0x160708
#   bottleFallAnimation:          0x160830
#   animationDidStop:finished:context: 0x160C20
# (initWithSuperView:delegate: 0x15FD00 and removeAllBottleObj 0x160428 have
# no caller in mb_ThrowBallVC and are not ported.)
#
# Geometry. The view itself is a zero-sized UIView (`[super init]`); it does
# not clip, so `baseView` (a subview) and the bottles inside it draw anyway.
# mb_ThrowBallVC moves it to (0, 10). baseView is re-framed on every reset to
# 3x3 bottles at one of two zooms, centred on one of three columns:
#
#   zoomScales  [1.0, 0.8, 0.7]     index randomPositionOfView = rand&1 + 1
#   rowLevel    [220, 170, 150]     -> baseView centre y (same index)
#   alignOfView [110, 160, 210]     -> baseView centre x (rand % 3)
#
# Bottle slots (unzoomed, can1.png = 40x70): a pyramid -- tag 1 top at
# (40,0), tags 2,3 at (20,70) (60,70), tags 4,5,6 at (0,140) (40,140)
# (80,140). Origins and sizes are multiplied by the zoom.
#
# Hit test quirk, kept: detectCollisionWithBall: offsets each bottle frame by
# baseView's origin only, NOT by this view's own (0, 10), while the ball rect
# comes from the controller's view. Collision rects therefore sit 10 px above
# the drawn bottles, exactly as on the device.

extends Node2D

const Anim := preload("res://midway/mb_Anim.gd")

## initPositions 0x15FEF4: zoomScales[0..2] = 1.0, then the 64-bit store
## 0x3F3333333F4CCCCD = (0.8, 0.7); rowLevel = 220, 0x96000000AA = (170, 150);
## alignOfView = 110, 0xD2000000A0 = (160, 210).
const ZOOM_SCALES := [1.0, 0.8, 0.7]
const ROW_LEVEL := [220, 170, 150]
const ALIGN_OF_VIEW := [110, 160, 210]

## initWithBaseImage: baseView initWithFrame (0, 50, w*3, h*3).
const BASE_VIEW_INIT_Y := 50.0

## detectCollisionWithBall: switch on (tag - 1). Each hit bottle knocks down
## these bottleList slots (byte offsets 68..73 = bottleList[0..5]).
const KNOCKS := {
	1: [0],
	2: [0, 1, 2],
	3: [0, 1, 2],
	4: [0, 1, 2, 3],
	5: [0, 1, 2, 3, 4, 5],
	6: [0, 1, 2, 5],
}

## bottleFallAnimation: 0x160830.
const FALL_MAX_DEGREES := 90      # arc4random % 0x5A
const FALL_CTRL_Y := -20          # control y = -20 - arc4random % 0x19
const FALL_CTRL_Y_SPAN := 25
const FALL_DROP := 50.0           # end y = start y + 50
const FALL_SPEED := 600.0         # duration = 2*sqrt((w/2)^2 + h^2) / 600

## <BottleBaseViewDelegate>: end_throw_breaked_bottles_current_breaked_bottles(total, current)
var delegate: Object = null

var action_performed := false
var total_breaked_bottles := 0
var bottles_breakcount := 0
var bottle_list: Array[bool] = [false, false, false, false, false, false]
var bottle_positon: Array[Rect2] = []
var random_position_of_view := 0
var random_alignment_of_view := 0
var can_name := ""
var bottle_width := 0.0
var bottle_height := 0.0

## baseView and its frame (UIView frame, in this view's coordinates).
var base_view: Node2D
var base_frame := Rect2()

var _can_texture: Texture2D


## initWithBaseImage: 0x15FD94.
func init_with_base_image(image_name: String) -> void:
	can_name = image_name
	if Assets.has_image(image_name):
		_can_texture = Assets.texture(image_name)
	if _can_texture != null:
		bottle_width = _can_texture.get_size().x
		bottle_height = _can_texture.get_size().y
	base_view = Node2D.new()
	base_view.name = "baseView"
	add_child(base_view)
	_set_base_frame(Rect2(0, BASE_VIEW_INIT_Y, bottle_width * 3.0, bottle_height * 3.0))


func _set_base_frame(r: Rect2) -> void:
	base_frame = r
	base_view.position = r.position


## initPositions 0x15FEF4 (the unzoomed slots; resetView scales them).
func init_positions() -> void:
	var w := bottle_width
	var h := bottle_height
	bottle_positon = [
		Rect2(w * 3.0 * 0.5 - w * 0.5, 0.0, w, h),
		Rect2(w * 3.0 / 3.0 - w * 0.5, h, w, h),
		Rect2(w + (w * 3.0 / 3.0 - w * 0.5), h, w, h),
		Rect2(0.0, h + h, w, h),
		Rect2(w * 3.0 * 0.5 - w * 0.5, h + h, w, h),
		Rect2(w * 0.5 + w * 3.0 * 0.5, h + h, w, h),
	]


## resetView 0x160094: clear, pick a zoom/row and a column, lay out six cans.
func reset_view() -> void:
	reset_view_with(int(randi() & 1) + 1, int(randi() % 3), [1, 2, 3, 4, 5, 6])


## The body of resetView with the random picks (and, for the port's resume
## path only, the surviving tags) passed in.
func reset_view_with(position_index: int, alignment_index: int, tags: Array) -> void:
	total_breaked_bottles = 0
	for child in base_view.get_children():
		var tag := int(child.get_meta("tag", 0))
		if tag >= 1 and tag <= 6:
			base_view.remove_child(child)
			child.queue_free()
	random_position_of_view = position_index
	random_alignment_of_view = alignment_index
	init_positions()
	var z: float = ZOOM_SCALES[random_position_of_view]
	for i in 6:
		if not tags.has(i + 1):
			continue
		var p: Rect2 = bottle_positon[i]
		var frame := Rect2(p.position * z, p.size * z)
		var s := Sprite2D.new()
		s.name = "bottle%d" % (i + 1)
		s.texture = _can_texture
		s.centered = true
		s.position = frame.get_center()
		if _can_texture != null:
			s.scale = frame.size / _can_texture.get_size()
		s.set_meta("tag", i + 1)
		s.set_meta("frame_size", frame.size)
		s.set_meta("center", frame.get_center())      # model centre
		s.set_meta("model_rotation", 0.0)            # model transform
		base_view.add_child(s)
	var size := Vector2(bottle_width * 3.0, bottle_height * 3.0) * z
	var center := Vector2(ALIGN_OF_VIEW[random_alignment_of_view], ROW_LEVEL[random_position_of_view])
	_set_base_frame(Rect2(center - size * 0.5, size))


## -[UIView viewWithTag:] over the bottles.
func bottle_with_tag(tag: int) -> Node2D:
	for child in base_view.get_children():
		if int(child.get_meta("tag", 0)) == tag:
			return child
	return null


## Tags of the bottles still standing (not removed, not falling).
func standing_tags() -> Array:
	var out := []
	for child in base_view.get_children():
		if not child.has_meta("fall_tween"):
			out.append(int(child.get_meta("tag", 0)))
	return out


## The bottle's UIView frame (model values): its centre never moves (the fall
## is a keyframe animation), its transform is the rotation target, so the
## frame is the bounding box of the rotated rectangle.
func bottle_frame(b: Node2D) -> Rect2:
	var size: Vector2 = b.get_meta("frame_size")
	var c: Vector2 = b.get_meta("center")
	var rot: float = b.get_meta("model_rotation")
	if rot == 0.0:
		return Rect2(c - size * 0.5, size)
	var hw := size * 0.5
	var r := Rect2(c + Vector2(-hw.x, -hw.y).rotated(rot), Vector2.ZERO)
	for corner in [Vector2(hw.x, -hw.y), Vector2(hw.x, hw.y), Vector2(-hw.x, hw.y)]:
		r = r.expand(c + (corner as Vector2).rotated(rot))
	return r


## detectCollisionWithBall: 0x16046C. `ball` is in the controller's view
## coordinates; bottles are compared at baseView.origin + bottle.frame, i.e.
## without this view's own (0, 10) offset (see header).
func detect_collision_with_ball(ball: Rect2) -> bool:
	for i in 6:
		bottle_list[i] = false
	var result := false
	for child in base_view.get_children():
		if not (child as CanvasItem).visible:
			continue
		var f := bottle_frame(child)
		f.position += base_frame.position
		# CGRectIntersectsRect: touching edges intersect (zero-area result).
		if f.intersects(ball, true):
			var tag := int(child.get_meta("tag", 0))
			if KNOCKS.has(tag):
				for idx: int in KNOCKS[tag]:
					bottle_list[idx] = true
				result = true
			else:
				push_warning("mb_BottleBaseView: Error")   # NSLog(@"Error")
				result = false
	return result


## showAnimation 0x160708: count, then knock down, every flagged bottle that
## still exists; with nothing flagged, report back at once.
func show_animation() -> void:
	bottles_breakcount = 0
	action_performed = false
	var any := false
	for i in 6:
		if bottle_list[i]:
			if bottle_with_tag(i + 1) != null:
				bottles_breakcount += 1
				total_breaked_bottles += 1
			any = true
	for i in 6:
		if bottle_list[i]:
			var b := bottle_with_tag(i + 1)
			if b != null:
				bottle_fall_animation(b)
	if not any and delegate != null:
		delegate.call("end_throw_breaked_bottles_current_breaked_bottles",
			total_breaked_bottles, bottles_breakcount)


## bottleFallAnimation: 0x160830. Two animations of one duration:
##   "Fall_bottles"  CAKeyframeAnimation on position, kCAAnimationPaced, along
##                   MoveTo(c) QuadCurveTo(ctrl, end), fill forwards;
##   "Rotate_Bottle" UIView block, curve 2 (ease-out), transform -> a rotation
##                   of rand%90 degrees, its stop selector removing the bottle.
## dir = rand&1: 1 -> drifts right (ctrl x + r/2, end x + r) and rotates by
## -deg; 0 -> drifts left and rotates by +deg. r = rand % (int)baseView width.
## ctrl y = -20 - rand%25 in baseView space (above the stack); end y = c.y+50.
## duration = 2*sqrt((box.w/2)^2 + box.h^2)/600, box = CGPathGetBoundingBox.
func bottle_fall_animation(b: Node2D) -> void:
	# A bottle hit again while still falling (its model frame never moved, so
	# a quick second throw can find it): the new transform animation replaces
	# the running "Rotate_Bottle" block, whose stop selector then fires
	# (finished:NO) and removes the bottle; the new animations land on a view
	# that is off screen and their own stop finds actionPerformed set.
	# INFERRED: UIKit's replace-then-stop ordering, not read from this binary.
	if b.has_meta("fall_tween"):
		var old: Tween = b.get_meta("fall_tween")
		if old != null and old.is_valid():
			old.kill()
		_rotate_bottle_did_stop(b)
		return
	var dir := int(randi() & 1)
	var deg := int(randi() % FALL_MAX_DEGREES)
	var c: Vector2 = b.get_meta("center")
	var width_i := int(base_frame.size.x)
	var r := float(randi() % width_i) if width_i > 0 else 0.0
	var ctrl_x := c.x + r * 0.5 if dir != 0 else c.x - r * 0.5
	var end_x := c.x + r if dir != 0 else c.x - r
	var ctrl := Vector2(ctrl_x, float(FALL_CTRL_Y - int(randi() % FALL_CTRL_Y_SPAN)))
	var end := Vector2(end_x, c.y + FALL_DROP)
	var box := Anim.quad_control_box(c, ctrl, end)
	var half_w := box.size.x * 0.5
	var duration := (2.0 * sqrt(half_w * half_w + box.size.y * box.size.y)) / FALL_SPEED
	var start_rot: float = b.get_meta("model_rotation")
	var target_rot := deg_to_rad(float(-deg if dir != 0 else deg))
	b.set_meta("model_rotation", target_rot)
	var table := Anim.paced_table(c, ctrl, end)

	var tw := b.create_tween().set_parallel(true)
	tw.tween_method(func(u: float) -> void:
		b.position = Anim.quad(c, ctrl, end, Anim.paced_t(table, u)),
		0.0, 1.0, duration)
	tw.tween_method(func(u: float) -> void:
		b.rotation = lerpf(start_rot, target_rot, Anim.curve(u, Anim.CURVE_EASE_OUT)),
		0.0, 1.0, duration)
	tw.chain().tween_callback(_rotate_bottle_did_stop.bind(b))
	b.set_meta("fall_tween", tw)


## animationDidStop:finished:context: 0x160C20, for "Rotate_Bottle": remove
## the bottle; the first one to finish reports the throw to the delegate.
func _rotate_bottle_did_stop(b: Node2D) -> void:
	if is_instance_valid(b) and b.get_parent() == base_view:
		base_view.remove_child(b)
		b.queue_free()
	if not action_performed:
		if delegate != null:
			delegate.call("end_throw_breaked_bottles_current_breaked_bottles",
				total_breaked_bottles, bottles_breakcount)
		action_performed = true


## Every fall still running ends now and its "Rotate_Bottle" stop runs (the
## bottle is removed; the first stop reports the throw). Used when a pushed
## screen covers the game -- INFERRED, see mb_ThrowBallVC._push_child.
func finish_falls() -> void:
	for child in base_view.get_children():
		if not child.has_meta("fall_tween"):
			continue
		var tw: Tween = child.get_meta("fall_tween")
		if tw != null and tw.is_valid():
			tw.kill()
			_rotate_bottle_did_stop(child)


## True while any bottle is still in its fall animation.
func has_falling_bottles() -> bool:
	for child in base_view.get_children():
		if child.has_meta("fall_tween"):
			return true
	return false
