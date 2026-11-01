# Base controller attached to every generated scene.
#
# The original screens were UIViewControllers wired to their nib through
# outlets and target/action pairs. This reproduces that: on load it reads the
# screen's bindings and connects each button to a method named after the
# original selector.
#
#     backClick:  ->  _on_backClick()
#     nextClick:  ->  _on_nextClick()
#
# A screen with no bespoke script still gets working back/next navigation from
# the defaults here, which is what makes all 86 screens browsable before any
# gameplay exists.

class_name Screen
extends Node2D

## Set by Nav before the scene enters the tree.
var screen_name: String = ""

var _outlets: Dictionary = {}
var _instruction_tween: Tween


## GROUNDED: there is no timed fade. The port's INSTRUCTION_HOLD /
## INSTRUCTION_FADE were invented -- the banner never dismisses itself.
##
## changeInstruction: jumps instIV SLIDE_OFFSET px to the right, swaps its
## image, and animates back to its authored home over 0.25s with
## UIViewAnimationCurveEaseInOut. It is hidden *explicitly* by gameplay events
## (blenderClick:, showNextButton, the start of a pour), never by a timeout.
##
## showNextButton slides the next button in exactly the same way, and hides
## instIV as it does so.
const INSTRUCTION_SLIDE := 0.25
const NEXT_SLIDE := 0.25
const SLIDE_OFFSET := 500.0

## Every ms screen disables its back button on entry and re-enables it 0.5s
## later (screenSetup 0x429F4, 0x548E0, 0x50918).
const BACK_LOCKOUT := 0.5

var _instruction_home := Vector2.ZERO
var _instruction_home_set := false

## The nibs do not agree on what these views are called, and this class used to
## hardcode one spelling each -- so on every screen using another name the
## helpers below resolved nothing and silently did nothing at all. Counted
## across the 56 generated scenes:
##
##   next:  nextButton 63, btn_next 3, nextBtn 1
##   back:  backButton 55, btn_back 17, backBtn 4
##   inst:  instIV 56, instruction 6, instructionView 1, inst_image 1
##
## So the back-button lockout was inert on ~21 screens and the instruction
## slide on 8. Resolve by trying each spelling in order of prevalence.
const NEXT_OUTLETS := ["nextButton", "btn_next", "nextBtn"]
const BACK_OUTLETS := ["backButton", "btn_back", "backBtn"]
const INSTRUCTION_OUTLETS := ["instIV", "instruction", "instructionView",
	"inst_image"]


## First of `names` that resolves to a node other than the screen itself.
func first_outlet(names: Array) -> Node:
	for n: String in names:
		var o := outlet(n)
		if o != null and o != self:
			return o
	return null


func _ready() -> void:
	if screen_name == "":
		screen_name = name
	_outlets = Bindings.outlets(screen_name)
	_wire_actions()
	_hide_upsells()
	_place_instruction()
	# Only the food-making screens do this; the menus have no screenSetup.
	if screen_name.begins_with("ms"):
		lock_back_button()
	on_enter()


## GROUNDED: productPurchased: (0x44740) ends with
##     if (boolForKey(FF_KEY_EVERYTHING)) buyAllBtn.setHidden(YES);
## The port ships everything unlocked, i.e. FF_KEY_EVERYTHING is true, so the
## original would hide BUY ALL on every gameplay screen. We match that.
##
## PORT CHOICE: it stays on the main menu, where pressing it explains that
## everything is unlocked. That is a deliberate divergence, not the original's
## behaviour -- kept because the button is authentic art worth showing.
const UNLOCK_MESSAGE := "Everything is already unlocked in this port."
## Was ["MainMenuViewController"]. MainMenu viewWillAppear: (0x1F62C) itself
## hides buyAllBtn when FF_KEY_EVERYTHING is owned, and the port owns
## everything, so Buy All is hidden everywhere.
const KEEPS_BUY_ALL: Array[String] = []

## Guards against the outlet resolving to the screen itself: some nibs have no
## 320x480 container, so their root view *is* an outlet and its path is ".".
## StickSelectViewController is one, and hiding it blanks the whole screen.
func _hide_upsells() -> void:
	var hide := ["adButton", "mg3button"]
	if not KEEPS_BUY_ALL.has(screen_name):
		hide.append_array(["buyAllBtn", "buyMysterySelect", "buyMysteryFlavor",
			"buyMysteryExtra", "buySpin"])
	for outlet_name in hide:
		var n := outlet(outlet_name)
		if n != null and n != self:
			n.visible = false


## Shown when an IAP button is pressed. Built in code because the original's
## alert was a UIAlertView, which has no nib to extract.
func show_unlock_notice() -> void:
	Audio.play("button_press")
	show_alert(UNLOCK_MESSAGE, ["OK"], Callable())


## UIAlertView -initWithTitle:message:delegate:cancelButtonTitle:
## otherButtonTitles: + -show, rebuilt from iOS 6.1.3 UIKit (the popup
## style: blue glass, see UIAlert below).
##
## `buttons[0]` is the cancelButtonTitle when the original had one (every
## alert in the game does): it is the left button of two, the bottom one of
## three or more, and gets the darker art. `on_choice(title)` runs at the tap
## (alertView:clickedButtonAtIndex: timing); `on_dismissed(title)` after the
## 0.2 s fade (alertView:didDismissWithButtonIndex:). `click_sound`: a
## UIAlertView button makes no sound of its own -- the app only hears one if
## its delegate plays it; pass false for alerts whose delegate does not.
## `title`: the game passes "" for most alerts (an empty title still takes
## room: the message sits 7 pt lower, as on the device).
##
## Returns the alert's CanvasLayer (layer 200, a child of this screen); it is
## freed when the alert goes away. While it is up it takes every touch.
func show_alert(message: String, buttons: Array, on_choice: Callable,
		click_sound: bool = true, title: String = "",
		on_dismissed: Callable = Callable()) -> CanvasLayer:
	var a := UIAlert.new()
	a.title_text = title
	a.message_text = message
	a.button_titles = buttons.duplicate()
	a.on_choice = on_choice
	a.on_dismissed = on_dismissed
	a.click_sound = click_sound
	add_child(a)
	return a


## Is one of this screen's UIAlertViews still up (not yet tapped)?
func alert_showing() -> bool:
	for c in get_children():
		if c is UIAlert and not (c as UIAlert).is_dismissing() and not c.is_queued_for_deletion():
			return true
	return false


## The iOS 6 UIAlertView, popup style (alertSheetStyle 4, set by
## -popupAlertAnimated:animationType:atOffset: 0x3308378C). Addresses are in
## iOS 6.1.3 UIKit (dyld_shared_cache_armv7). Points throughout; the art is
## UIKit's @2x artwork, drawn at half size.
class UIAlert extends CanvasLayer:
	const UIScrollSim := preload("res://core/UIScrollSim.gd")
	## +minimumSize (0x33291A60) = the background image's size: 284 x 62.
	const WIDTH := 284.0
	const MIN_HEIGHT := 62.0
	## -_titleHorizontalInset (0x330885B8) 12, -_titleVerticalTopInset
	## (0x330885E8) 15, -_titleVerticalBottomInset (0x33088674) 18 for the
	## popup style; -layout (0x330859F0) puts the message 7 below the title
	## and adds 5 after it when there is a title.
	const TEXT_INSET_X := 12.0
	const TITLE_TOP := 15.0
	const TITLE_BOTTOM := 18.0
	const BODY_GAP := 7.0
	const BODY_TAIL_WITH_TITLE := 5.0
	## -_buttonHeight (0x3308858C) 43; -layout: buttons 11 pt in, 8 pt apart,
	## over (width - 6); 7 pt between stacked rows, 21 before a stacked
	## cancel; -_bottomVerticalInset (0x33088734) 7, then 9 more for the
	## popup style.
	const BUTTON_HEIGHT := 43.0
	const BUTTON_X := 11.0
	const BUTTON_GAP := 8.0
	const ROW_GAP := 7.0
	const CANCEL_GAP := 21.0
	const BOTTOM_INSET := 7.0
	const POPUP_TAIL := 9.0
	## UIAlertTitleTextFont (0x330884D8) bold 18 for the popup style;
	## UIAlertBodyTextFont (0x33082ECC) 16; button titles bold 18, shrinking
	## to 12 to fit, inset 4 pt each side (-[UIAlertButton initWithTitle:]
	## 0x330834D8). All white with a black shadow 1 pt UP (offset 0,-1).
	const TITLE_SIZE := 18
	const BODY_SIZE := 16
	const BUTTON_TITLE_SIZE := 18
	const BUTTON_TITLE_MIN := 12
	const BUTTON_TITLE_INSET := 4.0
	## iOS 6 on a retina screen: GSFontSystemFontNameForScaleFactor(2.0)
	## (GraphicsServices 0x34C2FEFC) = ".Helvetica NeueUI". PORT CHOICE:
	## the nearest installed face stands in.
	const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans", "Liberation Sans", "Arial"]
	## Background contentsCenter (0, 21/31, 1, 1/62) in -layout: only one
	## row, 42 pt down, stretches (in @2x pixels: 84 top, 38 bottom).
	const BG_CAP_TOP_PX := 84
	const BG_CAP_BOTTOM_PX := 38
	## +[_UIAlerts_Support buttonContentStretch] (0x33083694) (5/11, 0,
	## 1/11, 1): 5 pt caps left and right (10 px @2x).
	const BUTTON_CAP_PX := 10
	## -_performPopup:animationType:revealedBySpringBoardAlert: (0x33083E88):
	## alpha 0 -> 1 over 0.4 s while the scale goes 0.01 -> 1.1 (0.2 s),
	## then _growAnimationDidStop: (0x330892D8) 1.1 -> 0.9 (0.1 s) and
	## _bubbleAnimationShrinkDidStop: (0x33089430) 0.9 -> 1.0 (0.1 s). All
	## UIView default curve (EaseInOut).
	const POP_FADE := 0.4
	const POP_SCALES := [[0.01, 1.1, 0.2], [1.1, 0.9, 0.1], [0.9, 1.0, 0.1]]
	## +[_UIAlertManager showDimmingViewAnimated:] (0x33088DBC): the
	## UIAlertViewDimmingSpotlight vignette, alpha 0 -> 1 over 0.5 s.
	const DIM_IN := 0.5
	## -_performPopoutAnimationAnimated:coveredBySpringBoardAlert:
	## (0x3308A0E0): alpha -> 0 over 0.2 s, no scale; the dimming view starts
	## a 1.0 s fade (+hideDimmingViewAnimated: 0x3308A5E4) but the alert
	## window is hidden when the 0.2 s ends (_removeAlertWindowOrShowAnOldAlert
	## 0x3308AB14), taking the dim with it.
	const POP_OUT := 0.2
	const DIM_OUT := 1.0
	## UIControl tracking (-[UIControl touchesMoved:] 0x3307DEB4,
	## _UIControlMostlyInsideEdgeInsets 0x32FE5DF0): a pressed button stays
	## highlighted, and fires on release, within 70 pt of its frame.
	const TOUCH_SLOP := 70.0

	var title_text := ""
	var message_text := ""
	var button_titles: Array = []
	var on_choice: Callable
	var on_dismissed: Callable
	var click_sound := true

	var _box: Node2D
	var _dim: TextureRect
	var _buttons: Array[Button] = []
	var _button_bgs: Array[NinePatchRect] = []
	var _gate: Node
	var _tracking := -1
	var _dismissing := false
	var _cancel_index := 0
	var _tex_button: Texture2D
	var _tex_cancel: Texture2D
	var _tex_press: Texture2D

	static var _fonts := {}

	func is_dismissing() -> bool:
		return _dismissing

	func _ready() -> void:
		layer = 200
		name = "UIAlertView"
		set_meta("uikit_window", true)
		_tex_button = _art("UIPopupAlertSheetButton.png")
		_tex_cancel = _art("UIPopupAlertSheetDefaultButton.png")
		_tex_press = _art("UIPopupAlertSheetButtonPress.png")
		_build()
		_gate = Nav.add_touch_gate(_on_touch)
		_pop_in()

	func _exit_tree() -> void:
		_release_gate()

	func _release_gate() -> void:
		if _gate != null and is_instance_valid(_gate):
			_gate.set("handler", Callable())
			_gate.set("active", false)
			_gate.queue_free()
		_gate = null

	static func font(bold: bool) -> Font:
		var key := 700 if bold else 400
		if not _fonts.has(key):
			var f := SystemFont.new()
			f.font_names = PackedStringArray(FONT_NAMES)
			f.font_weight = key
			_fonts[key] = f
		return _fonts[key]

	## The import cache's uikit/ art (present when the player supplied
	## Shared@2x.artwork), else the drawn fallback below.
	static func _art(file: String) -> Texture2D:
		var t := Assets.uikit_texture(file)
		return t if t != null else _fallback(file)

	## FALLBACK -- NOT the original look. The alert's art is iOS 6 UIKit's own
	## (Shared@2x.artwork), which only exists on an iOS 6 device or SDK; a
	## player who imported without one would get
	## text floating over the game with no box at all. These are plain drawn
	## stand-ins at the real art's pixel sizes (so the nine-patch layout above
	## is unchanged): a rounded blue box with a white rim, rounded translucent
	## buttons, a flat dim. The real art always wins when it is present.
	static var _fallbacks := {}

	static func _fallback(file: String) -> Texture2D:
		if _fallbacks.has(file):
			return _fallbacks[file]
		var t: Texture2D = null
		match file:
			"UIAlertViewDimmingSpotlight.png":
				var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
				img.fill(Color(0, 0, 0, 0.45))
				t = ImageTexture.create_from_image(img)
			"UIPopupAlertSheetBackground.png":
				t = _rounded(568, 124, 16.0, Color(0.04, 0.11, 0.33, 0.9),
					Color(1, 1, 1, 0.9), 4.0)
			"UIPopupAlertSheetButton.png":
				t = _rounded(22, 86, 10.0, Color(1, 1, 1, 0.2), Color(1, 1, 1, 0.45), 2.0)
			"UIPopupAlertSheetDefaultButton.png":
				t = _rounded(22, 86, 10.0, Color(0, 0, 0, 0.3), Color(1, 1, 1, 0.45), 2.0)
			"UIPopupAlertSheetButtonPress.png":
				t = _rounded(22, 86, 10.0, Color(0.35, 0.55, 1.0, 0.6), Color(1, 1, 1, 0.6), 2.0)
		_fallbacks[file] = t
		return t

	## A w x h rounded rectangle (signed-distance, anti-aliased edge) with a
	## border of `bw` px.
	static func _rounded(w: int, h: int, r: float, fill: Color, border: Color,
			bw: float) -> ImageTexture:
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		var half := Vector2(w, h) * 0.5
		for y in h:
			for x in w:
				var q := (Vector2(x + 0.5, y + 0.5) - half).abs() - (half - Vector2(r, r))
				var d := q.max(Vector2.ZERO).length() + minf(maxf(q.x, q.y), 0.0) - r
				var c := border if d > -bw else fill
				c.a *= clampf(0.5 - d, 0.0, 1.0)
				img.set_pixel(x, y, c)
		return ImageTexture.create_from_image(img)

	## Height UIKit's string drawing gives `text` at `size` in `width`:
	## an empty string is 0 tall (WebKit's __web_drawInRect:... never enters
	## its line loop for length 0).
	static func text_height(text: String, bold: bool, size: int, width: float) -> float:
		if text == "":
			return 0.0
		var s := font(bold).get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_CENTER,
			width, size, -1, TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND)
		return ceilf(s.y)

	## -layout's geometry for `title` / `message` / `count` buttons: the
	## text frames, the button frames (cancel first) and the alert height.
	static func layout(title: String, message: String, count: int) -> Dictionary:
		var text_w := WIDTH - 2.0 * TEXT_INSET_X
		var title_h := text_height(title, true, TITLE_SIZE, text_w)
		var y := TITLE_TOP + title_h + TITLE_BOTTOM
		var title_rect := Rect2(TEXT_INSET_X, TITLE_TOP, text_w, title_h)
		var body_rect := Rect2()
		if message != "":
			var body_h := text_height(message, false, BODY_SIZE, text_w)
			body_rect = Rect2(TEXT_INSET_X, TITLE_TOP + title_h + BODY_GAP, text_w, body_h)
			y += body_h + BODY_TAIL_WITH_TITLE
		var rects: Array[Rect2] = []
		var cols := count if count <= 2 else 1
		var height := y
		if count > 0:
			var bw := float(int((WIDTH - 6.0 - float(cols + 1) * BUTTON_GAP) / float(cols)))
			if count <= 2:
				for i in count:
					rects.append(Rect2(BUTTON_X + i * (bw + BUTTON_GAP), y, bw, BUTTON_HEIGHT))
				height = y + BUTTON_HEIGHT + BOTTOM_INSET + POPUP_TAIL
			else:
				# Cancel (index 0) goes to the bottom, 21 pt clear of the rest.
				var step := BUTTON_HEIGHT + ROW_GAP
				rects.append(Rect2(BUTTON_X, y + (count - 1) * step - ROW_GAP + CANCEL_GAP,
					bw, BUTTON_HEIGHT))
				for i in range(1, count):
					rects.append(Rect2(BUTTON_X, y + (i - 1) * step, bw, BUTTON_HEIGHT))
				height = y + (count - 2) * step + BUTTON_HEIGHT + CANCEL_GAP \
					+ BUTTON_HEIGHT + BOTTOM_INSET + POPUP_TAIL
		return {"title": title_rect, "body": body_rect, "buttons": rects,
			"height": maxf(MIN_HEIGHT, height)}

	func _build() -> void:
		var geo := layout(title_text, message_text, button_titles.size())
		var h: float = geo["height"]
		# _updateFrameForDisplay (0x330888C8): centred on the screen
		# (UIRectCenteredIntegralRect); the game hides the status bar.
		var origin := Vector2(floorf((320.0 - WIDTH) * 0.5), floorf((480.0 - h) * 0.5))

		_dim = TextureRect.new()
		_dim.texture = _art("UIAlertViewDimmingSpotlight.png")
		_dim.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_dim.stretch_mode = TextureRect.STRETCH_SCALE
		_dim.size = Vector2(320, 480)
		_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_dim.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		_dim.modulate.a = 0.0
		add_child(_dim)

		_box = Node2D.new()
		_box.name = "Alert"
		_box.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		_box.position = origin + Vector2(WIDTH, h) * 0.5
		add_child(_box)
		var corner := -Vector2(WIDTH, h) * 0.5

		var bg_tex := _art("UIPopupAlertSheetBackground.png")
		if bg_tex != null:
			var bg := NinePatchRect.new()
			bg.texture = bg_tex
			bg.patch_margin_top = BG_CAP_TOP_PX
			bg.patch_margin_bottom = BG_CAP_BOTTOM_PX
			bg.size = Vector2(WIDTH * 2.0, h * 2.0)
			bg.scale = Vector2(0.5, 0.5)
			bg.position = corner
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_box.add_child(bg)

		# The message label first: tests (and anything else) that look for
		# "the alert's text" read the first Label.
		if message_text != "":
			_box.add_child(_label(message_text, false, BODY_SIZE, geo["body"], corner))
		if title_text != "":
			_box.add_child(_label(title_text, true, TITLE_SIZE, geo["title"], corner))

		var rects: Array = geo["buttons"]
		for i in button_titles.size():
			var r: Rect2 = rects[i]
			var bgr := NinePatchRect.new()
			bgr.texture = _tex_cancel if i == _cancel_index and button_titles.size() >= 2 \
				else _tex_button
			bgr.patch_margin_left = BUTTON_CAP_PX
			bgr.patch_margin_right = BUTTON_CAP_PX
			bgr.size = r.size * 2.0
			bgr.scale = Vector2(0.5, 0.5)
			bgr.position = corner + r.position
			bgr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_box.add_child(bgr)
			_button_bgs.append(bgr)

			# A real Button carries the title (and a `pressed` signal) for
			# code and tests; the alert does its own hit-testing (_on_touch),
			# so the Button never sees the mouse and draws nothing itself.
			var b := Button.new()
			b.text = str(button_titles[i])
			b.flat = true
			b.focus_mode = Control.FOCUS_NONE
			b.mouse_filter = Control.MOUSE_FILTER_IGNORE
			b.position = corner + r.position
			b.size = r.size
			for st in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
				b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
			for c in ["font_color", "font_hover_color", "font_pressed_color",
					"font_focus_color", "font_hover_pressed_color", "font_disabled_color"]:
				b.add_theme_color_override(c, Color(0, 0, 0, 0))
			b.set_meta("uikit_skip", true)
			b.pressed.connect(_click.bind(i))
			var size := BUTTON_TITLE_SIZE
			var avail := r.size.x - 2.0 * BUTTON_TITLE_INSET
			while size > BUTTON_TITLE_MIN and font(true).get_string_size(b.text,
					HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > avail:
				size -= 1
			var l := _label(b.text, true, size,
				Rect2(BUTTON_TITLE_INSET, 0, avail, r.size.y), Vector2.ZERO)
			l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			l.autowrap_mode = TextServer.AUTOWRAP_OFF
			b.add_child(l)
			_box.add_child(b)
			_buttons.append(b)

	func _label(text: String, bold: bool, size: int, r: Rect2, corner: Vector2) -> Label:
		var l := Label.new()
		# Wrap BEFORE size: a Label whose size is set while autowrap is still
		# off is clamped to its one-line width (1057 px for the stand notice)
		# and keeps it after wrapping is turned on -- the message then ran off
		# the alert as one line.
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.text = text
		l.position = corner + r.position
		l.size = r.size
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.clip_text = false
		l.add_theme_font_override("font", font(bold))
		l.add_theme_font_size_override("font_size", size)
		l.add_theme_color_override("font_color", Color.WHITE)
		l.add_theme_color_override("font_shadow_color", Color.BLACK)
		l.add_theme_constant_override("shadow_offset_x", 0)
		l.add_theme_constant_override("shadow_offset_y", -1)
		l.add_theme_constant_override("line_spacing", 0)
		return l

	func _pop_in() -> void:
		_box.modulate.a = 0.0
		_box.scale = Vector2.ONE * 0.01
		var t := create_tween().set_parallel(true)
		t.tween_method(_set_dim, 0.0, 1.0, DIM_IN)
		t.tween_method(_set_alpha, 0.0, 1.0, POP_FADE)
		var s := create_tween()
		for leg: Array in POP_SCALES:
			s.tween_method(_set_scale.bind(leg[0], leg[1]), 0.0, 1.0, leg[2])

	func _set_dim(t: float) -> void:
		if _dim != null:
			_dim.modulate.a = UIScrollSim.curve(t)

	func _set_alpha(t: float) -> void:
		_box.modulate.a = UIScrollSim.curve(t)

	func _set_fade(t: float) -> void:
		_box.modulate.a = 1.0 - UIScrollSim.curve(t)

	func _set_dim_out(t: float) -> void:
		if _dim != null:
			_dim.modulate.a = 1.0 - UIScrollSim.curve(t)

	func _set_scale(t: float, from: float, to: float) -> void:
		_box.scale = Vector2.ONE * lerpf(from, to, UIScrollSim.curve(t))

	## Every touch while the alert is up comes here (Nav.add_touch_gate):
	## the alert window takes them all. PORT CHOICE: buttons answer during
	## the 0.4 s pop-in too (UIKit ignores all touches until it settles);
	## nothing else does.
	func _on_touch(event: InputEvent) -> void:
		if _dismissing or Nav.is_ignoring_interaction():
			return
		var mb := event as InputEventMouseButton
		if mb != null:
			if mb.button_index != MOUSE_BUTTON_LEFT:
				return
			if mb.pressed:
				_tracking = _button_at(mb.position, 0.0)
				_highlight(_tracking)
			elif _tracking >= 0:
				var i := _tracking
				_tracking = -1
				var inside := _button_at(mb.position, TOUCH_SLOP, i) == i
				_highlight(-1)
				if inside:
					_click(i)
			return
		var mm := event as InputEventMouseMotion
		if mm != null and _tracking >= 0:
			_highlight(_tracking if _button_at(mm.position, TOUCH_SLOP, _tracking) == _tracking else -1)

	func _button_at(p: Vector2, slop: float, only: int = -1) -> int:
		for i in _buttons.size():
			if only >= 0 and i != only:
				continue
			var r := _buttons[i].get_global_rect().grow(slop)
			if r.has_point(p):
				return i
		return -1

	## The pressed state: UIPopupAlertSheetButtonPress for every button.
	func _highlight(index: int) -> void:
		for i in _button_bgs.size():
			var normal := _tex_cancel if i == _cancel_index and _buttons.size() >= 2 else _tex_button
			_button_bgs[i].texture = _tex_press if i == index and _tex_press != null else normal

	## -_buttonClicked: (0x33089B28): the delegate's clickedButtonAtIndex:
	## first, then dismissWithClickedButtonIndex:animated:YES (0x33089CA0).
	func _click(index: int) -> void:
		if _dismissing:
			return
		_dismissing = true
		var t := str(button_titles[index])
		if click_sound:
			Audio.play("button_press")
		if on_choice.is_valid():
			on_choice.call(t)
		if not is_inside_tree():
			return
		_highlight(-1)
		if not Nav.animations_enabled():
			# Dev harness (Nav.animate_transitions): gone at once.
			_finish(t)
			return
		var tw := create_tween().set_parallel(true)
		tw.tween_method(_set_fade, 0.0, 1.0, POP_OUT)
		tw.tween_method(_set_dim_out, 0.0, POP_OUT / DIM_OUT, POP_OUT)
		tw.chain().tween_callback(_finish.bind(t))

	func _finish(t: String) -> void:
		_release_gate()
		queue_free()
		if on_dismissed.is_valid():
			on_dismissed.call(t)


## PORT CHOICE: every tilt pour is
## click-and-hold in the port, but these banners said "TILT YOUR DEVICE".
## The importer (core/import/PortBanners.gd)
## rebuilds them from the game's own lettering into the import cache (no font
## is rendered); the originals are used if they are absent.
const PORT_INSTRUCTIONS := {
	"inst_pour.png": "port_inst_pour.png",                # CLICK AND HOLD / TO POUR!
	"inst_pour_batter.png": "port_inst_pour_batter.png",  # CLICK AND HOLD TO POUR / INTO THE FUNNEL!
}


static func port_instruction(image_name: String) -> String:
	var alt: String = PORT_INSTRUCTIONS.get(image_name, "")
	if alt != "" and Assets.has_image(alt):
		return alt
	return image_name


## Remember where the nib parked instIV, then slide the first banner in.
func _place_instruction() -> void:
	var item := _instruction_node()
	if item == null:
		return
	# The nib's own banner art (ipPour and fcPourBatter only ever unhide it).
	if item is Sprite2D and (item as Sprite2D).texture != null:
		var nib_art := Assets.texture_name((item as Sprite2D).texture)
		var alt := port_instruction(nib_art)
		if alt != nib_art:
			(item as Sprite2D).texture = Assets.texture(alt)
	_instruction_home = item.position
	_instruction_home_set = true
	change_instruction("")


func _instruction_node() -> Node2D:
	var iv := first_outlet(INSTRUCTION_OUTLETS)
	if iv == null or not (iv is Node2D):
		return null
	return iv as Node2D


## Does this screen's changeInstruction: hide the next button? A binary-wide
## survey found 27 screens whose changeInstruction: ends with
## `nextButton setHidden:YES` and 28 whose does not; the port used to leave
## next visible on all of them (the nib ships it visible), so the arrow was
## up before the mechanic ran on the crush and stir screens. Screens in the
## first group override this to return true. Only an explicit image call
## hides -- the "" re-slide on first appearance never does.
func instruction_hides_next() -> bool:
	return false


## Port of changeInstruction:. Passing "" keeps whatever art the nib carries
## and just re-runs the slide, which is what a screen's first appearance does.
func change_instruction(image_name: String) -> void:
	if image_name != "" and instruction_hides_next():
		var nb := first_outlet(NEXT_OUTLETS)
		if nb != null and nb is CanvasItem:
			(nb as CanvasItem).visible = false
			if nb.has_method("set_disabled"):
				nb.set("disabled", true)
	var item := _instruction_node()
	if item == null:
		return
	if not _instruction_home_set:
		_instruction_home = item.position
		_instruction_home_set = true

	if image_name != "" and item is Sprite2D:
		# A file the app does not ship (inst_spray_pops.png): the original's
		# [UIImage imageNamed:] is nil and setImage:nil leaves the banner
		# BLANK and does not keep the previous art.
		(item as Sprite2D).texture = Assets.texture(port_instruction(image_name))

	if _instruction_tween != null and _instruction_tween.is_valid():
		_instruction_tween.kill()
	item.visible = true
	item.modulate.a = 1.0
	item.position = _instruction_home + Vector2(SLIDE_OFFSET, 0)
	_instruction_tween = create_tween()
	_instruction_tween.tween_property(item, "position", _instruction_home,
		INSTRUCTION_SLIDE).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## The original hides instIV outright on the interaction that makes it stale.
func dismiss_instruction() -> void:
	if _instruction_tween != null and _instruction_tween.is_valid():
		_instruction_tween.kill()
	var item := _instruction_node()
	if item != null:
		item.visible = false


const NEXT_HOME_META := "screen_next_home"


## Port of showNextButton: slide the button in from SLIDE_OFFSET px right and
## hide the instruction banner in the same breath.
func show_next_button() -> void:
	dismiss_instruction()
	var n := first_outlet(NEXT_OUTLETS)
	if n == null or not (n is CanvasItem):
		return
	# nextButton is a TextureButton in all 56 generated scenes -- a Control,
	# NOT a Node2D. This guard used to read `n is Node2D`, so it returned
	# immediately on every screen and the grounded slide never once ran. It
	# looked fine because dismiss_instruction() above the guard still fired.
	# Both classes expose `position`, so type on CanvasItem and go through
	# get()/set() rather than a typed member access.
	var btn := n as CanvasItem
	# Remember the home once (first use): reading the CURRENT position meant
	# a second call within the 0.25 s slide took the half-slid position as
	# home and parked the button 500 px off.
	if not btn.has_meta(NEXT_HOME_META):
		btn.set_meta(NEXT_HOME_META, btn.get("position"))
	var home: Vector2 = btn.get_meta(NEXT_HOME_META)
	btn.visible = true
	if btn.has_method("set_disabled"):
		btn.set("disabled", false)
	btn.set("position", home + Vector2(SLIDE_OFFSET, 0))
	create_tween().tween_property(btn, "position", home, NEXT_SLIDE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## Disable back for BACK_LOCKOUT seconds, as every ms screen does on entry.
func lock_back_button() -> void:
	var b := first_outlet(BACK_OUTLETS)
	if b == null:
		return
	b.set("disabled", true)
	await get_tree().create_timer(BACK_LOCKOUT).timeout
	if is_instance_valid(b):
		b.set("disabled", false)


func _wire_actions() -> void:
	# The original could target one control from several UIControlEvents
	# (touchDown and touchUpInside on the same button). Godot has a single
	# `pressed` signal, so those collapse to one connection.
	var wired := {}

	for action in Bindings.actions(screen_name):
		var node := get_node_or_null(NodePath(action.get("node", "")))
		if node == null:
			continue
		var selector: String = action.get("selector", "")

		# Only buttons emit `pressed`. Non-button sources in the original were
		# gesture targets; those get handled by gameplay scripts later.
		if not node.has_signal("pressed"):
			continue

		var key := "%s|%s" % [node.get_path(), selector]
		if wired.has(key):
			continue
		wired[key] = true

		var method := "_on_" + selector.rstrip(":").replace(":", "_")
		var callable := Callable(self, method) if has_method(method) \
			else _fallback_for(selector)
		if callable.is_valid() and not node.pressed.is_connected(callable):
			node.pressed.connect(callable)


## Screens that do not implement a selector fall back to generic navigation,
## so unimplemented buttons still do something sensible rather than nothing.
func _fallback_for(selector: String) -> Callable:
	match selector:
		"backClick:", "back:", "backButtonClick:":
			return _on_backClick
		"nextClick:", "next:":
			return _on_nextClick
		"BuyAllClick:", "buyMysterySelectClick:", "buyMysteryFlavorClick:", \
		"buyMysteryExtraClick:", "StoreClick:", "buySpinClick:":
			return show_unlock_notice
		_:
			return Callable(self, "_on_unhandled").bind(selector)


## Move-event pacing. The original's swipe mechanics count touchesMoved:
## events (peel banana adds a fixed 18 per event, 0x97464), and iOS delivered
## at most one such event per display frame -- 60 Hz on the iPhone 4. Godot
## delivers one mouse-motion event per *PC* frame, which on a 144-240 Hz
## monitor is two to four times as often, so those accumulators ran that much
## faster than on the phone (a click peeled the banana at once). Screens
## that count move events call this first and drop the event when it says no.
## INFERRED from the platform, not read from this binary: the 60 Hz ceiling is
## the iPhone 4's touch delivery rate, and the phone may in practice deliver
## fewer; compare on hardware and tune TOUCH_MOVE_HZ from a measurement only.
const TOUCH_MOVE_HZ := 60.0
var _last_touch_move_ms := -100000


func accept_touch_move() -> bool:
	var now := Time.get_ticks_msec()
	if float(now - _last_touch_move_ms) < 1000.0 / TOUCH_MOVE_HZ - 0.5:
		return false
	_last_touch_move_ms = now
	return true


## Look up a node by its original outlet name.
func outlet(outlet_name: String) -> Node:
	var path: String = _outlets.get(outlet_name, "")
	if path == "":
		return null
	return self if path == "." else get_node_or_null(NodePath(path))


# -- default behaviour ------------------------------------------------

func _on_backClick() -> void:
	Nav.back()


func _on_nextClick() -> void:
	Nav.next()


func _on_unhandled(selector: String) -> void:
	print("[%s] unhandled action: %s" % [screen_name, selector])


## Override points for gameplay scripts.
func on_enter() -> void:
	pass


func on_exit() -> void:
	pass


## viewDidAppear: timing: Nav calls this when the push/pop slide (0.35 s)
## has finished, or at once for an unanimated change. on_enter()/on_resume()
## run when the slide STARTS (viewDidLoad / viewWillAppear: timing); work the
## original does in viewDidAppear: belongs here.
func on_did_appear() -> void:
	pass
