# UIButton's generic press / disabled look, for every TextureButton in the
# port (generated from nibs or built in code). Autoload.
#
# Read from iOS 6.1.3 UIKit:
#   -[UIButton layoutSubviews] (0x32F78480): when the image for the current
#   state FALLS BACK to the normal-state image (no art of its own for that
#   state, _imageForState:usesImageForNormalState: 0x32F57878 /
#   _backgroundForState:usesBackgroundForNormalState: 0x32F57F18), the image
#   view gets
#     drawMode 2 if adjustsImageWhenHighlighted && !showsTouchWhenHighlighted
#                 && highlighted,
#     drawMode 1 else if adjustsImageWhenDisabled && !enabled,
#     drawMode 0 otherwise.
#   -[UIImageView(UIImageViewInternal) _setImageViewContents:] (0x32F4EDB4)
#   then redraws the image and fills its rect with
#     mode 2: blackColor, alpha 0.46667, composite op 5 (= SourceAtop, per
#             CoreGraphics' CGContextSetBlendMode.op table 0x312CE848)
#             -> every colour channel x (1 - 0.46667), alpha untouched;
#     mode 1: lightGrayColor, alpha 0.5, composite op 8 (= DestinationOut)
#             -> alpha x 0.5, colour untouched.
#   Both are exactly a modulate: (0.53333, 0.53333, 0.53333, 1) and
#   (1, 1, 1, 0.5). Applied on self_modulate (children -- titles, badges --
#   are separate views in UIKit and are not adjusted).
#
#   UIControl tracking (-touchesBegan: 0x3301C4A8, -touchesMoved: 0x3307DEB4,
#   -touchesEnded: 0x3301CC18, _UIControlMostlyInsideEdgeInsets 0x32FE5DF0):
#   highlighted on touch-down; while the finger moves it stays highlighted
#   within 70 pt of the frame; releasing within those 70 pt is
#   touchUpInside; a press shorter than 0.12 s stays highlighted until
#   0.12 s have passed (_unhighlight is performed after the remainder).
#
# Defaults: -[UIButton initWithFrame:] (0x32F5744C) sets both adjusts flags
# YES; -initWithCoder: (0x330D1BA8) decodes UIAdjustsImageWhenHighlighted /
# UIAdjustsImageWhenDisabled (every button in this game's nibs has both YES).
# Generated nodes carry them as metadata/uikit_adjusts_highlighted /
# metadata/uikit_adjusts_disabled, and metadata/uikit_has_highlighted_art /
# metadata/uikit_has_disabled_art when the nib gives that state its own
# image. A node may set metadata/uikit_skip = true to opt out entirely.
#
# PORT CHOICE: a button WITHOUT uikit_adjusts_disabled metadata (built in
# code) is not dimmed when disabled. Port code also uses `disabled` for the
# original's userInteractionEnabled = NO, which UIKit never dims
# (StickSelectViewController's spin, mb_ThrowBallVC's close); a code-made
# button that stands for setEnabled:NO opts in by setting the metadata.

extends Node

const HIGHLIGHT_TINT := Color(1.0 - 0.46667, 1.0 - 0.46667, 1.0 - 0.46667, 1.0)
const DISABLED_TINT := Color(1.0, 1.0, 1.0, 0.5)
const TOUCH_SLOP := 70.0
const MIN_HIGHLIGHT_MSEC := 120

## button -> state
var _state: Dictionary = {}

# -- touch ownership ----------------------------------------------------------
# UIKit delivers a touch to the view it BEGAN in for its whole life; buttons it
# merely passes over never see it. Godot's GUI instead hands mouse motion (and
# the release) to whatever STOP Control is under the cursor, so a donut or
# any other drag froze the moment it crossed the back / next button (seen on
# the donut fryer). For a press that did not land on a button, every
# tracked button ignores the mouse until the release.
var _mouse_held := false
var _press_on_button := false
var _ignoring: Dictionary = {}   # BaseButton -> its mouse_filter before


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	for n in get_tree().root.find_children("*", "TextureButton", true, false):
		_track(n)


func _on_node_added(n: Node) -> void:
	if n is TextureButton:
		_track(n)


func _track(n: Node) -> void:
	if _state.has(n) or n.get_meta("uikit_skip", false):
		return
	var b := n as BaseButton
	_state[b] = {"held": false, "within": false, "down": 0, "until": 0,
		"fired": false, "base": Color.WHITE, "applied": null}
	# A screen kept under a push leaves the tree and comes back: connect once.
	if not b.button_down.is_connected(_on_down):
		b.button_down.connect(_on_down.bind(b))
		b.pressed.connect(_on_pressed.bind(b))
		b.button_up.connect(_on_up.bind(b))
		b.tree_exiting.connect(_forget.bind(b))


## Out of the tree: drop the tint (the node is left as its code last set it)
## and the press; the entry is rebuilt if it comes back.
func _forget(b: BaseButton) -> void:
	if not _state.has(b):
		return
	var st: Dictionary = _state[b]
	if st["applied"] != null and is_instance_valid(b) and b.self_modulate == st["applied"]:
		b.self_modulate = st["base"]
	_state.erase(b)


func _on_down(b: BaseButton) -> void:
	_press_on_button = true
	var st: Dictionary = _state.get(b, {})
	if st.is_empty():
		return
	st["held"] = true
	st["within"] = true
	st["fired"] = false
	st["down"] = Time.get_ticks_msec()


func _on_pressed(b: BaseButton) -> void:
	var st: Dictionary = _state.get(b, {})
	if not st.is_empty():
		st["fired"] = true


func _on_up(b: BaseButton) -> void:
	var st: Dictionary = _state.get(b, {})
	if st.is_empty() or not st["held"]:
		return
	st["held"] = false
	st["until"] = int(st["down"]) + MIN_HIGHLIGHT_MSEC
	# Godot already fired (a release inside -- `pressed` comes before
	# `button_up`): never twice, even if the handler moved the button.
	if st["fired"] or not is_instance_valid(b) or b.disabled or b.toggle_mode \
			or b.action_mode != BaseButton.ACTION_MODE_BUTTON_RELEASE:
		return
	# Godot fires `pressed` only for a release inside the rect; UIKit's
	# touchUpInside reaches 70 pt further.
	var p := b.get_global_mouse_position()
	var r := b.get_global_rect()
	if not r.has_point(p) and r.grow(TOUCH_SLOP).has_point(p):
		b.pressed.emit()


func _process(_dt: float) -> void:
	var now := Time.get_ticks_msec()
	for b: BaseButton in _state.keys():
		if not is_instance_valid(b):
			_state.erase(b)
			continue
		if not b.is_inside_tree():
			continue
		var st: Dictionary = _state[b]
		var highlighted := false
		if st["held"]:
			st["within"] = b.get_global_rect().grow(TOUCH_SLOP).has_point(b.get_global_mouse_position())
			highlighted = st["within"]
		elif now < int(st["until"]):
			highlighted = true
		var tb := b as TextureButton
		var has_h_art: bool = b.get_meta("uikit_has_highlighted_art", false) \
			or (tb != null and tb.texture_pressed != null)
		var has_d_art: bool = b.get_meta("uikit_has_disabled_art", false) \
			or (tb != null and tb.texture_disabled != null)
		if has_h_art:
			# Own pressed art: Godot draws it while pressing inside; carry
			# that out to UIKit's 70 pt.
			b.keep_pressed_outside = st["held"] and st["within"]
		var tint := Color.WHITE
		if highlighted and not b.disabled and not has_h_art \
				and b.get_meta("uikit_adjusts_highlighted", true):
			tint = HIGHLIGHT_TINT
		elif b.disabled and not has_d_art and b.get_meta("uikit_adjusts_disabled", false):
			tint = DISABLED_TINT
		_apply(b, st, tint)


## Multiply `tint` onto whatever self_modulate the screen's own code set,
## and give that value back when the tint goes away.
func _apply(b: BaseButton, st: Dictionary, tint: Color) -> void:
	var cur := b.self_modulate
	if st["applied"] == null:
		if tint == Color.WHITE:
			return
		st["base"] = cur
	elif cur != st["applied"]:
		st["base"] = cur          # the screen changed it meanwhile
	if tint == Color.WHITE:
		b.self_modulate = st["base"]
		st["applied"] = null
		return
	var want: Color = st["base"] * tint
	b.self_modulate = want
	st["applied"] = want


## For tests: the tint currently applied to `b` (WHITE when none).
func tint_of(b: BaseButton) -> Color:
	var st: Dictionary = _state.get(b, {})
	if st.is_empty() or st["applied"] == null:
		return Color.WHITE
	var base: Color = st["base"]
	var a: Color = st["applied"]
	return Color(a.r / maxf(base.r, 1e-6), a.g / maxf(base.g, 1e-6),
		a.b / maxf(base.b, 1e-6), a.a / maxf(base.a, 1e-6))


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if (event as InputEventMouseButton).pressed:
			_mouse_held = true
			_press_on_button = false     # set by _on_down during GUI handling
		else:
			_mouse_held = false
			if not _ignoring.is_empty():
				# After this release has gone through (to its own view).
				call_deferred("_restore_buttons")
	elif event is InputEventMouseMotion and _mouse_held and not _press_on_button \
			and _ignoring.is_empty():
		for b in _state.keys():
			# CoinHUD manages its own GET COINS button the same way.
			if is_instance_valid(b) and (b as Control).name != "GetCoinsButton":
				_ignoring[b] = (b as Control).mouse_filter
				(b as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE


func _restore_buttons() -> void:
	if _mouse_held:
		return   # a new press already started; keep until its release
	for b in _ignoring.keys():
		if is_instance_valid(b):
			(b as Control).mouse_filter = _ignoring[b]
	_ignoring.clear()
