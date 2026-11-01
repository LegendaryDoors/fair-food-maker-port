# Curly Fries step 5 -- tip the bowl of raw slices into the hot oil, then
# watch the pile fry.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithInfoDict: 0x1412D8, viewDidLoad 0x14130C, viewWillAppear:
#   0x141968, viewDidAppear: 0x141C08 (bare super), viewWillDisappear:
#   0x141C34, backClick: 0x141D68, nextClick: 0x141E1C, resetClick: 0x141F2C,
#   grateTick 0x142610, animationDidStop: 0x142B1C, pourTick 0x142B70,
#   countTick 0x142CE0, bubbleTickForIndex: 0x1431A8,
#   accelerometer:didAccelerate: 0x143440, startAccelerometer 0x143718
#   (delegate + 1/30s -- live, scheduled 0.5s after viewWillAppear).
#   changeInstruction: 0x142E28 / showNextButton 0x143018 are the standard
#   +500/0.25s slide, run locally because this screen has no scene bindings.
#
# LAYOUT: the scene is generated from the nib and carries cff_background
# (0,0,320,500), fc_fryer (0,40,320,391), oilIV = fc_oil (22,91,275,275),
# fryer (22,91,275,275), fryed (22,93,275,275) -- 2px lower, as shipped --
# fryerContainer = cff_bowl (200,25,106,128), instIV inst_pour
# (102,416,218,59), backButton (0,416,94,63) and nextButton (226,414,94,63);
# all UIImageView / UIButton (true frames), and the shared fc_* fryer art is
# the nib's own choice, not a port substitution. The scene bindings wire
# backClick: / nextClick:. Extraction gaps compensated in _build_layout:
#   * backButton / nextButton used to lose their btn_back / btn_next art
#     (UIButton background images the extractor dropped); the scene now
#     carries it and the null-guarded assignment here is a fallback;
#   * fryer / fryed have no image in the nib (the infoDict supplies them), so
#     the generated Sprite2Ds are bare centred nodes -- re-anchored top-left
#     when their textures are assigned;
#   * fryerContainer is replaced in place by a code-built node, because
#     viewDidLoad reframes it, adds the BowlPile image inside and scales the
#     whole thing about its centre; the nib's 106x128 sprite is only the
#     resting placeholder.
#
# Mechanic, as read -- a tilt pour of SLICES (same shape as the water
# screen's, different clamps): viewDidLoad reframes fryerContainer to
# (nib.x - 90, nib.y - 20, 229, 192) -- literal pool 0x141874 = -90.0, the
# port had -88 -- i.e. cff_bowl's natural size, adds the infoDict BowlPile
# image inside it and scales the whole container 0.5, so its centre lands at
# (224.5, 101). The accelerometer clamps the rotation to [-1.4835, -0.2618]
# and pours while angle <= -1.3962634 AND pourTime < 4.0 (0x143440;
# transform = scale(0.5) concat rotation). pourTick (0.1s) adds 0.1f, calls
# grateTick -- one falling half-scale Slice_Image per tick -- and fades the
# raw pile in at pourTime * 0.25. pourTime and count are FLOATS: 0.1f summed
# reaches 4.0 on the 41st tick (4.0999985), 0.025f reaches 1.0 on the 41st
# (1.0249996) -- one tick more than double arithmetic gives, so the port
# accumulates in float32 too (41 slices, 4.1s pour; 5.125s crossfade). At
# 4.0 the accelerometer stops, instIV hides and a 0.125s countTick
# crossfades fryed/fryer by 0.025 per tick, hiding the bowl on its first
# tick; count >= 1.0 shows next.
#
# grateTick's slice path (0x142610) starts at y = fryerContainer.center.X
# - 70 + rand%10 (the X, not the y): disassembly 0x142A1C..0x142A28 loads
# [sp+0x20], the first float of the CGPoint. Original bug, kept: slices
# appear at y ~155-165, just under the bowl, and fall 100px into the oil.
# (The port used centre.y and dropped them over the bowl itself.) x =
# centre.x - 30 + (rand%5) * signed.
#
# Before startAccelerometer (0.5s after viewWillAppear) the container's
# transform is viewDidLoad's bare scale(0.5): the bowl sits level until the
# first accelerometer sample clamps it to the -0.2618 rest tilt.
#
# As everywhere in the port, the tilt becomes press-and-hold on the bowl
# (0.35s tilt time is the port choice, kc precedent; every clamp, threshold
# and tick count is the original's). The 0.5s startAccelerometer delay is
# kept as arming.
#
# Oil bubbles: 16 SpriteSheetViews over fc_fry_bubble1-4.png (62x62 frames
# over the 248x68 strip, transform-scaled 0.5), each on its own reschedule
# chain (0x1431A8): hidden -> place at oil.origin + 25 + rand % (dim - 50)
# per axis, show, tick every 0.1s; after the 4-frame cycle hide and come
# back in 0.1 + (rand % 25)/100 s. Initial stagger (rand % 100)/100
# (0x14319C block in viewDidLoad).
#
# QUIRK kept: viewWillAppear calls resetClick:, which (unlike fc's) plays no
# sound -- it just restarts frying_lo_loop and re-arms the screen.
# Not ported (IAP): buyAllBtn (suppressed) and productPurchased: 0x14217C.
#
# KEEP-STATE: kept alive under the push to cffDustSalt.
# viewDidLoad's layout and bubbles are built once; viewWillAppear: (resetClick,
# alphas, pour timer, 0.5s arming) runs on entry and in on_resume. on_exit =
# viewWillDisappear:. The bubble chains run on while covered.

extends "res://core/Screen.gd"

const cffSelectSlicer := preload("res://screens/cffSelectSlicer.gd")


## Round to IEEE single: pourTime / count are float ivars, and the binary's
## float sums cross their thresholds one tick later than doubles (header).
static func _f32(x: float) -> float:
	return PackedFloat32Array([x])[0]

const POUR_STEP_F32 := 0.10000000149011612   # 0.1f (0x3DCCCCCD)
const COUNT_STEP_F32 := 0.02500000037252903  # 0.025f

## Nib: oil / fryer at (22,91,275,275); fryed 2px lower.
const OIL_RECT := Rect2(22, 91, 275, 275)
const FRYED_POS := Vector2(22, 93)
## Nib UIButtonContent art the extractor drops (header).
const BUTTON_ART := {"backButton": "btn_back.png", "nextButton": "btn_next.png"}
## viewDidLoad (0x14130C): container frame (200-90, 25-20, 229, 192)
## (0xC2B40000 / -20.0; cff_bowl.png is 229x192), then scale 0.5 -- centre
## (224.5, 101).
const CONTAINER_FRAME := Rect2(110, 5, 229, 192)
const CONTAINER_SCALE := 0.5
## accelerometer (0x143440): clamp [-1.4835, -0.2618]; pour while
## angle <= -1.3962634 and pourTime < 4.0.
const REST_ROTATION := -0.2618
const POUR_ROTATION := -1.4835
const POUR_THRESHOLD := -1.3962634
const POUR_FULL := 4.0
## PORT CHOICE: hold-tilt time (kc precedent).
const TILT_SECONDS := 0.35
const ARM_DELAY := 0.5
## pourTick 0.1s (0x3FB99999A0000000); raw pile alpha = pourTime * 0.25.
## The per-tick increment is POUR_STEP_F32 (0.1f), not this interval.
const POUR_TICK_S := 0.1
const FRYER_ALPHA_K := 0.25
## countTick 0.125s / 0.025 per tick (0x142CE0).
const COUNT_TICK_S := 0.125
const COUNT_STEP := 0.025                  # as 0.025f: COUNT_STEP_F32
## grateTick slice path (0x142610): x = centre.x - 30 + (rand%5) * signed,
## y from centre.X - 70 (0xC28C0000) + rand%10 (header), falling +100
## (0x42C80000) over 1.0s.
const SLICE_X_OFF := -30.0
const SLICE_Y_OFF := -70.0
const SLICE_FALL := 100.0
const SLICE_SECONDS := 1.0
## Bubbles (0x14130C / 0x1431A8).
const BUBBLE_COUNT := 16
const BUBBLE_CELL := Vector2(62, 62)
const BUBBLE_SCALE := 0.5
const BUBBLE_INSET := 25.0
const BUBBLE_SHRINK := 50.0
const BUBBLE_TICK_S := 0.1

var _info: Dictionary = {}
var _view: Node2D                # the nib's root view; code-built nodes go here
var _oil: Sprite2D
var _fryer: Sprite2D
var _fryed: Sprite2D
var _container: Node2D
var _next_btn: TextureButton
var _holding := false
var _armed := false
var _pouring := false            # isPouringKernels
var _pour_time := 0.0
var _count := 0.0
var _done_pouring := false       # isPouringDone
var _pour_timer: Timer
var _fry_timer: Timer
var _bubbles: Array[Sprite2D] = []
var _arm_gen := 0
## The SceneTree, kept for timers that must fire while this screen is parked
## out of the tree (Nav keep-state): get_tree() is null then.
var _tree: SceneTree
var _bubble_idx: Array[int] = []


## UINavigationController keeps this controller alive under the push to
## cffDustSalt; Nav calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## initWithInfoDict: (0x1412D8) + viewDidLoad (0x14130C) once, then
## viewWillAppear: (0x141968).
func on_enter() -> void:
	_tree = get_tree()
	_info = cffSelectSlicer.info_or_default(GameState.custom_categories)
	var v := outlet("view")
	_view = v as Node2D if v is Node2D else self
	_build_layout()
	_build_bubbles()
	_pour_timer = Timer.new()
	_pour_timer.wait_time = POUR_TICK_S
	_pour_timer.timeout.connect(_pour_tick)
	add_child(_pour_timer)
	set_process(true)
	_will_appear()


## Back from cffDustSalt: viewWillAppear: runs again and RESETS the step --
## resetClick: restarts frying_lo_loop, the bowl comes back (with whatever
## transform it was frozen at), fryer / fryed go to alpha 0, pour time and
## count to 0, next hidden, the pour timer and the 0.5s arming rescheduled.
## The oil bubbles never stopped (their performSelector chains run on while
## covered; see _schedule_bubble).
func on_resume() -> void:
	_will_appear()


## viewWillAppear: (0x141968): resetClick, flags, alphas, timers.
func _will_appear() -> void:
	_on_resetClick()
	_done_pouring = false
	_container.visible = true
	_fryer.modulate.a = 0.0
	_fryed.modulate.a = 0.0
	if _next_btn != null:
		_next_btn.visible = false
	_pour_time = 0.0
	_count = 0.0
	change_instruction("inst_pour.png")        # instIV setHidden:NO + slide
	# startAccelerometer after 0.5s (performSelector:afterDelay:, cancelled
	# by viewWillDisappear: -- the generation check below); its first sample
	# snaps the bowl from level to the rest clamp.
	_arm_gen += 1
	var gen := _arm_gen
	get_tree().create_timer(ARM_DELAY).timeout.connect(func() -> void:
		if gen != _arm_gen:
			return
		_armed = true
		if not _done_pouring and not _holding:
			_container.rotation = REST_ROTATION)
	_pour_timer.start()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## Static views come from the scene. This adopts them, fills the extraction
## gaps (header) and builds what viewDidLoad (0x14130C) builds.
func _build_layout() -> void:
	_oil = outlet("oilIV") as Sprite2D
	_fryer = _adopt_pile("fryer", str(_info.get("Fryer_RawPile_Image", "")),
		OIL_RECT.position)
	_fryed = _adopt_pile("fryed", str(_info.get("Fryer_FriedPile_Image", "")),
		FRYED_POS)

	# fryerContainer: cff_bowl + the BowlPile image inside, on a centre
	# pivot so the rotation matches UIKit's about-centre transform. Takes the
	# nib placeholder's z-slot, then the placeholder goes.
	_container = Node2D.new()
	_container.position = CONTAINER_FRAME.get_center()
	_container.scale = Vector2(CONTAINER_SCALE, CONTAINER_SCALE)
	_container.rotation = 0.0                  # viewDidLoad: scale only
	_view.add_child(_container)
	var placeholder := outlet("fryerContainer")
	if placeholder != null and placeholder != self \
			and placeholder.get_parent() == _view:
		_view.move_child(_container, placeholder.get_index())
		placeholder.queue_free()
	var bowl := Sprite2D.new()
	bowl.texture = _tex("cff_bowl.png")
	bowl.centered = false
	bowl.position = -CONTAINER_FRAME.size * 0.5
	_container.add_child(bowl)
	var pile := Sprite2D.new()                 # addSubview at (0,0)
	pile.texture = _tex(str(_info.get("BowlPile_Image", "")))
	pile.centered = false
	pile.position = -CONTAINER_FRAME.size * 0.5
	_container.add_child(pile)

	for outlet_name: String in BUTTON_ART:
		var b := outlet(outlet_name)
		if b is TextureButton and (b as TextureButton).texture_normal == null:
			var tb := b as TextureButton
			tb.texture_normal = _tex(BUTTON_ART[outlet_name])
			tb.ignore_texture_size = true
			tb.stretch_mode = TextureButton.STRETCH_SCALE
	_next_btn = outlet("nextButton") as TextureButton
	if _next_btn == null:
		push_error("cffFrySlice: no nextButton outlet -- scene not regenerated?")
	else:
		_next_btn.visible = false


## fryer / fryed ship without an image (the infoDict supplies it), so the
## generated nodes are bare centred sprites: texture, anchor and position
## come from here.
func _adopt_pile(outlet_name: String, file: String, top_left: Vector2) -> Sprite2D:
	var s := outlet(outlet_name) as Sprite2D
	if s == null:
		push_error("cffFrySlice: no %s outlet -- scene not regenerated?" % outlet_name)
		s = Sprite2D.new()
		_view.add_child(s)
	s.texture = _tex(file)
	s.centered = false
	s.position = top_left
	return s


## resetClick: (0x141F2C) -- no button sound in this one, as read.
func _on_resetClick() -> void:
	Audio.stop("frying_lo_loop")
	Audio.stop("frying_hi_loop")
	Audio.loop("frying_lo_loop")
	if _next_btn != null and _next_btn.visible:
		_next_btn.visible = false
		change_instruction("inst_pour.png")


# -- input: press-and-hold on the bowl (PORT CHOICE) --------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		var half := CONTAINER_FRAME.size * CONTAINER_SCALE * 0.5
		if _armed and not _done_pouring and _container.visible \
				and Rect2(_container.position - half, half * 2.0) \
				.has_point(mb.position):
			_set_holding(true)
			get_viewport().set_input_as_handled()
	elif _holding:
		_set_holding(false)


func _set_holding(value: bool) -> void:
	if _holding == value:
		return
	_holding = value
	create_tween().tween_property(_container, "rotation",
		POUR_ROTATION if value else REST_ROTATION, TILT_SECONDS) \
		.set_trans(Tween.TRANS_SINE)


## The accelerometer body's pour gate (0x143440), run per frame.
func _process(_delta: float) -> void:
	var now := _container.rotation <= POUR_THRESHOLD \
		and _pour_time < POUR_FULL
	if now and not _pouring:
		Audio.loop("pouring_loop")
	elif not now and _pouring:
		Audio.stop("pouring_loop")
	_pouring = now


## pourTick (0x142B70).
func _pour_tick() -> void:
	if _pour_time <= POUR_FULL and _pouring:
		_pour_time = _f32(_pour_time + POUR_STEP_F32)
		_grate_tick()
		_fryer.modulate.a = clampf(_pour_time * FRYER_ALPHA_K, 0.0, 1.0)
	if _pour_time >= POUR_FULL and not _done_pouring:
		_done_pouring = true
		_pour_timer.stop()
		Audio.stop("pouring_loop")             # stopAccelerometer side
		_armed = false                         # stopAccelerometer
		dismiss_instruction()
		if _fry_timer == null:
			_fry_timer = Timer.new()
			_fry_timer.wait_time = COUNT_TICK_S
			_fry_timer.timeout.connect(_count_tick)
			add_child(_fry_timer)
		_fry_timer.start()


## grateTick (0x142610): one half-scale slice falls out of the bowl.
func _grate_tick() -> void:
	var t := _tex(str(_info.get("Slice_Image", "")))
	if t == null:
		return
	var chip := Sprite2D.new()
	chip.texture = t
	chip.scale = Vector2(0.5, 0.5)
	chip.rotation = cffSelectSlicer.rand_chip_angle()
	_view.add_child(chip)
	_view.move_child(chip, _container.get_index() + 1)   # above the container
	# Both coordinates come from the container's centre X (header).
	var cx := _container.position.x
	var start := Vector2(
		cx + SLICE_X_OFF + float(randi() % 5) * cffSelectSlicer.rand_signed(),
		cx + SLICE_Y_OFF + float(randi() % 10))
	chip.position = start
	var tw := create_tween().set_parallel(true)
	tw.tween_property(chip, "position:y", start.y + SLICE_FALL,
		SLICE_SECONDS).set_trans(Tween.TRANS_LINEAR)     # kCAAnimationPaced
	# "RotateKernel" (curve 1, ease-in) to a second random angle, shorter arc.
	tw.tween_property(chip, "rotation",
		cffSelectSlicer.shortest_target(chip.rotation,
			cffSelectSlicer.rand_chip_angle()), SLICE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(chip):
			chip.queue_free())


## countTick (0x142CE0): the crossfade to the fried pile (41 ticks, 5.125s).
func _count_tick() -> void:
	_count = _f32(_count + COUNT_STEP_F32)
	# UIView clamps alpha to [0,1]; the last tick writes 1.025 / -0.025.
	_fryed.modulate.a = clampf(_count, 0.0, 1.0)
	_fryer.modulate.a = clampf(1.0 - _count, 0.0, 1.0)
	if _container.visible:
		_container.visible = false
	if _count >= 1.0:
		_fry_timer.stop()
		show_next_button()


# -- bubbles (0x14130C / 0x1431A8) --------------------------------------

func _build_bubbles() -> void:
	var strip := _tex("fc_fry_bubble1-4.png")
	if strip == null or _oil == null:
		return
	for i in BUBBLE_COUNT:
		var b := Sprite2D.new()
		b.texture = strip
		b.region_enabled = true
		b.region_rect = Rect2(Vector2.ZERO, BUBBLE_CELL)
		b.scale = Vector2(BUBBLE_SCALE, BUBBLE_SCALE)
		b.visible = false
		_view.add_child(b)
		_view.move_child(b, _oil.get_index() + 1)    # insertSubview:aboveSubview:oil
		_bubbles.append(b)
		_bubble_idx.append(0)
		_schedule_bubble(i, float(randi() % 100) / 100.0)


## performSelector:withObject:afterDelay: -- NOT cancelled by
## viewWillDisappear: (it cancels only startAccelerometer), so each chain
## keeps running while the screen is covered, as the original's did. Timers
## come from the kept SceneTree reference because get_tree() is null while
## Nav has the screen parked; a popped (freed) screen drops its connections.
func _schedule_bubble(i: int, delay: float) -> void:
	_tree.create_timer(delay).timeout.connect(func() -> void:
		if is_instance_valid(_bubbles[i]):
			_bubble_tick_for(i))


## bubbleTickForIndex: (0x1431A8).
func _bubble_tick_for(i: int) -> void:
	var b := _bubbles[i]
	if not b.visible:
		var span := maxi(int(OIL_RECT.size.x - BUBBLE_SHRINK), 1)
		b.position = Vector2(
			OIL_RECT.position.x + BUBBLE_INSET + float(randi() % span),
			OIL_RECT.position.y + BUBBLE_INSET + float(randi() % span))
		b.visible = true
		_schedule_bubble(i, BUBBLE_TICK_S)
		return
	# SpriteSheetView tick (0x47910): show the current cell, then advance.
	b.region_rect = Rect2(
		Vector2(BUBBLE_CELL.x * (_bubble_idx[i] % 4), 0), BUBBLE_CELL)
	_bubble_idx[i] = (_bubble_idx[i] + 1) % 4
	if _bubble_idx[i] == 0:
		b.visible = false
		_schedule_bubble(i, BUBBLE_TICK_S + float(randi() % 25) / 100.0)
	else:
		_schedule_bubble(i, BUBBLE_TICK_S)


## nextClick: (0x141E1C): sound, both fry loops off, push cffDustSalt with
## the same infoDict. Wired by the scene bindings.
## The infoDict is re-published from this controller's own copy (a later
## screen's bake may have replaced GameState.custom_categories while this
## one was covered); the push is a NEW cffDustSalt (animated:NO).
func _on_nextClick() -> void:
	Audio.play("button_press")
	Audio.stop("frying_hi_loop")
	Audio.stop("frying_lo_loop")
	GameState.custom_categories = _info.duplicate()
	Nav.next()


## backClick: (0x141D68): button_press, both fry loops off, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Audio.stop("frying_lo_loop")
	Audio.stop("frying_hi_loop")
	Nav.back()


## viewWillDisappear: (0x141C34): cancel the pending startAccelerometer,
## the three loops off, pour / fry timers invalidated, stopAccelerometer.
## The bubbles' perform chains are not cancelled (see _schedule_bubble).
func on_exit() -> void:
	_arm_gen += 1
	Audio.stop("frying_hi_loop")
	Audio.stop("frying_lo_loop")
	Audio.stop("pouring_loop")
	for t in [_pour_timer, _fry_timer]:
		if t != null:
			(t as Timer).stop()
	_armed = false                             # stopAccelerometer
	if _holding:
		_set_holding(false)
