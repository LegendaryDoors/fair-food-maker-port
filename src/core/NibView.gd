# UIView state a plain Node2D has no slot for. The scene builder
# (core/import/SceneBuilder.gd) attaches this to generated views whose nib
# sets a background colour or clipsToBounds; screens never attach it by hand.
#
#   background_color  UIView.backgroundColor. A layer draws its background
#                     before its sublayers, and a Node2D draws its own _draw()
#                     before its children -- the same order, with no extra
#                     node in the tree (screens address children by index:
#                     sendSubviewToBack: is move_child(n, 0)).
#   clips_to_bounds   UIView.clipsToBounds: this node AND its children are
#                     clipped to (0, 0, nib_size) in this node's space -- a
#                     rectangular scissor, exactly what Control.clip_contents
#                     does (RenderingServer canvas_item_set_clip over a custom
#                     rect), so modulate fades keep working underneath (the
#                     alpha-mask clip_children loses them; see ipPour).
#                     PORT CHOICE: a rotated view clips to the bounding box of
#                     its rotated bounds; UIKit clips to the rotated rect.
#   nib_size          bounds.size from the nib. A screen that ports a
#                     setFrame: size change can assign it.
#
# The scene root cannot carry a script (Nav attaches the screen controller),
# so a root view's colour is a child of this class drawn with
# show_behind_parent -- below every sibling whatever its index.
extends Node2D

@export var nib_size := Vector2.ZERO:
	set(value):
		nib_size = value
		_apply_clip()
		queue_redraw()

@export var background_color := Color(0, 0, 0, 0):
	set(value):
		background_color = value
		queue_redraw()

@export var clips_to_bounds := false:
	set(value):
		clips_to_bounds = value
		_apply_clip()


func _apply_clip() -> void:
	var item := get_canvas_item()
	RenderingServer.canvas_item_set_custom_rect(item, clips_to_bounds,
		Rect2(Vector2.ZERO, nib_size))
	RenderingServer.canvas_item_set_clip(item, clips_to_bounds)


func _draw() -> void:
	if background_color.a > 0.0 and nib_size.x > 0.0 and nib_size.y > 0.0:
		draw_rect(Rect2(Vector2.ZERO, nib_size), background_color)
