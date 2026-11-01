# The prize popup the football toss builds in code when the ball drops into a
# hole: -[fbtThrowballVC showPrizeView] (0x24EAC) and closePrizeDialog:
# (0x25768). There is no nib for it; every number below is from that code.
#
#   container  UIView (0,0,320,480), tag 1000000, added on top of the view;
#              its transform starts at scale 0.01 and animates to identity
#              ("Show_Upgrade_Dialog", 0.5 s, UIViewAnimationCurveLinear).
#              Its delegate is set but no didStop selector -- nothing runs
#              when it finishes.
#   children, in order:
#     prize_popup.png             initWithImage: -> natural size at (0,0)
#     the prize image             initWithImage:, centre (160,240)
#     UIButton (0,0,94,63)        background daily_login_btn.png, centre
#                                 (160,400), touchUpInside -> closePrizeDialog:
#     prize_label.png             initWithImage:, centre (160,355)
#       UILabel (0,0,74,14)       inside the plate, centre (plate.w*0.5, 16),
#                                 clear background, the label's default font
#                                 re-made at 12 pt, adjustsFontSizeToFitWidth
#                                 with minimumFontSize 6, centred, text =
#                                 getPrizeName:
#   closePrizeDialog:  "button_press", then the button's superview (this
#                      container) is removed.
#
# The full-screen container also sits over the nav buttons, so while it is up
# they cannot be pressed -- MOUSE_FILTER_STOP gives the same result. The
# screen's touch handlers test for it by tag; the port asks is_open().

extends Control
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const TAG := 1000000
const POPUP_ART := "prize_popup.png"
const CLOSE_ART := "daily_login_btn.png"
const PLATE_ART := "prize_label.png"
const CONTAINER_SIZE := Vector2(320, 480)          # initWithFrame:(0,0,320,480)
const PRIZE_CENTER := Vector2(160, 240)            # 0x43200000 / 0x43700000
const CLOSE_SIZE := Vector2(94, 63)                # 0x42BC0000 / 0x427C0000
const CLOSE_CENTER := Vector2(160, 400)            # 0x43200000 / 0x43C80000
const PLATE_CENTER := Vector2(160, 355)            # 0x43200000 / 0x43B18000
const NAME_SIZE := Vector2(74, 14)                 # 0x42940000 / 0x41600000
const NAME_CENTER_Y := 16.0                        # 0x41800000
const NAME_FONT_SIZE := 12                         # fontWithName:size: 0x41400000
const NAME_MIN_FONT_SIZE := 6                      # setMinimumFontSize: 0x40C00000
const START_SCALE := 0.01                          # CGAffineTransformScale 0.01
const ENTRANCE_SECONDS := 0.5                      # setAnimationDuration: 0.5
## The UILabel default face; the port's stand-in list, as ConsumableButton.
const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans", "Liberation Sans", "Arial"]

## Emitted after closePrizeDialog: has removed the dialog.
signal closed

var prize: Variant = null
var _tween: Tween


static func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## `prize_image` is whatever PrizeManager.get_prize_image() returned (the
## original's UIImage): a Texture2D, an Image or an image file name; null
## leaves the slot empty, as initWithImage:nil would.
func setup(p_prize: Variant, prize_image: Variant, prize_name: Variant) -> void:
	prize = p_prize
	name = "PrizeDialog"
	set_meta("tag", TAG)
	position = Vector2.ZERO
	size = CONTAINER_SIZE
	pivot_offset = CONTAINER_SIZE * 0.5      # a UIView transform is about its centre
	mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := Sprite2D.new()
	bg.centered = false
	bg.texture = _tex(POPUP_ART)
	add_child(bg)

	var img := Sprite2D.new()
	img.texture = _as_texture(prize_image)
	img.position = PRIZE_CENTER                # centred Sprite2D == setCenter:
	add_child(img)

	var close := TextureButton.new()
	close.name = "closePrizeDialog"
	close.texture_normal = _tex(CLOSE_ART)
	close.ignore_texture_size = true
	close.stretch_mode = TextureButton.STRETCH_SCALE   # a background image fills the button
	close.size = CLOSE_SIZE
	close.position = CLOSE_CENTER - CLOSE_SIZE * 0.5
	close.pressed.connect(_on_close_prize_dialog)
	add_child(close)

	var plate_tex := _tex(PLATE_ART)
	var plate := Sprite2D.new()
	plate.texture = plate_tex
	plate.position = PLATE_CENTER
	add_child(plate)

	var plate_size: Vector2 = plate_tex.get_size() if plate_tex != null else Vector2.ZERO
	var label := Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Centre (plate.w * 0.5, 16) in the plate's own coordinates; the Sprite2D is
	# centred, so its origin is the plate's top-left minus half its size.
	UILabelFrame.set_frame(label, Rect2(Vector2(plate_size.x * 0.5, NAME_CENTER_Y)
		- NAME_SIZE * 0.5 - plate_size * 0.5, NAME_SIZE))
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := SystemFont.new()
	font.font_names = PackedStringArray(FONT_NAMES)
	label.add_theme_font_override("font", font)
	label.add_theme_color_override("font_color", Color.BLACK)   # UILabel default
	label.text = "" if prize_name == null else str(prize_name)
	label.add_theme_font_size_override("font_size", _fit_font_size(font, label.text))
	plate.add_child(label)


## UILabel adjustsFontSizeToFitWidth: shrink from 12 pt toward 6 pt until the
## single line fits the 74 pt width; past the minimum it truncates.
func _fit_font_size(font: Font, text: String) -> int:
	var fs := NAME_FONT_SIZE
	while fs > NAME_MIN_FONT_SIZE \
			and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > NAME_SIZE.x:
		fs -= 1
	return fs


static func _as_texture(v: Variant) -> Texture2D:
	if v is Texture2D:
		return v
	if v is Image:
		return ImageTexture.create_from_image(v)
	if v is String or v is StringName:
		return _tex(str(v))
	return null


## The 0.5 s linear scale-in from 0.01.
## "Show_Upgrade_Dialog" is +beginAnimations:/commitAnimations (showPrizeView
## 0x24EAC): UIKit hit-tests the container at its MODEL transform, identity
## from the commit, so the full-screen UIView swallows every touch from the
## first frame of the pop-in. Godot hit-tests this Control through its
## 0.01 -> 1 scale, so an unscaled blocker just under it stands in for the
## model frame (as wm_hitmole / mb_ThrowBallVC already do); without it the
## nav buttons answered under the growing dialog. It leaves with the dialog.
## PORT CHOICE: the close button is hit where it is drawn while it grows
## (UIKit: at its full model frame).
func play_entrance() -> void:
	var parent := get_parent()
	if parent != null:
		var blocker := Control.new()
		blocker.name = "PrizeDialogBlocker"
		blocker.position = position
		blocker.size = CONTAINER_SIZE
		blocker.mouse_filter = Control.MOUSE_FILTER_STOP
		parent.add_child(blocker)
		parent.move_child(blocker, get_index())
		tree_exiting.connect(blocker.queue_free)
	scale = Vector2(START_SCALE, START_SCALE)
	_tween = create_tween()
	_tween.tween_property(self, "scale", Vector2.ONE, ENTRANCE_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)


func is_open() -> bool:
	return is_inside_tree() and not is_queued_for_deletion()


## closePrizeDialog: (0x25768).
func _on_close_prize_dialog() -> void:
	Audio.play("button_press")
	var p := get_parent()
	if p != null:
		p.remove_child(self)      # viewWithTag: must stop finding it at once
	closed.emit()
	queue_free()
