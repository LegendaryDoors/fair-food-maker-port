# Candy Apple step 6 -- stir the grated chocolate until it melts.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithNibName: 0x159498, viewDidLoad 0x159764, viewWillAppear: 0x159FF0,
#   viewDidAppear: 0x15A1F0 -> showSpoon 0x15A320, viewWillDisappear:
#   0x15A200, bubbleTick 0x15ACFC, animationDidStop 0x15AFA0,
#   draggableTouchBegan/Moved/Ended 0x15AFE0/0x15B0CC/0x15B48C,
#   nextClick: 0x15BA04, skipClick: 0x15BB8C, changeInstruction: 0x15BD00.
#   Rate floats read from __const: 0x15B480 = 0.0025, 0x15B484 = 0.01.
#
# Mechanic, as read: the same crossfade family as cdStir/fcStir but with its
# own gating and its own subject. Three layers sit in the pot
# (nib chgum_pot at (9,216,302,200)):
#   * gratedChocolate: MaskedIV(alt-tinted choc_pile, chgum_pot_mask),
#     centre (160,318), baseOrigPt = the value caSelectChocolate handed over
#     via setGratedBaseOrig: -- the pile arrives exactly as full as it was
#     left. Starts at alpha 1. MaskedIV clips upside down (drawRect:
#     0x46E68, no CTM flip in UIKit's flipped context), so the mask is
#     flipped here as on caSelectChocolate/ccbSelectChocolate (the port
#     used to draw the bowl the right way up, and the pile showed below
#     the pot).
#   * meltedChocolate: nib UIImageView (34,243,253,109), image = alt-tinted
#     Melted_Chocolate.png (blend 3 / Overlay, TintedIV alternate path
#     0x4711C/0x474FC), stretched to the nib frame. Starts at alpha 0.
#   * bubbles: nib UIView (9,216,302,200) at alpha 0; a 0.1s timer spawns a
#     bubble 30% of ticks (arc4random % 100 <= 29): bubble.png at alpha 0.6,
#     scale 0.1, centre (rand 70..229, 135 - scaledH/2), animated to scale 1
#     and centre y 45 over 2.0s ease-in, removed on completion.
# Dragging the spoon (nib DraggableIV (210,8,57,207), rotated 0.5236 rad,
# snapTime 0.25, art cd_spoon.png -- shared with the corn dog) with its
# frame intersecting the pot's AND its centre at y >= 180 crossfades
# 0.0025 PER MOVE EVENT: melted +, grated -, bubbles +. At melted alpha
# >= 1.0 the stir sound stops and next slides in.
#
# Sounds: stir_unfinished (m4a) loops while held; stirring (mp3) loops only
# while actually stirring; both stop on release (0x15B48C) and on exit.
#
# Particles:
#  * the burner flame: nib SSEmitter `fire` (0,360,320,24), configured in
#    viewDidLoad (0x159764, call 0x159FE0: Candy_Apple_Flame_For_Pot_Anime
#    1..3, no tint, random, 0.05 s, 0.5 s, centre (160,12), alpha 0 -> 1,
#    scale 0.5, options 2); started by viewWillAppear: (0x159FF0), stopped by
#    viewWillDisappear: (0x15A200), backClick: (0x15B904) and nextClick:
#    (0x15BA04). Nib slot: above pot, below meltedChocolate (and the pile).
#  * the spoon tip: the 1x1 SSEmitter (tag 326) viewDidLoad puts inside the
#    spoon -- core/StirTool.gd's tip_emitter. showSpoon (0x15A320, call
#    0x15AA58) configures it ONLY in the two mixer branches
#    (White_Electric_Hand_Mixer_PS_1..3 for both mixers, tinted
#    infoDict["Color"]); draggableTouchMoved: (0x15B0CC) starts it while the
#    tool is over the pot (frame intersects, centre y >= 180) and stops it
#    otherwise; draggableTouchEnded: (0x15B48C) stops it. A later showSpoon
#    in the spoon branch never clears that configuration, so after a return
#    with a mixer used once, the plain spoon sparks too -- as shipped.
# Not ported:
#  * (the white/pink mixer consumables ARE ported; see the Mixers block
#    below);
#  * startBurner (0x15ACF8) is an empty function, and viewWillAppear's
#    "MoveBurner" UIView animation block (0x15A08C) sets no properties --
#    both dead in the original.
#
# KEEP STATE: the controller survives under caDipApple. On return
# viewWillAppear: (fire started, "inst_stir" slid in -- next hidden -- spoon
# hidden, bubbles alpha 0, a NEW 0.1 s bubbleTimer) and viewDidAppear: ->
# showSpoon (the tool for the owned mixers -- nextClick: zeroed them, so the
# plain spoon and both badges -- at home and brought to the front, melted
# alpha 0, pile alpha 1, the instruction again) re-run: the stir is RESET
# and must be done again. viewWillDisappear: stops the fire, fire_loop,
# stirring, mixer and stir_unfinished and invalidates the bubble timer.

extends "res://core/Screen.gd"

const MaskedSprite := preload("res://core/MaskedSprite2D.gd")
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")
const FIRE_KEY := "caStirIngredients.fire"
const TIP_KEY := "caStirIngredients.spoonTip"
const caSelectChocolate := preload("res://screens/caSelectChocolate.gd")

const POT_RECT := Rect2(9, 216, 302, 200)     # nib id 2
const MELTED_RECT := Rect2(34, 243, 253, 109) # nib id 4
const BUBBLES_POS := Vector2(9, 216)          # nib id 5
const PILE_CENTER := Vector2(160, 318)        # 0x43200000 / 0x439F0000
const PILE_SIZE := Vector2i(302, 200)
const PILE_BASE_X := 53.0
## Spoon: nib frame (210,8,57,207) -> centre (238.5,111.5); rotation
## 0.5236 rad; snapTime 0.25 (0x3E800000).
const SPOON_CENTER := Vector2(238.5, 111.5)
const SPOON_SIZE := Vector2(57, 207)
const SPOON_ROTATION := 0.5236
const SPOON_SNAP := 0.25

## Mixers, PORTED (the phone shows both badges). Shared
## logic in core/StirMixers.gd and core/StirTool.gd; this screen's own
## numbers: consumable names Mixer_60Mix / PinkMixer_60Mix, and the per-move
## crossfade step with the white mixer 0.01 and the pink one 0.02
## (draggableTouchMoved:, the two constants next to the no-mixer one plus
## the inline pink literal). Buying one swaps the tool in place (showSpoon),
## which also resets the stir progress and re-shows the instruction, and
## hides both badges; nextClick: zeroes the quantities.
const StirToolScript := preload("res://core/StirTool.gd")
const StirMixersScript := preload("res://core/StirMixers.gd")
const MIXER_NAME := "Mixer_60Mix"
const PINK_MIXER_NAME := "PinkMixer_60Mix"
const STIR_STEP_MIXER := 0.01
const STIR_STEP_PINK := 0.02

var _mixers: RefCounted
## Stir gate: spoon.centre.y >= 180.0 (0x15B10C compare).
const STIR_MIN_Y := 180.0
## No-mixer crossfade step per move event (float 0x15B480).
const STIR_STEP := 0.0025
## bubbleTick: 0.1s timer; 30% spawn; x in 70..229 (arc4random % 0xA0 + 70);
## start y 135 - h/2 (0x43070000), end y 45 (0x42340000); 2.0s ease-in;
## alpha 0.6 (0x3F19999A); start scale 0.1.
const BUBBLE_TICK_S := 0.1
const BUBBLE_X_MIN := 70
const BUBBLE_X_RANGE := 160
const BUBBLE_Y_BASE := 135.0
const BUBBLE_Y_END := 45.0
const BUBBLE_SECONDS := 2.0
const BUBBLE_ALPHA := 0.6
const BUBBLE_SCALE0 := 0.1

var _melted: Sprite2D
var _pile: MaskedSprite
var _bubbles: Node2D
var _spoon: Node2D
var _dragging := false
var _grab := Vector2.ZERO
## The spoon's SnapToOrig glide home (see _spoon_hit).
var _spoon_snap: Tween
var _bubble_timer: Timer
var _fire: SSEmitter                          # nib `fire`
## The shared infoDict (see caSelectStick._info).
var _info: Dictionary = {}


func on_enter() -> void:
	_info = GameState.custom_categories
	# viewDidLoad: the pot layers, the fire emitter, the spoon and badges.
	_build_layers()
	_build_fire()
	_build_spoon()
	_bubble_timer = Timer.new()
	_bubble_timer.wait_time = BUBBLE_TICK_S
	_bubble_timer.timeout.connect(_bubble_tick)
	add_child(_bubble_timer)
	_view_will_appear()


## viewWillAppear: (0x159FF0).
func _view_will_appear() -> void:
	if _fire != null:
		_fire.start()
	change_instruction("inst_stir.png")
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false     # changeInstruction: tail
	if _spoon != null:
		_spoon.visible = false
	if _bubbles != null:
		_bubbles.modulate.a = 0.0
	# scheduledTimerWithTimeInterval:0.1 (double 0x3FB999999999999A).
	_bubble_timer.start()


## UINavigationController keeps this controller alive under caDipApple
## (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## viewDidAppear: (0x15A1F0) -> showSpoon, on every appearance. Nav calls this
## when the push / pop slide ends, or at once for an unanimated change (the
## push in from the chocolate step is animated:NO; the pop back from
## caDipApple slides, so the spoon appears after it).
func on_did_appear() -> void:
	_show_spoon()


## Back from caDipApple: viewWillAppear: then viewDidAppear: -> showSpoon
## (see header).
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		# CoinHUD re-adds the panel after this; drop the first appearance's.
		remove_child(old)
		old.queue_free()
	_dragging = false
	if _spoon != null:
		_spoon.set("animating", false)
	_view_will_appear()


## viewDidLoad (0x159764): the nib SSEmitter `fire`, configured with tint nil.
func _build_fire() -> void:
	var host := outlet("fire")
	if host == null or host == self:
		return
	_fire = SSEmitter.attach(host, SSEmitterConfigs.frame_size(FIRE_KEY)) as SSEmitter
	SSEmitterConfigs.apply(_fire, FIRE_KEY, null)


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## viewDidLoad (0x159764) + showSpoon tail (0x15AC7A): melted at alpha 0,
## grated pile at alpha 1, bubbles at alpha 0. Entered standalone with no
## Color in the carrier, the tinted layers stay absent rather than invented.
func _build_layers() -> void:
	var color_v: Variant = _info.get("Color")
	if not (color_v is Color):
		return
	var color: Color = color_v

	# gratedChocolate: below meltedChocolate (insertSubview:belowSubview:).
	var pile_tinted := caSelectChocolate.bake_alt_tint(
		_tex("choc_pile.png"), color, 3)
	if pile_tinted != null:
		var base := pile_tinted.get_image()
		var canvas := Image.create(PILE_SIZE.x, PILE_SIZE.y, false,
			Image.FORMAT_RGBA8)
		var orig_y := float(_info.get("GratedOrigY", 138.0))
		canvas.blend_rect(base,
			Rect2i(0, 0, base.get_width(), base.get_height()),
			Vector2i(int(PILE_BASE_X), int(round(orig_y))))
		_pile = MaskedSprite.new()
		_pile.texture = ImageTexture.create_from_image(canvas)
		var mask := _tex("chgum_pot_mask.png")
		_pile.mask = mask
		_pile.mask_mode = MaskedSprite.detect_mask_mode(mask)
		# MaskedIV(tinted pile, chgum_pot_mask) -- the same upside-down clip as on
		# caSelectChocolate (MaskedSprite2D.mask_flip_v): the pile shows
		# exactly as far as it had risen into the flipped bowl there.
		_pile.mask_flip_v = true
		_pile.position = PILE_CENTER
		add_child(_pile)
		# insertSubview:belowSubview:meltedChocolate (0x1592F8) -- the pile
		# sits under the melted layer, not on top of the chrome.
		var mo := outlet("meltedChocolate")
		if mo != null and mo != self:
			move_child(_pile, (mo as Node).get_index())

	var melted_tinted := caSelectChocolate.bake_alt_tint(
		_tex("Melted_Chocolate.png"), color, 3)
	if melted_tinted != null:
		_melted = outlet("meltedChocolate") as Sprite2D
		if _melted == null:
			_melted = Sprite2D.new()
			add_child(_melted)
		_melted.texture = melted_tinted
		# The nib UIImageView stretches the 244x87 art to (34,243,253,109).
		_melted.centered = false
		_melted.position = MELTED_RECT.position
		_melted.scale = MELTED_RECT.size / Vector2(melted_tinted.get_size())
		_melted.modulate.a = 0.0

	_bubbles = outlet("bubbles") as Node2D
	if _bubbles == null:
		_bubbles = Node2D.new()
		_bubbles.position = BUBBLES_POS
		add_child(_bubbles)
	_bubbles.modulate.a = 0.0


## viewDidLoad: the nib DraggableIV spoon is replaced by the shared
## StirTool (core/StirTool.gd, which also carries the tag-326 tip emitter);
## initWithNibName:/viewDidLoad: the two mixer consumables and badges.
func _build_spoon() -> void:
	var o := outlet("spoon")
	if o != null and o != self:
		(o as CanvasItem).visible = false
	_mixers = StirMixersScript.new()
	_mixers.call("setup", self, MIXER_NAME, PINK_MIXER_NAME, _on_mixer_bought)
	_spoon = StirToolScript.new()
	_spoon.set("home", SPOON_CENTER)
	_spoon.set("kind", _mixers.call("kind"))
	add_child(_spoon)


## showSpoon (0x15A320): the tool for the owned mixers (pink first), its
## tip emitter configured in the mixer branches only, badges hidden with a
## mixer / shown with the spoon, unhidden at origCenter, addSubview: (to the
## front), melted alpha 0, pile alpha 1, "inst_stir" again.
func _show_spoon() -> void:
	var k := int(_mixers.call("kind"))
	_spoon.call("show_kind", k)
	if k != StirToolScript.Kind.SPOON:
		var tip: Node = _spoon.get("tip_emitter")
		var c: Variant = _info.get("Color")
		if tip != null:
			SSEmitterConfigs.apply(tip, TIP_KEY, c if c is Color else null)
	_mixers.call("set_badges_visible", k == StirToolScript.Kind.SPOON)
	move_child(_spoon, get_child_count() - 1)
	if _melted != null:
		_melted.modulate.a = 0.0
	if _pile != null:
		_pile.modulate.a = 1.0
	change_instruction("inst_stir.png")


## consumablePurchased: (0x15B560) -- quantity is already bumped by
## StirMixers; when the tool is showing and this is the first unit,
## showSpoon swaps the implement in place, resets the progress, re-shows the
## instruction and hides both badges. (Unlike ccbStir, caStir does NOT zero
## the bubbles here -- the port used to.)
func _on_mixer_bought(c: RefCounted) -> void:
	if _spoon != null and _spoon.visible and int(c.get("quantity")) == 1:
		_show_spoon()


## draggableTouchMoved:'s rate for the owned tool.
func _stir_step() -> float:
	match int(_mixers.call("kind")):
		StirToolScript.Kind.PINK_MIXER:
			return STIR_STEP_PINK
		StirToolScript.Kind.WHITE_MIXER:
			return STIR_STEP_MIXER
		_:
			return STIR_STEP


func _unhandled_input(event: InputEvent) -> void:
	if _spoon == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and not _dragging and _spoon_hit(mb.position):
			if _spoon_snapping():
				_spoon_snap.kill()
				_spoon.position = _spoon.get("home")
			_dragging = true
			_grab = _spoon.position - mb.position
			# draggableTouchBegan: (0x15AFE0): the "mixer" loop with a mixer owned, else
			# stir_unfinished; the frame animation starts either way.
			Audio.loop("mixer" if _mixers.call("any_owned") else "stir_unfinished")
			_spoon.set("animating", true)
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			# draggableTouchEnded: (0x15B48C) stops mixer/stir_unfinished/
			# stirring; DraggableIV then snaps home over 0.25s, linear.
			Audio.stop("mixer")
			Audio.stop("stir_unfinished")
			_spoon.set("animating", false)
			_tip_stop()
			Audio.stop("stirring")
			_snap_spoon_home()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		# iOS delivered touchesMoved: at most once per frame (60 Hz); see
		# Screen.accept_touch_move. Without that limit the funnel cake mix and
		# drain ran far too fast on a high-refresh monitor.
		if not accept_touch_move():
			get_viewport().set_input_as_handled()
			return
		_spoon.position = (event as InputEventMouseMotion).position + _grab
		_stir_move()
		get_viewport().set_input_as_handled()


## The spoon's 0.25 s SnapToOrig (DraggableIV touchesEnded: 0x46860) is
## +beginAnimations:/commitAnimations: the spoon stays touchable on its way
## home, hit-tested at its MODEL centre (origCenter), and the drag owns it
## once caught. StirTool.snap_home() leaves an untracked tween that kept
## pulling a caught spoon home under the finger while the stir test ran
## where the finger was, so this screen runs the same 0.25 s linear glide
## itself and can stop it (same as dicStir / ccbStir).
## PORT CHOICE: a caught spoon lands on the model at once instead of
## gliding on toward the finger for the rest of the 0.25 s.
func _spoon_hit(p: Vector2) -> bool:
	if _spoon_snapping():
		var t: Transform2D = _spoon.transform
		t.origin = _spoon.get("home")
		var sz: Vector2 = _spoon.get("size")
		return Rect2(-sz * 0.5, sz).has_point(t.affine_inverse() * p)
	return bool(_spoon.call("hit", p))


func _spoon_snapping() -> bool:
	return _spoon_snap != null and _spoon_snap.is_valid() \
		and _spoon_snap.is_running()


func _snap_spoon_home() -> void:
	if _spoon_snap != null and _spoon_snap.is_valid():
		_spoon_snap.kill()
	_spoon_snap = create_tween()
	_spoon_snap.tween_property(_spoon, "position", _spoon.get("home"),
		StirToolScript.SNAP_SECONDS).set_trans(Tween.TRANS_LINEAR)


## draggableTouchMoved: (0x15B0CC). The frame test is the rotated spoon's
## bounding box against the pot's nib frame, plus the centre-y gate.
func _stir_move() -> void:
	var frame: Rect2 = _spoon.call("frame_rect")
	var step := _stir_step()
	if frame.intersects(POT_RECT) and _spoon.position.y >= STIR_MIN_Y:
		var tip: Node = _spoon.get("tip_emitter")
		if tip != null:
			tip.call("start")                  # [[spoon viewWithTag:326] start]
		# CALayer clamps alpha to [0,1]; the >= 1.0 test relies on it.
		if _melted != null:
			_melted.modulate.a = clampf(_melted.modulate.a + step, 0.0, 1.0)
		if _pile != null:
			_pile.modulate.a = clampf(_pile.modulate.a - step, 0.0, 1.0)
		if _bubbles != null:
			_bubbles.modulate.a = clampf(_bubbles.modulate.a + step, 0.0, 1.0)
		var a := 1.0 if _melted == null else _melted.modulate.a
		if a >= 1.0:
			Audio.stop("stirring")
			var n := outlet("nextButton")
			if n != null and n != self and not (n as CanvasItem).visible:
				show_next_button()
		else:
			Audio.loop("stirring")
	else:
		Audio.stop("stirring")
		_tip_stop()


## [[spoon viewWithTag:326] stop].
func _tip_stop() -> void:
	var tip: Node = _spoon.get("tip_emitter") if _spoon != null else null
	if tip != null:
		tip.call("stop")


## bubbleTick (0x15ACFC), on the 0.1s timer.
func _bubble_tick() -> void:
	if _bubbles == null or randi() % 100 > 29:
		return
	var tex := _tex("bubble.png")
	if tex == null:
		return
	var b := Sprite2D.new()
	b.texture = tex
	b.modulate.a = BUBBLE_ALPHA
	b.scale = Vector2(BUBBLE_SCALE0, BUBBLE_SCALE0)
	var h := tex.get_size().y * BUBBLE_SCALE0
	b.position = Vector2(float(randi() % BUBBLE_X_RANGE + BUBBLE_X_MIN),
		BUBBLE_Y_BASE - h * 0.5)
	_bubbles.add_child(b)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(b, "scale", Vector2.ONE, BUBBLE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_property(b, "position:y", BUBBLE_Y_END, BUBBLE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	# animationDidStop:finished:context: (0x15AFA0) removes the bubble.
	tw.chain().tween_callback(b.queue_free)


## nextClick: (0x15BA04): button_press, push caDipApple with the same
## infoDict. (The `Color == nil -> clearColor` line computes a colour and
## discards it -- dead in the original, not ported.)
func _on_nextClick() -> void:
	_mixers.call("reset_quantities")   # setQuantity:0 on both mixers
	if _fire != null:
		_fire.stop()
	Audio.play("button_press")
	GameState.custom_categories = _info
	Nav.next()


## skipClick: (0x15BB8C) forwards to nextClick: -- no nib action reaches it.
func _on_skipClick() -> void:
	_on_nextClick()


## viewWillDisappear: (0x15A200): stop the fire emitter, stop fire_loop/
## stirring/mixer/stir_unfinished, invalidate the bubble timer.
func on_exit() -> void:
	if _fire != null:
		_fire.stop()
	Audio.stop("fire_loop")
	Audio.stop("stirring")
	Audio.stop("mixer")
	Audio.stop("stir_unfinished")
	if _bubble_timer != null:
		_bubble_timer.stop()


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true


## backClick: (0x15B904): both mixer quantities to 0, the fire emitter
## stopped, button_press, pop (animated NO). Screen's default popped
## silently and left the mixer quantities set.
func _on_backClick() -> void:
	_mixers.call("reset_quantities")
	if _fire != null:
		_fire.stop()
	Audio.play("button_press")
	Nav.back()
