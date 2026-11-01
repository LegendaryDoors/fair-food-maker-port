# The fairground -- the hub the player picks a stand from.
#
# Read from the 1.27 binary:
#   initFairgrounds        0x2CA64  (all 20 stands, both scroll strips)
#   viewWillAppear:        0x2C760  (entry offsets 1080 / 320)
#   viewDidAppear:         0x2C98C  ("Animate_To_First_Item", 2.0s to zero)
#   scrollViewDidScroll:   0x2FE68  (parallax = 0.4 * offset, y pinned to 0)
#   standClicked:          0x2ED74  (tag -> class switch, button_press.mp3)
#   lockedStandClicked:    0x2EC88  (tags 17/18 -> IAP purchase; port unlocked)
#   productPurchased:      0x2F764  (unlock swaps art / removes overlay)
#   stringForStandEnumerator: 0x2FACC, messageForAlertView: 0x2FC60
#   backClick:             0x2F92C, MoreGamesClick: 0x2EC14 (Chartboost)
# Kept alive under pushed screens; see on_resume for what re-runs on return
# (the entry sweep does, by the binary). Literal-pool floats are decoded from
# the binary at the addresses cited on each constant below.
#
# Two full-screen strips, both UIScrollViews in the nib:
#   parallaxScrollView (below) -- no subviews; its backgroundColor is
#     colorWithPatternImage:ff_stand_background.png, contentSize 1440x480,
#     driven at 0.4x the front strip's offset by scrollViewDidScroll:.
#   aScrollView (above) -- clear background, contentSize 1420x480, holding
#     20 blob shadows then 20 UIButton stands. decelerationRate is
#     UIScrollViewDecelerationRateFast on both.
#
# Layout branches on IAPlist.plist Misc/BoothDisplaySingleRow (0x2CA64 reads
# it from Documents). The shipped bundle has no Misc key, so the flag is
# false and the DOUBLE-ROW layout below is the only one a fresh install ever
# shows. The single-row variant (scale 2.0 at 0x2DAE8, every y=50 at 0x2DAF0,
# slot indices stepping by 2) is a dormant remote-config path; not ported.
#
# The four scrollViewDidEnd* delegates are literally `bx lr` (0x2FFC4..D0)
# and tweenScrollView: (0x2FF24) has a method-list entry but NO selref --
# nothing ever calls it. The strip free-scrolls; there is no snapping.
#
# SCROLLING: the strip is a real iOS 6 UIScrollView, built from
# core/UIScrollSim.gd's ScrollAxis through ScrollableGridView.PanScroller:
# UIKit's 10 pt drag hysteresis, the 0.55 rubber band past either end, the
# Fast (0.99/ms) deceleration both strips get, the bounce back, the release
# velocity filter. bounces is the nib default (YES: neither nib scroll view
# carries UIBounceEnabled) and both nib views have their indicators OFF
# (UIShowsHorizontal/VerticalScrollIndicator NO in the raw nib), so none is
# drawn. The empty scrollViewWillEndDragging:withVelocity:targetContentOffset:
# (0x2FFD0) leaves the target alone, which -_endPanWithEvent: (UIKit
# 0x330543E0) treats as "no delegate target" -- so no will_end_dragging
# callable. The old hand-rolled slop / clamp / 4 px/s stop and the
# "bounce not ported" gap are gone. viewDidAppear:'s sweep now starts when
# the push/pop slide ends (Screen.on_did_appear), as on the phone.

extends "res://core/Screen.gd"

const ScrollableGridView := preload("res://core/ScrollableGridView.gd")
const UIScrollSim := preload("res://core/UIScrollSim.gd")

# -- geometry, initFairgrounds 0x2CA64, scale 1.0 (0x2DAE4) -------------

## Stand slot pitch: every x is slot_index * 0x8C (140) + MARGIN, +- a
## per-stand nudge encoded inline (+5 for most, 0 / -5 / -10 / -20 for a few
## -- already folded into STANDS below).
const SLOT_PITCH := 140.0
## 20 * scale, converted through vcvt at 0x2CA64's head.
const MARGIN := 20.0
## Top row y (0x42480000 inline); bottom row y = 260 (0x2DAEC).
const ROW_TOP_Y := 50.0
const ROW_BOTTOM_Y := 260.0
## aScrollView contentSize: 20 + (9*140 + 140) = 1420, height 480
## (0x43F00000). parallaxScrollView is 20 wider: 1440.
const CONTENT_W := 1420.0
const PARALLAX_CONTENT_W := 1440.0
const VIEW_W := 320.0
const MAX_OFFSET := CONTENT_W - VIEW_W  # 1100

# -- entry sweep --------------------------------------------------------

## viewWillAppear: (0x2C760) parks aScrollView at x=1080 (0x44870000) and
## parallaxScrollView at x=320 (0x43A00000); viewDidAppear: (0x2C98C) then
## animates BOTH to CGPointZero in one 2.0s UIView animation
## ("Animate_To_First_Item", default ease-in-out curve).
const ENTRY_OFFSET := 1080.0
const ENTRY_PARALLAX_OFFSET := 320.0
const ENTRY_GLIDE_SECONDS := 2.0

# -- live scrolling -----------------------------------------------------

## scrollViewDidScroll: (0x2FE68): parallax offset = front offset * 0.4
## (DAT_0x2FF20), set un-animated; the front strip's y is re-pinned to 0.
## Every offset the front strip shows -- rubber band and bounce included --
## goes through it.
const PARALLAX_RATE := 0.4
## Both strips get setDecelerationRate:UIScrollViewDecelerationRateFast at
## the tail of initFairgrounds: UIKit's exported 0.99 per millisecond
## (UIScrollSim.DECELERATION_RATE_FAST). The parallax strip is never touched
## (the front one covers it), so its rate never shows.
const DECELERATION_RATE := UIScrollSim.DECELERATION_RATE_FAST
## The view height = the content height (480): the vertical axis cannot
## scroll (no alwaysBounceVertical), so only x is simulated.
const VIEW_H := 480.0
## The coins panel CoinHUD puts on this screen: a 320x60 UIView (CoinInfoView
## init 0x12E3CC) above the strips, centre (160,30) here -- a touch that lands
## on it is the panel's, not the scroll view's.
const COIN_PANEL_RECT := Rect2(0, 0, 320, 60)

## Every stand's blob shadow (MM_Booth_Blob_Shadow.png, a self-sizing
## UIImageView, so a true centre) sits at button.center + (20, 50). The +20
## is inline; every one of the six per-stand dy literals decodes to 50.0
## (0x2CFC8, 0x2D6C0, 0x2DB10, 0x2E310, 0x2E890, 0x2EB94).
const SHADOW_OFFSET := Vector2(20, 50)

## The 20 stands in construction order (which is the shadows' z-order).
## Frames are the UIButton initWithFrame: rects -- explicit frames, so
## ordinary geometry, centre = rect centre. Sizes are the frame, not the
## art: the ff_stand_*.png files are 2x-ish and UIButton's background image
## stretches to fill. `key` is stringForStandEnumerator: (0x2FACC).
const STANDS := [
	{"tag": 1, "art": "ff_stand_cottoncandy", "rect": Rect2(20, 260, 118, 182),
		"key": "FF_STAND_COTTON_CANDY"},          # w 0x2CFC4, h 0x2CFC0; no +5
	{"tag": 16, "art": "ff_stand_banana", "rect": Rect2(25, 50, 110, 196),
		"key": "FF_STAND_CHOCO_DIPPED_BANANA"},   # x-mult 0.0 at 0x2DAF4
	{"tag": 18, "art": "ff_stand_donut1", "rect": Rect2(165, 50, 110, 196),
		"key": "FF_STAND_DONUT_ICE_CREAM"},       # x-mult 140.0 at 0x2DAFC
	{"tag": 17, "art": "ff_stand_football_toss", "rect": Rect2(165, 260, 110, 196),
		"key": "FF_STAND_FOOTBALL_TOSS"},         # slot 1
	{"tag": 19, "art": "ff_stand_videoreward", "rect": Rect2(305, 50, 110, 196),
		"key": "FF_STAND_REWARDS_CINEMA"},        # slot 2
	{"tag": 12, "art": "ff_stand_candyapple", "rect": Rect2(305, 260, 110, 196),
		"key": "FF_STAND_CANDY_APPLE"},           # slot 2
	{"tag": 14, "art": "ff_stand_milkbottles", "rect": Rect2(445, 50, 115, 196),
		"key": "FF_STAND_MILK_BOTTLES"},          # slot 3, w 0x2D6C4
	{"tag": 3, "art": "ff_stand_snowcone", "rect": Rect2(440, 260, 120, 212),
		"key": "FF_STAND_SNOW_CONE"},             # slot 3, no +5, w 0x2D6C8 h 0x2DB04
	{"tag": 8, "art": "ff_stand_balloonpop", "rect": Rect2(585, 50, 110, 196),
		"key": "FF_STAND_BALLOON_POP"},           # slot 4
	{"tag": 2, "art": "ff_stand_milkshake", "rect": Rect2(580, 250, 112, 222),
		"key": "FF_STAND_MILKSHAKE"},             # slot 4, no +5, y 260-10, w 0x2DB0C h 0x2DB08
	{"tag": 6, "art": "ff_stand_icepops", "rect": Rect2(725, 50, 110, 196),
		"key": "FF_STAND_ICE_POP"},               # slot 5
	{"tag": 13, "art": "ff_stand_frenchfries", "rect": Rect2(725, 280, 110, 196),
		"key": "FF_STAND_FRENCH_FRIES"},          # slot 5, y 260+20
	{"tag": 9, "art": "ff_stand_fishbowl", "rect": Rect2(865, 50, 110, 196),
		"key": "FF_STAND_FISHBOWL_TOSS"},         # slot 6
	{"tag": 0, "art": "ff_stand_corndog", "rect": Rect2(860, 260, 117, 200),
		"key": "FF_STAND_CORN_DOG"},              # slot 6, no +5, w 0x2E308 h 0x2E30C
	{"tag": 10, "art": "ff_stand_froggy", "rect": Rect2(1005, 50, 110, 196),
		"key": "FF_STAND_FROG_TOSS"},             # slot 7
	{"tag": 7, "art": "ff_stand_kettlecorn", "rect": Rect2(1005, 260, 110, 196),
		"key": "FF_STAND_KETTLE_CORN"},           # slot 7
	{"tag": 4, "art": "ff_stand_lemon_shakeup", "rect": Rect2(1135, 50, 105, 200),
		"key": "FF_STAND_LEMON_SHAKE_UP"},        # slot 8, x-nudge -5, w 0x2E314
	{"tag": 5, "art": "ff_stand_funnel_cakes", "rect": Rect2(1130, 270, 125, 189),
		"key": "FF_STAND_FUNNEL_CAKE"},           # slot 8, -10, y 260+10, w 0x2E31C h 0x2E318
	{"tag": 15, "art": "ff_stand_wackamole", "rect": Rect2(1260, 50, 135, 196),
		"key": "FF_STAND_WACK_MOLE"},             # slot 9, x-nudge -20, w 0x2E320
	{"tag": 11, "art": "ff_stand_watergun", "rect": Rect2(1285, 260, 110, 196),
		"key": "FF_STAND_WATER_SHOOTER"},         # slot 9
]

## The buttons are all addSubview'd in one burst AFTER every shadow, in this
## exact order (0x2ED4A..0x2ED72 region of initFairgrounds) -- so e.g. the
## milkshake stand draws over the balloon-pop stand where they overlap.
const BUTTON_Z_ORDER: Array[int] = [
	10, 11, 8, 9, 7, 6, 0, 1, 2, 3, 4, 5, 12, 13, 14, 15, 16, 17, 18, 19,
]

## standClicked: (0x2ED74). Foods start their flows.json step list (whose
## first step is exactly the class the switch allocates); midway games push
## a single screen. Tag 19 is the rewarded-video booth, handled apart.
const FOOD_BY_TAG := {
	0: "cd",    # cdBatterSelectViewController
	1: "cc",    # ccSugarPickerViewController
	2: "ms",    # msSelectFlavorViewController
	3: "sc",    # scCrushIceViewController
	4: "lsu",   # lsuPourSugarViewController
	5: "fc",    # fcBatterSelectVC
	6: "ip",    # ipSelectStickShapeViewController
	7: "kc",    # kcPourOilViewController
	12: "ca",   # caSelectApple
	13: "cff",  # cffPeelViewController
	16: "ccb",  # ccbPeelBananaViewController
	18: "dic",  # dicMixIngredientsViewController (initWithDonutMixture:0)
}
const MIDWAY_BY_TAG := {
	8: "bpTossDartVC",
	9: "ftTossBallVC",
	10: "ffTossFrogVC",
	11: "wsRaceVC",
	14: "mb_ThrowBallVC",
	15: "wm_hitmole",
	17: "fbtThrowballVC",
}
const TAG_VIDEO := 19
## PORT CHOICE (no ads or purchases in this port): the stand
## "Notice:" popups only announce ads -- off. Flip to restore the original.
const SHOW_AD_NOTICES := false
## The video-reward booth (tag 19) stays on the fairground, as on the phone
## (hiding it would leave a gap); tapping it says why it is off.
const SHOW_VIDEO_BOOTH := true
const TAG_DONUT := 18

## firstTimeEnteringSection: (0x2FDE8): UIAlertView title.
const NOTICE_TITLE := "Notice:"
## standClicked: (0x2ED74) / flurryClick: (0x2F99C), tag 19 offline.
const NO_VIDEOS_TITLE := "Sorry!"
## The original's offline message was "No videos are available at this time."
## PORT CHOICE: say that the port has no ads or videos.
const NO_VIDEOS_MESSAGE := "This version has no ads or videos, so the video booth is turned off."

## messageForAlertView: (0x2FC60), by tag: ad notices for the foods, how-to
## lines for the midway games. 18 has a string but standClicked: never shows
## it; 19 has none (the switch's default asserts).
const NOTICE_MESSAGES := {
	0: "While playing Corn Dogs you will see ads. If you purchase the unlock Corn Dogs pack, ads will be removed.",
	1: "While playing Cotton Candy you will see ads. If you purchase the unlock Cotton Candy pack, ads will be removed.",
	2: "While playing Milkshake you will see ads. If you purchase the unlock Milkshake pack, ads will be removed.",
	3: "While playing Snow Cone you will see ads. If you purchase the unlock Snow Cone pack, ads will be removed.",
	4: "While playing Lemon Shake Up you will see ads. If you purchase the unlock Lemon Shake Up pack, ads will be removed.",
	5: "While playing Funnel Cake you will see ads. If you purchase the unlock Funnel Cake pack, ads will be removed.",
	6: "While playing QuickFreeze Ice Pops you will see ads. If you purchase the unlock QuickFreeze Ice Pops pack, ads will be removed.",
	7: "While playing Kettle Corn you will see ads. If you purchase the unlock Kettle Corn pack, ads will be removed.",
	8: "Swipe the dart upwards with your finger to pop a balloon and win a prize!",
	9: "Swipe the ball upwards with your finger to land it in a fishbowl and win a prize!",
	10: "Pull back on the frog and release to slingshot it onto a lilypad and win a prize!",
	11: "Aim the water gun with your finger to spray the clown's target and win a prize!",
	12: "While playing Candy Apple you will see ads. If you purchase the unlock Candy Apple pack, ads will be removed.",
	13: "While playing French Fries you will see ads. If you purchase the unlock French Fries pack, ads will be removed.",
	14: "Swipe the ball upwards with your finger to make all milk bottles fall and win a prize!",
	15: "Smack Sammy by hitting them with hammer when they are out of hole and win a prize!",
	16: "While playing Chocolate Dipped Banana you will see ads. If you purchase the unlock Chocolate Dipped Banana pack, ads will be removed.",
	17: "Throw the ball through one of the holes with your finger and win a prize!",
	18: "While playing Donut Ice Cream Sandwich you will see ads. If you purchase the unlock Donut Ice Cream Sandwich pack, ads will be removed.",
}

var _front: Node2D          # aScrollView
var _back: Node2D           # parallaxScrollView
var _offset := 0.0          # front strip contentOffset.x as shown
var _glide: Tween
## aScrollView's UIScrollView behaviour (horizontal).
var _pan: ScrollableGridView.PanScroller

# isLoadingStand (set in standClicked: for every tag but 19, cleared by
# viewWillAppear: -- so on_resume clears it: the same instance comes back
# under a popped food, and a flag left set would lock every stand).
var _loading_stand := false

## The current touch is the scroll view's, not a stand's: the pan claimed it
## or it caught the strip moving (PanScroller.caught).
var _suppress_tap := false


func on_enter() -> void:
	var f := outlet("aScrollView")
	var b := outlet("parallaxScrollView")
	if not (f is Node2D) or not (b is Node2D):
		push_error("StandSelect: scroll view outlets missing")
		return
	_front = f as Node2D
	_back = b as Node2D

	# MoreGamesClick: (0x2EC14) is Chartboost's more-apps wall. The port
	# ships without ad/cross-promo SDKs (same policy that hides adButton),
	# so the badge goes with them.
	var badge := get_node_or_null("RayCPBadge_Maker_83x83")
	if badge != null:
		(badge as CanvasItem).visible = false

	_pan = ScrollableGridView.PanScroller.new(false)
	_pan.axis.set_deceleration_rate(DECELERATION_RATE)
	_pan.configure(VIEW_W, CONTENT_W)

	_build_parallax_background()
	_build_stands()

	_view_will_appear()
	set_process(true)


## Kept under every food / midway game it pushes: the
## UINavigationController never releases this controller, so back -- from a
## food's first step, a midway game, or the coin store -- runs only
## viewWillAppear: and viewDidAppear: again on the SAME fairground.
##
## That does NOT leave the strip where the player left it: viewWillAppear:
## (0x2C760) unconditionally re-parks aScrollView at x=1080 and the parallax
## strip at 320 (the two setContentOffset: calls at 0x2C8A0..0x2C8E4
## follow initFairgrounds with no branch), and viewDidAppear: (0x2C98C) glides
## both back to zero over 2.0 s -- every appearance replays the entry sweep.
## What does survive is everything initFairgrounds built: its
## `aScrollView.subviews.count <= 3` guard makes the second call a no-op, so
## the stands are not rebuilt.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	if _front == null:
		return
	_view_will_appear()


## viewDidAppear: -- after the push/pop slide (Nav calls this at its end, or
## at once for an unanimated change), on the first appearance and on every
## return.
func on_did_appear() -> void:
	if _front == null:
		return
	_view_did_appear()


## viewWillAppear: (0x2C760): the app delegate's analytics fields (not
## ported), accelFlag = 0 and playedArcFlag = 0 in NSUserDefaults (each
## synchronized; the midway games' once-per-visit logging reads them back),
## initFairgrounds (built once, in on_enter -- a no-op on return), the entry
## offsets, isLoadingStand = NO. A fresh appearance also has no touch in
## progress; a flick still decaying when a stand was pushed does not carry
## over the re-park.
func _view_will_appear() -> void:
	Defaults.set_integer_for_key(0, "accelFlag")
	Defaults.synchronize()
	Defaults.set_integer_for_key(0, "playedArcFlag")
	Defaults.synchronize()
	if _glide != null and _glide.is_valid():
		_glide.kill()
	_suppress_tap = false
	_loading_stand = false
	# viewWillAppear: parks the strips pre-swept...
	_apply_entry_offsets()


## viewDidAppear: (0x2C98C): ...and glides both to zero, once the push/pop
## slide is over (on_did_appear).
func _view_did_appear() -> void:
	_start_entry_glide()


# -- construction -------------------------------------------------------

func _tex(art: String) -> Texture2D:
	return Assets.texture(art + ".png")


## parallaxScrollView has no subviews; the fairground backdrop is its
## backgroundColor, a pattern image -- i.e. ff_stand_background.png (320x480)
## tiled across the 1440x480 content. A view's background colour fills its
## whole bounds, so the pattern carries on past either end of the content
## while the front strip rubber-bands (0.4 x the overshoot); one extra tile
## each side covers the most the band can show (it never reaches a full
## screen width). Tiles stay phase-locked to the content origin.
func _build_parallax_background() -> void:
	var tex := _tex("ff_stand_background")
	if tex == null:
		return
	var tile := float(tex.get_width())
	var s := Sprite2D.new()
	s.texture = tex
	s.centered = false
	s.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	s.region_enabled = true
	s.region_rect = Rect2(-tile, 0, PARALLAX_CONTENT_W + 2.0 * tile, 480)
	s.position = Vector2(-tile, 0)
	_back.add_child(s)


func _build_stands() -> void:
	# Pass 1 -- every blob shadow, in construction order. The original adds
	# each shadow as its stand is built and defers all buttons, so the final
	# order is: 20 shadows, then 20 buttons.
	var shadow_tex := _tex("MM_Booth_Blob_Shadow")
	if shadow_tex != null:
		for stand: Dictionary in STANDS:
			if int(stand["tag"]) == TAG_VIDEO and not SHOW_VIDEO_BOOTH:
				continue
			var r: Rect2 = stand["rect"]
			var sh := Sprite2D.new()
			sh.texture = shadow_tex
			sh.centered = true
			sh.position = r.get_center() + SHADOW_OFFSET
			_front.add_child(sh)

	# Pass 2 -- the buttons, in the original's addSubview: burst order.
	var by_tag := {}
	for stand: Dictionary in STANDS:
		by_tag[stand["tag"]] = stand
	for tag: int in BUTTON_Z_ORDER:
		if tag == TAG_VIDEO and not SHOW_VIDEO_BOOTH:
			continue
		var stand: Dictionary = by_tag[tag]
		var r: Rect2 = stand["rect"]
		var btn := TextureButton.new()
		btn.name = "stand_%d" % tag
		# UIButton setBackgroundImage: stretches the art to the frame.
		btn.texture_normal = _tex(stand["art"] as String)
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_SCALE
		btn.position = r.position
		btn.size = r.size
		btn.pressed.connect(_on_stand_clicked.bind(tag))
		_front.add_child(btn)
		# After add_child: core/UIKitButtons connects its own button_down on
		# node_added, and this one must run after it (see _on_stand_down).
		btn.button_down.connect(_on_stand_down.bind(btn))

	# NOT DRAWN, deliberately: the two lock states (lockedStandClicked:
	# 0x2EC88, productPurchased: 0x2F764). The port ships everything
	# unlocked, which the original expresses as:
	#  * donut (18): FF_KEY_DONUT_ICE_CREAM true -> standClicked: target and
	#    no booth_lock.png overlay (frame (0,0,110,196) tag 0x3A0 when locked);
	#  * football toss (17): FF_KEY_CRATE_GAME_1 true ->
	#    ff_stand_football_toss.png, not ..._toss_crate.png.
	# Donut art: stringWithFormat ff_stand_donut%d.png with IAPlist
	# GameData/IceCreamDonutDesign clamped to {1,2}, anything else -> 1. No
	# IAPlist ships, so 1.


func _apply_entry_offsets() -> void:
	# setContentOffset: on both strips (not animated): any touch or flick
	# still recorded from before the push is gone.
	_pan.set_offset(ENTRY_OFFSET)
	_offset = ENTRY_OFFSET
	_front.position = Vector2(-ENTRY_OFFSET, 0)
	_back.position.x = -ENTRY_PARALLAX_OFFSET


## One eased progress value drives both strips -- numerically identical to
## the original's two parallel UIView property animations (each is linear in
## the shared eased progress), and it keeps _offset current at every step.
## The curve is UIKit's default EaseInOut, (0.42, 0, 0.58, 1)
## (UIScrollSim.curve).
func _start_entry_glide() -> void:
	if _front == null or not is_inside_tree():
		return
	if _glide != null and _glide.is_valid():
		_glide.kill()
	_glide = create_tween()
	_glide.tween_method(_glide_step, 0.0, 1.0, ENTRY_GLIDE_SECONDS)


## `t`: linear time through the 2.0 s animation.
func _glide_step(t: float) -> void:
	var p := 1.0 - UIScrollSim.curve(t, UIScrollSim.AnimCurve.EASE_IN_OUT)
	_offset = ENTRY_OFFSET * p
	_pan.set_offset(_offset)
	_front.position.x = -_offset
	_back.position.x = -(ENTRY_PARALLAX_OFFSET * p)


# -- scrolling ----------------------------------------------------------
#
# aScrollView takes every touch on the screen that does not land on the
# views above it (btn_back, the coins panel). A press grabs the strip (and
# stops the entry glide where it is -- see _begin_press); past UIKit's
# 10 pt along x the pan claims the touch and cancels the stand button under
# it; scrollViewDidScroll: (0x2FE68) keeps the parallax strip at 0.4x. During
# the entry glide the original instead animates the back strip 320->0
# alongside the front's 1080->0 (an effective 0.296 ratio -- the original's
# own inconsistency, kept).

## Positions come from the event itself (already in the 320x480 design space
## by the time _input sees them), never from the OS cursor -- synthetic
## events from the test harness do not move the real pointer. Alerts and
## Nav's slide lockout take touches through a gate that marks them handled
## before this runs.
func _input(event: InputEvent) -> void:
	if _pan == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		var p := to_local(mb.position)
		if mb.pressed:
			if _press_blocked(p):
				# Not the scroll view's touch -- and not a stand's either: a
				# stand peeking out under the coins panel never gets it.
				_suppress_tap = true
			else:
				_begin_press(p)
		elif _pan.tracking:
			_end_press(p)
	elif event is InputEventMouseMotion and _pan.tracking:
		_track_drag(to_local((event as InputEventMouseMotion).position))


## A press on a view stacked above the scroll views is that view's: the back
## button (nib object 3), and the coins panel's whole 320x60 frame -- a plain
## UIView, so UIKit's hit test stops on it even between its subviews.
func _press_blocked(p: Vector2) -> bool:
	var back := outlet("btn_back")
	if back == null:
		back = get_node_or_null("btn_back")
	if back is Control and (back as Control).is_visible_in_tree() \
			and Rect2((back as Control).position, (back as Control).size).has_point(p):
		return true
	var coins := get_node_or_null("CoinInfoView")
	if coins is CanvasItem and (coins as CanvasItem).visible \
			and Rect2((coins as Node2D).position, COIN_PANEL_RECT.size).has_point(p):
		return true
	return false


func _begin_press(p: Vector2) -> void:
	if _glide != null and _glide.is_valid():
		# PORT CHOICE (kept from the earlier port): a touch during the 2.0 s
		# entry sweep stops it where it is and the strip is grabbed there.
		# From the original binary: the sweep is a
		# +beginAnimations: block (viewDidAppear: 0x2C98C), so UIKit leaves
		# touches on and hit-tests the MODEL -- contentOffset is already 0 --
		# and the drawn strip would glide on toward wherever a drag moves the
		# model (a fromValue-only CABasicAnimation, UIKit 0x32F34998). A tap
		# would therefore pick the stand at its final place, not the one
		# drawn under the finger. Not reproduced: the stands are Controls,
		# which Godot hit-tests where they are drawn. Touches are allowed
		# either way, and the picture and the model agree from the press on.
		_glide.kill()
		_pan.set_offset(_offset)
	_pan.press(p)
	_suppress_tap = _pan.caught
	_did_scroll()


func _track_drag(p: Vector2) -> void:
	if _pan.move(p):
		_did_scroll()
	if _pan.dragging() and not _suppress_tap:
		# The pan claimed the touch: the stand under the finger loses it
		# (canCancelContentTouches YES).
		_suppress_tap = true
		_cancel_stand_touches()


func _end_press(p: Vector2) -> void:
	if not _pan.release(p):
		_suppress_tap = true
	_did_scroll()
	# The stand button sees this release after _input; _on_stand_clicked
	# drops it when _suppress_tap is set.


## A stand went down. If the touch is the scroll view's (it caught the strip
## moving) or the coins panel's, UIKit never handed it to the button: cancel
## it (deferred, so it runs after core/UIKitButtons has seen the press).
func _on_stand_down(btn: BaseButton) -> void:
	if _suppress_tap:
		_cancel_button.call_deferred(btn)


func _cancel_stand_touches() -> void:
	for c in _front.get_children():
		if c is BaseButton and (c as BaseButton).is_pressed():
			_cancel_button(c)


## touchesCancelled: for a stand button: it stops tracking without firing
## (disabled for an instant drops Godot's press; button_up, emitted while
## disabled, lets UIKitButtons drop its highlight without firing either).
func _cancel_button(btn: BaseButton) -> void:
	if not is_instance_valid(btn):
		return
	btn.disabled = true
	btn.button_up.emit()
	btn.disabled = false


func _process(delta: float) -> void:
	if _pan != null and _pan.step(delta):
		_did_scroll()


## Test / harness helper: setContentOffset: on the front strip.
func _set_offset(x: float) -> void:
	if _glide != null and _glide.is_valid():
		_glide.kill()
	_pan.set_offset(x)
	_did_scroll()


## scrollViewDidScroll: (0x2FE68): the parallax strip follows at 0.4x,
## un-animated; y stays 0.
func _did_scroll() -> void:
	_offset = _pan.offset()
	_sync_strips()


func _sync_strips() -> void:
	_front.position = Vector2(-_offset, 0)
	_back.position.x = -(_offset * PARALLAX_RATE)


# -- the stands ---------------------------------------------------------

func _on_stand_clicked(tag: int) -> void:
	if _suppress_tap:
		# The pan claimed this touch; UIScrollView would have cancelled the
		# button's tracking before the release.
		return
	if _loading_stand:
		return
	if tag != TAG_VIDEO:
		_loading_stand = true

	# The one-time "Notice:" (standClicked: 0x2ED74, before the switch): if
	# defaults has no "<stringForStandEnumerator:>_HAS_RUN" and the tag is
	# neither 18 (donut) nor 19 (video), firstTimeEnteringSection: (0x2FDE8)
	# shows UIAlertView "Notice:" / messageForAlertView: (0x2FC60) / "OK",
	# delegate self but no alertView: method -- OK just dismisses, silently.
	# The key is then set for EVERY tag, 18 and 19 included.
	#
	# PORT CHOICE (no ads or purchases in this port): every notice
	# message says the stand shows ads until its pack is bought -- the port
	# has neither ads nor purchases, so the notice is never shown. The
	# HAS_RUN key is still written, as the original does.
	var key := "%s_%s" % [_stand_key(tag), "HAS_RUN"]
	var notice := ""
	if SHOW_AD_NOTICES and not Defaults.bool_for_key(key) \
			and tag != TAG_DONUT and tag != TAG_VIDEO:
		notice = str(NOTICE_MESSAGES.get(tag, ""))
	Defaults.set_bool_for_key(true, key)

	if FOOD_BY_TAG.has(tag):
		Nav.start_food(FOOD_BY_TAG[tag] as String)
	elif MIDWAY_BY_TAG.has(tag):
		Nav.push(MIDWAY_BY_TAG[tag] as String)
	elif tag == TAG_VIDEO:
		_show_no_videos_alert()
	# The switch's default is an NSAssert; unreachable from the built tags.

	# UIAlertView is window-level: shown before the push, it stays up over the
	# pushed screen. The port's push frees this node, so the alert goes on the
	# screen that now owns the window.
	if notice != "":
		var top: Node = Nav.current_node()
		if top != null and top != self and top.has_method("show_alert"):
			top.call("show_alert", notice, ["OK"], Callable(), false, NOTICE_TITLE)

	# 0x2F5AA: every path out of standClicked: ends in
	# [AudioManager playFile:@"button_press" ofType:@"mp3"].
	Audio.play("button_press")


## stringForStandEnumerator: (0x2FACC) -- the STANDS table's `key`.
func _stand_key(tag: int) -> String:
	for stand: Dictionary in STANDS:
		if int(stand["tag"]) == tag:
			return str(stand["key"])
	return ""


## The rewards-cinema booth (tag 19). With connectivity the original hands
## off to the ad SDK (displayV4VCForLocation:); the port has no ad SDK, so
## it always takes the grounded offline branch: a UIAlertView titled
## "Sorry!" / "Ok", delegate nil (0x2ED74) -- so its Ok is silent. Only the
## message is the port's own (NO_VIDEOS_MESSAGE).
func _show_no_videos_alert() -> void:
	show_alert(NO_VIDEOS_MESSAGE, ["Ok"], Callable(), false, NO_VIDEOS_TITLE)


## backClick: (0x2F92C): button_press.mp3, then pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


# NOT PORTED, deliberately, rather than guessed:
#
#  * delaysContentTouches' 0.15 s hold-off before a stand button highlights
#    (UIKit _touchDelayForScrollDetection 0x3304DCE0): the stands are Godot
#    TextureButtons, which take the press at once; the pan still cancels
#    them past 10 pt, as UIKit does.
#  * The BoothDisplaySingleRow single-row layout (values in the header) --
#    dormant remote-config, unreachable with the shipped bundle.
#  * flurryClick: (video clips) and MoreGamesClick: (Chartboost) -- ad and
#    cross-promo surfaces the port ships without; their buttons are hidden.
