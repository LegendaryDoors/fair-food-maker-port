# UIImageView.clipsToBounds for a generated Sprite2D. The scene builder
# (core/import/SceneBuilder.gd) attaches this to image views whose nib sets
# clipsToBounds; screens never attach it by hand.
#
# The image and every child are clipped to the view's nib frame -- what the
# device does to art drawn larger than the frame (contentMode Center with
# oversized art, a swapped-in bigger image) and to subviews added later.
#
# `clip_rect` is that frame in this sprite's local space as generated
# (centered = false, offset 0, the scene's scale). Screens re-anchor nib
# sprites (`centered = true` plus position += size/2, to rotate about the
# centre as a layer does); that moves the local origin but not the frame, so
# the rect follows centered/offset changes via item_rect_changed. A texture
# swap moves neither: the frame stays put, as a UIImageView's does.
#
# Same rectangular scissor as NibView / Control.clip_contents.
# PORT CHOICE: a rotated sprite clips to the bounding box of its rotated
# frame; UIKit clips to the rotated rect itself.
extends Sprite2D

@export var clip_rect := Rect2():
	set(value):
		clip_rect = value
		_apply_clip()

@export var clips_to_bounds := false:
	set(value):
		clips_to_bounds = value
		_apply_clip()

## Local-space shift of the frame since generation, from centered/offset
## changes.
var _shift := Vector2.ZERO
var _seen_centered := false
var _seen_offset := Vector2.ZERO


func _init() -> void:
	item_rect_changed.connect(_on_item_rect_changed)


func _on_item_rect_changed() -> void:
	if centered == _seen_centered and offset == _seen_offset:
		return
	var tex_size := texture.get_size() if texture != null else Vector2.ZERO
	var before := (-tex_size * 0.5 if _seen_centered else Vector2.ZERO) + _seen_offset
	var after := (-tex_size * 0.5 if centered else Vector2.ZERO) + offset
	_shift += after - before
	_seen_centered = centered
	_seen_offset = offset
	_apply_clip()


func _apply_clip() -> void:
	var item := get_canvas_item()
	RenderingServer.canvas_item_set_custom_rect(item, clips_to_bounds,
		Rect2(clip_rect.position + _shift, clip_rect.size))
	RenderingServer.canvas_item_set_clip(item, clips_to_bounds)
