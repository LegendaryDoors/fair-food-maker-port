# Corn Dog step 2 -- drag the dry ingredients into the bowl, then pour milk.
#
# GROUNDED from initWithBatter: (0x880C8), viewDidLoad (0x88284),
# viewWillAppear: (0x885B4), viewDidAppear: (0x88AF0), setIngredients (0x84F10),
# addIngredient:ivCenter: (0x85030), draggableTouchBegan/Moved/Ended
# (0x86D44 / 0x86D48 / 0x871B0), accelerometer:didAccelerate: (0x879C0),
# startAccelerometer (0x88028), milkAndMilkPourAnimationDidFinish (0x858C0),
# saveIngredientsOriginalPosition (0x874C8), backClick: (0x85C1C) and
# nextClick: (0x85CB0).
#
# Mechanic, as read -- NOT what the class name suggests:
#  * Ingredients are DraggableIVs. The drop test is *frame intersects
#    bowl.frame* (0x871B0), not a point-in-rect test.
#  * The milk is ACCELEROMETER-driven (0x879C0): a low-pass filter, the angle
#    clamped to [-130, -15] deg, pouring while the angle sits in [-131, -95]
#    deg, one pour tick per 1/30s update (interval double at 0x88088), done
#    after count > 0x59 (90 ticks = 3s). As everywhere in the port, the
#    tilt becomes press-and-hold at one fixed angle inside the grounded
#    band; the tick
#    count, stream trig, puddle growth and end fade are kept exactly.
#  * There is NO stirring on this screen in v1.27. The spoon/readyToMix path
#    (showSpoon 0x856D8, the fade loop in draggableTouchMoved: 0x86D48) is
#    dead code: readyToMix is only ever written 0 (0x885B4 and the pour-end
#    block of 0x879C0), and showSpoon's only xref is its own method-list entry
#    (0x6EE314). Stirring happens on cdStirViewController. Left out.
#  * The buy-skip consumable flow (initWithBatter: consumable, buyClick:
#    0x85BB0, consumablePurchased: 0x85934, and nextClick:'s
#    sender == buySkip branch that force-fills the bowl) is a 3-coin
#    consumable, not IAP; PORTED, see the skip block below.
#
# nextClick: (0x85CB0) renders bowl.layer plus the milk puddle into one image
# and hands it to cdStirViewController setIngredients:. The port composites
# the same layers into an ImageTexture and carries it -- with the batter id --
# in GameState.custom_categories, the port's stand-in for the initWithBatter:
# argument chain.

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

## Skip consumable (PORTED; the phone shows the badge):
## initWithBatter: 0x880C8 builds Consumable DM_CONSUMABLE_SKIP / Skip_20Ingredients,
## cost = the dead server table GameData.CoinCosts ... SkipIngredients, 3 when
## absent; first-time message below. viewDidLoad 0x88284 builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0x85BB0 ("store" sound,
## purchaseConsumable). consumablePurchased: 0x85934 calls nextClick: with the badge as sender; nextClick: takes its sender == buySkip branch first (drop the bowl's mixed art, addIngredient:ivCenter: every base ingredient and the batter's extra at the bowl centre), then the usual render-and-push.
## consumablePurchaseFailed:error: 0x85ADC (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_20Ingredients"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton
## nextClick:'s force-fill order (0x85CB0 / 0x8A654): oil, egg, salt, flour
## (, pepper), then EXTRA_FOR_BATTER.
const FORCE_FILL_ORDER: Array = ["oil", "egg", "salt", "flour", "pepper"]

const DraggableSprite2D := preload("res://core/DraggableSprite2D.gd")

## Nib frames (from the screen's nib). The nib
## squashes cd_flour.png (254x348) into a 133x53 frame; UIImageView
## scaleToFill is reproduced with a per-axis sprite scale.
const BOWL_RECT := Rect2(38, 198, 244, 244)

## Per-ingredient data. `mixed`/`sound` from addIngredient:ivCenter: (0x85030):
## egg plays egg_crack (0x6BB3E4), everything else drop (0x6BB404). Flour and
## honey land EXACTLY on the bowl centre and are tagged 999 (the branch at
## 0x8553A); the others get a random offset of +/-(0..39) px per axis.
## Flour's fade-in target is flourAlpha = 0.5 (0x885B4); everything else
## ingredientAlpha = 1.0.
const INGREDIENTS := {
	"egg": {"frame": Rect2(129, 9, 62, 76), "art": "cd_ingred_egg.png",
		"mixed": "cd_mixed_egg.png", "sound": "egg_crack",
		"jitter": true, "alpha": 1.0},
	"oil": {"frame": Rect2(6, 137, 133, 53), "art": "cd_ingred_oil.png",
		"mixed": "cd_mixed_oil.png", "sound": "drop",
		"jitter": true, "alpha": 1.0},
	"salt": {"frame": Rect2(194, 85, 133, 53), "art": "cd_ingred_salt.png",
		"mixed": "cd_mixed_salt.png", "sound": "drop",
		"jitter": true, "alpha": 1.0},
	"pepper": {"frame": Rect2(6, 85, 131, 51), "art": "cd_ingred_pepper.png",
		"mixed": "cd_mixed_pepper.png", "sound": "drop",
		"jitter": true, "alpha": 1.0},
	"flour": {"frame": Rect2(184, 137, 133, 53), "art": "cd_flour.png",
		"mixed": "cd_mixed_flour.png", "sound": "drop",
		"jitter": false, "alpha": 0.5},
	"honey": {"frame": Rect2(114, 95, 92, 100), "art": "cd_ingred_honey.png",
		"mixed": "cd_ingred_honey_2.png", "sound": "drop",
		"jitter": false, "alpha": 1.0},
	"chocolate": {"frame": Rect2(104, 83, 113, 112),
		"art": "cd_ingred_chocolate.png", "mixed": "cd_ingred_chocolate_2.png",
		"sound": "drop", "jitter": true, "alpha": 1.0},
	"spicy": {"frame": Rect2(102, 83, 116, 116), "art": "cd_ingred_spicy.png",
		"mixed": "cd_ingred_spicy_2.png", "sound": "drop",
		"jitter": true, "alpha": 1.0},
}
## Nib order of the DraggableIV outlets (ids 3..10): egg, oil, salt, flour,
## pepper, spicy, chocolate, honey. Each sprite is inserted right after its
## outlet node so it layers exactly where the nib put it -- below the batter
## view, puddle, pour stream, jug, spoon, instruction and buttons. (It used to
## be appended last, drawing over the instruction banner and the back/next
## arrows while dragged; DraggableIV never brings itself to the front.)
const BASE_FIVE := ["egg", "oil", "salt", "flour", "pepper"]
## setIngredients (0x84F10): batter 1 unhides honey, 2 chocolate, 3 spicy;
## batter 0 has no extra and pre-sets hasExtra.
const EXTRA_FOR_BATTER := {1: "honey", 2: "chocolate", 3: "spicy"}
## setIngredients also picks the batter art the (dead here, live on cdStir)
## batter view uses, and sets its alpha to 0 (tail of 0x84F10).
const BATTER_TOP := {0: "cd_batter_original_top.png",
	1: "cd_batter_honey_top.png", 2: "cd_batter_choc_top.png",
	3: "cd_batter_spicy_top.png"}

## Random jitter modulus: arc4random() % 0x28 with a random sign per axis.
const JITTER_MOD := 40
## Show_Ingredient fade: duration 0.1 (double 0x856D0), curve 1 = ease-in.
const MIX_FADE := 0.1
## SnapToOriginalPosition: 0.2 (double 0x874C0), curve 3 = linear.
const SNAP_SECONDS := 0.2

# -- the milk pour (0x879C0) ------------------------------------------

## Rest pose set every viewWillAppear: rotation -0.2618 rad (0xBE860A92).
const REST_ROTATION := -0.261799
## Clamps on the filtered tilt angle: [-2.2689280 (0x87D98), -0.2617994
## (0x87D88)] rad = [-130, -15] deg.
const CLAMP_MIN := -2.2689280
const CLAMP_MAX := -0.2617994
## Pouring band: angle <= -1.6580628 (0x87DA0) and >= -2.2863813 (0x87DA8).
const POUR_THRESHOLD := -1.6580628
## PORT CHOICE: hold-to-pour uses one fixed angle inside the
## grounded band; same value the milkshake screen's remap picked.
const POUR_ROTATION := -2.0944
## UIAccelerometer updateInterval 1/30 (double literal 0x88088).
const TICK_HZ := 30.0
## Done when milkPourCount exceeds 0x59: 90 ticks.
const POUR_TICKS := 90
## Stream anchor: milk.center + (cos(a-90deg)*78, sin(a-90deg)*78) +
## (0, -12 + ((deg/130)+1)*3.7142856*10). 78.0 at 0x88000, 130.0 at 0x88018,
## 3.7142856 at 0x8801C, -90/180 at 0x87FF0/0x87FF8.
const STREAM_RADIUS := 78.0
const STREAM_DEG_DIV := 130.0
const STREAM_Y_K := 3.7142856
## milkPour transform: scale 0.5 (viewWillAppear 0x885B4).
const STREAM_SCALE := 0.5
## End fade: 0.1s (double 0x88008), curve 1.
const END_FADE := 0.1

## milk is a plain UIImageView (nib frame (209, 55, 73, 135)), so its centre
## is a true centre: (245.5, 122.5). The wrapper below rotates about it, as
## setTransform: does.
const MILK_CENTER := Vector2(245.5, 122.5)
## milkPuddle: UIImageView (141, 281, 105, 105) -> true centre (193.5, 333.5),
## scaled about it from 0 (viewWillAppear) to milkPourCount/90 (0x88020).
const PUDDLE_CENTER := Vector2(193.5, 333.5)
const PUDDLE_DIV := 90.0
## Puddle draw point in the bake: puddle.frame.origin converted to bowl
## coordinates (convertPoint:fromView: in 0x85CB0) = (141-38, 281-198).
const PUDDLE_IN_BOWL := Vector2(103, 83)

var _batter := 0
var _has: Dictionary = {}
var _needed: Array = []
var _mixed_records: Array = []   # {file, center (bowl-local), alpha}
var _drags: Dictionary = {}

var _milk: Node2D
var _stream: Sprite2D
var _puddle: Node2D
var _milk_shown := false
var _pouring := false
var _done := false
var _count := 0
var _accum := 0.0
## The jug tilt and the end-of-pour fade, killed when viewWillAppear: resets.
var _pour_tween: Tween
var _fade_tween: Tween


func on_enter() -> void:
	# viewDidLoad built the badge before any viewWillAppear content.
	_build_skip()
	_batter = int(GameState.custom_categories.get("batter", 0))
	_needed = BASE_FIVE.duplicate()
	if EXTRA_FOR_BATTER.has(_batter):
		_needed.append(EXTRA_FOR_BATTER[_batter])

	_build_draggables()
	_build_milk()
	_view_will_appear()
	set_process(true)
	UIKit.park_instruction(self)


## viewDidAppear: runs when the push / pop slide is over.
func on_did_appear() -> void:
	_view_did_appear()


## UINavigationController keeps this controller alive under cdStir (Nav.gd's
## opt-in). viewDidLoad does not run again on back; viewWillAppear: and
## viewDidAppear: do -- and here they RESET THE STEP: every has* flag and the
## pour count zeroed, ingredients back at their saved centres and unhidden,
## milk/stream/spoon hidden, next hidden, instruction back to "add to bowl".
## Together with viewDidDisappear: emptying the bowl, a return from cdStir
## starts the mixing over, exactly as on the device.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	_view_will_appear()
	# _view_did_appear() follows from on_did_appear(), after the slide.


## viewWillAppear: (0x885B4), the parts with something to show or count.
## The NSUserDefaults previousGame/previousScreen writes and the app
## delegate's analytics fields are not visible and not ported.
func _view_will_appear() -> void:
	for t: Tween in [_pour_tween, _fade_tween]:
		if t != null and t.is_valid():
			t.kill()
	# milk rotation -0.2618, milkPour scale 0.5, milkPuddle scale (0, 0).
	_milk.rotation = REST_ROTATION
	_milk.modulate.a = 1.0
	if _stream != null:
		_stream.scale = Vector2(STREAM_SCALE, STREAM_SCALE)
		_stream.modulate.a = 1.0
	_puddle.scale = Vector2(0.001, 0.001)
	_puddle.visible = false
	# startAccelerometer: a fresh filter -- the hold remap starts released.
	_pouring = false
	_accum = 0.0
	# hasEgg..hasSalt = 0, doneMilkPouring = 0, milkPourCount = 0.
	for n in _needed:
		_has[n] = false
	_done = false
	_count = 0
	# ingredientAlpha 1.0 on every DraggableIV; milkPuddle alpha 1. Then
	# resetIngredientsToOriginalPosition (0x87768) on every appearance after
	# the first (the first saves them), setHidden:NO on the five base
	# ingredients, and setIngredients (0x84F10) unhides the batter's extra.
	for n in _drags:
		var s: DraggableSprite2D = _drags[n]
		s.modulate.a = 1.0
		s.position = (INGREDIENTS[n]["frame"] as Rect2).position
		s.visible = true
		s.enabled = true
	_puddle.modulate.a = 1.0
	# milk and milkPour hidden (spoon is never shown on this screen).
	_milk.visible = false
	_milk_shown = false
	if _stream != null:
		_stream.visible = false
	# readyToMix = doneMixing = 0; nextButton hidden; the badge unhidden.
	var next := outlet("nextButton")
	if next != null and next != self:
		(next as CanvasItem).visible = false
	if _skip_button != null:
		_skip_button.visible = true


## viewDidAppear: (0x88AF0).
func _view_did_appear() -> void:
	change_instruction("inst_add_to_bowl.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## One DraggableSprite2D per needed ingredient, at its nib frame, art scaled
## to the frame (UIImageView scaleToFill). The generated scene's outlet nodes
## are empty Node2Ds; the sprites are built here beside them.
func _build_draggables() -> void:
	for n in _needed:
		var d: Dictionary = INGREDIENTS[n]
		var frame: Rect2 = d["frame"]
		var tex := _tex(d["art"])
		if tex == null:
			continue
		var s := DraggableSprite2D.new()
		s.texture = tex
		s.centered = false
		s.position = frame.position
		s.scale = frame.size / Vector2(tex.get_size())
		s.name = "drag_" + n
		s.drag_ended.connect(_on_ingredient_released.bind(n))
		_add_at_outlet(s, n)
		_drags[n] = s


## Insert `node` directly after the nib outlet `outlet_name` (same parent), so
## it takes that view's place in the stacking order; appended if absent.
func _add_at_outlet(node: Node, outlet_name: String) -> void:
	var o := outlet(outlet_name)
	if o != null and o != self and o.get_parent() != null:
		o.add_sibling(node)
	else:
		add_child(node)


## The milk jug, stream and puddle. All three scene nodes are rebuilt so the
## jug and puddle can rotate/scale about their UIKit centres. Each takes its
## outlet's place in the stack (puddle 12 < milkPour 13 < milk 14).
func _build_milk() -> void:
	for hide_name in ["milk", "milkPuddle"]:
		var o := outlet(hide_name)
		if o != null and o != self:
			(o as CanvasItem).visible = false

	_milk = Node2D.new()
	_milk.position = MILK_CENTER
	_milk.rotation = REST_ROTATION
	_milk.visible = false
	_add_at_outlet(_milk, "milk")
	var jug := Sprite2D.new()
	jug.texture = _tex("cd_ingred_milk.png")
	_milk.add_child(jug)

	# The stream reuses the scene's ms_Milk sprite: top-left anchored,
	# scale 0.5, hidden until a pour tick shows it (0x879C0).
	var pour := outlet("milkPour")
	if pour is Sprite2D:
		_stream = pour as Sprite2D
		_stream.scale = Vector2(STREAM_SCALE, STREAM_SCALE)
		_stream.visible = false

	_puddle = Node2D.new()
	_puddle.position = PUDDLE_CENTER
	_puddle.scale = Vector2(0.001, 0.001)   # transform scale (0,0) in 0x885B4
	_puddle.visible = false
	_add_at_outlet(_puddle, "milkPuddle")
	var pud := Sprite2D.new()
	pud.texture = _tex("cd_ingred_milk_2.png")
	_puddle.add_child(pud)


# -- ingredients ------------------------------------------------------

## draggableTouchEnded: (0x871B0): frame-intersects-bowl absorbs the
## ingredient; anything else animates back to origCenter over 0.2s linear.
func _on_ingredient_released(_pos: Vector2, _on_target: bool, n: String) -> void:
	var s: DraggableSprite2D = _drags[n]
	var d: Dictionary = INGREDIENTS[n]
	var frame_now := Rect2(s.position, (d["frame"] as Rect2).size)
	if frame_now.intersects(BOWL_RECT):
		# ivCenter = [touch locationInView:bowl]. DraggableIV left its centre
		# at touch + touchOffset, so the touch is position - offset.
		var touch: Vector2 = s.position - (s.get("_touch_offset") as Vector2)
		_absorb(n, s, touch)
	else:
		s.return_to_origin(SNAP_SECONDS)


## addIngredient:ivCenter: (0x85030). The mixed art starts at ivCenter (the
## release touch, in screen space here) and eases in to the bowl centre (+/-
## jitter) over 0.1s while fading to its alpha.
func _absorb(n: String, s: DraggableSprite2D, start: Vector2 = Vector2.INF) -> void:
	var d: Dictionary = INGREDIENTS[n]
	_has[n] = true
	Audio.play(d["sound"])
	s.visible = false
	s.enabled = false

	var bowl := outlet("bowl")
	var tex := _tex(d["mixed"])
	if bowl == null or bowl == self or tex == null:
		return
	var target := BOWL_RECT.size * 0.5
	if d["jitter"]:
		target += Vector2(
			(1 if randi() % 2 == 0 else -1) * float(randi() % JITTER_MOD),
			(1 if randi() % 2 == 0 else -1) * float(randi() % JITTER_MOD))

	var m := Sprite2D.new()
	m.texture = tex
	# addIngredient:ivCenter: -- `start` is the ivCenter argument; the free
	# path passes the release touch, the skip branch the bowl's centre.
	m.position = (s.center() if start == Vector2.INF else start) - BOWL_RECT.position
	m.modulate.a = 0.0
	bowl.add_child(m)

	var tw := create_tween().set_parallel(true)
	tw.tween_property(m, "modulate:a", float(d["alpha"]), MIX_FADE) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(m, "position", target, MIX_FADE) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

	_mixed_records.append({"file": d["mixed"], "center": target,
		"alpha": float(d["alpha"])})

	for k in _needed:
		if not _has[k]:
			return
	# All in: milk appears and the instruction flips (end of 0x871B0).
	_milk.visible = true
	_milk_shown = true
	change_instruction("inst_pour.png")


# -- the pour ---------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or _done or not _milk_shown:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_set_pouring(mb.pressed)


func _set_pouring(value: bool) -> void:
	if _pouring == value:
		return
	_pouring = value
	if _pour_tween != null and _pour_tween.is_valid():
		_pour_tween.kill()
	_pour_tween = create_tween()
	_pour_tween.tween_property(_milk, "rotation",
		POUR_ROTATION if value else REST_ROTATION, 0.35) \
		.set_trans(Tween.TRANS_SINE)
	if value:
		Audio.loop("pouring")   # loopFile 0x6B9534
	else:
		# Falling out of the band (0x879C0 head): sound stops, stream hides.
		Audio.stop("pouring")
		if _stream != null:
			_stream.visible = false


func _process(delta: float) -> void:
	if _stream != null and _stream.visible:
		_stream.position = _stream_origin()
	if not _pouring or _done:
		return
	_accum += delta
	var step := 1.0 / TICK_HZ
	while _accum >= step and not _done:
		_accum -= step
		_pour_tick()


## One accelerometer update's worth of pouring (0x879C0).
func _pour_tick() -> void:
	if _stream != null:
		_stream.visible = true
		_stream.position = _stream_origin()
	_count += 1
	_puddle.visible = true
	var k := float(_count) / PUDDLE_DIV
	_puddle.scale = Vector2(k, k)
	if _count > POUR_TICKS - 1:   # 0x59 < count
		_finish_pour()


## milkPour.frame.origin, from the current jug angle.
func _stream_origin() -> Vector2:
	var deg := rad_to_deg(_milk.rotation)
	var ph := deg_to_rad(deg - 90.0)
	return MILK_CENTER + Vector2(cos(ph) * STREAM_RADIUS,
		sin(ph) * STREAM_RADIUS - 12.0
		+ (deg / STREAM_DEG_DIV + 1.0) * STREAM_Y_K * 10.0)


## Tail of 0x879C0 plus milkAndMilkPourAnimationDidFinish (0x858C0): fade the
## jug and stream out over 0.1s, hide them, restore alpha, show next.
func _finish_pour() -> void:
	_done = true
	Audio.stop("pouring")
	_set_pouring(false)
	var tw := create_tween().set_parallel(true)
	_fade_tween = tw
	tw.tween_property(_milk, "modulate:a", 0.0, END_FADE) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	if _stream != null:
		_stream.visible = true
		tw.tween_property(_stream, "modulate:a", 0.0, END_FADE) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(func() -> void:
		_milk.visible = false
		_milk.modulate.a = 1.0
		if _stream != null:
			_stream.visible = false
			_stream.modulate.a = 1.0)
	show_next_button()


# -- hand-off ---------------------------------------------------------

## nextClick: (0x85CB0): stop the pour sound, button_press, reset the puddle
## transform to identity, render bowl.layer + the puddle into one image and
## push cdStirViewController with it and the batter id.
func _on_nextClick() -> void:
	Audio.stop("pouring")
	Audio.play("button_press")
	# initWithBatter: + setIngredients: -- built from this controller's own
	# state, not by copying the carrier, which may hold a later screen's dict
	# when this step is next-ed again after a back (keeps_state_on_push).
	var info: Dictionary = {"batter": _batter}
	var baked := _bake_bowl()
	if baked != null:
		info["ingredientsImg"] = baked
	GameState.custom_categories = info
	Nav.next()


func _on_skipClick() -> void:   # skipClick: (0x86414) just calls nextClick:.
	_on_nextClick()


## The renderInContext: composite: cd_bowl_top with every mixed ingredient at
## its settled centre and alpha, then the puddle at natural size at (103, 83).
## drawAtPoint: draws milkPuddle's IMAGE, not the view: it lands at full size
## and full opacity whether or not any milk was poured -- so the skip path's
## bowl carries the puddle too.
func _bake_bowl() -> ImageTexture:
	var base_tex := _tex("cd_bowl_top.png")
	if base_tex == null:
		return null
	var img := base_tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)

	for rec: Dictionary in _mixed_records:
		_blend(img, rec["file"],
			(rec["center"] as Vector2), rec["alpha"], true)
	_blend(img, "cd_ingred_milk_2.png", PUDDLE_IN_BOWL, 1.0, false)
	return ImageTexture.create_from_image(img)


func _blend(dst: Image, file: String, at: Vector2, alpha: float,
		centered: bool) -> void:
	var t := _tex(file)
	if t == null:
		return
	var src := t.get_image()
	if src.is_compressed():
		src.decompress()
	src.convert(Image.FORMAT_RGBA8)
	if alpha < 1.0:
		for y in src.get_height():
			for x in src.get_width():
				var c := src.get_pixel(x, y)
				c.a *= alpha
				src.set_pixel(x, y, c)
	var top_left := at - Vector2(src.get_size()) * 0.5 if centered else at
	dst.blend_rect(src, Rect2i(Vector2i.ZERO, src.get_size()),
		Vector2i(top_left.round()))


## backClick: (0x85C1C): stop the pour loop, button_press, pop.
func _on_backClick() -> void:
	Audio.stop("pouring")
	Audio.play("button_press")
	Nav.back()


## viewWillDisappear: (0x88B3C) stops stir_finished / stir_unfinished (the
## dead stir path's sounds -- stopped anyway, harmless); viewDidDisappear:
## (0x88BBC) stops the accelerometer and removes every bowl subview. The pour
## loop itself is stopped by nextClick:/backClick:; stopping it here too
## covers the accelerometer going away mid-pour.
func on_exit() -> void:
	Audio.stop("stir_finished")
	Audio.stop("stir_unfinished")
	Audio.stop("pouring")
	_pouring = false
	var bowl := outlet("bowl")
	if bowl != null and bowl != self:
		for c in bowl.get_children():
			bowl.remove_child(c)
			c.queue_free()
	_mixed_records.clear()


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


## consumablePurchased: -> nextClick: with the badge as sender, which
## takes the force-fill branch before the render-and-push (see header).
func _on_skip_purchased(_free: bool) -> void:
	_force_fill()
	_on_nextClick()


## nextClick:'s sender == buySkip branch: remove every subview of the bowl
## (the mixed art), then addIngredient:ivCenter: at the bowl's centre for
## each base ingredient in the original's order and the batter's extra.
func _force_fill() -> void:
	var bowl := outlet("bowl")
	if bowl != null and bowl != self:
		for c in bowl.get_children():
			bowl.remove_child(c)
			c.queue_free()
	_mixed_records.clear()
	var order: Array = FORCE_FILL_ORDER.duplicate()
	var extra: String = str(EXTRA_FOR_BATTER.get(_batter, ""))
	if extra != "":
		order.append(extra)
	var center := BOWL_RECT.position + BOWL_RECT.size * 0.5
	for n in order:
		if _drags.has(n):
			_absorb(str(n), _drags[n], center)
