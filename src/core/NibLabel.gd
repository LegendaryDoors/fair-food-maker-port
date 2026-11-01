# UILabel.adjustsFontSizeToFitWidth for a generated Label.
# The scene builder (core/import/SceneBuilder.gd) attaches this to labels
# whose nib sets it; screens never attach it by hand.
#
# A single-line UILabel with adjustsFontSizeToFitWidth draws its text at the
# largest size from its font's size down to the minimum that fits the width;
# text still too wide at the minimum is then cut the way its lineBreakMode
# says -- the scene sets that on the Label itself (text_overrun_behavior,
# clip_text), so this script only picks the size.
#
# The minimum is minimumScaleFactor x the font size when the nib has a scale
# factor, else minimumFontSize. INFERRED: iOS 6 introduced the scale factor
# and the nibs archive both, consistently (6 = 0.353 x 17, 10 = 0.588 x 17,
# 8.5 = 0.5 x 17), so the choice only matters if a screen changes the font
# size.
# PORT CHOICE: whole point sizes, never below the minimum (8.5 -> 9); UIKit
# shrinks to fractional sizes.
#
# A screen that sets its own font size (setFont:) changes the size this
# shrinks FROM, as setting a UILabel's font does.
extends Label

@export var adjusts_font_size_to_fit_width := false
@export var minimum_font_size := 0.0
@export var minimum_scale_factor := 0.0

var _base_size := 0
var _applied := 0
var _last_text := ""
var _last_width := -1.0


func _ready() -> void:
	_base_size = get_theme_font_size("font_size")
	_applied = _base_size
	set_process(adjusts_font_size_to_fit_width)
	if adjusts_font_size_to_fit_width:
		_fit()


func _process(_delta: float) -> void:
	var current := get_theme_font_size("font_size")
	if current != _applied:
		_base_size = current           # a screen set its own size
	elif text == _last_text and size.x == _last_width:
		return
	_fit()


func _min_size() -> int:
	var m := minimum_font_size
	if minimum_scale_factor > 0.0:
		m = minimum_scale_factor * float(_base_size)
	return int(ceil(m - 0.001))


func _fit() -> void:
	_last_text = text
	_last_width = size.x
	var fs := _base_size
	var font := get_theme_font("font")
	if font != null and text != "":
		var floor_size := mini(_min_size(), _base_size)
		while fs > floor_size and \
				font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > size.x:
			fs -= 1
	_applied = fs
	if get_theme_font_size("font_size") != fs:
		add_theme_font_size_override("font_size", fs)
