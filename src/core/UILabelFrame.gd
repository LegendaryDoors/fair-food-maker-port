# Give a Label built in code its UILabel frame.
#
# Never set a code-built Label's `size`. Godot clamps a Control to its minimum
# size at the moment `size` is set, and a Label outside the tree measures with
# the default 16 px font whatever font or size is set later -- so a 74x14
# prize-name label became 74x23 and drew its text 4.5 pt low (the prize name
# "Chick" sat low on its ribbon). Offsets are not clamped when set.
#
# What UILabel does with text that does not fit is matched by the grow
# directions: it centres its line box vertically on the frame, so a line taller
# than the frame overflows equally above and below (GROW_DIRECTION_BOTH); a
# too-wide line grows away from the edge the text is aligned to.
#
# Call AFTER horizontal_alignment is set. The scene builder applies the same
# rule to nib labels.

extends RefCounted


static func set_frame(label: Label, frame: Rect2) -> void:
	match label.horizontal_alignment:
		HORIZONTAL_ALIGNMENT_CENTER:
			label.grow_horizontal = Control.GROW_DIRECTION_BOTH
		HORIZONTAL_ALIGNMENT_RIGHT:
			label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		_:
			label.grow_horizontal = Control.GROW_DIRECTION_END
	label.grow_vertical = Control.GROW_DIRECTION_BOTH
	label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	label.offset_left = frame.position.x
	label.offset_top = frame.position.y
	label.offset_right = frame.end.x
	label.offset_bottom = frame.end.y
