# Funnel Cake step 6 -- pick a sugar and sift it over the cake.
#
# GROUNDED from initWithImage:batterID: (0x9D810), viewDidLoad (0x9DF4C),
# viewWillAppear: (0x9D914), viewDidAppear: (0x9DE1C),
# initializeToppingSelection (0x9D4E0), showToppingSelection (0x9D0FC),
# toppingClicked: (0x9CD18), hideToppingSelectionAndShowSifter (0x9D298),
# startSifting (0x9BE50), stopSifting (0x9BFB8), shakeClick: (0x9CD08),
# accelerometer:didAccelerate: (0x9C4E0) and nextClick: (0x9C8D8).
# Read from the original binary; showNextButton (0x9C6C0) and the SSEmitter
# internals (setParticles...finalOffset: 0xB294C, start 0xB2C80, emit
# 0xB2D54) read from the disassembly.
#
# Mechanic, as read: a topping panel slides down; picking one swaps the
# sifter art, slides the panel away and the sifter in, and reveals the SHAKE
# button. Each shake runs a 0.6s sift (sound + the `powder` SSEmitter,
# wired through core/particles) and then steps the topping overlay's alpha
# by 0.2667; after exactly 3 sifts the next button slides in and the shake
# button hides. Shaking the DEVICE (0x9C4E0, threshold 0.4, count +5 per
# shaking sample, -1 per still one, trigger at >= 9) starts the same sift;
# as a PORT CHOICE the desktop uses the original's own shakeClick: button
# instead.
#
# ORIGINAL BUG, kept: toppingClicked: builds a 4-frame powderedSugarSSV
# (frame (55,175,207,212)) and startSifting ticks it, but the view is NEVER
# added to the hierarchy -- and its fc_powdered_*1-4.png strips do not even
# exist in the app bundle. Doubly dead; not built. The visible sift feedback
# is the SSEmitter powder, the sound and the alpha steps, as shipped.
#
# ORIGINAL GAP, matched: the nib asks for behind_types_panel.png behind the
# topping buttons but no such file ships in the bundle, so the panel has no
# backdrop on device either. Left absent.
#
# EXTRACTION GAP, closed: backBtn/nextBtn carry btn_back.png / btn_next.png
# as UIButton *background* images, which the nib converter once dropped. It
# now records `backgroundImage` and the generated scene has the art; the
# null-guarded assignment below is kept only as a fallback.
#
# Not ported: locks / showLockedMessage (0x9BDC0, unreachable with everything
# unlocked) and the AdColony ad hook in viewDidLoad (0x9DF4C).
#
# aScrollView never scrolls: showToppingSelection sets contentSize to the
# frame's own size (320, 92), so neither axis can (_canScrollX/Y) and no
# indicator shows; the four buttons take taps directly. viewDidAppear:'s
# work runs in on_did_appear().

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

## initializeToppingSelection (0x9D4E0): button i at (11 + 74*i, 12, 74, 68)
## inside aScrollView, tag i.
const TOPPING_BTN_X0 := 11.0
const TOPPING_BTN_PITCH := 74.0
const TOPPING_BTN_POS_Y := 12.0
const TOPPING_BTN_SIZE := Vector2(74, 68)

## toppingClicked: (0x9CD18), by tag.
const TOPPINGS := [
	{"sifter": "fc_sifter.png", "topping": "fc_powdered_sugar_Toping.png"},
	{"sifter": "fc_sifter_cinnimon.png",
		"topping": "fc_powdered_cinnimon_Toping.png"},
	{"sifter": "fc_sifter_raw_sugar.png", "topping": "fc_raw_sugar_Toping.png"},
	{"sifter": "fc_sifter_cocoa.png", "topping": "fc_powdered_cocoa_Toping.png"},
]

## viewWillAppear: (0x9D914): drawnFunnelCake frame (0,0,212,212)
## (0x43540000), contentMode 1 = aspect fit, centred at fcPlate.center +
## (0, -6.5) (0xC0D00000). fcPlate is a plain UIImageView, true centre.
const CAKE_FIT := 212.0
const CAKE_Y_LIFT := -6.5
## fcSifter parks at origin (640, -1) (0x44200000 / 0xBF800000).
const SIFTER_PARK := Vector2(640, -1)
## Its nib home, where hideToppingSelectionAndShowSifter returns it.
const SIFTER_HOME := Vector2(76, -1)
## Sifter slide-in: 0.4s (double (0x9999999A, 0x3FD99999)), curve 2 ease-out.
const SIFTER_SLIDE := 0.4
## aScrollView: nib frame (0, 65, 320, 92); parked at (0, -92); panel slides
## over 0.5s -- down with curve 2 (ease-out, 0x9D0FC), up with curve 1
## (ease-in, 0x9D298).
const PANEL_HOME_Y := 65.0
const PANEL_HEIGHT := 92.0
const PANEL_SLIDE := 0.5
## stopSifting (0x9BFB8): topping alpha step 0.266666667 while siftCount <= 3;
## next appears at siftCount == 3.
const TOPPING_STEP := 0.266666667
const SIFTS_NEEDED := 3
## startSifting (0x9BE50): five 0.15s-spaced SSV ticks; stopSifting at 0.6s.
const SIFT_SECONDS := 0.6

# -- the powder emitter: the nib's `powder` SSEmitter (id 5, frame
#    (80,145,160,48), above instIV, below fcSifter), configured in
#    viewDidLoad (0x9DF4C, call 0x9E08E) with the finalOffset form; every
#    parameter lives in SSEmitterConfigs ("fcSiftSugarVC.powder") ----------
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")
const POWDER := "fcSiftSugarVC.powder"
var _powder: SSEmitter

var _batter := 0
var _cake_tex: Texture2D = null
var _drawn_cake: Sprite2D
var _panel: Node2D
var _sifter: Node2D
var _topping: CanvasItem
var _picked := false
var _sift_count := 0
var _sifting := false
## nextButtonCenter, saved on the first viewWillAppear: (isFirstInit) and
## restored on every later one.
var _next_home := Vector2.ZERO
var _next_home_set := false
var _panel_tween: Tween
var _sifter_tween: Tween


func on_enter() -> void:
	_batter = int(GameState.custom_categories.get("batter", 0))
	var img: Variant = GameState.custom_categories.get("cakeImg")
	if img is Texture2D:
		_cake_tex = img

	_topping = outlet("fcSugarTopping") as CanvasItem
	_panel = outlet("aScrollView") as Node2D
	_sifter = outlet("fcSifter") as Node2D

	_fix_button_art()
	_build_drawn_cake()
	_build_topping_buttons()
	_build_powder()
	_view_will_appear()
	UIKit.park_instruction(self)


## viewDidAppear: runs when the push / pop slide is over: the topping
## panel's slide-down and the banner start after the slide, as on the phone.
func on_did_appear() -> void:
	_view_did_appear()


## viewDidLoad (0x9DF4C, call 0x9E08E): the nib's `powder` SSEmitter.
func _build_powder() -> void:
	var host := outlet("powder")
	if host == null or host == self:
		return
	_powder = SSEmitter.attach(host, SSEmitterConfigs.frame_size(POWDER)) as SSEmitter
	SSEmitterConfigs.apply(_powder, POWDER, null)


## UINavigationController keeps this controller alive under Make (Nav.gd's
## opt-in). On back viewWillAppear: + viewDidAppear: run again and RESET the
## step: sift count 0, topping overlay alpha 0, shake and next hidden (next
## back at its saved centre), sifter parked, the topping panel sliding down
## again for a fresh pick.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	_view_will_appear()
	# _view_did_appear() follows from on_did_appear(), after the pop slide.


## viewWillAppear: (0x9D914): topping alpha 0, counters reset, shake and
## next hidden, sifter and panel parked off screen. (The lock badges are the
## unreachable IAP branch; the drawn cake's frame/centre reset is a no-op
## here -- the port never moves it.)
func _view_will_appear() -> void:
	for t: Tween in [_panel_tween, _sifter_tween]:
		if t != null and t.is_valid():
			t.kill()
	if _topping != null:
		_topping.modulate.a = 0.0
	_sift_count = 0
	_sifting = false
	_picked = false
	var nb := outlet("nextBtn")
	if nb != null and nb != self:
		if not _next_home_set:
			_next_home = nb.get("position")
			_next_home_set = true
		else:
			nb.set("position", _next_home)
	for hide_name in ["shakeButton", "nextBtn"]:
		var o := outlet(hide_name)
		if o != null and o != self:
			(o as CanvasItem).visible = false
	if _sifter != null:
		_sifter.position = SIFTER_PARK
	if _panel != null:
		_panel.position.y = -PANEL_HEIGHT


## viewDidAppear: (0x9DE1C): showToppingSelection (0x9D0FC, panel down over
## 0.5s, curve 2 ease-out), instIV unhidden, changeInstruction:.
func _view_did_appear() -> void:
	if _panel != null:
		_panel_tween = create_tween()
		_panel_tween.tween_property(_panel, "position:y", PANEL_HOME_Y,
			PANEL_SLIDE).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	change_instruction("inst_select_1sugar.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## The raw nib's UIButtonContent art, missing from the generated scene.
func _fix_button_art() -> void:
	var back := outlet("backBtn")
	if back is TextureButton and (back as TextureButton).texture_normal == null:
		var tb := back as TextureButton
		tb.texture_normal = _tex("btn_back.png")
		tb.ignore_texture_size = true
		tb.stretch_mode = TextureButton.STRETCH_SCALE
	var next := outlet("nextBtn")
	if next is TextureButton and (next as TextureButton).texture_normal == null:
		var tb2 := next as TextureButton
		tb2.texture_normal = _tex("btn_next.png")
		tb2.ignore_texture_size = true
		tb2.stretch_mode = TextureButton.STRETCH_SCALE


## initWithImage:batterID: (0x9D810) + viewWillAppear: the drawn cake sits
## aspect-fit in a 212x212 box centred just above the plate's centre, below
## the topping overlay. Entered standalone the carrier is empty and the
## plate stays bare -- absent rather than invented.
func _build_drawn_cake() -> void:
	if _cake_tex == null:
		return
	_drawn_cake = Sprite2D.new()
	_drawn_cake.texture = _cake_tex
	var size := Vector2(_cake_tex.get_size())
	var k := CAKE_FIT / maxf(size.x, size.y)
	_drawn_cake.scale = Vector2(k, k)
	var plate := outlet("fcPlate")
	var center := Vector2(158, 320)   # nib (26,188,264,264) -> true centre
	if plate is Sprite2D:
		var ps := plate as Sprite2D
		if ps.texture != null:
			center = ps.position + Vector2(ps.texture.get_size()) * ps.scale * 0.5
	_drawn_cake.position = center + Vector2(0, CAKE_Y_LIFT)
	if _topping != null and _topping.get_parent() != null:
		var parent := _topping.get_parent()
		parent.add_child(_drawn_cake)
		parent.move_child(_drawn_cake, _topping.get_index())
	else:
		add_child(_drawn_cake)


## initializeToppingSelection (0x9D4E0): four TextureButtons in the panel.
## The lock badges on 1..3 are the unreachable IAP branch; not built.
func _build_topping_buttons() -> void:
	if _panel == null:
		return
	for i in TOPPINGS.size():
		var b := TextureButton.new()
		b.texture_normal = _tex(TOPPINGS[i]["topping"])
		b.ignore_texture_size = true
		b.stretch_mode = TextureButton.STRETCH_SCALE
		b.position = Vector2(TOPPING_BTN_X0 + TOPPING_BTN_PITCH * i,
			TOPPING_BTN_POS_Y)
		b.size = TOPPING_BTN_SIZE
		b.pressed.connect(_on_topping_clicked.bind(i))
		_panel.add_child(b)


## toppingClicked: (0x9CD18) + hideToppingSelectionAndShowSifter (0x9D298).
func _on_topping_clicked(tag: int) -> void:
	Audio.play("button_press")
	if _picked:
		# The original lets a re-pick swap art only while the panel shows;
		# once it slid away the buttons are off screen and unreachable.
		return
	_picked = true
	var d: Dictionary = TOPPINGS[tag]
	if _sifter is Sprite2D:
		(_sifter as Sprite2D).texture = _tex(d["sifter"])
	if _topping is Sprite2D:
		var ts := _topping as Sprite2D
		var t := _tex(d["topping"])
		if t != null:
			ts.texture = t
			# Keep the nib's 202x202 footprint (scene ships scale 0.67333).
			ts.scale = Vector2(202, 202) / Vector2(t.get_size())
	# Panel up over 0.5s ease-in; sifter in over 0.4s ease-out.
	if _panel != null:
		if _panel_tween != null and _panel_tween.is_valid():
			_panel_tween.kill()
		_panel_tween = create_tween()
		_panel_tween.tween_property(_panel, "position:y", -PANEL_HEIGHT,
			PANEL_SLIDE).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	if _sifter != null:
		_sifter_tween = create_tween()
		_sifter_tween.tween_property(_sifter, "position", SIFTER_HOME,
			SIFTER_SLIDE).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	dismiss_instruction()
	var shake := outlet("shakeButton")
	if shake != null and shake != self:
		(shake as CanvasItem).visible = true


## shakeClick: (0x9CD08): the original's own button path for the shake
## gesture, which the port adopts wholesale.
func _on_shakeClick() -> void:
	if _picked:
		_start_sifting()


## startSifting (0x9BE50): guard, loop the sift sound, [powder start], and
## schedule stopSifting at 0.6s. The five SSV ticks are the dead sprite
## strip; nothing to tick.
func _start_sifting() -> void:
	if _sifting:
		return
	_sifting = true
	Audio.loop("fc_sugar_sift")
	if _powder != null:
		_powder.start()
	get_tree().create_timer(SIFT_SECONDS).timeout.connect(_stop_sifting)


## stopSifting (0x9BFB8).
func _stop_sifting() -> void:
	if not is_inside_tree():
		return
	_sift_count += 1
	_sifting = false
	Audio.stop("fc_sugar_sift")
	if _sift_count <= SIFTS_NEEDED and _topping != null:
		_topping.modulate.a += TOPPING_STEP
	_stop_powder()
	if _sift_count == SIFTS_NEEDED:
		_show_next_button()
		var shake := outlet("shakeButton")
		if shake != null and shake != self:
			(shake as CanvasItem).visible = false


## showNextButton (0x9C6C0): hide instIV, slide the button in from +500 over
## 0.25s curve 0 -- the shared pattern. Run locally because this screen's
## outlet is named "nextBtn", which Screen.show_next_button ("nextButton")
## cannot see.
func _show_next_button() -> void:
	dismiss_instruction()
	var n := outlet("nextBtn")
	if n == null or n == self or not (n is CanvasItem):
		return
	var btn := n as CanvasItem
	var home: Vector2 = _next_home if _next_home_set else btn.get("position")
	btn.visible = true
	if btn.has_method("set_disabled"):
		btn.set("disabled", false)
	btn.set("position", home + Vector2(500, 0))
	create_tween().tween_property(btn, "position", home, 0.25) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## [powder stop] -- stopSifting, backClick:, nextClick: and
## viewWillDisappear: all send it. Live particles finish their 0.5s.
func _stop_powder() -> void:
	if _powder != null:
		_powder.stop()


# -- hand-off ---------------------------------------------------------

## nextClick: (0x9C8D8): stop the powder, bake the finished cake into a
## 245x245 image -- cakeImg filling it, the topping drawn in (3.5, 5.5,
## 238, 238) at alpha 0.8 -- and hand MakeViewController the original's own
## two-layer infoDict. ItemCenterX/Y are the layers' TOP-LEFTs: both entries
## are zero-frame DecorateItemViews (the TintedIV rule).
func _on_nextClick() -> void:
	Audio.play("button_press")
	_stop_powder()
	_sifting = false
	Audio.stop("fc_sugar_sift")
	GameState.custom_categories = {
		"FunnelCake": {
			"Properties": {
				"IsEdible": true, "ViewIndex": 2, "Type": "Stationary",
				"ItemCenterX": 37.0, "ItemCenterY": 112.0,
			},
			"Image": _bake_cake(),
		},
		"FunnelCakePlate": {
			"Properties": {
				"IsEdible": false, "ViewIndex": 1, "Type": "Stationary",
				"ItemCenterX": 10.0, "ItemCenterY": 90.0,
			},
			"Image": _tex("fc_plate.png"),
		},
	}
	Nav.next()


## skipClick: (0x9CCF8) just calls nextClick:. Its sender is the nib's
## "debug skip" UIRoundedRectButton (242, 387, 84, 37), alpha 0.6, which
## ships UIHidden=YES and has no outlet, so nothing ever shows it -- the
## generated scene hides it too, and it is unreachable. (An older reading
## of "never hidden" came from swapped NIBArchive bool tags.)
func _on_skipClick() -> void:
	_on_nextClick()


## The UIGraphicsBeginImageContext(245, 245) composite from 0x9C8D8. The
## topping bakes at the FIXED alpha 0.8 (bits 0x3F4CCCCD) regardless of how
## far the on-screen overlay got -- original quirk, kept (next only appears
## after 3 sifts, when the overlay shows 0.8 anyway).
func _bake_cake() -> ImageTexture:
	var img := Image.create(245, 245, false, Image.FORMAT_RGBA8)
	if _cake_tex != null:
		var cake := _cake_tex.get_image()
		if cake.is_compressed():
			cake.decompress()
		cake.convert(Image.FORMAT_RGBA8)
		cake.resize(245, 245, Image.INTERPOLATE_BILINEAR)
		img.blend_rect(cake, Rect2i(0, 0, 245, 245), Vector2i.ZERO)
	var top_file: String = TOPPINGS[0]["topping"]
	if _topping is Sprite2D and (_topping as Sprite2D).texture != null:
		top_file = Assets.texture_name((_topping as Sprite2D).texture)
	# fcSugarTopping.image is drawn UNCONDITIONALLY (0x9C8D8): with no pick
	# (the debug-skip path) that is the nib's fc_powdered_sugar_Toping.png,
	# which TOPPINGS[0] already names.
	var top_tex := _tex(top_file)
	if top_tex != null:
		var top := top_tex.get_image()
		if top.is_compressed():
			top.decompress()
		top.convert(Image.FORMAT_RGBA8)
		top.resize(238, 238, Image.INTERPOLATE_BILINEAR)
		for y in top.get_height():
			for x in top.get_width():
				var c := top.get_pixel(x, y)
				c.a *= 0.8
				top.set_pixel(x, y, c)
		img.blend_rect(top, Rect2i(0, 0, 238, 238), Vector2i(4, 6))
	return ImageTexture.create_from_image(img)


## backClick: (0x9C84C): button_press, [powder stop], pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	_stop_powder()
	Nav.back()


## viewWillDisappear: (0x9DE9C): [powder stop], stopAccelerometer, and
## powderedSugarSSV removeFromSuperview (the dead strip, never added -- see
## header). viewDidDisappear: is super only. The sift loop is a PORT CHOICE
## safety stop: no exit is reachable mid-sift (next appears only once the
## third sift has stopped).
func on_exit() -> void:
	_stop_powder()
	Audio.stop("fc_sugar_sift")
