# Balloon Pop (midway game, stand tag 8) -- flick a dart at a 5x5 wall of
# balloons; pop one to win a prize.
#
# From the original binary (all 65 methods walked), with every float
# argument read from the instructions. Entry points from the ObjC method list:
#   initWithNibName:bundle:          0x114FE0   viewDidLoad        0x115430
#   viewWillAppear:                  0x115864   viewDidAppear:     0x115994
#   viewDidDisappear:                0x115B14   delayStartupEmitterBalloons 0x115ED8
#   backClick:                       0x1161E0   coinsClick:        0x116368
#   playClick:                       0x116448   prizeClick:        0x116508
#   touchesBegan:withEvent:          0x116620   touchesEnded:withEvent: 0x116818
#   initBalloons                     0x1173D8   resetBalloons      0x11799C
#   resetDart                        0x117D30   buyDarts           0x117E40
#   showDart                         0x1180DC   dartIVTick         0x1182E4
#   showEndMessage                   0x1183D0   closePrizeDialog:  0x118A3C
#   endThrow                         0x118BBC
#   animationDidStop:finished:context: 0x118CE8 (UIView animations)
#   animationDidStop:finished:       0x1193D4   (CAAnimation delegate)
#   alertView:didDismissWithButtonIndex: 0x119458
#   setDartCount:                    0x1195E0   showBuyMoreCoinsMessage 0x1196A8
#   slideView:toPoint:overDuration:  0x11972C   coinValueChanged:  0x1197D8
# Helpers: BalloonView 0x124408.. (src/midway/bp_BalloonView.gd), TintedIV
# 0x46FEC / 0x47304 (src/midway/bp_TintedIV.gd), IAPlistManager
# displayMediaBrixForLocation:withMiniGame: 0x1757E0 and
# alertView:clickedButtonAtIndex: 0x176C44.
#
# THE TOSS (touchesEnded 0x116818, read instruction by instruction):
#   touchesBegan stamps tossDate if the touch lands in dartIV.frame, no prize
#   dialog (tag 1000000) is up and no dart is in the air.
#   touchesEnded throws only if tossDate is set, the release is ABOVE
#   dartIV.frame's top edge, dartCount >= 1, no dialog, no dart in the air.
#     dist  = |release - dartIV.center|           (float sqrt of doubles)
#     angle = asin(|dx| / dist), negated when the release is left of centre
#     speed = dist / (now - tossDate), clamped to [500, 3000]
#     h     = speed / 6.25                        (80 .. 480)
#     dur   = h / (speed * 0.25)                  (= 0.64s, always)
#     xoff  = tan(angle) * (h + 480 - center.y)
#     end   = (center.x + xoff, 480 - h)
#     ctrl  = (center.x + xoff/2, 480 - h - 100)
#   The hit is decided NOW: the dart is parked at `end`, scaled 0.4, and its
#   hidden 10x10 dartTip (centre (49,80) in the 100x100 dartIV) is tested
#   against every visible balloon, rows top to bottom -- CGRectIntersectsRect
#   on the frames, then CGPathContainsPoint on the balloon outline. Then the
#   dart is put back and animated: UIView "ScaleDart" 1 -> 0.4 (linear, dur),
#   CAKeyframeAnimation "MoveDart" along the quad curve (dur, fill forwards),
#   and a dartIVTick timer at dur/4 flipping bp_dart_01..04. One throw in
#   three that hits (arc4random()%100 <= 32) bounces off instead of popping.
#   The wall-clock press->release time IS the throw strength: ported as is.
#
# OFFLINE STATE: IAPlistManager.iaplistDict only ever comes from Sunstorm's
# server (connectionDidFinishLoading: 0x17625C, cached in Documents); nothing
# ships in the bundle. So NUM_OF_DARTS takes its coded fallback 8, and
# showBuyMoreCoinsMessage's ad call finds no "Advertising" key -- see
# show_buy_more_coins_message() for the PORT CHOICE there.
#
# NOT PORTED (no visible effect): every +[DataLogging ...] call and the
# analytics-only defaults they feed ("uniqueToss", "dateArcFlag",
# "startArcDate", "endArcDate", "playedArcFlag"); backClick:'s interstitial
# (skipped under FF_KEY_EVERYTHING, the port's permanent state); the iPad
# flag set in viewWillAppear: (ipad2x, never read); instIV (no nib outlet --
# the viewDidAppear: slide messages nil).

extends "res://core/Screen.gd"
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const BalloonView := preload("res://midway/bp_BalloonView.gd")
const TintedIV := preload("res://midway/bp_TintedIV.gd")


# -- initWithNibName:bundle: (0x114FE0) ---------------------------------

const DART_IMAGES := ["bp_dart_01.png", "bp_dart_02.png", "bp_dart_03.png",
	"bp_dart_04.png"]
## [[IAPlist GameData] BalloonPurchase] intValue, 0 -> 8. No IAPlist exists
## without the server, so it is always the fallback.
const NUM_OF_DARTS := 8
## fallingCookies: one 80x80 UIImageView each, contentMode 1 (aspect fit),
## parked at centre (-999,-999), added to the view above every nib view.
const COOKIE_ART := ["circus_ballbubble.png", "circus_clownbubble.png",
	"circus_greenbubble.png", "circus_pinkbubble.png",
	"circus_yellowbubble.png", "circus_yellowbubble.png",
	"circus_pinkbubble.png", "circus_greenbubble.png",
	"Star_Emitters_End_Game_PS_1.png", "Star_Emitters_End_Game_PS_2.png",
	"Star_Emitters_End_Game_PS_3.png", "Star_Emitters_End_Game_PS_4.png",
	"Star_Emitters_End_Game_PS_5.png"]
const COOKIE_BOX := 80.0
const COOKIE_PARK := Vector2(-999, -999)

# -- viewDidLoad (0x115430), showDart (0x1180DC), slideView (0x11972C) --

## The nib's dartIV is a 100x100 UIView (frame (110,366,100,100), content
## mode Center) -- its image is drawn centred in it.
const DART_BOUNDS := Vector2(100, 100)
## dartTip: UIView (0,0,10,10), centre (49,80) in dartIV, black, HIDDEN.
const TIP_CENTER := Vector2(49, 80)
const TIP_SIZE := Vector2(10, 10)
## centre.x + 500, then slide back over 0.25s, UIViewAnimationCurveLinear (3).
const DART_OFFSTAGE := 500.0
const SLIDE_SECONDS := 0.25

# -- touchesEnded:withEvent: (0x116818) -----------------------------------

const SPEED_MIN := 500.0
const SPEED_MAX := 3000.0
const HEIGHT_DIV := 6.25
const DURATION_K := 0.25
const FLOOR_Y := 480.0
const APEX_RAISE := -100.0
const FLIGHT_SCALE := 0.4            # CGAffineTransformMakeScale 0x3ECCCCCD
const BOUNCE_PERCENT := 32           # arc4random() % 100 <= 0x20

# -- animationDidStop:finished:context: (0x118CE8) ------------------------

const BOUNCE_DROP := 50.0
const BOUNCE_CTRL_X := 25.0
const BOUNCE_OUT_X := 60.0
const BOUNCE_END_Y := 500.0
const BOUNCE_SECONDS := 0.699999988  # setDuration: double 0x3FE6666660000000
const BOUNCE_TILT_LEFT := -0.17453   # dart end left of / at balloon centre
const BOUNCE_TILT_RIGHT := 3.3161
const SPIN := 15.708                 # RotateDart concat +-15.708 rad
const SPIN_SECONDS := 0.5

# -- initBalloons (0x1173D8) / resetBalloons (0x11799C) -------------------

## dword table at 0x682AD0, 5 ints per row, indexed by the row's position in
## [row1, row2, row3, row4, row5] (row1 is the bottom row, y 298).
const BALLOON_TAGS := [
	[1, 1, 1, 1, 1],
	[1, 2, 2, 2, 1],
	[1, 2, 3, 2, 1],
	[1, 2, 2, 2, 1],
	[1, 1, 1, 1, 1],
]
## arc4random() % 100 per balloon: tag 3 always shows, tag 2 when <= 0x54,
## tag 1 when <= 0x45.
const SHOW_TAG2_MAX := 84
const SHOW_TAG1_MAX := 69
## [UIColor redColor], greenColor, blueColor; TintedIV blend mode 9.
const TINTS := [Color(1, 0, 0), Color(0, 1, 0), Color(0, 0, 1)]
const TINT_MODE := 9
const BALLOON_ART := ["bp_balloon.png", "bp_balloon_popping.png",
	"bp_balloon_popped.png"]

# -- showEndMessage (0x1183D0) -------------------------------------------

const DIALOG_TAG := 1000000
const DIALOG_POP_SECONDS := 0.5      # scale 0.01 -> identity, curve 3 (linear)
const DIALOG_START_SCALE := 0.01
const PRIZE_CENTER := Vector2(160, 240)    # 0x43200000 / 0x43700000 (disasm)
const CLOSE_SIZE := Vector2(94, 63)
const CLOSE_CENTER := Vector2(160, 400)
const PRIZE_LABEL_CENTER := Vector2(160, 355)
const NAME_SIZE := Vector2(74, 14)
const NAME_Y := 16.0                       # centre (prize_label.w * 0.5, 16)
const NAME_FONT_SIZE := 12
const NAME_MIN_FONT_SIZE := 6
const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans",
	"Liberation Sans", "Arial"]

# -- delayStartupEmitterBalloons (0x115ED8) -------------------------------

const COOKIE_X_RANGE := 200
const COOKIE_X_MIN := 60
const COOKIE_Y_RANGE := 50
const COOKIE_Y_MIN := 520
const COOKIE_RISE := -650.0
const COOKIE_SPREAD_PIVOT := -160.0  # x' = x + 2 * (x - 160)
const COOKIE_BASE_SECONDS := 1.5

# -- buyDarts (0x117E40) --------------------------------------------------

const DART_PRICE := 5                # totalCoins > 4, spendCoins:5

const OUT_OF_DARTS := "You are out of darts. Would you like to buy more?"
const NOT_ENOUGH_COINS := "You do not have enough coins. Would you like to buy more?"

# -- state (ivars) ---------------------------------------------------------

var dart_count := 0
var is_dart_in_air := false
var should_bounce := false
var dart_tick := 0
var dart_end_point := Vector2.ZERO
var original_dart_center := Vector2.ZERO
var popped_balloon: Node2D = null
## tossDate, as Time.get_ticks_usec(); -1 is nil.
var toss_usec := -1

var _dart_images: Array[Texture2D] = []
var _rows: Array[Node2D] = []        # [row1 .. row5]
var _falling_cookies: Array[Sprite2D] = []
var _coin_label: Label
var _dart_count_label: Label

## dartIV's UIView: position = its centre, scale/rotation = its transform.
var _dart_view: Node2D
var _dart_sprite: Sprite2D
## UIKit's MODEL values for dartIV (what -center / -frame / -transform
## return), which the visuals lag behind during animations. touchesBegan /
## touchesEnded read these, exactly as the original reads the model layer.
var _model_center := Vector2.ZERO
var _model_scale := 1.0
var _model_rotation := 0.0

var _move_tween: Tween               # "MoveDart" / "BounceDart" (CA position)
var _move_done: Callable             # BounceDart's animationDidStop:finished:
var _scale_tween: Tween              # "ScaleDart"
var _rotate_tween: Tween             # "RotateDart"
var _slide_tween: Tween              # "SlideView"
var _dart_timer: Timer

var _dialog: Control = null          # the tag-1000000 prize view
var _modal: CanvasLayer = null       # a UIAlertView is up


func on_enter() -> void:
	_init_with_nib()
	_view_will_appear()
	_view_did_appear()


## coinsClick: (0x116368), prizeClick: (0x116508) and the Get Coins alert
## PUSH over this controller; UINavigationController keeps it alive, so the
## wall's colours (initBalloons, viewDidLoad -- once), the dart count and a
## prize dialog left open are all still there on return. Nav keeps this
## instance and calls on_resume() instead of rebuilding it.
func keeps_state_on_push() -> bool:
	return true


## Back on top: viewWillAppear: (0x115864) re-rolls which balloons show
## (resetBalloons -- visibility only, the colours stay) and refreshes the
## coin label; viewDidAppear: (0x115994) re-slides the dart in when there are
## darts. Both run on every appearance in the original, this one included.
func on_resume() -> void:
	_view_will_appear()
	_view_did_appear()


func on_exit() -> void:
	# viewDidDisappear: (0x115B14) -- invalidates dartTimer, nothing else.
	_invalidate_dart_timer()


# ======================================================================
# Life cycle
# ======================================================================

## initWithNibName:bundle: (0x114FE0). Its `[self view]` inside the cookie
## loop is what loads the nib, so viewDidLoad runs before any cookie is added
## -- the 13 cookie views end up above every nib view.
func _init_with_nib() -> void:
	for n: String in DART_IMAGES:
		_dart_images.append(Assets.texture(n))
	dart_count = Defaults.integer_for_key("DartCount")
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


## viewDidLoad (0x115430).
func _view_did_load() -> void:
	for n: String in ["row1", "row2", "row3", "row4", "row5"]:
		_rows.append(outlet(n) as Node2D)
	_coin_label = outlet("coinLabel") as Label
	_dart_count_label = outlet("dartCountLabel") as Label
	# Both labels: adjustsFontSizeToFit YES (minimum 6 pt), default
	# truncate-tail, clipsToBounds -- the "NO" read here before came from the
	# swapped NIBArchive bool tags. The generated Labels carry all of it
	# (core/NibLabel.gd + clip_text / ellipsis in the scene).
	_build_dart_view()

	_init_balloons()
	original_dart_center = _model_center
	# dartTip lives as TIP_CENTER / TIP_SIZE: it is hidden and only ever used
	# for geometry.
	_set_dart_center(_model_center + Vector2(DART_OFFSTAGE, 0))
	set_dart_count(dart_count)
	_refresh_coin_label()


## viewWillAppear: (0x115864).
func _view_will_appear() -> void:
	_reset_balloons()
	_refresh_coin_label()


## viewDidAppear: (0x115994). The instIV slide messages nil (no outlet).
func _view_did_appear() -> void:
	if dart_count >= 1:
		_reset_dart()
		_show_dart()


## The generated scene has dartIV as a bare Sprite2D at the image's top-left.
## UIKit transforms it about its 100x100 view's centre, so give it a pivot at
## that centre (same place in the draw order) and hang the image off it
## centred -- content mode Center does exactly that for any image size.
func _build_dart_view() -> void:
	_dart_sprite = outlet("dartIV") as Sprite2D
	var tex_size := _dart_sprite.texture.get_size()
	var frame_origin := _dart_sprite.position - (DART_BOUNDS - tex_size) * 0.5
	_dart_view = Node2D.new()
	_dart_view.name = "dartIVView"
	var parent := _dart_sprite.get_parent()
	parent.add_child(_dart_view)
	parent.move_child(_dart_view, _dart_sprite.get_index())
	_dart_sprite.reparent(_dart_view, false)
	_dart_sprite.centered = true
	_dart_sprite.position = Vector2.ZERO
	_model_center = frame_origin + DART_BOUNDS * 0.5          # (160, 416)
	_dart_view.position = _model_center


func _refresh_coin_label() -> void:
	if _coin_label != null:
		_coin_label.text = "%d" % CoinManager.total_coins()


# ======================================================================
# Buttons
# ======================================================================

## backClick: (0x1161E0).
func _on_backClick() -> void:
	CoinManager.sync_coins(true)
	Audio.play("button_press")
	Nav.back()


## coinsClick: (0x116368).
func _on_coinsClick() -> void:
	Audio.play("store")
	_finish_interrupted_throw()
	Nav.push("CoinStoreViewController")


## playClick: (0x116448) -- the MORE DARTS button.
func _on_playClick() -> void:
	Audio.play("button_press")
	if not is_dart_in_air and buy_darts():
		_reset_dart()
		if dart_count == NUM_OF_DARTS:
			_show_dart()


## prizeClick: (0x116508) -- the TOYS button.
func _on_prizeClick() -> void:
	GameState.screen_args["PrizeViewController"] = {
		"background_file": "bg_minigame_room.png",
		"prizes": PrizeManager.get_prizes_for_game("balloon_pop"),
	}
	_finish_interrupted_throw()
	Nav.push("PrizeViewController")
	Audio.play("trophy_door")


# ======================================================================
# Touches
# ======================================================================

## _input, not _unhandled_input: UIKit binds a touch to the view that got
## touchesBegan, so the release reaches touchesEnded wherever it lands (even
## over a button). The nib's buttons do not overlap the dart, and the one
## control that does (the prize dialog's close button) is gated by the
## original's own tag-1000000 check.
func _input(event: InputEvent) -> void:
	if _modal != null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_touches_began(mb.position)
		else:
			_touches_ended(mb.position)


## touchesBegan:withEvent: (0x116620). The applicationFrame/320 scaling is
## 1.0 (UIStatusBarHidden is YES in Info.plist).
func _touches_began(p: Vector2) -> void:
	if _dart_frame().has_point(p):
		if _dialog == null and not is_dart_in_air:
			toss_usec = Time.get_ticks_usec()


## touchesEnded:withEvent: (0x116818).
func _touches_ended(t: Vector2) -> void:
	if toss_usec >= 0 and t.y < _dart_frame().position.y and dart_count >= 1 \
			and _dialog == null and not is_dart_in_air:
		var elapsed := float(Time.get_ticks_usec() - toss_usec) / 1000000.0
		_toss(t, elapsed)
	toss_usec = -1


## The body of touchesEnded: past its guards. `elapsed` is
## [[NSDate date] timeIntervalSinceDate:tossDate].
func _toss(t: Vector2, elapsed: float) -> void:
	var plan := plan_toss(_model_center, t, elapsed)
	var end: Vector2 = plan["end"]
	var dur: float = plan["duration"]

	popped_balloon = hit_balloon(end)

	# The dart is put back (centre + identity) before the animations start;
	# the model keeps the original centre throughout the flight.
	var start := _model_center
	_set_dart_center(original_dart_center)
	_model_rotation = 0.0

	# "ScaleDart": UIView animation, curve 3 (linear), dur; its didStop
	# selector is animationDidStop:finished:context:.
	_kill(_scale_tween)
	_dart_view.scale = Vector2.ONE
	_model_scale = FLIGHT_SCALE
	_scale_tween = create_tween()
	_scale_tween.tween_property(_dart_view, "scale",
		Vector2(FLIGHT_SCALE, FLIGHT_SCALE), dur)
	_scale_tween.tween_callback(_animation_did_stop_context.bind("ScaleDart"))

	# "MoveDart": CAKeyframeAnimation on position along the quad curve,
	# linear, fill forwards, not removed on completion. It replaces any
	# running SlideView on the same key path.
	# INFERRED: Core Animation advances a single quad segment's curve
	# parameter linearly in time (kCAAnimationLinear, no timing function).
	_kill(_slide_tween)
	_animate_path(start, plan["control"], end, dur)

	dart_end_point = end

	_invalidate_dart_timer()
	_dart_timer = Timer.new()
	_dart_timer.wait_time = dur / float(_dart_images.size())
	_dart_timer.one_shot = false
	_dart_timer.timeout.connect(_dart_iv_tick)
	add_child(_dart_timer)
	_dart_timer.start()

	if randi() % 100 <= BOUNCE_PERCENT and popped_balloon != null:
		should_bounce = true
	Audio.play("toss")
	is_dart_in_air = true


## touchesEnded's arithmetic, kept pure so the driver can check it.
## `center` is dartIV.center, `t` the release point, `elapsed` seconds.
static func plan_toss(center: Vector2, t: Vector2, elapsed: float) -> Dictionary:
	var dx := absf(center.x - t.x)
	var dy := absf(center.y - t.y)
	var dist := sqrt(dx * dx + dy * dy)          # cvt.f32 of a double sqrt
	var angle := asin(dx / dist)
	if t.x < center.x:
		angle = -angle
	var speed := SPEED_MIN
	var raw := dist / elapsed if elapsed > 0.0 else INF
	if raw >= SPEED_MIN:
		speed = minf(raw, SPEED_MAX)
	var h := speed / HEIGHT_DIV
	var dur := h / (speed * DURATION_K)
	var xoff := tan(angle) * (h + (FLOOR_Y - center.y))
	var end := Vector2(center.x + xoff, FLOOR_Y - h)
	var ctrl := Vector2(center.x + xoff * 0.5, FLOOR_Y - h + APEX_RAISE)
	return {"speed": speed, "height": h, "duration": dur, "end": end,
		"control": ctrl}


## The hit test at touchesEnded 0x116D56..0x117010, with dartIV parked at
## `end` and scaled 0.4 about its centre: dartTip's frame/centre converted
## into each row / balloon. Rows in the order [row5, row4, row3, row2, row1]
## (top to bottom), balloons in subview order; first match wins.
func hit_balloon(end: Vector2) -> Node2D:
	var half := DART_BOUNDS * 0.5
	var tip_origin := end + (TIP_CENTER - TIP_SIZE * 0.5 - half) * FLIGHT_SCALE
	var tip_rect := Rect2(tip_origin, TIP_SIZE * FLIGHT_SCALE)
	var tip_point := end + (TIP_CENTER - half) * FLIGHT_SCALE
	for i in range(_rows.size() - 1, -1, -1):
		var row := _rows[i]
		for b in row.get_children():
			if not (b is BalloonView) or not (b as Node2D).visible:
				continue
			var bv := b as BalloonView
			var origin: Vector2 = row.position + bv.position
			if not Rect2(origin, bv.size).intersects(tip_rect, true):
				continue
			if BalloonView.path_contains_point(tip_point - origin):
				return bv
	return null


## dartIV.frame from the model centre/transform (the bounding box of the
## transformed 100x100 bounds).
func _dart_frame() -> Rect2:
	var c := absf(cos(_model_rotation))
	var s := absf(sin(_model_rotation))
	var ext := DART_BOUNDS * 0.5 * _model_scale * (c + s)
	return Rect2(_model_center - ext, ext * 2.0)


# ======================================================================
# Flight, pop, bounce
# ======================================================================

## dartIVTick (0x1182E4).
func _dart_iv_tick() -> void:
	if dart_tick >= _dart_images.size():
		_invalidate_dart_timer()
		dart_tick = 0
	else:
		_dart_sprite.texture = _dart_images[dart_tick]
		dart_tick += 1


## animationDidStop:finished:context: (0x118CE8) -- only "ScaleDart" acts.
func _animation_did_stop_context(animation_id: String) -> void:
	if animation_id != "ScaleDart":
		return
	if popped_balloon == null:
		Audio.play("dart_hit")
		_show_end_message()
		return
	if not should_bounce:
		popped_balloon.call("pop")
		Audio.play("pop")
		_show_end_message()
		return
	_bounce()


## The bounce branch of animationDidStop:finished:context:.
func _bounce() -> void:
	var bv := popped_balloon as BalloonView
	var row := bv.get_parent() as Node2D
	var bc: Vector2 = row.position + bv.position + bv.size * 0.5
	var e := dart_end_point
	var ctrl := Vector2(e.x, e.y + BOUNCE_DROP)
	var out_x: float
	if e.x >= bc.x:
		out_x = e.x + BOUNCE_OUT_X
		ctrl.x += BOUNCE_CTRL_X
	else:
		out_x = e.x - BOUNCE_OUT_X
		ctrl.x -= BOUNCE_CTRL_X

	_dart_sprite.texture = Assets.texture("bp_dart_side.png")
	var tilt := BOUNCE_TILT_LEFT if e.x <= bc.x else BOUNCE_TILT_RIGHT
	_model_rotation += tilt
	_dart_view.rotation = _model_rotation

	# removeAllAnimations, then "BounceDart" (0.7s keyframe, fill forwards)
	_kill(_move_tween)
	_animate_path(e, ctrl, Vector2(out_x, BOUNCE_END_Y), BOUNCE_SECONDS,
		_animation_did_stop_finished)

	# "RotateDart": UIView animation, 0.5s, curve 3, transform concat
	# R(-15.708) when the dart ended left of / at the balloon centre, else
	# R(+15.708). INFERRED: Core Animation interpolates the affine transform
	# by its decomposed angle along the SHORTEST path, the way a UIView
	# rotation to 2*pi famously does not turn at all -- so +-15.708 (5*pi
	# plus 3.7e-5) shows as a half turn the other way, not 2.5 turns.
	var spin := -SPIN if e.x <= bc.x else SPIN
	var visible_turn := wrapf(spin, -PI, PI)
	_model_rotation += spin
	_kill(_rotate_tween)
	var from_r := _dart_view.rotation
	_rotate_tween = create_tween()
	_rotate_tween.tween_property(_dart_view, "rotation", from_r + visible_turn,
		SPIN_SECONDS)
	Audio.play("bounce_off")


## animationDidStop:finished: (0x1193D4), for the "BounceDart" animation.
func _animation_did_stop_finished() -> void:
	if should_bounce:
		popped_balloon = null
		should_bounce = false
	_show_end_message()


## A CAKeyframeAnimation of `position` along MoveTo(a) QuadCurveTo(c, b):
## linear, fill forwards, not removed -- the view stays at `b` afterwards.
func _animate_path(a: Vector2, c: Vector2, b: Vector2, secs: float,
		done: Callable = Callable()) -> void:
	_kill(_move_tween)
	_move_done = done
	_dart_view.position = a
	_move_tween = create_tween()
	_move_tween.tween_method(func(s: float) -> void:
		_dart_view.position = a.lerp(c, s).lerp(c.lerp(b, s), s), 0.0, 1.0, secs)
	if done.is_valid():
		_move_tween.tween_callback(done)


# ======================================================================
# End of a throw
# ======================================================================

## showEndMessage (0x1183D0).
func _show_end_message() -> void:
	if popped_balloon == null:
		Audio.play("aww")
		_end_throw()
		return

	var prize: Variant = PrizeManager.get_random_prize_game(true, "balloon_pop")
	PrizeManager.unlock_prize(prize)

	# UIView (0,0,320,480), tag 1000000. A full-screen Control: it swallows
	# taps meant for the nib's buttons, as the UIView does.
	_dialog = Control.new()
	_dialog.name = "PrizeDialog_%d" % DIALOG_TAG
	_dialog.position = Vector2.ZERO
	_dialog.size = Vector2(320, 480)
	_dialog.mouse_filter = Control.MOUSE_FILTER_STOP
	# "Show_Upgrade_Dialog" is +beginAnimations:/commitAnimations (0x1183D0):
	# UIKit hit-tests the container at its MODEL transform -- identity from
	# the commit -- so it is full-screen and swallowing from the first frame
	# of the pop-in. Only the drawing scales: the art lives in an inner
	# Control and `_dialog` itself stays 320x480. (Scaling `_dialog` shrank
	# the blocker to a dot, and the nav buttons answered under the growing
	# dialog for most of the 0.5 s.)
	# The close button is still hit where it is drawn while it grows
	# (UIKit: at its full model frame) -- PORT CHOICE, Godot hit-tests Controls
	# through their transform.
	var art := Control.new()
	art.name = "Art"
	art.size = _dialog.size
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dialog.add_child(art)

	var popup := TextureRect.new()
	popup.texture = Assets.texture("prize_popup.png")
	popup.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.add_child(popup)

	var prize_tex := _prize_texture(PrizeManager.get_prize_image(prize))
	var prize_iv := TextureRect.new()
	prize_iv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if prize_tex != null:
		prize_iv.texture = prize_tex
		prize_iv.position = PRIZE_CENTER - prize_tex.get_size() * 0.5
	art.add_child(prize_iv)

	var close := TextureButton.new()
	close.texture_normal = Assets.texture("daily_login_btn.png")
	close.ignore_texture_size = true
	close.stretch_mode = TextureButton.STRETCH_SCALE   # setBackgroundImage
	close.size = CLOSE_SIZE
	close.position = CLOSE_CENTER - CLOSE_SIZE * 0.5
	close.pressed.connect(_close_prize_dialog)
	art.add_child(close)

	var plate_tex := Assets.texture("prize_label.png")
	var plate := TextureRect.new()
	plate.texture = plate_tex
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.position = PRIZE_LABEL_CENTER - plate_tex.get_size() * 0.5
	art.add_child(plate)

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
		_fit_font_size(font, name_label.text))
	plate.add_child(name_label)

	# transform scale 0.01 -> identity, "Show_Upgrade_Dialog", 0.5s, curve 3.
	art.pivot_offset = art.size * 0.5
	art.scale = Vector2(DIALOG_START_SCALE, DIALOG_START_SCALE)
	create_tween().tween_property(art, "scale", Vector2.ONE,
		DIALOG_POP_SECONDS)
	add_child(_dialog)

	_delay_startup_emitter_balloons()
	Audio.play("fanfare")


## UILabel adjustsFontSizeToFitWidth YES, minimumFontSize 6, from size 12.
func _fit_font_size(font: Font, text: String) -> int:
	var fs := NAME_FONT_SIZE
	while fs > NAME_MIN_FONT_SIZE and \
			font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > NAME_SIZE.x:
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


## delayStartupEmitterBalloons (0x115ED8): the 13 cookie views jump below
## the screen, come to the front (above the prize dialog) and rise off the
## top, spreading away from x=160. UIView animation "Fall", curve 1
## (ease-in), (rand()%100)/100 + 1.5 s. No particle system is involved.
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


## closePrizeDialog: (0x118A3C).
func _close_prize_dialog() -> void:
	Audio.play("button_press")
	if _dialog != null:
		_dialog.queue_free()
		_dialog = null
	_end_throw()


## endThrow (0x118BBC).
func _end_throw() -> void:
	popped_balloon = null
	toss_usec = -1
	set_dart_count(dart_count - 1)
	is_dart_in_air = false
	if dart_count <= 0:
		_alert(OUT_OF_DARTS, ["Cancel", "Buy"], _alert_did_dismiss)
	else:
		_reset_balloons()
		_reset_dart()
		_show_dart()


## alertView:didDismissWithButtonIndex: (0x119458). Its "Get Coins" branch
## is unreachable from this screen's only alert (Cancel / Buy) but ported.
func _alert_did_dismiss(title: String) -> void:
	if title == "Buy":
		if buy_darts():
			_reset_dart()
			_show_dart()
			_reset_balloons()
	elif title == "Get Coins":
		Audio.play("store")
		Nav.push("CoinStoreViewController")


# ======================================================================
# Darts, coins, balloons
# ======================================================================

## buyDarts (0x117E40).
func buy_darts() -> bool:
	if CoinManager.total_coins() > DART_PRICE - 1:
		CoinManager.spend_coins(DART_PRICE)
		set_dart_count(dart_count + NUM_OF_DARTS)
		_refresh_coin_label()
		return true
	show_buy_more_coins_message()
	return false


## showBuyMoreCoinsMessage (0x1196A8) -> IAPlistManager
## displayMediaBrixForLocation:@"MiniGame" withMiniGame:@"Balloon Pop"
## (0x1757E0). With no IAPlist that call returns without showing anything.
## PORT CHOICE (same as core/Consumable.gd's not-enough-coins path): show the
## method's own no-ad branch for "MiniGame" instead -- UIAlertView, empty
## title, NOT_ENOUGH_COINS, Cancel / "Get Coins"; IAPlistManager
## alertView:clickedButtonAtIndex: (0x176C44) answers "Get Coins" with the
## "store" sound and a CoinStoreViewController push.
func show_buy_more_coins_message() -> void:
	_alert(NOT_ENOUGH_COINS, ["Cancel", "Get Coins"], func(title: String) -> void:
		if title == "Get Coins":
			Audio.play("store")
			Nav.push("CoinStoreViewController"))


## setDartCount: (0x1195E0) -- persisted under "DartCount" on every change.
func set_dart_count(n: int) -> void:
	dart_count = n
	Defaults.set_integer_for_key(dart_count, "DartCount")
	Defaults.synchronize()
	if _dart_count_label != null:
		_dart_count_label.text = "%d" % dart_count


## resetDart (0x117D30).
func _reset_dart() -> void:
	_kill(_move_tween)
	_kill(_scale_tween)
	_kill(_rotate_tween)
	_kill(_slide_tween)
	_invalidate_dart_timer()
	_model_scale = 1.0
	_model_rotation = 0.0
	_dart_view.scale = Vector2.ONE
	_dart_view.rotation = 0.0
	_set_dart_center(original_dart_center)
	_dart_sprite.texture = _dart_images[0]
	dart_tick = 0


## A throw still in flight when coinsClick:/prizeClick: push (nothing guards
## them). Out of the tree the port's tweens would pause, and on return
## viewDidAppear:'s resetDart would kill them -- leaving isDartInAir set for
## good (playClick: and every toss check it).
## INFERRED: UIKit does not hold a covered controller's animations for it --
## they end, and their didStop messages are still sent.
## animationDidStop:finished:context: (0x118CE8) never reads `finished`, so the
## "ScaleDart" stop resolves the throw (dart_hit / pop / bounce, then
## showEndMessage) exactly as on a completed flight; BounceDart's
## animationDidStop:finished: (0x1193D4) likewise. Delivered at the push,
## the same policy as fbtThrowballVC / mb_ThrowBallVC.
func _finish_interrupted_throw() -> void:
	for _guard in 4:
		if _scale_tween != null and _scale_tween.is_valid():
			_kill(_scale_tween)
			_dart_view.scale = Vector2(_model_scale, _model_scale)
			_animation_did_stop_context("ScaleDart")
		elif _move_tween != null and _move_tween.is_valid() and _move_done.is_valid():
			# BounceDart. A plain MoveDart has no stop handler that acts
			# (0x1193D4 only answers BounceDart): left to finish its path.
			_kill(_move_tween)
			var done := _move_done
			_move_done = Callable()
			_kill(_rotate_tween)
			if done.is_valid():
				done.call()
		else:
			return


## showDart (0x1180DC): jump 500 right, unhide, slideView back over 0.25s.
func _show_dart() -> void:
	var home := _model_center
	_set_dart_center(home + Vector2(DART_OFFSTAGE, 0))
	_dart_view.visible = true
	_slide_view_to(home, SLIDE_SECONDS)


## slideView:toPoint:overDuration: (0x11972C) for dartIV: UIView animation,
## curve 3 (linear). The model centre takes the target at once.
func _slide_view_to(p: Vector2, secs: float) -> void:
	_kill(_slide_tween)
	_model_center = p
	_slide_tween = create_tween()
	_slide_tween.tween_property(_dart_view, "position", p, secs)


## -setCenter: with no animation: model and view move together.
func _set_dart_center(p: Vector2) -> void:
	_kill(_slide_tween)
	_kill(_move_tween)
	_model_center = p
	_dart_view.position = p


func _invalidate_dart_timer() -> void:
	if _dart_timer != null:
		_dart_timer.stop()
		_dart_timer.queue_free()
		_dart_timer = null


## initBalloons (0x1173D8): 3 tints x 3 arts baked once; 5 balloons per row
## at x = 0, 60, .. 240, each a random tint (arc4random() % 3), tagged from
## BALLOON_TAGS.
func _init_balloons() -> void:
	var sets: Array = []
	for tint: Color in TINTS:
		var arts: Array = []
		for n: String in BALLOON_ART:
			arts.append(TintedIV.bake(Assets.texture(n), tint, TINT_MODE))
		sets.append(arts)
	for i in _rows.size():
		var row := _rows[i]
		for c in row.get_children():
			c.queue_free()
		var x := 0.0
		for k in 5:
			var arts: Array = sets[randi() % sets.size()]
			var b := BalloonView.new()
			b.init_with_balloon_image(arts[0])
			row.add_child(b)
			b.images = arts
			b.position = Vector2(x, 0)
			b.tag = BALLOON_TAGS[i][k]
			x += b.size.x


## resetBalloons (0x11799C): reset + hide every balloon, then reveal by tag.
func _reset_balloons() -> void:
	for row in _rows:
		for b in row.get_children():
			b.call("reset")
			(b as Node2D).visible = false
	for row in _rows:
		for b in row.get_children():
			if not (b is BalloonView):
				continue
			var r := randi() % 100
			var tag: int = (b as BalloonView).tag
			if tag == 3 or (tag == 2 and r <= SHOW_TAG2_MAX) \
					or (tag == 1 and r <= SHOW_TAG1_MAX):
				(b as Node2D).visible = true


# ======================================================================
# UIAlertView stand-in
# ======================================================================

## The iOS 6 UIAlertView (Screen.show_alert). No click sound: a UIAlertView
## makes none and none of this screen's handlers play one. `_modal` mirrors
## "an alert is up" for this screen's touch handling.
func _alert(message: String, buttons: Array, on_choice: Callable) -> void:
	var clicked := func(title: String) -> void:
		_modal = null
		if on_choice.is_valid():
			on_choice.call(title)
	_modal = show_alert(message, buttons, clicked, false)


func _kill(t: Tween) -> void:
	if t != null and t.is_valid():
		t.kill()
