# Candy Apple step 2 -- hose the dirt off five apples in the wash basket.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithNibName: 0x14DF20, viewDidLoad 0x14E0CC, viewWillAppear: 0x14EAF8,
#   viewWillDisappear: 0x14EE48, splashTick 0x14EFA8, showNextButton 0x14F2E4,
#   draggableTouchBegan/Moved/Ended 0x14FAAC/0x14FBF8/0x14FCCC,
#   changeInstruction: 0x14FD58, nextClick: 0x15003C.
#
# Mechanic, as read: the water jet (ca_waterjet.png, a DraggableIV with an
# explicit 296x234 frame -- true centre) hangs at (400,250), clamped to
# centre x 275..400, y 200..300 (setMinX/MaxX/MinY/MaxY, integer ivars).
# Holding it plays ca_water_jet and shows a 3-frame water spray
# (SpriteSheetView over ca_Water_Animation_Sheet.png, 200x221 cells) at the
# jet centre + (-212, +6) (0xC3540000 / +6.0). A 0.1s timer (splashTick)
# advances the spray frame and, while the spray's frame intersects the
# basket's (25,150,269,258), fades every dirt overlay by 0.025 per tick.
# All five dirts fade in lockstep, so at tick 40 (4s of spraying) all hit
# 0.0 together, dirtHitCount jumps 0 -> 5, and next slides in.
#
# PORTED QUIRKS:
#  * splashTick resets currentFrameIdx when >= 5, but tick() wraps at
#    rows*columns = 3 (SpriteSheetView 0x47770/0x47910), so the guard is
#    dead. The sheet is 600x442 but rows=1: the bottom half is never shown.
#  * dirtHitCount increments once per tick for EVERY dirt at alpha <= 0
#    (CALayer clamps stored alpha to 0), and completion tests == 5 exactly.
#    Lockstep fading makes that exact; ported verbatim.
#
# WATER SPLASH, PORTED (the coin consumable; the phone shows its badge).
# Read from:
#   initWithNibName: 0x14DF20  Consumable DM_CONSUMABLE_WATERSPLASH /
#     Hose_20Clean, cost = server table GameData.CoinCosts."Candy Apple".
#     ToolWaterSplash, 11 when absent; first-time message "Try out the Water
#     Splash! Easily clean apple! Try it for FREE now!".
#   viewDidLoad 0x14E0CC  ConsumableButton(btn_IAP_background, mask,
#     btn_IAP_waterSplash.png, border, lable, offsets (0,-25) / (65,3)),
#     added last (on top), centre (50, 350.5), target buyClick:.
#   viewWillAppear: 0x14EAF8  badge shown again.
#   buyClick: 0x14FF60  "store" sound, purchaseConsumable.
#   consumablePurchased: 0x14F7F8  quantity = 1 (never read back),
#     showSplash, badge hidden.
#   showSplash 0x14F4F0  changeInstruction: inst_spray_pops.png (the asset is
#     absent from the IPA: initWithContentsOfFile: of a nil path gives nil,
#     so the banner slides in BLANK, where the port used to keep the
#     clean-dirt art; next is hidden by the same call), every dirt overlay
#     back to alpha 1, dirtHitCount 0, the waterSplash SSEmitter started,
#     "ca_water_splash" looped, the jet hidden, then every dirt overlay
#     animated to alpha 0 over 1.0 s (UIView default curve), and stopSplash
#     scheduled 1.0 s out.
#   stopSplash 0x14F480  "ca_water_splash" stopped, emitter stopped,
#     showNextButton.
# The nib's waterSplash SSEmitter is wired as the original configures it
# in viewDidLoad (0x14E0CC, call 0x14E850:
# ca_waterdrop.png, no tint, interval 0.01, duration 0.8, repeat, final
# centre (0,500), alpha 0 -> 1, scale 1, variance [5,0,300,0], options 3),
# started by showSplash, stopped by stopSplash. viewDidLoad brings the
# emitter to the front after adding basketView and then adds the 320x480
# jetSplashView above it, so the drops fall in front of the basket and
# behind the jet. Its delegate callbacks getCCContainerTip 0x14F248 /
# hasFinishedGrabbingAllDirtParticles 0x14F470 are never reached (SSEmitter
# has no delegate calls). The splashTick timer keeps running after the
# splash in the original; with the jet hidden it does nothing, as here.
#
# KEEP STATE: the controller survives under caSelectStick, and
# viewWillAppear: (0x14EAF8) -- which holds the whole reset -- re-runs on
# return: jet back to (400,250) and unhidden, badge unhidden, next hidden,
# back to the front, "inst_clean_dirt" slid in, a NEW 0.1 s splashTimer,
# every dirt back to alpha 1, dirtHitCount 0. So coming back here the apples
# are dirty again and must be re-washed before next returns.

extends "res://core/Screen.gd"

const DraggableSprite := preload("res://core/DraggableSprite2D.gd")
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")
const SPLASH_KEY := "caCleanDirt.waterSplash"

## Water splash consumable (see header).
const HOSE_KEY := "DM_CONSUMABLE_WATERSPLASH"
const HOSE_NAME := "Hose_20Clean"
const HOSE_COST := 11
const HOSE_MESSAGE := "Try out the Water Splash! Easily clean apple! Try it for FREE now!"
const HOSE_BADGE_ART := "btn_IAP_waterSplash.png"
const HOSE_BADGE_CENTER := Vector2(50, 350.5)
const SPLASH_SECONDS := 1.0                   # the dirt fade
const SPLASH_STOP_DELAY := 1.0                # performSelector: stopSplash

## viewDidLoad: basketView frame (25,150,269,258) (0x41C80000/0x43160000/
## 0x43868000/0x43810000); ca_pot.png centre (160,290) (0x43910000).
const BASKET_RECT := Rect2(25, 150, 269, 258)
const POT_CENTER := Vector2(160, 290)
## Five apples (infoDict["Image"], 269x258 art) and five caDusting.png
## overlays, all transform-scaled 0.3, at these centres inside basketView.
const SLOT_CENTERS: Array[Vector2] = [
	Vector2(55, 155), Vector2(130, 155), Vector2(205, 155),
	Vector2(95, 105), Vector2(175, 105),
]
const SLOT_SCALE := 0.3

## The jet: home centre (400,250) (0x43C80000/0x437A0000), frame 296x234,
## snapTime 0.3 (0x3E99999A), clamps minX 275 / maxX 400 / minY 200 /
## maxY 300 (integer setters, viewDidLoad 0x14E0CC).
const JET_HOME := Vector2(400, 250)
const JET_BOUNDS := Rect2(275, 200, 125, 100)
const JET_SNAP := 0.3

## Spray sprite: 200x221 cells, 3 columns (0x43480000/0x435D0000, cols 3
## rows 1); centre = jet centre + (-212, +6).
const SPRAY_CELL := Vector2(200, 221)
const SPRAY_FRAMES := 3
const SPRAY_OFFSET := Vector2(-212.0, 6.0)

## splashTick timer 0.1s (double 0x3FB999999999999A, viewWillAppear).
const TICK_S := 0.1
## Dirt alpha step per tick (-0.025, splashTick 0x14F0BE).
const DIRT_STEP := 0.025
const DIRT_COUNT := 5

var _jet: DraggableSprite
var _spray: Sprite2D
var _spray_idx := 0
var _basket: Node2D
var _dirts: Array[Sprite2D] = []
var _jet_touched := false
var _hit_count := 0
var _timer: Timer

var _hose: RefCounted
var _hose_badge: TextureButton
var _splash: SSEmitter                       # nib waterSplash


func on_enter() -> void:
	# viewDidLoad: pot, basket, the waterSplash emitter brought to the front,
	# jetSplashView (jet + spray), the hose badge on top.
	_build_basket()
	_build_splash_emitter()
	_build_jet()
	_timer = Timer.new()
	_timer.wait_time = TICK_S
	_timer.timeout.connect(_splash_tick)
	add_child(_timer)
	_build_hose_badge()
	_view_will_appear()


## viewWillAppear: (0x14EAF8) -- the first appearance and every return.
func _view_will_appear() -> void:
	if _jet != null:
		# setCenter:(400,250) and setHidden:NO. A hidden UIView takes no
		# touches; unhiding it makes it draggable again (showSplash hid it).
		_jet.position = JET_HOME
		_jet.visible = true
		_jet.enabled = true
	_place_spray()
	if _hose_badge != null:
		_hose_badge.visible = true
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	# bringSubviewToFront: backButton (0x14EB6C).
	var b := outlet("backButton")
	if b != null and b != self:
		move_child(b as Node, get_child_count() - 1)
	change_instruction("inst_clean_dirt.png")
	# scheduledTimerWithTimeInterval:0.1 (double 0x3FB99999A0000000), repeats.
	_timer.start()
	# Every tag-100 dirt back to alpha 1; dirtHitCount 0.
	for d in _dirts:
		d.modulate.a = 1.0
	_hit_count = 0


## UINavigationController keeps this controller alive under caSelectStick
## (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from caSelectStick: only viewWillAppear: runs again -- the full reset
## above (see header). There is no viewDidAppear:.
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		# CoinHUD re-adds the panel after this (Nav.screen_changed); drop the
		# copy from the first appearance, as MakeViewController does.
		remove_child(old)
		old.queue_free()
	_view_will_appear()


## viewDidLoad (0x14E0CC): the nib's waterSplash SSEmitter, frame
## (129,0,62,33), configured with tint nil, and brought to the front right
## after basketView is added -- above the basket, below jetSplashView.
func _build_splash_emitter() -> void:
	var host := outlet("waterSplash")
	if host == null or host == self:
		return
	move_child(host, get_child_count() - 1)
	_splash = SSEmitter.attach(host, SSEmitterConfigs.frame_size(SPLASH_KEY)) as SSEmitter
	SSEmitterConfigs.apply(_splash, SPLASH_KEY, null)


# -- water splash ----------------------------------------------------------

## initWithNibName: + viewDidLoad: the Consumable and its badge, on top.
func _build_hose_badge() -> void:
	_hose = ConsumableScript.new(HOSE_KEY, HOSE_NAME, HOSE_COST)
	_hose.set("first_time_message", HOSE_MESSAGE)
	_hose.set("quantity", 0)                 # initWithNibName: setQuantity:0
	_hose.set("on_purchased", _on_hose_purchased)
	_hose.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyHose"
	b.call("setup", HOSE_BADGE_ART, 0, -25, HOSE_COST, 65, 3)
	b.position = HOSE_BADGE_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyClick)
	add_child(b)
	_hose_badge = b


## buyClick: (0x14FF60).
func _on_buyClick() -> void:
	Audio.play("store")
	_hose.call("purchase", self)


## consumablePurchased: (0x14F7F8).
func _on_hose_purchased(_free: bool) -> void:
	_hose.set("quantity", 1)
	_show_splash()
	if _hose_badge != null:
		_hose_badge.visible = false


## showSplash (0x14F4F0).
func _show_splash() -> void:
	# The art does not ship: the original's setImage: gets nil and the
	# banner slides in empty -- Screen.change_instruction blanks it itself.
	change_instruction("inst_spray_pops.png")
	for d in _dirts:
		d.modulate.a = 1.0
	_hit_count = 0
	if _splash != null:
		_splash.start()                      # [waterSplash start]
	Audio.loop("ca_water_splash")
	if _jet != null:
		_jet.enabled = false
		_jet.visible = false
	if _spray != null:
		_spray.visible = false
	_jet_touched = false
	Audio.stop("ca_water_jet")
	for d in _dirts:
		create_tween().tween_property(d, "modulate:a", 0.0, SPLASH_SECONDS) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# performSelector:@selector(stopSplash) afterDelay:1.0 retains the
	# controller, so stopSplash runs even if back popped the screen in that
	# second: the sound stop is bound to the Audio autoload so it survives a
	# freed screen; the rest only matters while the screen exists.
	var t := get_tree().create_timer(SPLASH_STOP_DELAY)
	t.timeout.connect(Audio.stop.bind("ca_water_splash"))
	t.timeout.connect(_stop_splash)


## stopSplash (0x14F480): stop the loop, stop the emitter, showNextButton.
## (No viewWillDisappear: work stops the emitter; live drops finish.)
func _stop_splash() -> void:
	Audio.stop("ca_water_splash")
	if _splash != null:
		_splash.stop()
	# Next is hidden for the whole splash, so nothing can push over this
	# screen in that second; out of the tree here means it is being freed.
	if not is_inside_tree():
		return
	var n := outlet("nextButton")
	if n != null and n != self:
		move_child(n as Node, get_child_count() - 1)
	show_next_button()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## viewDidLoad: pot first (behind the basket contents), then five apples,
## each immediately followed by its dirt overlay (tag 100 in the original).
func _build_basket() -> void:
	var pot := Sprite2D.new()
	pot.texture = _tex("ca_pot.png")
	pot.position = POT_CENTER
	add_child(pot)

	_basket = Node2D.new()
	_basket.position = BASKET_RECT.position
	add_child(_basket)

	var apple_tex := _tex(str(GameState.custom_categories.get("Image", "")))
	var dirt_tex := _tex("caDusting.png")
	for c in SLOT_CENTERS:
		# Entered standalone the carrier is empty and the apples are absent
		# rather than invented (house rule; cdStir does the same).
		if apple_tex != null:
			var a := Sprite2D.new()
			a.texture = apple_tex
			a.position = c
			a.scale = Vector2(SLOT_SCALE, SLOT_SCALE)
			_basket.add_child(a)
		if dirt_tex != null:
			var d := Sprite2D.new()
			d.texture = dirt_tex
			d.position = c
			d.scale = Vector2(SLOT_SCALE, SLOT_SCALE)
			_basket.add_child(d)
			_dirts.append(d)


func _build_jet() -> void:
	# jetSplashView is a full-screen container; the spray sits above the jet.
	_jet = DraggableSprite.new()
	_jet.texture = _tex("ca_waterjet.png")
	_jet.position = JET_HOME
	_jet.snap_back = true
	_jet.snap_time = JET_SNAP
	_jet.drag_bounds = JET_BOUNDS
	add_child(_jet)
	_jet.capture_origin()
	_jet.drag_started.connect(_on_jet_began)
	_jet.drag_moved.connect(_on_jet_moved)
	_jet.drag_ended.connect(_on_jet_ended)

	_spray = Sprite2D.new()
	_spray.texture = _tex("ca_Water_Animation_Sheet.png")
	_spray.region_enabled = true
	_spray.region_rect = Rect2(Vector2.ZERO, SPRAY_CELL)
	_spray.visible = false
	add_child(_spray)
	_place_spray()


func _place_spray() -> void:
	if _spray != null and _jet != null:
		_spray.position = _jet.position + SPRAY_OFFSET


## draggableTouchBegan: (0x14FAAC).
func _on_jet_began() -> void:
	Audio.loop("ca_water_jet")
	_spray.visible = true
	_jet_touched = true
	_place_spray()


func _on_jet_moved(_pos: Vector2) -> void:
	_place_spray()


## draggableTouchEnded: (0x14FCCC). DraggableSprite2D handles the snap home.
func _on_jet_ended(_pos: Vector2, _hit: bool) -> void:
	Audio.stop("ca_water_jet")
	_spray.visible = false
	_jet_touched = false


## splashTick (0x14EFA8), on the 0.1s timer.
func _splash_tick() -> void:
	if not _jet_touched:
		return
	# `if currentFrameIdx >= 5: reset` -- dead, tick() wraps at 3. Kept as a
	# comment, not code.
	_spray.region_rect = Rect2(Vector2(SPRAY_CELL.x * _spray_idx, 0), SPRAY_CELL)
	_spray_idx = (_spray_idx + 1) % SPRAY_FRAMES
	var spray_rect := Rect2(_spray.position - SPRAY_CELL * 0.5, SPRAY_CELL)
	if not spray_rect.intersects(BASKET_RECT):
		return
	for d in _dirts:
		# CALayer clamps stored alpha to [0,1]; every dirt already at 0
		# keeps incrementing the count each tick, exactly as shipped.
		d.modulate.a = clampf(d.modulate.a - DIRT_STEP, 0.0, 1.0)
		if d.modulate.a <= 0.0:
			_hit_count += 1
	if _hit_count == DIRT_COUNT:
		# showNextButton (0x14F2E4) brings the button to the front first.
		var n := outlet("nextButton")
		if n != null and n != self:
			move_child(n as Node, get_child_count() - 1)
		show_next_button()
		_timer.stop()


## nextClick: (0x15003C): button_press, push caSelectStick with the same
## infoDict (the carrier already holds the apple's image names).
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.next()


## viewWillDisappear: (0x14EE48) invalidates the timer -- nothing else.
## PORT CHOICE: ca_water_jet is also stopped. On the phone that loop only
## plays while a finger holds the jet, and draggableTouchEnded: stops it; a
## Godot screen leaving the tree can lose that release, so the loop would
## otherwise outlive the screen.
func on_exit() -> void:
	if _timer != null:
		_timer.stop()
	Audio.stop("ca_water_jet")


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true


## backClick: (0x14FFCC): button_press, then pop. Screen's default pops
## silently, so every original back press was missing its click.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()
