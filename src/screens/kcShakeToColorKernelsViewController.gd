# Kettle Corn step 4 -- shake the pot to pop the corn and colour it, then
# hand the finished kettle corn to MakeViewController.
#
# GROUNDED from initWithColor: (0x110F70), viewDidLoad (0x111050),
# viewWillAppear: (0x111778), viewDidAppear: (0x111EF0), viewWillDisappear:
# (0x11204C), shake (0x112258), animationDidStop:finished:context:
# (0x1129C8), popcornTick (0x113A44), bubbleTick (0x113678), shakeClick:
# (0x11488C), nextClick: (0x114478) and backClick: (0x114408). Three
# coordinates, the z-order, the sounds and the pot mask's flip were checked
# against the disassembly.
#
# THE MECHANIC IS THE BUTTON, NOT THE ACCELEROMETER, exactly as on the
# flatten screen: accelerometer:didAccelerate: (0x1141B0) exists but no
# method of this class references the startAccelerometer selref (checked in
# the original binary), so the delegate is never set and the handler is dead
# code. The shipped path is shakeClick: on the visible btn_IAP_Shake button.
#
# Each shake crossfades the raw kernels+oil+sugar tableau into the popped,
# tinted corn: with u = shakes/16 set INSTANTLY at shake start,
#   popcorn.alpha = 1-u   colorPopcorn.alpha = u   oil.alpha = 0.5(1-u)
#   kernels.alpha = 1-u   sugarPile.alpha = 1-u
#   both piles' baseOrigPt.y = 141(1-u)            (the pile grows)
# then three chained linear centre animations run: home -> x=80 (0.05s) ->
# x=240 (0.1s) -> home (0.05s); the sugar pile's TOP-LEFT (TintedIV) runs
# 105 -> 35 -> 195 -> 105 instead. `shakes` starts at 1 and shake() runs
# while shakes <= 15, so fifteen shakes finish the corn (shakes hits 16 and
# ShakeMid's completion shows next / hides the shake button).
#
# View classes behind every coordinate, per the TintedIV rule:
#   fryer/lid/oil/kernels  UIImageView        -> true centres (160/160/158/153)
#   popcorn, colorPopcorn  MaskedIV           -> true centre (156, 292),
#                          mask-sized 317x166, baseOrigPt (25, 121), mask
#                          applied upside down (kcPourOil.MaskedIV)
#   popcornView            UIView (66,223,183,121) -> true centre; NOT
#                          snapped on appear (stays 157.5), snapped to 156 by
#                          every shake
#   sugarPile              TintedIV, ZERO-FRAME -> setCenter: places the
#                          118x37 art's TOP-LEFT at (105, 312)
#
# viewWillAppear hides instIV; changeInstruction: (0x114A00) is never called
# on the shipped path. startBurner (0x112250) is `bx lr`. The AdColony ad in
# viewDidLoad only plays when the game is NOT unlocked; the port ships
# unlocked, so it is unreachable and not ported.
#
# nextClick: (0x114478) builds the customCategories dict for
# MakeViewController (classStr "KETTLE_CORN"): kcBucket + kcPopcorn, ported
# into GameState.custom_categories below.

extends "res://core/Screen.gd"

const kcPourOil := preload("res://screens/kcPourOilViewController.gd")
const kcSelectSugar := preload("res://screens/kcSelectSugarViewController.gd")
const kcKit := preload("res://screens/kcKit.gd")

# -- construction (viewDidLoad 0x111050) --------------------------------

## popcorn / colorPopcorn: MaskedIV(kc_popcorn_pile / its HardLight-9 bake,
## kc_mask), centre (156, 292) (MOVT #0x431C / #0x4392 at 0x1111A8; was 291
## here), baseOrigPt (25, 121) (0x41C80000 / 0x42F20000); colorPopcorn
## starts at alpha 0.
const PILE_CENTER := Vector2(156, 292)
const PILE_ORIG := Vector2(25, 121)
## oil setAlpha: 0.5 (0x3F000000) in viewWillAppear: -- the nib's own alpha.
const OIL_ALPHA := 0.5
## sugarPile: TintedIV(kc_sugar_pile, colour, blend 7=ColorBurn), setCenter
## (105, 312) (MOVT #0x42D2 / #0x439C at 0x11142C; was 317 here) -- the
## art's TOP-LEFT.
const SUGAR_TOP_LEFT := Vector2(105, 312)

# -- viewWillAppear: (0x111778): the per-element centre snap --------------

const HOME_X := {"fryer": 160.0, "lid": 160.0, "oil": 158.0, "popcorn": 156.0,
	"colorPopcorn": 156.0, "popcornView": 156.0, "kernels": 153.0,
	"sugarPile": 105.0}   # 0x43200000/0x431E0000/0x431C0000/0x43190000/0x42D20000
## popcornView's nib frame is (66, 223, 183, 121); as a UIView its centre is
## real, so half-width 91.5 converts snapped centres to Node2D positions.
const POPCORN_VIEW_SIZE := Vector2(183, 121)

# -- shake (0x112258) / animationDidStop (0x1129C8) ----------------------

const SHAKE_LEFT_X := 80.0            # 0x42A00000, every element but sugar
const SHAKE_RIGHT_X := 240.0          # 0x43700000
const SUGAR_LEFT_X := 35.0            # MOVT #0x420C at 0x1128F8 / 0x112C98
const SUGAR_RIGHT_X := 195.0          # 0x43430000
const LEFT_SECONDS := 0.05            # 0x3FA99999A0000000
const RIGHT_SECONDS := 0.1            # 0x3FB99999A0000000
const MID_SECONDS := 0.05
const SHAKE_STEP := 0.0625            # 0x3D800000 = 1/16
const PILE_ORIG_Y_FULL := 141.0       # 0x430D0000: baseOrigPt.y = 141*(1-u)
const SHAKES_DONE := 16               # "if (shakes >= 16)" in 0x1129C8
## Lid drop-in (viewDidAppear 0x111EF0): park centre (160, -height), 0.5s
## ease-in to the nib centre; MoveLid's completion plays lid_05.
const LID_SECONDS := 0.5
## popcorn_01: viewWillAppear loopFile:@"popcorn_01" ofType:@"mp3"
## withLoopCount:-1 (MOV.W R1,#0xFFFFFFFF stored as the 4th arg at 0x111C5E).
## shake resumes that same player through playerDict ("play"), ShakeMid
## pauses it -- so it pops continuously from entry until the first shake
## ends, then only during shakes, picking up where it paused.

# -- popcornTick (0x113A44), every 0.1s (0x3FB99999A0000000) -------------

## Pops only while shakes <= 6, at most 7 kernels in flight, 50% per tick.
## All coordinates are popcornView-local. Start (rand%w, h - art.h); hop
## dx = max(20, rand%(w/2)); control (x -/+ dx/2, cy) with cy = rand%h,
## folded up by h/2 when past it; end (x -/+ dx, start.y). Speed 400 px/s
## over 2*sqrt((bboxW/2)^2 + bboxH^2), the bbox including the control point
## (CGPathGetBoundingBox), walked at constant speed (kCAAnimationPaced).
## Rotation runs to -6.2657 (right half) / +6.2657 (left half) -- two
## setTransform: calls in one block, +/-3.1241 then +/-6.2657; the port
## animates to the LAST (what UIKit renders for that pair is an open device
## question), linear, over the same duration, and its
## stop handler removes the kernel. Each pop plays the first idle of five
## screen-owned players, pop_01/02/03/04/01 (kcKit.SoundBank).
const POP_TICK := 0.1
const POP_MAX_SHAKES := 6
const POP_MAX_FLYING := 7
const POP_CHANCE := 50                # rand % 100 > 0x31 -> skip
const POP_MIN_DX := 20.0
const POP_SPEED := 400.0
const POP_ROTATION := 6.2657          # 0x40C880E0 magnitude
const POP_SOUNDS := ["pop_01", "pop_02", "pop_03", "pop_04", "pop_01"]

var popcorn_color: Color = kcSelectSugar.selected_color

var _popcorn: kcPourOil.MaskedIV
var _color_popcorn: kcPourOil.MaskedIV
var _sugar: Sprite2D
var _elems: Array = []                # {node, half, home, left, right}
var _shakes := 1                      # viewWillAppear: self->shakes = 1
var _is_shaking := false
var _lid_animating := false
var _lid_home_center := Vector2.ZERO
var _pop_accum := 0.0
var _pop_sounds: kcKit.SoundBank
## AudioManager's popcorn_01 player (null when it was muted at entry, as
## loopFile returns nil then) and the newest shake_01 player.
var _popcorn_loop: AudioStreamPlayer
var _shake_sfx: AudioStreamPlayer
## The screen-owned popcorn_01 player behind _popcorn_loop.
var _popcorn_player: AudioStreamPlayer
var _bubbler: kcPourOil.OilBubbler
## Every tween this screen starts (kcKit.track / settle, keep-state).
var _tweens: Array = []


func on_enter() -> void:
	# initWithColor: (0x110F70) / viewDidLoad (0x111050).
	popcorn_color = kcSelectSugar.selected_color
	_build_piles()
	_build_elements()
	_bubbler = kcPourOil.OilBubbler.new(outlet("oil") as Sprite2D)
	add_child(_bubbler)
	_popcorn_player = kcKit.make_player(self, "popcorn_01", true)
	_shake_sfx = kcKit.make_player(self, "shake_01")
	_pop_sounds = kcKit.SoundBank.new(POP_SOUNDS)
	add_child(_pop_sounds)
	_view_will_appear()
	set_process(true)


## Back from Make: the same instance; viewWillAppear: and viewDidAppear:
## run again, which re-runs the whole step (shakes back to 1, the raw
## tableau faded back in, next hidden, the lid dropped on afresh).
func keeps_state_on_push() -> bool:
	return true


## viewDidAppear: (0x111EF0) -- the lid drop. Nav calls this when the push /
## pop slide ends (0.35 s after on_enter / on_resume), or at once for an
## unanimated change, on every appearance (it used to start with the
## slide, so the lid was half down before the screen had arrived).
func on_did_appear() -> void:
	_drop_lid()


func on_resume() -> void:
	kcKit.drop_coin_panel(self)
	_view_will_appear()


## viewWillAppear: (0x111778), in its order.
func _view_will_appear() -> void:
	_shakes = 1
	_is_shaking = false
	_lid_animating = false
	# Snaps every element's centre x EXCEPT popcornView's, which keeps
	# wherever it is (157.5, its nib centre, on the first appearance) until
	# the next shake.
	for e in _elems:
		if e["node"] != outlet("popcornView"):
			_set_elem_x(e, e["home"])
	# Both piles' baseOrigPt.y back to 121 (x kept), and the alphas.
	for p: kcPourOil.MaskedIV in [_popcorn, _color_popcorn]:
		p.set_base_orig_pt(Vector2(p.get_base_orig_pt().x, PILE_ORIG.y))
	_popcorn.modulate.a = 1.0
	_color_popcorn.modulate.a = 0.0
	var kernels := outlet("kernels") as Sprite2D
	if kernels != null:
		kernels.modulate.a = 1.0
	var oil := outlet("oil") as Sprite2D
	if oil != null:
		oil.modulate.a = OIL_ALPHA
	_sugar.modulate.a = 1.0
	_set_next_enabled(false)
	dismiss_instruction()             # setHidden:YES on instIV
	var shake_btn := outlet("shakeButton")
	if shake_btn != null and shake_btn != self:
		shake_btn.visible = true
	Audio.loop("frying_lo_loop", linear_to_db(0.5))    # volume 0x3F000000
	# popcornTimer 0.1s and bubbleTimer 0.2s: fresh timers.
	_pop_accum = 0.0
	if _bubbler != null:
		_bubbler.restart()
	# popcorn_01, a new looping player from the start (see the constant
	# block above); loopFile returns nil while muted.
	_popcorn_player.stop()
	_popcorn_player.stream_paused = false
	if Audio.muted:
		_popcorn_loop = null
	else:
		_popcorn_loop = _popcorn_player
		_popcorn_loop.play()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## viewDidLoad (0x111050): the two masked piles and the tinted sugar heap,
## re-stacked so the final z-order is
##   bg, grate, fryer, lid, kernels, popcorn, colorPopcorn, popcornView,
##   sugarPile, oil, instIV, buttons
## (the nib already has lid below kernels; the sequence of
## insertSubview:belowSubview:oil calls lands the rest). The port once moved
## the lid ABOVE the kernels and popcornView ABOVE the
## oil, because Godot's move_child to a later sibling's index lands after it.
func _build_piles() -> void:
	var mask := _tex("kc_mask.png")
	var pile_tex := _tex("kc_popcorn_pile.png")
	var oil := outlet("oil")

	_popcorn = kcPourOil.MaskedIV.new(pile_tex, mask, true)
	_popcorn.set_center(PILE_CENTER)
	_popcorn.set_base_orig_pt(PILE_ORIG)
	add_child(_popcorn)
	if oil != null and oil != self:
		move_child(_popcorn, oil.get_index())

	_color_popcorn = kcPourOil.MaskedIV.new(
		kcPourOil.bake_tint(pile_tex, popcorn_color, 9), mask, true)
	_color_popcorn.set_center(PILE_CENTER)
	_color_popcorn.set_base_orig_pt(PILE_ORIG)
	_color_popcorn.modulate.a = 0.0
	add_child(_color_popcorn)
	if oil != null and oil != self:
		move_child(_color_popcorn, oil.get_index())

	var pv := outlet("popcornView")
	if pv != null and pv != self and oil != null and oil != self:
		_insert_below(pv, oil)

	_sugar = Sprite2D.new()
	_sugar.texture = kcPourOil.bake_tint(_tex("kc_sugar_pile.png"),
		popcorn_color, 7)
	_sugar.centered = false
	_sugar.position = SUGAR_TOP_LEFT
	add_child(_sugar)
	if oil != null and oil != self:
		move_child(_sugar, oil.get_index())


## insertSubview:belowSubview: for a node already in the tree, from either
## side of `ref`.
func _insert_below(n: Node, ref: Node) -> void:
	var i := n.get_index()
	var r := ref.get_index()
	move_child(n, r - 1 if i < r else r)


## The centre-x rig: every element with its own home/left/right, since the
## snap values differ per element (0x111778 / 0x112258 / 0x1129C8).
func _build_elements() -> void:
	_elems.clear()
	for n in ["fryer", "lid", "oil", "kernels"]:
		var s := outlet(n) as Sprite2D
		if s == null:
			continue
		if n == "lid":
			_lid_home_center = s.position + s.texture.get_size() * s.scale * 0.5
		_elems.append({"node": s,
			"half": s.texture.get_size().x * s.scale.x * 0.5,
			"home": HOME_X[n], "left": SHAKE_LEFT_X, "right": SHAKE_RIGHT_X})
	var mask_half: float = _tex("kc_mask.png").get_size().x * 0.5
	for p: Node2D in [_popcorn, _color_popcorn]:
		_elems.append({"node": p, "half": mask_half,
			"home": HOME_X["popcorn"], "left": SHAKE_LEFT_X,
			"right": SHAKE_RIGHT_X})
	var pv := outlet("popcornView") as Node2D
	if pv != null:
		_elems.append({"node": pv, "half": POPCORN_VIEW_SIZE.x * 0.5,
			"home": HOME_X["popcornView"], "left": SHAKE_LEFT_X,
			"right": SHAKE_RIGHT_X})
	_elems.append({"node": _sugar, "half": 0.0,   # TintedIV: centre == top-left
		"home": HOME_X["sugarPile"], "left": SUGAR_LEFT_X,
		"right": SUGAR_RIGHT_X})


func _set_elem_x(e: Dictionary, cx: float) -> void:
	(e["node"] as Node2D).position.x = cx - float(e["half"])


## viewDidAppear: (0x111EF0) -- the lid drops on; lid_05 at the END.
func _drop_lid() -> void:
	var lid := outlet("lid") as Sprite2D
	if lid == null:
		return
	_lid_animating = true
	var size: Vector2 = lid.texture.get_size() * lid.scale
	lid.position = Vector2(160.0, -size.y) - size * 0.5
	var t := _tween()
	t.tween_property(lid, "position", _lid_home_center - size * 0.5,
		LID_SECONDS).set_custom_interpolator(kcKit.ui_curve(kcKit.UI_EASE_IN))
	t.tween_callback(func() -> void:
		_lid_animating = false
		Audio.play("lid_05"))


# -- the shake ----------------------------------------------------------

## shakeClick: (0x11488C) -- the one live entry point.
func _on_shakeClick() -> void:
	_shake()


## shake (0x112258).
func _shake() -> void:
	if _lid_animating or _shakes > SHAKES_DONE - 1 or _is_shaking:
		return
	_is_shaking = true
	_shakes += 1
	var u := _shakes * SHAKE_STEP
	# The crossfade and pile growth snap instantly, before the animation.
	var orig_y := PILE_ORIG_Y_FULL * (1.0 - u)
	_popcorn.set_base_orig_pt(Vector2(_popcorn.get_base_orig_pt().x, orig_y))
	_color_popcorn.set_base_orig_pt(
		Vector2(_color_popcorn.get_base_orig_pt().x, orig_y))
	_popcorn.modulate.a = minf(1.0, 1.0 - u)
	_color_popcorn.modulate.a = minf(1.0, u)
	var oil := outlet("oil") as Sprite2D
	if oil != null:
		oil.modulate.a = 0.5 - u * 0.5
	var kernels := outlet("kernels") as Sprite2D
	if kernels != null:
		kernels.modulate.a = 1.0 - u
	_sugar.modulate.a = 1.0 - u
	for e in _elems:
		_set_elem_x(e, e["home"])
	# [[playerDict objectForKey:@"popcorn_01"] play] -- resume the paused
	# loop (a no-op while it still plays) -- then playFile shake_01.
	if _popcorn_loop != null:
		if _popcorn_loop.stream_paused:
			_popcorn_loop.stream_paused = false
		elif not _popcorn_loop.playing:
			_popcorn_loop.play()
	_shake_sfx.stop()
	if not Audio.muted:
		_shake_sfx.play()
	var t := _tween().set_trans(Tween.TRANS_LINEAR)
	t.tween_method(_leg.bind("home", "left"), 0.0, 1.0, LEFT_SECONDS)
	t.tween_method(_leg.bind("left", "right"), 0.0, 1.0, RIGHT_SECONDS)
	t.tween_method(_leg.bind("right", "home"), 0.0, 1.0, MID_SECONDS)
	t.tween_callback(_shake_done)


func _leg(t: float, from_key: String, to_key: String) -> void:
	for e in _elems:
		if is_instance_valid(e["node"]):
			_set_elem_x(e, lerpf(float(e[from_key]), float(e[to_key]), t))


## animationDidStop "ShakeMid" (0x1129C8).
func _shake_done() -> void:
	_is_shaking = false
	# [[playerDict objectForKey:@"popcorn_01"] pause]; stopPlayerForFile:
	# shake_01 -- the 2.35s shake sound is cut off after the 0.2s shake.
	if _popcorn_loop != null and _popcorn_loop.playing:
		_popcorn_loop.stream_paused = true
	_shake_sfx.stop()
	if _shakes >= SHAKES_DONE:
		show_next_button()
		_set_next_enabled(true)
		var shake_btn := outlet("shakeButton")
		if shake_btn != null and shake_btn != self:
			shake_btn.visible = false


# -- popcornTick (0x113A44) ---------------------------------------------

func _process(delta: float) -> void:
	_pop_accum += delta
	while _pop_accum >= POP_TICK:
		_pop_accum -= POP_TICK
		_popcorn_tick()


func _popcorn_tick() -> void:
	if _shakes > POP_MAX_SHAKES:
		return
	var pv := outlet("popcornView") as Node2D
	if pv == null or pv.get_child_count() > POP_MAX_FLYING - 1:
		return
	if randi() % 100 > POP_CHANCE - 1:
		return
	var tex := _tex("kc_popcorn_%d.png" % (randi() % 3 + 1))
	if tex == null:
		return
	var w := POPCORN_VIEW_SIZE.x
	var h := POPCORN_VIEW_SIZE.y
	var k := Sprite2D.new()
	k.texture = tex
	k.centered = true
	var x := float(randi() % int(w))
	var start_y := h - tex.get_size().y
	k.position = Vector2(x, start_y)
	pv.add_child(k)

	var dx := maxf(POP_MIN_DX, float(randi() % int(w * 0.5)))
	var going_right := x < w * 0.5
	var cp_y := float(randi() % int(h))
	if cp_y > h * 0.5:
		cp_y -= h * 0.5
	var cp := Vector2(x + dx * 0.5 if going_right else x - dx * 0.5, cp_y)
	var end := Vector2(x + dx if going_right else x - dx, start_y)

	# CGPathGetBoundingBox includes the control point.
	var bb_min := Vector2(minf(minf(x, cp.x), end.x), minf(minf(start_y, cp.y), end.y))
	var bb_max := Vector2(maxf(maxf(x, cp.x), end.x), maxf(maxf(start_y, cp.y), end.y))
	var bb := bb_max - bb_min
	var seconds := 2.0 * sqrt(pow(bb.x * 0.5, 2.0) + pow(bb.y, 2.0)) / POP_SPEED

	# kCAAnimationPaced along the quad: constant speed, linear in time.
	var path := kcKit.paced_quad(Vector2(x, start_y), cp, end)
	var t := _tween()
	t.set_parallel(true)
	t.tween_method(func(u: float) -> void:
		if is_instance_valid(k):
			k.position = path.at(u),
		0.0, 1.0, seconds)
	t.tween_property(k, "rotation",
		-POP_ROTATION if not going_right else POP_ROTATION, seconds) \
		.set_trans(Tween.TRANS_LINEAR)
	# "Rotate_Popcorn"'s stop handler removes the kernel (0x1129C8).
	t.chain().tween_callback(k.queue_free)

	# First idle player of pop_01/02/03/04/01, none if all five are busy.
	_pop_sounds.play_first_idle()


# -- navigation ---------------------------------------------------------

func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.set("disabled", not on)


## nextClick: (0x114478): the customCategories bake for MakeViewController.
## kcBucket at (20, 240) (0x41A00000 / 0x43700000), kcPopcorn -- the
## HardLight-9 bake of kc_bucket_pile in the chosen colour -- at (20, 100)
## (0x42C80000), classStr "KETTLE_CORN". ItemCenterX/Y place the layer's
## TOP-LEFT: DecorateItemView is a zero-frame TintedIV, so its "center" is
## its origin (MakeViewController's own doc, 0xBC914).
##
## "Image" carries an Image, the type MakeViewController._append_custom
## renders (ccMachine's worked example does the same; GameState's doc
## comment says Texture2D, which Make silently drops).
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.custom_categories = {
		"kcBucket": {
			"Properties": {
				"IsEdible": false, "ViewIndex": 1, "Type": "Stationary",
				"ItemCenterX": 20.0, "ItemCenterY": 240.0,
			},
			"Image": _handoff_img(_tex("kc_bucket.png")),
		},
		"kcPopcorn": {
			"Properties": {
				"IsEdible": true, "ViewIndex": 2, "Type": "Stationary",
				"ItemCenterX": 20.0, "ItemCenterY": 100.0,
			},
			"Image": _handoff_img(kcPourOil.bake_tint(
				_tex("kc_bucket_pile.png"), popcorn_color, 9)),
		},
	}
	Nav.next()


func _handoff_img(tex: Texture2D) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


## backClick: (0x114408).
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


func on_exit() -> void:
	# viewWillDisappear: (0x11204C): popcornTimer and bubbleTimer off (the
	# port's accumulators stop with the node out of the tree and are reset
	# by the next viewWillAppear:), frying_lo_loop and popcorn_01 stopped,
	# the five pop players stopped. Hops and a shake in flight complete
	# while covered (settled first). (shake_01 is not stopped there; PORT
	# CHOICE: its player leaves the tree with the screen, which silences it.)
	kcKit.settle(_tweens)
	if _bubbler != null:
		_bubbler.restart()
	Audio.stop("frying_lo_loop")
	if _popcorn_loop != null:
		_popcorn_loop.stop()
	if _pop_sounds != null:
		_pop_sounds.stop_all()


func _tween() -> Tween:
	return kcKit.track(_tweens, create_tween())


## This screen's changeInstruction: hides nextButton (read from the
## binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
