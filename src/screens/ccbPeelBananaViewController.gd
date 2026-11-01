# Chocolate Covered Banana step 1 -- swipe down the banana to peel it,
# strip by strip.
#
# From the original binary (entry points from the ObjC method list):
#   initWithNibName: 0x96890 (bare super), viewDidLoad 0x968C0 (analytics
#   only), viewWillAppear: 0x96AF0, enableTouches 0x96F8C (window-level,
#   nothing here disables it -- not ported), nextClick: 0x97044,
#   changeInstruction: 0x970F8 (never called -- the nib art stands),
#   showNextButton 0x97300, peelbanana 0x97464, resetPeelGestureData 0x97764,
#   touchesBegan/Moved/Ended/Cancelled 0x97798/0x9789C/0x979B8/0x979C8,
#   viewDidDisappear: 0x97A04 (tears the four layers down -- on_exit),
#   skipClick: 0x970F4 (a bare-return stub, dead), backClick: 0x96FD4.
#   A full re-read found only backClick:'s button_press missing.
#
# Mechanic, as read: the nib banana (UIImageView (87,69,147,313),
# BS_Layer0.png -- the naked banana) sits under four code-built
# SpriteSheetViews (viewWillAppear:), each a 6-column 1-row strip whose cell
# size IS its frame:
#   layer1 (106, 73,122,332) BS_Layer1.png (732x332)  above the banana
#   layer2 ( 23, 72,203,325) BS_Layer2.png (1218x325) below layer1
#   layer3 (148, 63,196,306) BS_Layer3.png (1176x306) below layer2
#   layer4 (159,103, 66,258) BS_Layer4.png (396x258)  below layer3
# (floats 0x42D40000/0x42920000/0x42F40000/0x43A60000 etc., all decoded.)
#
# touchesBegan on the banana view: touchedBanana, startTouchY = int(y),
# play "fruit_pull". touchesMoved: while inside the banana frame, moving
# BELOW the start (startTouchY < y) and crossing a new integer row
# (int(y) > previousTouchY) calls peelbanana once and records the row.
#
# peelbanana (0x97464): totalPeelDistance += 18 -- a FIXED 18 per qualifying
# move event, not the actual delta. While distance/bananaHeight >=
# currentSpriteIndex/5.0, tick the active sheet (peel 0 ticks layer1 AND
# layer4; peel 1 layer2; peel 2 layer3) and step the index 0..5 then wrap.
# SpriteSheetView tick (0x47910) shows the CURRENT cell then increments, so
# the six ticks of one peel land on cells 0..5. distance >= height (313,
# int-truncated) finishes a peel: numberOfPeelsPerformed++, gesture reset,
# distance 0. At 3 peels: banana interaction off, showNextButton, and a 2.0s
# "Banana_peel" animation slides all four layers' centres to y=2000
# (0x44FA0000).
#
# touchesEnded/Cancelled: resetPeelGestureData (touched 0, startTouchY -1,
# previousTouchY -1).
#
# KEEP STATE: the controller survives under
# ccbSelectStickViewController. viewDidDisappear: (0x97A04) removes the four
# layers and nils them; on return viewWillAppear: (0x96AF0) hides next,
# builds four FRESH layers, re-enables the banana, resets the gesture and
# zeroes numberOfPeelsPerformed / totalPeelDistance / currentSpriteIndex --
# the banana is unpeeled again and must be peeled before next returns. The
# banner showNextButton hid stays hidden (nothing here unhides instIV).
#
# PORT NOTE: the generated scene gives the banana node scale
# (0.37667, 0.3725) -- the grater's scale from ccbSelectChocolate, a
# scene generator mix-up. BS_Layer0.png is 147x313, exactly the nib
# frame, so the real scale is 1; corrected here at runtime.

extends "res://core/Screen.gd"

## viewWillAppear: (0x96AF0) SpriteSheetView frames; 6 columns, 1 row each.
const LAYER_FRAMES: Array[Rect2] = [
	Rect2(106, 73, 122, 332),   # BS_Layer1
	Rect2(23, 72, 203, 325),    # BS_Layer2
	Rect2(148, 63, 196, 306),   # BS_Layer3
	Rect2(159, 103, 66, 258),   # BS_Layer4
]
const LAYER_COLUMNS := 6
## Banana hit view: nib UIImageView frame (87,69,147,313).
const BANANA_RECT := Rect2(87, 69, 147, 313)
## peelbanana: += 18 per qualifying move event (0x97468).
const PEEL_STEP := 18
## Sheet tick gate: distance/height >= index/5.0 (0x97464).
const TICK_DENOM := 5.0
## Three full peels finish the screen.
const PEELS_NEEDED := 3
## "Banana_peel": layers' centres to y=2000 (0x44FA0000) over 2.0s.
const SLIDE_Y := 2000.0
const SLIDE_SECONDS := 2.0

var _layers: Array[Sprite2D] = []
var _layer_idx: Array[int] = [0, 0, 0, 0]   # each sheet's currentFrameIdx
var _banana: Sprite2D
var _touched := false
var _start_y := -1
var _prev_y := -1
var _distance := 0                          # totalPeelDistance
var _sprite_idx := 0                        # currentSpriteIndex
var _peels := 0                             # numberOfPeelsPerformed
var _done := false


func on_enter() -> void:
	_banana = outlet("banana") as Sprite2D
	if _banana != null:
		# Scene-generator mix-up: see PORT NOTE in the header.
		_banana.scale = Vector2.ONE
	_view_will_appear()


## viewWillAppear: (0x96AF0) -- the first appearance and every return.
func _view_will_appear() -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	_build_layers()
	_done = false                             # banana interaction back on
	_reset_gesture()
	_peels = 0
	_distance = 0
	_sprite_idx = 0


## UINavigationController keeps this controller alive under
## ccbSelectStickViewController (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from ccbSelectStickViewController: viewWillAppear: again (header).
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		# CoinHUD re-adds the panel after this; drop the first appearance's.
		remove_child(old)
		old.queue_free()
	_view_will_appear()


## viewDidDisappear: (0x97A04): the four layers removeFromSuperview and set
## to nil (their slide-off tweens die with them).
func on_exit() -> void:
	for l in _layers:
		if is_instance_valid(l):
			l.queue_free()
	_layers.clear()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## viewWillAppear: (0x96AF0). Z order bottom->top: banana, layer4, layer3,
## layer2, layer1 (layer1 above the banana, each next below the previous).
func _build_layers() -> void:
	_layers.clear()
	_layer_idx = [0, 0, 0, 0]
	var base_index := 0 if _banana == null else _banana.get_index() + 1
	# Build 1..4 then order 4,3,2,1 above the banana.
	for i in LAYER_FRAMES.size():
		var s := Sprite2D.new()
		s.texture = _tex("BS_Layer%d.png" % (i + 1))
		s.centered = false
		s.position = LAYER_FRAMES[i].position
		s.region_enabled = true
		s.region_rect = Rect2(Vector2.ZERO, LAYER_FRAMES[i].size)
		add_child(s)
		_layers.append(s)
	# insertSubview ordering: 1 above banana, 2 below 1, 3 below 2, 4 below 3
	# -> bottom to top: banana, 4, 3, 2, 1. Each move_child to base_index
	# lands UNDER the layers already moved there, so move 1 first. (An
	# earlier loop ran 4,3,2,1, which stacked layer 4 on top.)
	for i in [0, 1, 2, 3]:
		move_child(_layers[i], base_index)


## SpriteSheetView tick (0x47910): show the CURRENT cell, then advance and
## wrap at rows*columns.
func _tick_layer(i: int) -> void:
	var s := _layers[i]
	var cell := LAYER_FRAMES[i].size
	var idx := _layer_idx[i]
	s.region_rect = Rect2(Vector2(cell.x * (idx % LAYER_COLUMNS), 0), cell)
	_layer_idx[i] = (idx + 1) % LAYER_COLUMNS


## resetPeelGestureData (0x97764).
func _reset_gesture() -> void:
	_touched = false
	_start_y = -1
	_prev_y = -1


func _unhandled_input(event: InputEvent) -> void:
	if _done:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			# touchesBegan (0x97798): only when the touch lands on the
			# banana view.
			if BANANA_RECT.has_point(mb.position):
				_touched = true
				_start_y = int(mb.position.y)
				Audio.play("fruit_pull")
				get_viewport().set_input_as_handled()
		else:
			_reset_gesture()      # touchesEnded (0x979B8)
	elif event is InputEventMouseMotion and _touched:
		get_viewport().set_input_as_handled()
		# iOS delivered touchesMoved: at most once per frame; see
		# Screen.accept_touch_move. Without this the peel completed in a
		# few pixels of mouse travel on a high-refresh monitor.
		if not accept_touch_move():
			return
		var p := (event as InputEventMouseMotion).position
		# touchesMoved (0x9789C): inside the frame, below the start, and
		# crossing a new integer row.
		if BANANA_RECT.has_point(p) and float(_start_y) < p.y \
				and int(p.y) > _prev_y:
			_peel_banana()
			_prev_y = int(p.y)


## peelbanana (0x97464).
func _peel_banana() -> void:
	_distance += PEEL_STEP
	var h := int(BANANA_RECT.size.y)     # vcvt_s32_f32 of the frame height
	if float(_distance) / float(h) >= float(_sprite_idx) / TICK_DENOM:
		match _peels:
			0:
				_tick_layer(0)           # banana_layer1
				_tick_layer(3)           # banana_layer4 -- both, as shipped
			1:
				_tick_layer(1)
			2:
				_tick_layer(2)
		_sprite_idx = _sprite_idx + 1 if _sprite_idx <= 4 else 0
	if _distance >= h:
		_peels += 1
		_reset_gesture()
		_distance = 0
	if _peels >= PEELS_NEEDED:
		_done = true                     # setUserInteractionEnabled:0
		show_next_button()
		# "Banana_peel": every layer's CENTRE to y 2000 over 2.0s (curve 0,
		# ease-in-out). The sprites are top-left anchored; convert.
		for i in _layers.size():
			var target := SLIDE_Y - LAYER_FRAMES[i].size.y * 0.5
			create_tween().tween_property(_layers[i], "position:y", target,
				SLIDE_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## nextClick: (0x97044): button_press, push ccbSelectStickViewController.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.next()


## backClick: (0x96FD4): button_press, pop. (Screen's default pops silently.)
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
