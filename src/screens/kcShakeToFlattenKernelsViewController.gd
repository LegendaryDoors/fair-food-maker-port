# Kettle Corn step 2 -- put the lid on, then shake the pot to flatten the
# kernels.
#
# GROUNDED from initWithNibName:bundle: (0x107898), viewDidLoad (0x107934),
# viewWillAppear: (0x107A68), viewDidAppear: (0x107D30), viewWillDisappear:
# (0x107E8C), shake (0x107F00), animationDidStop:finished:context: (0x108238),
# bubbleTick (0x1089D0), shakeClick: (0x109128), nextClick: (0x109068),
# backClick: (0x108FF8), skipClick: (0x109118) and showNextButton (0x109138).
#
# THE MECHANIC IS THE BUTTON, NOT THE ACCELEROMETER. This class has a full
# shake detector (accelerometer:didAccelerate: 0x108DA0, a jolt counter over
# filtered deltas with a 0.05 threshold that calls shake) -- but no method of
# this class ever references the startAccelerometer selref (checked: its
# only kc referrers are kcPourOil viewWillAppear 0x104C3C and
# kcSelectSugar screenSetup 0x10CFF4 / selectFlavorButtonClick: 0x10DA1C;
# kcPourOil's viewWillDisappear also clears the shared delegate before this
# screen appears). The delegate is never set, so the handler is dead code,
# exactly like lemon shake up's. The shipped path is shakeClick: on the
# btn_IAP_Shake button the nib keeps visible -- on the phone too, shaking the
# device does nothing here. No press-and-hold remap is needed.
#
# One shake = three chained linear UIView animations moving the centres of
# fryer, oil, lid and kernelPile together:
#   snap x=160, "ShakeLeft"  -> x=80,  0.15s   (0x3FC30C3340000000)
#   snap x=80,  "ShakeRight" -> x=240, 0.30s   (0x3FD30C3340000000)
#   snap x=240, "ShakeMid"   -> x=160, 0.15s
# ShakeMid's completion swaps kernelPile to kc_kernelpile_<shakes>.png and,
# at shakes >= 7, shows next and hides the shake button. `shakes` starts AT 1
# (viewWillAppear) and shake() runs only while shakes <= 6, so there are six
# shakes and the pile ends on kc_kernelpile_7.png.
#
# viewWillAppear HIDES instIV outright and this class's changeInstruction:
# (0x10929C) has zero callers -- the screen ships with no instruction banner.
# startBurner (0x107EFC) is 4 bytes of `bx lr`, a no-op scheduled 0.5s out.
#
# Not ported, with addresses:
#  * accelerometer:didAccelerate: 0x108DA0 -- dead code, see above.
#  * The consumable-skip IAP flow (skipClick: 0x109118 just calls nextClick:;
#    the scene has no skip button and the port suppresses IAP everywhere).

extends "res://core/Screen.gd"

const kcPourOil := preload("res://screens/kcPourOilViewController.gd")
const kcKit := preload("res://screens/kcKit.gd")

# -- viewWillAppear: (0x107A68) -----------------------------------------

## All four tableau views are UIImageViews (self-sizing, true centres); their
## centres are snapped to x = 160 on appear and before every shake.
const SNAP_X := 160.0                # 0x43200000 in every setCenter:
const FIRST_PILE_ART := "kc_kernelpile_1.png"
## bubbleTick every 0.2s (0x3FC99999A0000000).
## frying_lo_loop at volume 0.5 (0x3F000000), loop -1.
const FRY_VOLUME := 0.5

# -- viewDidAppear: (0x107D30): the lid drops on ------------------------

## Lid parks at centre (160, -lid.height) and animates to its nib centre,
## "MoveLid", 0.5s, curve 1 (ease-in). Its completion (0x108238) clears
## isLidAnimating and plays lid_05 -- the sound is at the END here, unlike
## kcPourOil where it plays alongside the flight.
const LID_SECONDS := 0.5             # 0x3FE0000000000000

# -- shake (0x107F00) / animationDidStop (0x108238) ---------------------

const SHAKE_LEFT_X := 80.0           # 0x42A00000
const SHAKE_RIGHT_X := 240.0         # 0x43700000
const LEFT_SECONDS := 0.15           # 0x3FC30C3340000000 (0.15000000596...)
const RIGHT_SECONDS := 0.3           # 0x3FD30C3340000000
const MID_SECONDS := 0.15            # same pair as LEFT
## shakes initialises to 1 and shake() runs while shakes <= 6; the pile art
## is kc_kernelpile_%d.png with the incremented count (2..7).
const SHAKES_DONE := 7               # "if (shakes >= 7)" in 0x108238
const PILE_ART := "kc_kernelpile_%d.png"

var _shakes := 1                     # viewWillAppear: self->shakes = 1
var _is_shaking := false
## slide_02: AudioManager stopPlayerForFile: + playFile:, i.e. a restart of
## the newest player (0xE873C / 0xE87C8). The 1.66s sound outlasts a 0.6s
## shake, so the port needs a stoppable player of its own (kcKit header).
var _slide_sfx: AudioStreamPlayer
var _lid_animating := false
var _lid_home_center := Vector2.ZERO
var _bubbler: kcPourOil.OilBubbler
## Every tween this screen starts (kcKit.track / settle, keep-state).
var _tweens: Array = []


func on_enter() -> void:
	# viewDidLoad (0x107934): lidOriginalCenter, read before any x-snap.
	var lid := _sprite("lid")
	if lid != null:
		_lid_home_center = _center_of(lid)
	_bubbler = kcPourOil.OilBubbler.new(_sprite("oil"))
	add_child(_bubbler)
	_slide_sfx = kcKit.make_player(self, "slide_02")
	_view_will_appear()


## Back from kcSelectSugar: the same instance; viewWillAppear: and
## viewDidAppear: run again, which re-runs the whole step (shakes back to
## 1, pile art kc_kernelpile_1, next hidden, shake button shown, the lid
## dropped on afresh).
func keeps_state_on_push() -> bool:
	return true


## viewDidAppear: (0x107D30) -- the lid drop. Nav calls this when the push /
## pop slide ends (0.35 s after on_enter / on_resume), or at once for an
## unanimated change, on every appearance (it used to start with the
## slide, so the lid was half down before the screen had arrived).
func on_did_appear() -> void:
	_drop_lid()


func on_resume() -> void:
	kcKit.drop_coin_panel(self)
	_view_will_appear()


## viewWillAppear: (0x107A68).
func _view_will_appear() -> void:
	_shakes = 1
	_is_shaking = false
	var pile := _sprite("kernelPile")
	if pile != null:
		var t := _tex(FIRST_PILE_ART)
		if t != null:
			pile.texture = t
	for n in ["fryer", "oil", "lid", "kernelPile"]:
		_snap_center_x(n)
	if _bubbler != null:
		_bubbler.restart()           # a fresh 0.2s bubbleTimer
	dismiss_instruction()            # setHidden:YES on instIV; never re-shown
	_set_next_enabled(false)
	var shake_btn := outlet("shakeButton")
	if shake_btn != null and shake_btn != self:
		shake_btn.visible = true
	Audio.loop("frying_lo_loop", linear_to_db(FRY_VOLUME))


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _sprite(outlet_name: String) -> Sprite2D:
	var n := outlet(outlet_name)
	return n if n is Sprite2D else null


## Centre of a top-left-anchored scene sprite (UIImageView semantics).
func _center_of(s: Sprite2D) -> Vector2:
	return s.position + s.texture.get_size() * s.scale * 0.5


func _set_center(s: Sprite2D, c: Vector2) -> void:
	s.position = c - s.texture.get_size() * s.scale * 0.5


func _snap_center_x(outlet_name: String) -> void:
	var s := _sprite(outlet_name)
	if s != null:
		s.position.x = SNAP_X - s.texture.get_size().x * s.scale.x * 0.5


## viewDidAppear: (0x107D30).
func _drop_lid() -> void:
	var lid := _sprite("lid")
	if lid == null:
		return
	_lid_animating = true
	var h: float = lid.texture.get_size().y * lid.scale.y
	_set_center(lid, Vector2(SNAP_X, -h))
	var t := _tween()
	t.tween_property(lid, "position",
		_lid_home_center - lid.texture.get_size() * lid.scale * 0.5,
		LID_SECONDS).set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_IN))
	# animationDidStop "MoveLid" (0x108238): flag down, THEN the clang.
	t.tween_callback(func() -> void:
		_lid_animating = false
		Audio.play("lid_05"))


# -- the shake ----------------------------------------------------------

## shakeClick: (0x109128) -- the one live entry point to shake.
func _on_shakeClick() -> void:
	_shake()


## shake (0x107F00).
func _shake() -> void:
	if _lid_animating or _shakes > SHAKES_DONE - 1 or _is_shaking:
		return
	_is_shaking = true
	_shakes += 1
	for n in ["fryer", "oil", "lid", "kernelPile"]:
		_snap_center_x(n)
	# stopPlayerForFile then playFile -- a restart, so rapid shakes retrigger.
	_slide_sfx.stop()
	if not Audio.muted:                  # loopFile returns nil while muted
		_slide_sfx.play()
	var t := _tween().set_trans(Tween.TRANS_LINEAR)
	t.tween_method(_set_all_x, SNAP_X, SHAKE_LEFT_X, LEFT_SECONDS)
	t.tween_method(_set_all_x, SHAKE_LEFT_X, SHAKE_RIGHT_X, RIGHT_SECONDS)
	t.tween_method(_set_all_x, SHAKE_RIGHT_X, SNAP_X, MID_SECONDS)
	t.tween_callback(_shake_done)


func _set_all_x(cx: float) -> void:
	for n in ["fryer", "oil", "lid", "kernelPile"]:
		var s := _sprite(n)
		if s != null:
			s.position.x = cx - s.texture.get_size().x * s.scale.x * 0.5


## animationDidStop "ShakeMid" (0x108238).
func _shake_done() -> void:
	_is_shaking = false
	var pile := _sprite("kernelPile")
	var t := _tex(PILE_ART % _shakes)
	if pile != null and t != null:     # imageNamed nil-check, as the original
		pile.texture = t
	if _shakes >= SHAKES_DONE:
		show_next_button()
		_set_next_enabled(true)
		var shake_btn := outlet("shakeButton")
		if shake_btn != null and shake_btn != self:
			shake_btn.visible = false


# -- navigation ---------------------------------------------------------

func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.set("disabled", not on)


## nextClick: (0x109068): button_press, push kcSelectSugar.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.next()


## backClick: (0x108FF8).
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


func on_exit() -> void:
	# viewWillDisappear: (0x107E8C): stopAccelerometer (never started here),
	# bubbleTimer invalidated, frying_lo_loop stopped. A shake or lid drop
	# in flight completes while covered (settled), as on Core Animation.
	# PORT CHOICE: slide_02 is not stopped there (AudioManager owns it and
	# lets a tail of at most 1.66s run on); the port's player leaves the
	# tree with the screen, which silences it.
	kcKit.settle(_tweens)
	if _bubbler != null:
		_bubbler.restart()
	Audio.stop("frying_lo_loop")


func _tween() -> Tween:
	return kcKit.track(_tweens, create_tween())


## This screen's changeInstruction: hides nextButton (read from the
## binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
