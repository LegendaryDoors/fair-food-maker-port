# Chocolate Covered Banana step 7 -- sink the dipped banana into the flash
# freezer, wait for the frost, then hand the finished food to
# MakeViewController.
#
# From the original binary (entry points from the ObjC method list; the
# state-4 sound's string arguments read from the disassembly at
# 0xF8F5E..0xF8F7C):
#   initWithDictionary: 0xF9A88, viewDidLoad 0xFA744, viewWillAppear: 0xFAB44,
#   viewWillDisappear: 0xFACA4, startChill 0xFAD54 (an EMPTY function that
#   viewWillAppear still schedules 0.5s out -- a no-op, ported as nothing),
#   resetScreen 0xF91A4, resetIcePop 0xF9078, fadeIcePop 0xF8D90,
#   startIcePopFadeTimer 0xF8F90, stopFadeTimerForIcePop 0xF884C,
#   checkFreezerSoundPlayer 0xF89F0, showNextButtonWhenIcePopIsReady 0xF87A4,
#   showNextButton 0xF85C8, draggableTouchBegan/Moved/Ended
#   0xFBBD8/0xFBCB8/0xFBE90, backClick: 0xFADD0, nextClick: 0xFAEA8,
#   skipClick: 0xFB474 (forwards to nextClick:; its nib button at
#   (200,377,120,40) is UIHidden=YES and never unhidden -- unreachable),
#   changeInstruction: 0xF9864.
#
# NOT the same mechanic as ipFreezer, despite the shared method names. The
# pop is a DraggableIV built by initWithDictionary: exactly like
# ccbDipBanana's lollipop -- clear 325x400 container, scale 0.45, home
# (160,140) -- with one extra child: mold = Frozen_Banana.png (the frost
# coat), rotated 3.1416 like the banana and coating, centred at
# banana.centre + (0,-6), starting at ALPHA 0. There is no juice, no
# texture layer (the `texture` ivar is never assigned -- resetIcePop's
# setAlpha:0.2 on it is a message to nil), and the frost fades IN, not out:
#
#  * Dragging (draggableTouchMoved 0xFBCB8, delegate-side clamps -- the
#    DraggableIV min/max stay at their INT_MIN/INT_MAX defaults, 0x4638C):
#    centre clamped to x in [110,210] (0x42DC0000/0x43520000) and
#    y <= 300 (0x43960000).
#  * Release with centre.y > 210 (0xFBE90): clamp again, "DropIcePop" 0.5s
#    curve 3 (linear) to y=300, interaction OFF (the pop never comes back
#    out on the free path), instruction hidden, soaked, and the fade timer
#    starts -- 2.0s per tick without the freeze gun (0xF8F90; the gun
#    shortens it to 0.7).
#  * fadeIcePop (0xF8D90): old = state++; while old <= 4 and soaked the
#    frost gains 0.25 alpha over a 0.5s linear "FadeOutMold" tween (the
#    name is inherited; here it fades IN). At state 4 (8s) it plays
#    "liquid freeze_03"; at state 5 (10s) it stops the timer and slides the
#    next button in -- with the pop still sitting in the freezer.
#  * Release with centre.y <= 210 (only possible before the first drop):
#    showNextButtonWhenIcePopIsReady (0xF87A4 -- state!=4 hides next, a
#    no-op at state 0), "SnapIcePop" 0.2s (double 0x3FC999999999999A) curve
#    3 back home, soaked off, timer stopped.
#  * checkFreezerSoundPlayer (0xF89F0): "liquid freeze_04" loops while
#    soaked, stops otherwise. freezer_02 loops for the whole screen.
#
# FREEZE GUN (the coin consumable, ported; the original shows its badge on
# the phone). Read from:
#   initWithDictionary: 0xF9A88  Consumable DM_CONSUMABLE_FREEZE_GUN /
#     Sprayer_70Dip, cost = server table GameData.CoinCosts."Chocolate Dipped
#     Banana".ToolFreezeGun, 11 when absent; quantity set to 0 at init.
#   viewDidLoad 0xFA744  ConsumableButton(btn_IAP_background, mask,
#     freeze_gun_upgrade.png scaled proportionally into 60x60, border,
#     lable, offsets (0,-25) / (65,3)), inserted above instIV, centre
#     (50, 350.5), target buyClick:.
#   buyClick: 0xFAD64  "store" sound, purchaseConsumable.
#   consumablePurchased: 0xFC2EC  quantity = 1, resetIcePop, showFreezeGun,
#     instIV hidden, badge hidden, the coins panel removed from the view.
#   showFreezeGun 0xFB484  "HideFreezer" 0.5 s: the freezer art's centre
#     y += 500, the pop's transform rotated by 3.1416 and its centre moved
#     to (240,220); pop interaction OFF; freezer_02 and liquid freeze_04
#     stopped; the gun = DraggableIV Freeze_Gun.png (169x117) at centre
#     (100,230), inserted above the pop, origCenter there, snapTime 0.5.
#   draggableTouchBegan (gun) 0xFBBD8  freezeSpray every 0.05 s, soaked,
#     startIcePopFadeTimer (0.7 s per tick while the spray timer runs,
#     0xF8F90), loop freezer_02.
#   draggableTouchMoved (gun) 0xFBCB8  centre.y >= 250 -> not soaked and
#     the fade timer stopped; else soaked and the timer (re)started. No
#     position clamps on the gun.
#   draggableTouchEnded (gun) 0xFBE90  spray timer invalidated, not
#     soaked, fade timer stopped, freezer_02 stopped; DraggableIV snaps home.
#   freezeSpray 0xFB778  a Freeze_Spray_{1..3}.png puff at scale 0.2 below
#     the gun, centre (gun.x + 70, gun.y - 25); animateWithDuration 2.0,
#     curve ease-out (0x20000): centre += (230, rand % 100), scale x5,
#     alpha 0 (sub_FB9F8), removed on completion (sub_FBBA8); the animation
#     block calls showNextButton when icePopState == 4.
#   fadeIcePop 0xF8D90  the sound (state 4) and the finish (state 5) run
#     only while the spray timer is NOT valid; with the gun held the frost
#     just gains 0.25 per 0.7 s tick and the puff block finishes the screen.
#   showNextButton 0xF85C8  also hides instIV and the badge.
#   resetScreen 0xF91A4  with boughtFreezeGun: gun removed, badge shown,
#     freezer art back up 500 -- the re-appear path, taken on a return from
#     Make (see KEEP STATE below).
# PORT CHOICES: the puff block calls showNextButton on EVERY puff spawned
# while the state is 4 (about 14 in the 0.7 s window), restarting the slide
# each time; the port finishes once. The pop's rotation and slide share one
# 0.5 s ease-in-out tween (UIView default curve).
#
# DEAD / UNREACHABLE, NOT PORTED:
#   rotatePerfectlyFrozenIcePop 0xF9310 (rotate 2.3562 over 0.6s) and
#   animateRemoveMold 0xF9470 (egg_crack; two flying halves built from
#   infoDict["moldImg"] -- a key NOTHING in the ccb flow ever writes, so
#   the halves would be imageless even then) run only from touchEnded's
#   state==4 branches, which need the pop draggable at state 4 -- and the
#   gun turns the pop's interaction OFF, so they stay unreachable. Likewise
#   shakeIcePopForDuration: 0xF8888, overFreezeIcePop 0xF8CA8,
#   showRedCrossAtPoint:/removeRedCross 0xF8738/0xF877C (the ff_red_x
#   cross parks at (-100,-100) and nothing ever shows it),
#   resizeImage: 0xF85A0 (no caller) and the AdColony hook.
#
# Corrections from a full re-read of the original:
#  * Layering: initWithDictionary: asks for [self view] (loading the nib
#    and running viewDidLoad, which inserts the badge above instIV) and
#    only THEN addSubview:s the pop -- so the pop is the topmost view, over
#    instIV, the badge and the buttons, and the gun goes above it. The port
#    had the pop under instIV and the badge.
#  * PORT CHOICE: the bake below is merged into the carrier instead of
#    replacing it (Stick, Color, GratedOrigY ride along). The screen now
#    also keeps its own infoDict (_info) and survives under Make, so
#    the merge is no longer what a return relies on; it is kept because Make
#    skips entries that are not {Properties, Image} dictionaries anyway.
#
# KEEP STATE: the controller survives under MakeViewController. On
# return viewWillAppear: (0xFAB44) re-runs: instIV and the freeze-gun badge
# unhidden, freezer_02 looped, and resetScreen (0xF91A4) -> resetIcePop
# (0xF9078): the fade timer invalidated, not soaked, state 0, the pop back
# at origCenter (160,140), interactive, alpha 1, the frost at alpha 0, its
# transform reset to scale 0.45 (undoing the gun's 3.1416 turn);
# "inst_flash_freezer" slid in; if the gun had been bought it is removed,
# the badge shown and the freezer art moved back up 500; next hidden. The
# banana must be frozen again. viewWillDisappear: (0xFACA4) stops
# freezer_02 and "liquid freeze_04" and invalidates the fade timer.
#
# nextClick: (0xFAEA8) BAKES the finished food (this food's bake lives
# here, not on the dip screen) -- three layers, art at natural size, the
# centres being TOP-LEFTs (zero-frame DecorateItemView):
#   BananaStick       infoDict[Stick],          VI 4, (140,187), inedible
#   Banana            banana_for_stick.png,     VI 5, (97,52.5), edible, Layer 2
#   ChocolateCoating  cc_banana.png alt-tinted with Color (blend 3 Overlay),
#                                               VI 6, (103,62.5), edible, Layer 1
# (floats 0x430C0000=140... ItemCenterX literals: 140.0/187.0, 97.0/52.5,
# 103.0/62.5 at 0xFAF44..0xFB0FC.) classStr "Chocolate Dipped Banana".

extends "res://core/Screen.gd"

const caSelectChocolate := preload("res://screens/caSelectChocolate.gd")
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const DraggableSprite := preload("res://core/DraggableSprite2D.gd")

## Freeze gun consumable (see header).
const GUN_KEY := "DM_CONSUMABLE_FREEZE_GUN"
const GUN_NAME := "Sprayer_70Dip"
const GUN_COST := 11
const GUN_MESSAGE := "Try out the Freeze Gun! Easily freeze Chocolate Dipped Banana! Try it for FREE now!"
const GUN_BADGE_ART := "freeze_gun_upgrade.png"
const GUN_BADGE_CENTER := Vector2(50, 350.5)
const GUN_ART := "Freeze_Gun.png"
const GUN_HOME := Vector2(100, 230)           # 0x42C80000 / 0x43660000
const GUN_SNAP := 0.5                         # 0x3F000000
const GUN_STOP_Y := 250.0                     # touchMoved: y >= 250 stops
const GUN_FADE_INTERVAL := 0.7                # startIcePopFadeTimer with the gun
const GUN_NEXT_STATE := 4                     # the puff block's showNextButton
const HIDE_FREEZER_DY := 500.0                # 0x43FA0000
const HIDE_FREEZER_SECONDS := 0.5
const POP_GUN_CENTER := Vector2(240, 220)     # 0x43700000 / 0x435C0000
const SPRAY_INTERVAL := 0.05                  # 0x3FA999999999999A
const SPRAY_SCALE0 := 0.2
const SPRAY_SCALE_MUL := 5.0
const SPRAY_OFFSET := Vector2(70, -25)        # 0x428C0000 / -25.0
const SPRAY_DX := 230.0                       # 0x43660000
const SPRAY_DY_RANGE := 100                   # arc4random() % 0x64
const SPRAY_SECONDS := 2.0

## initWithDictionary: (0xF9A88): container 325x400, scale 0.45, home
## (160,140); children relative to the container's UIKit centre.
const POP_SIZE := Vector2(325, 400)
const POP_SCALE := 0.45
const POP_HOME := Vector2(160, 140)
const BANANA_DX := -8.0
const COATING_DY := 28.0
const MOLD_DY := -6.0
const PART_ROTATION := 3.1416                 # the shipped literal
## draggableTouchMoved (0xFBCB8): centre x in [110,210], y <= 300.
const DRAG_MIN_X := 110.0
const DRAG_MAX_X := 210.0
const DRAG_MAX_Y := 300.0
## draggableTouchEnded (0xFBE90): centre.y > 210 means "into the freezer".
const FREEZER_Y := 210.0
const SOAK_Y := 300.0
const DROP_SECONDS := 0.5                     # "DropIcePop", curve 3
const SNAP_SECONDS := 0.2                     # "SnapIcePop", 0x3FC999999999999A
## startIcePopFadeTimer (0xF8F90): 2.0s per tick, no freeze gun.
const FADE_INTERVAL := 2.0
## fadeIcePop (0xF8D90): +0.25 frost alpha per tick over 0.5s, curve 3.
const FADE_STEP := 0.25
const FADE_SECONDS := 0.5
const SOUND_STATE := 4                        # "liquid freeze_03"
const DONE_STATE := 5

## nextClick: (0xFAEA8) bake -- top-left placements, see header.
const STICK_TOP_LEFT := Vector2(140, 187)
const BANANA_TOP_LEFT := Vector2(97, 52.5)
const COATING_TOP_LEFT := Vector2(103, 62.5)

var _pop: Node2D
var _mold: Sprite2D                           # the frost coat
var _state := 0                               # icePopState
var _soaked := false
var _done := false
var _fade_timer: Timer
var _dragging := false
var _grab := Vector2.ZERO
## The "SnapIcePop" glide home (see _released).
var _pop_snap: Tween

var _freeze_gun: RefCounted
var _gun_badge: TextureButton
var _gun: DraggableSprite
var _gun_bought := false                      # boughtFreezeGun
var _gun_held := false                        # freezeSprayTimer isValid
var _spray_timer: Timer
## The shared infoDict (initWithDictionary:'s argument; see
## ccbSelectStickViewController._info).
var _info: Dictionary = {}


func on_enter() -> void:
	_info = GameState.custom_categories
	_build_pop()
	_fade_timer = Timer.new()
	_fade_timer.wait_time = FADE_INTERVAL
	_fade_timer.one_shot = false
	_fade_timer.timeout.connect(_fade_tick)
	add_child(_fade_timer)
	_spray_timer = Timer.new()
	_spray_timer.wait_time = SPRAY_INTERVAL
	_spray_timer.one_shot = false
	_spray_timer.timeout.connect(_freeze_spray)
	add_child(_spray_timer)
	_build_gun_badge()
	# initWithDictionary: adds the pop after the nib and viewDidLoad's badge:
	# it is the topmost view (see header).
	move_child(_pop, get_child_count() - 1)
	_view_will_appear()


## viewWillAppear: (0xFAB44) -- the first appearance and every return. (The
## 0.5 s performSelector of startChill is an empty method.)
func _view_will_appear() -> void:
	var inst := outlet("instIV")
	if inst != null and inst != self:
		(inst as CanvasItem).visible = true
	if _gun_badge != null:
		_gun_badge.visible = true
	Audio.loop("freezer_02")
	_reset_screen()


## UINavigationController keeps this controller alive under
## MakeViewController (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from MakeViewController: viewWillAppear: again (see header).
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		# CoinHUD re-adds the panel after this (the gun purchase had removed
		# it from this view; the app delegate puts it back on every show).
		remove_child(old)
		old.queue_free()
	_view_will_appear()


# -- freeze gun ----------------------------------------------------------

## initWithDictionary: + viewDidLoad: the Consumable and its badge, above
## instIV.
func _build_gun_badge() -> void:
	_freeze_gun = ConsumableScript.new(GUN_KEY, GUN_NAME, GUN_COST)
	_freeze_gun.set("first_time_message", GUN_MESSAGE)
	_freeze_gun.set("quantity", 0)
	_freeze_gun.set("on_purchased", _on_gun_purchased)
	_freeze_gun.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyFreezeGun"
	b.call("setup", GUN_BADGE_ART, 0, -25, GUN_COST, 65, 3)
	b.position = GUN_BADGE_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyClick)
	add_child(b)
	var inst := outlet("instIV")
	if inst != null and inst != self:
		move_child(b, (inst as Node).get_index() + 1)
	_gun_badge = b


## buyClick: (0xFAD64).
func _on_buyClick() -> void:
	Audio.play("store")
	_freeze_gun.call("purchase", self)


## consumablePurchased: (0xFC2EC).
func _on_gun_purchased(_free: bool) -> void:
	_freeze_gun.set("quantity", 1)
	_reset_ice_pop()
	_show_freeze_gun()
	dismiss_instruction()
	_gun_bought = true
	if _gun_badge != null:
		_gun_badge.visible = false
	# [[delegate coinsView] removeFromSuperview]: the coins panel leaves this
	# screen. CoinHUD parents it here under that name.
	var hud := get_node_or_null("CoinInfoView")
	if hud != null:
		hud.visible = false


## resetIcePop (0xF9078): timer off, not soaked, state 0, pop home at
## scale 0.45 with no rotation, pop interactive, pop alpha 1, frost alpha 0.
func _reset_ice_pop() -> void:
	_fade_timer.stop()
	_soaked = false
	_state = 0
	_done = false
	_dragging = false
	_pop.position = POP_HOME
	_pop.rotation = 0.0
	_pop.scale = Vector2(POP_SCALE, POP_SCALE)
	_pop.modulate.a = 1.0
	if _mold != null:
		_mold.modulate.a = 0.0


## showFreezeGun (0xFB484).
func _show_freeze_gun() -> void:
	var tw := create_tween().set_parallel(true)
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var freezer := outlet("freezer")
	if freezer != null and freezer != self and freezer is Node2D:
		var f := freezer as Node2D
		tw.tween_property(f, "position:y", f.position.y + HIDE_FREEZER_DY,
			HIDE_FREEZER_SECONDS)
	tw.tween_property(_pop, "rotation", _pop.rotation + PART_ROTATION,
		HIDE_FREEZER_SECONDS)
	tw.tween_property(_pop, "position", POP_GUN_CENTER, HIDE_FREEZER_SECONDS)
	_dragging = false
	Audio.stop("freezer_02")
	Audio.stop("liquid freeze_04")

	_gun = DraggableSprite.new()
	_gun.texture = _tex(GUN_ART)
	_gun.position = GUN_HOME
	_gun.snap_back = true
	_gun.snap_time = GUN_SNAP
	add_child(_gun)
	move_child(_gun, _pop.get_index() + 1)      # insertSubview:aboveSubview:icePop
	_gun.capture_origin()
	_gun.drag_started.connect(_on_gun_began)
	_gun.drag_moved.connect(_on_gun_moved)
	_gun.drag_ended.connect(_on_gun_ended)


## draggableTouchBegan: (0xFBBD8), freezeGun branch.
func _on_gun_began() -> void:
	_gun_held = true
	_spray_timer.start()
	_soaked = true
	_start_fade_timer()
	Audio.loop("freezer_02")


## draggableTouchMoved: (0xFBCB8), freezeGun branch.
func _on_gun_moved(pos: Vector2) -> void:
	if pos.y >= GUN_STOP_Y:
		_soaked = false
		_fade_timer.stop()
	else:
		_soaked = true
		_start_fade_timer()


## draggableTouchEnded: (0xFBE90), freezeGun branch.
func _on_gun_ended(_pos: Vector2, _hit: bool) -> void:
	_spray_timer.stop()
	_gun_held = false
	_soaked = false
	_fade_timer.stop()
	Audio.stop("freezer_02")


## freezeSpray (0xFB778) + its animation blocks (sub_FB9F8 / sub_FBBA8).
func _freeze_spray() -> void:
	if _gun == null:
		return
	var puff := Sprite2D.new()
	puff.texture = _tex("Freeze_Spray_%d.png" % (randi() % 3 + 1))
	puff.scale = Vector2(SPRAY_SCALE0, SPRAY_SCALE0)
	puff.position = _gun.position + SPRAY_OFFSET
	add_child(puff)
	move_child(puff, _gun.get_index())          # insertSubview:belowSubview:freezeGun
	var target := puff.position + Vector2(SPRAY_DX, float(randi() % SPRAY_DY_RANGE))
	var tw := create_tween().set_parallel(true)
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(puff, "position", target, SPRAY_SECONDS)
	tw.tween_property(puff, "scale", puff.scale * SPRAY_SCALE_MUL, SPRAY_SECONDS)
	tw.tween_property(puff, "modulate:a", 0.0, SPRAY_SECONDS)
	tw.chain().tween_callback(puff.queue_free)
	if _state == GUN_NEXT_STATE and not _done:
		_finish_freeze()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _color() -> Variant:
	return _info.get("Color")


## initWithDictionary: (0xF9A88): stick + upside-down banana + coating as on
## the dip screen, plus the frost mold at alpha 0.
func _build_pop() -> void:
	_pop = Node2D.new()
	_pop.position = POP_HOME
	_pop.scale = Vector2(POP_SCALE, POP_SCALE)
	add_child(_pop)                           # restacked on top in on_enter

	var half := POP_SIZE * 0.5
	var stick_tex := _tex(str(_info.get("Stick", "")))
	var stick_h := 0.0
	if stick_tex != null:
		stick_h = stick_tex.get_size().y
		var stick := Sprite2D.new()
		stick.texture = stick_tex
		stick.position = Vector2(0, (POP_SIZE.y - stick_h) - half.y)
		_pop.add_child(stick)

	var banana_local := Vector2(BANANA_DX, (POP_SIZE.y - stick_h * 0.5) - half.y)
	var banana_tex := _tex("banana_for_stick.png")
	if banana_tex != null:
		var b := Sprite2D.new()
		b.texture = banana_tex
		b.position = banana_local
		b.rotation = PART_ROTATION
		_pop.add_child(b)

	var c: Variant = _color()
	if c is Color:
		var coat_tex := caSelectChocolate.bake_alt_tint(
			_tex("cc_banana.png"), c, 3)
		if coat_tex != null:
			var coat := Sprite2D.new()
			coat.texture = coat_tex
			coat.position = banana_local + Vector2(0, COATING_DY)
			coat.rotation = PART_ROTATION
			_pop.add_child(coat)

	_mold = Sprite2D.new()
	_mold.texture = _tex("Frozen_Banana.png")
	_mold.position = banana_local + Vector2(0, MOLD_DY)
	_mold.rotation = PART_ROTATION
	_mold.modulate.a = 0.0
	_pop.add_child(_mold)
	# The `texture` ivar of the original is never assigned on this screen;
	# resetIcePop's texture.alpha = 0.2 is a message to nil. Nothing to port.


## resetScreen (0xF91A4): resetIcePop, instIV unhidden, the instruction,
## the gun branch (only after a purchase: gun removed, badge shown, freezer
## art back up 500, boughtFreezeGun 0), next hidden.
func _reset_screen() -> void:
	_reset_ice_pop()
	change_instruction("inst_flash_freezer.png")   # also unhides instIV
	if _gun_bought:
		_spray_timer.stop()
		_gun_held = false
		if _gun != null and is_instance_valid(_gun):
			_gun.queue_free()
		_gun = null
		if _gun_badge != null:
			_gun_badge.visible = true
		var freezer := outlet("freezer")
		if freezer != null and freezer != self and freezer is Node2D:
			(freezer as Node2D).position.y -= HIDE_FREEZER_DY
		_gun_bought = false
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false


func _pop_rect() -> Rect2:
	var size := POP_SIZE * POP_SCALE
	return Rect2(_pop.position - size * 0.5, size)


func _unhandled_input(event: InputEvent) -> void:
	# showFreezeGun turns the pop's interaction off for good.
	if _pop == null or _done or _soaked or _gun_bought:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		# "SnapIcePop" (0xFBE90) is +beginAnimations:/commitAnimations and
		# leaves the pop's interaction on, so it can be caught on its 0.2 s
		# way home -- at its MODEL centre, origCenter -- and the drag owns it
		# from there. The port used to hit-test the drawn pop and leave the
		# snap tween running, so a pop caught and dropped in the freezer
		# soaked at the drop x while the snap pulled it to x 160.
		# PORT CHOICE: it lands on the model at once instead of gliding on
		# toward the finger for the rest of the 0.2 s.
		var snapping := _pop_snap != null and _pop_snap.is_valid() \
			and _pop_snap.is_running()
		var hit_rect := Rect2(POP_HOME - POP_SIZE * POP_SCALE * 0.5,
			POP_SIZE * POP_SCALE) if snapping else _pop_rect()
		if mb.pressed and not _dragging and hit_rect.has_point(mb.position):
			if snapping:
				_pop_snap.kill()
				_pop.position = POP_HOME
			_dragging = true
			_grab = _pop.position - mb.position
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			_released()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		var p: Vector2 = (event as InputEventMouseMotion).position + _grab
		# draggableTouchMoved (0xFBCB8): y <= 300, x in [110,210].
		p.y = minf(p.y, DRAG_MAX_Y)
		p.x = clampf(p.x, DRAG_MIN_X, DRAG_MAX_X)
		_pop.position = p
		_check_freezer_sound()      # called on every move in the original
		get_viewport().set_input_as_handled()


## draggableTouchEnded (0xFBE90), icePop branch.
func _released() -> void:
	if _pop.position.y > FREEZER_Y:
		_drop_in()
	else:
		# showNextButtonWhenIcePopIsReady (0xF87A4): at state 0 with next
		# hidden this is a no-op; the state-4 branch needs the freeze gun.
		# "SnapIcePop": 0.2s linear back home.
		_pop_snap = create_tween()
		_pop_snap.tween_property(_pop, "position", POP_HOME,
			SNAP_SECONDS).set_trans(Tween.TRANS_LINEAR)
		change_instruction("inst_flash_freezer.png")
		_soaked = false
		_fade_timer.stop()
		_check_freezer_sound()


func _drop_in() -> void:
	# Clamps re-applied, then "DropIcePop": 0.5s linear to y=300.
	_pop.position.x = clampf(_pop.position.x, DRAG_MIN_X, DRAG_MAX_X)
	create_tween().tween_property(_pop, "position:y", SOAK_Y, DROP_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)
	_soaked = true                    # interaction off via the _soaked gate
	dismiss_instruction()
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	_start_fade_timer()
	_check_freezer_sound()


## startIcePopFadeTimer (0xF8F90): 0.7 s per tick while the spray timer is
## valid (the gun is held), else 2.0 s.
func _start_fade_timer() -> void:
	if _fade_timer.is_stopped():
		_fade_timer.wait_time = GUN_FADE_INTERVAL if _gun_held else FADE_INTERVAL
		_fade_timer.start()


## fadeIcePop (0xF8D90), every 2.0s while soaking.
func _fade_tick() -> void:
	var prev := _state
	_state += 1
	if prev <= 4 and _soaked and _mold != null:
		# "FadeOutMold" -- the frost fades IN here, +0.25 over 0.5s linear.
		create_tween().tween_property(_mold, "modulate:a",
			minf(_mold.modulate.a + FADE_STEP, 1.0), FADE_SECONDS) \
			.set_trans(Tween.TRANS_LINEAR)
	# Both branches sit behind `!freezeSprayTimer.isValid`: with the gun held
	# the puff block (freezeSpray) finishes the screen instead.
	if _gun_held:
		return
	if _state == DONE_STATE:
		_finish_freeze()
	elif _state == SOUND_STATE:
		Audio.play("liquid freeze_03")


## fadeIcePop's state-5 branch: interaction off (already off), stop the
## timer, slide next in. The pop STAYS in the freezer -- no snap-out, no
## rotate, no mold crack on the free path (see header).
func _finish_freeze() -> void:
	_done = true
	_fade_timer.stop()
	# showNextButton (0xF85C8) also hides instIV and the freeze-gun badge.
	if _gun_badge != null:
		_gun_badge.visible = false
	show_next_button()


## checkFreezerSoundPlayer (0xF89F0).
func _check_freezer_sound() -> void:
	if _soaked:
		Audio.loop("liquid freeze_04")    # no-op if already looping
	else:
		Audio.stop("liquid freeze_04")


# -- handoff -----------------------------------------------------------

## nextClick: (0xFAEA8): stop the freezer sounds, button_press, bake the
## three MakeViewController layers (values at 0xFAF44..0xFB0FC), push
## MakeViewController (classStr "Chocolate Dipped Banana").
func _on_nextClick() -> void:
	Audio.stop("freezer_02")
	Audio.stop("liquid freeze_04")
	Audio.play("button_press")
	# PORT CHOICE (header): keep the carrier's own keys next to the layers.
	var out := {}
	for k in ["Stick", "Color", "GratedOrigY"]:
		if _info.has(k):
			out[k] = _info[k]
	var stick_tex := _tex(str(_info.get("Stick", "")))
	if stick_tex != null:
		out["BananaStick"] = {
			"Properties": {
				"IsEdible": false, "ViewIndex": 4, "Type": "Stationary",
				"ItemCenterX": STICK_TOP_LEFT.x, "ItemCenterY": STICK_TOP_LEFT.y,
			},
			"Image": stick_tex,
		}
	var banana_tex := _tex("banana_for_stick.png")
	if banana_tex != null:
		out["Banana"] = {
			"Properties": {
				"IsEdible": true, "ViewIndex": 5, "Type": "Stationary",
				"ItemCenterX": BANANA_TOP_LEFT.x, "ItemCenterY": BANANA_TOP_LEFT.y,
				"Layer": 2,
			},
			"Image": banana_tex,
		}
	var c: Variant = _color()
	if c is Color:
		var coat := caSelectChocolate.bake_alt_tint(_tex("cc_banana.png"), c, 3)
		if coat != null:
			out["ChocolateCoating"] = {
				"Properties": {
					"IsEdible": true, "ViewIndex": 6, "Type": "Stationary",
					"ItemCenterX": COATING_TOP_LEFT.x,
					"ItemCenterY": COATING_TOP_LEFT.y,
					"Layer": 1,
				},
				"Image": coat,
			}
	GameState.custom_categories = out
	Nav.next()


## skipClick: (0xFB474) forwards to nextClick:. The nib wires it to an
## alpha-0.3 "Debug Skip" button at (200,377,120,40) that ships UIHidden=YES
## and has no outlet, so nothing ever shows it: unreachable on the device and
## in the port (the generated scene hides it; before the NIBArchive bool fix
## this note called it live).
func _on_skipClick() -> void:
	_on_nextClick()


## backClick: (0xFADD0): stop sounds, invalidate the fade timer, pop.
func _on_backClick() -> void:
	Audio.stop("freezer_02")
	Audio.stop("liquid freeze_04")
	Audio.play("button_press")
	if _fade_timer != null:
		_fade_timer.stop()
	if _spray_timer != null:
		_spray_timer.stop()
	Nav.back()


## viewWillDisappear: (0xFACA4): stop freezer_02 and "liquid freeze_04",
## stopFadeTimerForIcePop. PORT CHOICE: the spray timer is stopped too -- the
## original leaves freezeSprayTimer to draggableTouchEnded:, which a held gun
## always reaches before next/back can be pressed on the phone.
func on_exit() -> void:
	Audio.stop("freezer_02")
	Audio.stop("liquid freeze_04")
	if _fade_timer != null:
		_fade_timer.stop()
	if _spray_timer != null:
		_spray_timer.stop()
