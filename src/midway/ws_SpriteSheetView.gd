# SpriteSheetView, ported for wsRaceVC (the water stream on the hose).
#
# From the original binary (IMPs from the ObjC method list):
#   -initWithFrame:andContentView:andColumns:andRows:  0x47770
#       a UIScrollView: clipsToBounds YES, userInteractionEnabled NO, the
#       content view added at (0,0), contentSize = the content view's frame
#       size; xStep = (int)(contentSize.w / columns), yStep =
#       (int)(contentSize.h / rows); currentFrameIdx 0.
#   -tick  0x47910
#       contentOffset = (xStep * (idx % columns), yStep * (idx / columns))
#       (sub_575778 is the runtime's divmod), then ++idx, wrapping to 0 when
#       it reaches rows * columns.
#   currentFrameIdx / setCurrentFrameIdx:  0x47A2C / 0x47A3C
#
# A clipping scroll view showing one image through a frame-sized window is a
# Sprite2D with region_rect = (contentOffset, frame size). contentOffset set
# programmatically is never clamped by UIScrollView, which is why wsRaceVC can
# shrink contentSize to the frame and still page through the sheet.
#
# `position` is the view's frame origin in its superview's coordinates.

extends Node2D

var columns := 0
var rows := 0
var x_step := 0
var y_step := 0
var current_frame_idx := 0
## The frame size (the visible window onto the content).
var size := Vector2.ZERO
var content_offset := Vector2.ZERO

var _content: Sprite2D


## -initWithFrame:andContentView:andColumns:andRows: (0x47770). The content
## view here is a UIImageView made with initWithImage:, so its frame size is
## the texture's size.
func init_with_frame_and_content_view_and_columns_and_rows(frame: Rect2,
		content: Texture2D, cols: int, row_count: int) -> void:
	position = frame.position
	size = frame.size
	_content = Sprite2D.new()
	_content.centered = false
	_content.texture = content
	_content.region_enabled = true
	add_child(_content)
	columns = cols
	rows = row_count
	var content_size := content.get_size() if content != null else Vector2.ZERO
	x_step = int(content_size.x / float(columns))
	y_step = int(content_size.y / float(rows))
	current_frame_idx = 0
	set_content_offset(Vector2.ZERO)


## -tick (0x47910).
func tick() -> void:
	@warning_ignore("integer_division")
	var row := current_frame_idx / columns
	var col := current_frame_idx % columns
	set_content_offset(Vector2(float(col * x_step), float(row * y_step)))
	current_frame_idx += 1
	if current_frame_idx == rows * columns:
		current_frame_idx = 0


## -setContentOffset: -- what the clipped window shows.
func set_content_offset(p: Vector2) -> void:
	content_offset = p
	if _content != null:
		_content.region_rect = Rect2(content_offset, size)


## The frame's centre, in the superview's coordinates.
func get_center() -> Vector2:
	return position + size * 0.5


func set_center(c: Vector2) -> void:
	position = c - size * 0.5
