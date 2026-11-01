# Ice Pop step 3 -- tilt the jug; the flavoured water fills the mold.
#
# From the original binary (disassembly at the ObjC method list's IMPs; the
# pour tail checked instruction by instruction):
#   initWithDictionary:andDelegate: 0xF2468, viewDidLoad 0xF2650,
#   screenSetup 0xF2170, initMaskedIV 0xF02A4,
#   accelerometer:didAccelerate: 0xF1A08 (tail disasm 0xF1E66..0xF20A6),
#   offsetLiquid 0xF1964, getMaskStart: 0xF007C, getMaskEnd: 0xF0148,
#   shouldShowEmitter: 0xF01C0, startAccelerometer 0xF20D0 (interval 1/30),
#   nextClick: 0xF10C8, addFlavor: 0xF18B4,
#   passInfoToFlavorViewAndPopViewController 0xF17E8,
#   getScreenshotOfMoldLiquid 0xF070C, setScreenshotOfMoldLiquid 0xF0B6C,
#   setInfoDictAndPushViewController 0xF0BBC, viewWillAppear: 0xF2EF8,
#   viewWillDisappear: 0xF302C, showNextButton 0xF0A08.
#
# The accelerometer is real here (0xF20D0 sets the shared delegate), so the
# port's press-and-hold applies: one fixed angle inside the grounded clamp;
# every tick count and threshold is the original's.
#
# ORIGINAL BUG, PORTED: the fill-complete check calls getMaskEnd: and then
# DISCARDS the result -- the comparison at 0xF203A is against the literal
# 310.0 (dbl_F20C0), so every mold stops at the same water line no matter
# what ipMaskPoints says its end is. Verified in the disassembly; the per-
# mold maskEnd values (227..316) are dead.
#
# DEAD CODE, NOT PORTED: shouldShowEmitter: (0xF01C0) is computed and its
# result thrown away at the call site (0xF1FC8): the original code has no
# consumer and no ipGLFXView emitter call anywhere in this class. The splash
# emitter never fires in the shipped build.
#
# MaskedIV geometry (initMaskedIV 0xF02A4): the masked view is created at
# the mask's own size (initWithBaseImg:andMaskImg: 0x46CE0 -> initWithFrame
# (0,0,320,333)), so setCenter: to the mold's centre (161, 292.5) is a TRUE
# centre, then the whole view is rotated pi. The Water_Wave base (320x350)
# is drawn inside it at baseOrigPt, which starts at (0, -waveHeight) =
# (0, -350) -- or (0, -moldLiquidY) when resuming after Add Flavor -- and
# rises 5px every 5th tick (offsetLiquid 0xF1964).
#
# MASK ORIENTATION: MaskedIV drawRect: (0x46E68) calls
# CGContextClipToMask inside UIKit's flipped drawing context without a CTM
# flip, so the mask lands UPSIDE DOWN in the view (the MaskedIV quirk). The
# FP_Pop_Mask_N art is authored as the vertical mirror of FP_Pop_Shape_N
# (dog, fish, dino, horse, clover all checked), which is exactly what makes
# the quirk come out right: flipped once by the clip and turned pi with the
# view, the liquid fills the pi-turned mold art. Sampling the mask upright --
# as the port did -- filled every asymmetric mold upside down, and baked an
# upside-down juice into Make/Eat.

#
# KEEP-STATE: Nav keeps this screen under the extras
# screen. Back from there runs viewWillAppear: -> screenSetup again: with
# shouldResetMold armed by nextClick:, the carried liquid is dropped
# (transparent, moldLiquidY "-1000.000000") and initMaskedIV builds a fresh,
# empty mold liquid -- viewDidDisappear: had already removed the old layers.
# The step is poured again from 1000 px down.
#
# The flavour screen is the delegate; its setMoldLiquidInfo:moldLiquidY:
# crosses the pop through GameState meta (ipFlavor.DELEGATE_META).

extends "res://core/Screen.gd"

const ipFlavor := preload("res://screens/ipFlavorViewController.gd")
## Keep-state helpers shared with the kc screens.
const kcKit := preload("res://screens/kcKit.gd")

## Skip consumable (ported; the original shows its badge):
## initWithDictionary:andDelegate: 0xF2468 builds Consumable DM_CONSUMABLE_SKIP / Skip_30AddFlavor,
## cost = the dead server table GameData.CoinCosts ... SkipIngredients, 3 when
## absent; first-time message below. viewDidLoad 0xF2650 builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0xF0F74 ("store" sound,
## purchaseConsumable). consumablePurchased: 0xF0CF4 calls nextClick: with the badge as sender -- the same path as the next button.
## consumablePurchaseFailed:error: 0xF0EA0 (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_30AddFlavor"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton

## The import cache's data/ipMaskPoints.json (Assets).
const MASK_POINTS := "ipMaskPoints"
const DESIGN_MOLD_CENTER := Vector2(161, 292.5)   # nib mold frame (1,126,320,333)
const MASK_SIZE := Vector2i(320, 333)
const WAVE_HEIGHT := 350.0                        # Water_Wave.png is 320x350

# -- the pour (0xF1A08) -------------------------------------------------

const REST_ROTATION := -0.2618      # clamp high side
const CLAMP_ROTATION := -1.9199     # clamp low side
## Pouring happens while the jug angle is in [-1.93731547, -1.48352986].
const POUR_MIN := -1.93731547
const POUR_MAX := -1.48352986
## PORT CHOICE: fixed hold angle inside the pour window.
const POUR_ROTATION := -1.75
const TIP_SECONDS := 0.35
const TICK_HZ := 30.0               # setUpdateInterval: 1/30 (0xF20D0)
## offsetLiquid every 5th tick: baseOrigPt.y += 5.
const OFFSET_EVERY := 5
const OFFSET_STEP := 5.0
## The dead-getMaskEnd literal: full when baseOrigPt.y + 333 > 310.
const FILL_STOP := 310.0
const MASK_SPAN := 333.0
## Stream frame: x = spout-in-view - width/2, y = spoutY - 20 (0xF1A08).
const STREAM_Y_LIFT := 20.0
const STREAM_ALPHA := 0.8           # liquidPouring setAlpha: 0x3F4CCCCD

## pourLiquidGroup nib frame (166,10,132,160): UIView transforms rotate
## about the centre, (232, 90). spoutRef is (28,3,15,13) inside it.
const GROUP_ORIGIN := Vector2(166, 10)
const GROUP_SIZE := Vector2(132, 160)
const SPOUT_LOCAL_CENTER := Vector2(35.5, 9.5)

const ADD_FLAVOR_DELAY := 0.5       # 0xF1948, double 0x3FE0000000000000
const NEXT_PUSH_DELAY := 0.6        # 0xF11D6, double 0x3FE3333333333333
## viewWillAppear: (0xF2EF8) disables back and Add Flavor; enableButtons
## (0xF0038) re-enables both 0.5s later (double 0x3FE0000000000000).
const BUTTON_LOCKOUT := 0.5
## setMoldLiquidInfo:moldLiquidY: sentinel: "no carried liquid".
const NO_CARRY_Y := -999

## TintedIV blend mode 5 is kCGBlendModeLighten: out = max(art, tint) per
## channel. That is load-bearing, NOT a nicety -- Water_Wave.png and
## FP_Water_Drop.png are pure BLACK art (rgb 0, ~74% / 100% alpha), so the
## ms screens' modulate shortcut renders every flavour black; Lighten over
## black IS the flavour colour. Verified against the palette bytes.
##
## The masked pour rides the same shader: sample the mold mask at the wave
## pixel's position in mask space and use it as coverage (the mask art is an
## alpha-less CG image mask -- black paints -- hence inverted luminance).
## clip_children was tried first and silently drops modulate on the clipped
## subtree, and Godot 4 gives custom canvas shaders no modulate at all, so
## both the colour and the layer alpha ride in the `tint` uniform.
const LIQUID_SHADER := "
shader_type canvas_item;
uniform sampler2D mask_tex : filter_linear;
uniform vec4 tint : source_color = vec4(1.0);
uniform float offset_y = -350.0;
uniform vec2 wave_size = vec2(320.0, 350.0);
uniform vec2 mask_size = vec2(320.0, 333.0);
void fragment() {
	vec2 mp = (UV * wave_size + vec2(0.0, offset_y)) / mask_size;
	float cov = 0.0;
	if (mp.x >= 0.0 && mp.x <= 1.0 && mp.y >= 0.0 && mp.y <= 1.0) {
		// MaskedIV quirk: the clip mask lands vertically flipped.
		vec4 m = texture(mask_tex, vec2(mp.x, 1.0 - mp.y));
		cov = (1.0 - dot(m.rgb, vec3(0.299, 0.587, 0.114))) * m.a;
	}
	vec4 art = texture(TEXTURE, UV);
	COLOR = vec4(max(art.rgb, tint.rgb), art.a * cov * tint.a);
}"

## Plain Lighten, for the un-masked TintedIVs (jug water, pour stream).
const LIGHTEN_SHADER := "
shader_type canvas_item;
uniform vec4 tint : source_color = vec4(1.0);
void fragment() {
	vec4 art = texture(TEXTURE, UV);
	COLOR = vec4(max(art.rgb, tint.rgb), art.a * tint.a);
}"

static var _mask_cache: Dictionary = {}

var _info: Dictionary = {}
var _mask_points: Dictionary = {}
var _mold_index := 0
var _color: Color = Color.WHITE

var _group: Node2D
var _liquid_container: Node2D
var _wave: Sprite2D
var _old: Sprite2D
var _stream: Sprite2D

var _base_y := -350.0
var _held := false
var _pouring := false
var _tick_count := 0
var _accum := 0.0
var _finished := false
var _next_shown := false               # isNextButtonShown
var _leaving := false
## Every tween this screen starts (kcKit.track / settle, keep-state).
var _tweens: Array = []


func on_enter() -> void:
	# initWithDictionary:andDelegate: (0xF2468) keeps its own copy
	# (dictionaryWithDictionary:) of the flavour screen's dict.
	_info = (GameState.get_meta("ip_info", {}) as Dictionary).duplicate()
	# viewDidLoad (0xF2650): the badge, the chosen stick and mold, the jug,
	# the pour stream (inserted below the mold first, so it ends up BEHIND
	# the mold liquid screenSetup's initMaskedIV inserts there later).
	_build_skip()
	_mold_index = int(_info.get("moldIndex", 0))
	_color = _info.get("selectedColor", Color.WHITE)
	_load_mask_points()
	_dress_mold_and_stick()
	_build_group()
	_build_stream()
	_view_will_appear()
	set_process(true)


## UINavigationController keeps this controller under the extras screen.
func keeps_state_on_push() -> bool:
	return true


## Back from the extras screen: viewWillAppear: again (see the header).
func on_resume() -> void:
	kcKit.drop_coin_panel(self)
	_leaving = false
	_held = false
	if _group != null:
		_group.rotation = REST_ROTATION    # the accelerometer at rest
	_view_will_appear()


## viewWillDisappear: (0xF302C) stopAccelerometer; viewDidDisappear:
## (0xF306C) removes moldLiquid and oldMoldLiquid from the view.
func on_exit() -> void:
	_held = false
	_stop_pour_fx()
	kcKit.settle(_tweens)
	if _liquid_container != null:
		_liquid_container.get_parent().remove_child(_liquid_container)
		_liquid_container.queue_free()
		_liquid_container = null
		_wave = null
		_old = null


## viewWillAppear: (0xF2EF8): back and Add Flavor off for 0.5s, then
## screenSetup (0xF2170).
func _view_will_appear() -> void:
	_lock_buttons()
	_screen_setup()


## screenSetup (0xF2170), in its order.
func _screen_setup() -> void:
	# shouldResetMold (armed by nextClick:) wipes the carried liquid.
	if str(_info.get("shouldResetMold", "")) == "TRUE":
		_info["moldLiquidImage"] = null
		_info["moldLiquidY"] = -1000.0     # %f of -1000.0 (0xC08F4000)
		_info["shouldResetMold"] = "FALSE"
	# startAccelerometer: the port's _process tilt ticks run whenever the
	# screen is in the tree and not leaving.
	var inst := _instruction_node()
	if inst != null:
		inst.visible = true                # instIV setHidden:NO only
	_set_next_visible(false)
	if _stream != null:
		_stream.visible = false
	if _group != null:
		_group.visible = true
	var add := _add_flavor_button()
	if add != null:
		add.visible = true
	_finished = false
	_pouring = false
	_next_shown = false
	_accum = 0.0
	_build_liquid()                        # initMaskedIV
	# liquidPouring changeColor: infoDict["selectedColor"].
	var c: Color = _info.get("selectedColor", _color)
	if _stream != null and _stream.material is ShaderMaterial:
		(_stream.material as ShaderMaterial).set_shader_parameter("tint",
			Color(c, STREAM_ALPHA))
	if _skip_button != null:
		_skip_button.visible = true


func _tween() -> Tween:
	return kcKit.track(_tweens, create_tween())


## viewWillAppear: back and Add Flavor off for BUTTON_LOCKOUT.
func _lock_buttons() -> void:
	lock_back_button()
	var add := _add_flavor_button()
	if add == null:
		return
	add.set("disabled", true)
	await get_tree().create_timer(BUTTON_LOCKOUT).timeout
	if is_instance_valid(add):
		add.set("disabled", false)


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _load_mask_points() -> void:
	var parsed: Variant = Assets.json(MASK_POINTS)
	if typeof(parsed) == TYPE_DICTIONARY:
		_mask_points = parsed


## getMaskStart: (0xF007C): maskPoints["%d" % (index+1)][0].
func _mask_start(index: int) -> float:
	var row: Array = _mask_points.get(str(index + 1), [])
	return float(row[0]) if row.size() > 0 else 0.0


## getMaskEnd: (0xF0148): element [1]. Read for fidelity; the original
## discards it (see the header) and so does the port.
func _mask_end(index: int) -> float:
	var row: Array = _mask_points.get(str(index + 1), [])
	return float(row[1]) if row.size() > 1 else 0.0


# -- construction ------------------------------------------------------

## viewDidLoad (0xF2650): stick and mold take the chosen art and both are
## rotated pi -- the mold hangs open-end-up for filling.
func _dress_mold_and_stick() -> void:
	for pair in [["stick", "stickFileString"], ["mold", "moldFileString"]]:
		var n := outlet(pair[0])
		if not (n is Sprite2D):
			continue
		var s := n as Sprite2D
		var t := _tex(str(_info.get(pair[1], "")))
		if t != null:
			s.texture = t
		if not s.centered and s.texture != null:
			s.centered = true
			s.position += s.texture.get_size() * 0.5
		s.rotation = PI


## The jug rotates about the UIKit centre of its (166,10,132,160) frame.
## The generated scene parks the Node2D at the frame origin, so re-pivot it.
func _build_group() -> void:
	var n := outlet("pourLiquidGroup")
	if not (n is Node2D):
		return
	_group = n as Node2D
	for child in _group.get_children():
		if child is Node2D:
			(child as Node2D).position -= GROUP_SIZE * 0.5
	_group.position = GROUP_ORIGIN + GROUP_SIZE * 0.5
	_group.rotation = REST_ROTATION
	# pourLiquid: FP_Water tinted with the selected colour at the ref's
	# frame -- TintedIV blend 5, so Lighten. The nib ref carries the
	# geometry; shade it in place.
	var ref := outlet("pourLiquidRef")
	if ref is Sprite2D:
		(ref as Sprite2D).material = _lighten(Color(_color, 1.0))
		# The nib ref itself is UIHidden; it stands in here for the pourLiquid
		# TintedIV viewDidLoad builds at its centre (natural 212x234 art at
		# scale 0.5 = the ref's 106x117 frame), so make it explicitly visible.
		(ref as Sprite2D).visible = true


## initMaskedIV (0xF02A4): moldLiquid = MaskedIV(Water_Wave tinted, mask),
## centred on the mold and rotated pi, plus oldMoldLiquid (the carry-over
## screenshot) above it, below the mold art.
func _build_liquid() -> void:
	# baseOrigPt starts at (0,0); initMaskedIV subtracts the wave height
	# (350) when moldLiquidY's intValue is -999, else -moldLiquidY -- so the
	# carried y is used as is. That includes the -1000 shouldResetMold
	# writes: a mold revisited from the extras screen starts 1000 down.
	_base_y = -WAVE_HEIGHT
	var carried := float(_info.get("moldLiquidY", float(NO_CARRY_Y)))
	if int(carried) != NO_CARRY_Y:
		_base_y = carried

	_liquid_container = Node2D.new()
	_liquid_container.position = DESIGN_MOLD_CENTER
	_liquid_container.rotation = PI
	var mold := outlet("mold")
	if mold is Node2D:
		var parent := (mold as Node2D).get_parent()
		parent.add_child(_liquid_container)
		parent.move_child(_liquid_container, (mold as Node2D).get_index())
	else:
		add_child(_liquid_container)

	_wave = Sprite2D.new()
	_wave.texture = _tex("Water_Wave.png")
	_wave.centered = false
	var sh := Shader.new()
	sh.code = LIQUID_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("tint", Color(_color.r, _color.g, _color.b))
	var mask_file := str(_info.get("moldMaskFileString", ""))
	if Assets.has_image(mask_file):
		mat.set_shader_parameter("mask_tex", Assets.texture(mask_file))
	if _wave.texture != null:
		mat.set_shader_parameter("wave_size", _wave.texture.get_size())
	mat.set_shader_parameter("mask_size", Vector2(MASK_SIZE))
	_wave.material = mat
	_liquid_container.add_child(_wave)
	_set_wave_offset(_base_y)

	var carried_img: Variant = _info.get("moldLiquidImage")
	_old = Sprite2D.new()
	if carried_img is Image:
		_old.texture = ImageTexture.create_from_image(carried_img)
	_old.centered = false
	_old.position = -Vector2(MASK_SIZE) * 0.5
	_liquid_container.add_child(_old)


## Move the wave to baseOrigPt (mask-local top-left plus the offset) and
## keep the shader's mask sampling in step.
func _set_wave_offset(y: float) -> void:
	if _wave == null:
		return
	_wave.position = -Vector2(MASK_SIZE) * 0.5 + Vector2(0, y)
	if _wave.material is ShaderMaterial:
		(_wave.material as ShaderMaterial).set_shader_parameter("offset_y", y)


func _build_stream() -> void:
	_stream = Sprite2D.new()
	_stream.texture = _tex("FP_Water_Drop.png")
	_stream.centered = false
	_stream.material = _lighten(Color(_color, STREAM_ALPHA))
	_stream.visible = false
	var mold := outlet("mold")
	if mold is Node2D:
		var parent := (mold as Node2D).get_parent()
		parent.add_child(_stream)
		parent.move_child(_stream, (mold as Node2D).get_index())
	else:
		add_child(_stream)


func _lighten(tint: Color) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = LIGHTEN_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("tint", tint)
	return mat


## CG image masks paint where the sample is 0: black is the shape. Convert
## to an alpha texture for clip_children. Cached per file.
static func _mask_texture(file: String) -> Texture2D:
	if _mask_cache.has(file):
		return _mask_cache[file]
	if not Assets.has_image(file):
		return null
	var tex: Texture2D = Assets.texture(file)
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var out := Image.create(img.get_width(), img.get_height(), false,
		Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			out.set_pixel(x, y, Color(1, 1, 1, (1.0 - lum) * c.a))
	var result := ImageTexture.create_from_image(out)
	_mask_cache[file] = result
	return result


# -- interaction -------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _finished or _leaving:
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_set_held(event.pressed)


func _set_held(value: bool) -> void:
	if _held == value or _group == null:
		return
	_held = value
	# The accelerometer path never touches instIV; only showNextButton hides
	# it.
	_tween().tween_property(_group, "rotation",
		POUR_ROTATION if value else REST_ROTATION, TIP_SECONDS) \
		.set_trans(Tween.TRANS_SINE)


func _process(delta: float) -> void:
	if _group == null or _finished or _leaving:
		_stop_pour_fx()
		return
	var rot := _group.rotation
	if rot > POUR_MAX or rot < POUR_MIN:
		_stop_pour_fx()
		return
	if not _pouring:
		_pouring = true
		Audio.loop("pouring")
	_stream.visible = true
	_place_stream()
	_accum += delta
	while _accum >= 1.0 / TICK_HZ and not _finished:
		_accum -= 1.0 / TICK_HZ
		_tick()


func _stop_pour_fx() -> void:
	if _pouring:
		_pouring = false
		Audio.stop("pouring")
	if _stream != null:
		_stream.visible = false


## The stream hangs from the spout, converted to view coords each tick, at
## (spoutX - width/2, spoutY - 20).
func _place_stream() -> void:
	if _stream == null or _stream.texture == null or _group == null:
		return
	var local := SPOUT_LOCAL_CENTER - GROUP_SIZE * 0.5
	var spout := _group.position + local.rotated(_group.rotation)
	_stream.position = Vector2(spout.x - _stream.texture.get_size().x * 0.5,
		spout.y - STREAM_Y_LIFT)


## One accelerometer tick of 0xF1A08's pouring branch.
func _tick() -> void:
	# Full-to-the-brim check (baseOrigPt.y - 1 >= 0). Unreachable in normal
	# play -- the 310 line always fires first -- but ported for fidelity.
	if _base_y - 1.0 >= 0.0:
		_finish_fill()
		return
	_tick_count += 1
	if _tick_count % OFFSET_EVERY == 0:
		_base_y += OFFSET_STEP
		_tick_count = 0
		_set_wave_offset(_base_y)
	# The maskStart gate only latches isPouring / would-be emitter state;
	# the emitter itself is dead (see header). Kept for the call shape.
	if _base_y + MASK_SPAN >= _mask_start(_mold_index):
		pass
	# ORIGINAL BUG PORTED: getMaskEnd: computed, discarded; literal 310.
	var _dead_mask_end := _mask_end(_mold_index)
	if _base_y + MASK_SPAN > FILL_STOP:
		_finish_fill()


func _finish_fill() -> void:
	_finished = true
	_stop_pour_fx()
	if not _next_shown:
		_next_shown = true
		_set_next_visible(true)
		show_next_button()
	var add := _add_flavor_button()
	if add != null:
		add.visible = false
	if _group != null:
		_group.visible = false


func _add_flavor_button() -> Node:
	# The addFlavor: action is wired to the unnamed nib button (id 3).
	return get_node_or_null("UIButton")


# -- the round trip and the handoff ------------------------------------

## getScreenshotOfMoldLiquid (0xF070C): render the moldLiquid layer, then
## oldMoldLiquid on top, in UNROTATED layer space. The port composites the
## same two layers into a mask-sized image.
func _screenshot_mold_liquid() -> Image:
	var out := Image.create(MASK_SIZE.x, MASK_SIZE.y, false, Image.FORMAT_RGBA8)
	# Current fill: tinted wave clipped by the mask.
	var mask_tex := _mask_texture(str(_info.get("moldMaskFileString", "")))
	var wave_tex := _tex("Water_Wave.png")
	if mask_tex != null and wave_tex != null:
		var mask_img := mask_tex.get_image()
		var wave_img := wave_tex.get_image()
		if wave_img.is_compressed():
			wave_img.decompress()
		wave_img.convert(Image.FORMAT_RGBA8)
		var y0 := int(_base_y)
		for vy in MASK_SIZE.y:
			var wy := vy - y0
			if wy < 0 or wy >= wave_img.get_height():
				continue
			for vx in MASK_SIZE.x:
				# MaskedIV quirk: mask row flipped (see header).
				var m := mask_img.get_pixel(vx, MASK_SIZE.y - 1 - vy).a
				if m <= 0.0:
					continue
				# Lighten, the same math as the live shader.
				var c := wave_img.get_pixel(vx, wy)
				out.set_pixel(vx, vy, Color(maxf(c.r, _color.r),
					maxf(c.g, _color.g), maxf(c.b, _color.b), c.a * m))
	# Previous rounds render on top, exactly as oldMoldLiquid did.
	var prev: Variant = _info.get("moldLiquidImage")
	if prev is Image:
		out.blend_rect(prev, Rect2i(Vector2i.ZERO, MASK_SIZE), Vector2i.ZERO)
	return out


## addFlavor: (0xF18B4): stop the pour, then 0.5s later hand the liquid
## state back to the flavour screen and pop
## (passInfoToFlavorViewAndPopViewController 0xF17E8). setMoldLiquidInfo:
## (0xEBF80) resets the flavour screen's selectedColor to blue -- an
## original quirk, carried in the info dict.
func _on_addFlavor() -> void:
	if _leaving:
		return
	_leaving = true
	Audio.play("button_press")
	Audio.stop("pouring")
	_stop_pour_fx()
	await get_tree().create_timer(ADD_FLAVOR_DELAY).timeout
	if not is_inside_tree():
		return
	# passInfoToFlavorViewAndPopViewController: the delegate's
	# setMoldLiquidInfo:(screenshot) moldLiquidY:(baseOrigPt.y), then
	# popViewControllerAnimated: -- back to the KEPT flavour screen, whose
	# on_resume applies it (and resets its selectedColor to blue, 0xEBF80).
	GameState.set_meta(ipFlavor.DELEGATE_META, {
		"moldLiquidImage": _screenshot_mold_liquid(),
		"moldLiquidY": _base_y,
	})
	Nav.back()


## nextClick: (0xF10C8): sounds stop, shouldResetMold arms for a future
## revisit, and 0.6s later setInfoDictAndPushViewController (0xF0BBC)
## screenshots the liquid into the dict and pushes the extras screen.
func _on_nextClick(from_skip := false) -> void:
	if _leaving:
		return
	_leaving = true
	Audio.play("button_press")
	Audio.stop("pouring")
	_stop_pour_fx()
	# sender == buySkip: moldLiquid setBaseOrigPt:(0,0) -- the mold is shown
	# brim-full at once, and that is what gets screenshotted 0.6s later.
	if from_skip:
		_base_y = 0.0
		_set_wave_offset(_base_y)
	_info["shouldResetMold"] = "TRUE"
	await get_tree().create_timer(NEXT_PUSH_DELAY).timeout
	if not is_inside_tree():
		return
	_info["moldLiquidImage"] = _screenshot_mold_liquid()
	_info["moldLiquidY"] = _base_y
	# initWithDictionary: -- the extras screen copies the dict.
	GameState.set_meta("ip_info", _info.duplicate())
	Nav.next()


## backClick: (0xF0FE0): pop, and the delegate (the flavour screen) gets
## setMoldLiquidInfo:transparent.png moldLiquidY:-999 -- carried liquid
## dropped and selectedColor reset to blueColor (0xEBF80).
func _on_backClick() -> void:
	Audio.play("button_press")
	Audio.stop("pouring")
	GameState.set_meta(ipFlavor.DELEGATE_META, {
		"moldLiquidImage": null,
		"moldLiquidY": float(NO_CARRY_Y),
	})
	Nav.back()


func _set_next_visible(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.set("disabled", not on)


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


## consumablePurchased: -> nextClick: with the badge as sender.
func _on_skip_purchased(_free: bool) -> void:
	_on_nextClick(true)
