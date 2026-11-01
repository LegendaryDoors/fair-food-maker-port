# Port of ConsumableButton (0x12CCD0): the round coin-priced "mystery" badges
# with a BUY: <cost> plate under them.
#
# From the original binary:
#   frame  = (0,0, max(mask.w, label.w), mask.h + label.h + labelYOffset)
#   buttonView      UIImageView(buttonImage)   at (0,0)
#   maskedView      MaskedIV(consumableImage masked by buttonMask), centred
#                   in the button
#   buttonOverlayView UIImageView(buttonOverlay) at (0,0)   -- the border
#   labelImageView  UIImageView(labelImage) at (floor(labelXOffset),
#                   floor(labelYOffset + masked.h))         -- the BUY plate
#   textLabelView   UILabel (label.x + costLabelXOffset, label.y +
#                   costLabelYOffset, label.w, label.h), text "%d" cost,
#                   default font (system 17), clear background
#   highlightedView hidden; touchesEnded fires the target/action (0x12D97C).
# Every screen that builds one passes btn_IAP_background / btn_IAP_mask /
# btn_IAP_border / btn_IAP_lable and its own consumable art.
#
# KNOWN SIMPLIFICATION: MaskedSprite2D applies the 94x94 mask in the
# consumable art's own UV space, so art smaller than the mask (btn_IAP_mixer
# is 56x77) is masked by a squashed circle. Every badge's art sits inside the
# circle, so nothing visible changes; a frame-space mask would be exact.

extends TextureButton
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const MaskedSprite := preload("res://core/MaskedSprite2D.gd")
const BACKGROUND := "btn_IAP_background.png"
const MASK := "btn_IAP_mask.png"
const BORDER := "btn_IAP_border.png"
const LABEL_PLATE := "btn_IAP_lable.png"
const COST_FONT_SIZE := 17   # UILabel default
const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans", "Liberation Sans", "Arial"]

var cost := 0:
	set(value):
		cost = value
		if _cost_label != null:
			_cost_label.text = str(cost)

var _cost_label: Label


static func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## `consumable_image` is the badge art (btn_mystery_selection.png etc.).
## Offsets are the original's per-call arguments.
func setup(consumable_image: String, label_x_offset: int, label_y_offset: int,
		cost_value: int, cost_x_offset: int, cost_y_offset: int) -> void:
	var mask := _tex(MASK)
	var plate := _tex(LABEL_PLATE)
	var mask_size: Vector2 = mask.get_size() if mask != null else Vector2.ZERO
	var plate_size: Vector2 = plate.get_size() if plate != null else Vector2.ZERO
	var w: float = plate_size.x if mask_size.x <= plate_size.x else mask_size.x
	var h: float = mask_size.y + plate_size.y + float(label_y_offset)
	custom_minimum_size = Vector2(w, h)
	size = Vector2(w, h)
	ignore_texture_size = true
	# PASS, not STOP: a drag that started on a scroll strip and crosses the
	# badge must keep delivering motion to the screen's _unhandled_input, as
	# UIKit keeps a pan on the view it began in. STOP swallowed the motion
	# and left the strip stranded (found by the play-through driver on
	# scSelectCupShape). Taps on the badge still arrive.
	mouse_filter = Control.MOUSE_FILTER_PASS
	cost = cost_value

	var bg := Sprite2D.new()
	bg.texture = _tex(BACKGROUND)
	bg.centered = false
	add_child(bg)

	var masked: Sprite2D = MaskedSprite.new()
	masked.texture = _tex(consumable_image)
	masked.set("mask", mask)
	# btn_IAP_mask.png is a grayscale image mask (CGImage mask semantics).
	masked.set("mask_mode", MaskedSprite.MaskMode.LUMINANCE)
	masked.position = mask_size * 0.5
	add_child(masked)

	var border := Sprite2D.new()
	border.texture = _tex(BORDER)
	border.centered = false
	add_child(border)

	var plate_pos := Vector2(floorf(float(label_x_offset)),
		floorf(float(label_y_offset) + mask_size.y))
	var plate_sprite := Sprite2D.new()
	plate_sprite.texture = plate
	plate_sprite.centered = false
	plate_sprite.position = plate_pos
	add_child(plate_sprite)

	_cost_label = Label.new()
	UILabelFrame.set_frame(_cost_label, Rect2(Vector2(floorf(float(cost_x_offset)
		+ plate_pos.x), floorf(float(cost_y_offset) + plate_pos.y)), plate_size))
	_cost_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var font := SystemFont.new()
	font.font_names = PackedStringArray(FONT_NAMES)
	_cost_label.add_theme_font_override("font", font)
	_cost_label.add_theme_font_size_override("font_size", COST_FONT_SIZE)
	_cost_label.add_theme_color_override("font_color", Color.BLACK)
	_cost_label.text = str(cost)
	_cost_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cost_label)
