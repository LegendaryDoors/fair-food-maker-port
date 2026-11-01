# Curly Fries step 6 -- shake the sifter to salt the fries, then bake the
# finished food for MakeViewController.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithNibName: 0x170AD0 (Skip consumable), initWithInfoDict: 0x170C60,
#   viewDidLoad 0x170C94, viewWillAppear: 0x17122C, viewWillDisappear:
#   0x171484, shakeDuster 0x171528, stopShake 0x171820,
#   accelerometer:didAccelerate: 0x1718D8, startAccelerometer 0x171A90,
#   shakeClick: 0x1727B0, backClick: 0x172184, nextClick: 0x172248.
#   changeInstruction: 0x171F7C / showNextButton 0x171E18 are the standard
#   +500/0.25s slide.
#
# Mechanic, as read -- BUTTON-driven, not shake-driven: shakeClick: (the nib
# btn_IAP_Shake button) runs shakeDuster when isShake is set. The
# accelerometer jolt detector (0x1718D8, threshold 0.05 per axis) exists but
# NOTHING ever starts it: the only reference to this class's
# startAccelerometer IMP is its own method-list row (0x714B94), no method of
# the class sends the selector, and viewWillDisappear's
# cancelPreviousPerformRequests for it (0x1714B4) is cancelling a perform
# nothing schedules. Dead code (one of several dead accelerometers in this
# app), so the port ships the button only; no press-and-hold remap needed.
#
# shakeDuster (0x171528): isShake off, shakeCounter++, loop "rolling",
# [saltSprites start -- see below], fade saltPileIV's alpha to
# shakeCounter * 0.25 over 3.0s curve 0 ("Show_SaltPile"), snap the sifter
# to translate(-40,+2) and wobble it to translate(+40,-2) autoreversed 7
# times at 0.2s (0x3FC9999A...), then stopShake after 3.0s (0x40080000):
# rolling off; at shakeCounter == 2 next slides in and the shake button
# hides, else isShake re-arms. The sifter ends each wobble at the +40,-2
# model value -- UIKit autoreverse snap, kept.
#
# viewWillAppear (0x17122C): instIV HIDDEN outright (inst_dust_salt.png
# never shows -- as shipped), next hidden, shake button shown, pileIV =
# infoDict["FriedPile_Image"], saltPileIV alpha 0, potImageView's leftover
# subviews cleared, counters reset.
#
# saltSprites (particles): the nib's UIClassSwapper SSEmitter at
# (70,140,172,124), between
# saltPileIV and saltDuster. viewDidLoad 0x170C94 (call 0x170FDE) configures
# it: Fires_Salt_PS_1..3.png, tint nil, random, interval 0.05, duration 0.5,
# repeat, finalCenter = frame.size/2 = (86,62), alpha 1 -> 0, scale 1 -> 1,
# variances 0, options 3 (SSEmitterConfigs "cffDustSalt.saltSprites").
# start: shakeDuster 0x171528. stop: stopShake 0x171820, backClick:
# 0x172184, nextClick: 0x172248, viewWillDisappear: 0x171484. The salt
# fades out in place at (156,202).
# The Skip consumable (0x170AD0, centre (50, 350.5), buyClick: 0x171DAC,
# consumablePurchased: 0x171B30) is a 3-coin consumable, not IAP; PORTED,
# see the skip block. BUT viewWillAppear: (0x17122C) ends its
# setup with `buySkip setHidden:YES`, and nothing in the class ever unhides
# it (the only setHidden: on buySkip in the binary's cffDustSalt methods),
# so on this screen the badge is built and never seen. Hidden here too
# (the port used to show it). Still not ported (ads): the AdColony
# interstitial + its mute callbacks (0x170FBC / 0x171124 / 0x171168).
#
# nextClick: (0x172248) bakes customCategories for MakeViewController:
#   PlateDict     {inedible, ViewIndex 2, Stationary, ItemCenter (10,100),
#                  Image cff_tray.png}
#   FriesPileDict {edible, ViewIndex 3, Stationary, ItemCenter (10,100),
#                  Image = a 300x300 render of FriedPile_Image with
#                  cff_salt_layer at alpha 0.5 over it}
# ItemCenterX/Y are 0x41200000/0x42C80000 = (10,100) -- DecorateItemViews
# are zero-frame, so these are the art's TOP-LEFT. classStr "French Fries".
#
# KEEP-STATE: kept alive under the push to Make.
# viewDidLoad's work (badge, salt-in-sifter, emitter config) runs once;
# viewWillAppear:'s reset runs on entry and in on_resume. on_exit =
# viewWillDisappear: (rolling off, emitter stopped). The bake reads this
# controller's own infoDict (_info), so a second nextClick: after a return
# bakes the same fries.

extends "res://core/Screen.gd"

## Skip consumable (PORTED; the phone shows the badge):
## initWithNibName: 0x170AD0 builds Consumable DM_CONSUMABLE_SKIP / Skip_70Salt,
## cost = the dead server table GameData.CoinCosts ... SkipShaker, 3 when
## absent; first-time message below. viewDidLoad 0x170C94 builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0x171DAC ("store" sound,
## purchaseConsumable). consumablePurchased: 0x171B30 calls nextClick: with the badge as sender -- the same path as the next button.
## consumablePurchaseFailed:error: 0x171CD8 (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_70Salt"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton

const cffSelectSlicer := preload("res://screens/cffSelectSlicer.gd")
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")
const SALT_EMITTER := "cffDustSalt.saltSprites"

## shakeDuster: saltPile alpha step per shake (0.25); fade 3.0s, curve 0.
const PILE_ALPHA_STEP := 0.25
const PILE_FADE_S := 3.0
## The sifter wobble: translate (-40,2) -> (40,-2), 0.2s legs, 7 repeats,
## autoreversed; stopShake 3.0s later (0x40080000).
const WOBBLE_FROM := Vector2(-40, 2)
const WOBBLE_TO := Vector2(40, -2)
const WOBBLE_LEG_S := 0.2
const WOBBLE_REPEATS := 7
const STOP_AFTER_S := 3.0
## stopShake: done at two shakes.
const SHAKES_NEEDED := 2
## nextClick: bake geometry (0x172248).
const BAKE_SIZE := 300
const HANDOFF_TOP_LEFT := Vector2(10, 100)
const SALT_LAYER_ALPHA := 0.5

var _info: Dictionary = {}
var _is_shake := true
var _shake_counter := 0
var _sifter_home := Vector2.ZERO
var _wobble: Tween
var _salt: SSEmitter             # saltSprites


## UINavigationController keeps this controller alive under the push to
## MakeViewController; Nav calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## initWithInfoDict: (0x170C60) + viewDidLoad (0x170C94) once, then
## viewWillAppear: (0x17122C).
func on_enter() -> void:
	# viewDidLoad built the badge before any viewWillAppear content.
	_build_skip()
	_info = cffSelectSlicer.info_or_default(GameState.custom_categories)
	# viewDidLoad (0x170C94): cff_salt.png as a subview of the sifter (0,0).
	var sifter := outlet("sifter")
	if sifter is Sprite2D:
		_sifter_home = (sifter as Node2D).position
		var salt := Sprite2D.new()
		salt.texture = _tex("cff_salt.png")
		salt.centered = false
		(sifter as Node).add_child(salt)
	# viewDidLoad: setParticles:... on the nib's saltSprites SSEmitter.
	var host := outlet("saltSprites")
	if host != null and host != self:
		_salt = SSEmitter.attach(host, SSEmitterConfigs.frame_size(SALT_EMITTER)) \
			as SSEmitter
		SSEmitterConfigs.apply(_salt, SALT_EMITTER, null)
	_will_appear()


## Back from Make: viewWillAppear: runs again and RESETS the step -- next
## hidden, SHAKE shown, the salt pile at alpha 0, shakeCounter 0. The sifter
## keeps the (+40,-2) offset its last wobble ended on (viewWillAppear: never
## resets its transform).
func on_resume() -> void:
	_will_appear()


## viewWillAppear: (0x17122C).
func _will_appear() -> void:
	dismiss_instruction()                      # instIV setHidden:1, as shipped
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	var shake := outlet("shakeButton")
	if shake != null and shake != self:
		(shake as CanvasItem).visible = true
	var sifter := outlet("sifter")
	if sifter != null and sifter != self:
		(sifter as CanvasItem).visible = true  # setHidden:NO
	var pile := outlet("pileIV")
	if pile is Sprite2D:
		(pile as Sprite2D).texture = _tex(str(_info.get("FriedPile_Image", "")))
		(pile as Sprite2D).centered = false    # nib frame (10,126,300,300)
	# buySkip setHidden:YES (0x17122C) -- never shown again.
	if _skip_button != null:
		_skip_button.visible = false
	# potImageView's subviews are removed; the port never adds any.
	_shake_counter = 0
	_is_shake = true
	var salt_pile := outlet("saltPileIV")
	if salt_pile != null and salt_pile != self:
		(salt_pile as CanvasItem).modulate.a = 0.0


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## shakeClick: (0x1727B0) -- no sound of its own, as read.
func _on_shakeClick() -> void:
	if _is_shake:
		_shake_duster()


## shakeDuster (0x171528).
func _shake_duster() -> void:
	_is_shake = false
	_shake_counter += 1
	Audio.loop("rolling")
	if _salt != null:
		_salt.start()                          # [saltSprites start]
	var salt_pile := outlet("saltPileIV")
	if salt_pile != null and salt_pile != self:
		# "Show_SaltPile": 3.0s, curve 0 (ease-in-out).
		create_tween().tween_property(salt_pile, "modulate:a",
			_shake_counter * PILE_ALPHA_STEP, PILE_FADE_S) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var sifter := outlet("sifter") as Node2D
	if sifter != null:
		if _wobble != null and _wobble.is_valid():
			_wobble.kill()
		sifter.position = _sifter_home + WOBBLE_FROM
		# "shake-UpDown": autoreverse x7 at 0.2s; UIKit then snaps to the
		# model value (+40,-2), so the sequence ends there.
		_wobble = create_tween()
		for i in WOBBLE_REPEATS:
			_wobble.tween_property(sifter, "position",
				_sifter_home + WOBBLE_TO, WOBBLE_LEG_S) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			_wobble.tween_property(sifter, "position",
				_sifter_home + WOBBLE_FROM, WOBBLE_LEG_S) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_wobble.tween_callback(func() -> void:
			sifter.position = _sifter_home + WOBBLE_TO)
	get_tree().create_timer(STOP_AFTER_S).timeout.connect(_stop_shake)


## stopShake (0x171820).
func _stop_shake() -> void:
	if not is_inside_tree():
		return
	if _salt != null:
		_salt.stop()                           # [saltSprites stop]
	Audio.stop("rolling")
	if _shake_counter == SHAKES_NEEDED:
		show_next_button()
		var shake := outlet("shakeButton")
		if shake != null and shake != self:
			(shake as CanvasItem).visible = false
	else:
		_is_shake = true


## nextClick: (0x172248) -- the bake; see header for the layer table.
func _on_nextClick() -> void:
	Audio.stop("rolling")
	if _salt != null:
		_salt.stop()                           # [saltSprites stop]
	Audio.play("button_press")

	var out := {}
	var tray := _img(_tex("cff_tray.png"))
	if tray != null:
		out["PlateDict"] = {
			"Properties": {"IsEdible": false, "ViewIndex": 2,
				"Type": "Stationary",
				"ItemCenterX": HANDOFF_TOP_LEFT.x,
				"ItemCenterY": HANDOFF_TOP_LEFT.y},
			"Image": tray,
		}
	var composite := _bake_pile()
	if composite != null:
		out["FriesPileDict"] = {
			"Properties": {"IsEdible": true, "ViewIndex": 3,
				"Type": "Stationary",
				"ItemCenterX": HANDOFF_TOP_LEFT.x,
				"ItemCenterY": HANDOFF_TOP_LEFT.y},
			"Image": composite,
		}
	GameState.custom_categories = out
	Nav.next()                                 # end of flow -> MakeViewController


func _img(t: Texture2D) -> Image:
	if t == null:
		return null
	var img := t.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	return img


## The 300x300 renderInContext: composite -- FriedPile_Image at (0,0) with
## cff_salt_layer source-over at alpha 0.5 (0x172248).
func _bake_pile() -> Image:
	var base := _img(_tex(str(_info.get("FriedPile_Image", ""))))
	var salt := _img(_tex("cff_salt_layer.png"))
	var out := Image.create(BAKE_SIZE, BAKE_SIZE, false, Image.FORMAT_RGBA8)
	if base != null:
		out.blit_rect(base, Rect2i(0, 0,
			mini(base.get_width(), BAKE_SIZE),
			mini(base.get_height(), BAKE_SIZE)), Vector2i.ZERO)
	if salt != null:
		for y in mini(salt.get_height(), BAKE_SIZE):
			for x in mini(salt.get_width(), BAKE_SIZE):
				var s := salt.get_pixel(x, y)
				var sa := s.a * SALT_LAYER_ALPHA
				if sa <= 0.0:
					continue
				var d := out.get_pixel(x, y)
				var ao := sa + d.a * (1.0 - sa)
				if ao <= 0.0:
					continue
				out.set_pixel(x, y, Color(
					(s.r * sa + d.r * d.a * (1.0 - sa)) / ao,
					(s.g * sa + d.g * d.a * (1.0 - sa)) / ao,
					(s.b * sa + d.b * d.a * (1.0 - sa)) / ao, ao))
	return out


## backClick: (0x172184): rolling off, button_press, pop.
func _on_backClick() -> void:
	Audio.stop("rolling")
	if _salt != null:
		_salt.stop()                           # [saltSprites stop]
	Audio.play("button_press")
	Nav.back()


## viewWillDisappear: (0x171484): rolling off, the (dead) startAccelerometer
## perform cancelled, saltSprites stopped, stopAccelerometer (dead).
func on_exit() -> void:
	Audio.stop("rolling")
	if _salt != null:
		_salt.stop()


# -- skip consumable ----------------------------------------------------

## viewDidLoad's ConsumableButton and the init's Consumable (see header).
func _build_skip() -> void:
	_skip = ConsumableScript.new(SKIP_KEY, SKIP_NAME, SKIP_COST)
	_skip.set("first_time_message", SKIP_MESSAGE)
	_skip.set("on_purchased", _on_skip_purchased)
	_skip.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buySkip"
	b.call("setup", SKIP_ART, 0, -25, SKIP_COST, 65, 3)
	b.position = SKIP_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyClick)
	add_child(b)
	_skip_button = b


## buyClick: -- "store" sound, purchaseConsumable.
func _on_buyClick() -> void:
	Audio.play("store")
	_skip.call("purchase", self)


## consumablePurchased: -> nextClick: (see header).
func _on_skip_purchased(_free: bool) -> void:
	_on_nextClick()


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
