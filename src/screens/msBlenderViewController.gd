# Milkshake step 5 -- blend it.
#
# From the original binary: initFlavors (0x54A7C), startBlender (0x57618),
# updateLogic: (0x57A40), stopBlender (0x57D60) and AverageAllColors (0x562F8).
# initFlavors was read end to end in the disassembly (the function is 6268
# bytes) and updateLogic:/stopBlender at instruction level; the jar
# contents, the swirl and the stop cleanup below all come from that reading.
#
# The port's earlier version had every constant wrong and one invented sound:
#
#   * BLEND_SECONDS was 2.5; stopBlender is scheduled at +5.0.
#   * The blades were animated at a made-up 22Hz. They do not alternate at all
#     -- one swap to ms_Blade_On at start, one to ms_Blade_Off at stop.
#   * The contents were a single sprite at a guessed position and scale. They
#     are three stacked TintedIVs sharing frame (57,47,198,244), crossfading.
#   * The body shake was sin(t*46)*1.6. The original is a 2px "earthquake".
#   * Audio.play("maker_finished") was fabricated -- stopBlender only stops
#     blend_loop. No such cue exists in the blend path.
#
# What is still missing is listed at the bottom of this file.
#
# Kept alive under the push. nextClick:
# removes finishedBlend / tintedMilkFront / tintedMilk; on_resume() re-runs
# viewWillAppear: (0x548E0, which calls initFlavors), on_did_appear()
# viewDidAppear:, after the 0.35 s push / pop slide.

extends "res://core/Screen.gd"

const UIKit := preload("res://screens/msUIKit.gd")

## stopBlender is scheduled at +5.0s, and the crossfade runs the same 5.0.
const BLEND_SECONDS := 5.0
## Everything is driven by an NSTimer at 1/30s feeding updateLogic:, not by
## wall clock. Counting ticks keeps the fill stable under frame hitches.
const TICK_HZ := 30.0

## All three contents layers share this frame inside parentBlenderView.
## ms_Shake_Texture.png is natively 198x244, so there is no scaling.
const CONTENTS_RECT := Rect2(57, 47, 198, 244)
## ms_Milk_Texture_Cloudy sits over the crossfade at a constant alpha
## (0x3E99999A at 0x5620A).
const CLOUDY_ALPHA := 0.3

## BlenderView -- nib id 5, frame (96, 66, 121, 192) inside parentBlenderView.
## initFlavors reads this frame for every random placement and updateLogic:
## reads it once for both wrap bounds; nothing ever resizes it, so the nib
## size is used directly.
const BLENDER_VIEW_SIZE := Vector2(121, 192)

## Six balls of the chosen flavour art (ms_icscoopsNN, the same file
## GameState.ice_cream_texture holds), each a TintedIV(image, nil, blend 1)
## scaled 0.5 (0x3F000000 at 0x54C4C). setCenter((i%3)*40, height - 35*row)
## -- zero-frame TintedIV, so those are art TOP-LEFTs in BlenderView space.
## row runs 1,1,2,2,3,3: it increments when the *next* index is even
## (BIC/ADD at 0x54CF4..0x54CF8).
const BALL_COL_PITCH := 40.0    # literal pool 0x54EF8, used at 0x54C9A
const BALL_ROW_OFFSET := -35.0  # literal pool 0x54EFC, used at 0x54CC6
const BALL_SCALE := 0.5         # 0x54C4C
const BALL_ROWS: Array[int] = [1, 1, 2, 2, 3, 3]

## One TintedIV(image, nil, blend 1) per added ingredient, scaled 0.3
## (0x3E99999A at 0x553CA), top-left at
##   (arc4random() % int(width - 30) - 20, arc4random() % int(height - 140))
## BlenderView-local (-30.0 at 0x54D5A, -20.0 at 0x54D56, -140.0 pool
## 0x54F00; the umod/setCenter sequence is 0x552FC..0x55414).
const ING_SCALE := 0.3
const ING_X_SHRINK := -30.0
const ING_X_OFFSET := -20.0
const ING_Y_SHRINK := -140.0

## Ingredient art by tag, from the 21 case blocks of the switch at 0x5501C
## (strings 0x54E0A..0x552D8). The default case (0x552B0) falls through into
## the strawberry tail at 0x552BC, so tag 7 (Blueberry) -- and any unknown
## tag -- draws *strawberry* art in the jar. That is the original's own
## behaviour, kept as read.
const ING_ART := {
	"0": "ms_Strawberry.png", "1": "ms_Rasberry.png", "2": "ms_Orange.png",
	"3": "ms_Mango.png", "4": "ms_Lychees.png", "5": "ms_Yogurt.png",
	"6": "ms_banana.png",
	"100": "ms_Chocolate.png", "101": "ms_Cinnamon_Imperials.png",
	"102": "ms_Gummi_Bears.png", "103": "ms_M_Ms.png",
	"104": "ms_Peppermints.png", "105": "ms_Spice_Drops.png",
	"106": "ms_Butter_Cups.png", "107": "ms_Chocolate_Kisses.png",
	"108": "ms_Chocolete_Candies.png", "109": "ms_chocCookies.png",
	"200": "ms_Chopped_Peanuts.png", "201": "ms_Roasted_Cashews.png",
	"202": "ms_Pistachios.png", "203": "ms_Walnuts.png",
}
const ING_ART_DEFAULT := "ms_Strawberry.png"  # def case 0x552B0 -> 0x552BC

## Three FX bits per ingredient inside finishedBlend, TintedIV(image, nil,
## blend 1) scaled 0.3 (0x55E62/0x55F90/0x560C2 -- three unrolled copies of
## one loaded image, 0x55D9E..0x56128), top-left at
##   (arc4random() % int(width - 30) + 60, arc4random() % int(height - 30) + 42)
## where width/height are *BlenderView's* (the frame read at 0x55DAE uses the
## BlenderView ivar stored at 0x557E8) even though the bits are added to
## finishedBlend. 60.0/42.0 are the pool at 0x55B18/0x55B1C; both mods
## shrink by -30.0 (0x55782).
##
## Art per tag from the FX switch at 0x55B58 (strings 0x5587A..0x55D7A).
## Two-entry rows are the random variants: random()*2^-31 < 0.5 picks the
## first (the "_2" art) on all three -- BLT 0x55C5A for strawberry, BGE to
## the "_1" block at 0x558C4 (orange) and 0x55914 (mango). Tag 5 (Yogurt) is
## missing from the fruit jump table (0x55B6A has six real targets) and tag 7
## overflows it, so both take the default (0x55D52), which falls into the
## ms_FX_Strawberry_2 load at 0x55D78. Kept as read.
const FX_SCALE := 0.3
const FX_X_OFFSET := 60.0
const FX_Y_OFFSET := 42.0
const FX_RANGE_SHRINK := -30.0
const FX_ART := {
	"0": ["ms_FX_Strawberry_2.png", "ms_FX_Strawberry_1.png"],
	"1": ["ms_FX_Fruit_One.png"],
	"2": ["ms_FX_Orange_2.png", "ms_FX_Orange_1.png"],
	"3": ["ms_FX_Mango_2.png", "ms_FX_Mango_1.png"],
	"4": ["ms_FX_Lychees.png"],
	"6": ["ms_FX_Banana.png"],
	"100": ["ms_FX_Chocolate.png"], "101": ["ms_FX_Cinnamon_Imperials.png"],
	"102": ["ms_FX_Gummi_Bears.png"], "103": ["ms_FX_M_Ms.png"],
	"104": ["ms_FX_Peppermints.png"], "105": ["ms_FX_Spice_Drops.png"],
	"106": ["ms_FX_Butter_Cups.png"], "107": ["ms_FX_Chocolate_Kisses.png"],
	"108": ["ms_FX_Chocolete_Candies.png"], "109": ["ms_FX_Fake_Oreos.png"],
	"200": ["ms_FX_Chopped_Peanuts.png"], "201": ["ms_FX_Roasted_Cashews.png"],
	"202": ["ms_FX_Pistachios.png"], "203": ["ms_FX_Walnuts.png"],
}
const FX_ART_DEFAULT := "ms_FX_Strawberry_2.png"  # def 0x55D52 -> 0x55D78

## The swirl -- updateLogic: (0x57A40), run per 1/30s tick during the blend.
## Speed ladder: 240 px/s for the first subview, -10 per subview, wrapping
## back to 240 once it drops below 20 (0x57BE4..0x57BF6, same in both loops).
const SWIRL_SPEED_MAX := 240.0  # 0x57D58
const SWIRL_SPEED_STEP := -10.0
const SWIRL_SPEED_MIN := 20.0
## BlenderView subviews wrap x to -10 on reaching width - 55 (flt 0x57D5C is
## -55.0; VMOV.F32 D15, #-10.0 at 0x57B2E).
const SWIRL_JAR_WRAP_AT := -55.0
const SWIRL_JAR_WRAP_TO := -10.0
## finishedBlend subviews wrap x to 40 (0x42200000 at 0x57CF2) on reaching
## *BlenderView's* width -- the bound register S18 is loaded once at 0x57A9A
## and never reloaded for the second loop. The original's own quirk, kept.
const SWIRL_FX_WRAP_TO := 40.0

## "Earthquake": translate (2,-2) <-> (-2,2), autoreversed, 0.05s each way,
## repeatCount 50 -- which is exactly the 5s the blend lasts.
const SHAKE_OFFSET := Vector2(2, -2)
const SHAKE_HALF_PERIOD := 0.05
const SHAKE_REPEATS := 50

## Entrance, re-run on every appearance because viewWillAppear calls
## initFlavors: the jar rises from center (160,520) to frame (0,0,320,480) and
## the lid drops from center (160,-500) onto frame (58,17,207,90), over 0.5s.
const ENTER_SECONDS := 0.5
const JAR_ENTER_CENTER := Vector2(160, 520)
const JAR_REST_CENTER := Vector2(160, 240)
const LID_ENTER_CENTER := Vector2(160, -500)
const LID_REST_CENTER := Vector2(161.5, 62)

var _blending := false
## hasBeenStarted: reset by every viewWillAppear:, so a return to this screen
## can blend again. (The port used to gate on GameState.blended, which
## survives a back-navigation and locked the button for good.)
var _started := false
var _fade_tween: Tween
var _enter_tween: Tween
var _next_home := Vector2.ZERO
var _ticks := 0
var _accum := 0.0
var _blender_view: Node2D
var _tinted_milk: Sprite2D
var _finished_blend: Sprite2D
var _cloudy: Sprite2D
var _shake_tween: Tween
var _body_rest := Vector2.ZERO
var _lid_rest := Vector2.ZERO


func on_enter() -> void:
	_next_home = UIKit.next_home(self)
	_blender_view = outlet("BlenderView") as Node2D
	# The nib frames the entrance animates to; read once, before anything
	# moves them (a return visit finds the jar where the shake left it).
	var body := outlet("parentBlenderView")
	if body is Node2D:
		_body_rest = (body as Node2D).position
	var lid := outlet("BlenderLidView")
	if lid is Node2D:
		_lid_rest = (lid as Node2D).position
	_build_contents()
	_build_jar()
	_build_fx()
	_set_next_enabled(false)
	set_process(false)
	UIKit.park_instruction(self)
	_play_entrance()


## viewDidAppear: (0x549E4), after the push / pop slide:
## changeInstruction:@"inst_blend.png" (which hides next) -- every appearance.
func on_did_appear() -> void:
	change_instruction("inst_blend.png")


## viewWillAppear: (0x548E0) ENABLES backButton; the 0.5s enableBackButton it
## schedules is a no-op then. No lockout on this screen.
func lock_back_button() -> void:
	pass


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _total_ticks() -> int:
	return int(BLEND_SECONDS * TICK_HZ)


# -- construction -----------------------------------------------------

## Three layers plus the jar contents, in the z-order initFlavors builds:
## finishedBlend is inserted above BlenderView (0x5561E), tintedMilkFront
## above BlenderView later -- landing *between* the two (0x561FC) -- and
## tintedMilk below BlenderView last (0x562AC). Bottom to top:
##   tintedMilk < BlenderView (balls + bits) < cloudy < finishedBlend,
## all under the nib's TopBlenderView jar art.
func _build_contents() -> void:
	var parent: Node = outlet("parentBlenderView")
	if parent == null or parent == self:
		parent = self

	_tinted_milk = _layer("ms_Milk_Texture.png", GameState.milk_color, 1.0, parent)
	_finished_blend = _layer("ms_Shake_Texture.png", GameState.final_color(),
		0.0, parent)
	_cloudy = _layer("ms_Milk_Texture_Cloudy.png", GameState.milk_color,
		CLOUDY_ALPHA, parent)

	if _blender_view != null and _blender_view.get_parent() == parent:
		if _tinted_milk != null:
			parent.move_child(_tinted_milk, _blender_view.get_index())
		if _cloudy != null:
			parent.move_child(_cloudy, _blender_view.get_index() + 1)
		if _finished_blend != null and _cloudy != null:
			parent.move_child(_finished_blend, _cloudy.get_index() + 1)


## The tint goes on self_modulate so children (the FX bits inside
## finishedBlend) are not recoloured -- a TintedIV tints only its own image --
## while modulate.a carries the crossfade, which, like UIView alpha, applies
## to the whole subtree.
func _layer(file: String, tint: Color, alpha: float, parent: Node) -> Sprite2D:
	var tex := _tex(file)
	if tex == null:
		return null
	var s := Sprite2D.new()
	s.texture = tex
	s.centered = false
	s.position = CONTENTS_RECT.position
	s.self_modulate = Color(tint.r, tint.g, tint.b, 1.0)
	s.modulate = Color(1, 1, 1, alpha)
	parent.add_child(s)
	return s


## Six half-scale balls, then one 0.3-scale bit per added ingredient, all
## into BlenderView in that order -- updateLogic:'s speed ladder walks the
## subviews in add order, so the order matters.
func _build_jar() -> void:
	if _blender_view == null:
		return
	var ball_tex := _tex(GameState.ice_cream_texture)
	if ball_tex != null:
		for i in 6:
			var b := Sprite2D.new()
			b.texture = ball_tex
			b.centered = false
			b.scale = Vector2(BALL_SCALE, BALL_SCALE)
			b.position = Vector2(
				float(i % 3) * BALL_COL_PITCH,
				BLENDER_VIEW_SIZE.y + BALL_ROW_OFFSET * float(BALL_ROWS[i]))
			_blender_view.add_child(b)
	for tag in GameState.fruits:
		var tex := _tex(ING_ART.get(tag, ING_ART_DEFAULT))
		if tex == null:
			continue
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		s.scale = Vector2(ING_SCALE, ING_SCALE)
		s.position = Vector2(
			float(randi() % int(BLENDER_VIEW_SIZE.x + ING_X_SHRINK)) + ING_X_OFFSET,
			float(randi() % int(BLENDER_VIEW_SIZE.y + ING_Y_SHRINK)))
		_blender_view.add_child(s)


## Three copies of one art choice per ingredient, into finishedBlend. The
## original also NSLogs "currentFruit2 = %d" per item (0x55B4C); dropped.
func _build_fx() -> void:
	if _finished_blend == null:
		return
	for tag in GameState.fruits:
		var variants: Array = FX_ART.get(tag, [FX_ART_DEFAULT])
		var file: String = variants[0]
		if variants.size() == 2 and randf() >= 0.5:
			file = variants[1]
		var tex := _tex(file)
		if tex == null:
			continue
		for i in 3:
			var s := Sprite2D.new()
			s.texture = tex
			s.centered = false
			s.scale = Vector2(FX_SCALE, FX_SCALE)
			s.position = Vector2(
				float(randi() % int(BLENDER_VIEW_SIZE.x + FX_RANGE_SHRINK))
					+ FX_X_OFFSET,
				float(randi() % int(BLENDER_VIEW_SIZE.y + FX_RANGE_SHRINK))
					+ FX_Y_OFFSET)
			_finished_blend.add_child(s)


func _play_entrance() -> void:
	var body := outlet("parentBlenderView")
	if body is Node2D:
		var n := body as Node2D
		# INFERRED (UIKit, not this binary): on a return visit the jar still
		# carries the shake's model transform translate(-2,2); setCenter: and
		# setFrame: are taken to place the VISIBLE frame, so the jar starts
		# from (160,520) and lands on its nib frame with the 2px offset gone.
		n.position = _body_rest + (JAR_ENTER_CENTER - JAR_REST_CENTER)
		# kept so a blend started mid-entrance can take over (see _start_shake)
		# beginAnimations block with no setAnimationCurve: -> ease-in-out.
		# (The port used to ease out.)
		_enter_tween = create_tween()
		_enter_tween.tween_property(n, "position", _body_rest, ENTER_SECONDS) \
			.set_trans(UIKit.TRANS).set_ease(UIKit.EASE)

	var lid := outlet("BlenderLidView")
	if lid is Node2D:
		var l := lid as Node2D
		l.position = _lid_rest + (LID_ENTER_CENTER - LID_REST_CENTER)
		create_tween().tween_property(l, "position", _lid_rest, ENTER_SECONDS) \
			.set_trans(UIKit.TRANS).set_ease(UIKit.EASE)


# -- the one action on this screen ------------------------------------

## blenderClick: (0x575C4): once per appearance -- hide instIV, startBlender.
func _on_blenderClick() -> void:
	if _started:
		return
	_started = true
	_blending = true
	_ticks = 0
	_accum = 0.0
	set_process(true)
	dismiss_instruction()
	Audio.play("big_red_button")
	Audio.loop("blend_loop")

	_set_blades("ms_Blade_On.png")
	_set_power_lamp("ms_Power_Button_On.png")
	# "Hide_Flavors": a 5.0s UIView animation, default ease-in-out curve, of
	# tintedMilk alpha -> 0 and finishedBlend alpha -> 1. (The port used a
	# linear ramp driven off the tick count.)
	_fade_tween = create_tween().set_parallel(true)
	if _tinted_milk != null:
		_fade_tween.tween_property(_tinted_milk, "modulate:a", 0.0, BLEND_SECONDS) \
			.set_trans(UIKit.TRANS).set_ease(UIKit.EASE)
	if _finished_blend != null:
		_fade_tween.tween_property(_finished_blend, "modulate:a", 1.0, BLEND_SECONDS) \
			.set_trans(UIKit.TRANS).set_ease(UIKit.EASE)
	_start_shake()


## One swap, held for the whole blend. There is no frame alternation.
func _set_blades(file: String) -> void:
	var blades := outlet("BlenderBladesView")
	if blades is Sprite2D:
		(blades as Sprite2D).texture = _tex(file)


func _set_power_lamp(file: String) -> void:
	var btn := outlet("onButton")
	if btn == null or btn == self:
		return
	var tex: Texture2D = _tex(file) if file != "" else null
	if btn is Sprite2D:
		(btn as Sprite2D).texture = tex
	elif btn.has_method("set_texture_normal"):
		btn.set("texture_normal", tex)


## startBlender (0x57618): setTransform: translate(2,-2) at once, then an
## "earthquake" block -- autoreverses, repeatCount 50, 0.05s (double
## 0x3FA999999999999A), default curve -- to translate(-2,2). 50 there-and-back
## cycles = 5.0s. When an autoreversing UIView animation ends the layer shows
## its MODEL value, translate(-2,2), and nothing resets it (stopBlender leaves
## the transform alone), so the jar ends 2px left and 2px down.
func _start_shake() -> void:
	var body := outlet("parentBlenderView")
	if not (body is Node2D):
		return
	var n := body as Node2D
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	# PORT CHOICE: the original animates frame (entrance) and transform
	# (shake) independently, so a click inside the 0.5s entrance shakes a
	# still-rising jar. The port drives both through `position`; the entrance
	# is cut short to its end point instead.
	if _enter_tween != null and _enter_tween.is_valid():
		_enter_tween.kill()
	n.position = _body_rest + SHAKE_OFFSET
	_shake_tween = create_tween()
	for i in SHAKE_REPEATS:
		_shake_tween.tween_property(n, "position", _body_rest - SHAKE_OFFSET,
			SHAKE_HALF_PERIOD).set_trans(UIKit.TRANS).set_ease(UIKit.EASE)
		_shake_tween.tween_property(n, "position", _body_rest + SHAKE_OFFSET,
			SHAKE_HALF_PERIOD).set_trans(UIKit.TRANS).set_ease(UIKit.EASE)
	_shake_tween.tween_callback(func() -> void:
		n.position = _body_rest - SHAKE_OFFSET)


func _process(delta: float) -> void:
	if not _blending:
		return
	_accum += delta
	var step := 1.0 / TICK_HZ
	while _accum >= step:
		_accum -= step
		_ticks += 1
		_swirl_tick(step)

	# stopBlender is performSelector'd at +5.0s; 150 ticks of 1/30s.
	if _ticks >= _total_ticks():
		_finish()


## One tick of updateLogic: (0x57A40).
##
## Loop 1 -- every BlenderView subview: x += speed*dt; on reaching
## width - 55 it wraps to -10 (strict <, 0x57B9A); then
## alpha = min(1, x/20, width - x/20). The third term really divides by 20
## too: the VDIV at 0x57BB2 runs before the VSUB at 0x57BB6. It never bites
## (width - x/20 >= 117 for the reachable x range) but is kept as read.
## UIKit renders the negative alphas of freshly wrapped views as invisible;
## Godot needs the explicit clamp for the same look.
##
## Loop 2 -- every finishedBlend subview at the same speed ladder, but a
## subview whose speed is >= 240 is not moved at all (VCMPE/BPL 0x57C9C).
## That always skips subviews[0], the TintedIV's own image -- which in this
## port is the _finished_blend sprite itself, so the ladder starts at a
## phantom index -- and again at every wrap of the ladder (indices 23, 46...).
## x wraps to 40 on reaching BlenderView's width. No alpha change here.
func _swirl_tick(dt: float) -> void:
	var w := BLENDER_VIEW_SIZE.x
	var speed := SWIRL_SPEED_MAX
	if _blender_view != null:
		for c in _blender_view.get_children():
			if c is Node2D:
				var n := c as Node2D
				var x := n.position.x + speed * dt
				if x >= w + SWIRL_JAR_WRAP_AT:
					x = SWIRL_JAR_WRAP_TO
				n.position.x = x
				n.modulate.a = clampf(
					minf(1.0, minf(x / 20.0, w - x / 20.0)), 0.0, 1.0)
			speed += SWIRL_SPEED_STEP
			if speed < SWIRL_SPEED_MIN:
				speed = SWIRL_SPEED_MAX
	if _finished_blend != null:
		speed = SWIRL_SPEED_MAX
		var fx := _finished_blend.get_children()
		for j in fx.size() + 1:
			if speed < SWIRL_SPEED_MAX and j > 0 and fx[j - 1] is Node2D:
				var n2 := fx[j - 1] as Node2D
				var x2 := n2.position.x + speed * dt
				if x2 >= w:
					x2 = SWIRL_FX_WRAP_TO
				n2.position.x = x2
			speed += SWIRL_SPEED_STEP
			if speed < SWIRL_SPEED_MIN:
				speed = SWIRL_SPEED_MAX


## The blend ran its 5.0s: stopBlender, and set the port-side blended flag.
func _finish() -> void:
	GameState.blended = true
	_stop_blender()


## stopBlender (0x57D60).
func _stop_blender() -> void:
	_blending = false
	set_process(false)
	Audio.stop("blend_loop")

	# The earthquake's last cycle ends on the same frame; land on its model
	# value (see _start_shake) rather than trusting tween timing.
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	var body := outlet("parentBlenderView")
	if body is Node2D:
		(body as Node2D).position = _body_rest - SHAKE_OFFSET
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()

	_set_blades("ms_Blade_Off.png")
	_set_power_lamp("")

	# stopBlender (0x57D60) removes every BlenderView subview -- balls and
	# ingredient bits -- while the FX bits inside finishedBlend stay, frozen
	# wherever the swirl left them.
	if _blender_view != null:
		for c in _blender_view.get_children():
			c.queue_free()

	# stopBlender forces the crossfade to its end state rather than trusting
	# the last tick to have landed exactly on 1.0.
	if _tinted_milk != null:
		_tinted_milk.modulate.a = 0.0
	if _finished_blend != null:
		_finished_blend.modulate.a = 1.0

	print("[ms] finished: ", GameState.describe(),
		"  final=", GameState.final_color().to_html(false))
	UIKit.show_next_from_home(self, _next_home)


func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.disabled = not on


## viewWillDisappear: (0x54A30) only calls super. Next is only offered once
## stopBlender has run, and back stops a running blend, so nothing is looping
## here by then; kept as a guard.
func on_exit() -> void:
	Audio.stop("blend_loop")


## UINavigationController keeps this controller alive under StickSelect
## (nextClick: pushes), so back shows the same instance (Nav.gd opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from StickSelect. viewWillAppear: (0x548E0): hasBeenStarted = NO (the
## button blends again), backButton enabled, initFlavors (0x54A7C) -- which
## has no first-visit branch, so it re-adds everything: six balls and the
## ingredient bits into BlenderView (emptied by stopBlender), a new
## finishedBlend (alpha 0) with its FX bits, tintedMilkFront (0.3) and
## tintedMilk, and the 0.5s entrance of jar and lid. viewDidAppear:
## (0x549E4): changeInstruction:@"inst_blend.png" (hides next). The blades
## keep ms_Blade_Off and the power lamp stays blank -- stopBlender's state.
func on_resume() -> void:
	UIKit.drop_coin_view(self)
	_started = false
	_blending = false
	# Port-side flag: the jar is un-blended again.
	GameState.blended = false
	var back := first_outlet(BACK_OUTLETS)
	if back != null:
		back.set("disabled", false)
	_build_contents()
	_build_jar()
	_build_fx()
	_play_entrance()
	# viewDidAppear:'s changeInstruction: runs in on_did_appear().


## backClick: (0x56520): button_press; a running blend is stopped
## (cancelPreviousPerformRequests + stopBlender); pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	if _blending:
		_stop_blender()
	Nav.back()


# -- the bake-out (nextClick: 0x56608, skipClick: 0x57294) -------------
#
# From the original binary. On next the original tears the live contents views
# down, composites the finished shake into one image, and hands StickSelect
# an info dict. The context is sized to ms_Ice_Cream_For_Glass.png (204x318
# native); after the standard scale(1,-1)/translate(0,-h) un-flip, draw
# coordinates are measured from the image's BOTTOM-left:
#
#   * clip to the art's alpha, fill with finalColor       (silhouette)
#   * blend mode 1 (multiply), draw the art over the fill
#   * alpha 0.3 (0x3E99999A), still multiply: per added ingredient, one FX
#     image drawn three times at 20x20 (0x41A00000), each at
#     x = arc4random()%80 + 50, y = arc4random()%165 + 110 (bottom-left).
#
# The bake's FX switch is NOT the jar's: candy 106..109 have no case here
# and fall to the default (ms_FX_Strawberry_2), where the jar switch gave
# them their own art. Tags 5 and 7 default here too. Kept as read.

## Bake FX art by tag, from the switch in 0x56608 (case bodies 0x568F6..
## 0x56AB8). Two-entry rows: random()*2^-31 < 0.5 (0x30000000/0x3F000000)
## picks the first ("_2") variant.
const BAKE_FX_ART := {
	"0": ["ms_FX_Strawberry_2.png", "ms_FX_Strawberry_1.png"],
	"1": ["ms_FX_Fruit_One.png"],
	"2": ["ms_FX_Orange_2.png", "ms_FX_Orange_1.png"],
	"3": ["ms_FX_Mango_2.png", "ms_FX_Mango_1.png"],
	"4": ["ms_FX_Lychees.png"],
	"6": ["ms_FX_Banana.png"],
	"100": ["ms_FX_Chocolate.png"], "101": ["ms_FX_Cinnamon_Imperials.png"],
	"102": ["ms_FX_Gummi_Bears.png"], "103": ["ms_FX_M_Ms.png"],
	"104": ["ms_FX_Peppermints.png"], "105": ["ms_FX_Spice_Drops.png"],
	"200": ["ms_FX_Chopped_Peanuts.png"], "201": ["ms_FX_Roasted_Cashews.png"],
	"202": ["ms_FX_Pistachios.png"], "203": ["ms_FX_Walnuts.png"],
}
const BAKE_FX_DEFAULT := "ms_FX_Strawberry_2.png"  # def -> 0x56AB8 tail

const BAKE_STAMP_SIZE := 20        # 0x41A00000
const BAKE_STAMP_ALPHA := 0.3      # 0x3E99999A
const BAKE_STAMPS_PER_FRUIT := 3   # three unrolled DrawImage calls
const BAKE_X_MOD := 80             # arc4random() % 0x50
const BAKE_X_OFF := 50             # + 0x32
const BAKE_Y_MOD := 165            # arc4random() % 0xA5
const BAKE_Y_OFF := 110            # + 0x6E, from the image BOTTOM

## Both hand-off entries share ItemCenter (58, 180) on next (0x42680000 /
## 0x43340000) and (58, 140) on skip (0x430C0000). They are data for
## MakeViewController (not yet ported); which view class anchors them is
## that screen's question, not settled here.
const HANDOFF_CENTER_NEXT := Vector2(58, 180)
const HANDOFF_CENTER_SKIP := Vector2(58, 140)


func _on_nextClick() -> void:
	Audio.play("button_press")     # 0x56608 head
	# Before compositing: finishedBlend's subviews, then finishedBlend,
	# tintedMilkFront and tintedMilk removeFromSuperview. The controller
	# stays alive under the push; the next appearance's initFlavors makes new
	# ones. (The bake below reads GameState, not these views.)
	for layer in [_finished_blend, _cloudy, _tinted_milk]:
		if layer != null and is_instance_valid(layer):
			layer.queue_free()
	_finished_blend = null
	_cloudy = null
	_tinted_milk = null
	var glass_tex := _tex("ms_Ice_Cream_Glass.png")
	GameState.custom_categories = {
		"MilkShake": {
			"Properties": {
				"IsEdible": true, "ViewIndex": 4, "Type": "Stationary",
				"ItemCenterX": HANDOFF_CENTER_NEXT.x,
				"ItemCenterY": HANDOFF_CENTER_NEXT.y,
			},
			"Image": _bake_shake_texture(),
		},
		"MilkShakeGlass": {
			"Properties": {
				"IsEdible": false, "ViewIndex": 5, "Type": "Stationary",
				"ItemCenterX": HANDOFF_CENTER_NEXT.x,
				"ItemCenterY": HANDOFF_CENTER_NEXT.y,
			},
			"Image": glass_tex,
		},
	}
	Nav.next()


## skipClick: (0x57294): the same pair, untinted and unstamped, with
## ViewIndex 5/9 and centre (58, 140). No button sound in the original.
## UNREACHABLE IN THE ORIGINAL TOO: the shipped
## msBlenderViewController nib has no skipButton outlet and no skipClick:
## action, and no code in the binary sends skipClick: to this class (the only
## code caller of any skipClick: is dicMixIngredientsViewController's own).
## Kept as read.
func _on_skipClick() -> void:
	GameState.custom_categories = {
		"MilkShake": {
			"Properties": {
				"IsEdible": true, "ViewIndex": 5, "Type": "Stationary",
				"ItemCenterX": HANDOFF_CENTER_SKIP.x,
				"ItemCenterY": HANDOFF_CENTER_SKIP.y,
			},
			"Image": _tex("ms_Ice_Cream_For_Glass.png"),
		},
		"MilkShakeGlass": {
			"Properties": {
				"IsEdible": false, "ViewIndex": 9, "Type": "Stationary",
				"ItemCenterX": HANDOFF_CENTER_SKIP.x,
				"ItemCenterY": HANDOFF_CENTER_SKIP.y,
			},
			"Image": _tex("ms_Ice_Cream_Glass.png"),
		},
	}
	Nav.next()


## The composite. Silhouette fill + multiply art collapse to a per-pixel
## product with finalColor (alpha kept from the art); the stamps then
## multiply in at 0.3. Divergence, flagged: CG's multiply paints a stamp at
## full strength where the destination is fully transparent (Da = 0); the
## stamp field (x 50..149, y-from-top 24..208 on the 204x318 art) lies on
## the glass body, so the port multiplies against the destination only and
## leaves true holes unstamped.
func _bake_shake_texture() -> ImageTexture:
	var art := _tex("ms_Ice_Cream_For_Glass.png")
	if art == null:
		return null
	var img := art.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()

	var fc := GameState.final_color()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y,
				Color(c.r * fc.r, c.g * fc.g, c.b * fc.b, c.a))

	for tag in GameState.fruits:
		var variants: Array = BAKE_FX_ART.get(tag, [BAKE_FX_DEFAULT])
		var file: String = variants[0]
		if variants.size() == 2 and randf() >= 0.5:
			file = variants[1]
		var fx_tex := _tex(file)
		if fx_tex == null:
			continue
		var stamp := fx_tex.get_image()
		if stamp.is_compressed():
			stamp.decompress()
		stamp.convert(Image.FORMAT_RGBA8)
		stamp.resize(BAKE_STAMP_SIZE, BAKE_STAMP_SIZE,
			Image.INTERPOLATE_BILINEAR)
		for i in BAKE_STAMPS_PER_FRUIT:
			var sx := BAKE_X_OFF + randi() % BAKE_X_MOD
			var y_bottom := BAKE_Y_OFF + randi() % BAKE_Y_MOD
			var sy := h - BAKE_STAMP_SIZE - y_bottom
			_stamp_multiply(img, stamp, sx, sy)

	return ImageTexture.create_from_image(img)


func _stamp_multiply(dest: Image, stamp: Image, ox: int, oy: int) -> void:
	for y in stamp.get_height():
		for x in stamp.get_width():
			var dx := ox + x
			var dy := oy + y
			if dx < 0 or dy < 0 or dx >= dest.get_width() \
					or dy >= dest.get_height():
				continue
			var s := stamp.get_pixel(x, y)
			var d := dest.get_pixel(dx, dy)
			var k := BAKE_STAMP_ALPHA * s.a
			dest.set_pixel(dx, dy, Color(
				d.r * (1.0 - k) + d.r * s.r * k,
				d.g * (1.0 - k) + d.g * s.g * k,
				d.b * (1.0 - k) + d.b * s.b * k,
				d.a))


# NOT PORTED, deliberately, rather than guessed:
#
#  * Vibration. The original calls AudioServicesPlaySystemSound(0xFFF) at
#    0,1,2,3,4s of the blend. Desktop has no equivalent, so it is listed
#    here rather than silently omitted.
#  * The shake detector (0x582F0: 10 jolts >= 0.02 at 1/30s -> showNextButton)
#    has no static caller in the class and looks
#    dormant/cut; not ported until a caller is read.
#  * NSLog("currentFruit2 = %d") per ingredient in the FX loop (0x55B4C) --
#    debug logging, dropped.
#  * The skip hand-off is implemented (_on_skipClick) but unreachable, as it
#    is in the shipped build (no nib button, no code caller).
#  * The AdColony video ad viewDidLoad plays when neither FF_KEY_EVERYTHING
#    nor FF_KEY_MILKSHAKE is set -- everything is unlocked in the port.


## This screen's changeInstruction: hides nextButton (read from the binary);
## Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
