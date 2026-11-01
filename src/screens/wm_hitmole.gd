# Whac-a-Mole midway game. Port of wm_hitmole (0x16B208..0x16F0D0) with its
# helpers Board (res://midway/wm_Board.gd) and Animator
# (res://midway/wm_Animator.gd). Every method of the class was walked in the
# original binary, with doubles and float constants read from the instructions.
#
# What the player sees (all from the class):
#
#   initWithNibName:bundle: 0x16B2A0  playCount = defaults
#       "WhackAMolePlayCountKey"; NUM_OF_PLAYS = IAPlist GameData/
#       WAPlayPurchase or 2; 13 "falling cookies" (80x80 aspect-fit image
#       views: five circus bubbles, three repeated, five end-game stars)
#       parked at (-999,-999) above the nib views.
#   viewDidLoad 0x16B6C0 / viewWillAppear: 0x16B8C8  labels; time "00:30";
#       the row scale (0.8) and its step (0.1); coins label.
#   touchesBegan:withEvent: 0x16E7D4  a tap that lands on no button and no
#       mole: when idle (no countdown, no race, no prize popup) it is the
#       "tap to start": button_press, then the out-of-plays alert if
#       playCount < 1, else hide inst_image and startCountdown. Otherwise it
#       swings the hammer with the board sound.
#   startCountdown 0x16C7FC / countdownTick: 0x16C92C  a clear full-screen
#       view (tag 3) eats every touch; a 1.0 s repeating timer shows
#       Mini_G_3, _2, _1 (countdown_tick) then Mini_G_Go (countdown_end),
#       each centred (160,240) fading in over 0.25 s linear; startGame: 1.0 s
#       after Go.
#   startGame: 0x16BA14  removes the countdown view; 1.0 s tick timer;
#       30 s; playCount-1; 6..9 moles at Board centres, each row 0.1 larger
#       than the one above (0.8 first); the hammer (Wm_Hammer.png) created
#       hidden at (200,100).
#   startTimer 0x16C1A0  each second: time-1, "00:%d" / "00:0%d",
#       Time_tick; below 0 -> checkGameStatus. So 31 ticks after Go+1s.
#   checkGameStatus 0x16C304  score <= 14: aww.mp3; 15..25 "Small";
#       26..35 "Medium"; 36+ "Large" prize popup. Then resetGame.
#   hitHammerAtPoint:BoardSound: 0x16CC50 / hideHammer 0x16C5F8 / hide
#       0x16C7B8  hammer swing, see hit_hammer_at_point_board_sound().
#   showPrizeView: 0x16D4B0  in-place popup (not PrizeViewController):
#       prize_popup.png, the prize, its name on prize_label.png, a close
#       button (daily_login_btn.png); scales up from 0.01 over 0.5 s linear;
#       the falling cookies rise past it; fanfare + cheer.
#   coinsClick: / playClick: / prizeClick: 0x16E320 / 0x16E42C / 0x16E4B4
#       only between games. backBtn: 0x16E5F8 always.
#
# Not ported (no player-visible effect in the port): DataLogging analytics
# calls, the interstitial ad in backBtn: (needs FF_KEY_EVERYTHING false; the
# port ships everything unlocked), the dealloc/viewDidUnload releases.

extends "res://core/Screen.gd"
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const Board := preload("res://midway/wm_Board.gd")
const Animator := preload("res://midway/wm_Animator.gd")

const VIEW_RECT := Rect2(0, 0, 320, 480)   # view.frame (status bar hidden)

## Defaults keys, as the original spells them.
const PLAY_COUNT_KEY := "WhackAMolePlayCountKey"
const UNIQUE_KEY := "whacUnique"
const DATE_ARC_FLAG := "dateArcFlag"
const START_ARC_DATE := "startArcDate"
const END_ARC_DATE := "endArcDate"
const PLAYED_ARC_FLAG := "playedArcFlag"

## Game key for PrizeManager (getRandomPrizeByCategory:... / getPrizesForGame:).
const PRIZE_GAME := "WAKEAMOLE"
const OUT_OF_PLAYS := "You are out of plays. Would you like to buy more?"

## initWithNibName:bundle: fallingCookies, in order.
const FALLING_COOKIES := [
	"circus_ballbubble.png", "circus_clownbubble.png", "circus_greenbubble.png",
	"circus_pinkbubble.png", "circus_yellowbubble.png", "circus_yellowbubble.png",
	"circus_pinkbubble.png", "circus_greenbubble.png",
	"Star_Emitters_End_Game_PS_1.png", "Star_Emitters_End_Game_PS_2.png",
	"Star_Emitters_End_Game_PS_3.png", "Star_Emitters_End_Game_PS_4.png",
	"Star_Emitters_End_Game_PS_5.png",
]
const COOKIE_FRAME := Vector2(80, 80)        # contentMode 1 = aspect fit
const PARKED := Vector2(-999, -999)

const GAME_SECONDS := 30                     # startGame: timeCount
const TICK := 1.0                            # tickTimer / countDownTimer
const COUNTDOWN_FROM := 3                    # startCountdown setTag:3
const COUNTDOWN_FADE := 0.25                 # "TimeFadeIn", curve 3 (linear)
const GO_TO_START := 1.0                     # afterDelay {0, 0x3FF00000}
const MOLES_MIN := 6                         # getRandomNumber:6 to:9
const MOLES_MAX := 9
const GRID := 3                              # metrix
const MOLE_TAG := 999
const MOLE_SLEEP_MIN := 1.0
const MOLE_SLEEP_MAX := 5.0
const MOLE_ANIM_MIN := 1.0
const MOLE_ANIM_MAX := 5.0
const SCALE_START := 0.8                     # dword_7A3378
const SCALE_STEP := 0.1                      # dword_7A337C
const ROW_JUMP := 20.0                       # y step that starts a new row
const MOLE_SHEET := "Wm_Mole_Spritesheeet.png"   # sic: three e's

const HAMMER_ART := "Wm_Hammer.png"
const HAMMER_HOME := Vector2(200, 100)
## Doubles read from the binary: setAnimationDuration: 0.300000012
## ((double)0.3f), afterDelay {0x33333333, 0x3FD33333} = 0.3. Its high word
## alone, misread as a float, would give 1.65f.
const HAMMER_SWING := 0.3
const HAMMER_TILT := 0.02                    # CGAffineTransformMakeRotation
const HAMMER_ARC := 1.8                      # -1.8 swing, +1.8 return

const PRIZE_TAG := 1000000
const PRIZE_SCALE_FROM := 0.01
const PRIZE_SHOW := 0.5                      # "Show_Upgrade_Dialog", curve 3
const PRIZE_CENTER := Vector2(160, 240)
const PRIZE_BUTTON_SIZE := Vector2(94, 63)
const PRIZE_BUTTON_CENTER := Vector2(160, 400)
const PRIZE_LABEL_ART_CENTER := Vector2(160, 355)
const PRIZE_NAME_SIZE := Vector2(74, 14)
const PRIZE_NAME_FONT := 12
const PRIZE_NAME_MIN_FONT := 6
const PRIZE_NAME_Y := 16.0                   # centre y inside prize_label.png
const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans", "Liberation Sans", "Arial"]

## CoinManager's COIN_NOTIFICATION_VALUE_CHANGED (userInfo totalCoins).
const COIN_SIGNAL := &"coin_value_changed"

const PLAY_PRICE := 5                        # buyPlay spendCoins:5 (> 4 coins)
const PLAYS_PER_BUY := 2

# -- ivars -------------------------------------------------------------------
var touch_location := Vector2.ZERO
var hammer: Sprite2D = null
var tick_timer: Timer = null
var is_hammer := false
var is_counting_down := false
var count_down_timer: Timer = null
var score := 0
var metrix := 0
var play_count := 0
var num_of_plays := 0                        # NUM_OF_PLAYS: set, never read
var falling_cookies: Array[Sprite2D] = []
var is_start_game := false
var time_count := 0
var race_started := false
## tapHoseToStart, starTouchHammer, hoseCount, hitCount, hoseGrabbed: ivars
## with no nib outlet and no writer -- nil/0 for the whole game, so every
## message sent to them (the "HideTapLabel" alpha fade) is a no-op.

# outlets
var inst_image: CanvasItem
var coin_label: Label
var play_count_label: Label
var time_count_label: Label
var score_tens_digit: Sprite2D
var score_ones_digit: Sprite2D

## dword_7A3378 / dword_7A337C: the running mole scale and its step.
var _mole_scale := SCALE_START
var _mole_scale_step := SCALE_STEP

## The hammer's model transform (what UIKit's `transform` property holds;
## animations run from the old model value to the new one).
var _hammer_angle := 0.0
var _hammer_scale := 1.0
var _hammer_tween: Tween

var _countdown_view: Control = null          # tag 3
var _prize_view: Node2D = null               # tag 1000000
var _prize_blocker: Control = null
var _cookie_tweens: Dictionary = {}


## The nib's inst_image is the "tap to start" plate. Screen._ready() would
## slide it in like a food screen's instruction banner; this class has no
## changeInstruction: and never moves it.
func _place_instruction() -> void:
	pass


func on_enter() -> void:
	inst_image = outlet("inst_image") as CanvasItem
	coin_label = outlet("coinLabel") as Label
	play_count_label = outlet("playCountLabel") as Label
	time_count_label = outlet("timeCountLabel") as Label
	score_tens_digit = outlet("scoreTensDigit") as Sprite2D
	score_ones_digit = outlet("scoreOnesDigit") as Sprite2D
	_init_with_nib()
	_view_did_load()
	_view_will_appear()


## coinsClick: (0x16E320) and prizeClick: (0x16E4B4) push over this
## controller, which UINavigationController keeps alive -- so the unsaved
## playCount (persisted only by backBtn:), the score digits and an open prize
## view are all there on return. Nav keeps this instance (this replaces an
## earlier static _resume that carried play_count/score).
func keeps_state_on_push() -> bool:
	return true


## Back on top: viewWillAppear: (0x16B8C8) again -- "00:30", the mole scale
## and its step reset, the coin label. (Its view setUserInteractionEnabled:YES
## is a no-op: nothing in the class ever disables it.)
func on_resume() -> void:
	_view_will_appear()


## viewWillDisappear: 0x16BA04 -- invalidateTimer, on a push as on a pop.
func on_exit() -> void:
	invalidate_timer()


# -- life cycle --------------------------------------------------------------

## initWithNibName:bundle: 0x16B2A0.
func _init_with_nib() -> void:
	# addObserver: COIN_NOTIFICATION_VALUE_CHANGED -> coinValueChanged:
	# (CoinManager's coin_value_changed signal; freed screens auto-disconnect).
	if CoinManager.has_signal(COIN_SIGNAL) \
			and not CoinManager.is_connected(COIN_SIGNAL, coin_value_changed):
		CoinManager.connect(COIN_SIGNAL, coin_value_changed)
	play_count = Defaults.integer_for_key(PLAY_COUNT_KEY)
	_set_label(play_count_label, "%d" % play_count)
	# IAPlistManager iaplistDict GameData/WAPlayPurchase intValue, or 2. The
	# IAPlist is server-delivered and none ships, so 2. Never read again.
	num_of_plays = 2
	for art: String in FALLING_COOKIES:
		var iv := Sprite2D.new()
		iv.centered = true
		iv.texture = _tex(art)
		if iv.texture != null:
			var sz: Vector2 = iv.texture.get_size()
			var fit: float = minf(COOKIE_FRAME.x / sz.x, COOKIE_FRAME.y / sz.y)
			iv.scale = Vector2(fit, fit)
		iv.position = PARKED
		add_child(iv)
		falling_cookies.append(iv)


## viewDidLoad 0x16B6C0 (DataLogging calls dropped).
func _view_did_load() -> void:
	_set_label(play_count_label, "%d" % play_count)
	if not Defaults.bool_for_key(UNIQUE_KEY):
		Defaults.set_bool_for_key(true, UNIQUE_KEY)
		Defaults.synchronize()
	if Defaults.integer_for_key(DATE_ARC_FLAG) == 0:
		Defaults.set_object_for_key(_now(), START_ARC_DATE)
		Defaults.set_integer_for_key(1, DATE_ARC_FLAG)
		Defaults.synchronize()


## viewWillAppear: 0x16B8C8. (byte_7A8EBC = 0 there is a write-only global.)
func _view_will_appear() -> void:
	_set_label(time_count_label, "00:30")
	_mole_scale_step = SCALE_STEP
	_mole_scale = SCALE_START
	_set_label(coin_label, "%d" % CoinManager.total_coins())


## coinValueChanged: 0x16B208.
func coin_value_changed(total_coins: int) -> void:
	_set_label(coin_label, "%d" % total_coins)


# -- touches -------------------------------------------------------------------

## UIKit hit-testing for what is not a button: the topmost mole whose
## transformed 70x70 bounds hold the point gets the touch (Animator
## touchesBegan:), anything else reaches the controller (touchesBegan:).
## The nib buttons are Controls and take their own presses first; no mole
## overlaps one (centres y 168..283, buttons y < 61 and > 418).
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var p := mb.position
	var mole := _mole_at(p)
	if mole != null:
		mole.call("touches_began")
	else:
		touches_began(p)
	get_viewport().set_input_as_handled()


func _mole_at(p: Vector2) -> Node:
	var kids := get_children()
	for i in range(kids.size() - 1, -1, -1):
		var c: Node = kids[i]
		if c.get_script() == Animator and int(c.get("tag")) == MOLE_TAG \
				and bool(c.get("user_interaction_enabled")) \
				and (c as CanvasItem).visible and bool(c.call("point_inside", p)):
			return c
	return null


## touchesBegan:withEvent: 0x16E7D4.
func touches_began(p: Vector2) -> void:
	if not VIEW_RECT.has_point(p) or is_counting_down or race_started \
			or _view_with_tag_prize() != null:
		touch_location = p
		hit_hammer_at_point_board_sound(touch_location, true)
		return
	Audio.play("button_press")
	if play_count < 1:
		show_alert(OUT_OF_PLAYS, ["Cancel", "Buy"], alert_view_clicked_button, false)
	else:
		if inst_image != null:
			inst_image.visible = false
		start_countdown()
		# tapHoseToStart setAlpha:1 / "HideTapLabel" fade to 0: nil, no-op.


## touchesEnded:withEvent: 0x16E7D0 is empty.


## alertView:clickedButtonAtIndex: 0x16DC20. Only "Cancel"/"Buy" can reach
## it -- this class shows no other alert -- and "Cancel" matches no branch.
## (The "Get Coins"/"OK"/"Yes"/"No" branches are unreachable from here.)
func alert_view_clicked_button(title: String) -> void:
	if title == "Buy":
		buy_play()


## Animator delegate: didAnimatorTouchBegan: 0x16EB04.
func did_animator_touch_began(p: Vector2) -> void:
	hit_hammer_at_point_board_sound(p, false)


## Animator delegate: didAnimatorHit 0x16EB28.
func did_animator_hit() -> void:
	score += 1
	set_score_display()


# -- countdown -----------------------------------------------------------------

## startCountdown 0x16C7FC.
func start_countdown() -> void:
	var v := Control.new()
	v.position = VIEW_RECT.position
	v.size = VIEW_RECT.size
	v.mouse_filter = Control.MOUSE_FILTER_STOP     # a plain UIView eats touches
	v.set_meta("tag", COUNTDOWN_FROM)
	v.gui_input.connect(_on_blocker_input.bind(v))
	add_child(v)
	_countdown_view = v
	is_counting_down = true
	count_down_timer = _schedule_timer(TICK, &"countdown_tick", v)


## countdownTick: 0x16C92C.
func countdown_tick(v: Control) -> void:
	_set_label(time_count_label, "00:30")
	for c in v.get_children():
		v.remove_child(c)
		c.queue_free()
	var tag: int = int(v.get_meta("tag"))
	var art: String
	if tag < 1:
		Audio.play("countdown_end")
		art = "Mini_G_Go.png"
	else:
		art = "Mini_G_%d.png" % tag
		Audio.play("countdown_tick")
	var iv := Sprite2D.new()
	iv.centered = true
	iv.texture = _tex(art)
	iv.position = Vector2(160, 240)
	v.add_child(iv)
	iv.modulate.a = 0.0
	iv.create_tween().tween_property(iv, "modulate:a", 1.0, COUNTDOWN_FADE) \
		.set_trans(Tween.TRANS_LINEAR)
	if tag <= 0:
		_invalidate(count_down_timer)
		count_down_timer = null
		_perform_after(GO_TO_START, &"start_game", v)
	else:
		v.set_meta("tag", tag - 1)


# -- the game ------------------------------------------------------------------

## getRandomNumber:to: 0x16B6A4: inclusive a..b.
func get_random_number_to(a: int, b: int) -> int:
	return randi() % (1 - a + b) + a


## startGame: 0x16BA14.
func start_game(sender: Node) -> void:
	if is_instance_valid(sender):
		if sender.get_parent() == self:
			remove_child(sender)
		sender.queue_free()
	if sender == _countdown_view:
		_countdown_view = null
	is_counting_down = false
	tick_timer = _schedule_timer(TICK, &"start_timer")
	time_count = GAME_SECONDS
	is_start_game = true
	var n := get_random_number_to(MOLES_MIN, MOLES_MAX)
	var board = Board.new()
	score = 0
	set_score_display()
	race_started = true
	play_count -= 1
	_set_label(play_count_label, "%d" % play_count)
	metrix = GRID
	_mole_scale = SCALE_START
	var centers: Array = board.get_random_centers_no_of_mole_screen_width_screen_height(
		GRID, n, 320, 480)
	var sheet_cutter = Animator.new()
	var frames: Array = sheet_cutter.get_image_array_colums_rows_img_width_img_height(
		MOLE_SHEET, 4, 2, 114, 114)
	sheet_cutter.free()
	var prev_y := 0.0
	if not centers.is_empty():
		var first: Vector2 = centers[0]
		prev_y = first.y
	for c: Vector2 in centers:
		var mole = Animator.new()
		mole.initwith_center(c)
		mole.set_center(c)
		# A new row starts more than 20 pt below the previous centre; each
		# row is drawn 0.1 larger than the one above it.
		if c.y - prev_y > ROW_JUMP:
			_mole_scale += _mole_scale_step
		mole.set_transform_scale(_mole_scale)
		mole.is_hit = false
		mole.is_sleep = false
		mole.is_awake = true
		mole.sleep_min_time = MOLE_SLEEP_MIN
		mole.sleep_max_time = MOLE_SLEEP_MAX
		mole.animation_min_time = MOLE_ANIM_MIN
		mole.animation_max_time = MOLE_ANIM_MAX
		mole.image_array = frames
		mole.user_interaction_enabled = true
		mole.tag = MOLE_TAG
		mole.delegate = self
		# The original calls startSleeping just before addSubview:; Godot
		# timers need the node in the tree, so the two swap (same frame).
		add_child(mole)
		mole.start_sleeping()
		prev_y = c.y
	hammer = Sprite2D.new()
	hammer.centered = true
	hammer.texture = _tex(HAMMER_ART)
	hammer.position = HAMMER_HOME
	_hammer_angle = 0.0
	_hammer_scale = 1.0
	_apply_hammer_transform()
	add_child(hammer)
	hammer.visible = false
	if Defaults.integer_for_key(DATE_ARC_FLAG) >= 1:
		Defaults.set_object_for_key(_now(), END_ARC_DATE)
		Defaults.synchronize()


## startTimer 0x16C1A0.
func start_timer() -> void:
	time_count -= 1
	if time_count > 9:
		_set_label(time_count_label, "00:%d" % time_count)
	else:
		_set_label(time_count_label, "00:0%d" % time_count)
	Audio.play("Time_tick")
	if time_count <= -1:
		invalidate_timer()
		check_game_status()


## invalidateTimer 0x16C2C0.
func invalidate_timer() -> void:
	if tick_timer != null:
		_invalidate(tick_timer)
		tick_timer = null


## checkGameStatus 0x16C304.
func check_game_status() -> void:
	if score > 14:
		if score > 25:
			if score - 26 > 9:
				show_prize_view("Large")
			else:
				show_prize_view("Medium")
		else:
			show_prize_view("Small")
	else:
		Audio.play("aww")
	reset_game()


## resetGame 0x16C3C0.
func reset_game() -> void:
	_set_label(time_count_label, "00:30")
	race_started = false
	if inst_image != null:
		inst_image.visible = true
	if hammer != null:
		hammer.visible = false
	for c in get_children():
		if c.get_script() == Animator and int(c.get("tag")) == MOLE_TAG:
			c.call("stop_animating")
			c.call("invalidate_timer")
			c.call("cancel_previous_perform_requests")
			remove_child(c)
			c.set("delegate", null)
			c.queue_free()
	is_start_game = false
	if hammer != null:
		_kill_hammer_tween()
		remove_child(hammer)
		hammer.queue_free()
	hammer = null


## setScoreDisplay 0x16EB6C. imageNamed: "wm_Score_%i"; a tens digit of 10+
## names no image and the view goes blank, as on the device.
func set_score_display() -> void:
	if score_tens_digit != null:
		score_tens_digit.texture = _tex("wm_Score_%d.png" % (score / 10))
	if score_ones_digit != null:
		score_ones_digit.texture = _tex("wm_Score_%d.png" % (score % 10))


# -- hammer ----------------------------------------------------------------------

## hitHammerAtPoint:BoardSound: 0x16CC50 (constants read from the instructions).
##
## Only for 20 < x < 290 and while no swing is in progress (isHammer). The
## hammer is shown only inside the board band 150 < y < 325 during a game,
## and only then does a tap off the moles knock (wm_hit_board). Its pose is
## reset to rotation 0.02 at scale 1, then by y band:
##   y < 200          centre (x+30, y-10), scale 0.7
##   200 < y < 257    centre (x+40, y-15), scale 0.8
##   257 < y < 325    centre (x+40, y-15), scale 0.9
##   y = 200, y = 257 or y >= 325: centre and scale untouched
## then rotates by -1.8 rad over 0.3 s (ease-in-out); hideHammer 0.3 s later.
func hit_hammer_at_point_board_sound(p: Vector2, board_sound: bool) -> void:
	var x := p.x
	var y := p.y
	if not (x > 20.0 and x < 290.0 and not is_hammer):
		return
	if hammer != null:
		hammer.modulate.a = 1.0
	if y < 325.0 and y > 150.0 and is_start_game:
		if hammer != null:
			hammer.visible = true
		if board_sound:
			Audio.play("wm_hit_board")
	is_hammer = true
	_kill_hammer_tween()
	_hammer_angle = HAMMER_TILT
	_hammer_scale = 1.0
	if y >= 200.0:
		if y <= 200.0 or y >= 257.0:
			if y > 257.0 and y < 325.0:
				_set_hammer_center(Vector2(x + 40.0, y - 15.0))
				_hammer_scale *= 0.9
		else:
			_set_hammer_center(Vector2(x + 40.0, y - 15.0))
			_hammer_scale *= 0.8
	else:
		_set_hammer_center(Vector2(x + 30.0, y - 10.0))
		_hammer_scale *= 0.7
	_apply_hammer_transform()
	_animate_hammer(-HAMMER_ARC)
	_perform_after(HAMMER_SWING, &"hide_hammer")


## hideHammer 0x16C5F8: swing back (+1.8 over 0.3 s), clear isHammer, and
## hide 0.3 s later.
func hide_hammer() -> void:
	_animate_hammer(HAMMER_ARC)
	is_hammer = false
	_perform_after(HAMMER_SWING, &"hide_hammer_view")


## hide 0x16C7B8. (Renamed: `hide` is CanvasItem's own method.)
func hide_hammer_view() -> void:
	if hammer != null:
		hammer.visible = false
	is_hammer = false


func _set_hammer_center(c: Vector2) -> void:
	if hammer != null:
		hammer.position = c


func _apply_hammer_transform() -> void:
	if hammer != null:
		hammer.rotation = _hammer_angle
		hammer.scale = Vector2(_hammer_scale, _hammer_scale)


## "MoveHammer": transform = current concat rotation(delta), 0.3 s, curve 0
## (ease-in-out). A new animation on the same property replaces the old one.
func _animate_hammer(delta: float) -> void:
	var from := _hammer_angle
	_hammer_angle += delta
	if hammer == null:
		return
	_kill_hammer_tween()
	hammer.rotation = from
	_hammer_tween = hammer.create_tween()
	_hammer_tween.tween_property(hammer, "rotation", _hammer_angle, HAMMER_SWING) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _kill_hammer_tween() -> void:
	if _hammer_tween != null and _hammer_tween.is_valid():
		_hammer_tween.kill()
	_hammer_tween = null


# -- prize popup -------------------------------------------------------------------

## showPrizeView: 0x16D4B0.
func show_prize_view(category: String) -> void:
	# The 320x480 container is a plain UIView: it swallows every touch that
	# misses its button (they reach touchesBegan:, which swings nothing
	# because the race is over). The blocker stays full size while the
	# container scales, as UIKit hit-tests the model transform.
	var blocker := Control.new()
	blocker.position = VIEW_RECT.position
	blocker.size = VIEW_RECT.size
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	blocker.gui_input.connect(_on_blocker_input.bind(blocker))
	add_child(blocker)
	_prize_blocker = blocker

	var v := Node2D.new()
	v.position = PRIZE_CENTER                  # scales about its centre
	v.set_meta("tag", PRIZE_TAG)
	add_child(v)
	_prize_view = v

	var bg := Sprite2D.new()
	bg.centered = false
	bg.texture = _tex("prize_popup.png")
	bg.position = -PRIZE_CENTER                # initWithImage: frame at (0,0)
	v.add_child(bg)

	var prize: Variant = PrizeManager.get_random_prize_by_category_game_categoried(
		true, PRIZE_GAME, category)
	PrizeManager.unlock_prize(prize)
	var prize_iv := Sprite2D.new()
	prize_iv.centered = true
	prize_iv.texture = _prize_texture(PrizeManager.get_prize_image(prize))
	prize_iv.position = Vector2(160, 240) - PRIZE_CENTER
	v.add_child(prize_iv)

	var btn := TextureButton.new()
	btn.texture_normal = _tex("daily_login_btn.png")
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE
	btn.size = PRIZE_BUTTON_SIZE
	btn.position = PRIZE_BUTTON_CENTER - PRIZE_BUTTON_SIZE * 0.5 - PRIZE_CENTER
	btn.pressed.connect(close_prize_dialog)
	v.add_child(btn)

	var label_iv := Sprite2D.new()
	label_iv.centered = true
	label_iv.texture = _tex("prize_label.png")
	label_iv.position = PRIZE_LABEL_ART_CENTER - PRIZE_CENTER
	v.add_child(label_iv)

	# UILabel (0,0,74,14) inside prize_label.png, centred at
	# (labelImage.width * 0.5, 16); system font at 12, shrinking to fit the
	# width down to 6; centred; clear background.
	var label_size: Vector2 = label_iv.texture.get_size() if label_iv.texture != null \
		else Vector2.ZERO
	var label_origin: Vector2 = PRIZE_LABEL_ART_CENTER - label_size * 0.5
	var name_center := label_origin + Vector2(label_size.x * 0.5, PRIZE_NAME_Y)
	var name_label := Label.new()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UILabelFrame.set_frame(name_label, Rect2(name_center - PRIZE_NAME_SIZE * 0.5
		- PRIZE_CENTER, PRIZE_NAME_SIZE))
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.clip_text = true
	var font := SystemFont.new()
	font.font_names = PackedStringArray(FONT_NAMES)
	name_label.add_theme_font_override("font", font)
	name_label.add_theme_color_override("font_color", Color.BLACK)
	var prize_name: Variant = PrizeManager.get_prize_name(prize)
	name_label.text = "" if prize_name == null else str(prize_name)
	name_label.add_theme_font_size_override("font_size",
		_fit_font_size(font, name_label.text, PRIZE_NAME_SIZE.x))
	v.add_child(name_label)

	v.scale = Vector2(PRIZE_SCALE_FROM, PRIZE_SCALE_FROM)
	v.create_tween().tween_property(v, "scale", Vector2.ONE, PRIZE_SHOW) \
		.set_trans(Tween.TRANS_LINEAR)
	delay_startup_emitter_balloons()
	Audio.play("fanfare")
	if Defaults.integer_for_key(DATE_ARC_FLAG) >= 1:
		Defaults.set_object_for_key(_now(), END_ARC_DATE)
		Defaults.synchronize()


## closePrizeDialog: 0x16DBB4: button_press, remove the sender's superview.
func close_prize_dialog() -> void:
	Audio.play("button_press")
	if _prize_view != null and is_instance_valid(_prize_view):
		remove_child(_prize_view)
		_prize_view.queue_free()
	if _prize_blocker != null and is_instance_valid(_prize_blocker):
		remove_child(_prize_blocker)
		_prize_blocker.queue_free()
	_prize_view = null
	_prize_blocker = null


## viewWithTag:1000000.
func _view_with_tag_prize() -> Node:
	if _prize_view != null and is_instance_valid(_prize_view):
		return _prize_view
	return null


## delayStartupEmitterBalloons 0x16D1A8 (despite the name, plain UIView
## animations, not a particle emitter). Each of the 13 images jumps to
## (rand()%200 + 60, rand()%50 + 520), comes to the front, and rises over
## (rand()%100)/100 + 1.5 s, curve 1 (ease-in), to
## (x + 2*(x - 160), y - 650) -- fanning out from the middle.
func delay_startup_emitter_balloons() -> void:
	for iv in falling_cookies:
		var x: int = _rand() % 200 + 60
		var y: int = _rand() % 50 + 520
		var from := Vector2(float(x), float(y))
		if _cookie_tweens.has(iv):
			var old: Tween = _cookie_tweens[iv]
			if old != null and old.is_valid():
				old.kill()
		iv.position = from
		move_child(iv, get_child_count() - 1)    # bringSubviewToFront:
		var secs: float = float(_rand() % 100) / 100.0 + 1.5
		var to := Vector2(from.x + 2.0 * (from.x - 160.0), from.y - 650.0)
		var tw := iv.create_tween()
		tw.tween_property(iv, "position", to, secs) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		_cookie_tweens[iv] = tw
	Audio.play("cheer")


# -- buttons ------------------------------------------------------------------------

## buyPlay 0x16E0A4.
func buy_play() -> bool:
	if CoinManager.total_coins() > PLAY_PRICE - 1:
		if Defaults.integer_for_key(DATE_ARC_FLAG) >= 1:
			Defaults.set_object_for_key(_now(), END_ARC_DATE)
			Defaults.synchronize()
		if Defaults.integer_for_key(PLAYED_ARC_FLAG) == 0:
			Defaults.set_integer_for_key(1, PLAYED_ARC_FLAG)
			Defaults.synchronize()
		CoinManager.spend_coins(PLAY_PRICE)
		# spendCoins: posts COIN_NOTIFICATION_VALUE_CHANGED -> coinValueChanged:.
		if not CoinManager.has_signal(COIN_SIGNAL):
			coin_value_changed(CoinManager.total_coins())
		play_count += PLAYS_PER_BUY
		_set_label(play_count_label, "%d" % play_count)
		return true
	show_buy_more_coins_message()
	return false


## showBuyMoreCoinsMessage 0x16E020 -> IAPlistManager
## displayMediaBrixForLocation:"MiniGame" withMiniGame: (0x1757E0). That
## method does nothing at all unless the server IAPlist has an
## "Advertising" dictionary (then: a MediaBrix ad, or a "You do not have
## enough coins. Would you like to buy more?" Cancel / Get Coins alert owned
## by IAPlistManager). No IAPlist ships and the server is gone, so -- as on a
## fresh device install -- nothing is shown.
func show_buy_more_coins_message() -> void:
	pass


## coinsClick: 0x16E320.
func _on_coinsClick() -> void:
	if not race_started and not is_counting_down:
		Audio.play("store")
		Nav.push("CoinStoreViewController")


## playClick: 0x16E42C.
func _on_playClick() -> void:
	if not race_started and not is_counting_down:
		Audio.play("button_press")
		buy_play()


## prizeClick: 0x16E4B4: PrizeViewController with setPrizes: and
## setBackgroundFile:.
func _on_prizeClick() -> void:
	if not race_started and not is_counting_down:
		Audio.play("trophy_door")
		GameState.screen_args["PrizeViewController"] = {
			"prizes": PrizeManager.get_prizes_for_game(PRIZE_GAME),
			"background_file": "wm_prize_bg.png",
		}
		Nav.push("PrizeViewController")


## backBtn: 0x16E5F8. Not guarded: it also abandons a running game. The play
## count is persisted only here, from the label's text.
func _on_backBtn() -> void:
	Audio.play("button_press")
	reset_game()
	var shown: String = play_count_label.text if play_count_label != null else ""
	Defaults.set_integer_for_key(shown.to_int(), PLAY_COUNT_KEY)
	# FF_KEY_EVERYTHING false -> displayAdForLocation:"Interstitial": the port
	# ships everything unlocked and no ad SDK.
	Defaults.set_object_for_key(_now(), END_ARC_DATE)
	Defaults.synchronize()
	Nav.back()


# -- helpers --------------------------------------------------------------------------

func _on_blocker_input(event: InputEvent, v: Control) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			touches_began(v.get_global_transform() * mb.position)


func _set_label(l: Label, text: String) -> void:
	if l != null:
		l.text = text


func _tex(art: String) -> Texture2D:
	return Assets.texture(art)


## PrizeManager getPrizeImage: answers a UIImage; accept whatever form the
## port's PrizeManager hands back (texture, image, or image file name).
func _prize_texture(img: Variant) -> Texture2D:
	if img is Texture2D:
		return img
	if img is Image:
		return ImageTexture.create_from_image(img)
	if img is String and img != "":
		var s: String = img
		if not Assets.has_image(s) and Assets.has_image(s + ".png"):
			s += ".png"
		return Assets.texture(s)
	return null


## adjustsFontSizeToFitWidth with minimumFontSize 6.
func _fit_font_size(font: Font, text: String, width: float) -> int:
	var s := PRIZE_NAME_FONT
	while s > PRIZE_NAME_MIN_FONT \
			and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, s).x > width:
		s -= 1
	return s


## NSDate for the arc-time defaults. PORT CHOICE: stored as Unix seconds.
func _now() -> float:
	return Time.get_unix_time_from_system()


## rand(): 0..RAND_MAX (2^31 - 1).
func _rand() -> int:
	return randi() & 0x7FFFFFFF


## performSelector:withObject:afterDelay: -- never cancelled by this class.
func _perform_after(delay: float, method: StringName, arg: Variant = null) -> void:
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = delay
	add_child(t)
	t.timeout.connect(_fire.bind(t, method, arg))
	t.start()


func _fire(t: Timer, method: StringName, arg: Variant) -> void:
	t.queue_free()
	if arg == null:
		call(method)
	else:
		call(method, arg)


## scheduledTimerWithTimeInterval:...repeats:YES; first fire after `interval`.
func _schedule_timer(interval: float, method: StringName, arg: Variant = null) -> Timer:
	var t := Timer.new()
	t.one_shot = false
	t.wait_time = interval
	add_child(t)
	if arg == null:
		t.timeout.connect(Callable(self, method))
	else:
		t.timeout.connect(Callable(self, method).bind(arg))
	t.start()
	return t


func _invalidate(t: Timer) -> void:
	if t != null and is_instance_valid(t):
		t.stop()
		t.queue_free()
