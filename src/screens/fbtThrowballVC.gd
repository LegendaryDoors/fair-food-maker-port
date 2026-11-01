# Football Toss -- the midway game behind stand tag 17. Port of fbtThrowballVC
# (77 methods) and its nib, read from the original v1.27 binary. Every number
# below cites where it came from.
#
# THE GAME
#   init        0x23120  playCount = defaults FootballTossPlayCountKey;
#                        numOfPlays = server GameData.FootballTossNumberOfPlays
#                        (3 when absent/0); morePlaysCost = GameData.
#                        FootballTossMorePlaysCost (5 when absent); the gun
#                        Consumable (below); 13 balloon views 80x80 aspect-fit
#                        parked at (-999,-999) -- added *after* viewDidLoad ran
#                        (the first [self view] in the loop loads the nib), so
#                        they sit above the gun badge.
#   viewDidLoad 0x23660  ballCountLabel "0"; instIV shown; ballIV hidden;
#                        originalBallCenter = ballIV.center; ball animation
#                        frames football_1..5; labels; showBall; the gun badge
#                        at centre (50,350.5), hidden.
#   viewWillAppear: 0x23D8C  coin label; ballIV, gun, backBtn, instIV to front.
#   touchesBegan 0x26764 (gun hidden):
#     - not started, no prize dialog, touch in instIV.frame: playCount < 1 ->
#       alert "You are out of plays. Would you like to buy more?" Cancel/Buy;
#       else instIV hidden, gameStarted, startGame, badge shown.
#     - otherwise, touch in ballIV.frame and no dialog: tossDate = now,
#       lastFootballGrabLocation = touch.
#   touchesEnded 0x26B08 (gun hidden): a throw needs tossDate, grab.y != 0,
#     grab.y - end.y > 28, chanceCount >= 1, no dialog, ball not in air.
#     d = |ballCentre - end|, angle = asin(d.x / |d|), negative when the
#     release is left of the ball; speed = |d| / (now - tossDate) clamped to
#     [500, 3000]; h = speed / 10; duration = h / (speed * 0.25) (= 0.4 s);
#     off = tan(angle) * (h + 480 - ball.y); end = (ball.x + off, 310 - h);
#     path = quad curve start -> (ball.x + off/2, 210 - h) -> end (CAKeyframe
#     "MoveBall", linear). Zoom level from end.y, collision = end in one of
#     the three hole colliders. Ball frames over duration - 0.1 s, once;
#     "ScaleBall" UIView animation (linear, duration) to the zoom scale,
#     didStop -> animationDidStop:; "toss"; isBallInAir.
#     (The applicationFrame scale factors are 1: UIStatusBarHidden is YES.)
#   setBallZoomLevel 0x246D8  y >= 300 -> 0.8, (240,300) -> 0.7, (180,240] ->
#                        0.6, (120,180] -> 0.5, (60,120] -> 0.4, else 0.3.
#   detectCollision 0x24428  holeCollider1/2/3 frames (nib) contain end.
#   animationDidStop: 0x25CF0 ("ScaleBall"): centre = end, then
#     hit:  ball sent to the back (behind the field art, seen only through
#           the hole), animateWithDuration 0.3 (option 1 -> default ease-in-
#           out): centre.y + 200, alpha 0 (sub_26000); completion sub_26084:
#           displayStartMsg after 0.2 s, chanceCount 0, not started, label
#           "0", resetBall, showPrizeView, showBalloons, endGame.
#     miss: ball re-inserted below the foreground, image football_fail_1|2
#           (arc4random & 1), animateWithDuration 0.6: centre + (end.x -
#           originalCentre.x, 400), alpha 0, and a 1.5708 rad turn for fail_2
#           (sub_261AC); completion sub_262D4: chanceCount--, label,
#           resetBall, showBall, endGame when chanceCount <= 0.
#     then smoke stop, incorrectUseOfGun = NO.
#   resetBall 0x247C8  football_start, original centre, identity, alpha 1,
#                        ball and gun to front, removeAllAnimations, not in air.
#   showBall 0x24938   centre.x + 500, then slideView back over 0.25 s linear.
#   startGame 0x24540  playCount - 1, chanceCount 3, ball shown.
#   endGame 0x26394    not started, instIV shown, label "0", ball hidden,
#                        resetBall, hideGun, badge hidden.
#   showPrizeView 0x24EAC  hole 1/2/3 -> getRandomPrizeByCategory:YES game:
#                        "FootballToss" Categoried: "Small"/"Medium"/"Large";
#                        nil (or no hole) -> getRandomPrize:YES game:; unlock;
#                        the dialog (midway/fbt_prize_dialog.gd); "fanfare".
#   showBalloons 0x257D8  each balloon at (60+rand%200, 520+rand%50), to front,
#                        ease-in 1.5+(rand%100)/100 s to (3x-320, y-650); "cheer".
#   buyBalls 0x24A70   coins >= cost: spendCoins, playCount += numOfPlays; else
#                        "You do not have enough coins. Would you like to buy
#                        more?" Cancel / Get Coins.
#   morePlayClick: 0x24238  button_press; if not in air and buyBalls: resetBall.
#   alertView:didDismissWithButtonIndex: 0x2650C  button_press unless "Get
#                        Coins"; Buy -> buyBalls -> resetBall; Get Coins -> push
#                        the coin store. ("OK" and "Yes" branches exist but no
#                        alert of this class offers those titles.)
#   backClick: 0x23FD0  syncCoins, button_press, (interstitial ad), pop.
#   coinsClick: 0x24158 "store", push CoinStoreViewController.
#   myToysClick: 0x242C4 "trophy_door", PrizeViewController with prizes =
#                        getPrizesForGame:"FootballToss", background
#                        mb_prize_bg.png.
#   coinValueChanged: 0x25C54  coin label from the notification.
#
# FOOTBALL GUN (coin consumable DM_CONSUMABLE_FOOTBALL_GUN, "Gun", cost =
# server CoinCosts."Football Toss".FootballGun, 11 when < 1; quantity 0 at
# init; first-time message "Try out the Football Gun! Better accuracy! Try it
# for FREE now!"). Badge: ConsumableButton(btn_IAP_background, btn_IAP_mask,
# football_gun_upgrade.png, btn_IAP_border, btn_IAP_lable, (0,-25), cost,
# (65,3)), centre (50,350.5), target buyClick: ("store", purchaseConsumable).
#   consumablePurchased: 0x276CC  quantity 1, showGun (balls plate ->
#     btn_play_minigame_fbshots.png, gun shown), badge hidden.
#   With the gun shown, touchesBegan sets incorrectUseOfGun = touch in
#   ballIV.frame and no dialog; touchesEnded (if not incorrectUseOfGun):
#   incorrectUseOfGun = YES, end = the touch itself, zoom, collision, ball to
#   its original centre, "ScaleBall" 0.3 s linear to the zoom scale AND to
#   end, smoke start -> the same animationDidStop:. No chance or in-air check.
#
# The gun view (FootballGun_Start) ships UIHidden = YES in the nib, and only
# showGun (consumablePurchased:) unhides it; hideGun (endGame) hides it again.
# So on entry there is no gun and taps outside "Tap to start" do nothing.
# (Corrected: this header used to describe a "gun mode on entry" quirk; the
# nib was read with NIBArchive's bool tags swapped, so every UIHidden decoded
# NO. The generated scene now hides the gun; nothing here had to change in
# code, since the port never forced it visible.)
#
# Particles: `smoke` (SSEmitter, nib (145,280,30,30), FootballGun_FX_1..3,
# interval 0.05, duration 1, repeat NO, scale 0.5 -> 1, alpha 1 -> 0, end
# variance 50x50) is configured in viewDidLoad
# (call 0x23D80), started right after the gun's "ScaleBall" commit in
# touchesEnded: (0x26B08) and stopped at the end of animationDidStop:finished:
# context: (0x25CF0). Wired through core/particles.
#
# STATE UNDER A PUSH: coinsClick:, myToysClick: and the alert's Get
# Coins push over this controller and UINavigationController keeps it alive,
# so Nav keeps this instance (keeps_state_on_push) and on_resume() runs
# viewWillAppear: (0x23D8C) again. The class has no viewDidAppear: and no
# viewWillDisappear:/viewDidDisappear:. (An earlier park/restore through
# GameState.screen_args is gone; the instance itself survives.)
#
# PORT CHOICES
#  * INFERRED: a ball stage still animating when one of those pushes happens
#    is run to completion first (_push_away). UIKit ends a covered view's
#    animations and still runs their completions (finished = NO); out of the
#    tree the port's tweens would instead sit paused until the return.
#  * The not-enough-coins path of the gun badge shows Consumable's alert (the
#    original shows a MediaBrix ad), as on every ported consumable screen.
#  * DataLogging / Flurry / ad calls are analytics or ads and are left out;
#    the NSUserDefaults flags they gate (uniqueFBToss, dateArcFlag,
#    startArcDate, endArcDate, playedArcFlag, accelFlag) are still written.
#    NSDate values are stored as Unix seconds.
#  * A removed or replaced ball animation still runs its completion (UIKit
#    calls it with finished = NO); the port defers it to the next frame.

extends "res://core/Screen.gd"

const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const PrizeDialog := preload("res://midway/fbt_prize_dialog.gd")
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")

const GAME := "FootballToss"
## The gun's smoke emitter (see Particles above).
const SMOKE := "fbtThrowballVC.smoke"

# -- NSUserDefaults keys ------------------------------------------------
const KEY_PLAY_COUNT := "FootballTossPlayCountKey"
const KEY_UNIQUE := "uniqueFBToss"
const KEY_DATE_ARC_FLAG := "dateArcFlag"
const KEY_START_ARC_DATE := "startArcDate"
const KEY_END_ARC_DATE := "endArcDate"
const KEY_PLAYED_ARC_FLAG := "playedArcFlag"
const KEY_ACCEL_FLAG := "accelFlag"

# -- server table fallbacks (IAPlistManager iaplistDict is not bundled) --
const NUM_OF_PLAYS := 3              # FootballTossNumberOfPlays, 3 when 0
const MORE_PLAYS_COST := 5           # FootballTossMorePlaysCost, 5 when absent
const CHANCES_PER_GAME := 3          # startGame: chanceCount = 3

# -- football gun consumable --------------------------------------------
const GUN_KEY := "DM_CONSUMABLE_FOOTBALL_GUN"
const GUN_NAME := "Gun"
const GUN_COST := 11                 # CoinCosts."Football Toss".FootballGun, 11 when < 1
const GUN_MESSAGE := "Try out the Football Gun! Better accuracy! Try it for FREE now!"
const GUN_BADGE_ART := "football_gun_upgrade.png"
const GUN_BADGE_CENTER := Vector2(50, 350.5)    # 0x42480000 / 0x43AF4000
const ART_BALLS_PLATE := "fb_lable_balls.png"            # hideGun
const ART_SHOTS_PLATE := "btn_play_minigame_fbshots.png" # showGun

# -- ball ------------------------------------------------------------------
const BALL_START_ART := "football_start.png"
const BALL_FRAMES := ["football_1.png", "football_2.png", "football_3.png",
	"football_4.png", "football_5.png"]
const BALL_FAIL_ART := "football_fail_%d.png"
## ballIV nib frame size (117,271,87,140), contentMode center; the art is the
## same size, so frame and image coincide.
const BALL_SIZE := Vector2(87, 140)
## initBallZoomLevel 0x243DC.
const ZOOM_SCALES := [0.8, 0.7, 0.6, 0.5, 0.4, 0.3]

## holeCollider1..3 nib frames, in detectCollision's order, and the prize
## category showPrizeView asks for on each.
const HOLE_RECTS := [Rect2(79, 230, 65, 65), Rect2(200, 129, 55, 55), Rect2(77, 87, 40, 40)]
const HOLE_CATEGORIES := ["Small", "Medium", "Large"]

# touchesEnded: throw constants (0x26B08; floats from the literal pool)
const SWIPE_MIN := 28.0              # VMOV.F32 #28.0
const SPEED_MIN := 500.0             # 0x26F20
const SPEED_MAX := 3000.0            # 0x26F24
const HEIGHT_DIV := 10.0             # VMOV.F32 #10.0
const DURATION_K := 0.25             # VMOV.F32 #0.25
const FIELD_BOTTOM := 480.0          # 0x26F1C (also the 480 of the frame scale)
const CONTROL_Y := 210.0             # 0x26F30
const END_Y := 310.0                 # 0x275CC
const FRAME_LEAD := 0.1              # 0x275D0 -0.1

const GUN_SHOT_SECONDS := 0.3        # 0x26F28 DCFD 0.300000012
const HIT_SECONDS := 0.3             # 0x25FF0
const HIT_DROP := 200.0              # sub_26000 0x43480000
const MISS_SECONDS := 0.6            # 0x25FF8
const MISS_DROP := 400.0             # sub_261AC 0x43C80000
const MISS_TURN := 1.5708            # CGAffineTransformRotate(.., 1.5708)
const SHOW_BALL_DX := 500.0          # showBall 0x43FA0000
const SHOW_BALL_SECONDS := 0.25      # 0x3E800000
const START_MSG_DELAY := 0.2         # performSelector:afterDelay: 0x3FC999999999999A

# -- balloons (init + showBalloons) ------------------------------------
const BALLOON_ART := ["circus_ballbubble.png", "circus_clownbubble.png",
	"circus_greenbubble.png", "circus_pinkbubble.png", "circus_yellowbubble.png",
	"circus_yellowbubble.png", "circus_pinkbubble.png", "circus_greenbubble.png",
	"Star_Emitters_End_Game_PS_1.png", "Star_Emitters_End_Game_PS_2.png",
	"Star_Emitters_End_Game_PS_3.png", "Star_Emitters_End_Game_PS_4.png",
	"Star_Emitters_End_Game_PS_5.png"]
const BALLOON_FRAME := 80.0          # initWithFrame:(0,0,80,80), contentMode 1
const BALLOON_PARK := Vector2(-999, -999)
const BALLOON_RISE := 650.0          # -650
const BALLOON_SPREAD_X := 160.0      # x + 2*(x - 160)
const BALLOON_SECONDS_MIN := 1.5     # + (rand % 100) / 100, curve EaseIn

# -- alert text (UIAlertView, title "") --------------------------------
const MSG_OUT_OF_PLAYS := "You are out of plays. Would you like to buy more?"
const MSG_NO_COINS := "You do not have enough coins. Would you like to buy more?"

# -- outlets ---------------------------------------------------------------
var _view: Node2D
var _ball: Sprite2D
var _gun: CanvasItem
var _inst: Node2D
var _foreground: Node
var _back_btn: Node
var _ball_count_bg: Sprite2D
var _ball_count_label: Label
var _coin_label: Label
var _play_count_label: Label
var _more_plays_cost_label: Label
var _badge: TextureButton
var _balloons: Array[Sprite2D] = []
var _popup: Control = null
var _smoke: SSEmitter

# -- controller ivars ------------------------------------------------------
var _play_count := 0
var _chance_count := 0
var _num_of_plays := NUM_OF_PLAYS
var _more_plays_cost := MORE_PLAYS_COST
var _game_started := false
var _is_ball_in_air := false
var _action_performed := false       # written by the throw, read by nothing
var _is_collision_detect := false
var _incorrect_use_of_gun := false
var _toss_usec := -1                 # tossDate; -1 = nil
var _last_grab := Vector2.ZERO       # lastFootballGrabLocation
var _end_points := Vector2.ZERO      # endPointsOfBall
var _original_center := Vector2.ZERO
var _zoom_level := 0
var _gun_consumable: RefCounted

# -- ballIV model (UIKit model values; the sprite shows the presentation) ---
var _ball_center := Vector2.ZERO
var _ball_scale := 1.0
var _ball_rot := 0.0
var _ball_image: Texture2D
var _ball_anim: Tween = null         # the current UIView/CA layer animation
var _ball_frames: Tween = null       # UIImageView startAnimating
var _pending: Callable = Callable()  # the current ball animation's completion
var _deferred: Array[Callable] = []  # completions of removed animations


func on_enter() -> void:
	_resolve_outlets()
	_undo_instruction_slide()
	_init_with_nib()
	_view_did_load()
	_build_balloons()
	_view_will_appear()
	# initWithNibName: adds the COIN_NOTIFICATION_VALUE_CHANGED observer;
	# dealloc (0x27A0C) removes it -- see _notification.
	if not CoinManager.coin_value_changed.is_connected(_coin_value_changed):
		CoinManager.coin_value_changed.connect(_coin_value_changed)
	set_process(true)


## The pushed coin store / prize shelf covers this controller; it is not
## destroyed (Nav.gd's opt-in). See the header's STATE UNDER A PUSH.
func keeps_state_on_push() -> bool:
	return true


## Back on top: viewWillAppear: (0x23D8C) -- the coin label, then ballIV,
## gun, backBtn and instIV brought to the front, as on the first appearance.
func on_resume() -> void:
	_view_will_appear()


## No viewWillDisappear:/viewDidDisappear: in this class: nothing stops when a
## screen is pushed over it. The coin observer belongs to dealloc.
func on_exit() -> void:
	pass


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if CoinManager.coin_value_changed.is_connected(_coin_value_changed):
			CoinManager.coin_value_changed.disconnect(_coin_value_changed)


func _process(_delta: float) -> void:
	if _deferred.is_empty():
		return
	var batch := _deferred.duplicate()
	_deferred.clear()
	for c: Callable in batch:
		if c.is_valid():
			c.call()


# -- setup -------------------------------------------------------------------

func _resolve_outlets() -> void:
	_view = outlet("view") as Node2D
	_ball = outlet("ballIV") as Sprite2D
	_gun = outlet("gun") as CanvasItem
	_inst = outlet("instIV") as Node2D
	_foreground = outlet("foreground")
	_back_btn = outlet("backBtn")
	_ball_count_bg = outlet("ballCountBackground") as Sprite2D
	_ball_count_label = outlet("ballCountLabel") as Label
	_coin_label = outlet("coinLabel") as Label
	_play_count_label = outlet("playCountLabel") as Label
	_more_plays_cost_label = outlet("morePlaysCostLabel") as Label


## Screen._ready slides every instIV in (changeInstruction:). This class has
## no changeInstruction: -- "Tap to start" simply sits where the nib put it.
func _undo_instruction_slide() -> void:
	if _instruction_tween != null and _instruction_tween.is_valid():
		_instruction_tween.kill()
	if _inst != null and _instruction_home_set:
		_inst.position = _instruction_home


## The nib's root view (320x480) has an opaque black backgroundColor (raw
## nib: UIBackgroundColor rgb 0 0 0, alpha 1). It is what shows through the
## field's transparent holes once a scoring ball is sent behind the field
## art. The generated `view` node draws it
## itself (core/NibView.gd, beneath all of its subviews), so the hand-added
## ColorRect this screen used to put ahead of `view` is gone.


## initWithNibName:bundle: (0x23120), minus the balloons (built after
## viewDidLoad, as in the original).
func _init_with_nib() -> void:
	_play_count = Defaults.integer_for_key(KEY_PLAY_COUNT)
	_num_of_plays = NUM_OF_PLAYS
	_more_plays_cost = MORE_PLAYS_COST
	_gun_consumable = ConsumableScript.new(GUN_KEY, GUN_NAME, GUN_COST)
	_gun_consumable.set("first_time_message", GUN_MESSAGE)
	_gun_consumable.set("quantity", 0)
	_gun_consumable.set("on_purchased", _consumable_purchased)
	_gun_consumable.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	_incorrect_use_of_gun = false


## viewDidLoad (0x23660) -- once per controller.
func _view_did_load() -> void:
	_last_grab = Vector2.ZERO
	if not Defaults.bool_for_key(KEY_UNIQUE):
		Defaults.set_bool_for_key(true, KEY_UNIQUE)
		Defaults.synchronize()
	if Defaults.integer_for_key(KEY_DATE_ARC_FLAG) == 0:
		Defaults.set_object_for_key(_now(), KEY_START_ARC_DATE)
		Defaults.set_integer_for_key(1, KEY_DATE_ARC_FLAG)
		Defaults.synchronize()
	_set_label(_ball_count_label, "0")
	if _inst != null:
		_inst.visible = true
	# ballIV: a centred sprite so the zoom transform scales about its centre,
	# as a UIView transform does.
	if _ball != null:
		var nib_origin := _ball.position
		_ball.centered = true
		_ball_center = nib_origin + BALL_SIZE * 0.5
		_ball.position = _ball_center
		_ball.visible = false
	_original_center = _ball_center
	_ball_image = _tex(BALL_START_ART)
	_apply_ball_texture()
	_set_play_count(_play_count)
	_set_label(_ball_count_label, "%d" % _chance_count)
	_set_label(_more_plays_cost_label, "%d" % _more_plays_cost)
	_show_ball()
	_build_gun_badge()
	# smoke: setParticles:... on the nib's SSEmitter (call 0x23D80), after the
	# gun badge.
	var host := outlet("smoke")
	if host != null:
		_smoke = SSEmitter.attach(host, SSEmitterConfigs.frame_size(SMOKE)) as SSEmitter
		SSEmitterConfigs.apply(_smoke, SMOKE, null)


## The ConsumableButton viewDidLoad adds to the view (on top at that time).
func _build_gun_badge() -> void:
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyFootballGun"
	b.call("setup", GUN_BADGE_ART, 0, -25, int(_gun_consumable.get("cost")), 65, 3)
	b.position = GUN_BADGE_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyClick)
	b.visible = false
	_view.add_child(b)
	_badge = b


## init's balloon loop: 80x80 aspect-fit, parked off screen, above the badge.
func _build_balloons() -> void:
	for art: String in BALLOON_ART:
		var s := Sprite2D.new()
		s.texture = _tex(art)
		if s.texture != null:
			var ts: Vector2 = s.texture.get_size()
			var k: float = minf(BALLOON_FRAME / ts.x, BALLOON_FRAME / ts.y)
			s.scale = Vector2(k, k)
		s.position = BALLOON_PARK
		_view.add_child(s)
		_balloons.append(s)


## viewWillAppear: (0x23D8C).
func _view_will_appear() -> void:
	_set_label(_coin_label, "%d" % CoinManager.total_coins())
	_bring_to_front(_ball)
	_bring_to_front(_gun)
	_bring_to_front(_back_btn)
	_bring_to_front(_inst)


## coinValueChanged: (0x25C54) -- COIN_NOTIFICATION_VALUE_CHANGED.
func _coin_value_changed(total_coins: int) -> void:
	_set_label(_coin_label, "%d" % total_coins)


# -- buttons -------------------------------------------------------------------

## backClick: (0x23FD0).
func _on_backClick() -> void:
	Defaults.set_object_for_key(_now(), KEY_END_ARC_DATE)
	Defaults.synchronize()
	CoinManager.sync_coins(true)
	Audio.play("button_press")
	# displayAdForLocation:"Interstitial" unless FF_KEY_EVERYTHING -- no ads.
	Nav.back()


## coinsClick: (0x24158).
func _on_coinsClick() -> void:
	Audio.play("store")
	_push_away("CoinStoreViewController")


## morePlayClick: (0x24238).
func _on_morePlayClick() -> void:
	Audio.play("button_press")
	if not _is_ball_in_air and _buy_balls():
		_reset_ball()


## myToysClick: (0x242C4).
func _on_myToysClick() -> void:
	Audio.play("trophy_door")
	GameState.screen_args["PrizeViewController"] = {
		"prizes": PrizeManager.get_prizes_for_game(GAME),
		"background_file": "mb_prize_bg.png",
	}
	_push_away("PrizeViewController")


## buyClick: (0x23F64).
func _on_buyClick() -> void:
	Audio.play("store")
	_gun_consumable.call("purchase", self)


## consumablePurchased: (0x276CC).
func _consumable_purchased(free: bool) -> void:
	if not free and Defaults.integer_for_key(KEY_ACCEL_FLAG) == 0:
		Defaults.set_integer_for_key(1, KEY_ACCEL_FLAG)
		Defaults.synchronize()
	_gun_consumable.set("quantity", 1)
	_show_gun()
	if _badge != null:
		_badge.visible = false


## alertView:didDismissWithButtonIndex: (0x2650C): button_press for every
## title but "Get Coins" (the alert itself is silent: show_alert(.., false)).
func _alert_dismissed(title: String) -> void:
	if title != "Get Coins":
		Audio.play("button_press")
	match title:
		"Buy":
			if _buy_balls():
				_reset_ball()
		"Get Coins":
			_push_away("CoinStoreViewController")
		_:
			pass   # "Cancel": nothing


## buyBalls (0x24A70).
func _buy_balls() -> bool:
	if CoinManager.total_coins() >= _more_plays_cost:
		if Defaults.integer_for_key(KEY_DATE_ARC_FLAG) >= 1:
			Defaults.set_object_for_key(_now(), KEY_END_ARC_DATE)
			Defaults.synchronize()
		if Defaults.integer_for_key(KEY_PLAYED_ARC_FLAG) == 0:
			Defaults.set_integer_for_key(1, KEY_PLAYED_ARC_FLAG)
			Defaults.synchronize()
		CoinManager.spend_coins(_more_plays_cost)
		_set_play_count(_play_count + _num_of_plays)
		_set_label(_coin_label, "%d" % CoinManager.total_coins())
		return true
	show_alert(MSG_NO_COINS, ["Cancel", "Get Coins"], _alert_dismissed, false)
	return false


## setPlayCount: (0x25AE0) -- persisted on every change.
func _set_play_count(n: int) -> void:
	_play_count = n
	Defaults.set_integer_for_key(_play_count, KEY_PLAY_COUNT)
	Defaults.synchronize()
	_set_label(_play_count_label, "%d" % _play_count)


# -- touches -------------------------------------------------------------------

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


## touchesBegan:withEvent: (0x26764).
func _touches_began(p: Vector2) -> void:
	if not _gun_shown():
		if not _game_started and not _has_popup() and _inst_frame().has_point(p):
			if _play_count < 1:
				show_alert(MSG_OUT_OF_PLAYS, ["Cancel", "Buy"], _alert_dismissed, false)
			else:
				if _inst.visible:
					_inst.visible = false
				_game_started = true
				_start_game()
				_badge.visible = true
			return
		if _ball_frame().has_point(p) and not _has_popup():
			_toss_usec = Time.get_ticks_usec()
			_last_grab = p
	else:
		_incorrect_use_of_gun = _ball_frame().has_point(p) and not _has_popup()


## touchesEnded:withEvent: (0x26B08).
func _touches_ended(p: Vector2) -> void:
	if not _gun_shown():
		if _toss_usec >= 0 and _last_grab.y != 0.0:
			if _last_grab.y - p.y > SWIPE_MIN and _chance_count >= 1 \
					and not _has_popup() and not _is_ball_in_air:
				_throw(p)
		_toss_usec = -1
		_last_grab = Vector2.ZERO
	elif not _incorrect_use_of_gun:
		_incorrect_use_of_gun = true
		_fire_gun(p)


## The throw half of touchesEnded. Both points are multiplied by
## applicationFrame / (320, 480) in the original -- 1.0 on the phone, where
## UIStatusBarHidden is YES.
func _throw(p: Vector2) -> void:
	var ball := _ball_center
	var dx := absf(ball.x - p.x)
	var dy := absf(ball.y - p.y)
	var dist := sqrt(dy * dy + dx * dx)
	# INFERRED: a release exactly on the ball centre gives asin(0/0) = NaN,
	# which CALayer rejects with an exception on iOS; the port throws straight.
	var angle := asin(dx / dist) if dist > 0.0 else 0.0
	if p.x < ball.x:
		angle = -angle
	var dt := float(Time.get_ticks_usec() - _toss_usec) / 1000000.0
	var raw := dist / dt if dt > 0.0 else INF
	var speed := SPEED_MIN
	if raw >= SPEED_MIN:
		speed = SPEED_MAX if raw > SPEED_MAX else raw
	var h := speed / HEIGHT_DIV
	var duration := h / (speed * DURATION_K)
	var off := tan(angle) * (h + (FIELD_BOTTOM - ball.y))
	var start := ball
	var control := Vector2(off * 0.5 + ball.x, CONTROL_Y - h)
	_end_points = Vector2(off + ball.x, END_Y - h)
	_set_ball_zoom_level()
	_is_collision_detect = _detect_collision()
	_set_ball_center(_original_center)
	_set_ball_transform(1.0, 0.0)
	var frames_seconds := duration
	if duration - FRAME_LEAD > 0.0:
		frames_seconds = duration - FRAME_LEAD
	_action_performed = false
	_start_ball_frames(frames_seconds)
	# "ScaleBall" (curve 3 linear, didStop -> animationDidStop:) and the
	# "MoveBall" CAKeyframeAnimation (linear, fill forwards) share `duration`;
	# the keyframe animation moves the layer only, so the model centre stays
	# put until animationDidStop: sets it to the end point.
	var s: float = ZOOM_SCALES[_zoom_level]
	_ball_scale = s
	var tw := _begin_ball_animation(_animation_did_stop_scale_ball)
	tw.tween_property(_ball, "scale", Vector2(s, s), duration).set_trans(Tween.TRANS_LINEAR)
	tw.tween_method(_place_on_path.bind(start, control, _end_points), 0.0, 1.0,
		duration).set_trans(Tween.TRANS_LINEAR)
	Audio.play("toss")
	_is_ball_in_air = true


## One step of the "MoveBall" CGPath: MoveToPoint(start) +
## AddQuadCurveToPoint(control, end), kCAAnimationLinear in the curve
## parameter.
func _place_on_path(t: float, start: Vector2, control: Vector2, end: Vector2) -> void:
	_ball.position = _quad_point(start, control, end, t)


## The gun half of touchesEnded: the shot goes where the player tapped.
func _fire_gun(p: Vector2) -> void:
	_end_points = p
	_set_ball_zoom_level()
	_is_collision_detect = _detect_collision()
	_set_ball_center(_original_center)
	_set_ball_transform(1.0, 0.0)
	var s: float = ZOOM_SCALES[_zoom_level]
	_ball_scale = s
	_ball_center = _end_points
	var tw := _begin_ball_animation(_animation_did_stop_scale_ball)
	tw.tween_property(_ball, "scale", Vector2(s, s), GUN_SHOT_SECONDS).set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(_ball, "position", _end_points, GUN_SHOT_SECONDS).set_trans(Tween.TRANS_LINEAR)
	# [smoke start] right after commitAnimations (touchesEnded: 0x26B08).
	if _smoke != null:
		_smoke.start()


static func _quad_point(a: Vector2, c: Vector2, b: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return a * (u * u) + c * (2.0 * u * t) + b * (t * t)


## setBallZoomLevel (0x246D8), branch for branch.
func _set_ball_zoom_level() -> void:
	var y := _end_points.y
	var level: int
	if y >= 300.0:
		level = 0
	elif y > 240.0:
		level = 1
	elif y > 180.0:
		level = 2
	elif y > 120.0:
		level = 3
	elif y > 60.0:
		level = 4
	else:
		level = 5
	_zoom_level = level


## detectCollision (0x24428).
func _detect_collision() -> bool:
	for r: Rect2 in HOLE_RECTS:
		if r.has_point(_end_points):
			return true
	return false


## animationDidStop:finished:context: (0x25CF0) for "ScaleBall".
func _animation_did_stop_scale_ball() -> void:
	var collision := _is_collision_detect
	_set_ball_center(_end_points)
	if collision:
		_send_to_back(_ball)
		var target := Vector2(_end_points.x, _end_points.y + HIT_DROP)
		_ball_center = target
		var tw := _begin_ball_animation(_hit_completed)
		tw.tween_property(_ball, "position", target, HIT_SECONDS) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(_ball, "modulate:a", 0.0, HIT_SECONDS) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	else:
		_insert_below(_ball, _foreground)
		var which := (randi() & 1) + 1
		_ball_image = _tex(BALL_FAIL_ART % which)
		_apply_ball_texture()
		var dx := _end_points.x - _original_center.x
		var target := Vector2(_end_points.x + dx, _end_points.y + MISS_DROP)
		_ball_center = target
		var tw := _begin_ball_animation(_miss_completed)
		tw.tween_property(_ball, "position", target, MISS_SECONDS) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(_ball, "modulate:a", 0.0, MISS_SECONDS) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		if which == 2:
			_ball_rot += MISS_TURN
			tw.tween_property(_ball, "rotation", _ball_rot, MISS_SECONDS) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# [smoke stop] (0x25CF0): unconditional, after the ScaleBall branch. With
	# repeat NO it has usually stopped itself by now (3 puffs, 0.15 s).
	if _smoke != null:
		_smoke.stop()
	_incorrect_use_of_gun = false


## sub_26084 -- the ball went in.
func _hit_completed() -> void:
	get_tree().create_timer(START_MSG_DELAY).timeout.connect(_display_start_msg)
	_chance_count = 0
	_game_started = false
	_set_label(_ball_count_label, "0")
	_reset_ball()
	_show_prize_view()
	_show_balloons()
	if _chance_count <= 0:
		_end_game()


## sub_262D4 -- the ball fell.
func _miss_completed() -> void:
	_chance_count -= 1
	_set_label(_ball_count_label, "%d" % _chance_count)
	_reset_ball()
	_show_ball()
	if _chance_count <= 0:
		_end_game()


## displayStartMsg (0x24D18).
func _display_start_msg() -> void:
	if _inst != null:
		_inst.visible = true


## startGame (0x24540).
func _start_game() -> void:
	_set_play_count(_play_count - 1)
	_chance_count = CHANCES_PER_GAME
	_set_label(_ball_count_label, "%d" % _chance_count)
	_ball.visible = true
	if Defaults.integer_for_key(KEY_DATE_ARC_FLAG) >= 1:
		Defaults.set_object_for_key(_now(), KEY_END_ARC_DATE)
		Defaults.synchronize()


## endGame (0x26394).
func _end_game() -> void:
	_game_started = false
	_inst.visible = true
	_set_label(_ball_count_label, "0")
	_ball.visible = false
	_reset_ball()
	_hide_gun()
	if _badge != null:
		_badge.visible = false


## showGun (0x275D4) / hideGun (0x27650).
func _show_gun() -> void:
	_ball_count_bg.texture = _tex(ART_SHOTS_PLATE)
	_gun.visible = true


func _hide_gun() -> void:
	_ball_count_bg.texture = _tex(ART_BALLS_PLATE)
	_gun.visible = false


func _gun_shown() -> bool:
	return _gun != null and _gun.visible


# -- ball ------------------------------------------------------------------------

## resetBall (0x247C8).
func _reset_ball() -> void:
	_ball_image = _tex(BALL_START_ART)
	_set_ball_center(_original_center)
	_set_ball_transform(1.0, 0.0)
	_ball.modulate.a = 1.0
	_bring_to_front(_ball)
	_bring_to_front(_gun)
	_remove_all_ball_animations()
	_is_ball_in_air = false


## showBall (0x24938): jump 500 right, slide back (slideView:toPoint:
## overDuration: 0x25BA8 -- "SlideView", curve 3 linear, no didStop).
func _show_ball() -> void:
	var c := _ball_center
	_set_ball_center(c + Vector2(SHOW_BALL_DX, 0))
	_ball_center = c
	var tw := _begin_ball_animation(Callable())
	tw.tween_property(_ball, "position", c, SHOW_BALL_SECONDS).set_trans(Tween.TRANS_LINEAR)


## A new UIView animation on ballIV. Replacing one still in flight runs the
## old one's completion (finished = NO) -- deferred, as UIKit delivers it.
func _begin_ball_animation(completion: Callable) -> Tween:
	_replace_ball_animation()
	var tw := create_tween().set_parallel(true)
	_ball_anim = tw
	_pending = completion
	tw.finished.connect(_on_ball_animation_finished.bind(tw))
	return tw


func _on_ball_animation_finished(tw: Tween) -> void:
	if tw != _ball_anim:
		return
	_ball_anim = null
	var c := _pending
	_pending = Callable()
	if c.is_valid():
		c.call()


func _replace_ball_animation() -> void:
	if _ball_anim != null and _ball_anim.is_valid():
		_ball_anim.kill()
	_ball_anim = null
	if _pending.is_valid():
		_deferred.append(_pending)
	_pending = Callable()


## [ballIV.layer removeAllAnimations]: the movement and the frame cycle stop,
## the sprite shows the model values.
func _remove_all_ball_animations() -> void:
	_replace_ball_animation()
	if _ball_frames != null and _ball_frames.is_valid():
		_ball_frames.kill()
	_ball_frames = null
	_ball.position = _ball_center
	_ball.scale = Vector2(_ball_scale, _ball_scale)
	_ball.rotation = _ball_rot
	_apply_ball_texture()


## setCenter: outside an animation block.
func _set_ball_center(c: Vector2) -> void:
	_ball_center = c
	_ball.position = c


## setTransform: outside an animation block (scale + rotation only).
func _set_ball_transform(s: float, rot: float) -> void:
	_ball_scale = s
	_ball_rot = rot
	_ball.scale = Vector2(s, s)
	_ball.rotation = rot


## UIImageView animationImages football_1..5, setAnimationRepeatCount:1,
## startAnimating: the frames, evenly, then back to `image`.
func _start_ball_frames(seconds: float) -> void:
	if _ball_frames != null and _ball_frames.is_valid():
		_ball_frames.kill()
	var step := seconds / float(BALL_FRAMES.size())
	var tw := create_tween()
	for art: String in BALL_FRAMES:
		tw.tween_callback(_show_ball_frame.bind(art))
		tw.tween_interval(step)
	tw.tween_callback(_end_ball_frames)
	_ball_frames = tw


func _show_ball_frame(art: String) -> void:
	_ball.texture = _tex(art)


func _end_ball_frames() -> void:
	_ball_frames = null
	_apply_ball_texture()


func _apply_ball_texture() -> void:
	if _ball_frames == null or not _ball_frames.is_valid():
		_ball.texture = _ball_image


## ballIV.frame: the transformed bounds' bounding box around the centre.
func _ball_frame() -> Rect2:
	var w := BALL_SIZE.x * _ball_scale
	var h := BALL_SIZE.y * _ball_scale
	var c := absf(cos(_ball_rot))
	var s := absf(sin(_ball_rot))
	var size := Vector2(w * c + h * s, w * s + h * c)
	return Rect2(_ball_center - size * 0.5, size)


## instIV.frame -- the nib's 200x100 box the art is stretched into.
func _inst_frame() -> Rect2:
	if _inst is Sprite2D and (_inst as Sprite2D).texture != null:
		var sp := _inst as Sprite2D
		return Rect2(sp.position, sp.texture.get_size() * sp.scale)
	return Rect2()


# -- prize, balloons -------------------------------------------------------------

func _has_popup() -> bool:
	return _popup != null and is_instance_valid(_popup) and _popup.call("is_open")


## showPrizeView (0x24EAC).
func _show_prize_view() -> void:
	var prize: Variant = null
	for i in HOLE_RECTS.size():
		if (HOLE_RECTS[i] as Rect2).has_point(_end_points):
			prize = PrizeManager.get_random_prize_by_category_game_categoried(
				true, GAME, HOLE_CATEGORIES[i])
			break
	if prize == null:
		prize = PrizeManager.get_random_prize_game(true, GAME)
	PrizeManager.unlock_prize(prize)
	_open_prize_dialog(prize)
	if Defaults.integer_for_key(KEY_DATE_ARC_FLAG) >= 1:
		Defaults.set_object_for_key(_now(), KEY_END_ARC_DATE)
		Defaults.synchronize()
	Audio.play("fanfare")


func _open_prize_dialog(prize: Variant) -> void:
	var d: Control = PrizeDialog.new()
	d.call("setup", prize, PrizeManager.get_prize_image(prize),
		PrizeManager.get_prize_name(prize))
	_view.add_child(d)
	_popup = d
	d.call("play_entrance")


## showBalloons (0x257D8).
func _show_balloons() -> void:
	for b: Sprite2D in _balloons:
		var start := Vector2(float(randi() % 200 + 60), float(randi() % 50 + 520))
		b.position = start
		_bring_to_front(b)
		var secs: float = float(randi() % 100) / 100.0 + BALLOON_SECONDS_MIN
		var target := Vector2(start.x + 2.0 * (start.x - BALLOON_SPREAD_X),
			start.y - BALLOON_RISE)
		create_tween().tween_property(b, "position", target, secs) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	Audio.play("cheer")


# -- leaving and coming back -----------------------------------------------------

## The pushed controller covers this one; Nav keeps this instance alive.
## INFERRED (header, PORT CHOICES): a ball stage still in flight finishes --
## completions run -- before the push, as UIKit ends a covered view's
## animations; the port's tweens would otherwise wait, paused, for the return.
func _push_away(screen: String) -> void:
	_flush_ball_completions()
	Nav.push(screen)


func _flush_ball_completions() -> void:
	for _guard in 16:
		if _pending.is_valid():
			var c := _pending
			_pending = Callable()
			if _ball_anim != null and _ball_anim.is_valid():
				_ball_anim.kill()
			_ball_anim = null
			c.call()
		elif not _deferred.is_empty():
			var c2: Callable = _deferred.pop_front()
			if c2.is_valid():
				c2.call()
		else:
			return


# -- helpers ---------------------------------------------------------------------

static func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


static func _now() -> float:
	return Time.get_unix_time_from_system()


static func _set_label(l: Label, text: String) -> void:
	if l != null:
		l.text = text


func _bring_to_front(n: Node) -> void:
	if n != null and n.get_parent() == _view:
		_view.move_child(n, _view.get_child_count() - 1)


func _send_to_back(n: Node) -> void:
	if n != null and n.get_parent() == _view:
		_view.move_child(n, 0)


## insertSubview:belowSubview:.
func _insert_below(n: Node, ref: Node) -> void:
	if n == null or ref == null or n.get_parent() != _view or ref.get_parent() != _view:
		return
	var to := ref.get_index()
	if n.get_index() < to:
		to -= 1
	_view.move_child(n, to)
