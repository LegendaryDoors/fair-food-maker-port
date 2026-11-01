# BalloonView, ported for bpTossDartVC (the wsRace port keeps its own copy).
#
# From the original binary (IMPs from the ObjC method list):
#   -initWithBalloonImage:  0x124408  frame (0,0, image.size) -- 60x60 for
#                                     bp_balloon.png; one UIImageView (baseIV)
#                                     with the image at (0,0); baseImg = image.
#   -reset                  0x124520  imageIndex 0, baseIV.image = images[0],
#                                     unhidden, transform identity.
#   -pop                    0x1245EC  baseIV.image = images[imageIndex];
#                                     ++imageIndex; if imageIndex >= count:
#                                     imageIndex 0 and HIDDEN; else
#                                     performSelector:@selector(pop)
#                                     afterDelay: 0.05 (a double, lo/hi words
#                                     0xA0000000 / 0x3FA99999).
#   -path                   0x124704  one CGPath shared by every balloon
#                                     (built once into a static), see PATH.
#   setImages: / tag        bpTossDartVC.initBalloons sets images to the three
#                                     tinted arts and the tag from its table.
#
# ORIGINAL QUIRK, ported as is: with images [balloon, popping, popped], pop's
# first call re-sets the balloon art, the second (0.05s later) shows
# "popping", and the third (0.10s) sets "popped" AND hides the view in the
# same call -- so bp_balloon_popped.png is never on screen.

extends Node2D

## performSelector:withObject:afterDelay: in -pop.
const POP_STEP := 0.05

## -path (0x124704), in the balloon's own coordinates (UIKit, y down):
##   move (30,0)
##   curve c1 (30,0)  c2 (5,14)  -> (0,33)
##   curve c1 (0,33)  c2 (0,60)  -> (30,60)
##   curve c1 (30,60) c2 (60,60) -> (60,33)
##   line (51,17), close.
## CGPathContainsPoint(eoFill:NO) uses non-zero winding; the outline is a
## simple (non-self-intersecting) loop, so a polygon test is equivalent.
const PATH_START := Vector2(30, 0)
const PATH_CURVES := [
	[Vector2(30, 0), Vector2(5, 14), Vector2(0, 33)],
	[Vector2(0, 33), Vector2(0, 60), Vector2(30, 60)],
	[Vector2(30, 60), Vector2(60, 60), Vector2(60, 33)],
]
const PATH_LINE_TO := Vector2(51, 17)
## Flattening resolution for each cubic. PORT CHOICE: CG tests the exact
## curve; 32 chords per 30-60px curve keep the error well under 0.1px.
const CURVE_STEPS := 32

static var _polygon := PackedVector2Array()

var base_iv: Sprite2D
var base_img: Texture2D
var images: Array = []
var image_index := 0
## UIView.tag -- 1, 2 or 3 from bpTossDartVC's row table.
var tag := 0
## The view's frame size (initWithBalloonImage: takes it from the image).
var size := Vector2.ZERO


## -initWithBalloonImage: (0x124408).
func init_with_balloon_image(img: Texture2D) -> void:
	size = img.get_size() if img != null else Vector2.ZERO
	base_iv = Sprite2D.new()
	base_iv.centered = false
	base_iv.texture = img
	add_child(base_iv)
	base_img = img


## -reset (0x124520).
func reset() -> void:
	image_index = 0
	base_iv.texture = images[image_index]
	visible = true
	scale = Vector2.ONE
	rotation = 0.0


## -pop (0x1245EC).
func pop() -> void:
	base_iv.texture = images[image_index]
	image_index += 1
	if image_index >= images.size():
		image_index = 0
		visible = false
	else:
		# The main loop, not get_tree(): the next frame must still come while
		# a pushed screen has taken this view out of the tree (the original's
		# timer keeps running under it).
		(Engine.get_main_loop() as SceneTree).create_timer(POP_STEP).timeout.connect(pop)


## CGPathContainsPoint([self path], NULL, p, NO), p in this view's coords.
static func path_contains_point(p: Vector2) -> bool:
	if _polygon.is_empty():
		_polygon = _flatten()
	return Geometry2D.is_point_in_polygon(p, _polygon)


static func _flatten() -> PackedVector2Array:
	var out := PackedVector2Array()
	var cur: Vector2 = PATH_START
	out.append(cur)
	for seg: Array in PATH_CURVES:
		var c1: Vector2 = seg[0]
		var c2: Vector2 = seg[1]
		var end: Vector2 = seg[2]
		for i in range(1, CURVE_STEPS + 1):
			out.append(cur.bezier_interpolate(c1, c2, end, float(i) / CURVE_STEPS))
		cur = end
	out.append(PATH_LINE_TO)
	return out
