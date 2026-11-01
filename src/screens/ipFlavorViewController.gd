# Ice Pop step 2 -- pick a flavour powder, pour it into the water jug, stir.
#
# GROUNDED from ipFlavorViewController (the class body read from the
# original binary; the 33-colour table cross-read instruction by instruction
# in the disassembly, for the CGFloat args carried over between calls):
#   initWithDictionary: 0xEE418 (colour table 0xEE600..0xEEAC8),
#   viewDidLoad 0xEEFE0, screenSetup 0xEED30, viewWillAppear: 0xEF9A0,
#   showScrollView 0xEB6E4, hideScrollView 0xEBE10,
#   categoryButtonClick: 0xED064, selectFlavorButtonClick: 0xED0C0,
#   showSugarBag: 0xECD98, setColors: 0xEB620, resetVars 0xEEB38,
#   accelerometer:didAccelerate: 0xEC638, startAccelerometer 0xECA38
#   (interval 1/30), hasFinishedPouring 0xEC080, hasFinishedMixing 0xEC2A8,
#   draggableTouchMoved:fromSender: 0xEDEE8, draggableTouchEnded 0xEE130,
#   limitDraggableCenter:ToRect: 0xEDAA8, nextClick: 0xED30C,
#   setMoldLiquidInfo:moldLiquidY: 0xEBF80.
#
# The accelerometer IS started on this screen (startAccelerometer wires the
# shared accelerometer's delegate at 0xECA38; not dead code), so as
# everywhere in the port the tilt becomes press-and-hold at a fixed angle
# inside the grounded clamp range. Tick counts, thresholds and alpha steps
# are unchanged.
#
# Divergences (house precedent from the ms screens):
#  * TintedIV blend modes 5 (lighten) and 1 (multiply) render as a plain
#    modulate.
#  * The nib's pourLiquidRef / sugarPileRef image views are geometry
#    references; the original inserts its tinted TintedIVs directly below
#    them. The port tints in place and adds the second liquid layer above.
#
# Particles: flavorMixSprites is the real SSEmitter (core/particles),
# configured by every showSugarBag:, started / stopped by the 30 Hz
# accelerometer update, stopped by back / next / viewWillDisappear:. The old
# _spawn_powder stand-in is gone.
#
# Keep-state: Nav keeps this screen under ipPour. Coming back (back, or
# Add Flavor's pop) runs viewWillAppear: again, and that calls
# screenSetup: the step starts over (pick a flavour; picker flashes in and
# out), with the ipPour delegate's setMoldLiquidInfo:moldLiquidY: applied.
# What survives is what screenSetup does not touch: the mixing stick's
# position (hasFinishedPouring drops it from wherever it was left), the
# picker's scroll offset, and the carried mold liquid.

extends "res://core/Screen.gd"

const DraggableSprite := preload("res://core/DraggableSprite2D.gd")
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")
## Keep-state helpers and the UIView curves, shared with the kc screens.
const kcKit := preload("res://screens/kcKit.gd")
## The picker's UIScrollView: UIKit's own drag / deceleration /
## bounce physics and scroll indicator (kcScrollView.gd header).
const ScrollView := preload("res://screens/kcScrollView.gd")
const MIX_FX := "ipFlavorViewController.flavorMixSprites"
## The ipPour -> ipFlavor delegate call setMoldLiquidInfo:moldLiquidY:
## (0xEBF80), carried across the pop: ipPour (backClick: 0xF0FE0,
## passInfoToFlavorViewAndPopViewController 0xF17E8) writes
## {"moldLiquidImage": Image|null, "moldLiquidY": float} here before
## Nav.back(); on_resume applies it to this instance's own infoDict.
const DELEGATE_META := "ip_flavor_set_mold_liquid_info"

## The 33 flavour colours, in scroll-view order, from initWithDictionary:
## (0xEE418). All colorWithHue:saturation:brightness:alpha: except index 1
## (UIColor brownColor = RGB 0.6/0.4/0.2) and the last two (white, black).
## The hue ladder steps by 3/32 = 0.09375 with a (pastel s=0.3, vivid,
## dark b=0.7 a=0.7) triple per hue; hue 0.65625 already appeared as index 2
## so its triple is only two entries. Read from the asm literal stream --
## e.g. 0x3F280000 = 0.65625, 0x3E99999A = 0.3, 0x3F333333 = 0.7.
## (RGB literals precomputed from the HSB values so the table stays a
## constant expression; the h/s/b comments are the values as read.)
const COLORS: Array[Color] = [
	Color(1.0, 0.0, 0.0, 1.0),          # 0  h=0       s=1   b=1  (red)
	Color(0.6, 0.4, 0.2, 1.0),          # 1  brownColor
	Color(0.0, 0.0625, 1.0, 1.0),       # 2  h=0.65625 s=1   b=1  (blue)
	Color(1.0, 0.7, 0.7, 1.0),          # 3  h=0       s=0.3 b=1
	Color(0.7, 0.0, 0.0, 0.7),          # 4  h=0       s=1   b=.7 a=.7
	Color(1.0, 0.86875, 0.7, 1.0),      # 5  h=0.09375 s=0.3 b=1
	Color(1.0, 0.5625, 0.0, 1.0),       # 6  h=0.09375 s=1   b=1
	Color(0.7, 0.39375, 0.0, 0.7),      # 7  h=0.09375 s=1   b=.7 a=.7
	Color(0.9625, 1.0, 0.7, 1.0),       # 8  h=0.1875  s=0.3 b=1
	Color(0.875, 1.0, 0.0, 1.0),        # 9  h=0.1875  s=1   b=1
	Color(0.6125, 0.7, 0.0, 0.7),       # 10 h=0.1875  s=1   b=.7 a=.7
	Color(0.79375, 1.0, 0.7, 1.0),      # 11 h=0.28125 s=0.3 b=1
	Color(0.3125, 1.0, 0.0, 1.0),       # 12 h=0.28125 s=1   b=1
	Color(0.21875, 0.7, 0.0, 0.7),      # 13 h=0.28125 s=1   b=.7 a=.7
	Color(0.7, 1.0, 0.775, 1.0),        # 14 h=0.375   s=0.3 b=1
	Color(0.0, 1.0, 0.25, 1.0),         # 15 h=0.375   s=1   b=1
	Color(0.0, 0.7, 0.175, 0.7),        # 16 h=0.375   s=1   b=.7 a=.7
	Color(0.7, 1.0, 0.94375, 1.0),      # 17 h=0.46875 s=0.3 b=1
	Color(0.0, 1.0, 0.8125, 1.0),       # 18 h=0.46875 s=1   b=1
	Color(0.0, 0.7, 0.56875, 0.7),      # 19 h=0.46875 s=1   b=.7 a=.7
	Color(0.7, 0.8875, 1.0, 1.0),       # 20 h=0.5625  s=0.3 b=1
	Color(0.0, 0.625, 1.0, 1.0),        # 21 h=0.5625  s=1   b=1
	Color(0.0, 0.4375, 0.7, 0.7),       # 22 h=0.5625  s=1   b=.7 a=.7
	Color(0.7, 0.71875, 1.0, 1.0),      # 23 h=0.65625 s=0.3 b=1
	Color(0.0, 0.04375, 0.7, 0.7),      # 24 h=0.65625 s=1   b=.7 a=.7
	Color(0.85, 0.7, 1.0, 1.0),         # 25 h=0.75    s=0.3 b=1
	Color(0.5, 0.0, 1.0, 1.0),          # 26 h=0.75    s=1   b=1
	Color(0.35, 0.0, 0.7, 0.7),         # 27 h=0.75    s=1   b=.7 a=.7
	Color(1.0, 0.7, 0.98125, 1.0),      # 28 h=0.84375 s=0.3 b=1
	Color(1.0, 0.0, 0.9375, 1.0),       # 29 h=0.84375 s=1   b=1
	Color(0.7, 0.0, 0.65625, 0.7),      # 30 h=0.84375 s=1   b=.7 a=.7
	Color.WHITE,                        # 31
	Color.BLACK,                        # 32
]

# -- picker (showScrollView 0xEB6E4) ------------------------------------

## Buttons: initWithFrame:(100*(i%3)+24, 100*row+62, 80, 80); inside each a
## tinted Flavor_Mix_Back and a Flavor_Mix_Front overlay, both at (10,10,60,60).
const BTN_X0 := 24.0
const BTN_Y0 := 62.0
const BTN_PITCH := 100.0
const BTN_SIZE := 80.0
const ICON_RECT := Rect2(10, 10, 60, 60)
## contentSize height = 100*(rows)+124 (0xEB6E4 loop tail).
const PANEL_EXTRA_H := 124.0
## The scroll view parks 500 above its resting centre (0xC3FA0000) and slides
## in over 0.25s with UIViewAnimationCurveEaseOut (curve 2).
const PANEL_OFFSET := -500.0
const PANEL_SLIDE := 0.25
## Nib aScrollView frame (0,0,320,480); no indicator / bounce / rate keys,
## so the nib defaults hold: bounces YES, decelerationRate 0.998, the
## vertical indicator shows (contentSize (320, 1224) in 480).
const PANEL_FRAME := Rect2(0, 0, 320, 480)

# -- pour (accelerometer:didAccelerate: 0xEC638, 30 Hz) ------------------

const REST_ROTATION := -0.2618           # clamp high side
const CLAMP_ROTATION := -2.2689          # clamp low side
## Pouring happens while the bag angle sits in [-2.28638132, -1.65806279].
const POUR_MIN := -2.28638132
const POUR_MAX := -1.65806279
## PORT CHOICE: fixed hold angle inside the pour window.
const POUR_ROTATION := -2.0
const TIP_SECONDS := 0.35
const TICK_HZ := 30.0                    # setUpdateInterval: 1/30 (0xECA38)
## pourCount is incremented then compared: > 95 finishes, i.e. 96 ticks.
const POUR_TICKS := 96
## sugarPile.alpha += 0.005263158 (0x3BAC7692) per pouring tick.
const SUGAR_ALPHA_STEP := 0.005263158

# -- jug liquids (viewDidLoad 0xEEFE0 / resetVars 0xEEB38) ---------------

## pourLiquidBase: FP_Water tinted colorWithRed:0.5254902 green:0.9411765
## blue:0.9921569 alpha:1 (0x3F0C0C07/0x3F70F0F1/0x3F7DFDFE), alpha 0.8.
const WATER_TINT := Color(0.5254902, 0.9411765, 0.9921569)
const BASE_ALPHA := 0.8                  # 0x3F4CCCCD
## draggableTouchMoved: per motion event, while pourLiquid.alpha <= 0.8:
##   pourLiquid += 0.006, pourLiquidBase -= 0.006, sugarPile -= 0.00375.
const MIX_LIQUID_STEP := 0.006
const MIX_SUGAR_STEP := 0.00374999994
const MIX_DONE_ALPHA := 0.8
## hasFinishedPouring (0xEC080): the stick jumps 500 up and slides back down
## over 0.4s (double 0x3FD999999999999A).
const STICK_DROP_SECONDS := 0.4
## limitDraggableCenter:ToRect: (0xEDAA8), run after every move and on
## release, keeps the stick's whole 100x264 FRAME inside draggableBounds
## (nib 49,0,201,425): centre x in [49+50, 250-50], y in [0+132, 425-132].
## (The port used to clamp the centre to the bounds rect itself.)
const STICK_FRAME := Vector2(100, 264)
const STICK_CENTER_BOUNDS := Rect2(99, 132, 101, 161)
## Nib: mixingStick frame (110,108,100,264) -- a DraggableIV showing
## transparent.png, so the whole 100x264 frame takes the touch; viewDidLoad
## adds FP_MixStick (35x338) inside it at scale 0.78, centred.
const STICK_HOME := Vector2(160, 240)
const STICK_ART_SCALE := 0.78

## TintedIV blend 5 is kCGBlendModeLighten (out = max(art, tint)). The jug
## water art (FP_Water) is flat 0.706 grey and Flavor_Mix_Back is mostly
## BLACK, so the ms screens' modulate shortcut would render dark flavours
## nearly black; Lighten is what the original computes. Godot 4 gives custom
## canvas shaders no modulate, so colour AND layer alpha ride in `tint`.
## (sugarPile is blend 1 -- multiply -- which plain modulate already is.)
const LIGHTEN_SHADER := "
shader_type canvas_item;
uniform vec4 tint : source_color = vec4(1.0);
void fragment() {
	vec4 art = texture(TEXTURE, UV);
	COLOR = vec4(max(art.rgb, tint.rgb), art.a * tint.a);
}"

var _info: Dictionary = {}
var _selected: Color = Color.WHITE
var _has_selection := false

var _panel: Control
var _panel_content: Node2D
var _panel_shown := false
var _panel_content_h := 0.0
var _sv: Node                            # kcScrollView (aScrollView)

var _bag: Sprite2D
var _base: Sprite2D
var _liquid: Sprite2D
var _sugar: Sprite2D
var _stick: Sprite2D

var _held := false
var _pouring := false                    # isPouring
var _pour_count := 0
var _accum := 0.0
## The shared accelerometer's delegate is this screen (startAccelerometer
## 0xECA38 / stopAccelerometer 0xECAA0); updates arrive at 30 Hz only then.
var _accel_on := false
## flavorMixSprites, the nib's SSEmitter (row 13).
var _mix_fx: SSEmitter
## Every tween this screen starts (kcKit.track / settle, keep-state).
var _tweens: Array = []
var _finished_pouring := false
var _finished_mixing := false
## changeInstruction: records its argument in currentInst (0xEC438);
## showSugarBag: only re-slides "inst_pour" when it is not already up.
var _current_inst := ""

## Mystery flavour (ported):
##   initWithDictionary: 0xEE418  Consumable DM_CONSUMABLE_MYSTERY_FLAVOR /
##     MysteryFlavor_20MixFlavor, cost = CoinCosts."QuickFreeze Ice Pops".
##     MysteryFlavor, 6 when absent; first-time message.
##   viewDidLoad 0xEEFE0  ConsumableButton(btn_mystery_flavor, (0,-25) /
##     (65,3)) at centre (50, 350.5); buyMysteryFlavorClick:; buyAllBtn hidden.
##   buyMysteryFlavorClick: 0xECFF8  "store" sound, purchaseConsumable.
##   consumablePurchased: 0xECAD8  quantity 0, setSelectedColor: a random
##     colour (see mystery_color), showSugarBag:, startAccelerometer. The
##     picker is NOT hidden (a normal tap hides it). startAccelerometer has no
##     port counterpart (the port uses press-and-hold).
##   consumablePurchaseFailed:error:2 0xECCC4  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_FLAVOR"
const MYSTERY_NAME := "MysteryFlavor_20MixFlavor"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery flavor! You never know what flavor it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_flavor.png"
const MYSTERY_CENTER := Vector2(50, 350.5)

var _mystery: RefCounted
var _mystery_button: TextureButton


func on_enter() -> void:
	# initWithDictionary: (0xEE418) keeps its own copy
	# (dictionaryWithDictionary:) of ipSelectStickShape's dict.
	_info = (GameState.get_meta("ip_info", {}) as Dictionary).duplicate()
	# viewDidLoad (0xEEFE0) seeds the mold-liquid carry-over with
	# transparent.png and moldLiquidY -999 via setMoldLiquidInfo:moldLiquidY:
	# (0xEBF80). That helper also sets selectedColor to UIColor blueColor --
	# an original quirk that matters on the add-flavor round trip.
	_set_mold_liquid_info(null, -999.0)

	_build_jug_liquids()
	_build_emitter()
	_build_bag()
	_build_stick()
	_build_mystery()
	_build_panel()
	_view_will_appear()
	set_process(true)


## UINavigationController keeps this controller under ipPour.
func keeps_state_on_push() -> bool:
	return true


## Back from ipPour (its back, or Add Flavor's pop): the delegate call, then
## viewWillAppear: -- screenSetup starts the step over.
func on_resume() -> void:
	kcKit.drop_coin_panel(self)
	if GameState.has_meta(DELEGATE_META):
		var msg: Variant = GameState.get_meta(DELEGATE_META)
		GameState.remove_meta(DELEGATE_META)
		if msg is Dictionary:
			_set_mold_liquid_info((msg as Dictionary).get("moldLiquidImage"),
				float((msg as Dictionary).get("moldLiquidY", -999.0)))
	# The accelerometer restarts from a phone held level (in the port: no hold).
	_held = false
	if _bag != null:
		_bag.rotation = REST_ROTATION
	_view_will_appear()


## viewWillDisappear: (0xEFABC): flavorMixSprites stop, stopAccelerometer,
## "flavored powder_04" stopped. (The stir loop is not stopped here; back /
## next stop it.) Animations in flight finish while covered (settled).
func on_exit() -> void:
	if _mix_fx != null:
		_mix_fx.stop()
	_stop_accelerometer()
	_held = false
	Audio.stop("flavored powder_04")
	kcKit.settle(_tweens)
	if _sv != null:
		_sv.call("settle")               # a flick in flight lands while covered


## setMoldLiquidInfo:moldLiquidY: (0xEBF80): selectedColor = blueColor (into
## infoDict too), plus the carried liquid image (null = transparent.png) and
## its y ("%f").
func _set_mold_liquid_info(image: Variant, y: float) -> void:
	_selected = Color.BLUE
	_info["selectedColor"] = Color.BLUE
	_info["moldLiquidImage"] = image
	_info["moldLiquidY"] = y


## viewWillAppear: (0xEF9A0): back disabled, enableBackButton 0.5s later
## (double 0x3FE0000000000000), then screenSetup.
func _view_will_appear() -> void:
	lock_back_button()
	_screen_setup()


## screenSetup (0xEED30), in its order.
func _screen_setup() -> void:
	if _base != null:
		_set_tint(_base, Color(_tint_of(_base), BASE_ALPHA))
	if _liquid != null:
		_set_tint(_liquid, Color(_tint_of(_liquid), 0.0))
	if _sugar != null:
		_sugar.modulate.a = 0.0
	if _stick != null:
		_stick.visible = false
		_stick.set("enabled", false)
	_set_next_visible(false)
	if _bag != null:
		_bag.visible = false
	if _panel != null:
		_panel.visible = false
	var cat := outlet("selectFlavorButton")
	if cat != null and cat != self:
		cat.visible = true
	_finished_pouring = false
	_finished_mixing = false
	_pouring = false
	_pour_count = 0
	_change_inst("inst_select_flavor.png")
	if _mystery_button != null:
		_mystery_button.visible = true           # setHidden:NO
	# ...and it ends with showScrollView + hideScrollView back to back: the
	# picker is unhidden at its home and slides up off screen (0.25s, curve
	# 2 = ease-out) while the screen appears. showScrollView stops the
	# accelerometer and zeroes the badge; hideScrollView restores the badge
	# and, with the bag hidden, leaves the accelerometer off.
	_stop_accelerometer()
	_set_mystery_alpha(0.0)
	_panel.visible = true
	_panel.position = Vector2.ZERO
	_panel_shown = true
	_hide_panel(true)


## startAccelerometer (0xECA38): this screen becomes the delegate; the
## first 1/30 s update arrives one interval later.
func _start_accelerometer() -> void:
	if not _accel_on:
		_accel_on = true
		_accum = 0.0


## stopAccelerometer (0xECAA0).
func _stop_accelerometer() -> void:
	_accel_on = false


func _tween() -> Tween:
	return kcKit.track(_tweens, create_tween())


## consumablePurchased:'s colour: hue = arc4random() % 1000 / 1000,
## saturation and brightness = arc4random() % 500 / 1000 + 0.5, alpha 1.
static func mystery_color() -> Color:
	var hue := float(randi() % 1000) / 1000.0
	var sat := float(randi() % 500) / 1000.0 + 0.5
	var bri := float(randi() % 500) / 1000.0 + 0.5
	return Color.from_hsv(hue, sat, bri, 1.0)


## viewDidLoad: the ConsumableButton, and init's Consumable.
func _build_mystery() -> void:
	_mystery = ConsumableScript.new(MYSTERY_KEY, MYSTERY_NAME, MYSTERY_COST)
	_mystery.set("first_time_message", MYSTERY_MESSAGE)
	_mystery.set("on_purchased", _on_mystery_purchased)
	_mystery.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyMysteryFlavor"
	b.call("setup", MYSTERY_ART, 0, -25, MYSTERY_COST, 65, 3)
	b.position = MYSTERY_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyMysteryFlavorClick)
	add_child(b)
	_mystery_button = b


func _on_buyMysteryFlavorClick() -> void:
	Audio.play("store")
	_mystery.call("purchase", self)


## consumablePurchased: (0xECAD8): setSelectedColor: + showSugarBag:, then
## startAccelerometer.
func _on_mystery_purchased(_free: bool) -> void:
	_apply_flavor(mystery_color())
	_start_accelerometer()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


static func _lighten(tint: Color) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = LIGHTEN_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("tint", tint)
	return mat


static func _tint_of(s: Sprite2D) -> Color:
	if s != null and s.material is ShaderMaterial:
		return (s.material as ShaderMaterial).get_shader_parameter("tint")
	return Color.WHITE


static func _set_tint(s: Sprite2D, tint: Color) -> void:
	if s != null and s.material is ShaderMaterial:
		(s.material as ShaderMaterial).set_shader_parameter("tint", tint)


# -- construction ------------------------------------------------------

## The two liquid layers replace the nib's pourLiquidRef in place: base
## (plain water tint, alpha 0.8) below, selected-colour layer above at
## alpha 0 until stirring blends it in. Their TintedIVs get explicit frames
## in viewDidLoad, so centres are true centres.
func _build_jug_liquids() -> void:
	var ref := outlet("pourLiquidRef")
	if ref is Sprite2D:
		var r := ref as Sprite2D
		r.visible = false
		_base = Sprite2D.new()
		_base.texture = r.texture
		_base.centered = false
		_base.position = r.position
		_base.material = _lighten(Color(WATER_TINT, BASE_ALPHA))
		add_child(_base)
		move_child(_base, r.get_index())
		_liquid = Sprite2D.new()
		_liquid.texture = r.texture
		_liquid.centered = false
		_liquid.position = r.position
		_liquid.material = _lighten(Color(_selected, 0.0))
		add_child(_liquid)
		move_child(_liquid, r.get_index())
	var sref := outlet("sugarPileRef")
	if sref is Sprite2D:
		var s := sref as Sprite2D
		s.visible = false
		_sugar = Sprite2D.new()
		_sugar.texture = s.texture
		_sugar.centered = false
		_sugar.position = s.position
		_sugar.modulate = Color(_selected, 0.0)
		add_child(_sugar)
		move_child(_sugar, s.get_index())


## flavorMixSprites: the nib's SSEmitter (id 5, frame (130,115,81,298)),
## above pourLiquidRef and below sugarPileRef -- the generated scene's outlet
## node sits at the frame origin in that place. Configured by showSugarBag:.
func _build_emitter() -> void:
	var host := outlet("flavorMixSprites")
	if host == null or host == self:
		return
	_mix_fx = SSEmitter.attach(host, SSEmitterConfigs.frame_size(MIX_FX)) \
		as SSEmitter


## pourSourceContainer (nib frame 190,24,105,132) is the powder bag. It gets
## the tinted Flavor_Mix_Back once a flavour is picked, keeps the
## Flavor_Mix_Front overlay on top (viewDidLoad adds it as a subview), and
## rotates about its own centre while pouring. self_modulate carries the tint
## so the overlay stays untinted.
func _build_bag() -> void:
	var n := outlet("pourSourceContainer")
	if not (n is Sprite2D):
		return
	_bag = n as Sprite2D
	var size := Vector2(105, 132)
	if _bag.texture != null:
		size = _bag.texture.get_size()
	if not _bag.centered:
		_bag.centered = true
		_bag.position += size * 0.5
	var front := Sprite2D.new()
	front.texture = _tex("Flavor_Mix_Front.png")
	front.position = Vector2.ZERO
	_bag.add_child(front)
	_bag.rotation = REST_ROTATION
	_bag.visible = false


func _build_stick() -> void:
	_stick = DraggableSprite.new()
	# The DraggableIV's own image is a transparent frame-sized stand-in so
	# DraggableSprite2D hit-tests the full 100x264 view, as UIKit did.
	var frame_img := Image.create(int(STICK_FRAME.x), int(STICK_FRAME.y),
		false, Image.FORMAT_RGBA8)
	_stick.texture = ImageTexture.create_from_image(frame_img)
	var art := Sprite2D.new()
	art.texture = _tex("FP_MixStick.png")
	art.scale = Vector2(STICK_ART_SCALE, STICK_ART_SCALE)
	_stick.add_child(art)
	_stick.position = STICK_HOME
	_stick.set("drag_bounds", STICK_CENTER_BOUNDS)
	_stick.visible = false
	# A hidden UIView receives no touches; DraggableSprite2D has no such
	# check, so gate it explicitly or the invisible stick eats the pour hold.
	_stick.set("enabled", false)
	add_child(_stick)
	# Nib order: mixingStick sits just above FP_Water_Jug_Back, BELOW
	# pourLiquidRef -- so the two water layers viewDidLoad inserts below the
	# ref, the powder, the sugar pile and the jug front (pourContainer) all
	# draw over it: the stick stands IN the jug. Nothing ever brings it to
	# the front. (The port used to draw it above everything.) The
	# layers above it take no touches (TintedIVs set userInteractionEnabled
	# NO, the SSEmitter and pourContainer are NO in the nib), so it still
	# drags.
	var ms := outlet("mixingStick")
	if ms != null and ms != self:
		move_child(_stick, (ms as Node).get_index() + 1)
	_stick.connect("drag_moved", _on_stick_moved)
	_stick.connect("drag_ended", _on_stick_released)


## showScrollView (0xEB6E4): 33 buttons in a 3-column grid inside a
## full-screen scroll view; content is 1224 tall so it drag-scrolls. With
## everything unlocked the black_lock overlays are dead.
func _build_panel() -> void:
	_panel = Control.new()
	_panel.clip_contents = true
	_panel.size = Vector2(320, 480)
	_panel.position = Vector2(0, PANEL_OFFSET)
	_panel.visible = false
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	# The picker is the nib's aScrollView: above the jug and the bag, below
	# instIV, the category button and back/next (nib order), and below the
	# mystery badge viewDidLoad adds last.
	var sv := outlet("aScrollView")
	if sv != null and sv != self:
		move_child(_panel, (sv as Node).get_index())

	_panel_content = Node2D.new()
	_panel.add_child(_panel_content)

	var bg := _tex("Sub_Button_Background.png")
	var back := _tex("Flavor_Mix_Back.png")
	var front := _tex("Flavor_Mix_Front.png")
	var rows := 0
	for i in COLORS.size():
		var col := i % 3
		var origin := Vector2(BTN_X0 + BTN_PITCH * col,
			BTN_Y0 + BTN_PITCH * rows)
		var item := Node2D.new()
		item.position = origin
		_panel_content.add_child(item)
		if bg != null:
			var b := Sprite2D.new()
			b.texture = bg
			b.centered = false
			b.scale = Vector2(BTN_SIZE, BTN_SIZE) / bg.get_size()
			item.add_child(b)
		if back != null:
			var icon := Sprite2D.new()
			icon.texture = back
			icon.centered = false
			icon.position = ICON_RECT.position
			icon.scale = ICON_RECT.size / back.get_size()
			# TintedIV(Flavor_Mix_Back, colour, 5) -> Lighten.
			icon.material = _lighten(Color(COLORS[i].r, COLORS[i].g,
				COLORS[i].b, 1.0))
			item.add_child(icon)
		if front != null:
			var over := Sprite2D.new()
			over.texture = front
			over.centered = false
			over.position = ICON_RECT.position
			over.scale = ICON_RECT.size / front.get_size()
			item.add_child(over)
		if col == 2:
			rows += 1
	if COLORS.size() % 3 != 0:
		rows += 1
	_panel_content_h = BTN_PITCH * rows + PANEL_EXTRA_H
	# setContentSize:(320, 100 * rows + 124) in the build loop (0xEB6E4).
	_sv = ScrollView.new()
	_sv.name = "aScrollViewSim"
	add_child(_sv)
	_sv.call("configure", true, PANEL_FRAME, _panel_content_h)
	_sv.set("content", _panel_content)
	_sv.call("add_indicator", _panel, Rect2(Vector2.ZERO, PANEL_FRAME.size))
	_sv.connect("tapped", _on_panel_tapped)


# -- picker interaction ------------------------------------------------

## categoryButtonClick: (0xED064) -> showScrollView / hideScrollView toggle.
func _on_categoryButtonClick() -> void:
	Audio.play("button_press")
	if _panel_shown:
		_hide_panel(true)
	else:
		_show_panel()


func _show_panel() -> void:
	# showScrollView stops the accelerometer while the picker is up, and
	# sets the mystery badge's alpha to 0 (hidden, untouchable).
	_stop_accelerometer()
	_set_held(false)
	_set_mystery_alpha(0.0)
	_panel.visible = true
	_panel.position = Vector2(0, PANEL_OFFSET)
	_tween().tween_property(_panel, "position", Vector2.ZERO, PANEL_SLIDE) \
		.set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_OUT))
	_panel_shown = true


func _hide_panel(_animated: bool) -> void:
	if not _panel_shown:
		return
	# hideScrollView (0xEBE10): the accelerometer restarts if the bag is
	# showing; badge alpha back to 1.
	if _bag != null and _bag.visible:
		_start_accelerometer()
	_set_mystery_alpha(1.0)
	var tw := _tween()
	tw.tween_property(_panel, "position", Vector2(0, PANEL_OFFSET),
		PANEL_SLIDE).set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_OUT))
	tw.tween_callback(func() -> void: _panel.visible = false)
	_panel_shown = false


func _change_inst(image_name: String) -> void:
	_current_inst = image_name
	change_instruction(image_name)


## UIKit skips views at alpha 0 when hit-testing, so alpha 0 doubles as
## "not tappable".
func _set_mystery_alpha(a: float) -> void:
	if _mystery_button == null:
		return
	_mystery_button.modulate.a = a
	_mystery_button.mouse_filter = Control.MOUSE_FILTER_STOP if a > 0.0 \
		else Control.MOUSE_FILTER_IGNORE


## selectFlavorButtonClick: (0xED0C0): button sound, hide the picker, dress
## the bag (showSugarBag: 0xECD98).
func _pick_color(index: int) -> void:
	_start_accelerometer()
	Audio.play("button_press")
	_hide_panel(true)
	_apply_flavor(COLORS[index])


func _apply_flavor(color: Color) -> void:
	_selected = color
	_has_selection = true
	# setColors: (0xEB620) -- infoDict["selectedColor"], both tinted layers.
	_info["selectedColor"] = color
	GameState.set_meta("ip_info", _info)
	if _liquid != null:
		_set_tint(_liquid, Color(color, _tint_of(_liquid).a))
	if _sugar != null:
		_sugar.modulate = Color(color.r, color.g, color.b, _sugar.modulate.a)
	if _bag != null:
		_bag.material = _lighten(Color(color, 1.0))
	if _current_inst != "inst_pour.png":
		_change_inst("inst_pour.png")
	# setParticles:tint:selectedColor ... (call 0xECFD8): re-configured on
	# every pick, which also restarts its frame bookkeeping.
	if _mix_fx != null:
		SSEmitterConfigs.apply(_mix_fx, MIX_FX, color)
	_reset_vars()


## resetVars (0xEEB38).
func _reset_vars() -> void:
	if _sugar != null:
		_sugar.modulate.a = 0.0
	if _liquid != null:
		_set_tint(_liquid, Color(_tint_of(_liquid), 0.0))
	if _base != null:
		_set_tint(_base, Color(WATER_TINT, BASE_ALPHA))
	if _stick != null:
		_stick.visible = false
		_stick.set("enabled", false)
	_set_next_visible(false)
	if _bag != null:
		_bag.visible = true
		_bag.rotation = REST_ROTATION
	_finished_pouring = false
	_finished_mixing = false
	_pouring = false
	_pour_count = 0


# -- input -------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	# Only while shown: a picker sliding away is already at its model
	# position off screen as far as UIKit hit-testing is concerned.
	if _panel_shown:
		_panel_input(event)
		return
	# Press-and-hold pour (PORT CHOICE) once a flavour is on the bag. The hold
	# stands for the device tilt, which only reaches the screen while it is
	# the accelerometer's delegate.
	if _accel_on and _bag != null and _bag.visible and not _finished_pouring:
		if event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT:
			_set_held(event.pressed)


## The open picker: the scroll view takes the touches (drag, flick, tap).
func _panel_input(event: InputEvent) -> void:
	if _sv != null and _sv.call("handle_input", event):
		get_viewport().set_input_as_handled()


## A touch that never became a drag reaches the button under it
## (touchUpInside: the release must stay within its bounds + 70 pt).
func _on_panel_tapped(press: Vector2, release: Vector2) -> void:
	for i in COLORS.size():
		var col := i % 3
		var row := i / 3
		var rect := Rect2(BTN_X0 + BTN_PITCH * col, BTN_Y0 + BTN_PITCH * row,
			BTN_SIZE, BTN_SIZE)
		if rect.has_point(press):
			if ScrollView.release_inside(rect, release):
				_pick_color(i)
			return


func _set_held(value: bool) -> void:
	if _held == value:
		return
	_held = value
	if _bag == null:
		return
	_tween().tween_property(_bag, "rotation",
		POUR_ROTATION if value else REST_ROTATION, TIP_SECONDS) \
		.set_trans(Tween.TRANS_SINE)


# -- the pour (0xEC638, 30 Hz) -----------------------------------------

func _process(delta: float) -> void:
	if not _accel_on:
		return
	_accum += delta
	while _accel_on and _accum >= 1.0 / TICK_HZ:
		_accum -= 1.0 / TICK_HZ
		_accelerometer_tick()


## One accelerometer:didAccelerate: update (0xEC638). The bag's angle is
## the press-and-hold tween; everything after the transform is the
## original's, in order.
func _accelerometer_tick() -> void:
	var a: float = _bag.rotation if _bag != null else REST_ROTATION
	if a > POUR_MAX or a < POUR_MIN or _finished_pouring:
		# Out of the pour window, or already finished (the emitter keeps
		# running one update past hasFinishedPouring and stops here).
		if _mix_fx != null:
			_mix_fx.stop()
		_pouring = false
		Audio.stop("flavored powder_04")
		return
	_pour_count += 1
	if _pour_count > POUR_TICKS - 1:
		_finish_pouring()
		Audio.stop("flavored powder_04")
		return
	if _sugar != null:
		_sugar.modulate.a += SUGAR_ALPHA_STEP
	if not _pouring:
		if _mix_fx != null:
			_mix_fx.start()
		_pouring = true
	# The pour leaves instIV alone: "inst_pour" stays up until
	# hasFinishedPouring swaps in the mixing banner.
	Audio.loop("flavored powder_04")             # only if not playing


## hasFinishedPouring (0xEC080) plus the caller's tail (bag and category
## button hidden). The mixing stick jumps 500 up from WHEREVER IT IS and
## slides back down over 0.4s, curve 0 (ease-in-out) -- on an Add Flavor
## round trip that is where the player left it, not the nib home.
func _finish_pouring() -> void:
	_finished_pouring = true
	_pouring = false
	_change_inst("inst_mix_ingreds.png")
	var home := _stick.position
	_stick.position = home + Vector2(0, -500)
	_stick.visible = true
	_stick.set("enabled", true)
	# "Show_Mixing_Stick" is +beginAnimations:/commitAnimations (0xEC080),
	# so the stick takes touches on the way down -- at `home`, its model --
	# and a grab hands it to the drag. The port used to hit-test it where it
	# was drawn and let the drop tween keep pulling a grabbed stick down
	# under the finger.
	kcKit.animate_draggable(_tweens, self, _stick, home, STICK_DROP_SECONDS,
		kcKit.UI_EASE_IN_OUT)
	# hasFinishedPouring ends with buyMysteryFlavor setHidden:YES.
	if _mystery_button != null:
		_mystery_button.visible = false
	_bag.visible = false
	var cat := outlet("selectFlavorButton")
	if cat != null and cat != self:
		cat.visible = false


# -- mixing (0xEDEE8 / 0xEE130) ----------------------------------------

func _on_stick_moved(_pos: Vector2) -> void:
	if not _finished_pouring or _finished_mixing:
		return
	Audio.loop("metal rod stir_03")
	if _liquid == null:
		return
	# The alpha steps are per touchesMoved: event (134 of them to mix);
	# iOS delivered at most one per 60 Hz frame.
	if not accept_touch_move():
		return
	var la := _tint_of(_liquid)
	if la.a <= MIX_DONE_ALPHA:
		_set_tint(_liquid, Color(la, la.a + MIX_LIQUID_STEP))
		if _base != null:
			var ba := _tint_of(_base)
			_set_tint(_base, Color(ba, ba.a - MIX_LIQUID_STEP))
		if _sugar != null:
			_sugar.modulate.a -= MIX_SUGAR_STEP
	else:
		_finish_mixing()


func _on_stick_released(_pos: Vector2, _hit: bool) -> void:
	Audio.stop("metal rod stir_03")


## hasFinishedMixing (0xEC2A8): latch once, show next.
func _finish_mixing() -> void:
	if _finished_mixing:
		return
	_finished_mixing = true
	Audio.stop("metal rod stir_03")
	_set_next_visible(true)
	show_next_button()


# -- navigation --------------------------------------------------------

## nextClick: (0xED30C): sound, stop loops, push ipPourViewController with
## the infoDict (selectedColor already stored by setColors:).
func _on_nextClick() -> void:
	Audio.play("button_press")
	if _mix_fx != null:
		_mix_fx.stop()
	# initWithDictionary:andDelegate: -- ipPour copies the dict it is given.
	GameState.set_meta("ip_info", _info.duplicate())
	Nav.next()
	Audio.stop("flavored powder_04")
	Audio.stop("metal rod stir_03")


## backClick: (0xED1BC): sound, flavorMixSprites stop, pop, then the two
## sound stops.
func _on_backClick() -> void:
	Audio.play("button_press")
	if _mix_fx != null:
		_mix_fx.stop()
	Nav.back()
	Audio.stop("flavored powder_04")
	Audio.stop("metal rod stir_03")


func _set_next_visible(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.set("disabled", not on)
