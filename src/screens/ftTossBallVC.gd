# Midway game: Fish Bowl toss (ftTossBallVC, "Fish Bowl" booth).
#
# From the original binary, with every float argument read from the
# instructions:
#   initWithNibName:bundle: 0x11AA28   viewDidLoad 0x11AE00
#   viewWillAppear: 0x11B1C8   viewDidAppear: 0x11B2F8   initBowls 0x11E13C
#   touchesBegan: 0x11C180   touchesEnded: 0x11C368 (the whole throw)
#   animationDidStart: 0x11F1E4   animationDidStop:finished: 0x11F3D4
#   resetBall 0x11E678   showBall 0x11E7A0   resetBowls 0x11ED5C
#   buyBalls 0x11EAC0   endThrow 0x11F0F0   closePrizeDialog: 0x11FD78
#   alertView:didDismissWithButtonIndex: 0x11FEF8   setBallCount: 0x120128
#   delayStartupEmitterBalloons 0x11BA10   backClick: 0x11BD18
#   coinsClick: 0x11BEC8   playClick: 0x11BFA8   prizeClick: 0x11C068
# Helper class BowlView: midway/ft_BowlView.gd.
#
# The game: five receding rows of five tinted fish bowls. Press on the ball,
# flick upward, release. Release speed (distance from the ball's centre to the
# release point over the time since touch-down) picks the row; the line from
# the ball through the release point picks the x. The ball flies there on a
# quadratic arc, shrinking, and is tested against the three hit boxes of the
# row's visible bowls: a rim may bounce it in, out, or into a neighbour; the
# centre drops it in. A ball in a bowl wins a random "fishtoss" prize. Every
# throw costs one ball; 8 balls (NUM_OF_BALLS) cost 5 coins.
#
# NOT PORTED (no visible effect, or outside the port's scope):
#  * DataLogging calls (analytics) and both ad calls: backClick:'s
#    displayAdForLocation:"Interstitial" (only without FF_KEY_EVERYTHING) and
#    showBuyMoreCoinsMessage's displayMediaBrixForLocation:withMiniGame: --
#    the port has no ad SDK, so "more balls" with < 5 coins does nothing.
#  * ballTimer: viewDidAppear: schedules a 0.1 s repeating ballTick
#    (interval double 0x3FB99999A0000000), whose body is empty (0x11F0EC);
#    invalidated in viewWillDisappear:. Nothing to see or hear, so no timer
#    runs; the rest of viewDidAppear: (the ball slide) is on_did_appear.
#  * instIV: the class slides it in on viewDidAppear:, but the nib has no
#    instIV outlet, so it is nil on the device too.
#  * ipad2x: set in viewWillAppear:, never read.

extends "res://core/Screen.gd"
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const BowlView := preload("res://midway/ft_BowlView.gd")

# -- persistent state (NSUserDefaults keys, verbatim) ------------------------

const KEY_BALL_COUNT := "FishTossBallCount"
const KEY_UNIQUE := "uniqueBall"
const KEY_DATE_ARC_FLAG := "dateArcFlag"
const KEY_START_ARC_DATE := "startArcDate"
const KEY_END_ARC_DATE := "endArcDate"
const KEY_PLAYED_ARC_FLAG := "playedArcFlag"

## initWithNibName: NUM_OF_BALLS = IAPlist GameData/FishbowlPurchase intValue,
## 8 when that is 0/absent. No IAPlist ships (the server table is dead), so 8.
const NUM_OF_BALLS := 8
## buyBalls: needs totalCoins > 4, then spendCoins:5.
const BALL_PRICE := 5

# -- layout (nib ftTossBallVC) -----------------------------------------------

## ballIV / ball2IV frame (135,425,50,50): originalBallCenter (160,450).
const BALL_SIZE := Vector2(50, 50)
## Heights of row1..row5 (front rows; frame origins come from the nodes).
## row1 (1,226,320,60) row2 (0,196,320,51) row3 (0,176,320,42)
## row4 (0,158,320,33) row5 (0,144,320,24). The back rows match except
## row3Back, which sits at y 175 -- one pixel above row3.
const ROW_HEIGHTS := [60.0, 51.0, 42.0, 33.0, 24.0]

# -- initBowls 0x11E13C ------------------------------------------------------

## Per row: bowl scale (0x682B34) and first bowl centre x (0x682B48); each
## next bowl sits one scaled bowl width to the right.
const BOWL_SCALES := [1.0, 0.85, 0.7, 0.55, 0.4]
const BOWL_START_X := [40.0, 58.0, 75.0, 94.0, 112.0]
## Bowl tags, row-major (0x682B5C) -- resetBowls' visibility class.
const BOWL_TAGS := [
	1, 1, 1, 1, 1,
	1, 2, 2, 2, 1,
	1, 2, 3, 2, 1,
	1, 2, 2, 2, 1,
	1, 1, 1, 1, 1,
]
## [UIColor blueColor], redColor, greenColor; one picked per bowl.
const BOWL_COLORS := [Color(0, 0, 1), Color(1, 0, 0), Color(0, 1, 0)]
const WATER_ART := "ft_bowl_water.png"
const FRONT_ART := "ft_bowl_1.png"
const BACK_ART := "ft_bowl_2.png"

## resetBowls: tag 3 always shown, tag 2 when rand%100 <= 84, tag 1 <= 69.
const SHOW_TAG2_MAX := 84
const SHOW_TAG1_MAX := 69

# -- touchesEnded: 0x11C368 ---------------------------------------------------

## Release-speed bands (pt/s). Index 0 below 300, then 1,3,5,7,9; a speed
## exactly on an edge falls through to 0, as the original's strict compares do.
const SPEED_EDGES := [300.0, 900.0, 1500.0, 2100.0, 2700.0]
## v301: target y per index. Even entries (row centres) are unreachable --
## the speed bands only ever pick 0,1,3,5,7,9 -- but are kept for fidelity.
const TARGET_Y_FIXED := {0: 280.0, 1: 233.0, 3: 205.0, 5: 185.0, 7: 165.0, 9: 150.0}
## v300: ball scale per index.
const TARGET_SCALE := [0.49, 0.46, 0.43, 0.4, 0.37, 0.34, 0.31, 0.28, 0.25, 0.22, 0.18]
## MoveBall's control point rises 200 above the target; bounces rise 150.
const MOVE_RISE := 200.0
const BOUNCE_RISE := 150.0
## Durations (doubles, read from the literal pools).
const MOVE_SECONDS := 0.8        # MoveBall default
const PASS_SECONDS := 0.9        # MoveBall to the row's bottom edge
const RIM_LAND_SECONDS := 1.2    # BounceEndLand into the rim's own bowl
const BOUNCE_SECONDS := 0.8      # BounceMid / BounceEndLand / BounceEndMiss
const DROP_IN_SECONDS := 0.1     # MoveEndLand
## BounceEndMiss off a rim: control +-10, end +-20 (left rim negative).
const RIM_MISS_CX := 10.0
const RIM_MISS_DX := 20.0
## Rim percentage rolls: <= 49 of 100.
const HALF_ROLL := 49

const TAG_LEFT_RIM := BowlView.TAG_LEFT_RIM
const TAG_RIGHT_RIM := BowlView.TAG_RIGHT_RIM
const TAG_CENTER := BowlView.TAG_CENTER

# -- showBall / slideView:toPoint:overDuration: ------------------------------

const BALL_SLIDE_OFFSET := 500.0
const SLIDE_SECONDS := 0.25      # curve 3 = linear

# -- prize dialog (animationDidStop:finished: 0x11F3D4) ----------------------

const PRIZE_DIALOG_TAG := 1000000
const PRIZE_GAME := "fishtoss"
const POPUP_ART := "prize_popup.png"
const PRIZE_CENTER := Vector2(160, 240)
const CLOSE_ART := "daily_login_btn.png"
const CLOSE_SIZE := Vector2(94, 63)
const CLOSE_CENTER := Vector2(160, 400)
const LABEL_ART := "prize_label.png"
const LABEL_ART_CENTER := Vector2(160, 355)
## UILabel (0,0,74,14) at (labelArt.width * 0.5, 16); system font 12, shrink
## to fit down to 6, centred, clear background.
const NAME_LABEL_SIZE := Vector2(74, 14)
const NAME_LABEL_Y := 16.0
const NAME_FONT_SIZE := 12
const NAME_MIN_FONT_SIZE := 6
## The whole dialog scales 0.01 -> 1 over 0.5 s, curve 3 (linear).
const DIALOG_START_SCALE := 0.01
const DIALOG_SECONDS := 0.5

# -- prizeClick: 0x11C068 ------------------------------------------------------

const PRIZE_BACKGROUND := "bg_minigame_aqua.png"

# -- fallingCookies (init 0x11AA28 / delayStartupEmitterBalloons 0x11BA10) ----

## 13 UIImageViews 80x80, contentMode 1 (aspect fit), parked at (-999,-999).
const COOKIE_ARTS := [
	"circus_ballbubble.png", "circus_clownbubble.png",
	"circus_greenbubble.png", "circus_pinkbubble.png",
	"circus_yellowbubble.png", "circus_yellowbubble.png",
	"circus_pinkbubble.png", "circus_greenbubble.png",
	"Star_Emitters_End_Game_PS_1.png", "Star_Emitters_End_Game_PS_2.png",
	"Star_Emitters_End_Game_PS_3.png", "Star_Emitters_End_Game_PS_4.png",
	"Star_Emitters_End_Game_PS_5.png",
]
const COOKIE_BOX := 80.0
const COOKIE_PARK := Vector2(-999, -999)
## Start (rand%200 + 60, rand%50 + 520); end (3x - 320, y - 650);
## duration 1.5 + (rand%100)/100, curve 1 (ease-in).
const COOKIE_X0 := 60
const COOKIE_X_SPAN := 200
const COOKIE_Y0 := 520
const COOKIE_Y_SPAN := 50
const COOKIE_RISE := 650.0
const COOKIE_SECONDS := 1.5

const OUT_OF_BALLS := "You are out of balls. Would you like to buy more?"

## Dev aid: outline every bowl's hit boxes.
var debug_hitboxes := false:
	set(v):
		debug_hitboxes = v
		for b in all_bowls():
			b.debug_hitboxes = v

# -- outlets ---------------------------------------------------------------

var _view: Node2D
var _ball: Sprite2D
var _ball2: Sprite2D
var _rows: Array[Node2D] = []
var _row_backs: Array[Node2D] = []
var _coin_label: Label
var _ball_count_label: Label

# -- ivars -----------------------------------------------------------------

var ball_count := 0
var is_ball_in_air := false
var is_ball_in_bowl := false
var original_ball_center := Vector2.ZERO
## tossDate, as Time.get_ticks_usec(); -1 = nil.
var _toss_usec := -1
## UIKit *model* values of ballIV/ball2IV (always equal): what -center and
## -frame answer while a CAAnimation shows something else on screen.
var _ball_model_center := Vector2.ZERO
var _ball_model_scale := 1.0

## ballAnimations: [{ "key", "segments", "duration" }] -- the first is on the
## ball, the rest wait for animationDidStop:finished:.
var ball_animations: Array[Dictionary] = []
var _running: Dictionary = {}
var _running_t := 0.0
## MoveBall is added to ball2IV's layer as well (without a delegate).
var _running_drives_ball2 := false
## view.userInteractionEnabled -- off from each animationDidStart: until its
## animationDidStop:finished:.
var interaction_enabled := true

var _scale_tween: Tween
var _slide_tweens: Array[Tween] = []
var _prize_dialog: Control = null
var _alert_layer: CanvasLayer = null
var _cookies: Array[Sprite2D] = []
var _cookie_tweens: Array[Tween] = []

var _water_tex: Texture2D
var _front_tex: Texture2D
var _back_tex: Texture2D


func on_enter() -> void:
	_view = outlet("view") as Node2D
	_ball = outlet("ballIV") as Sprite2D
	_ball2 = outlet("ball2IV") as Sprite2D
	for i in range(1, 6):
		_rows.append(outlet("row%d" % i) as Node2D)
		_row_backs.append(outlet("row%dBack" % i) as Node2D)
	_coin_label = outlet("coinLabel") as Label
	_ball_count_label = outlet("ballCountLabel") as Label
	_water_tex = Assets.texture(WATER_ART)
	_front_tex = Assets.texture(FRONT_ART)
	_back_tex = Assets.texture(BACK_ART)

	# The nib places the balls by their top-left; a UIView transform scales
	# about the centre, so centre the sprites on their UIKit centre.
	for b: Sprite2D in [_ball, _ball2]:
		var c := b.position + BALL_SIZE * 0.5
		b.centered = true
		b.position = c

	# initWithNibName:bundle: -- observe COIN_NOTIFICATION_VALUE_CHANGED
	# (CoinManager.coin_value_changed in the port); ballCount from defaults.
	if CoinManager.has_signal("coin_value_changed"):
		CoinManager.connect("coin_value_changed", _coin_value_changed)
	# Its first [self view] loads the nib, which runs viewDidLoad before the
	# cookies are created, so they end up above everything the nib holds.
	ball_count = Defaults.integer_for_key(KEY_BALL_COUNT)
	_view_did_load()
	_make_cookies()
	_view_will_appear()
	# viewDidAppear: -> on_did_appear, after the push slide.


# -- lifecycle ---------------------------------------------------------------

## viewDidLoad 0x11AE00.
func _view_did_load() -> void:
	_init_bowls()
	original_ball_center = _ball.position
	# Both balls parked 500 to the right, unhidden; viewDidAppear: slides them
	# in only if there are balls left.
	_ball_model_center = original_ball_center + Vector2(BALL_SLIDE_OFFSET, 0)
	_set_ball_center(_ball_model_center)
	_ball.visible = true
	_ball2.visible = true
	set_ball_count(ball_count)
	_update_coin_label(CoinManager.total_coins())
	if not Defaults.bool_for_key(KEY_UNIQUE):
		Defaults.set_bool_for_key(true, KEY_UNIQUE)
		Defaults.synchronize()
	if Defaults.integer_for_key(KEY_DATE_ARC_FLAG) == 0:
		Defaults.set_object_for_key(_now_date(), KEY_START_ARC_DATE)
		Defaults.set_integer_for_key(1, KEY_DATE_ARC_FLAG)
		Defaults.synchronize()


## viewWillAppear: 0x11B1C8.
func _view_will_appear() -> void:
	reset_bowls()
	_update_coin_label(CoinManager.total_coins())


## viewDidAppear: 0x11B2F8 (instIV is nil -- no outlet in the nib).
func _view_did_appear() -> void:
	if ball_count >= 1:
		reset_ball()
		show_ball()


## coinsClick: (0x11BEC8), prizeClick: (0x11C068) and the Get Coins alert
## push over this controller, which UINavigationController keeps alive: the
## bowls initBowls coloured (viewDidLoad -- once), the ball count and an open
## prize dialog are all as they were on return. Nav keeps this instance.
func keeps_state_on_push() -> bool:
	return true


## Back on top: viewWillAppear: (0x11B1C8) re-rolls which bowls show
## (resetBowls -- visibility only; the colours stay) and refreshes the coin
## label; viewDidAppear: (0x11B2F8) re-slides the ball in when there are
## balls. A throw cannot be in flight here: every button is dead while one is
## (view.userInteractionEnabled NO from animationDidStart:).
func on_resume() -> void:
	_view_will_appear()


## viewDidAppear: timing: Nav calls this when the push /
## pop slide ends (at once when unanimated), so the ball slides in after the
## screen has, as on the phone -- it used to start with the slide.
func on_did_appear() -> void:
	_view_did_appear()


## viewWillDisappear: (0x11B4D0) only invalidates ballTimer, which the port
## does not run (its ballTick body is empty -- see the header). The coin
## observer is dealloc's (0x11B80C), so it stays connected while a pushed
## screen covers this one: see _notification.
func on_exit() -> void:
	pass


## dealloc: removeObserver for COIN_NOTIFICATION_VALUE_CHANGED -- when the
## controller is really released (popped or replaced), not when covered.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if CoinManager.has_signal("coin_value_changed") \
				and CoinManager.is_connected("coin_value_changed", _coin_value_changed):
			CoinManager.disconnect("coin_value_changed", _coin_value_changed)


## coinValueChanged: 0x12029C -- the label shows userInfo totalCoins.
func _coin_value_changed(total: int) -> void:
	_update_coin_label(total)


func _process(delta: float) -> void:
	if not _running.is_empty():
		_running_t += delta
		_apply_running(minf(_running_t, float(_running["duration"])))
		if _running_t >= float(_running["duration"]):
			var done := _running
			_running = {}
			_animation_did_stop(done)


# -- initBowls 0x11E13C ------------------------------------------------------

func _init_bowls() -> void:
	for i in 5:
		var row := _rows[i]
		var back := _row_backs[i]
		for c in row.get_children():
			c.queue_free()
		for c in back.get_children():
			c.queue_free()
		var s: float = BOWL_SCALES[i]
		var x: float = BOWL_START_X[i]
		for j in 5:
			var color: Color = BOWL_COLORS[randi() % BOWL_COLORS.size()]
			var bowl := BowlView.new()
			bowl.init_with_water_image(_water_tex, color, BowlView.BLEND_HARD_LIGHT,
				_front_tex)
			var back_iv := Sprite2D.new()
			back_iv.texture = _back_tex
			bowl.set_back_view(back_iv)
			bowl.tag = BOWL_TAGS[i * 5 + j]
			var size := bowl.frame.size * s
			bowl.set_frame(Rect2(Vector2.ZERO, size))
			bowl.set_back_frame(Rect2(Vector2.ZERO, size))
			bowl.adjust_hitboxes(s)
			bowl.debug_hitboxes = debug_hitboxes
			row.add_child(bowl)
			back.add_child(back_iv)
			bowl.set_center(Vector2(x, float(ROW_HEIGHTS[i]) * 0.5))
			x += bowl.frame.size.x


## resetBowls 0x11ED5C.
func reset_bowls() -> void:
	for row in _rows:
		for b in _bowls_of(row):
			b.set_hidden(true)
	for row in _rows:
		for b in _bowls_of(row):
			var roll := randi() % 100
			match b.tag:
				3:
					b.set_hidden(false)
				2:
					if roll <= SHOW_TAG2_MAX:
						b.set_hidden(false)
				1:
					if roll <= SHOW_TAG1_MAX:
						b.set_hidden(false)


func _bowls_of(row: Node2D) -> Array:
	var out := []
	for c in row.get_children():
		if c.get_script() == BowlView and not c.is_queued_for_deletion():
			out.append(c)
	return out


func all_bowls() -> Array:
	var out := []
	for row in _rows:
		out.append_array(_bowls_of(row))
	return out


# -- the ball ------------------------------------------------------------------

## resetBall 0x11E678.
func reset_ball() -> void:
	_stop_ball_animations()
	_ball_model_center = original_ball_center
	_ball_model_scale = 1.0
	_set_ball_center(original_ball_center)
	_ball.scale = Vector2.ONE
	_ball2.scale = Vector2.ONE
	is_ball_in_air = false
	is_ball_in_bowl = false


## showBall 0x11E7A0: jump 500 right, unhide, slide back over 0.25 s linear.
func show_ball() -> void:
	for t in _slide_tweens:
		if t != null and t.is_valid():
			t.kill()
	_slide_tweens.clear()
	for b: Sprite2D in [_ball, _ball2]:
		b.position = _ball_model_center + Vector2(BALL_SLIDE_OFFSET, 0)
		b.visible = true
		var t := create_tween()
		t.tween_property(b, "position", _ball_model_center, SLIDE_SECONDS) \
			.set_trans(Tween.TRANS_LINEAR)
		_slide_tweens.append(t)
	_touch_end_arc_date()


func _set_ball_center(c: Vector2) -> void:
	_ball.position = c
	_ball2.position = c


## ballIV.frame, from the model values (CGRectContainsPoint hit test).
func ball_model_frame() -> Rect2:
	var size := BALL_SIZE * _ball_model_scale
	return Rect2(_ball_model_center - size * 0.5, size)


## setBallCount: 0x120128 -- persisted and shown at once.
func set_ball_count(n: int) -> void:
	ball_count = n
	Defaults.set_integer_for_key(ball_count, KEY_BALL_COUNT)
	Defaults.synchronize()
	if _ball_count_label != null:
		_ball_count_label.text = "%d" % ball_count


func _update_coin_label(coins: int) -> void:
	if _coin_label != null:
		_coin_label.text = "%d" % coins


# -- touches -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not interaction_enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			touches_began(mb.position)


## The release is taken before the GUI so a flick that ends over a button
## still reaches touchesEnded:, as on iOS (the touch stays with the view that
## began it).
func _input(event: InputEvent) -> void:
	if _toss_usec < 0:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			touches_ended(mb.position)


## touchesBegan:withEvent: 0x11C180. (applicationFrame is the full 320x480 --
## UIStatusBarHidden -- so the original's screen-scale factors are 1.)
func touches_began(p: Vector2) -> void:
	if ball_model_frame().has_point(p) and _prize_dialog == null:
		_toss_usec = Time.get_ticks_usec()


## touchesEnded:withEvent: 0x11C368.
func touches_ended(p: Vector2) -> void:
	if _toss_usec >= 0:
		var ball := _ball_model_center
		if p.y < ball.y and ball_count >= 1 and _prize_dialog == null:
			var elapsed := float(Time.get_ticks_usec() - _toss_usec) / 1000000.0
			toss(p, elapsed)
	_toss_usec = -1


## Index into the target tables for a release speed (the nested compares).
static func speed_index(speed: float) -> int:
	if speed < SPEED_EDGES[0]:
		return 0
	if speed > SPEED_EDGES[0] and speed < SPEED_EDGES[1]:
		return 1
	if speed > SPEED_EDGES[1] and speed < SPEED_EDGES[2]:
		return 3
	if speed > SPEED_EDGES[2] and speed < SPEED_EDGES[3]:
		return 5
	if speed > SPEED_EDGES[3] and speed < SPEED_EDGES[4]:
		return 7
	if speed > SPEED_EDGES[4]:
		return 9
	return 0


## v301[index]: odd entries fixed, even entries the row centres.
func target_y(index: int) -> float:
	if TARGET_Y_FIXED.has(index):
		return TARGET_Y_FIXED[index]
	var row := _rows[index / 2 - 1]
	return row.position.y + float(ROW_HEIGHTS[index / 2 - 1]) * 0.5


## The throw proper: everything touchesEnded: does once it has decided to
## toss. `touch` is the release point, `elapsed` the seconds since tossDate.
func toss(touch: Vector2, elapsed: float) -> void:
	# The keyframe animation added below overrides any showBall slide still
	# running on the same property.
	for t in _slide_tweens:
		if t != null and t.is_valid():
			t.kill()
	_slide_tweens.clear()
	is_ball_in_bowl = false
	var ball := _ball_model_center
	var dx := absf(ball.x - touch.x)
	var dy := absf(ball.y - touch.y)
	var dist := sqrt(dy * dy + dx * dx)
	var angle := asin(dx / dist)
	if touch.x < ball.x:
		angle = -angle
	var speed := dist / elapsed if elapsed > 0.0 else INF
	var index := speed_index(speed)
	var ty := target_y(index)
	var s: float = TARGET_SCALE[index]
	# offset = tan(angle) * (480 - (ty + (480 - ball.y)))
	var offset := tan(angle) * (ball.y - ty)
	var ctrl := Vector2(offset * 0.5 + ball.x, ty - MOVE_RISE)
	var end_x := offset + ball.x
	var final_y := ty
	var move_secs := MOVE_SECONDS
	var below := true
	var queued: Array[Dictionary] = []
	# v45: the view the ball is re-inserted against (index 0 = ballIV itself).
	var relative: Node = _ball if index == 0 else _rows[(index - 1) / 2]

	if index in [1, 3, 5, 7, 9]:
		var row := _rows[(index - 1) / 2]
		var row_h: float = ROW_HEIGHTS[(index - 1) / 2]
		var ball_size := BALL_SIZE * _ball_model_scale * s
		var ball_rect := Rect2(Vector2(end_x, ty) - ball_size * 0.5, ball_size)
		var end_pt := Vector2(end_x, ty)
		var bowls := _bowls_of(row)
		var best_area := 0.0
		var best_box: Variant = null
		var best_bowl: Node2D = null
		for b in bowls:
			if b.is_hidden():
				continue
			var local := Rect2(ball_rect.position - row.position - b.frame.position,
				ball_rect.size)
			var res: Array = b.area_of_view_overlapping_rect(local)
			if float(res[0]) > best_area and res[1] != null:
				best_area = res[0]
				best_box = res[1]
				best_bowl = b

		if best_box == null:
			# No hit box touched: on to the row's bottom edge, behind it.
			final_y = row.position.y + row_h
			below = true
			move_secs = PASS_SECONDS
		else:
			var box: Dictionary = best_box
			var tag := int(box["tag"])
			var local_x: float = ball_rect.position.x - row.position.x \
				- best_bowl.frame.position.x + ball_rect.size.x * 0.5
			var roll := randi() % 100
			var bowl_pt: Vector2 = row.position + best_bowl.get_center()
			var bowl_h: float = best_bowl.frame.size.y
			var done := false
			if tag == TAG_LEFT_RIM or tag == TAG_RIGHT_RIM \
					or (tag == TAG_CENTER and roll <= HALF_ROLL):
				var c := BowlView.box_center(box).x
				if c * 0.5 >= local_x or tag != TAG_LEFT_RIM:
					if (c * 1.5 <= local_x or tag == TAG_LEFT_RIM) and tag != TAG_CENTER:
						# The outer edge of a rim: the ball carries on past the
						# row, in front of it, to the row's bottom edge.
						final_y = row.position.y + row_h
						below = false
						move_secs = PASS_SECONDS
						done = true
				if not done:
					if roll > HALF_ROLL:
						# Off the rim and into this bowl.
						queued.append(_anim("BounceEndLand", RIM_LAND_SECONDS, [
							_quad(end_pt, Vector2(end_x + (bowl_pt.x - end_x) * 0.5,
								ty - BOUNCE_RISE), bowl_pt),
							_line(bowl_pt, bowl_pt)]))
						is_ball_in_bowl = true
						below = true
						done = true
					elif randi() % 100 <= HALF_ROLL:
						var r := _neighbour_bounce(row, bowls, best_bowl, end_x, ty,
							bowl_h, queued)
						if r >= 0:
							below = r == 1
							done = true
					if not done:
						if tag != TAG_CENTER:
							# Off the rim and out, landing in front of the row.
							var dir := -1.0 if tag == TAG_LEFT_RIM else 1.0
							queued.append(_anim("BounceEndMiss", BOUNCE_SECONDS, [
								_quad(end_pt, Vector2(end_x + RIM_MISS_CX * dir,
									ty - BOUNCE_RISE),
									Vector2(end_x + RIM_MISS_DX * dir,
										bowl_pt.y + bowl_h * 0.5))]))
							below = false
						else:
							queued.append(_anim("MoveEndLand", DROP_IN_SECONDS,
								[_line(end_pt, bowl_pt)]))
							is_ball_in_bowl = true
							below = true
			elif tag == TAG_CENTER:
				# Clean through the middle.
				queued.append(_anim("MoveEndLand", DROP_IN_SECONDS,
					[_line(end_pt, bowl_pt)]))
				is_ball_in_bowl = true
				below = true

	var move := _anim("MoveBall", move_secs,
		[_quad(ball, ctrl, Vector2(end_x, final_y))])
	ball_animations.append(move)

	# removeFromSuperview + insertSubview:below/aboveSubview:relative.
	_reinsert_ball(relative, below)

	# hideView: ball2IV half way through MoveBall.
	var hide_t := create_tween()
	hide_t.tween_interval(move_secs * 0.5)
	hide_t.tween_callback(func() -> void: _ball2.visible = false)

	# "ScaleBall": both to identity, then to scale s over half the flight,
	# curve 3 (linear). Its did-stop selector body is a no-op (0x11F3B4).
	_ball.scale = Vector2.ONE
	_ball2.scale = Vector2.ONE
	_ball_model_scale = s
	if _scale_tween != null and _scale_tween.is_valid():
		_scale_tween.kill()
	_scale_tween = create_tween().set_parallel(true)
	_scale_tween.tween_property(_ball, "scale", Vector2(s, s), move_secs * 0.5) \
		.set_trans(Tween.TRANS_LINEAR)
	_scale_tween.tween_property(_ball2, "scale", Vector2(s, s), move_secs * 0.5) \
		.set_trans(Tween.TRANS_LINEAR)

	if not ball_animations.is_empty():
		_start_animation(ball_animations[0], true)
	ball_animations.append_array(queued)
	Audio.play("toss")


## The 50% neighbour bounce. Returns 1 (lands, ball below the row),
## 0 (misses, ball above the row) or -1 (no visible neighbour).
func _neighbour_bounce(row: Node2D, bowls: Array, bowl: Node2D, end_x: float,
		ty: float, bowl_h: float, queued: Array[Dictionary]) -> int:
	var idx := bowls.find(bowl)
	var prev: Node2D = bowls[idx - 1] if idx - 1 >= 0 else null
	var next: Node2D = bowls[idx + 1] if idx + 1 < bowls.size() else null
	var chosen: Node2D = null
	var prev_ok: bool = prev != null and not prev.is_hidden()
	var next_ok: bool = next != null and not next.is_hidden()
	if prev_ok:
		chosen = prev
	if next_ok:
		chosen = next
	if prev_ok and next_ok:
		chosen = prev if (randi() & 1) == 0 else next
	if chosen == null:
		return -1
	var lands := (randi() & 1) == 1
	var nb_pt: Vector2 = row.position + chosen.get_center()
	var d := absf(end_x - nb_pt.x)
	var x1: float
	var cx1: float
	if chosen == prev:
		x1 = end_x - d
		cx1 = end_x - d * 0.5
	else:
		x1 = end_x + d
		cx1 = end_x + d * 0.5
	# BounceMid ends at the row frame's top, but the next leg starts at the
	# target height -- a few pixels' jump, exactly as in the original.
	queued.append(_anim("BounceMid", BOUNCE_SECONDS, [_quad(Vector2(end_x, ty),
		Vector2(cx1, ty - BOUNCE_RISE), Vector2(x1, row.position.y))]))
	if lands:
		# Its x is the neighbour's row-local centre, not converted (row1 sits
		# at x 1, so it lands one pixel left there).
		var cx: float = chosen.get_center().x
		queued.append(_anim("BounceEndLand", BOUNCE_SECONDS, [_quad(
			Vector2(x1, ty), Vector2(cx, ty - BOUNCE_RISE), Vector2(cx, nb_pt.y))]))
		is_ball_in_bowl = true
		return 1
	queued.append(_anim("BounceEndMiss", BOUNCE_SECONDS, [_quad(
		Vector2(x1, ty), Vector2(end_x - RIM_MISS_CX, ty - BOUNCE_RISE),
		Vector2(end_x - RIM_MISS_DX, nb_pt.y + bowl_h * 0.5))]))
	return 0


## Re-insert ballIV just below or above `relative` among view's subviews.
## INFERRED for the weak throw (index 0): the original inserts ballIV
## relative to *itself*, already removed from its superview. UIKit's
## behaviour then is not documented; NSView's identical API documents that a
## sibling that is not a subview puts the view below (or above) all its
## siblings, so the ball goes to the very bottom -- under the background, i.e.
## it disappears once ball2IV is hidden half way through the flight.
func _reinsert_ball(relative: Node, below: bool) -> void:
	if relative == _ball:
		_view.move_child(_ball, 0)
		return
	var target := relative.get_index()
	if not below:
		target += 1
	if _ball.get_index() < relative.get_index():
		target -= 1
	_view.move_child(_ball, target)


# -- CAKeyframeAnimation stand-in --------------------------------------------
#
# Each throw leg is a CAKeyframeAnimation on "position" with a CGPath,
# calculationMode linear, fill forwards, not removed on completion, linear
# timing. INFERRED from Core Animation's documented keyframe semantics: with
# keyTimes nil, time is split evenly between the path's elements, and each
# element is traversed by its curve parameter. That matters once: the
# rim-bounce BounceEndLand path is quad + a zero-length line, so the ball
# arrives in 0.6 s and rests for the other 0.6 s.

static func _quad(p0: Vector2, c: Vector2, p1: Vector2) -> Dictionary:
	return {"type": "quad", "p0": p0, "c": c, "p1": p1}


static func _line(p0: Vector2, p1: Vector2) -> Dictionary:
	return {"type": "line", "p0": p0, "p1": p1}


static func _anim(key: String, secs: float, segments: Array) -> Dictionary:
	return {"key": key, "duration": secs, "segments": segments}


static func path_point(anim: Dictionary, t: float) -> Vector2:
	var segs: Array = anim["segments"]
	var d: float = anim["duration"]
	var u := clampf(t / d, 0.0, 1.0) if d > 0.0 else 1.0
	var n := segs.size()
	var i := mini(int(floor(u * n)), n - 1)
	var lt := u * n - float(i)
	var seg: Dictionary = segs[i]
	var p0: Vector2 = seg["p0"]
	var p1: Vector2 = seg["p1"]
	if seg["type"] == "quad":
		var c: Vector2 = seg["c"]
		var m := 1.0 - lt
		return p0 * (m * m) + c * (2.0 * m * lt) + p1 * (lt * lt)
	return p0.lerp(p1, lt)


func _start_animation(anim: Dictionary, with_ball2: bool) -> void:
	_running = anim
	_running_t = 0.0
	_running_drives_ball2 = with_ball2
	_apply_running(0.0)
	_animation_did_start(anim)


func _apply_running(t: float) -> void:
	var p := path_point(_running, t)
	_ball.position = p
	if _running_drives_ball2:
		_ball2.position = p


## layer removeAllAnimations on both balls: positions fall back to the model.
func _stop_ball_animations() -> void:
	_running = {}
	if _scale_tween != null and _scale_tween.is_valid():
		_scale_tween.kill()
	for t in _slide_tweens:
		if t != null and t.is_valid():
			t.kill()
	_slide_tweens.clear()


## animationDidStart: 0x11F1E4.
func _animation_did_start(anim: Dictionary) -> void:
	interaction_enabled = false
	if ball_animations.has(anim) and str(anim["key"]).contains("Bounce"):
		if (randi() & 1) == 0:
			Audio.play("bounce_ppball1")


## animationDidStop:finished: 0x11F3D4. The sound pass runs over *every*
## queued leg, not just the one that stopped (verified in the disassembly at
## 0x11F52C: only the match is conditional) -- so a landing splashes when the
## flight ends and again when the ball settles.
func _animation_did_stop(anim: Dictionary) -> void:
	interaction_enabled = true
	for a: Dictionary in ball_animations:
		var key := str(a["key"])
		if key.contains("Land"):
			Audio.play("splash")
		if key.contains("Miss"):
			Audio.play("bounce_table")
	ball_animations.erase(anim)
	if not ball_animations.is_empty():
		_start_animation(ball_animations[0], false)
	elif is_ball_in_bowl:
		_show_prize_dialog()
	else:
		Audio.play("aww")
		end_throw()


## endThrow 0x11F0F0.
func end_throw() -> void:
	set_ball_count(ball_count - 1)
	if ball_count <= 0:
		_show_out_of_balls_alert()
	else:
		reset_bowls()
		reset_ball()
		show_ball()


## buyBalls 0x11EAC0.
func buy_balls() -> bool:
	if CoinManager.total_coins() > BALL_PRICE - 1:
		_touch_end_arc_date()
		if Defaults.integer_for_key(KEY_PLAYED_ARC_FLAG) == 0:
			Defaults.set_integer_for_key(1, KEY_PLAYED_ARC_FLAG)
			Defaults.synchronize()
		CoinManager.spend_coins(BALL_PRICE)
		set_ball_count(ball_count + NUM_OF_BALLS)
		_update_coin_label(CoinManager.total_coins())
		return true
	# showBuyMoreCoinsMessage 0x1200A4: analytics + a MediaBrix ad only.
	return false


# -- prize dialog ---------------------------------------------------------------

## The isBallInBowl branch of animationDidStop:finished: 0x11F3D4.
func _show_prize_dialog() -> void:
	var dialog := Control.new()
	dialog.name = "PrizeDialog"
	dialog.set_meta("tag", PRIZE_DIALOG_TAG)
	dialog.position = Vector2.ZERO
	dialog.size = Vector2(320, 480)
	dialog.mouse_filter = Control.MOUSE_FILTER_STOP
	# The pop-in is +beginAnimations:/commitAnimations (0x11F3D4): UIKit
	# hit-tests the container at its MODEL transform, identity from the
	# commit, so the full-screen UIView swallows every touch from the first
	# frame. `dialog` is drawn scaling up from 0.01 and Godot hit-tests it
	# through that scale, so an unscaled blocker under it stands in for the
	# model frame (as wm_hitmole / mb_ThrowBallVC already do). Without it the
	# nav buttons answered under the growing dialog.
	# PORT CHOICE: the close button itself is hit where it is drawn.
	var blocker := Control.new()
	blocker.name = "PrizeDialogBlocker"
	blocker.size = Vector2(320, 480)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.add_child(blocker)
	dialog.tree_exiting.connect(blocker.queue_free)
	_view.add_child(dialog)
	_prize_dialog = dialog

	dialog.add_child(_image_rect(Assets.texture(POPUP_ART), Vector2.ZERO, false))

	var prize: Variant = PrizeManager.get_random_prize_game(true, PRIZE_GAME)
	PrizeManager.unlock_prize(prize)
	var prize_tex := _as_texture(PrizeManager.get_prize_image(prize))
	if prize_tex != null:
		dialog.add_child(_image_rect(prize_tex, PRIZE_CENTER, true))

	var close := TextureButton.new()
	close.texture_normal = Assets.texture(CLOSE_ART)
	close.ignore_texture_size = true
	close.stretch_mode = TextureButton.STRETCH_SCALE
	close.size = CLOSE_SIZE
	close.position = CLOSE_CENTER - CLOSE_SIZE * 0.5
	close.pressed.connect(_close_prize_dialog)
	dialog.add_child(close)

	var label_tex: Texture2D = Assets.texture(LABEL_ART)
	var plate := _image_rect(label_tex, LABEL_ART_CENTER, true)
	dialog.add_child(plate)
	var name_label := Label.new()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UILabelFrame.set_frame(name_label, Rect2(Vector2(label_tex.get_width() * 0.5,
		NAME_LABEL_Y) - NAME_LABEL_SIZE * 0.5, NAME_LABEL_SIZE))
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Helvetica", "Helvetica Neue",
		"Nimbus Sans", "Liberation Sans", "Arial"])
	name_label.add_theme_font_override("font", font)
	name_label.add_theme_color_override("font_color", Color.BLACK)
	var prize_name: Variant = PrizeManager.get_prize_name(prize)
	name_label.text = "" if prize_name == null else str(prize_name)
	name_label.add_theme_font_size_override("font_size",
		_fit_font_size(font, name_label.text))
	plate.add_child(name_label)

	# CGAffineTransformScale(0.01) -> identity, 0.5 s, curve 3 (linear).
	dialog.pivot_offset = dialog.size * 0.5
	dialog.scale = Vector2(DIALOG_START_SCALE, DIALOG_START_SCALE)
	create_tween().tween_property(dialog, "scale", Vector2.ONE, DIALOG_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)

	delay_startup_emitter_balloons()
	Audio.play("fanfare")


## adjustsFontSizeToFitWidth with minimumFontSize 6.
func _fit_font_size(font: Font, text: String) -> int:
	var size := NAME_FONT_SIZE
	while size > NAME_MIN_FONT_SIZE and font.get_string_size(text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > NAME_LABEL_SIZE.x:
		size -= 1
	return size


## closePrizeDialog: 0x11FD78.
func _close_prize_dialog() -> void:
	Audio.play("button_press")
	if _prize_dialog != null:
		_prize_dialog.queue_free()
		_prize_dialog = null
	_touch_end_arc_date()
	end_throw()


## delayStartupEmitterBalloons 0x11BA10 -- despite the name, plain
## UIImageViews (UIView animation "Fall"), not a particle emitter: the 13
## bubbles and stars start below the screen and rise 650, fanning out.
func delay_startup_emitter_balloons() -> void:
	for t in _cookie_tweens:
		if t != null and t.is_valid():
			t.kill()
	_cookie_tweens.clear()
	for c in _cookies:
		var start := Vector2(float(randi() % COOKIE_X_SPAN + COOKIE_X0),
			float(randi() % COOKIE_Y_SPAN + COOKIE_Y0))
		c.position = start
		_view.move_child(c, _view.get_child_count() - 1)
		var secs := COOKIE_SECONDS + float(randi() % 100) / 100.0
		var dest := Vector2(start.x + 2.0 * (start.x - 160.0), start.y - COOKIE_RISE)
		var t := create_tween()
		t.tween_property(c, "position", dest, secs) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		_cookie_tweens.append(t)
	Audio.play("cheer")


func _make_cookies() -> void:
	for art: String in COOKIE_ARTS:
		var tex: Texture2D = Assets.texture(art)
		var c := Sprite2D.new()
		c.texture = tex
		c.centered = true
		# contentMode 1 (aspect fit) inside the 80x80 frame.
		var ts := tex.get_size()
		var k := minf(COOKIE_BOX / ts.x, COOKIE_BOX / ts.y)
		c.scale = Vector2(k, k)
		c.position = COOKIE_PARK
		_view.add_child(c)
		_cookies.append(c)


func _image_rect(tex: Texture2D, center: Vector2, centred: bool) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.size = tex.get_size()
	r.position = center - r.size * 0.5 if centred else center
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## PrizeManager.get_prize_image answers a UIImage in the original; accept
## whatever the port's PrizeManager hands back.
static func _as_texture(v: Variant) -> Texture2D:
	if v is Texture2D:
		return v
	if v is Image:
		return ImageTexture.create_from_image(v)
	if v is String and v != "":
		return Assets.texture(v)
	return null


# -- out-of-balls alert (endThrow) ------------------------------------------

## UIAlertView: title "", the message, Cancel / Buy (Screen.show_alert, the
## iOS 6 rebuild). No click sound: dismissing a UIAlertView makes no app
## sound and this class's delegate plays none for these titles.
func _show_out_of_balls_alert() -> void:
	var clicked := func(title: String) -> void:
		_alert_layer = null
		alert_dismissed(title)
	_alert_layer = show_alert(OUT_OF_BALLS, ["Cancel", "Buy"], clicked, false)


## alertView:didDismissWithButtonIndex: 0x11FEF8. ("OK" and "Get Coins" are
## handled there too, but this class never shows an alert with them.)
func alert_dismissed(title: String) -> void:
	match title:
		"OK":
			end_throw()
		"Buy":
			if buy_balls():
				reset_bowls()
				reset_ball()
				show_ball()
		"Get Coins":
			Audio.play("store")
			Nav.push("CoinStoreViewController")


func alert_showing() -> bool:
	return _alert_layer != null


func prize_dialog() -> Control:
	return _prize_dialog


# -- buttons ---------------------------------------------------------------------

## backClick: 0x11BD18.
func _on_backClick() -> void:
	if not interaction_enabled:
		return
	_touch_end_arc_date()
	CoinManager.sync_coins(true)
	Audio.play("button_press")
	Nav.back()


## coinsClick: 0x11BEC8.
func _on_coinsClick() -> void:
	if not interaction_enabled:
		return
	Audio.play("store")
	Nav.push("CoinStoreViewController")


## playClick: 0x11BFA8 ("more balls"). isBallInAir is never set anywhere, so
## only the disabled view (during a throw) blocks it.
func _on_playClick() -> void:
	if not interaction_enabled:
		return
	Audio.play("button_press")
	if not is_ball_in_air and buy_balls():
		reset_ball()
		if ball_count == NUM_OF_BALLS:
			show_ball()


## prizeClick: 0x11C068 (the fish button, top right).
func _on_prizeClick() -> void:
	if not interaction_enabled:
		return
	GameState.screen_args["PrizeViewController"] = {
		"prizes": PrizeManager.get_prizes_for_game(PRIZE_GAME),
		"background_file": PRIZE_BACKGROUND,
	}
	Nav.push("PrizeViewController")
	Audio.play("trophy_water")


# -- defaults bookkeeping ----------------------------------------------------------

## The "if dateArcFlag >= 1, endArcDate = now" block repeated in backClick:,
## showBall, buyBalls and closePrizeDialog: (feeds DataLogging arcTime).
func _touch_end_arc_date() -> void:
	if Defaults.integer_for_key(KEY_DATE_ARC_FLAG) >= 1:
		Defaults.set_object_for_key(_now_date(), KEY_END_ARC_DATE)
		Defaults.synchronize()


## PORT CHOICE: an NSDate is stored as Unix seconds.
static func _now_date() -> float:
	return Time.get_unix_time_from_system()
