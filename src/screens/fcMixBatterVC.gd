# Funnel Cake step 2 -- drag the dry ingredients into the bowl, then pour milk.
#
# GROUNDED from initWithBatter: (0x8C8E0), viewDidLoad (0x8CA9C, IAP only),
# viewWillAppear: (0x8CDCC), setIngredients (0x89938), addIngredient:ivCenter:
# (0x89A58), draggableTouchMoved/Ended (0x8B678 / 0x8BAE0),
# accelerometer:didAccelerate: (0x8C1B8), startAccelerometer (0x8C840),
# milkAndMilkPourAnimationDidFinish (0x8A260), showNextButton (0x8B320) and
# nextClick: (0x8A654). Read from the original binary.
#
# Mechanic, as read (the same shape as cdMixIngredients but its own numbers):
#  * Ingredients are DraggableIVs; the drop test is *frame intersects
#    bowl.frame* (0x8BAE0). The mixed art reuses corn-dog assets (cd_mixed_*,
#    cd_ingred_*_2) -- an original asset-sharing choice, kept.
#  * The milk is ACCELEROMETER-driven (0x8C1B8): low-pass 0.05/0.95, angle =
#    filtered_x * 6 clamped to [-130, -15] deg, pouring while in
#    [-131, -95] deg, one tick per 1/30s update (0x8C840), done at tick 90.
#    As everywhere in the port, the tilt becomes press-and-hold at one fixed
#    angle inside the grounded band; ticks, stream trig, puddle growth and
#    end fade kept. A tick also requires the jug's current angle to be in
#    that band (the original's own test), so nothing pours -- and no stream
#    shows -- while the jug is still tipping on press.
#  * showNextButton fires at the END OF THE POUR (0x8C1B8 tail), not after any
#    stirring: the spoon/readyToMix stir branch in draggableTouchMoved:
#    (0x8B678) is DEAD CODE here -- readyToMix is only ever written 0
#    (viewWillAppear: and the pour-end block) and showSpoon (0x8A078) has no
#    code xref. Stirring happens on fcStirViewController. Left out.
#  * The buy-skip consumable (initWithBatter: 0x8C8E0, buyClick: 0x8A554) is
#    a 3-coin consumable, not IAP; ported, see the skip block.
#
# nextClick: (0x8A654) renders bowl.layer plus the milk puddle into one image
# (the puddle unconditionally) and hands it to fcStirViewController
# setIngredients: along with batterID.
# The port composites the same layers into an ImageTexture and carries both in
# GameState.custom_categories.

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

## Skip consumable (ported; the original shows its badge):
## initWithBatter: 0x8C8E0 builds Consumable DM_CONSUMABLE_SKIP / Skip_20Ingredients,
## cost = the dead server table GameData.CoinCosts ... SkipIngredients, 3 when
## absent; first-time message below. viewDidLoad 0x8CA9C builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0x8A554 ("store" sound,
## purchaseConsumable). consumablePurchased: 0x8A2D4 calls nextClick: with the badge as sender; nextClick: takes its sender == buySkip branch first (drop the bowl's mixed art, addIngredient:ivCenter: every base ingredient and the batter's extra at the bowl centre), then the usual render-and-push.
## consumablePurchaseFailed:error: 0x8A480 (error 2) shows "You do not
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
const FORCE_FILL_ORDER: Array = ["oil", "egg", "salt", "flour"]

const DraggableSprite2D := preload("res://core/DraggableSprite2D.gd")

## Nib frame (fcMixBatterVC nib): bowl (38, 203, 244, 244).
## One row lower than the corn dog's (38, 198) -- same shape, own constants.
const BOWL_RECT := Rect2(38, 203, 244, 244)

## Per-ingredient data. Frames from the nib; art/sound from
## addIngredient:ivCenter: (0x89A58): egg plays egg_crack, everything else
## drop. Flour lands EXACTLY on the bowl centre and is tagged 999 (the
## flour == sender branch); the others get a random offset of +/-(0..39) px
## per axis. Flour's fade target is flourAlpha = 0.5, the rest
## ingredientAlpha = 1.0 (viewWillAppear: 0x8CDCC).
const INGREDIENTS := {
	"egg": {"frame": Rect2(35, 144, 62, 76), "art": "cd_ingred_egg.png",
		"mixed": "cd_mixed_egg.png", "sound": "egg_crack",
		"jitter": true, "alpha": 1.0},
	"oil": {"frame": Rect2(6, 90, 133, 53), "art": "cd_ingred_oil.png",
		"mixed": "cd_mixed_oil.png", "sound": "drop",
		"jitter": true, "alpha": 1.0},
	"salt": {"frame": Rect2(181, 84, 133, 53), "art": "cd_ingred_salt.png",
		"mixed": "cd_mixed_salt.png", "sound": "drop",
		"jitter": true, "alpha": 1.0},
	"flour": {"frame": Rect2(191, 137, 133, 53), "art": "cd_flour.png",
		"mixed": "cd_mixed_flour.png", "sound": "drop",
		"jitter": false, "alpha": 0.5},
	"strawberry": {"frame": Rect2(91, 87, 116, 116),
		"art": "cd_ingred_strawberry.png", "mixed": "cd_ingred_strawberry_2.png",
		"sound": "drop", "jitter": true, "alpha": 1.0},
	"caramel": {"frame": Rect2(103, 99, 92, 100), "art": "cd_ingred_caramel.png",
		"mixed": "cd_ingred_caramel_2.png", "sound": "drop",
		"jitter": true, "alpha": 1.0},
	"chocolate": {"frame": Rect2(93, 87, 113, 112),
		"art": "cd_ingred_chocolate.png", "mixed": "cd_ingred_chocolate_2.png",
		"sound": "drop", "jitter": true, "alpha": 1.0},
}
const BASE_FOUR := ["egg", "oil", "salt", "flour"]
## setIngredients (0x89938): batter 1 unhides strawberry, 2 caramel,
## 3 chocolate; batter 0 has no extra and pre-sets hasExtra.
const EXTRA_FOR_BATTER := {1: "strawberry", 2: "caramel", 3: "chocolate"}
## setIngredients also picks fc_batter_*_top.png for the `batter` view at
## alpha 0. That view only ever gains alpha in the DEAD stir branch, so it
## never becomes visible on this screen; set for fidelity, not effect.
const BATTER_TOP := {0: "fc_batter_original_top.png",
	1: "fc_batter_strawberry_top.png", 2: "fc_batter_caramel_top.png",
	3: "fc_batter_choc_top.png"}

## Random jitter modulus: arc4random() % 0x28 with a random sign per axis
## (0x89A58).
const JITTER_MOD := 40
## Show_Ingredient fade: 0.1 (double (0xA0000000, 0x3FB99999)), curve 1.
const MIX_FADE := 0.1
## SnapToOriginalPosition: 0.2 (double (0xA0000000, 0x3FC99999)), curve 3.
const SNAP_SECONDS := 0.2

# -- the milk pour (0x8C1B8) ------------------------------------------

## Rest pose set every viewWillAppear: rotation -0.2618 rad.
const REST_ROTATION := -0.2618
## Clamps on the filtered tilt angle: [-2.26892803, -0.261799388] rad
## (bits 0xC0113560 / 0xBE860A92 in 0x8C1B8).
const CLAMP_MIN := -2.26892803
const CLAMP_MAX := -0.261799388
## Pouring band: angle <= -1.65806279 and >= -2.28638132.
const POUR_THRESHOLD := -1.65806279
const POUR_BAND_MIN := -2.28638132
## PORT CHOICE: hold-to-pour uses one fixed angle inside the
## grounded band; the same value the corn-dog mix screen's remap picked.
const POUR_ROTATION := -2.0944
## UIAccelerometer updateInterval 1/30 (double (0x20000000, 0x3FA11111),
## startAccelerometer 0x8C840).
const TICK_HZ := 30.0
## Done when milkPourCount reaches 90 (cmp at the tail of 0x8C1B8).
const POUR_TICKS := 90
## Stream anchor: milk.center + (cos(a-90deg)*78, sin(a-90deg)*78) +
## (0, -12 + ((deg/130)+1)*3.7142856*10). 78.0, 130.0, 3.7142856 (bits
## 0x406DB6DB), -12.0 and the 180/pi conversion all in 0x8C1B8.
const STREAM_RADIUS := 78.0
const STREAM_DEG_DIV := 130.0
const STREAM_Y_K := 3.7142856
## milkPour transform: scale 0.5 (viewWillAppear: 0x8CDCC).
const STREAM_SCALE := 0.5
## End fade of milk + stream: 0.1s (double (0xA0000000, 0x3FB99999)), curve 1.
const END_FADE := 0.1

## milk is a plain UIImageView (nib frame (209, 60, 73, 135)), so its centre
## is a true centre: (245.5, 127.5). The wrapper below rotates about it, as
## setTransform: does.
const MILK_CENTER := Vector2(245.5, 127.5)
## milkPuddle: UIImageView (141, 286, 105, 105) -> true centre (193.5, 338.5),
## scaled about it from 0 (viewWillAppear:) to milkPourCount/90 (0x8C1B8).
const PUDDLE_CENTER := Vector2(193.5, 338.5)
const PUDDLE_DIV := 90.0
## Puddle draw point in the bake: puddle.frame.origin converted to bowl
## coordinates (convertPoint:fromView: in 0x8A654) = (141-38, 286-203).
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
var _sound_on := false
## The jug tilt and the end-of-pour fade, killed when viewWillAppear: resets.
var _pour_tween: Tween
var _fade_tween: Tween


func on_enter() -> void:
	# viewDidLoad built the badge before any viewWillAppear content.
	_build_skip()
	_batter = int(GameState.custom_categories.get("batter", 0))
	_needed = BASE_FOUR.duplicate()
	if EXTRA_FOR_BATTER.has(_batter):
		_needed.append(EXTRA_FOR_BATTER[_batter])

	_setup_batter_view()
	_build_draggables()
	_build_milk()
	_view_will_appear()
	set_process(true)
	UIKit.park_instruction(self)


## viewDidAppear: runs when the push / pop slide is over.
func on_did_appear() -> void:
	_view_did_appear()


## UINavigationController keeps this controller alive under fcStir (Nav.gd's
## opt-in). viewDidLoad does not run again on back; viewWillAppear: and
## viewDidAppear: do -- and here they RESET THE STEP: every has* flag and the
## pour count zeroed, ingredients back at their saved centres and unhidden,
## milk/stream/spoon hidden, next hidden, instruction back to "add to bowl".
## With viewDidDisappear: emptying the bowl, a return from fcStir starts the
## mixing over, exactly as on the device.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	_view_will_appear()
	# _view_did_appear() follows from on_did_appear(), after the slide.


## viewWillAppear: (0x8CDCC), the parts with something to show or count.
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
	# resetIngredientsToOriginalPosition (0x8C048) on every
	# appearance after the first, setHidden:NO on the four base ingredients,
	# and setIngredients (0x89938) unhides the batter's extra and zeroes the
	# batter view's alpha.
	for n in _drags:
		var s: DraggableSprite2D = _drags[n]
		s.modulate.a = 1.0
		s.position = (INGREDIENTS[n]["frame"] as Rect2).position
		s.visible = true
		s.enabled = true
	_puddle.modulate.a = 1.0
	var b := outlet("batter")
	if b != null and b != self:
		(b as CanvasItem).modulate.a = 0.0
	# milk and milkPour hidden; the spoon node stays hidden for the whole
	# screen (dead stir branch).
	_milk.visible = false
	_milk_shown = false
	if _stream != null:
		_stream.visible = false
	# readyToMix = doneMixing = 0; isMilkPourSoundPlaying = 0; nextButton
	# hidden; the skip badge unhidden.
	_sound_on = false
	for hide_name in ["spoon", "nextButton"]:
		var o := outlet(hide_name)
		if o != null and o != self:
			(o as CanvasItem).visible = false
	if _skip_button != null:
		_skip_button.visible = true


## viewDidAppear: (0x8D2E4): changeInstruction:@"inst_add_to_bowl.png" --
## the banner slides in from +500 over 0.25s (0x8B484 does not hide next).
func _view_did_appear() -> void:
	change_instruction("inst_add_to_bowl.png")


## Insert `node` directly above the generated outlet `outlet_name` in the
## root's child order, so code-built stand-ins keep the nib's z-order.
func _place_above(node: Node, outlet_name: String) -> void:
	var o := outlet(outlet_name)
	if o != null and o != self and o.get_parent() == node.get_parent():
		node.get_parent().move_child(node, o.get_index() + 1)


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## setIngredients (0x89938) tail: batter.image = fc_batter_*_top, alpha 0.
## Never shown on this screen (see header); set anyway for fidelity.
func _setup_batter_view() -> void:
	var b := outlet("batter")
	if b is Sprite2D:
		var s := b as Sprite2D
		var tex := _tex(BATTER_TOP.get(_batter, BATTER_TOP[0]))
		if tex != null:
			s.centered = false
			s.texture = tex
			# Nib frame (57, 223, 206, 203); the art is 210x206 (scaleToFill).
			s.scale = Vector2(206, 203) / Vector2(tex.get_size())
		s.modulate.a = 0.0


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
		add_child(s)
		# Nib z-order: the ingredients sit below batter, puddle, stream, jug
		# and the chrome (views 3-9 of the nib's 0-19).
		_place_above(s, n)
		_drags[n] = s


## The milk jug, stream and puddle. All three scene nodes are rebuilt so the
## jug and puddle can rotate/scale about their UIKit centres.
func _build_milk() -> void:
	for hide_name in ["milk", "milkPuddle"]:
		var o := outlet(hide_name)
		if o != null and o != self:
			(o as CanvasItem).visible = false

	_milk = Node2D.new()
	_milk.position = MILK_CENTER
	_milk.rotation = REST_ROTATION
	_milk.visible = false
	add_child(_milk)
	_place_above(_milk, "milk")   # nib view 13: above the stream (12)
	var jug := Sprite2D.new()
	jug.texture = _tex("cd_ingred_milk.png")
	_milk.add_child(jug)

	# The stream reuses the scene's ms_Milk sprite: top-left anchored,
	# scale 0.5 (0x8CDCC), hidden until a pour tick shows it (0x8C1B8).
	var pour := outlet("milkPour")
	if pour is Sprite2D:
		_stream = pour as Sprite2D
		_stream.scale = Vector2(STREAM_SCALE, STREAM_SCALE)
		_stream.visible = false

	_puddle = Node2D.new()
	_puddle.position = PUDDLE_CENTER
	_puddle.scale = Vector2(0.001, 0.001)   # transform scale (0,0) in 0x8CDCC
	_puddle.visible = false
	add_child(_puddle)
	# Nib view 11: below the stream (12) that falls into it, above the bowl.
	_place_above(_puddle, "milkPuddle")
	var pud := Sprite2D.new()
	pud.texture = _tex("cd_ingred_milk_2.png")
	_puddle.add_child(pud)


# -- ingredients ------------------------------------------------------

## draggableTouchEnded: (0x8BAE0): frame-intersects-bowl absorbs the
## ingredient; anything else animates back to origCenter over 0.2s linear.
func _on_ingredient_released(_pos: Vector2, _on_target: bool, n: String) -> void:
	var s: DraggableSprite2D = _drags[n]
	var d: Dictionary = INGREDIENTS[n]
	var frame_now := Rect2(s.position, (d["frame"] as Rect2).size)
	if frame_now.intersects(BOWL_RECT):
		_absorb(n, s)
	else:
		s.return_to_origin(SNAP_SECONDS)


## addIngredient:ivCenter: (0x89A58). The original starts the mixed art at the
## touch's locationInView:bowl; the port starts it at the released sprite's
## centre -- a 0.1s transient only, flagged rather than silently equated.
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
	# path passes the released sprite's centre, the skip branch the bowl's.
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
	# All in: milk appears, the filter state zeroes and the instruction flips
	# to inst_pour.png (end of 0x8BAE0).
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
	if not value:
		_out_of_band()


## The not-pouring branch of 0x8C1B8: stop "pouring", clear
## isMilkPourSoundPlaying, hide the stream.
func _out_of_band() -> void:
	Audio.stop("pouring")
	_sound_on = false
	if _stream != null:
		_stream.visible = false


func _process(delta: float) -> void:
	# After the 90th tick doneMilkPouring stops every frame update: the
	# stream fades out where it stood while the jug tips back.
	if _stream != null and _stream.visible and not _done:
		_stream.position = _stream_origin()
	if not _pouring or _done:
		return
	_accum += delta
	var step := 1.0 / TICK_HZ
	while _accum >= step and not _done:
		_accum -= step
		_pour_tick()


## One accelerometer update (0x8C1B8). It pours only while the jug's angle
## is inside the band [-2.28638132, -1.65806279] rad; the stream geometry is
## only defined there. With the hold remap the jug is still tipping for the
## first ~0.25s of a press -- those updates take the not-pouring branch, as
## they would on the device while it was being tilted.
func _pour_tick() -> void:
	var a := _milk.rotation
	if a > POUR_THRESHOLD or a < POUR_BAND_MIN:
		_out_of_band()
		return
	if _stream != null:
		_stream.visible = true
		_stream.position = _stream_origin()
	if not _sound_on:   # isMilkPourSoundPlaying
		Audio.loop("pouring")   # loopFile "pouring"/"m4a" in 0x8C1B8
		_sound_on = true
	_count += 1
	_puddle.visible = true
	var k := float(_count) / PUDDLE_DIV
	_puddle.scale = Vector2(k, k)
	if _count >= POUR_TICKS:
		_finish_pour()


## milkPour.frame.origin, from the current jug angle.
func _stream_origin() -> Vector2:
	var deg := rad_to_deg(_milk.rotation)
	var ph := deg_to_rad(deg - 90.0)
	return MILK_CENTER + Vector2(cos(ph) * STREAM_RADIUS,
		sin(ph) * STREAM_RADIUS - 12.0
		+ (deg / STREAM_DEG_DIV + 1.0) * STREAM_Y_K * 10.0)


## Tail of 0x8C1B8 plus milkAndMilkPourAnimationDidFinish (0x8A260): stop the
## sound, flip the instruction back to inst_mix_ingreds.png, fade the jug and
## stream out over 0.1s curve 1, hide them, restore alpha, and slide the next
## button in -- the pour is this screen's final act.
func _finish_pour() -> void:
	_done = true
	Audio.stop("pouring")
	_set_pouring(false)
	change_instruction("inst_mix_ingreds.png")
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
	show_next_button()   # 0x8B320, the standard +500/0.25 slide


# -- hand-off ---------------------------------------------------------

## nextClick: (0x8A654): stop the pour sound, button_press, reset the puddle
## transform to identity, render bowl.layer + the puddle into one image and
## push fcStirViewController with it and the batter id.
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


func _on_skipClick() -> void:   # skipClick: (0x8AD44) just calls nextClick:.
	_on_nextClick()


## backClick: (0x8A5C0): stop "pouring", button_press, pop. (The base Screen
## back pops silently.)
func _on_backClick() -> void:
	Audio.stop("pouring")
	Audio.play("button_press")
	Nav.back()


## The renderInContext: composite: cd_bowl_top with every mixed ingredient at
## its settled centre and alpha, then the puddle at natural size at (103, 83).
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
	# milkPuddle.image drawAtPoint: is UNCONDITIONAL in 0x8A654 -- the
	# puddle art lands in the bake even when no milk was poured (the skip
	# consumable's force-fill path). drawAtPoint: ignores the view's
	# transform and alpha: natural size, full opacity.
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


## viewWillDisappear: (0x8D330) stops the accelerometer plus stir_finished
## and stir_unfinished (dead-branch sounds the port never starts);
## viewDidDisappear: (0x8D3C4) removes every bowl subview. The pour loop is
## stopped by nextClick:/backClick:; stopping it here too covers the
## accelerometer going away mid-pour.
func on_exit() -> void:
	Audio.stop("stir_finished")
	Audio.stop("stir_unfinished")
	Audio.stop("pouring")
	_pouring = false
	_sound_on = false
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
	_place_above(b, "instIV")   # insertSubview:aboveSubview:instIV (0x8CA9C)
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
