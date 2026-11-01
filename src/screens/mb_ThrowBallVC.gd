# Milk Bottle midway game -- throw a baseball at a pyramid of six milk cans.
#
# Read from mb_ThrowBallVC in the original binary (constants, doubles and the
# ScaleBall duration checked against the instructions):
#   initWithNibName:bundle: 0x165230   viewDidLoad 0x16573C
#   viewWillAppear: 0x165C30           backClick: 0x165DE4
#   coinsClick: 0x165F6C               morePlayClick: 0x16604C
#   myToysClick: 0x1660D8              initBallZoomLevel 0x1661F0
#   detectCollision 0x16623C           startGame 0x166324
#   setBallZoomLevel 0x166498          resetBall 0x166588
#   showBall 0x1666BC                  buyBalls 0x166904
#   reset 0x166BA0                     showBalloons 0x166BC0
#   resetBottles 0x166EC8              displayStartMsg 0x166F9C
#   endThrowBreakedBottles:currentBreakedBottles: 0x166FC8
#   showPrizeView 0x167254             enableButton: 0x167984
#   closePrizeDialog: 0x167998         setPlayCount: 0x167A18
#   slideView:toPoint:overDuration: 0x167AE0
#   coinValueChanged: 0x167B8C         animationDidStart: 0x167C24
#   animationDidStop:finished:context: 0x167C78
#   showBuyMoreCoinsMessage 0x167CC8   alertView:didDismissWithButtonIndex: 0x167D10
#   touchesBegan:withEvent: 0x167F68   touchesEnded:withEvent: 0x168204
#   getImageArray:colums:rows:imgWidth:imgHeight: 0x1655C8, cropingImage:img: 0x1656DC
# The bottles are src/midway/mb_BottleBaseView.gd.
#
# The game, as the code plays it:
#   * Tap "TAP TO START" (instIV's frame) with plays left: one play is spent
#     and you get 3 balls. With none left: "You are out of plays. Would you
#     like to buy more?" Cancel / Buy (5 coins -> NUM_OF_PLAYS plays).
#   * Touch the ball and release anywhere above its top edge. Speed = distance
#     from the ball centre to the release point / time held, clamped to
#     [500, 3000]. The ball flies a quadratic arc for 0.4 s (always: the
#     duration is (v/10)/(v/4)) to (cx + tan(a)*(v/10 + 480 - cy), 310 - v/10),
#     spinning through 15 sprite frames in 0.3 s and shrinking to 0.8..0.3 by
#     how high it lands. Whatever a ball-sized rect at the landing point
#     overlaps is knocked down (see the bottle file for which cans each hit
#     takes with it). Then the ball snaps back and slides in from the right.
#   * All six down within 3 balls: prize popup with a random MilkBottle prize
#     (unlocked), balloons and stars rise, cheer + fanfare. Otherwise "aww".
#
# Not ported: DataLogging (analytics), the interstitial ad on back
# (FF_KEY_EVERYTHING is on in the port), the iPad flag (ipad2x is set and
# never read). No particles on this screen.
#
# STATE UNDER A PUSH: coinsClick:, myToysClick: and the
# Get Coins alert push over this controller and UINavigationController keeps
# it alive, so Nav keeps this instance (keeps_state_on_push) and on_resume()
# re-runs viewWillAppear: (0x165C30). The class has no viewDidAppear: and no
# viewWillDisappear:/viewDidDisappear:. An earlier static _resume snapshot is
# gone; the game itself survives.

extends "res://core/Screen.gd"
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const BottleBaseView := preload("res://midway/mb_BottleBaseView.gd")
const Anim := preload("res://midway/mb_Anim.gd")

# -- defaults keys --------------------------------------------------------
const PLAY_COUNT_KEY := "MilkBottlePlayCountKey"
const UNIQUE_KEY := "uniqueBottle"
const DATE_ARC_FLAG := "dateArcFlag"
const START_ARC_DATE := "startArcDate"
const END_ARC_DATE := "endArcDate"
const PLAYED_ARC_FLAG := "playedArcFlag"
const EVERYTHING_KEY := "FF_KEY_EVERYTHING"

## initWithNibName: NUM_OF_PLAYS = IAPlist GameData.MilkBottlePurchase, 3 when
## that is 0. The IAPlist is the (dead) server table, so 3.
const NUM_OF_PLAYS_FALLBACK := 3
## buyBalls 0x166904: needs totalCoins > 4, spends 5.
const PLAYS_COST := 5
## startGame 0x166324: chanceCount = 3.
const CHANCES_PER_GAME := 3

## initWithNibName: 13 UIImageViews, frame 80x80, contentMode 1 (aspect fit),
## parked at centre (-999, -999), added to the view after viewDidLoad.
const BALLOON_IMAGES := [
	"circus_ballbubble.png", "circus_clownbubble.png", "circus_greenbubble.png",
	"circus_pinkbubble.png", "circus_yellowbubble.png", "circus_yellowbubble.png",
	"circus_pinkbubble.png", "circus_greenbubble.png",
	"Star_Emitters_End_Game_PS_1.png", "Star_Emitters_End_Game_PS_2.png",
	"Star_Emitters_End_Game_PS_3.png", "Star_Emitters_End_Game_PS_4.png",
	"Star_Emitters_End_Game_PS_5.png",
]
const BALLOON_BOX := 80.0
const BALLOON_PARK := Vector2(-999, -999)
## showBalloons 0x166BC0 (rand moduli and constants from the disassembly):
## start centre (rand%200 + 60, rand%50 + 520); animate, curve 1 (ease-in),
## over rand%100/100 + 1.5 s, to (x + 2*(x - 160), y - 650).
const BALLOON_X_SPAN := 200
const BALLOON_X_MIN := 60
const BALLOON_Y_SPAN := 50
const BALLOON_Y_MIN := 520
const BALLOON_PIVOT_X := 160.0
const BALLOON_RISE := 650.0
const BALLOON_BASE_SECONDS := 1.5

## viewDidLoad: bottleBaseObj = initWithBaseImage:"can1.png", then its frame
## moved down by 10.
const CAN_IMAGE := "can1.png"
const BOTTLE_BASE_DROP := 10.0

## Nib geometry: ballIV / ball2IV (135,425,50,50), contentMode center;
## instIV (60,225,200,100).
const BALL_FRAME := Rect2(135, 425, 50, 50)
const INST_FRAME := Rect2(60, 225, 200, 100)
const BALL_IMAGE := "fb_1.png"

## viewDidLoad: animationImages = getImageArray:"mb_ballSprite.png" colums:5
## rows:3 imgWidth:50 imgHeight:50. The loop sets the row origin to imgHeight
## (not += imgHeight) at each wrap, so rows 2 and 3 both crop y = 50: frames
## 10-14 repeat 5-9. Kept.
const BALL_SPRITE := "mb_ballSprite.png"
const BALL_SPRITE_COLS := 5
const BALL_SPRITE_ROWS := 3
const BALL_SPRITE_CELL := 50

## initBallZoomLevel 0x1661F0.
const BALL_ZOOMING_SCALE := [0.8, 0.7, 0.6, 0.5, 0.4, 0.3]

## showBall 0x1666BC: both balls jump 500 right, then slideView: back over
## 0.25 s, curve 3 (linear).
const BALL_SLIDE_OFFSET := 500.0
const BALL_SLIDE_SECONDS := 0.25

## performSelector:afterDelay: doubles (the hi word alone decodes as a
## meaningless float): reset 0x3FB999999999999A = 0.1,
## displayStartMsg 0x3FC999999999999A = 0.2, enableButton: 0x3FE6666666666666 = 0.7.
const RESET_DELAY := 0.1
const START_MSG_DELAY := 0.2
const ENABLE_BUTTON_DELAY := 0.7

## touchesEnded: 0x168204 (floats at 0x16860C..0x16861C, 0x1686E6).
## applicationFrame is (0,0,320,480) -- Info.plist UIStatusBarHidden = YES --
## so the /320 and /480 scale factors are 1 and drop out.
const SPEED_MIN := 500.0
const SPEED_MAX := 3000.0
const SPEED_TO_HEIGHT := 10.0       # v / 10
const SPEED_TO_TIME := 0.25         # duration = (v/10) / (v*0.25) = 0.4 s
const SCREEN_BOTTOM := 480.0
const CTRL_Y_BASE := 210.0
const END_Y_BASE := 310.0
const SPRITE_TIME_TRIM := 0.1       # image animation = duration - 0.1 if > 0

## setBallZoomLevel 0x166498: landing y bands -> ballZoomingScale index.
const ZOOM_BANDS := [300.0, 240.0, 180.0, 120.0, 60.0]

## showPrizeView 0x167254.
const PRIZE_TAG := 1000000
const PRIZE_POPUP := "prize_popup.png"
const PRIZE_CENTER := Vector2(160, 240)
const PRIZE_CLOSE_ART := "daily_login_btn.png"
const PRIZE_CLOSE_SIZE := Vector2(94, 63)
const PRIZE_CLOSE_CENTER := Vector2(160, 400)
const PRIZE_LABEL_ART := "prize_label.png"
const PRIZE_LABEL_CENTER := Vector2(160, 355)
const PRIZE_NAME_SIZE := Vector2(74, 14)
const PRIZE_NAME_Y := 16.0          # centre (labelIV.width/2, 16)
const PRIZE_NAME_FONT := 12
const PRIZE_NAME_MIN_FONT := 6
const PRIZE_POP_FROM := 0.01
const PRIZE_POP_SECONDS := 0.5      # curve 3 (linear)
## UILabel's default font on iOS 6 is Helvetica; fontWithName:[font fontName].
const FONT_NAMES := ["Helvetica", "Helvetica Neue", "Nimbus Sans", "Liberation Sans", "Arial"]

## myToysClick: 0x1660D8.
const PRIZE_GAME := "MilkBottle"
const PRIZE_BACKGROUND := "mb_prize_bg.png"

const OUT_OF_PLAYS := "You are out of plays. Would you like to buy more?"
## -[IAPlistManager displayMediaBrixForLocation:withMiniGame:] 0x1757E0, the
## "MiniGame" branch (delegate = IAPlistManager, whose
## alertView:clickedButtonAtIndex: 0x176C44 plays "store" and pushes the coin
## store on "Get Coins").
const NOT_ENOUGH_COINS := "You do not have enough coins. Would you like to buy more?"

var _view: Node2D
var _ball: Sprite2D
var _ball2: Sprite2D
var _inst: CanvasItem
var _back_btn: Control
var _coin_label: Label
var _ball_count_label: Label
var _play_count_label: Label

var _bottle_base: BottleBaseView
var _balloons: Array[Sprite2D] = []
var _ball_frames: Array[Texture2D] = []
var _ball_texture: Texture2D

var _num_of_plays := NUM_OF_PLAYS_FALLBACK
var _play_count := 0
var _chance_count := 0
var _ball_zoom_level := 0
var _original_ball_center := Vector2.ZERO
var _end_points_of_ball := Vector2.ZERO
var _toss_time := -1.0                 # tossDate; < 0 is nil
var _is_ball_in_air := false
var _action_performed := false
var _game_started := false
var _is_collision_detect := false

## ballIV's model transform scale (the hit test reads the model frame).
var _ball_model_scale := 1.0
var _ball_tween: Tween                  # "MoveBall" + "ScaleBall"
var _ball_slide: Tween
var _ball2_slide: Tween
## UIImageView startAnimating: wall-clock start, < 0 when not animating.
var _sprite_start := -1.0
var _sprite_duration := 0.0
var _pending_resets := 0

var _prize_view: Node2D                 # the tag-1000000 container


## The original controller has no changeInstruction: -- instIV is
## shown and hidden in place, never slid in.
func _place_instruction() -> void:
	pass


func on_enter() -> void:
	_view = outlet("view") as Node2D
	_ball = outlet("ballIV") as Sprite2D
	_ball2 = outlet("ball2IV") as Sprite2D
	_inst = outlet("instIV") as CanvasItem
	_back_btn = outlet("backBtn") as Control
	_coin_label = outlet("coinLabel") as Label
	_ball_count_label = outlet("ballCountLabel") as Label
	_play_count_label = outlet("playCountLabel") as Label
	_ball_texture = _load_texture(BALL_IMAGE)
	# contentMode center: the 50x50 art sits centred in the 50x50 frame; centre
	# the sprites so the ball's transform scales about its centre as on iOS.
	for b in [_ball, _ball2]:
		(b as Sprite2D).centered = true
		(b as Sprite2D).position = BALL_FRAME.get_center()

	_original_ball_center = BALL_FRAME.get_center()
	_ball_frames = _get_image_array(BALL_SPRITE, BALL_SPRITE_COLS, BALL_SPRITE_ROWS,
		BALL_SPRITE_CELL, BALL_SPRITE_CELL)

	# initWithNibName: -- before the view loads.
	_play_count = Defaults.integer_for_key(PLAY_COUNT_KEY)
	_num_of_plays = NUM_OF_PLAYS_FALLBACK

	_view_did_load()
	_build_balloons()            # init's loop, after viewDidLoad
	_view_will_appear()


## See the header's STATE UNDER A PUSH (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back on top: viewWillAppear: (0x165C30) -- coin label, then ballIV,
## backBtn and instIV brought to the front.
func on_resume() -> void:
	_view_will_appear()


## No viewWillDisappear:/viewDidDisappear: in this class; the base on_exit
## (nothing) stands, so nothing stops while a pushed screen covers it.


# -- view lifecycle ------------------------------------------------------

## viewDidLoad 0x16573C.
func _view_did_load() -> void:
	if not Defaults.bool_for_key(UNIQUE_KEY):
		# +[DataLogging uniqueVisits] -- analytics, not ported.
		Defaults.set_bool_for_key(true, UNIQUE_KEY)
		Defaults.synchronize()
	if Defaults.integer_for_key(DATE_ARC_FLAG) == 0:
		# PORT CHOICE: NSDate stored as Unix seconds.
		Defaults.set_object_for_key(Time.get_unix_time_from_system(), START_ARC_DATE)
		Defaults.set_integer_for_key(1, DATE_ARC_FLAG)
		Defaults.synchronize()
	# +[DataLogging totalStartedArc], LogBoothClick:withType: -- not ported.
	_build_bottle_base()
	_ball_count_label.text = "0"
	# initBallZoomLevel: BALL_ZOOMING_SCALE.
	_inst.visible = true
	_ball.visible = false
	_original_ball_center = _ball.position
	# setAnimationImages: (built in on_enter) -- the 15 crops.
	_ball.visible = false
	_set_play_count(_play_count)
	_coin_label.text = "%d" % CoinManager.total_coins()
	_reset_bottles()


func _build_bottle_base() -> void:
	_bottle_base = BottleBaseView.new()
	_bottle_base.name = "bottleBaseObj"
	_bottle_base.init_with_base_image(CAN_IMAGE)
	_bottle_base.delegate = self
	_view.add_child(_bottle_base)
	# setFrame: (x, y + 10, w, h) of its own (zero) frame.
	_bottle_base.position = Vector2(0, BOTTLE_BASE_DROP)


func _build_balloons() -> void:
	for image_name: String in BALLOON_IMAGES:
		var s := Sprite2D.new()
		s.name = "balloon"
		var tex := _load_texture(image_name)
		s.texture = tex
		s.centered = true
		if tex != null:
			var k := minf(BALLOON_BOX / tex.get_width(), BALLOON_BOX / tex.get_height())
			s.scale = Vector2(k, k)
		s.position = BALLOON_PARK
		_view.add_child(s)
		_balloons.append(s)


## viewWillAppear: 0x165C30.
func _view_will_appear() -> void:
	_coin_label.text = "%d" % CoinManager.total_coins()
	_view.move_child(_ball, -1)
	_view.move_child(_back_btn, -1)
	_view.move_child(_inst as Node, -1)


## getImageArray:colums:rows:imgWidth:imgHeight: 0x1655C8 with its row bug.
func _get_image_array(image_name: String, cols: int, rows: int, w: int, h: int) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	var sheet := _load_texture(image_name)
	if sheet == null:
		return out
	var col := 0
	var y := 0
	for n in cols * rows:
		var at := AtlasTexture.new()
		at.atlas = sheet
		at.region = Rect2(col * w, y, w, h)
		out.append(at)
		col += 1
		if col == cols:
			y = h
			col = 0
	return out


func _load_texture(image_name: String) -> Texture2D:
	return Assets.texture(image_name)


# -- buttons ------------------------------------------------------------

## backClick: 0x165DE4.
func _on_backClick() -> void:
	Defaults.set_object_for_key(Time.get_unix_time_from_system(), END_ARC_DATE)
	Defaults.synchronize()
	# +[DataLogging arcTime] -- not ported.
	CoinManager.sync_coins(true)
	Audio.play("button_press")
	if not Defaults.bool_for_key(EVERYTHING_KEY):
		pass   # displayAdForLocation:"Interstitial" -- an ad, not ported.
	Nav.back()


## coinsClick: 0x165F6C.
func _on_coinsClick() -> void:
	Audio.play("store")
	# +[DataLogging LogStoreNavigationCarnival:withSink:] -- not ported.
	_push_child("CoinStoreViewController")


## morePlayClick: 0x16604C.
func _on_morePlayClick() -> void:
	Audio.play("button_press")
	if not _is_ball_in_air and _buy_balls():
		_reset_ball()


## myToysClick: 0x1660D8.
func _on_myToysClick() -> void:
	Audio.play("trophy_door")
	GameState.screen_args["PrizeViewController"] = {
		"prizes": PrizeManager.get_prizes_for_game(PRIZE_GAME),
		"background_file": PRIZE_BACKGROUND,
	}
	_push_child("PrizeViewController")


## coinsClick:/myToysClick:/Get Coins: pushViewController:animated:.
## INFERRED: nothing guards these against a throw in flight. UIKit ends a
## covered view's animations and still sends their stop messages, so the
## throw resolves -- "ScaleBall" stop (showAnimation), then each falling can's
## "Rotate_Bottle" stop (the first reports endThrow...) -- rather than waiting,
## as the port's paused tweens would, for the return.
func _push_child(screen: String) -> void:
	_finish_throw_in_flight()
	Nav.push(screen)


func _finish_throw_in_flight() -> void:
	if _ball_tween != null and _ball_tween.is_valid():
		_ball_tween.kill()
		_ball.scale = Vector2(_ball_model_scale, _ball_model_scale)
		_ball.position = _end_points_of_ball      # MoveBall fills forwards
		_scale_ball_did_stop()
	_bottle_base.finish_falls()


# -- game state ---------------------------------------------------------

## setPlayCount: 0x167A18.
func _set_play_count(n: int) -> void:
	_play_count = n
	Defaults.set_integer_for_key(_play_count, PLAY_COUNT_KEY)
	Defaults.synchronize()
	_play_count_label.text = "%d" % _play_count


## startGame 0x166324.
func _start_game() -> void:
	_set_play_count(_play_count - 1)
	_chance_count = CHANCES_PER_GAME
	_ball_count_label.text = "%d" % _chance_count
	_log_arc_end()
	# +[DataLogging LogCarnivalStart:withType:] -- not ported.


## The block several methods repeat: stamp endArcDate when dateArcFlag >= 1.
func _log_arc_end() -> void:
	if Defaults.integer_for_key(DATE_ARC_FLAG) >= 1:
		Defaults.set_object_for_key(Time.get_unix_time_from_system(), END_ARC_DATE)
		Defaults.synchronize()
		# +[DataLogging arcTime] -- not ported.


## buyBalls 0x166904.
func _buy_balls() -> bool:
	if CoinManager.total_coins() > PLAYS_COST - 1:
		_log_arc_end()
		if Defaults.integer_for_key(PLAYED_ARC_FLAG) == 0:
			# +[DataLogging playedArcGms] -- not ported.
			Defaults.set_integer_for_key(1, PLAYED_ARC_FLAG)
			Defaults.synchronize()
		# +[DataLogging LogSink:...] -- not ported.
		CoinManager.spend_coins(PLAYS_COST)
		_set_play_count(_play_count + _num_of_plays)
		_coin_label.text = "%d" % CoinManager.total_coins()
		return true
	_show_buy_more_coins_message()
	return false


## showBuyMoreCoinsMessage 0x167CC8 -> displayMediaBrixForLocation:"MiniGame"
## withMiniGame:"Milk Bottle". The whole method is gated on the server
## IAPlist's "Advertising" entry; with the server gone it does nothing.
## PORT CHOICE (as core/Consumable.gd does for the food screens): show the
## alert its no-ad branch shows, so the player is told why nothing happened.
func _show_buy_more_coins_message() -> void:
	var clicked := func(choice: String) -> void:
		if choice == "Get Coins":
			Audio.play("store")
			_push_child("CoinStoreViewController")
	show_alert(NOT_ENOUGH_COINS, ["Cancel", "Get Coins"], clicked, false)


## alertView:didDismissWithButtonIndex: 0x167D10: button_press for every
## title but "Get Coins" (the alert itself is silent: show_alert(.., false)).
func _alert_did_dismiss(title: String) -> void:
	if title != "Get Coins":
		Audio.play("button_press")
	match title:
		"OK":
			_inst.visible = true
		"Buy":
			if _buy_balls():
				_reset_ball()
		"Get Coins":
			_push_child("CoinStoreViewController")
		"Yes":
			if _inst.visible:
				_inst.visible = false
			_game_started = true
			_start_game()
		_:
			pass


## reset 0x166BA0, via performSelector:afterDelay:.
func _reset() -> void:
	_pending_resets -= 1
	_bottle_base.reset_view()


## resetBottles 0x166EC8.
func _reset_bottles() -> void:
	_ball_count_label.text = "%d" % _chance_count
	_ball.visible = true
	_show_ball()
	_pending_resets += 1
	get_tree().create_timer(RESET_DELAY).timeout.connect(_reset)


## displayStartMsg 0x166F9C.
func _display_start_msg() -> void:
	_inst.visible = true


# -- the ball -----------------------------------------------------------

## resetBall 0x166588: both balls back to the original centre, identity
## transform, every layer animation removed.
func _reset_ball() -> void:
	_kill(_ball_tween)
	_kill(_ball_slide)
	_kill(_ball2_slide)
	_ball_tween = null
	_ball.position = _original_ball_center
	_ball.scale = Vector2.ONE
	_ball_model_scale = 1.0
	_ball2.position = _original_ball_center
	_ball2.scale = Vector2.ONE
	_stop_sprite()
	_is_ball_in_air = false


## showBall 0x1666BC.
func _show_ball() -> void:
	_kill(_ball_slide)
	_kill(_ball2_slide)
	_ball.position = _original_ball_center + Vector2(BALL_SLIDE_OFFSET, 0)
	_ball2.position = _original_ball_center + Vector2(BALL_SLIDE_OFFSET, 0)
	_ball_slide = _slide_view(_ball, _original_ball_center, BALL_SLIDE_SECONDS)
	_ball2_slide = _slide_view(_ball2, _original_ball_center, BALL_SLIDE_SECONDS)


## slideView:toPoint:overDuration: 0x167AE0 -- curve 3 (linear).
func _slide_view(node: Node2D, to: Vector2, seconds: float) -> Tween:
	var tw := node.create_tween()
	tw.tween_property(node, "position", to, seconds)
	return tw


func _kill(tw: Tween) -> void:
	if tw != null and tw.is_valid():
		tw.kill()


## ballIV.frame from model values: the centre is always the original (every
## slide ends there and MoveBall never changes the model), scaled by the
## model transform.
func _ball_frame() -> Rect2:
	var size := BALL_FRAME.size * _ball_model_scale
	return Rect2(_original_ball_center - size * 0.5, size)


## setBallZoomLevel 0x166498.
func _set_ball_zoom_level() -> void:
	var y := _end_points_of_ball.y
	if y >= ZOOM_BANDS[0]:
		_ball_zoom_level = 0
	elif y > ZOOM_BANDS[1]:
		_ball_zoom_level = 1
	elif y > ZOOM_BANDS[2]:
		_ball_zoom_level = 2
	elif y > ZOOM_BANDS[3]:
		_ball_zoom_level = 3
	elif y > ZOOM_BANDS[4]:
		_ball_zoom_level = 4
	else:
		_ball_zoom_level = 5


## detectCollision 0x16623C: a ball-frame-sized rect, scaled by the landing
## zoom, centred on the landing point.
func _detect_collision() -> bool:
	var s: float = BALL_ZOOMING_SCALE[_ball_zoom_level]
	var size := _ball_frame().size * s
	return _bottle_base.detect_collision_with_ball(
		Rect2(_end_points_of_ball - size * 0.5, size))


func _now() -> float:
	return Time.get_ticks_usec() / 1000000.0


# -- touches ------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		_touches_began(mb.position)
	else:
		_touches_ended(mb.position)


## touchesBegan:withEvent: 0x167F68.
func _touches_began(p: Vector2) -> void:
	if not _game_started and _prize_view == null and INST_FRAME.has_point(p):
		if _play_count < 1:
			show_alert(OUT_OF_PLAYS, ["Cancel", "Buy"], _alert_did_dismiss, false)
		else:
			if _inst.visible:
				_inst.visible = false
			_game_started = true
			_start_game()
		return
	if _ball_frame().has_point(p) and _prize_view == null:
		_toss_time = _now()


## touchesEnded:withEvent: 0x168204. There is no touchesMoved: -- only the
## release point and the hold time matter.
func _touches_ended(p: Vector2) -> void:
	if _toss_time >= 0.0:
		if p.y < _ball_frame().position.y and _chance_count >= 1:
			if _prize_view == null and not _is_ball_in_air:
				_throw(p, _now() - _toss_time)
	_toss_time = -1.0


func _throw(p: Vector2, held: float) -> void:
	var c := _original_ball_center
	var dx := absf(c.x - p.x)
	var dy := absf(c.y - p.y)
	var dist := sqrt(dy * dy + dx * dx)
	var angle := asin(dx / dist)
	if p.x < c.x:
		angle = -angle
	var speed := dist / held if held > 0.0 else INF
	var v := SPEED_MIN
	if speed >= SPEED_MIN:
		v = minf(speed, SPEED_MAX)
	var height := v / SPEED_TO_HEIGHT
	var duration := height / (v * SPEED_TO_TIME)
	var reach := tan(angle) * (height + (SCREEN_BOTTOM - c.y))
	var ctrl := Vector2(reach * 0.5 + c.x, CTRL_Y_BASE - height)
	_end_points_of_ball = Vector2(reach + c.x, END_Y_BASE - height)
	_set_ball_zoom_level()
	_is_collision_detect = _detect_collision()
	# Model reset; the presentation keeps sliding until MoveBall overrides it.
	_kill(_ball_slide)
	_ball.position = _original_ball_center
	_ball.scale = Vector2.ONE
	var start := _original_ball_center
	var sprite_seconds := duration
	if duration - SPRITE_TIME_TRIM > 0.0:
		sprite_seconds = duration - SPRITE_TIME_TRIM
	_action_performed = false          # set here, never read (as in the original)
	_start_sprite(sprite_seconds)

	var s: float = BALL_ZOOMING_SCALE[_ball_zoom_level]
	_ball_model_scale = s
	var end := _end_points_of_ball
	var tw := _ball.create_tween().set_parallel(true)
	# "ScaleBall": UIView block, curve 3 (linear), duration = the path's
	# (S20 at 0x1687DC), stop -> animationDidStop:finished:context:.
	tw.tween_property(_ball, "scale", Vector2(s, s), duration)
	# "MoveBall": CAKeyframeAnimation on position, kCAAnimationLinear,
	# MoveTo(centre) QuadCurveTo(ctrl, end), fill forwards, not removed.
	# INFERRED: linear calculation mode advances the curve parameter linearly
	# in time (not paced).
	tw.tween_method(func(u: float) -> void:
		_ball.position = Anim.quad(start, ctrl, end, u), 0.0, 1.0, duration)
	tw.chain().tween_callback(_scale_ball_did_stop)
	_ball_tween = tw
	_animation_did_start.call_deferred()
	Audio.play("toss")
	_is_ball_in_air = true


## animationDidStop:finished:context: 0x167C78 for "ScaleBall".
func _scale_ball_did_stop() -> void:
	_ball_tween = null
	_bottle_base.show_animation()


## animationDidStart: 0x167C24 -- MoveBall's CA delegate: half the time.
func _animation_did_start() -> void:
	if (randi() & 1) == 0:
		Audio.play("bounce_ppball1")


## UIImageView startAnimating with animationRepeatCount 1.
func _start_sprite(seconds: float) -> void:
	_sprite_start = _now()
	_sprite_duration = seconds
	if not _ball_frames.is_empty():
		_ball.texture = _ball_frames[0]


func _stop_sprite() -> void:
	_sprite_start = -1.0
	_ball.texture = _ball_texture


func _process(_delta: float) -> void:
	if _sprite_start < 0.0 or _ball_frames.is_empty():
		return
	var t := _now() - _sprite_start
	if t >= _sprite_duration:
		_stop_sprite()
		return
	var idx := int(t / (_sprite_duration / _ball_frames.size()))
	_ball.texture = _ball_frames[clampi(idx, 0, _ball_frames.size() - 1)]


# -- the throw's outcome ------------------------------------------------

## endThrowBreakedBottles:currentBreakedBottles: 0x166FC8 (the bottle view's
## delegate call).
func end_throw_breaked_bottles_current_breaked_bottles(total: int, current: int) -> void:
	_chance_count -= 1
	_reset_ball()
	if current == 1:
		if _is_collision_detect:
			Audio.play("Milk_bottle_fall")
	elif current >= 2 and current <= 6 and _is_collision_detect:
		Audio.play("Milk_bottles_fall")
	if total < 6:
		if _chance_count <= 0:
			Audio.play("aww")
			_ball.visible = false
			_inst.visible = false
			_game_started = false
			_inst.visible = true
			_reset_bottles()
		else:
			_show_ball()
	else:
		_ball.visible = false
		get_tree().create_timer(START_MSG_DELAY).timeout.connect(_display_start_msg)
		_chance_count = 0
		_game_started = false
		_show_prize_view()
		_show_balloons()
	_ball_count_label.text = "%d" % _chance_count


## showBalloons 0x166BC0.
func _show_balloons() -> void:
	for b in _balloons:
		var x := float(int(randi() % BALLOON_X_SPAN) + BALLOON_X_MIN)
		var y := float(int(randi() % BALLOON_Y_SPAN) + BALLOON_Y_MIN)
		var from := Vector2(x, y)
		b.position = from
		_view.move_child(b, -1)
		var seconds := float(randi() % 100) / 100.0 + BALLOON_BASE_SECONDS
		var to := Vector2(x + 2.0 * (x - BALLOON_PIVOT_X), y - BALLOON_RISE)
		# A new "Fall" block on centre replaces any still-running one.
		if b.has_meta("fall"):
			_kill(b.get_meta("fall"))
		var tw := b.create_tween()
		tw.tween_method(func(u: float) -> void:
			b.position = from.lerp(to, Anim.curve(u, Anim.CURVE_EASE_IN)), 0.0, 1.0, seconds)
		b.set_meta("fall", tw)
	Audio.play("cheer")


## showPrizeView 0x167254.
func _show_prize_view() -> void:
	var dialog := Node2D.new()
	dialog.name = "PrizeDialog"
	dialog.set_meta("tag", PRIZE_TAG)
	_view.add_child(dialog)
	_prize_view = dialog

	# The container is a plain 320x480 UIView: it takes every touch in its
	# bounds (hit-testing uses the model transform, already identity), so the
	# nib's buttons beneath are unreachable while it is up.
	var blocker := Control.new()
	blocker.size = Vector2(320, 480)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	dialog.add_child(blocker)

	# Everything else scales 0.01 -> 1 about the container's centre.
	var content := Node2D.new()
	content.position = PRIZE_CENTER
	dialog.add_child(content)

	var popup := Sprite2D.new()
	popup.texture = _load_texture(PRIZE_POPUP)
	popup.centered = false
	popup.position = -PRIZE_CENTER
	content.add_child(popup)

	var prize: Variant = PrizeManager.get_random_prize_game(true, PRIZE_GAME)
	PrizeManager.unlock_prize(prize)
	var prize_iv := Sprite2D.new()
	prize_iv.texture = _as_texture(PrizeManager.get_prize_image(prize))
	prize_iv.centered = true
	prize_iv.position = Vector2.ZERO   # centre (160, 240)
	content.add_child(prize_iv)

	var close := TextureButton.new()
	close.texture_normal = _load_texture(PRIZE_CLOSE_ART)
	close.ignore_texture_size = true
	close.stretch_mode = TextureButton.STRETCH_SCALE
	close.size = PRIZE_CLOSE_SIZE
	close.position = PRIZE_CLOSE_CENTER - PRIZE_CLOSE_SIZE * 0.5 - PRIZE_CENTER
	close.disabled = true       # setUserInteractionEnabled:NO
	close.pressed.connect(_close_prize_dialog.bind(dialog))
	content.add_child(close)
	get_tree().create_timer(ENABLE_BUTTON_DELAY).timeout.connect(_enable_button.bind(close))

	var label_iv := Sprite2D.new()
	label_iv.texture = _load_texture(PRIZE_LABEL_ART)
	label_iv.centered = true
	label_iv.position = PRIZE_LABEL_CENTER - PRIZE_CENTER
	content.add_child(label_iv)
	var label_size := label_iv.texture.get_size() if label_iv.texture != null else Vector2.ZERO
	var name_label := Label.new()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UILabelFrame.set_frame(name_label, Rect2(Vector2(label_size.x * 0.5, PRIZE_NAME_Y)
		- PRIZE_NAME_SIZE * 0.5 - label_size * 0.5, PRIZE_NAME_SIZE))
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_color_override("font_color", Color.BLACK)
	var font := SystemFont.new()
	font.font_names = PackedStringArray(FONT_NAMES)
	name_label.add_theme_font_override("font", font)
	var prize_name: Variant = PrizeManager.get_prize_name(prize)
	name_label.text = "" if prize_name == null else str(prize_name)
	# adjustsFontSizeToFitWidth, minimumFontSize 6.
	var fs := PRIZE_NAME_FONT
	while fs > PRIZE_NAME_MIN_FONT and font.get_string_size(name_label.text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > PRIZE_NAME_SIZE.x:
		fs -= 1
	name_label.add_theme_font_size_override("font_size", fs)
	name_label.clip_text = true
	label_iv.add_child(name_label)

	content.scale = Vector2(PRIZE_POP_FROM, PRIZE_POP_FROM)
	content.create_tween().tween_property(content, "scale", Vector2.ONE, PRIZE_POP_SECONDS)
	_log_arc_end()
	# +[DataLogging nbrToysWon], LogCarnivalWin:withType: -- not ported.
	Audio.play("fanfare")


## getPrizeImage: answers a UIImage; accept whatever the PrizeManager port
## hands back (texture, image, or an image file name).
func _as_texture(v: Variant) -> Texture2D:
	if v is Texture2D:
		return v
	if v is Image:
		return ImageTexture.create_from_image(v)
	if v is String and v != "":
		return Assets.texture(v)
	return null


## enableButton: 0x167984.
func _enable_button(b: TextureButton) -> void:
	if is_instance_valid(b):
		b.disabled = false


## closePrizeDialog: 0x167998.
func _close_prize_dialog(dialog: Node2D) -> void:
	Audio.play("button_press")
	_reset_bottles()
	if is_instance_valid(dialog):
		dialog.queue_free()
	if _prize_view == dialog:
		_prize_view = null
