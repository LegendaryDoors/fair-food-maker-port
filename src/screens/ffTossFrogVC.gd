# Midway game "Frog Flip" -- pull the frog back on the slingshot and fling it
# onto one of three lily pads drifting round the pond.
#
# Ported from the original binary (entry points are the ObjC method-list
# IMPs), with the data tables and every CGFloat/double argument read from the
# instructions. Every method of the class:
#
#   initWithNibName:bundle:   0x1260D8  frogCount = defaults FrogTossCountKey;
#                                       NUM_OF_FROGS = iaplist GameData/
#                                       FrogPurchase or 5; 13 "falling cookie"
#                                       UIImageViews (80x80, aspect-fit,
#                                       parked at -999,-999) added on top.
#   viewDidLoad               0x1264B4  frog.del = self; frog.minY = (int)
#                                       frog.centre.y; maxY = (int) view
#                                       height; frog flipbook Froggy_Anime_1..6;
#                                       originalFrogCenter; frogBox: hidden
#                                       black 50x60 subview of the frog,
#                                       centre (w/2, h/2 - 8) -- the landing
#                                       hit box.
#   viewWillAppear:           0x126A1C  resetLillies; coin label; hide frog,
#                                       slingshot, band.
#   viewDidAppear:            0x126B34  frogCount < 1 (or the prize dialog,
#                                       tag 10000000, is up): keep them hidden,
#                                       frog untouchable. Else resetFrog +
#                                       showFrog.
#   resetLillies(:)           0x126C54 / 0x126C68  see _reset_lillies.
#   buyFrogs                  0x127CF8  > 4 coins: spendCoins:5, frogCount +=
#                                       NUM_OF_FROGS; else
#                                       showBuyMoreCoinsMessage.
#   resetFrog                 0x127F28  see _reset_frog.
#   showFrog                  0x1281E8  slingshot assembly slides in from
#                                       +300px, "ResetFrog" linear 0.25s.
#   showEndMessage:finish:    0x1284E4  win: prize dialog; miss: "aww".
#   closePrizeDialog:         0x128C78
#   showBuyMoreCoinsMessage   0x128EE8
#   endThrow                  0x128F6C
#   delayStartupEmitterBalloons 0x1291F0
#   draggableTouchBegan/Moved/Ended:fromSender:  0x1294F8 / 0x129558 / 0x129870
#   animationDidStop:finished:context:           0x129F50
#   willBounce:               0x12AEC0
#   willNotBounce:            0x12B5E8
#   alertView:clickedButtonAtIndex: 0x12B644
#   coinValueChanged:         0x12B7FC   applicationDidBecomeActive: 0x12B894 (empty)
#   setFrogCount:             0x12B898  persists FrogTossCountKey + label.
#   backClick: 0x12B960  coinsClick: 0x12BB30  playClick: 0x12BC24
#   prizeClick: 0x12BCE8
#
# Helpers: DraggableIV -> midway/ff_Draggable.gd, LillyView ->
# midway/ff_LillyView.gd. IAPlistManager displayMediaBrixForLocation:
# withMiniGame: 0x1757E0 and its alertView:clickedButtonAtIndex: 0x176C44 were
# read for the not-enough-coins path.
#
# Left out: DataLogging (Flurry analytics) calls, the FF_KEY_EVERYTHING
# interstitial ad on back, the MediaBrix ad itself. No particles: the end
# "balloons" are plain UIImageViews with UIView animations and are ported.

extends "res://core/Screen.gd"
const UILabelFrame := preload("res://core/UILabelFrame.gd")

const Draggable := preload("res://midway/ff_Draggable.gd")
const LillyView := preload("res://midway/ff_LillyView.gd")

const LINEAR := 3          # UIViewAnimationCurveLinear
const EASE_IN := 1         # UIViewAnimationCurveEaseIn

# -- initWithNibName:bundle: (0x1260D8) ------------------------------------
const COUNT_KEY := "FrogTossCountKey"
## [[[iaplistDict GameData] FrogPurchase] intValue], 0 -> 5. The iaplist is
## downloaded from central.sunstormserver.com (no bundled copy); with no
## dictionary the lookup is 0, so the original's own fallback applies.
const NUM_OF_FROGS_FALLBACK := 5
const COOKIE_IMAGES := [
	"circus_ballbubble.png", "circus_clownbubble.png", "circus_greenbubble.png",
	"circus_pinkbubble.png", "circus_yellowbubble.png", "circus_yellowbubble.png",
	"circus_pinkbubble.png", "circus_greenbubble.png",
	"Star_Emitters_End_Game_PS_1.png", "Star_Emitters_End_Game_PS_2.png",
	"Star_Emitters_End_Game_PS_3.png", "Star_Emitters_End_Game_PS_4.png",
	"Star_Emitters_End_Game_PS_5.png",
]
const COOKIE_FRAME := Vector2(80, 80)          # contentMode 1 = aspect fit
const COOKIE_PARK := Vector2(-999, -999)

# -- nib (ffTossFrogVC) ---------------------------------------------------
const FROG_NIB_SIZE := Vector2(60, 109)        # DraggableIV frame (131,343,60,109)
const BAND_SIZE := Vector2(75, 75)             # band frame (123,354,75,75)

# -- viewDidLoad (0x1264B4) ------------------------------------------------
const FROG_IMAGES := ["Froggy_Anime_1.png", "Froggy_Anime_2.png",
	"Froggy_Anime_3.png", "Froggy_Anime_4.png", "Froggy_Anime_5.png",
	"Froggy_Anime_6.png"]
const FROG_BOX_SIZE := Vector2(50, 60)
const FROG_BOX_LIFT := 8.0
const VIEW_HEIGHT := 480.0                     # maxY = (int) view.frame.size.height

# -- resetFrog (0x127F28) --------------------------------------------------
const BAND_IMAGE := "FF_rubberband.png"
const BAND_IMAGE_SIZE := Vector2(75, 60)       # setFrame (0,0,75,60)
const BAND_IMAGE_LIFT := 25.0                  # anchor (0.5,0), centre.y - 25

# -- showFrog (0x1281E8) ---------------------------------------------------
const SLIDE_IN_OFFSET := 300.0
const SLIDE_IN_TIME := 0.25

# -- draggableTouchMoved:/Ended: (0x129558 / 0x129870) ---------------------
const BAND_STRETCH_PAD := 5.0                  # hyp + frog.frame.h/2 + 5
const BAND_RELEASED_SIZE := Vector2(75, 75)
const MIN_PULL := 20.0
const THROW_RANGE := 450.0                     # distance at a full pull
const THROW_TIME := 3.0                        # seconds at a full pull
const FLIP_SHORTEN := 0.1
const SCALE_UP := 1.5

# -- animationDidStop:finished:context: (0x129F50) -------------------------
const LILY_HIT_PERCENT := 35.0                 # overlap / frogBox area * 100
const LILY_BOUNCE_ROLL := 24                   # arc4random % 100 <= 24
const EDGE_BOUNCE_MIN := 0.4
const EDGE_BOUNCE_MAX := 0.7
const BOUNCE_DELAY := 0.20000000298            # (double)0.2f, willBounce:
const SETTLE_DELAY := 0.5                      # willNotBounce:
const SPLASH_IMAGES := ["splash01.png", "splash02.png", "splash03.png",
	"splash04.png", "splash05.png", "splash06.png", "splash07.png",
	"splash08.png", "splash09.png"]
const SPLASH_TIME := 0.5
const SPLASH_LIFT := 10.0
const FADE_TIME := 0.30000001192               # (double)0.3f, "FadeFrog"

# -- willBounce: (0x12AEC0) ------------------------------------------------
const BOUNCE_DISTANCE := 100.0
const BOUNCE_TIME := 2.0
const BOUNCE_FLIP_TIME := 1.89999997616        # (double)1.9f
const BOUNCE_SCALE_TIME := 0.66666668653       # (double)(2.0f/3)

# -- lily paths, resetLillies: (0x126C68) ----------------------------------
const LILY_PATH_TIME := 30.0
const LILY_CIRCLE_RADIUS := 100.0
const LILY_CIRCLE_FROM := [-90, -210, -330]    # dword_682BC0, degrees
const LILY_CIRCLE_TO := [270, 150, 30]         # dword_682BCC
const LILY_SQUARE_SHIFT := 10.0
## path 2: x unk_682BD8, y unk_682C44; path 3: x unk_682CB0, y unk_682D1C
const LILY_SQUARE_X2 := [
	[150, 250, 250, 250, 150, 50, 50, 50, 150],
	[250, 150, 50, 50, 50, 150, 250, 250, 250],
	[50, 50, 50, 150, 250, 250, 250, 150, 50]]
const LILY_SQUARE_Y2 := [
	[50, 50, 150, 250, 250, 250, 150, 50, 50],
	[250, 250, 250, 150, 50, 50, 50, 150, 250],
	[250, 150, 50, 50, 50, 150, 250, 250, 250]]
const LILY_SQUARE_X3 := [
	[150, 50, 50, 50, 150, 250, 250, 250, 150],
	[250, 250, 250, 150, 50, 50, 50, 150, 250],
	[50, 150, 250, 250, 250, 150, 50, 50, 50]]
const LILY_SQUARE_Y3 := [
	[50, 50, 150, 250, 250, 250, 150, 50, 50],
	[250, 150, 50, 50, 50, 150, 250, 250, 250],
	[250, 250, 250, 150, 50, 50, 50, 150, 250]]
## path 4 (a five-pointed star): x unk_682D88 + 35, y unk_682E0C + 47
const LILY_STAR_SHIFT := Vector2(35, 47)
const LILY_STAR_X := [
	[125, 154, 250, 172, 200, 125, 50, 78, 0, 96, 125],
	[200, 125, 50, 78, 0, 96, 125, 154, 250, 172, 200],
	[50, 78, 0, 96, 125, 154, 250, 172, 200, 125, 50]]
const LILY_STAR_Y := [
	[0, 90, 90, 146, 235, 180, 235, 146, 90, 90, 0],
	[235, 180, 235, 146, 90, 90, 0, 90, 90, 146, 235],
	[235, 146, 90, 90, 0, 90, 90, 146, 235, 180, 235]]
const LILY_STAR_SIZE := 50.0

# -- showEndMessage:finish: (0x1284E4) -------------------------------------
const PRIZE_GAME := "frogtoss"
const PRIZE_FORCE_SCALE := 20.0
const PRIZE_CENTER := Vector2(160, 240)
const PRIZE_BUTTON_SIZE := Vector2(94, 63)
const PRIZE_BUTTON_CENTER := Vector2(160, 400)
const PRIZE_LABEL_CENTER := Vector2(160, 355)
const PRIZE_NAME_SIZE := Vector2(74, 14)
const PRIZE_NAME_Y := 16.0
const PRIZE_NAME_FONT := 12
const PRIZE_NAME_MIN_FONT := 6
const DIALOG_POP_TIME := 0.5
const DIALOG_START_SCALE := 0.01
const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans",
	"Liberation Sans", "Arial"]

# -- buyFrogs (0x127CF8) / alerts -------------------------------------------
const FROG_PRICE := 5
const OUT_OF_FROGS := "You are out of frogs. Would you like to buy more?"
## IAPlistManager displayMediaBrixForLocation:withMiniGame: (0x1757E0), its
## "MiniGame" branch when no brand ad is chosen.
const NOT_ENOUGH_COINS := "You do not have enough coins. Would you like to buy more?"

# -- prizeClick: (0x12BCE8) -------------------------------------------------
const PRIZE_BACKGROUND := "bg_minigame_room.png"

## ivars
var frog: Node2D                      # DraggableIV
var original_frog_center := Vector2.ZERO
var frog_count := 0
var is_frog_in_air := false
var lilly_path := 0
var falling_cookies: Array[Sprite2D] = []
var outside_bounce_count := 0
var num_of_frogs := NUM_OF_FROGS_FALLBACK

var _pool: Sprite2D
var _pool_frame := Rect2()
var _slingshot: Sprite2D
var _sling_home := Vector2.ZERO
var _band: Node2D
var _band_home := Vector2.ZERO
var _band_image: Sprite2D
var _band_image_frame := Rect2()
var _coin_label: Label
var _frog_count_label: Label
var _frog_box := Rect2()              # frogBox frame, in the frog's bounds
var _popup: Control                   # tag 10000000
var _popup_button_tag := 0
var _splash: Sprite2D                 # tag 10000001
var _touching := false
var _slide_tween: Tween
var _cookie_tweens: Array[Tween] = []
var _shown_coins := -1


func on_enter() -> void:
	_pool = outlet("pool") as Sprite2D
	_slingshot = outlet("slingshot") as Sprite2D
	_band = outlet("band") as Node2D
	_coin_label = outlet("coinLabel") as Label
	_frog_count_label = outlet("frogCountLabel") as Label
	if _pool == null or _slingshot == null or _band == null:
		push_error("ffTossFrogVC: nib outlets missing")
		return
	_pool_frame = Rect2(_pool.position, _pool.texture.get_size() * _pool.scale)
	_prepare_nib_views()
	_init_with_nib()
	_view_did_load()
	_view_will_appear()
	# viewDidAppear: follows the navigation push; the port's Nav has no
	# transition, so it runs on the next frame (same as StandSelect's glide).
	_view_did_appear.call_deferred()


## coinsClick: (0x12BB30), prizeClick: (0x12BCE8) and the Get Coins alert
## push over this controller; UINavigationController keeps it alive, so the
## frog count, an open prize dialog and everything viewDidLoad built are
## there on return. Nav keeps this instance and calls on_resume().
func keeps_state_on_push() -> bool:
	return true


## Back on top: viewWillAppear: (0x126A1C) -- resetLillies (a new random
## path), coin label, frog / slingshot / band hidden -- then viewDidAppear:
## (0x126B34), which re-slides the slingshot in when there are frogs and no
## prize dialog. Deferred one frame as in on_enter. The class has no
## viewWillDisappear:/viewDidDisappear:, so the base on_exit (nothing) stands.
## No throw can be in flight: every button is ignored while isFrogInAir.
func on_resume() -> void:
	_view_will_appear()
	_view_did_appear.call_deferred()


## The generated scene carries the nib's views but not their behaviour: the
## UIClassSwapper frog is an empty Node2D, and UIKit transforms rotate about a
## view's centre. Rebuild the frog as a DraggableIV and re-pivot the slingshot
## and band on their centres; positions and z-order stay the nib's.
func _prepare_nib_views() -> void:
	var placeholder := outlet("frog") as Node2D
	var idx := placeholder.get_index() if placeholder != null else get_child_count()
	var origin: Vector2 = placeholder.position if placeholder != null else Vector2(131, 343)
	if placeholder != null:
		remove_child(placeholder)
		placeholder.free()
	frog = Draggable.new()
	frog.name = "frog"
	add_child(frog)
	move_child(frog, idx)
	frog.call("setup", Rect2(origin, FROG_NIB_SIZE), _tex(FROG_IMAGES[0]))

	var sling_size: Vector2 = _slingshot.texture.get_size() * _slingshot.scale
	_slingshot.centered = true
	_slingshot.position += sling_size * 0.5
	_sling_home = _slingshot.position

	_band.position += BAND_SIZE * 0.5
	_band_home = _band.position


# -- lifecycle ----------------------------------------------------------------

func _init_with_nib() -> void:
	_set_frog_count(Defaults.integer_for_key(COUNT_KEY))
	num_of_frogs = NUM_OF_FROGS_FALLBACK
	for file: String in COOKIE_IMAGES:
		var s := Sprite2D.new()
		s.texture = _tex(file)
		if s.texture != null:
			var art := s.texture.get_size()
			var k := minf(COOKIE_FRAME.x / art.x, COOKIE_FRAME.y / art.y)
			s.scale = Vector2(k, k)
		s.position = COOKIE_PARK
		add_child(s)
		falling_cookies.append(s)


func _view_did_load() -> void:
	_set_frog_count(frog_count)
	frog.set("del", self)
	var c: Vector2 = frog.get("center")
	frog.set("min_y", int(c.y))
	frog.set("max_y", int(VIEW_HEIGHT))
	var frames: Array[Texture2D] = []
	for f: String in FROG_IMAGES:
		frames.append(_tex(f))
	frog.set("animation_images", frames)
	original_frog_center = c
	# frogBox: frame (0,0,50,60), centre (frog.w/2, frog.h/2 - 8) in the frog.
	var box_center := Vector2(FROG_NIB_SIZE.x * 0.5, FROG_NIB_SIZE.y * 0.5 - FROG_BOX_LIFT)
	_frog_box = Rect2(box_center - FROG_BOX_SIZE * 0.5, FROG_BOX_SIZE)
	# Analytics bookkeeping (no gameplay effect); the DataLogging calls are
	# not ported. PORT CHOICE: NSDate values are stored as unix seconds.
	if not Defaults.bool_for_key("uniqueFrog"):
		Defaults.set_bool_for_key(true, "uniqueFrog")
		Defaults.synchronize()
	if Defaults.integer_for_key("dateArcFlag") == 0:
		Defaults.set_object_for_key(Time.get_unix_time_from_system(), "startArcDate")
		Defaults.set_integer_for_key(1, "dateArcFlag")
		Defaults.synchronize()


func _view_will_appear() -> void:
	_reset_lillies()
	_refresh_coin_label()
	frog.visible = false
	_slingshot.visible = false
	_band.visible = false


func _view_did_appear() -> void:
	if not is_instance_valid(frog):
		return
	frog.visible = true
	if frog_count < 1 or _popup != null:
		frog.visible = false
		_band.visible = false
		_slingshot.visible = false
		frog.set("user_interaction_enabled", false)
	else:
		_reset_frog()
		_show_frog()


## coinValueChanged: (0x12B7FC). PORT CHOICE: there is no notification
## centre; the label follows CoinManager's total instead, which is the value
## the notification carried.
func _process(_delta: float) -> void:
	_refresh_coin_label()


func _refresh_coin_label() -> void:
	var total := CoinManager.total_coins()
	if total != _shown_coins and _coin_label != null:
		_shown_coins = total
		_coin_label.text = "%d" % total


## setFrogCount: (0x12B898)
func _set_frog_count(n: int) -> void:
	frog_count = n
	Defaults.set_integer_for_key(frog_count, COUNT_KEY)
	Defaults.synchronize()
	if _frog_count_label != null:
		_frog_count_label.text = "%d" % frog_count


# -- lilies -----------------------------------------------------------------

## resetLillies: (0x126C68). A random path 0..4 unless one is given.
func _reset_lillies(path: int = -1) -> void:
	for c in _pool.get_children():
		_pool.remove_child(c)
		c.queue_free()
	var roll := randi() % 5
	if path < 0:
		path = roll
	lilly_path = path
	# ((arc4random() % 50) / 100.0 + 0.5) * 100 -> 50..99, path 4 always 50.
	var side := (float(randi() % 50) / 100.0 + 0.5) * 100.0
	if path == 4:
		side = LILY_STAR_SIZE
	var lilies: Array[Node2D] = []
	var center := _pool_frame.size * 0.5
	for i in 3:
		var l := LillyView.new()
		l.call("setup", Vector2(side, side))
		_pool.add_child(l)
		l.position = center
		lilies.append(l)
	for i in 3:
		var pts := PackedVector2Array()
		match path:
			0, 1:
				# Circle of radius 100 about the lily's centre, one keyframe
				# per degree from..to inclusive; path 1 runs it mirrored.
				var dir := -1 if path == 1 else 1
				for deg in range(LILY_CIRCLE_FROM[i], LILY_CIRCLE_TO[i] + 1):
					var a := float(dir * deg) * 3.14159265 / 180.0
					pts.append(center + Vector2(cos(a), sin(a)) * LILY_CIRCLE_RADIUS)
			2, 3:
				var xs: Array = LILY_SQUARE_X2[i] if path == 2 else LILY_SQUARE_X3[i]
				var ys: Array = LILY_SQUARE_Y2[i] if path == 2 else LILY_SQUARE_Y3[i]
				for k in xs.size():
					pts.append(Vector2(float(xs[k]), float(ys[k])) + Vector2(LILY_SQUARE_SHIFT, LILY_SQUARE_SHIFT))
			4:
				for k in LILY_STAR_X[i].size():
					pts.append(Vector2(float(LILY_STAR_X[i][k]), float(LILY_STAR_Y[i][k])) + LILY_STAR_SHIFT)
		if pts.size() >= 2:
			lilies[i].call("set_path", pts, LILY_PATH_TIME)
	for l in lilies:
		l.call("bob")


func _lillies() -> Array[Node2D]:
	var out: Array[Node2D] = []
	if _pool == null:
		return out
	for c in _pool.get_children():
		if c.get_script() == LillyView:
			out.append(c as Node2D)
	return out


func _pause_lillies() -> void:
	for l in _lillies():
		l.call("pause_layer")


func _resume_lillies() -> void:
	for l in _lillies():
		l.call("resume_layer")


# -- frog / slingshot -------------------------------------------------------

## resetFrog (0x127F28)
func _reset_frog() -> void:
	frog.call("remove_all_animations")
	move_child(frog, -1)                         # removeFromSuperview + addSubview
	frog.set("user_interaction_enabled", true)
	frog.call("set_transform_rs", 0.0, 1.0)
	frog.call("set_alpha", 1.0)
	_band.rotation = 0.0
	_slingshot.rotation = 0.0
	for c in _band.get_children():
		_band.remove_child(c)
		c.queue_free()
	_band_image = Sprite2D.new()
	_band_image.texture = _tex(BAND_IMAGE)
	_band_image.centered = false
	_band.add_child(_band_image)
	# frame (0,0,75,60), anchorPoint (0.5,0) leaves position (37.5,30) so the
	# frame becomes (0,30,...); centre.y - 25 then puts its top at y 5.
	_set_band_image_frame(Rect2(Vector2(0, BAND_IMAGE_SIZE.y * 0.5 - BAND_IMAGE_LIFT), BAND_IMAGE_SIZE))


func _set_band_image_frame(r: Rect2) -> void:
	_band_image_frame = r
	if _band_image == null or _band_image.texture == null:
		return
	_band_image.position = r.position - BAND_SIZE * 0.5
	_band_image.scale = r.size / _band_image.texture.get_size()


## showFrog (0x1281E8): in from 300px right, "ResetFrog" linear 0.25s.
func _show_frog() -> void:
	frog.visible = true
	_slingshot.visible = true
	_band.visible = true
	var shift := Vector2(SLIDE_IN_OFFSET, 0)
	frog.call("set_center", original_frog_center + shift)
	_slingshot.position = _sling_home + shift
	_band.position = _band_home + shift
	frog.call("animate", {"center": original_frog_center}, SLIDE_IN_TIME, LINEAR)
	if _slide_tween != null and _slide_tween.is_valid():
		_slide_tween.kill()
	_slide_tween = create_tween().set_parallel(true)
	_slide_tween.tween_property(_slingshot, "position", _sling_home, SLIDE_IN_TIME)
	_slide_tween.tween_property(_band, "position", _band_home, SLIDE_IN_TIME)
	_mark_arc_end()


# -- touches (DraggableIV) ----------------------------------------------------

## The frog is the top view once resetFrog has run; a touch that lands on it
## (its model geometry, as UIKit hit-tests) is its until the finger lifts.
## Presses go through _unhandled_input so the nib's buttons and the prize
## dialog keep priority; the rest of a frog touch is taken in _input so a
## button the finger passes over cannot swallow it.
func _unhandled_input(event: InputEvent) -> void:
	if frog == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed and not _touching:
		var p: Vector2 = (event as InputEventMouseButton).position
		if frog.call("hit_test", p):
			_touching = true
			frog.call("touches_began", p)
			get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not _touching:
		return
	if event is InputEventMouseMotion:
		frog.call("touches_moved", (event as InputEventMouseMotion).position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and not event.pressed:
		_touching = false
		frog.call("touches_ended", (event as InputEventMouseButton).position)
		get_viewport().set_input_as_handled()


## draggableTouchBegan:fromSender: (0x1294F8)
func draggable_touch_began(_p: Vector2, _sender: Object) -> void:
	if not is_frog_in_air:
		Audio.play("slingshot_pull")


## draggableTouchMoved:fromSender: (0x129558) -- frog, slingshot and band
## turn to face the pull; the band stretches to the frog.
func draggable_touch_moved(_p: Vector2, _sender: Object) -> void:
	if is_frog_in_air:
		return
	var c: Vector2 = frog.get("center")
	var dy := c.y - original_frog_center.y
	var dx := c.x - original_frog_center.x
	var hyp := Vector2(dy, dx).length()
	# PORT CHOICE: at hyp == 0 the original computes acos(0/0) = NaN and hands
	# UIKit NaN geometry; the port uses the straight-down limit instead.
	var angle := 0.0 if hyp == 0.0 else -(PI / 2.0 - acos(dx / hyp))
	frog.call("set_transform_rs", angle, 1.0)
	_slingshot.rotation = angle
	var frog_frame: Rect2 = frog.call("frame")
	var h := hyp + frog_frame.size.y * 0.5 + BAND_STRETCH_PAD
	_set_band_image_frame(Rect2(_band_image_frame.position, Vector2(BAND_IMAGE_SIZE.x, h)))
	_band.rotation = angle


## draggableTouchEnded:fromSender: (0x129870) -- the throw.
func draggable_touch_ended(_p: Vector2, _sender: Object) -> void:
	if is_frog_in_air:
		return
	outside_bounce_count = 0
	var c: Vector2 = frog.get("center")
	var dy := c.y - original_frog_center.y
	var dx := c.x - original_frog_center.x
	var hyp := Vector2(dy, dx).length()
	if hyp < MIN_PULL:
		_reset_frog()
		frog.call("set_center", original_frog_center)
		return
	var a := acos(dx / hyp)
	var ratio := hyp / (VIEW_HEIGHT - original_frog_center.y)
	var dist := ratio * THROW_RANGE
	var angle := -(PI / 2.0 - a)
	var target := Vector2(c.x - dx * dist / hyp, c.y - dy * dist / hyp)
	Audio.play("slingshot_release1" if (randi() & 1) != 0 else "slingshot_release2")
	var d := ratio * THROW_TIME - 1.0 + 1.0
	var flip := d - FLIP_SHORTEN if d - FLIP_SHORTEN > 0.0 else d
	frog.set("animation_duration", flip)
	frog.set("animation_repeat_count", 1)
	frog.call("start_animating")
	var move_ctx := {"hyp": hyp, "width": dx, "height": dy, "angle": angle}
	frog.call("animate", {"center": target}, d, LINEAR,
		_animation_did_stop.bind("MoveFrog", move_ctx))
	var scale_ctx := {"angle": angle, "animationDuration": d, "hyp": hyp}
	frog.call("animate", {"transform": [angle, SCALE_UP]}, d / 3.0, LINEAR,
		_animation_did_stop.bind("ScaleUpFrog", scale_ctx))
	_set_band_image_frame(Rect2(_band_image_frame.position, BAND_RELEASED_SIZE))
	is_frog_in_air = true


# -- the flight -----------------------------------------------------------------

## animationDidStop:finished:context: (0x129F50). ScaleUpFrog -> PauseFrog ->
## ResetFrogScale is the jump arc (grow 1.5x, hold, shrink back, a third of
## the flight each); MoveFrog is the landing.
##
## INFERRED: "PauseFrog" animates alpha 1.0 -> 2.0. Alpha is clamped to 1, so
## nothing changes on screen; the port assumes UIKit still runs the block for
## its full duration (the hold the name describes) rather than ending it at
## once. Worth a look on the phone: the frog should stay at 1.5x for the
## middle third of its flight.
##
## Animations replaced or removed before they finish do not call back in the
## port. In the original they would, with finished:NO; the reachable cases
## (resetFrog removing "ResetFrog", willBounce replacing "ResetFrogScale")
## name animations this method ignores, so nothing is lost.
func _animation_did_stop(anim_id: String, ctx: Dictionary) -> void:
	if not is_instance_valid(frog):
		return
	match anim_id:
		"ScaleUpFrog":
			var dur := float(ctx["animationDuration"])
			frog.call("set_alpha", 1.0)
			frog.call("animate", {"alpha": 2.0}, dur / 3.0, LINEAR,
				_animation_did_stop.bind("PauseFrog", ctx))
		"PauseFrog":
			frog.call("animate", {"transform": [float(ctx["angle"]), 1.0]},
				float(ctx["animationDuration"]) / 3.0, LINEAR,
				_animation_did_stop.bind("ResetFrogScale", {}))
		"MoveFrog":
			_frog_landed(ctx)


## frogBox in the main view's coordinates (convertRect:fromView:frog), using
## the frog's model transform as UIKit does.
func _frog_box_in_view() -> Rect2:
	return frog.call("convert_rect_to_superview", _frog_box)


## The "MoveFrog" branch of animationDidStop:.
func _frog_landed(ctx: Dictionary) -> void:
	frog.call("stop_animating")
	var box_view := _frog_box_in_view()
	var box_pool := Rect2(box_view.position - _pool_frame.position, box_view.size)
	var box_area := FROG_BOX_SIZE.x * FROG_BOX_SIZE.y
	var hit: Node2D = null
	for l in _lillies():
		var lily_frame: Rect2 = l.call("presentation_frame")
		var overlap := box_pool.intersection(lily_frame)
		if overlap.get_area() / box_area * 100.0 > LILY_HIT_PERCENT:
			hit = l                                   # the last one wins
	var roll := randi() % 100
	var in_pool := _pool_frame.intersection(box_view)
	var bounce := false
	if hit != null:
		bounce = roll <= LILY_BOUNCE_ROLL
	else:
		var share := in_pool.get_area() / box_view.get_area()
		if share > EDGE_BOUNCE_MIN and share < EDGE_BOUNCE_MAX and outside_bounce_count <= 0:
			outside_bounce_count += 1
			bounce = true
	if bounce:
		Audio.play("bounce_off")
		frog.call("pause_layer")
		_pause_lillies()
		is_frog_in_air = true
		var next := ctx.duplicate()
		if hit != null:
			next["hitLilly"] = hit
		_after(BOUNCE_DELAY, _will_bounce.bind(next))
		return

	_mark_arc_end()
	if hit != null:
		Audio.play("frog_hit")
	elif _pool_frame.encloses(box_view):
		Audio.play("frog_splash")
		_start_splash()
		frog.call("set_alpha", 1.0)
		frog.call("animate", {"alpha": 0.0}, FADE_TIME, LINEAR)   # "FadeFrog"
	else:
		Audio.play("frog_hit")
	_pause_lillies()
	_after(SETTLE_DELAY, _will_not_bounce.bind(hit))


## splash01..09 over 0.5s once, tag 10000001, centred 10px above the frog.
## After the run a UIImageView shows its `image` (splash01) again until
## willNotBounce: removes it.
func _start_splash() -> void:
	var frames: Array[Texture2D] = []
	for f: String in SPLASH_IMAGES:
		frames.append(_tex(f))
	_splash = Sprite2D.new()
	_splash.texture = frames[0]
	var c: Vector2 = frog.get("center")
	_splash.position = Vector2(c.x, c.y - SPLASH_LIFT)
	add_child(_splash)
	var s := _splash
	var tw := create_tween()
	tw.tween_method(func(v: float) -> void:
		if is_instance_valid(s):
			s.texture = frames[mini(int(v), frames.size() - 1)],
		0.0, float(frames.size()), SPLASH_TIME)
	tw.tween_callback(func() -> void:
		if is_instance_valid(s):
			s.texture = frames[0])


## willBounce: (0x12AEC0). A lily bounce goes 100px in a random up-left
## direction; an edge bounce carries on 100px the way it was going.
func _will_bounce(d: Dictionary) -> void:
	var hit: Variant = d.get("hitLilly")
	var height := float(d.get("height", 0.0))
	var width := float(d.get("width", 0.0))
	var hyp := float(d.get("hyp", 0.0))
	var angle := float(d.get("angle", 0.0))
	if hit != null:
		height = float(randi() % 100)
		width = float(randi() % 100)
		hyp = Vector2(height, width).length()
		# PORT CHOICE: both rolls 0 gives 0/0 (NaN geometry) in the original;
		# the port leaves the frog where it is, facing up.
		var a := 0.0 if hyp == 0.0 else acos(width / hyp)
		if hyp == 0.0:
			angle = 0.0
		elif height <= 0.0:
			angle = 4.71238898 - a
		else:
			angle = -(1.57079633 - a)
	var c: Vector2 = frog.get("center")
	var target := c
	if hyp != 0.0:
		target = Vector2(c.x + width * -BOUNCE_DISTANCE / hyp,
			c.y + height * -BOUNCE_DISTANCE / hyp)
	frog.set("animation_duration", BOUNCE_FLIP_TIME)
	frog.set("animation_repeat_count", 1)
	frog.call("start_animating")
	var move_ctx := {"hyp": hyp, "width": width, "height": height, "angle": angle}
	frog.call("animate", {"center": target}, BOUNCE_TIME, LINEAR,
		_animation_did_stop.bind("MoveFrog", move_ctx))
	frog.call("set_transform_rs", angle, 1.0)
	var scale_ctx := {"angle": angle, "animationDuration": BOUNCE_TIME, "hyp": hyp}
	frog.call("animate", {"transform": [angle, SCALE_UP]}, BOUNCE_SCALE_TIME, LINEAR,
		_animation_did_stop.bind("ScaleUpFrog", scale_ctx))
	frog.call("resume_layer")
	_resume_lillies()
	is_frog_in_air = true


## willNotBounce: (0x12B5E8)
func _will_not_bounce(hit: Variant) -> void:
	if _splash != null and is_instance_valid(_splash):
		_splash.queue_free()
	_splash = null
	_show_end_message(hit, true)


# -- end of a throw -------------------------------------------------------------

## showEndMessage:finish: (0x1284E4)
func _show_end_message(hit: Variant, finish: bool) -> void:
	if hit != null:
		_build_prize_dialog(finish)
		_delay_startup_emitter_balloons()
		Audio.play("fanfare")
	else:
		_close_prize_dialog(null)
		Audio.play("aww")
	is_frog_in_air = false


func _build_prize_dialog(finish: bool) -> void:
	var box := Control.new()
	box.name = "PrizeDialog"                    # tag 10000000
	box.position = Vector2.ZERO
	box.size = Vector2(320, 480)
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	# "Show_Upgrade_Dialog" is +beginAnimations:/commitAnimations
	# (showEndMessage:finish: 0x1284E4): UIKit hit-tests the container at its
	# MODEL transform, identity from the commit, so the full-screen UIView
	# swallows every touch from the first frame of the pop-in. `box` is drawn
	# scaling up from 0.01 and Godot hit-tests it through that scale, so an
	# unscaled blocker under it stands in for the model frame (as
	# wm_hitmole / mb_ThrowBallVC already do). Without it the frog and the
	# nav buttons answered under the growing dialog.
	# PORT CHOICE: the button itself is hit where it is drawn while it grows.
	var blocker := Control.new()
	blocker.name = "PrizeDialogBlocker"
	blocker.size = Vector2(320, 480)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(blocker)
	box.tree_exiting.connect(blocker.queue_free)
	add_child(box)
	_popup = box

	box.add_child(_image_rect(_tex("prize_popup.png"), Vector2.ZERO))

	# force = (pool.h - frog.y in pool) / pool.h * 20 -- the further up the
	# pond the frog came down, the higher the force.
	var c: Vector2 = frog.get("center")
	var in_pool := c - _pool_frame.position
	var force := (_pool_frame.size.y - in_pool.y) / _pool_frame.size.y * PRIZE_FORCE_SCALE
	var prize: Variant = PrizeManager.get_random_prize_game_force(true, PRIZE_GAME, force)
	PrizeManager.unlock_prize(prize)
	var prize_tex := _as_texture(PrizeManager.get_prize_image(prize))
	var prize_iv := _image_rect(prize_tex, Vector2.ZERO)
	box.add_child(prize_iv)
	prize_iv.position = PRIZE_CENTER - prize_iv.size * 0.5

	var btn := TextureButton.new()
	btn.texture_normal = _tex("daily_login_btn.png")
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE
	btn.size = PRIZE_BUTTON_SIZE
	btn.position = PRIZE_BUTTON_CENTER - PRIZE_BUTTON_SIZE * 0.5
	_popup_button_tag = 1 if finish else 0
	btn.pressed.connect(_close_prize_dialog.bind(btn))
	box.add_child(btn)

	var label_iv := _image_rect(_tex("prize_label.png"), Vector2.ZERO)
	box.add_child(label_iv)
	label_iv.position = PRIZE_LABEL_CENTER - label_iv.size * 0.5
	var lbl := Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UILabelFrame.set_frame(lbl, Rect2(Vector2(label_iv.size.x * 0.5, PRIZE_NAME_Y)
		- PRIZE_NAME_SIZE * 0.5, PRIZE_NAME_SIZE))
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color.BLACK)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font := SystemFont.new()
	font.font_names = PackedStringArray(FONT_NAMES)
	lbl.add_theme_font_override("font", font)
	var name_v: Variant = PrizeManager.get_prize_name(prize)
	lbl.text = "" if name_v == null else str(name_v)
	# adjustsFontSizeToFitWidth, minimumFontSize 6. PORT CHOICE: whole points.
	var fs := PRIZE_NAME_FONT
	while fs > PRIZE_NAME_MIN_FONT and \
			font.get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > PRIZE_NAME_SIZE.x:
		fs -= 1
	lbl.add_theme_font_size_override("font_size", fs)
	label_iv.add_child(lbl)

	# "Show_Upgrade_Dialog": scale 0.01 -> identity, 0.5s linear, about the
	# view's centre.
	box.pivot_offset = box.size * 0.5
	box.scale = Vector2(DIALOG_START_SCALE, DIALOG_START_SCALE)
	create_tween().tween_property(box, "scale", Vector2.ONE, DIALOG_POP_TIME) \
		.set_trans(Tween.TRANS_LINEAR)


## closePrizeDialog: (0x128C78). `sender` is the dialog's button, or null.
func _close_prize_dialog(sender: Variant) -> void:
	Audio.play("button_press")
	var tag := 0
	if sender != null:
		tag = _popup_button_tag
		if _popup != null:                       # [[sender superview] removeFromSuperview]
			_popup.hide()
			_popup.queue_free()
			_popup = null
	if tag == 1 or sender == null:
		_end_throw()
	else:
		# Unreachable here (the only caller with a sender tags it 1), kept
		# as read: resume the frog's layer and the lilies.
		frog.call("resume_layer")
		_resume_lillies()


## endThrow (0x128F6C)
func _end_throw() -> void:
	_set_frog_count(frog_count - 1)
	_resume_lillies()
	if frog_count <= 0:
		frog.visible = false
		_band.visible = false
		_slingshot.visible = false
		frog.set("user_interaction_enabled", false)
		show_alert(OUT_OF_FROGS, ["Cancel", "Buy"], _alert_view_clicked, false)
	else:
		_reset_lillies()
		_reset_frog()
		_show_frog()


## delayStartupEmitterBalloons (0x1291F0): each of the 13 images jumps to
## (60..259, 520..569), comes to the front and rises off the top, fanning out
## (x + 2(x-160), y - 650), "Fall" curve 1 (ease-in), 1.5..2.49s.
func _delay_startup_emitter_balloons() -> void:
	for tw in _cookie_tweens:
		if tw.is_valid():
			tw.kill()
	_cookie_tweens.clear()
	for v in falling_cookies:
		var x := float(randi() % 200 + 60)
		var y := float(randi() % 50 + 520)
		v.position = Vector2(x, y)
		move_child(v, -1)
		var dur := float(randi() % 100) / 100.0 + 1.5
		var tw := create_tween()
		tw.tween_property(v, "position", Vector2(x + 2.0 * (x - 160.0), y - 650.0), dur) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		_cookie_tweens.append(tw)
	Audio.play("cheer")


# -- coins / alerts -------------------------------------------------------------

## buyFrogs (0x127CF8)
func _buy_frogs() -> bool:
	if CoinManager.total_coins() > FROG_PRICE - 1:
		_mark_arc_end()
		if Defaults.integer_for_key("playedArcFlag") == 0:
			Defaults.set_integer_for_key(1, "playedArcFlag")
			Defaults.synchronize()
		CoinManager.spend_coins(FROG_PRICE)
		_set_frog_count(frog_count + num_of_frogs)
		return true
	_show_buy_more_coins_message()
	return false


## showBuyMoreCoinsMessage (0x128EE8) -> IAPlistManager
## displayMediaBrixForLocation:"MiniGame" withMiniGame:"Frog Flip" (0x1757E0).
## That shows nothing at all unless the downloaded iaplist has an
## "Advertising" entry; with one, it either plays a MediaBrix ad or, for
## "MiniGame", this alert (delegate IAPlistManager, whose "Get Coins" plays
## "store" and pushes the coin store, 0x176C44).
## PORT CHOICE (as core/Consumable.gd): no ad network, so the alert stands in.
func _show_buy_more_coins_message() -> void:
	show_alert(NOT_ENOUGH_COINS, ["Cancel", "Get Coins"], _alert_view_clicked, false)


## alertView:clickedButtonAtIndex: (0x12B644); IAPlistManager's "Get Coins"
## (0x176C44) does the same as this one's.
func _alert_view_clicked(title: String) -> void:
	match title:
		"OK":
			_close_prize_dialog(null)
		"Buy":
			if _buy_frogs():
				_reset_lillies()
				_reset_frog()
				_show_frog()
		"Get Coins":
			Audio.play("store")
			Nav.push("CoinStoreViewController")


# -- buttons ----------------------------------------------------------------------

## backClick: (0x12B960). The interstitial ad shown when FF_KEY_EVERYTHING is
## unset is not ported (no ad networks).
func _on_backClick() -> void:
	if is_frog_in_air:
		return
	_mark_arc_end()
	CoinManager.sync_coins(true)
	Audio.play("button_press")
	Nav.back()


## coinsClick: (0x12BB30)
func _on_coinsClick() -> void:
	if is_frog_in_air:
		return
	Audio.play("store")
	Nav.push("CoinStoreViewController")


## playClick: (0x12BC24) -- the MORE FROGS button.
func _on_playClick() -> void:
	if is_frog_in_air:
		return
	Audio.play("button_press")
	if not is_frog_in_air and _buy_frogs():
		_reset_frog()
		if frog_count == num_of_frogs:
			_show_frog()


## prizeClick: (0x12BCE8)
func _on_prizeClick() -> void:
	if is_frog_in_air:
		return
	Audio.play("trophy_door")
	GameState.screen_args["PrizeViewController"] = {
		"prizes": PrizeManager.get_prizes_for_game(PRIZE_GAME),
		"background_file": PRIZE_BACKGROUND,
	}
	Nav.push("PrizeViewController")


# -- helpers ------------------------------------------------------------------------

## The arc-time bookkeeping several methods repeat (analytics only).
func _mark_arc_end() -> void:
	if Defaults.integer_for_key("dateArcFlag") >= 1:
		Defaults.set_object_for_key(Time.get_unix_time_from_system(), "endArcDate")
		Defaults.synchronize()


## performSelector:withObject:afterDelay: -- a run-loop timer, unaffected by
## layer pauses; owned by this screen so it dies with it.
func _after(secs: float, fn: Callable) -> void:
	var tw := create_tween()
	tw.tween_interval(secs)
	tw.tween_callback(fn)


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## UIImageView initWithImage: -- natural size, no input.
func _image_rect(tex: Texture2D, pos: Vector2) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.position = pos
	if tex != null:
		r.size = tex.get_size()
	return r


## getPrizeImage: hands back a UIImage; accept whatever the PrizeManager port
## returns for it (texture, image, or a file name).
func _as_texture(v: Variant) -> Texture2D:
	if v is Texture2D:
		return v
	if v is Image:
		return ImageTexture.create_from_image(v)
	if v is String and (v as String) != "":
		var file: String = v
		if file.get_extension() == "":
			file += ".png"
		return _tex(file)
	return null
