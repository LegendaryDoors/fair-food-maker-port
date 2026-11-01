# Water Race (midway game, stand tag 11) -- squirt the centre clown's mouth
# with the water gun to blow up its balloon before the two AI clowns pop
# theirs; pop it to win a prize.
#
# From the original binary (all 100 methods walked: 26 with behaviour, the
# rest synthesized accessors), with every float argument read from the
# instructions. Entry points from the ObjC method list:
#   initWithNibName:bundle:    0xA9D0    viewDidLoad          0xAD74
#   viewWillAppear:            0xBE88    viewWillDisappear:   0xC08C
#   viewDidDisappear:          0xC10C    resetRace            0xC5A8
#   startRace                  0xC830    endRace              0xCCC8
#   closePrizeDialog:          0xD56C    delayStartupEmitterBalloons 0xD6F0
#   moveClown                  0xD9F8    startCountdown       0xDDA0
#   countdownTick:             0xDED0    startGame:           0xE1C4
#   spriteTick                 0xE378    backClick:           0xEE58
#   coinsClick:                0xF034    playClick:           0xF150
#   prizeClick:                0xF1E8    touchesBegan:withEvent: 0xF32C
#   touchesMoved:withEvent:    0xF7C8    touchesEnded:withEvent: 0xFBF4
#   coinValueChanged:          0xFC8C    buyHoses             0xFD24
#   setHoseCount:              0xFF54    alertView:clickedButtonAtIndex: 0x1001C
#   showBuyMoreCoinsMessage    0x103C4   (distanceBetweenPt:andPt: 0xE344 and
#   animationDidStop:finished: 0xE374 exist but nothing uses them)
# Helpers: ClownView 0x12C700.. (src/midway/ws_ClownView.gd), BalloonView
# 0x124408.. (ws_BalloonView.gd), SpriteSheetView 0x47770.. (ws_SpriteSheetView.gd),
# TintedIV 0x46FEC / 0x47304 (ws_TintedIV.gd), IAPlistManager
# displayMediaBrixForLocation:withMiniGame: 0x1757E0 and
# alertView:clickedButtonAtIndex: 0x176C44.
#
# THE GAME (spriteTick 0xE378, every 0.1s while a race runs):
#   The water tip is a hidden 25x30 view centred at hose.center + (-3,-277).
#   When it intersects the centre clown's (hidden, 15x15) mouth -- taken from
#   the clown's PRESENTATION layer, i.e. where its wandering animation has it
#   -- inflate_loop plays and the player's balloon gains 0.1 (whether or not
#   the hose is held; holding it is what refreshes the 3.5s "last hit" clock).
#   The race is rigged at startRace: shouldAIWin = arc4random()%100 < 50.
#     shouldAIWin: the AI balloons gain 0.1 EVERY tick; the favoured AI pops
#       at 12 + (r & 7), the other at 24 + (r & 15), and the player needs
#       (r % 12) MORE than the favoured AI -- so the player cannot win.
#     otherwise: pop times 20 / 40 (ai1WillWin picks which), player
#       11 + (r & 7); the AI balloons gain 0.1 only on ticks where the
#       player's fraction is strictly ahead of BOTH of theirs, so they shadow
#       the player and never catch up -- unless 3.5s pass with no held hit,
#       which flips shouldAIWin on for the rest of the race.
#   Every balloon is drawn at scale 1 + amount/popTime, bottom edge pinned.
#   The player's pop is checked BEFORE the increment (it pops the tick after
#   reaching its time); an AI pop ends the race at once (AI 1 first).
#   Everything accumulates in float32, as the original's float ivars do.
#
# OFFLINE STATE: IAPlistManager.iaplistDict only ever comes from Sunstorm's
# server, so NUM_OF_HOSES takes its coded fallback 2 and
# showBuyMoreCoinsMessage's ad call finds no "Advertising" key -- see
# show_buy_more_coins_message() for the PORT CHOICE there. The first-run play
# count (WaterShooterCountKey = 15) is seeded by core/AppDelegate.gd.
#
# NOT PORTED (no visible effect): every +[DataLogging ...] call and the
# analytics-only defaults they feed ("uniqueWater", "dateArcFlag",
# "startArcDate", "endArcDate", "playedArcFlag"); backClick:'s interstitial
# (skipped under FF_KEY_EVERYTHING, the port's permanent state); the iPad
# flag set in viewWillAppear: (ipad2x, never read); instIV (no nib outlet);
# NSLogs. The two unreachable branches of alertView:clickedButtonAtIndex:
# ("OK" does nothing; "Yes"/"No" belong to no alert this class shows) are
# ported for completeness.

extends "res://core/Screen.gd"
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const ClownView := preload("res://midway/ws_ClownView.gd")
const BalloonView := preload("res://midway/ws_BalloonView.gd")
const SpriteSheetView := preload("res://midway/ws_SpriteSheetView.gd")
const TintedIV := preload("res://midway/ws_TintedIV.gd")


# -- initWithNibName:bundle: (0xA9D0) ------------------------------------

## [[IAPlist GameData] WaterPurchase] intValue, 0 -> 2. No IAPlist exists
## without the server, so it is always the fallback.
const NUM_OF_HOSES := 2
const KEY_HOSE_COUNT := "WaterShooterCountKey"
## fallingCookies: one 80x80 UIImageView each, contentMode 1 (aspect fit),
## parked at centre (-999,-999), added to the view above every other view
## (the `[self view]` inside the loop is what loads the nib and runs
## viewDidLoad, before the first cookie is added).
const COOKIE_ART := ["circus_ballbubble.png", "circus_clownbubble.png",
	"circus_greenbubble.png", "circus_pinkbubble.png",
	"circus_yellowbubble.png", "circus_yellowbubble.png",
	"circus_pinkbubble.png", "circus_greenbubble.png",
	"Star_Emitters_End_Game_PS_1.png", "Star_Emitters_End_Game_PS_2.png",
	"Star_Emitters_End_Game_PS_3.png", "Star_Emitters_End_Game_PS_4.png",
	"Star_Emitters_End_Game_PS_5.png"]
const COOKIE_BOX := 80.0
const COOKIE_PARK := Vector2(-999, -999)

# -- viewDidLoad (0xAD74) --------------------------------------------------

## TintedIV(art, redColor / blueColor, mode 9), each read back from baseIV.
const BALLOON_ART := ["ws_balloon.png", "ws_balloon_popping.png",
	"ws_balloon_popped.png"]
const PLAYER_TINT := Color(1, 0, 0)          # +[UIColor redColor]
const AI_TINT := Color(0, 0, 1)              # +[UIColor blueColor]
const TINT_MODE := 9                         # kCGBlendModeHardLight
const PLAYER_CLOWN_ART := "WS_center_clown_head.png"
const AI1_CLOWN_ART := "WS_left_clown_head.png"
const AI2_CLOWN_ART := "WS_right_clown_head.png"
const PLAYER_CLOWN_CENTER := Vector2(160, 190)
const AI1_CLOWN_CENTER := Vector2(15, 200)
const AI2_CLOWN_CENTER := Vector2(305, 200)
## The water on the hose: SpriteSheetView (0,0,120,234) over
## Water_Animation_Sheet.png (360x468), 3 columns x 2 rows, centred at the
## view point (164,235) converted into hoseIV (convertPoint:fromView:).
const WATER_ART := "Water_Animation_Sheet.png"
const WATER_SIZE := Vector2(120, 234)
const WATER_COLUMNS := 3
const WATER_ROWS := 2
const WATER_CENTER_IN_VIEW := Vector2(164, 235)
## spriteTick resets the frame index to 0 once it reaches 5 (the sheet's
## sixth cell is empty).
const WATER_FRAMES_USED := 5
## waterTipView: UIView (0,0,25,30), blueColor, HIDDEN -- a hit box only.
const TIP_SIZE := Vector2(25, 30)
## spriteTick: tip centre = hose.center + (-3, -277).
const TIP_FROM_HOSE := Vector2(-3, -277)
## The AI water: a 132x344 clipping UIScrollView each, over
## Water_Animation_Sheet_Curved.png (132x1720, five 344-tall frames), centred
## at the AI clown's centre + (-6,20) / (+6,20); AI 1's image is mirrored
## (CGAffineTransformMakeScale(-1, 1)).
const AI_WATER_ART := "Water_Animation_Sheet_Curved.png"
const AI_WATER_SIZE := Vector2(132, 344)
const AI1_WATER_FROM_CLOWN := Vector2(-6, 20)
const AI2_WATER_FROM_CLOWN := Vector2(6, 20)
const AI_WATER_FRAMES := 5
## hoseIV: nib frame (131,306,58,300), content mode Center; viewDidLoad adds a
## second WS_hose.png UIImageView to it, centred in its bounds, above the
## water -- so the water comes out from behind the gun.
const HOSE_BOUNDS := Vector2(58, 300)
const HOSE_ART := "WS_hose.png"
## barrelDetectionView: nib frame (120,259,80,222). The generated scene keeps
## only its origin (a bare Node2D), so the size is taken from the nib here.
const BARREL_SIZE := Vector2(80, 222)

# -- startRace (0xC830) / spriteTick (0xE378) -----------------------------

## NSTimer, 0.1s repeating (double 0x3FB999999999999A).
const SPRITE_TICK := 0.1
## 0x3DCCCCCD added per tick to pBalloon / aiBalloon1 / aiBalloon2.
const BALLOON_STEP := 0.1
## [[NSDate date] timeIntervalSinceDate:dateSinceLastHit] >= 3.5
const NO_HIT_SECONDS := 3.5
## arc4random() % 100 < 50
const AI_WIN_PERCENT := 50
## setCenter: (center.x, -frame.h * 0.5 + 21) -- the balloon's bottom stays
## at y=21 in the clown's bounds as it grows.
const BALLOON_BOTTOM := 21.0

# -- moveClown (0xD9F8) ----------------------------------------------------

## CGPath from originalClownCenter through 30 points at
## originalClownCenter + (+-((r % (int)barrel.w) >> 1), +-(r % 50)).
const CLOWN_PATH_POINTS := 30
const CLOWN_Y_SPAN := 50
## setDuration: (double)(arc4random() % 20 + 50).
const CLOWN_SECONDS_MIN := 50
const CLOWN_SECONDS_SPAN := 20

# -- touchesMoved:withEvent: (0xF7C8) --------------------------------------

## centre = (clamp(x + off.x, barrel.minX, barrel.maxX),
##           clamp(y + 10 + off.y, barrel.minY, barrel.maxY) + 20)
const MOVE_Y_NUDGE := 10.0
const MOVE_Y_DROP := 20.0

# -- startCountdown (0xDDA0) / countdownTick: (0xDED0) / startGame: --------

const COUNTDOWN_FROM := 3                    # the overlay's tag
const COUNTDOWN_TICK := 1.0                  # NSTimer 1.0s repeating
const COUNTDOWN_FADE := 0.25                 # "TimeFadeIn", curve 3 (linear)
const COUNTDOWN_CENTER := Vector2(160, 240)
const START_GAME_DELAY := 1.0                # afterDelay: double 0x3FF0000000000000

# -- touchesBegan / endRace: the "Tap gun to start" label -----------------

const TAP_LABEL_FADE := 0.5                  # "HideTapLabel" / "ShowTapLabel", curve 3

# -- endRace (0xCCC8): the prize dialog ------------------------------------

const DIALOG_TAG := 1000000
const DIALOG_POP_SECONDS := 0.5      # scale 0.01 -> identity, curve 3 (linear)
const DIALOG_START_SCALE := 0.01
const PRIZE_CENTER := Vector2(160, 240)
const CLOSE_SIZE := Vector2(94, 63)
const CLOSE_CENTER := Vector2(160, 400)
const PRIZE_LABEL_CENTER := Vector2(160, 355)
const NAME_SIZE := Vector2(74, 14)
const NAME_Y := 16.0                 # centre (prize_label.w * 0.5, 16)
const NAME_FONT_SIZE := 12
const NAME_MIN_FONT_SIZE := 6
const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans",
	"Liberation Sans", "Arial"]
const PRIZE_GAME := "watershooter"

# -- delayStartupEmitterBalloons (0xD6F0) ----------------------------------

const COOKIE_X_RANGE := 200
const COOKIE_X_MIN := 60
const COOKIE_Y_RANGE := 50
const COOKIE_Y_MIN := 520
const COOKIE_RISE := -650.0
const COOKIE_SPREAD_PIVOT := -160.0  # x' = x + 2 * (x - 160)
const COOKIE_BASE_SECONDS := 1.5

# -- buyHoses (0xFD24) -----------------------------------------------------

const PLAY_PRICE := 5                # totalCoins > 4, spendCoins:5

## The nib's coin / play count labels: 22x20, 17pt, adjustsFontSizeToFit
## YES, minimumFontSize 6 (runtime.nib, objects 22 and 74). The generated
## Labels carry that themselves (core/NibLabel.gd shrinks, the scene sets
## clip + tail ellipsis), so this screen only sets the text.

const OUT_OF_PLAYS := "You are out of plays. Would you like to buy more?"
const NOT_ENOUGH_COINS := "You do not have enough coins. Would you like to buy more?"

# -- state (ivars) ---------------------------------------------------------

var hose_count := 0
var race_started := false
var should_ai_win := false
var ai1_will_win := false
var p_balloon := 0.0
var ai_balloon1 := 0.0
var ai_balloon2 := 0.0
var player_pop_time := 0.0
var ai1_pop_time := 0.0
var ai2_pop_time := 0.0
var hose_grabbed := false
var is_counting_down := false
var current_pt := Vector2.ZERO
var touch_offset := Vector2.ZERO
var original_hose_center := Vector2.ZERO
var original_clown_center := Vector2.ZERO
var barrel_detection_frame := Rect2()
## dateSinceLastHit, as Time.get_ticks_msec() (NSDate is wall-clock).
var last_hit_msec := 0

var player_clown: ClownView
var ai_clown1: ClownView
var ai_clown2: ClownView

## hoseIV: a pivot at its centre (what -center reads and writes); its
## subviews hang off _hose_bounds, at UIKit coordinates in hoseIV's bounds.
var _hose_view: Node2D
var _hose_bounds: Node2D
var _water: SpriteSheetView
var _water_tip: ColorRect
## The AI water "scroll views" (their frames stay, for touch hit-testing)
## and the curved-water image views inside them (what endRace hides).
var _ai1_water_frame := Rect2()
var _ai2_water_frame := Rect2()
var _ai1_water: Sprite2D
var _ai2_water: Sprite2D

var _tap_label: Sprite2D
var _tap_tween: Tween
var _coin_label: Label
var _hose_count_label: Label
var _falling_cookies: Array[Sprite2D] = []

var _sprite_timer: Timer
var _countdown_timer: Timer
var _countdown: Control = null       # the tag-3 overlay view
var _countdown_tag := 0
var _dialog: Control = null          # the tag-1000000 prize view
var _modal: CanvasLayer = null       # a UIAlertView is up
## The touch that began on the controller's view (not a button / alert).
var _touch_owned := false


func on_enter() -> void:
	_init_with_nib()
	_view_will_appear()


## coinsClick: (0xF034), prizeClick: (0xF1E8) and the Get Coins alert push
## over this controller; UINavigationController keeps it alive (hose count,
## the clowns built in viewDidLoad, an open prize dialog), so Nav keeps this
## instance and calls on_resume() instead of rebuilding it.
func keeps_state_on_push() -> bool:
	return true


## Back on top: viewWillAppear: (0xBE88) runs again -- resetRace, the coin
## label, both AI water views hidden, back/prize buttons to the front, the
## "tap the hose" label at alpha 1. The class has no viewDidAppear:.
func on_resume() -> void:
	_view_will_appear()


## viewWillDisappear: (0xC08C) + viewDidDisappear: (0xC10C) -- on a push as on
## a pop: both loops stopped, spriteTimer invalidated; nothing else.
func on_exit() -> void:
	Audio.stop("inflate_loop")
	Audio.stop("spray_loop")
	_invalidate_sprite_timer()


# ======================================================================
# Life cycle
# ======================================================================

## initWithNibName:bundle: (0xA9D0).
func _init_with_nib() -> void:
	if not CoinManager.coin_value_changed.is_connected(_coin_value_changed):
		CoinManager.coin_value_changed.connect(_coin_value_changed)
	set_hose_count(Defaults.integer_for_key(KEY_HOSE_COUNT))
	_view_did_load()
	for n: String in COOKIE_ART:
		var s := Sprite2D.new()
		s.centered = true
		s.texture = Assets.texture(n)
		var sz := s.texture.get_size()
		var k := minf(COOKIE_BOX / sz.x, COOKIE_BOX / sz.y)   # aspect fit
		s.scale = Vector2(k, k)
		s.position = COOKIE_PARK
		add_child(s)
		_falling_cookies.append(s)


## viewDidLoad (0xAD74).
func _view_did_load() -> void:
	_coin_label = outlet("coinLabel") as Label
	_hose_count_label = outlet("hoseCountLabel") as Label
	_tap_label = outlet("tapHoseToStart") as Sprite2D
	set_hose_count(hose_count)
	_refresh_coin_label()

	# The balloons: three tinted arts each for the player (red) and the AI
	# clowns (blue).
	var red: Array = []
	var blue: Array = []
	for n: String in BALLOON_ART:
		var art := Assets.texture(n)
		red.append(TintedIV.bake(art, PLAYER_TINT, TINT_MODE))
		blue.append(TintedIV.bake(art, AI_TINT, TINT_MODE))

	# Clowns, inserted below barrelDetectionView: [bg, ai1, ai2, player, ...].
	var barrel := outlet("barrelDetectionView") as Node2D
	player_clown = _make_clown(red, PLAYER_CLOWN_ART)
	add_child(player_clown)
	move_child(player_clown, barrel.get_index())
	player_clown.set_center(PLAYER_CLOWN_CENTER)
	ai_clown1 = _make_clown(blue, AI1_CLOWN_ART)
	add_child(ai_clown1)
	move_child(ai_clown1, player_clown.get_index())
	ai_clown1.set_center(AI1_CLOWN_CENTER)
	ai_clown2 = _make_clown(blue, AI2_CLOWN_ART)
	add_child(ai_clown2)
	move_child(ai_clown2, player_clown.get_index())
	ai_clown2.set_center(AI2_CLOWN_CENTER)

	# The hose and the water on it.
	_build_hose_view()
	var hose_origin := _hose_view.position - HOSE_BOUNDS * 0.5
	_water = SpriteSheetView.new()
	_water.init_with_frame_and_content_view_and_columns_and_rows(
		Rect2(Vector2.ZERO, WATER_SIZE), Assets.texture(WATER_ART),
		WATER_COLUMNS, WATER_ROWS)
	_hose_bounds.add_child(_water)
	_water.set_center(WATER_CENTER_IN_VIEW - hose_origin)   # (33,-71)

	_water_tip = ColorRect.new()
	_water_tip.size = TIP_SIZE
	_water_tip.color = Color(0, 0, 1)                       # blueColor
	_water_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_water_tip.visible = false
	add_child(_water_tip)

	original_hose_center = _hose_view.position
	original_clown_center = player_clown.center
	barrel_detection_frame = Rect2(barrel.position, BARREL_SIZE)

	var ai_art := Assets.texture(AI_WATER_ART)
	_ai1_water_frame = Rect2(ai_clown1.center + AI1_WATER_FROM_CLOWN
		- AI_WATER_SIZE * 0.5, AI_WATER_SIZE)
	_ai1_water = _make_ai_water(ai_art, _ai1_water_frame, true)
	_ai2_water_frame = Rect2(ai_clown2.center + AI2_WATER_FROM_CLOWN
		- AI_WATER_SIZE * 0.5, AI_WATER_SIZE)
	_ai2_water = _make_ai_water(ai_art, _ai2_water_frame, false)

	# The second WS_hose.png, centred in hoseIV's bounds, above the water.
	var hose_copy := Sprite2D.new()
	hose_copy.texture = Assets.texture(HOSE_ART)
	hose_copy.centered = true
	hose_copy.position = HOSE_BOUNDS * 0.5
	_hose_bounds.add_child(hose_copy)

	_sprite_timer = Timer.new()
	_sprite_timer.wait_time = SPRITE_TICK
	_sprite_timer.one_shot = false
	_sprite_timer.timeout.connect(_sprite_tick)
	add_child(_sprite_timer)


func _make_clown(arts: Array, clown_art: String) -> ClownView:
	var c := ClownView.new()
	c.init_with_balloon_image_clown_image(arts[0], Assets.texture(clown_art))
	c.balloon.images = arts
	return c


## A 132x344 window onto the curved water sheet (a clipping UIScrollView
## whose contentOffset pages through it).
func _make_ai_water(art: Texture2D, frame: Rect2, mirrored: bool) -> Sprite2D:
	var holder := Node2D.new()
	holder.position = frame.position
	add_child(holder)
	var s := Sprite2D.new()
	s.centered = false
	s.texture = art
	s.region_enabled = true
	s.region_rect = Rect2(Vector2.ZERO, AI_WATER_SIZE)
	# The image view is mirrored about its own centre; it is exactly as wide
	# as the window, so the window shows the mirrored column.
	s.flip_h = mirrored
	holder.add_child(s)
	return s


## The generated scene has hoseIV as a bare Sprite2D at its art's top-left
## (content mode Center: the 160x300 art centred in the 58x300 frame). Give it
## a pivot at the frame's centre -- the point -center reads and writes -- in
## the same place in the draw order, with a bounds node for its subviews.
func _build_hose_view() -> void:
	var nib_sprite := outlet("hoseIV") as Sprite2D
	var tex_size := nib_sprite.texture.get_size()
	var frame_origin := nib_sprite.position - (HOSE_BOUNDS - tex_size) * 0.5
	_hose_view = Node2D.new()
	_hose_view.name = "hoseIVView"
	add_child(_hose_view)
	move_child(_hose_view, nib_sprite.get_index())
	_hose_bounds = Node2D.new()
	_hose_bounds.position = -HOSE_BOUNDS * 0.5
	_hose_view.add_child(_hose_bounds)
	nib_sprite.reparent(_hose_bounds, false)
	nib_sprite.centered = true
	nib_sprite.position = HOSE_BOUNDS * 0.5
	_hose_view.position = frame_origin + HOSE_BOUNDS * 0.5     # (160, 456)


## viewWillAppear: (0xBE88).
func _view_will_appear() -> void:
	reset_race()
	_refresh_coin_label()
	_ai1_water.visible = false
	_ai2_water.visible = false
	for n: String in ["backBtn", "prizeBtn"]:          # bringSubviewToFront:
		var b := outlet(n)
		if b != null:
			move_child(b, get_child_count() - 1)
	_set_tap_alpha(1.0)


# ======================================================================
# Buttons
# ======================================================================

## backClick: (0xEE58).
func _on_backClick() -> void:
	if is_counting_down:
		return
	CoinManager.sync_coins(true)
	Audio.play("button_press")
	Nav.back()


## coinsClick: (0xF034).
func _on_coinsClick() -> void:
	if race_started or is_counting_down:
		return
	Audio.play("store")
	Nav.push("CoinStoreViewController")


## playClick: (0xF150) -- the MORE PLAYS button.
func _on_playClick() -> void:
	if race_started or is_counting_down:
		return
	Audio.play("button_press")
	buy_hoses()


## prizeClick: (0xF1E8) -- the TOYS button.
func _on_prizeClick() -> void:
	if race_started or is_counting_down:
		return
	Audio.play("trophy_door")
	GameState.screen_args["PrizeViewController"] = {
		"prizes": PrizeManager.get_prizes_for_game(PRIZE_GAME),
		"background_file": "bg_minigame_room.png",
	}
	Nav.push("PrizeViewController")


# ======================================================================
# Touches
# ======================================================================

## _input, not _unhandled_input: the overlays the original adds (countdown,
## prize dialog) are plain UIViews, so a touch on them is forwarded up the
## responder chain to this controller's touchesBegan: -- while still keeping
## it off the buttons underneath. route_touch() reproduces UIKit's hit test.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_touch_owned = route_touch(mb.position)
			if _touch_owned:
				touches_began(mb.position)
		elif _touch_owned:
			_touch_owned = false
			touches_ended(mb.position)
	elif event is InputEventMouseMotion and _touch_owned:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			touches_moved(mm.position)


## Does a touch at `p` reach this controller's touch handlers? UIKit's hit
## test, front to back: an alert takes everything; the prize dialog view and
## the countdown overlay are full-screen UIViews that forward to the
## controller (the dialog's close button excepted); then the back and toys
## buttons (brought to front in viewWillAppear:); then the AI water scroll
## views; then the nib's other buttons. Image views, labels and the clowns
## pass touches on to the controller.
## INFERRED: a UIScrollView does not forward touchesBegan: to its next
## responder, so a touch inside either AI water view (transparent, 132x344,
## at the screen's left and right edges) never reaches touchesBegan:.
func route_touch(p: Vector2) -> bool:
	if _modal != null:
		return false
	if _dialog != null:
		for c in _dialog.get_children():
			if c is TextureButton and (c as Control).get_global_rect().has_point(p):
				return false
		return true
	if _countdown != null:
		return true
	for n: String in ["backBtn", "prizeBtn"]:
		if _over_button(n, p):
			return false
	if _ai1_water_frame.has_point(p) or _ai2_water_frame.has_point(p):
		return false
	for n: String in ["playBtn", "coinsBtn"]:
		if _over_button(n, p):
			return false
	return true


func _over_button(outlet_name: String, p: Vector2) -> bool:
	var b := outlet(outlet_name) as Control
	return b != null and b.is_visible_in_tree() and b.get_global_rect().has_point(p)


## touchesBegan:withEvent: (0xF32C).
func touches_began(p: Vector2) -> void:
	var hit := _hose_frame().has_point(p)            # CGRectContainsPoint
	if race_started:
		if hit:
			hose_grabbed = true
			_water.visible = true
			touch_offset = _hose_view.position - p
			Audio.play("button_press")
		return
	if hit:
		hose_grabbed = true
		touch_offset = _hose_view.position - p
	if not is_counting_down and not race_started:
		Audio.play("button_press")
		if hose_count < 1:
			_alert(OUT_OF_PLAYS, ["Cancel", "Buy"], _alert_clicked)
		else:
			_begin_countdown()


## The block touchesBegan: and the alert's "Yes" share: countdown, reset,
## fade the "Tap gun to start" label out ("HideTapLabel", 0.5s, linear).
func _begin_countdown() -> void:
	start_countdown()
	reset_race()
	_set_tap_alpha(1.0)
	_fade_tap_label(0.0)


## touchesMoved:withEvent: (0xF7C8). The hose follows the finger (keeping the
## grab offset, nudged 10 down), clamped into barrelDetectionView, then
## dropped another 20. Absolute, not accumulated: no 60 Hz gate needed.
func touches_moved(p: Vector2) -> void:
	if not hose_grabbed:
		return
	current_pt = p
	var f := barrel_detection_frame
	var x := clampf(current_pt.x + touch_offset.x, f.position.x, f.end.x)
	var y := clampf(current_pt.y + MOVE_Y_NUDGE + touch_offset.y, f.position.y, f.end.y)
	_hose_view.position = Vector2(x, y + MOVE_Y_DROP)


## touchesEnded:withEvent: (0xFBF4).
func touches_ended(_p: Vector2) -> void:
	current_pt = Vector2.ZERO
	if hose_grabbed:
		hose_grabbed = false
		_water.visible = race_started


## hoseIV.frame: the 58x300 nib frame around its centre.
func _hose_frame() -> Rect2:
	return Rect2(_hose_view.position - HOSE_BOUNDS * 0.5, HOSE_BOUNDS)


# ======================================================================
# Countdown
# ======================================================================

## startCountdown (0xDDA0): a clear 320x480 view (tag 3) on top of everything
## and a 1s repeating timer that carries it.
func start_countdown() -> void:
	_countdown = Control.new()
	_countdown.name = "CountdownView"
	_countdown.position = Vector2.ZERO
	_countdown.size = Vector2(320, 480)
	_countdown.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_countdown)
	_countdown_tag = COUNTDOWN_FROM
	is_counting_down = true
	_countdown_timer = Timer.new()
	_countdown_timer.wait_time = COUNTDOWN_TICK
	_countdown_timer.one_shot = false
	_countdown_timer.timeout.connect(_countdown_tick)
	add_child(_countdown_timer)
	_countdown_timer.start()


## countdownTick: (0xDED0): 3, 2, 1 with countdown_tick, then Go with
## countdown_end; each image fades in over 0.25s; startGame: 1s after Go.
func _countdown_tick() -> void:
	var view := _countdown
	if view == null:
		return
	for c in view.get_children():
		c.queue_free()
	var art: String
	if _countdown_tag < 1:
		Audio.play("countdown_end")
		art = "Mini_G_Go.png"
	else:
		art = "Mini_G_%d.png" % _countdown_tag
		Audio.play("countdown_tick")
	var tex := Assets.texture(art)
	var iv := TextureRect.new()
	iv.texture = tex
	iv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	iv.position = COUNTDOWN_CENTER - tex.get_size() * 0.5
	iv.modulate.a = 0.0
	view.add_child(iv)
	create_tween().tween_property(iv, "modulate:a", 1.0, COUNTDOWN_FADE)
	if _countdown_tag <= 0:
		_countdown_timer.stop()
		_countdown_timer.queue_free()
		_countdown_timer = null
		get_tree().create_timer(START_GAME_DELAY).timeout.connect(_start_game.bind(view))
	else:
		_countdown_tag -= 1


## startGame: (0xE1C4).
func _start_game(view: Control) -> void:
	if is_instance_valid(view):
		view.queue_free()
	if _countdown == view:
		_countdown = null
	is_counting_down = false
	if hose_grabbed:
		_water.visible = true
	reset_race()
	start_race()


# ======================================================================
# The race
# ======================================================================

## resetRace (0xC5A8).
func reset_race() -> void:
	race_started = false
	_water.visible = false
	_hose_view.position = original_hose_center
	for c: ClownView in [player_clown, ai_clown1, ai_clown2]:
		c.balloon.reset()
	for c: ClownView in [player_clown, ai_clown1, ai_clown2]:
		c.remove_all_animations()
	for c: ClownView in [player_clown, ai_clown1, ai_clown2]:
		c.resume_layer()
	for c: ClownView in [player_clown, ai_clown1, ai_clown2]:
		c.balloon.position = c.original_balloon_center


## startRace (0xC830).
func start_race() -> void:
	if race_started:
		return
	Audio.loop("spray_loop")
	Audio.play("spray_start")
	race_started = true
	set_hose_count(hose_count - 1)
	p_balloon = 0.0
	ai_balloon1 = 0.0
	ai_balloon2 = 0.0
	_water.visible = true
	_ai1_water.visible = true
	_ai2_water.visible = true
	var r_win := randi()
	ai1_will_win = randi() % 2 == 1
	should_ai_win = r_win % 100 < AI_WIN_PERCENT
	last_hit_msec = Time.get_ticks_msec()
	if should_ai_win:
		ai1_will_win = randi() % 2 == 1
		if ai1_will_win:
			ai1_pop_time = float((randi() & 7) + 12)
			ai2_pop_time = float((randi() & 15) + 24)
			player_pop_time = _f32(float(randi() % 12) + ai1_pop_time)
		else:
			ai1_pop_time = float((randi() & 15) + 24)
			ai2_pop_time = float((randi() & 7) + 12)
			player_pop_time = _f32(float(randi() % 12) + ai2_pop_time)
	else:
		if ai1_will_win:
			ai1_pop_time = 20.0           # 0x41A00000
			ai2_pop_time = 40.0
		else:
			ai1_pop_time = 40.0           # 0x42200000
			ai2_pop_time = 20.0
		player_pop_time = float((randi() & 7) + 11)
	_sprite_timer.start()
	move_clown()


## moveClown (0xD9F8): a 30-leg random wander around the clown's home,
## 50-69s per pass, linear, autoreversing, repeating for ever.
## INFERRED: the path's last element, CGPathMoveToPoint to the clown's frame
## ORIGIN, starts no segment and defines no keyframe, so it is dropped. It
## could only matter after the first full pass (50s+), which a race reaches
## only if the player keeps hitting at intervals under 3.5s for that long.
func move_clown() -> void:
	if not race_started:
		return
	var pts := PackedVector2Array([original_clown_center])
	var w := int(barrel_detection_frame.size.x)
	for i in CLOWN_PATH_POINTS:
		var dx := float((randi() % w) >> 1)
		if randi() & 1:
			dx = -dx
		var dy := float(randi() % CLOWN_Y_SPAN)
		if randi() & 1:
			dy = -dy
		pts.append(original_clown_center + Vector2(dx, dy))
	var secs := float(randi() % CLOWN_SECONDS_SPAN + CLOWN_SECONDS_MIN)
	player_clown.resume_layer()
	player_clown.remove_all_animations()
	player_clown.add_position_animation(pts, secs, true)


## spriteTick (0xE378).
func _sprite_tick() -> void:
	var hose_c := _hose_view.position
	_water_tip.position = hose_c + TIP_FROM_HOSE - TIP_SIZE * 0.5
	var k := randi() % AI_WATER_FRAMES
	if _water.current_frame_idx >= WATER_FRAMES_USED:
		_water.current_frame_idx = 0
	_water.tick()
	var ai_offset := Vector2(0, float(int(AI_WATER_SIZE.y) * k))
	_ai1_water.region_rect = Rect2(ai_offset, AI_WATER_SIZE)
	_ai2_water.region_rect = Rect2(ai_offset, AI_WATER_SIZE)

	if race_started:
		var mouth := player_clown.presented_mouth_rect()
		var tip := Rect2(_water_tip.position, TIP_SIZE)
		if tip.intersects(mouth, true):                  # CGRectIntersectsRect
			# [playerDict objectForKey:@"inflate_loop"] == nil -> loop it;
			# Audio.loop() is already a no-op while that loop exists.
			Audio.loop("inflate_loop")
			if hose_grabbed:
				last_hit_msec = Time.get_ticks_msec()
			if p_balloon >= player_pop_time:
				player_clown.balloon.pop()
				end_race()
			else:
				p_balloon = _f32(p_balloon + _f32(BALLOON_STEP))
				_inflate(player_clown, p_balloon, player_pop_time)
		else:
			Audio.stop("inflate_loop")

	if float(Time.get_ticks_msec() - last_hit_msec) / 1000.0 >= NO_HIT_SECONDS \
			and not should_ai_win:
		should_ai_win = true
		ai1_will_win = randi() & 1 == 1
	if should_ai_win or (_ratio(p_balloon, player_pop_time) > _ratio(ai_balloon1, ai1_pop_time)
			and _ratio(p_balloon, player_pop_time) > _ratio(ai_balloon2, ai2_pop_time)):
		ai_balloon1 = _f32(ai_balloon1 + _f32(BALLOON_STEP))
		ai_balloon2 = _f32(ai_balloon2 + _f32(BALLOON_STEP))
	_inflate(ai_clown1, ai_balloon1, ai1_pop_time)
	_inflate(ai_clown2, ai_balloon2, ai2_pop_time)

	if p_balloon < player_pop_time:
		var popped := false
		if ai_balloon1 >= ai1_pop_time:
			ai_clown1.balloon.pop()
			popped = true
		if not popped:
			if ai_balloon2 < ai2_pop_time:
				return
			ai_clown2.balloon.pop()
		end_race()


## setTransform: scale(1 + amount/popTime), then setCenter: so the bottom
## edge stays at BALLOON_BOTTOM.
func _inflate(c: ClownView, amount: float, pop_time: float) -> void:
	var s := _f32(_ratio(amount, pop_time) + 1.0)
	var b := c.balloon
	b.scale = Vector2(s, s)
	b.position = Vector2(b.position.x, -b.frame_height() * 0.5 + BALLOON_BOTTOM)


static func _ratio(amount: float, pop_time: float) -> float:
	return _f32(amount / pop_time)


## The original's ivars are 32-bit floats; GDScript's are doubles.
static func _f32(x: float) -> float:
	var a := PackedFloat32Array([x])
	return a[0]


## endRace (0xCCC8).
func end_race() -> void:
	Audio.stop("inflate_loop")
	Audio.stop("spray_loop")
	Audio.play("pop")
	hose_grabbed = false
	_water.visible = false
	_hose_view.position = original_hose_center
	_invalidate_sprite_timer()
	for c: ClownView in [player_clown, ai_clown1, ai_clown2]:
		c.pause_layer()
	_ai1_water.visible = false
	_ai2_water.visible = false
	_set_tap_alpha(0.0)
	_fade_tap_label(1.0)                               # "ShowTapLabel"
	if p_balloon >= player_pop_time:
		_show_prize_dialog()
		_delay_startup_emitter_balloons()
		Audio.play("fanfare")
	else:
		reset_race()
		Audio.play("aww")


func _invalidate_sprite_timer() -> void:
	if _sprite_timer != null:
		_sprite_timer.stop()


func _set_tap_alpha(a: float) -> void:
	if _tap_tween != null and _tap_tween.is_valid():
		_tap_tween.kill()
	if _tap_label != null:
		_tap_label.modulate.a = a


func _fade_tap_label(to: float) -> void:
	if _tap_label == null:
		return
	_tap_tween = create_tween()
	_tap_tween.tween_property(_tap_label, "modulate:a", to, TAP_LABEL_FADE)


# ======================================================================
# Winning
# ======================================================================

## endRace's win branch: the prize dialog (UIView 0,0,320,480, tag 1000000).
## A full-screen Control: it keeps taps off the nib's buttons as the UIView
## does; route_touch() still hands them to touches_began.
func _show_prize_dialog() -> void:
	var prize: Variant = PrizeManager.get_random_prize_game(true, PRIZE_GAME)
	PrizeManager.unlock_prize(prize)

	_dialog = Control.new()
	_dialog.name = "PrizeDialog_%d" % DIALOG_TAG
	_dialog.position = Vector2.ZERO
	_dialog.size = Vector2(320, 480)
	_dialog.mouse_filter = Control.MOUSE_FILTER_STOP

	var popup := TextureRect.new()
	popup.texture = Assets.texture("prize_popup.png")
	popup.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dialog.add_child(popup)

	var prize_tex := _prize_texture(PrizeManager.get_prize_image(prize))
	var prize_iv := TextureRect.new()
	prize_iv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if prize_tex != null:
		prize_iv.texture = prize_tex
		prize_iv.position = PRIZE_CENTER - prize_tex.get_size() * 0.5
	_dialog.add_child(prize_iv)

	var close := TextureButton.new()
	close.texture_normal = Assets.texture("daily_login_btn.png")
	close.ignore_texture_size = true
	close.stretch_mode = TextureButton.STRETCH_SCALE   # setBackgroundImage
	close.size = CLOSE_SIZE
	close.position = CLOSE_CENTER - CLOSE_SIZE * 0.5
	close.pressed.connect(_close_prize_dialog)
	_dialog.add_child(close)

	var plate_tex := Assets.texture("prize_label.png")
	var plate := TextureRect.new()
	plate.texture = plate_tex
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.position = PRIZE_LABEL_CENTER - plate_tex.get_size() * 0.5
	_dialog.add_child(plate)

	var name_label := Label.new()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER  # alignment 1
	UILabelFrame.set_frame(name_label, Rect2(Vector2(plate_tex.get_size().x * 0.5,
		NAME_Y) - NAME_SIZE * 0.5, NAME_SIZE))
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := SystemFont.new()
	font.font_names = PackedStringArray(FONT_NAMES)
	name_label.add_theme_font_override("font", font)
	name_label.add_theme_color_override("font_color", Color.BLACK)
	var prize_name: Variant = PrizeManager.get_prize_name(prize)
	name_label.text = "" if prize_name == null else str(prize_name)
	name_label.add_theme_font_size_override("font_size",
		_fit_font_size(font, name_label.text, NAME_SIZE.x, NAME_FONT_SIZE,
			NAME_MIN_FONT_SIZE))
	plate.add_child(name_label)

	# transform scale 0.01 -> identity, "Show_Upgrade_Dialog", 0.5s, curve 3.
	_dialog.pivot_offset = _dialog.size * 0.5
	_dialog.scale = Vector2(DIALOG_START_SCALE, DIALOG_START_SCALE)
	create_tween().tween_property(_dialog, "scale", Vector2.ONE,
		DIALOG_POP_SECONDS)
	# "Show_Upgrade_Dialog" is +beginAnimations:/commitAnimations (endRace
	# 0xCCC8): UIKit hit-tests the container at its MODEL transform,
	# identity from the commit, so it keeps taps off the nib's buttons from
	# the first frame of the pop-in. Godot hit-tests `_dialog` through its
	# 0.01 -> 1 scale, so an unscaled blocker under it stands in for the
	# model frame (as wm_hitmole / mb_ThrowBallVC already do); without it
	# back / toys / play answered under the growing dialog.
	# route_touch() already treats the dialog as
	# full-screen. PORT CHOICE: the close button is hit where it is drawn.
	var blocker := Control.new()
	blocker.name = "PrizeDialogBlocker"
	blocker.size = Vector2(320, 480)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(blocker)
	_dialog.tree_exiting.connect(blocker.queue_free)
	add_child(_dialog)


## UILabel adjustsFontSizeToFitWidth YES: the largest size from `from` down
## to `min_size` whose text fits `width`.
## PORT CHOICE: whole point sizes; UIKit shrinks continuously.
static func _fit_font_size(font: Font, text: String, width: float, from: int,
		min_size: int) -> int:
	var fs := from
	while fs > min_size and \
			font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width:
		fs -= 1
	return fs


## getPrizeImage: hands back a UIImage in the original; accept whatever the
## PrizeManager port returns for it.
func _prize_texture(v: Variant) -> Texture2D:
	if v is Texture2D:
		return v
	if v is Image:
		return ImageTexture.create_from_image(v)
	if v is String and v != "":
		return Assets.texture(v)
	return null


## delayStartupEmitterBalloons (0xD6F0): the 13 cookie views jump below the
## screen, come to the front (above the prize dialog) and rise off the top,
## spreading away from x=160. UIView animation "Fall", curve 1 (ease-in),
## (rand()%100)/100 + 1.5 s. No particle system is involved.
func _delay_startup_emitter_balloons() -> void:
	for s in _falling_cookies:
		s.position = Vector2(randi() % COOKIE_X_RANGE + COOKIE_X_MIN,
			randi() % COOKIE_Y_RANGE + COOKIE_Y_MIN)
		move_child(s, get_child_count() - 1)
		var secs := float(randi() % 100) / 100.0 + COOKIE_BASE_SECONDS
		var c := s.position
		var to := Vector2(c.x + 2.0 * (c.x + COOKIE_SPREAD_PIVOT), c.y + COOKIE_RISE)
		create_tween().tween_property(s, "position", to, secs) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	Audio.play("cheer")


## closePrizeDialog: (0xD56C).
func _close_prize_dialog() -> void:
	Audio.play("button_press")
	if _dialog != null:
		_dialog.queue_free()
		_dialog = null
	reset_race()


# ======================================================================
# Plays, coins
# ======================================================================

## buyHoses (0xFD24).
func buy_hoses() -> bool:
	if CoinManager.total_coins() > PLAY_PRICE - 1:
		CoinManager.spend_coins(PLAY_PRICE)
		set_hose_count(hose_count + NUM_OF_HOSES)
		return true
	show_buy_more_coins_message()
	return false


## setHoseCount: (0xFF54) -- persisted under WaterShooterCountKey on every
## change.
func set_hose_count(n: int) -> void:
	hose_count = n
	Defaults.set_integer_for_key(hose_count, KEY_HOSE_COUNT)
	Defaults.synchronize()
	_set_count_text(_hose_count_label, "%d" % hose_count)


## coinValueChanged: (0xFC8C) -- COIN_NOTIFICATION_VALUE_CHANGED.
func _coin_value_changed(total: int) -> void:
	_set_count_text(_coin_label, "%d" % total)


func _refresh_coin_label() -> void:
	_set_count_text(_coin_label, "%d" % CoinManager.total_coins())


func _set_count_text(l: Label, text: String) -> void:
	if l == null:
		return
	l.text = text


## showBuyMoreCoinsMessage (0x103C4) -> IAPlistManager
## displayMediaBrixForLocation:@"MiniGame" withMiniGame:@"Water Gun"
## (0x1757E0). With no IAPlist that call returns without showing anything.
## PORT CHOICE (as bpTossDartVC and core/Consumable.gd): show the method's own
## no-ad branch for "MiniGame" instead -- UIAlertView, empty title,
## NOT_ENOUGH_COINS, Cancel / "Get Coins"; IAPlistManager
## alertView:clickedButtonAtIndex: (0x176C44) answers "Get Coins" with the
## "store" sound and a CoinStoreViewController push.
func show_buy_more_coins_message() -> void:
	_alert(NOT_ENOUGH_COINS, ["Cancel", "Get Coins"], func(title: String) -> void:
		if title == "Get Coins":
			Audio.play("store")
			Nav.push("CoinStoreViewController"))


## alertView:clickedButtonAtIndex: (0x1001C).
func _alert_clicked(title: String) -> void:
	match title:
		"Buy":
			buy_hoses()
		"Get Coins":
			Audio.play("store")
			Nav.push("CoinStoreViewController")
		"Yes":
			Audio.play("button_press")
			if hose_count >= 1:
				_begin_countdown()
			else:
				_alert(OUT_OF_PLAYS, ["Cancel", "Buy"], _alert_clicked)
		"No":
			# A tail call; the disassembly at 0x102EC..0x10332 gives its
			# arguments, @"button_press" / @"mp3".
			Audio.play("button_press")


# ======================================================================
# UIAlertView stand-in
# ======================================================================

## The iOS 6 UIAlertView (Screen.show_alert). No click sound: a UIAlertView
## makes none of its own. `_modal` mirrors "an alert is up" for this
## screen's touch handling.
func _alert(message: String, buttons: Array, on_choice: Callable) -> void:
	# INFERRED (UIKit): an alert window cancels the touch in progress, and
	# this class has no touchesCancelled:, so touchesEnded: never runs for it
	# -- hoseGrabbed stays as the press left it.
	_touch_owned = false
	var clicked := func(title: String) -> void:
		_modal = null
		if on_choice.is_valid():
			on_choice.call(title)
	_modal = show_alert(message, buttons, clicked, false)
