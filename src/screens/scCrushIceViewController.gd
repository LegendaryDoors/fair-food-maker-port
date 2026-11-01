# Snow Cone step 1 -- pour the ice bag, watch the lid close, crush.
#
# Read from scCrushIceViewController in the original binary:
#   viewDidLoad 0x6F454, viewWillAppear: 0x6FAE0, viewDidAppear: 0x6FF78,
#   loop 0x70128, icePileLoop 0x707FC, crushIce: 0x70C38,
#   stopCrushingIce: 0x70D90, nextClick: 0x70F1C,
#   accelerometer:didAccelerate: 0x71AA8, animationDidStop:... 0x71A10.
#
# The original screen has three phases:
#   1. POUR   -- tilt (here: hold, a port choice) rotates the ice bag; while
#                tipped past the pour threshold a loop timer (0.2s) spawns
#                sc_ice_cube sprites that spin and arc into the machine.
#                pourTime += 0.2 per spawn; done at 3.0 (15 cubes).
#   2. LID    -- once every cube has landed, the bag hides, the instruction
#                becomes inst_grind.png and the lid closes by itself: -pi
#                about a hinge at (8, h-16) in lid coords, 1.0s ease-in,
#                sc_lid.mp3 played 0.9s in. The touchesBegan/isLidBeingTouched
#                machinery exists in the binary but touchesMoved is an empty
#                stub -- the lid is NOT draggable.
#   3. CRUSH  -- an invisible button at (190,198,88,50) (nib id10) wired
#                touchDown -> crushIce: / touchUp -> stopCrushingIce:.
#                Holding it plays big_red_button + loops blend_loop and runs
#                icePileLoop at 0.1s.
#                CORRECTED against the original code (on an iPhone 4 a
#                crush takes 8.5 s): the ice pile is NOT nil. initWithNibName:
#                (0x6F05C) builds it in code -- sc_ice_pile.png (208x93) in a
#                clipping UIView at (56,317,208,93) inserted above `machine`,
#                the pile parked at y = its own height, i.e. fully below the
#                container and hidden. viewWillAppear: (0x6FAE0) re-parks it
#                and sets targetCenterY = baseCenterY - height + 8 -- a rise
#                of 85 px. icePileLoop (0x707FC) moves the centre up 1 px per
#                0.1 s tick while the button is held; at the target:
#                stopCrushingIce, doneCrushingIce, showNextButton,
#                cc_sugar_ding. So a full crush is 8.5 s of holding, with the
#                pile emerging under the machine as feedback. The earlier
#                "one tick finishes it" note was a misread.
#
# Completion: cc_sugar_ding.mp3, showNextButton. Next pushes scScoopIce.
#
# Corrections from a full re-read of the original: cubes start only once
# the bag is tipped past isPouring's -2.0071 rad (not on the press); the bag
# keeps following the hold after the 15th cube; the instruction is no longer
# hidden on the first pour (only showNextButton hides it); readyToCrush is
# set as the lid starts to swing, not 1 s later; the cubes fly at constant
# speed (kCAAnimationPaced); the skip badge sits above instIV, not on top of
# everything.
#
# KEEP STATE:
#  * Kept under a push (Nav keeps_state_on_push). viewWillAppear: (0x6FAE0)
#    and viewDidAppear: (0x6FF78) run on every appearance, and on a return
#    they restart the screen: viewDidDisappear: (0x70054) always sets
#    doneCrushingIce, so viewWillAppear: rotates the lid back by +pi (no
#    animation), re-parks the ice pile, clears every pour/crush flag, shows
#    the bag and the skip badge and starts a fresh 0.2 s `loop` timer; then
#    viewDidAppear: slides inst_pour in (hiding next). The player pours and
#    crushes again. on_exit = viewWillDisappear: ([crushedIce stop]) +
#    viewDidDisappear: (loop timer off, accelerometer off, doneCrushingIce).
#  * The crushedIce SSEmitter replaces the SCAFFOLDING
#    snow block: configured in viewDidLoad, start in crushIce:, stop in
#    stopCrushingIce: / backClick: / nextClick: / viewWillDisappear:.

extends "res://core/Screen.gd"

## For park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")

## Skip consumable (ported; the original shows its badge on the phone):
## viewDidLoad 0x6F454 (the Consumable is built there) builds Consumable DM_CONSUMABLE_SKIP / Skip_10Grind,
## cost = the dead server table GameData.CoinCosts ... SkipIngredients, 3 when
## absent; first-time message below. viewDidLoad 0x6F454 builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0x70BC8 ("store" sound,
## purchaseConsumable). consumablePurchased: 0x7094C calls nextClick: with the badge as sender -- the same path as the next button.
## consumablePurchaseFailed:error: 0x70AF4 (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_10Grind"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton

## viewWillAppear: (0x6FAE0) schedules `loop` at 0.2s (double at 0x6FF70).
const LOOP_INTERVAL := 0.2
## loop (0x70128): pourTime += 0.2 (float 0x70470) per spawn, done at 3.0
## (vmov.f32 d1, #3.0 at 0x7050C).
const POUR_TIME_STEP := 0.2
const POUR_TIME_DONE := 3.0

# -- accelerometer (0x71AA8), remapped to a hold (port choice) --------
## Low-pass 0.05/0.95 (doubles 0x71C40/0x71C48); rotation = filtered_x * 6.0;
## clamped to [-2.0944, -0.2618] (floats 0x71C6C/0x71C68); isPouring while
## rotation <= -2.0071286 (double 0x71C60). The hold drives the bag to the
## clamp bound, which sits inside the pouring band.
const REST_ROTATION := -0.2618
const POUR_ROTATION := -2.0944
## accelerometer:didAccelerate: (0x71AA8): isPouring = rotation <= this. The
## loop reads isPouring, so the cubes start only once the bag is actually
## tipped past it, not on the press itself.
const POUR_THRESHOLD := -2.00712864
## Port convention: the original reaches the clamp through its
## low-pass filter; the hold tweens there over 0.3s like the ms milk screen.
## (At the 1/30 s update interval set by startAccelerometer 0x71C70, a full
## tilt crosses the pour threshold after ~8 updates = 0.27 s, so 0.3 s is the
## same feel.)
const TILT_SECONDS := 0.3

# -- the cube flight (loop 0x70128) ------------------------------------
## Spin: setTransform ends at -6.2657 rad (0xC0C880E0), 1.0s
## (vmov.f64 d16, #1.0 at 0x702CA), curve 3 = linear, one pass.
## INFERRED (unverified on the phone): the block sets rotation(-3.1241) and
## then rotation(-6.2657) as matrices, and Core Animation interpolates a
## transform matrix along the shortest rotation -- -6.2657 is the same matrix
## as +0.0175 rad, so the device may show far less than a full turn. The
## port keeps the full counter-clockwise turn the angles describe; compare
## on hardware before changing it.
const CUBE_SPIN_RAD := -6.2657
const CUBE_SECONDS := 1.0
## Path (disasm 0x70486..0x704BC): MoveTo (bag.cx-30, bag.cy+30), then
## CGPathAddCurveToPoint cp1 = cp2 = (85, bag.cy+30), end (85, 200). 1.0s,
## kCAAnimationPaced: constant speed along the curve, so the port samples a
## baked Curve2D by arc length rather than by Bezier t.
const CUBE_START_OFF := Vector2(-30, 30)
const CUBE_CTRL_X := 85.0
const CUBE_END := Vector2(85, 200)

# -- the lid (loop 0x70128, "Close_Lid") -------------------------------
## Anchor point (8/w, (h-16)/h) via setAnchorPoint:forView: -> hinge at
## (8, 67) in the 123x83 lid. Rotate by -pi (0xC0490FDB), 1.0s, curve 1 =
## ease-in. playMachineLidClosingSound (sc_lid, cfstr 0x6BABE4) fires via
## performSelector:afterDelay:0.9.
## INFERRED: the swing direction. CGAffineTransformRotate(-3.1416) is a
## half-turn matrix, and which way Core Animation interpolates a half turn is
## decided inside QuartzCore, not this binary. The port swings the lid up and
## over the top (counter-clockwise), the only way it clears the machine body;
## unverified against the phone.
const LID_HINGE := Vector2(8, 67)
const LID_SECONDS := 1.0
const LID_SOUND_DELAY := 0.9

# -- the crush (crushIce: 0x70C38 / icePileLoop 0x707FC) ---------------
## icePileLoop repeats at 0.1s (double 0x70D88); 1 px per tick.
const CRUSH_TICK := 0.1
## Ice pile (initWithNibName: 0x6F05C / viewWillAppear: 0x6FAE0): clipping
## container (56,317,208,93) = the art's size (0x42600000 / 0x439E8000);
## pile parked at y = height (hidden); rise = height - 8 (vsub, +8.0).
const PILE_CONTAINER := Rect2(56, 317, 208, 93)
const PILE_ART := "sc_ice_pile.png"
const PILE_TARGET_MARGIN := 8.0

## The SSEmitter behind `crushedIce` (nib id2, frame (99,261,123,164), second
## subview: above bg_snowcone, below lid, bag and machine). viewDidLoad
## (0x6F454, call 0x6F86E) configures it with setParticles:
## [Grinding_Snow_PS_1..3] tint:nil random:YES interval:0.05 duration:0.2
## repeat:YES finalCenter:(frame.size/2 = 61.5,82) alpha 0->1 scale 1->1
## variances 0 options:2 -- a random snow image every 0.05 s fading in
## where it stands. Parameters: core/particles/SSEmitterConfigs.gd; the
## emitter itself: core/particles/SSEmitter.gd.
const SNOW := "scCrushIceViewController.crushedIce"
var _snow: SSEmitter

## machineLid: UIKit rotates a view about its layer anchorPoint -- the centre
## until loop's setAnchorPoint:forView: (0x6ED00) moves it to the hinge. The
## port keeps the sprite's pivot in `_lid_pivot` (texture coords) and its
## model rotation (the value UIKit's `transform` reads back, even while an
## animation is still presenting) in `_lid_model_rotation`.
var _lid: Sprite2D
var _lid_pivot := Vector2.ZERO
var _lid_model_rotation := 0.0
var _lid_tween: Tween

var _bag: Sprite2D
var _pouring := false
var _pour_time := 0.0
var _loop_accum := 0.0
var _cubes_in_flight := 0
var _done_pouring := false
var _lid_closing := false
var _ready_to_crush := false
var _crushing := false
var _crush_accum := 0.0
## doneCrushingIce. Also stands for the two invalidated NSTimers: _process
## does nothing while it is set.
var _done := false
var _pile: Sprite2D
var _pile_y := 0.0          # icePileCurrentCenterY, as the sprite's top-left y
var _pile_target_y := 0.0   # icePileTargetCenterY, likewise


func on_enter() -> void:
	# initWithNibName: (0x6F05C) + viewDidLoad (0x6F454): once per instance.
	_build_skip()
	_build_pile()
	_prepare_bag()
	_prepare_lid()
	_build_snow()
	_wire_crush_button()
	# viewWillAppear: here and on every return (on_resume); viewDidAppear:
	# in on_did_appear(), when the push / pop slide is over.
	_view_will_appear()
	UIKit.park_instruction(self)
	set_process(true)


func on_did_appear() -> void:
	_view_did_appear()


## Nav keeps this controller alive under the next step, as the
## UINavigationController does.
func keeps_state_on_push() -> bool:
	return true


## Back from scScoopIce: viewWillAppear: again (viewDidAppear: follows in
## on_did_appear(), after the pop slide).
func on_resume() -> void:
	_view_will_appear()


## viewWillDisappear: (0x6FFF4) [crushedIce stop]; viewDidDisappear:
## (0x70054) invalidates `timer` (the 0.2 s loop), stopAccelerometer,
## doneCrushingIce = YES, and removes the machine view's subviews (the nib's
## `machine` has none, so nothing to do). blend_loop is NOT stopped here --
## nextClick: / backClick: already stopped it; icePileTimer is not
## invalidated either (it only runs while the crush button is held).
func on_exit() -> void:
	if _snow != null:
		_snow.stop()
	_done = true


## viewWillAppear: (0x6FAE0). The first time doneCrushingIce is NO; after a
## return it is always YES (viewDidDisappear:), which first undoes the lid
## and the pile: CGAffineTransformRotate(lid.transform, +3.1416) with no
## animation -- the closed lid flips back open about its hinge -- and the
## pile's frame reset to (0, h, w, h), below its clipping box.
func _view_will_appear() -> void:
	if _done:
		_rotate_lid_now(PI)
		if _pile != null and _pile.texture != null:
			_pile_y = _pile.texture.get_size().y
			_pile.position.y = _pile_y
	_pile_target_y = PILE_TARGET_MARGIN         # centre - h + 8, as a top edge
	_done_pouring = false                       # isPouring/donePouring = NO
	_cubes_in_flight = 0                        # iceCubeCount = 0 (lifts INT_MIN)
	_lid_closing = false
	if _bag != null:
		_bag.visible = true                     # iceBag setHidden:NO
	_ready_to_crush = false
	_done = false
	_pour_time = 0.0                            # pourTime / rotateTime = 0
	_loop_accum = 0.0                           # a fresh 0.2 s `loop` timer
	_rest_bag()                                 # startAccelerometer
	if _skip_button != null:
		_skip_button.visible = true             # buySkip setHidden:NO


## viewDidAppear: (0x6FF78): instIV unhidden, changeInstruction:
## inst_pour.png -- which hides nextButton (0x715FC); showNextButton
## (0x71804) is the only thing that unhides it.
func _view_did_appear() -> void:
	change_instruction("inst_pour.png")


## The nib bag is a top-left Sprite2D scaled to (95,126); UIKit transforms
## rotate about the view centre, so re-anchor it there: centre (161.5, 71).
func _prepare_bag() -> void:
	var bag := outlet("iceBag")
	if bag == null or not (bag is Sprite2D):
		return
	_bag = bag as Sprite2D
	if _bag.texture != null and not _bag.centered:
		var half := _bag.texture.get_size() * 0.5
		_bag.offset = -half
		_bag.position += half * _bag.scale
	_bag.rotation = REST_ROTATION


## startAccelerometer on a (re)appearance. The tilt filter is a static in the
## original (flt_7A9178), so the bag follows the phone again at once. PORT
## CHOICE: with the hold remap nothing is held when the screen
## comes back, so the bag stands at rest -- set directly, not tweened, so
## isPouring cannot read a leftover tilt on the first loop tick.
func _rest_bag() -> void:
	if _bag == null:
		return
	if _tilt_tween != null and _tilt_tween.is_valid():
		_tilt_tween.kill()
	_pouring = false
	_bag.rotation = REST_ROTATION


## machineLid starts on UIKit's default anchor, its centre.
func _prepare_lid() -> void:
	var lid := outlet("machineLid")
	if not (lid is Sprite2D) or (lid as Sprite2D).texture == null:
		return
	_lid = lid as Sprite2D
	_lid.centered = false
	_lid_pivot = Vector2.ZERO
	_lid.offset = Vector2.ZERO
	_set_lid_anchor(_lid.texture.get_size() * 0.5)


## setAnchorPoint:forView: (0x6ED00): move the pivot without moving the
## picture -- position += T(new) - T(old) through the view's transform.
func _set_lid_anchor(pivot: Vector2) -> void:
	if _lid == null:
		return
	_lid.position += ((pivot - _lid_pivot) * _lid.scale).rotated(_lid.rotation)
	_lid.offset = -pivot
	_lid_pivot = pivot


## A transform change outside an animation block: any swing still running
## is cut to its model value first.
func _rotate_lid_now(by: float) -> void:
	if _lid == null:
		return
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()
	_lid_model_rotation += by
	_lid.rotation = _lid_model_rotation


## viewDidLoad (0x6F454, call 0x6F86E): the snow emitter on the nib's
## crushedIce view.
func _build_snow() -> void:
	var host := outlet("crushedIce")
	if host == null or host == self:
		return
	_snow = SSEmitter.attach(host, SSEmitterConfigs.frame_size(SNOW)) as SSEmitter
	SSEmitterConfigs.apply(_snow, SNOW, null)


## The crush button fires on touchDown, not on release; Screen.gd only wires
## `pressed`, so hook button_down/button_up on the same node ourselves.
func _wire_crush_button() -> void:
	for action in Bindings.actions(screen_name):
		if action.get("selector", "") != "crushIce:":
			continue
		var node := get_node_or_null(NodePath(action.get("node", "")))
		if node is BaseButton:
			var b := node as BaseButton
			if not b.button_down.is_connected(_crush_press):
				b.button_down.connect(_crush_press)
			if not b.button_up.is_connected(_crush_release):
				b.button_up.connect(_crush_release)
		return


# Screen.gd wires both selectors to `pressed` (release); the hold semantics
# live in _crush_press/_crush_release, so these stay as intentional no-ops.
func _on_crushIce() -> void:
	pass


func _on_stopCrushingIce() -> void:
	pass


# -- phase 1: pour ------------------------------------------------------

## The tilt stand-in: press anywhere the GUI does not take (buttons, the
## badge) to tip the bag, release to stand it up. The accelerometer keeps
## driving the bag until it is hidden at the lid close (stopAccelerometer only
## runs on next/back/disappear), so the hold does too. The release is taken in
## _input so it is seen even when the cursor is over a button by then.
func _unhandled_input(event: InputEvent) -> void:
	if _lid_closing or _done:
		return
	if event is InputEventMouseButton \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and (event as InputEventMouseButton).pressed:
		_set_pouring(true)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
			and not (event as InputEventMouseButton).pressed:
		_set_pouring(false)


## `_pouring` is the held tilt; the original's isPouring is derived from the
## bag's actual rotation each loop tick (see _is_pouring). Nothing here
## dismisses the instruction: on this screen only showNextButton (0x71804)
## hides instIV (the port used to hide it on the first pour).
var _tilt_tween: Tween


func _set_pouring(value: bool) -> void:
	if _pouring == value or _bag == null:
		return
	_pouring = value
	if _tilt_tween != null and _tilt_tween.is_valid():
		_tilt_tween.kill()
	_tilt_tween = create_tween()
	_tilt_tween.tween_property(_bag, "rotation",
		POUR_ROTATION if value else REST_ROTATION, TILT_SECONDS) \
		.set_trans(Tween.TRANS_SINE)


## isPouring as accelerometer:didAccelerate: computes it (0x71AA8).
func _is_pouring() -> bool:
	return _bag != null and _bag.rotation <= POUR_THRESHOLD


func _process(delta: float) -> void:
	if _done:
		return
	if _crushing:
		_crush_accum += delta
		while _crush_accum >= CRUSH_TICK and not _done:
			_crush_accum -= CRUSH_TICK
			_pile_tick()
		return
	# The original's loop timer keeps firing until the crush completes; once
	# the lid has started closing its donePouring block is fenced off by the
	# INT_MIN sentinel written into iceCubeCount. _lid_closing plays that role.
	if _lid_closing:
		return

	_loop_accum += delta
	if _loop_accum < LOOP_INTERVAL:
		return
	_loop_accum -= LOOP_INTERVAL
	# One `loop` tick (0x70128). The bag is not forced upright when the pour
	# completes: it keeps following the tilt (the hold) until the lid phase
	# hides it.
	if _is_pouring() and not _done_pouring:
		_pour_time += POUR_TIME_STEP
		_spawn_cube()
		if _pour_time >= POUR_TIME_DONE:
			_done_pouring = true
	if _done_pouring and _cubes_in_flight <= 0:
		_begin_lid_close()


func _bag_center() -> Vector2:
	return _bag.position if _bag != null else Vector2(161.5, 71)


func _spawn_cube() -> void:
	var tex := _tex("sc_ice_cube.png")
	if tex == null or _bag == null:
		return
	var cube := Sprite2D.new()
	cube.texture = tex
	var c := _bag_center()
	cube.position = c
	# insertSubview:belowSubview:iceBag
	var parent := _bag.get_parent()
	parent.add_child(cube)
	parent.move_child(cube, _bag.get_index())
	_cubes_in_flight += 1

	var p0 := c + CUBE_START_OFF
	var cp := Vector2(CUBE_CTRL_X, c.y + CUBE_START_OFF.y)
	# kCAAnimationPaced: constant speed along the path.
	var path := Curve2D.new()
	path.bake_interval = 1.0
	path.add_point(p0, Vector2.ZERO, cp - p0)
	path.add_point(CUBE_END, cp - CUBE_END, Vector2.ZERO)
	var length := path.get_baked_length()
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(cube, "rotation", CUBE_SPIN_RAD, CUBE_SECONDS)
	tw.tween_method(func(t: float) -> void:
		if is_instance_valid(cube):
			cube.position = path.sample_baked(t * length),
		0.0, 1.0, CUBE_SECONDS)
	tw.chain().tween_callback(_cube_landed.bind(cube))


## animationDidStop ("Rotate_Cube", 0x71A10): play ice.mp3, remove the cube,
## decrement the in-flight count.
func _cube_landed(cube: Sprite2D) -> void:
	Audio.play("ice")
	if is_instance_valid(cube):
		cube.queue_free()
	_cubes_in_flight -= 1


# -- phase 2: lid -------------------------------------------------------

func _begin_lid_close() -> void:
	if _lid_closing:
		return
	_lid_closing = true
	change_instruction("inst_grind.png")    # cfstr 0x6BACD4
	if _bag != null:
		_bag.visible = false

	# setAnchorPoint:(8/w, (h-16)/h) -- read from `frame`, which for the lid
	# at 0 or pi is its own 123x83 box either way -- then Close_Lid rotates
	# the transform by -pi from wherever it is.
	if _lid != null:
		_set_lid_anchor(LID_HINGE)
		if _lid_tween != null and _lid_tween.is_valid():
			_lid_tween.kill()
		_lid_model_rotation -= PI
		_lid_tween = create_tween()
		_lid_tween.tween_property(_lid, "rotation", _lid_model_rotation,
			LID_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	# performSelector:afterDelay:0.9 -- never cancelled, so it sounds even if
	# the screen was covered in the meantime (a SceneTreeTimer does too).
	get_tree().create_timer(LID_SOUND_DELAY).timeout.connect(
		func() -> void: Audio.play("sc_lid"))
	# loop (0x70128) sets readyToCrush = 1 in the same pass that starts the
	# lid animation -- the button works while the lid is still swinging
	# (the port used to wait out the 1.0 s swing).
	_ready_to_crush = true


## initWithNibName: / viewWillAppear: -- the hidden ice pile in its clipping
## box above the machine.
func _build_pile() -> void:
	var tex := _tex(PILE_ART)
	if tex == null:
		return
	var box := Control.new()
	box.name = "icePileBox"
	box.position = PILE_CONTAINER.position
	box.size = PILE_CONTAINER.size
	box.clip_contents = true
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var machine := outlet("machine")
	add_child(box)
	if machine != null and machine != self:
		move_child(box, (machine as Node).get_index() + 1)   # insertSubview:aboveSubview:machine
	_pile = Sprite2D.new()
	_pile.texture = tex
	_pile.centered = false
	_pile_y = tex.get_size().y                              # parked below the box
	_pile_target_y = PILE_TARGET_MARGIN                     # centre - h + 8, as a top edge
	_pile.position = Vector2(0, _pile_y)
	box.add_child(_pile)


## icePileLoop (0x707FC): one tick.
func _pile_tick() -> void:
	_pile_y -= 1.0
	if _pile != null:
		_pile.position.y = _pile_y
	if _pile_y <= _pile_target_y:
		_finish_crush()


# -- phase 3: crush -----------------------------------------------------

## crushIce: (0x70C38), touch-down, only if readyToCrush and not
## doneCrushingIce: big_red_button, [crushedIce start], a fresh 0.1 s
## icePileTimer, blend_loop looped.
func _crush_press() -> void:
	if not _ready_to_crush or _done:
		return
	Audio.play("big_red_button")
	if _snow != null:
		_snow.start()
	_crushing = true
	_crush_accum = 0.0
	Audio.loop("blend_loop")


## stopCrushingIce: (0x70D90), touch-up, same guard: icePileTimer
## invalidated, [crushedIce stop], blend_loop stopped.
func _crush_release() -> void:
	_stop_crushing_ice()


func _stop_crushing_ice() -> void:
	if not _ready_to_crush or _done:
		return
	_crushing = false
	if _snow != null:
		_snow.stop()
	Audio.stop("blend_loop")


## icePileLoop's arrival branch: stopCrushingIce: (still before
## doneCrushingIce, so its guard passes and the snow stops), doneCrushingIce,
## showNextButton, cc_sugar_ding, both timers invalidated.
func _finish_crush() -> void:
	_stop_crushing_ice()
	_crushing = false
	_done = true
	show_next_button()
	Audio.play("cc_sugar_ding")


## backClick: (0x70E38): click, blend_loop stopped, icePileTimer invalidated,
## [crushedIce stop], stopAccelerometer, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Audio.stop("blend_loop")
	_crushing = false
	if _snow != null:
		_snow.stop()
	Nav.back()


## nextClick: (0x70F1C) -- click sound, stop the crush loop, [crushedIce
## stop], stopAccelerometer, push a NEW scScoopIce. No done-gate in the
## method itself; the button is hidden by changeInstruction: until
## showNextButton, and the skip badge calls it too.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Audio.stop("blend_loop")
	if _snow != null:
		_snow.stop()
	Nav.next()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


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
	# insertSubview:aboveSubview:instIV -- above the banner, below the nib's
	# next/back/crush buttons.
	var inst := outlet("instIV")
	if inst != null and inst != self and inst.get_parent() == self:
		move_child(b, inst.get_index() + 1)
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
