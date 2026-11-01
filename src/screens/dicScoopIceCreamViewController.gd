# Donut Ice Cream Sandwich step 6 -- pick ice cream flavours and scoop three
# balls onto the bottom half; the top half then falls from the sky, whoa.
#
# From the original binary (IMPs from the ObjC method list):
#   init 0xBA644 (the 33-colour table), viewDidLoad 0xBAAB0, viewWillAppear:
#   0xBAD0C, resetScreen 0xBAD4C, flavorClick: 0xBAF3C,
#   showIceCreamBucketWithIceCreamColor: 0xBAF98, hideIceCreamBucket 0xBB050,
#   nextClick: 0xBB10C, showScrollView 0xBB588, showIceCreamOnScoopWithColor:
#   0xBBBD4, hideIceCreamOnScoop 0xBBC64, showIceCreamOnDonutWithColor:
#   0xBBC90, isDonutFullOfIceCream 0xBBDE4, hideScrollView 0xBBEC0,
#   selectFlavorButtonClick: 0xBC030, finalizeScreen 0xBC118,
#   donutFallsFromTheSkyWhoa 0xBC1A8, draggableTouchMoved/Ended 0xBC3D0 /
#   0xBC61C, blocks sub_BBB90/sub_BBFF0 (panel fades), sub_BC24C (the fall),
#   sub_BC338 (push Frosting initWithColors:), sub_BC6C0 (scoop home);
#   -[UIImage tintedImageWithColor:] 0x144204.
#
# Mechanic, as read:
#  * The iceCreamButton toggles a colour picker over the screen: 80x80
#    buttons at (24 + 100*(i%3), 95*row) -- note the 95pt ROW pitch against
#    the 100pt content-height step, an original quirk -- each showing
#    dis_icecream_scoop.png in a (15,15,50,50) sub-frame, tinted through
#    TintedIV's ALTERNATE path with CGBlendMode 3 / Overlay (0x144204 is
#    literally a wrapper around initWithAlternateImage:andTintColor:
#    andBlendMode:3), over Sub_Button_Background.png. The panel fades
#    in/out over 0.1s while next/back drop to alpha 0. The colour table is
#    IDENTICAL to caSelectChocolate's 33 entries (same constructor sequence
#    at 0xBA644), so that screen's colors() is reused.
#  * Picking a flavour tints the bucket's dis_IceCream_For_Container.png and
#    reveals the bucket + the dis_scoop DraggableIV (235,60,64,231).
#  * Scooping happens on touch-MOVE (0xBC3D0), and the tested point is the
#    scoop's frame ORIGIN (top-left), not its centre. Pick up: origin inside
#    iceCreamInBucket.frame -- which the original reads in the BUCKET's
#    coordinate space, (13,23,189,84), while the origin is in root space, so
#    the live region sits (9,55) up-left of the bucket art; quirk kept
#    verbatim. That shows an 80x60 tinted ball riding the scoop's head (a
#    subview built in viewDidLoad 0xBAAB0) and plays ms_ice_cream. Drop:
#    origin inside donutBottom.frame (37,212,247,191) with the ball shown --
#    the first hidden of iceCream1..3 gets the tinted scoop art, the colour
#    is recorded, ms_ice_cream plays again.
#  * Third scoop -> finalizeScreen: instruction, scoop, bucket and flavour
#    button vanish and donutTop falls from y=-150 to y=161 (0x43210000 --
#    one point off the frosting nib's 160, original quirk) over 0.25s;
#    the completion pushes dicFrosting initWithColors:(the three colours)
#    with animated:NO. The port carries them in
#    GameState.custom_categories["iceCreamColors"].
#  * Releasing the scoop animates it home over 0.25s (sub_BC6C0).
#  * showScrollView brings the scroll view, then the iceCreamButton, to the
#    front (so the toggle stays on top of the panel), and the panel then
#    covers the scoop: a tap on a cell over the scoop picks the flavour. The
#    port's scoop reads input before the screen does, so it is switched off
#    while the panel is up (_sync_scoop_input) -- same outcome as the
#    original's view order.
#
# Dead code, not ported: nextClick: (0xBB10C) pushes Frosting with plain
# init (nil colours) -- but nothing on this screen ever shows the next
# button (resetScreen hides it; showNextButton 0xBAFBC has no free caller),
# so it is unreachable. draggableTouchBegan: is an empty stub.
#
# KEEP-STATE: kept alive under the push to dicFrosting.
# Scoop and picker are built once (viewDidLoad); resetScreen
# (viewWillAppear:) runs on entry and in on_resume. No on_exit: the class
# has no disappear methods.

extends "res://core/Screen.gd"

const UIKit := preload("res://screens/msUIKit.gd")

const DraggableSprite2D := preload("res://core/DraggableSprite2D.gd")
const caSelectChocolate := preload("res://screens/caSelectChocolate.gd")

## Panel geometry (showScrollView 0xBB588): scrollView nib (0,55,320,365);
## cells 80x80 (0x42A00000) at x 24+100*(i%3), y 95*row; icon (15,15,50,50)
## (0x41700000/0x42480000); contentSize (320, 100*rows).
const PANEL_RECT := Rect2(0, 55, 320, 365)
const CELL_X0 := 24.0
const CELL_X_PITCH := 100.0
const CELL_Y_PITCH := 95.0
const CELL_SIZE := 80.0
const ICON_RECT := Rect2(15, 15, 50, 50)
const CONTENT_ROW_H := 100.0
## Panel fade: 0.1s (0x3FB999999999999A), options 2.
const PANEL_FADE := 0.1

## The scoop DraggableIV nib frame and its ball overlay, a UIImageView
## subview at (0,0,80,60) (viewDidLoad 0xBAAB0: 0x42A00000 x 0x42700000).
const SCOOP_FRAME := Rect2(235, 60, 64, 231)
const BALL_RECT := Rect2(0, 0, 80, 60)
## Pickup region: iceCreamInBucket.frame AS READ -- bucket-local coords
## tested against a root-space point (0xBC3D0); see header.
const BUCKET_PICK_RECT := Rect2(13, 23, 189, 84)
## Drop region: donutBottom.frame (root space, no mismatch).
const DONUT_RECT := Rect2(37, 212, 247, 191)
## Scoop release snap: 0.25s (0xBC61C).
const SNAP_SECONDS := 0.25
## The fall (sub_BC24C): donutTop frame y -150 -> 161.0 (0x43210000), 0.25s.
const FALL_SECONDS := 0.25
const TOP_FALL_Y := 161.0

var _colors: Array[Color] = []
var _scoop: DraggableSprite2D
var _ball: Sprite2D
var _panel: Control
var _content: Node2D
var _content_h := 0.0
var _panel_shown := false
## contentOffset.y, fed by the scroll physics.
var _panel_scroll := 0.0
## The scrollView's UIScrollView touches and motion, and the press
## it is tracking.
var _physics: UIKit.ScrollPhysics
var _tracking := false
var _press := Vector2.ZERO
var _last_color: Variant = null
var _selected: Array = []
var _finalized := false


## changeInstruction: (0xBB354) ends with nextButton setHidden:YES.
func instruction_hides_next() -> bool:
	return true


## UINavigationController keeps this controller alive under the push to
## dicFrosting; Nav calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## init (0xBA644) + viewDidLoad (0xBAAB0) once, then viewWillAppear:
## (0xBAD0C -> resetScreen).
func on_enter() -> void:
	## The colour table at 0xBA644 is constructor-for-constructor identical
	## to caSelectChocolate's (0x1573xx); reuse rather than duplicate.
	_colors = caSelectChocolate.colors()
	_build_scoop()
	_build_panel()
	_reset_screen()


## Back from the frosting screen: resetScreen hides the three scoops on the
## donut, the bucket, the scoop and the picker, clears the chosen colours and
## re-shows the flavour button and inst_choose_icecream. donutTop is NOT
## reset: the top half stays where it fell (y 161) until the next third
## scoop drops it from -150 again -- as shipped. This class has no
## viewDidAppear: / viewWillDisappear: / viewDidDisappear:.
func on_resume() -> void:
	_reset_screen()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _build_scoop() -> void:
	var o := outlet("scoopDraggable")
	if o != null and o != self:
		(o as CanvasItem).visible = false
	_scoop = DraggableSprite2D.new()
	_scoop.texture = _tex("dis_scoop.png")   # 64x231, native
	_scoop.centered = false
	_scoop.position = SCOOP_FRAME.position
	add_child(_scoop)
	# Keep nib z-order: the scoop sits below the scrollView/instruction.
	var sv := outlet("scrollView")
	if sv is Node:
		move_child(_scoop, (sv as Node).get_index())
	_ball = Sprite2D.new()
	var ball_tex := _tex("dis_icecream_scoop.png")
	_ball.texture = ball_tex
	_ball.centered = false
	_ball.position = BALL_RECT.position
	if ball_tex != null:
		_ball.scale = BALL_RECT.size / Vector2(ball_tex.get_size())
	_ball.visible = false
	_scoop.add_child(_ball)
	_scoop.drag_moved.connect(_on_scoop_moved)
	_scoop.drag_ended.connect(_on_scoop_released)


## resetScreen (0xBAD4C).
func _reset_screen() -> void:
	_hide_panel_now()
	var bucket := outlet("iceCreamBucket")
	if bucket != null and bucket != self:
		(bucket as CanvasItem).visible = false
	_scoop.visible = false
	_scoop.enabled = false
	var next := first_outlet(NEXT_OUTLETS)
	if next != null:
		(next as CanvasItem).visible = false
	var btn := outlet("iceCreamButton")
	if btn != null and btn != self:
		(btn as CanvasItem).visible = true
	_ball.visible = false
	change_instruction("inst_choose_icecream.png")
	for i in 3:
		var s := outlet("iceCream%d" % (i + 1))
		if s != null and s != self:
			(s as CanvasItem).visible = false
	_last_color = null
	_selected = []
	_finalized = false


# -- the flavour picker -----------------------------------------------

func _build_panel() -> void:
	_panel = Control.new()
	_panel.clip_contents = true
	_panel.position = PANEL_RECT.position
	_panel.size = PANEL_RECT.size
	_panel.modulate.a = 0.0
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	_content = Node2D.new()
	_panel.add_child(_content)

	var bg := _tex("Sub_Button_Background.png")
	var art := _tex("dis_icecream_scoop.png")
	var row := 0
	for i in _colors.size():
		var cell := Node2D.new()
		cell.position = Vector2(CELL_X0 + CELL_X_PITCH * (i % 3),
			CELL_Y_PITCH * row)
		_content.add_child(cell)
		if bg != null:
			var b := Sprite2D.new()
			b.texture = bg
			b.centered = false
			b.scale = Vector2(CELL_SIZE, CELL_SIZE) / bg.get_size()
			cell.add_child(b)
		var icon_tex := caSelectChocolate.bake_alt_tint(art, _colors[i], 3)
		if icon_tex != null:
			var icon := Sprite2D.new()
			icon.texture = icon_tex
			icon.position = ICON_RECT.position + ICON_RECT.size * 0.5
			icon.scale = ICON_RECT.size / Vector2(icon_tex.get_size())
			cell.add_child(icon)
		if i % 3 == 2:
			row += 1
	_content_h = CONTENT_ROW_H * (row + (0 if _colors.size() % 3 == 0 else 1))
	# showScrollView (0xBB588): setContentSize:(320, 100 * rows); everything else
	# is the nib's default (bounces, Normal deceleration, both indicators on
	# -- only the vertical can show: 320 of 320 across). contentOffset is
	# never reset, so a re-opened picker shows where it was left.
	_physics = UIKit.ScrollPhysics.new(PANEL_RECT.size,
		Vector2(PANEL_RECT.size.x, _content_h))
	_physics.name = "UIScrollPhysics"
	add_child(_physics)
	_physics.scrolled.connect(func(o: Vector2) -> void:
		_panel_scroll = o.y
		_content.position.y = -o.y)
	_physics.attach_indicators(_panel, Rect2(Vector2.ZERO, PANEL_RECT.size))


## flavorClick: (0xBAF3C) -> showScrollView (0xBB588), a toggle.
func _on_flavorClick() -> void:
	Audio.play("button_press")
	if _panel_shown:
		_hide_panel()
		return
	# bringSubviewToFront: scrollView, then iceCreamButton (0xBB588).
	move_child(_panel, get_child_count() - 1)
	var btn := outlet("iceCreamButton")
	if btn != null and btn != self and btn.get_parent() == self:
		move_child(btn, get_child_count() - 1)
	change_instruction("inst_choose_icecream.png")
	_set_chrome_alpha(0.0)
	_panel.visible = true
	create_tween().tween_property(_panel, "modulate:a", 1.0, PANEL_FADE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_panel_shown = true
	_sync_scoop_input()


## hideScrollView (0xBBEC0).
func _hide_panel() -> void:
	if not _panel_shown:
		return
	_cancel_panel_touch()
	change_instruction("inst_choose_icecream.png" if not _scoop.visible
		else "inst_scoop.png")
	_set_chrome_alpha(1.0)
	create_tween().tween_property(_panel, "modulate:a", 0.0, PANEL_FADE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_panel_shown = false
	_sync_scoop_input()


func _hide_panel_now() -> void:
	_cancel_panel_touch()
	_panel.modulate.a = 0.0
	_panel.visible = false
	_panel_shown = false
	_set_chrome_alpha(1.0)
	_sync_scoop_input()


## The scoop takes touches only while it is shown and the panel is not over
## it (see header).
func _sync_scoop_input() -> void:
	if _scoop != null:
		_scoop.enabled = _scoop.visible and not _panel_shown and not _finalized


## showScrollView zeroes next/back alpha while the picker is up. Alpha-0
## UIViews also stop receiving touches; mirror with disabled.
func _set_chrome_alpha(a: float) -> void:
	for oname: Array in [NEXT_OUTLETS, BACK_OUTLETS]:
		var o := first_outlet(oname)
		if o != null and o is CanvasItem:
			var ci := o as CanvasItem
			ci.modulate.a = a
			if ci.has_method("set_disabled"):
				ci.set("disabled", a <= 0.0)


## selectFlavorButtonClick: (0xBC030).
func _select_flavor(i: int) -> void:
	Audio.play("button_press")
	if i < 0 or i >= _colors.size():
		return
	_last_color = _colors[i]
	_show_bucket(_colors[i])
	_hide_panel()
	change_instruction("inst_scoop.png")


## showIceCreamBucketWithIceCreamColor: (0xBAF98).
func _show_bucket(c: Color) -> void:
	var in_bucket := outlet("iceCreamInBucket") as Sprite2D
	if in_bucket != null:
		var tinted := caSelectChocolate.bake_alt_tint(
			_tex("dis_IceCream_For_Container.png"), c, 3)
		if tinted != null:
			in_bucket.texture = tinted
	_scoop.visible = true
	_sync_scoop_input()
	var bucket := outlet("iceCreamBucket")
	if bucket != null and bucket != self:
		(bucket as CanvasItem).visible = true


# -- scooping ---------------------------------------------------------

## draggableTouchMoved: (0xBC3D0). The tested point is the scoop's frame
## ORIGIN, and the bucket rect is the original's coordinate-space quirk.
func _on_scoop_moved(_center: Vector2) -> void:
	if _finalized:
		return
	var origin := _scoop.position
	if BUCKET_PICK_RECT.has_point(origin) and not _ball.visible:
		if _last_color is Color:
			_show_ball(_last_color)
		Audio.play("ms_ice_cream")
		return
	if DONUT_RECT.has_point(origin) and _ball.visible:
		_ball.visible = false          # hideIceCreamOnScoop (0xBBC64)
		if _last_color is Color:
			_drop_on_donut(_last_color)
		if _is_donut_full():
			_finalize()
		Audio.play("ms_ice_cream")


## showIceCreamOnScoopWithColor: (0xBBBD4).
func _show_ball(c: Color) -> void:
	var tinted := caSelectChocolate.bake_alt_tint(
		_tex("dis_icecream_scoop.png"), c, 3)
	if tinted != null:
		_ball.texture = tinted
		_ball.scale = BALL_RECT.size / Vector2(tinted.get_size())
	_ball.visible = true


## showIceCreamOnDonutWithColor: (0xBBC90): the first hidden slot fills.
func _drop_on_donut(c: Color) -> void:
	for i in 3:
		var s := outlet("iceCream%d" % (i + 1)) as Sprite2D
		if s == null or s.visible:
			continue
		var tinted := caSelectChocolate.bake_alt_tint(
			_tex("dis_icecream_scoop.png"), c, 3)
		if tinted != null:
			s.texture = tinted
		s.visible = true
		_selected.append(c)
		return


func _is_donut_full() -> bool:   # isDonutFullOfIceCream (0xBBDE4)
	for i in 3:
		var s := outlet("iceCream%d" % (i + 1))
		if s != null and s != self and not (s as CanvasItem).visible:
			return false
	return true


## finalizeScreen (0xBC118) + donutFallsFromTheSkyWhoa (0xBC1A8):
## chrome vanishes, the top half drops in, the completion pushes Frosting
## initWithColors: (sub_BC338, animated:NO).
func _finalize() -> void:
	_finalized = true
	dismiss_instruction()
	_scoop.visible = false
	_scoop.enabled = false
	var bucket := outlet("iceCreamBucket")
	if bucket != null and bucket != self:
		(bucket as CanvasItem).visible = false
	var btn := outlet("iceCreamButton")
	if btn != null and btn != self:
		(btn as CanvasItem).visible = false
	var top := outlet("donutTop") as Sprite2D
	var tw := create_tween()
	if top != null:
		tw.tween_property(top, "position:y", TOP_FALL_Y, FALL_SECONDS) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	else:
		tw.tween_interval(FALL_SECONDS)
	tw.tween_callback(func() -> void:
		var info: Dictionary = GameState.custom_categories.duplicate(true)
		info["iceCreamColors"] = _selected.duplicate()
		GameState.custom_categories = info
		Nav.push("dicFrostingViewController", "dic"))


## draggableTouchEnded: (0xBC61C): 0.25s home (sub_BC6C0).
## +animateWithDuration:delay:options:animations:completion: with options 2
## = UIViewAnimationOptionAllowUserInteraction (0xBC676): the scoop stays
## touchable on its way home, hit-tested at its MODEL frame (home), and the
## drag owns it once caught -- animate_position(). The port used to leave a
## plain tween pulling a caught scoop home while the scoop/drop tests (which
## read the drag's position) ran where the finger was.
func _on_scoop_released(_pos: Vector2, _hit: bool) -> void:
	_scoop.animate_position(create_tween(), SCOOP_FRAME.position,
		SNAP_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# -- panel scrolling / tapping (same idiom as caSelectChocolate) -------

## A press inside the scroll view's frame is the UIScrollView's
## (UIKit.ScrollPhysics: a drag after 10 pt with UIKit's momentum and
## bounce); released before that it is a tap on the cell under the press.
## Moves and the release are read in _input so a drag keeps tracking
## wherever the finger goes.
func _unhandled_input(event: InputEvent) -> void:
	if not _panel_shown or not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if not PANEL_RECT.has_point(mb.position):
		return
	_tracking = true
	_press = mb.position
	_physics.touch_began(mb.position)
	get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not _tracking:
		return
	if event is InputEventMouseMotion:
		_physics.touch_moved((event as InputEventMouseMotion).position)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT or mb.pressed:
			return
		_tracking = false
		if _physics.touch_ended(mb.position) and _panel_shown:
			_panel_tap(_press)
		get_viewport().set_input_as_handled()


func _cancel_panel_touch() -> void:
	if _tracking and _physics != null:
		_physics.touch_cancelled()
	_tracking = false


func _panel_tap(pos: Vector2) -> void:
	var local := pos - _panel.position + Vector2(0, _panel_scroll)
	for i in _colors.size():
		var rect := Rect2(Vector2(CELL_X0 + CELL_X_PITCH * (i % 3),
			CELL_Y_PITCH * int(float(i) / 3.0)), Vector2(CELL_SIZE, CELL_SIZE))
		if rect.has_point(local):
			_select_flavor(i)
			return


## backClick: (0xBB09C): button_press, pop. (Without this override the
## base Screen back was silent.)
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()
