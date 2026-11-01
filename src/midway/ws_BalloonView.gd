# BalloonView, ported for wsRaceVC (the balloon on each clown's head).
# bpTossDartVC keeps its own copy (src/midway/bp_BalloonView.gd).
#
# From the original binary (IMPs from the ObjC method list):
#   -initWithBalloonImage:  0x124408  frame (0,0, image.size) -- 60x60 for
#                                     ws_balloon.png; one UIImageView (baseIV)
#                                     with the image at (0,0); baseImg = image.
#   -reset                  0x124520  imageIndex 0, baseIV.image = images[0],
#                                     unhidden, transform identity.
#   -pop                    0x1245EC  baseIV.image = images[imageIndex];
#                                     ++imageIndex; if imageIndex >= count:
#                                     imageIndex 0 and HIDDEN; else
#                                     performSelector:@selector(pop)
#                                     afterDelay: 0.05 (a double, lo/hi words
#                                     0xA0000000 / 0x3FA99999).
#   -path                   0x124704  never called by wsRaceVC; not ported.
#
# ORIGINAL QUIRKS, ported as is:
#   - with images [balloon, popping, popped], pop's first call re-sets the
#     balloon art, the second (0.05s later) shows "popping", and the third
#     (0.10s) sets "popped" AND hides the view in the same call -- so
#     ws_balloon_popped.png is never on screen;
#   - -reset does not cancel a pending pop. wsRaceVC resets the race (and so
#     every balloon) in the same tick an AI balloon pops on a loss, and the
#     queued pop then restarts the sequence on the reset balloon: back at
#     normal size it shows "popping" from 0.10s and is hidden at 0.15s,
#     staying hidden until the next reset.
#
# Geometry: `position` is the UIKit centre in the superview's bounds
# coordinates; `scale` is the view's transform (UIKit scales about the
# centre, as Node2D does about its origin). The art is centred on the origin.

extends Node2D

## performSelector:withObject:afterDelay: in -pop.
const POP_STEP := 0.05

var base_iv: Sprite2D
var base_img: Texture2D
var images: Array = []
var image_index := 0
## The view's bounds size (initWithBalloonImage: takes it from the image).
var size := Vector2.ZERO


## -initWithBalloonImage: (0x124408).
func init_with_balloon_image(img: Texture2D) -> void:
	size = img.get_size() if img != null else Vector2.ZERO
	base_iv = Sprite2D.new()
	base_iv.centered = true
	base_iv.texture = img
	add_child(base_iv)
	base_img = img


## -reset (0x124520).
func reset() -> void:
	image_index = 0
	base_iv.texture = images[image_index]
	visible = true
	scale = Vector2.ONE


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


## -frame's height: the bounds scaled by the transform.
func frame_height() -> float:
	return size.y * scale.y
