# Cotton candy step 3 -- drag the stick around the spinning tub, sweeping up
# 26 tinted sugar wisps; the candy on the stick grows and takes their colours.
#
# GROUNDED from viewDidLoad (0x7E000, tail disassembled 0x7E400..0x7EDF8),
# initWithDictionary: (0x7DD54), viewWillAppear: (0x7DDA8), viewDidAppear:
# (0x7DF74), viewWillDisappear: (0x7DEC8), touchesBegan/Moved:withEvent:
# (0x7F6F0 / 0x7F938), grabCottonCandyParticles (0x7D2C4, tail disassembled),
# getCCContainerTip (0x7CAC4), getCurrentDirectionInDegrees (0x7C9F0),
# getNewPointFromAngle:distanceFromOrigin: (0x7C710),
# getCCParticleDistanceFromOrigin: (0x7D8F8, table 0x682AC4),
# getCCParticleImgString: (0x7D860), addCottonCandyParticle:pt:angle:
# tintColor: (0x7D948), addCottonCandyParticles:frequency: (0x7DAE0),
# rotateUIImage:angle: (0x7D648), colorCottonCandyOnStick: (0x7CE00),
# getNewAlpha:ccParticleColor:isFirstGrab:colorOrderIndex: (0x7CCF4,
# disassembled), isFirstTimeGrabbingColor: (0x7CB98), getOrderFromColor:
# (0x7CC34), getCottonCandyColorIndex: (0x7CB00), removeDuplicateColors:
# (0x7C488), runSpinAnimationOnView:... (0x7C5F8),
# hasFinishedGrabbingAllCottonCandyParticles (0x7C818), nextClick: (0x7EFA8),
# backClick: (0x7F670) and skipClick: (0x7F6E0).
#
# This is NOT an accelerometer screen and there is no hold-to-spin remap to
# make: the original drives everything from touchesBegan/Moved. The stick
# container's centre is set to the raw touch point, its rotation follows the
# angle from the tub's hub to that point, and each event sweeps a 30x30 box
# around the touch for wisps. scaleCottonCandiesOnStick (0x7EFA4) is an empty
# `bx lr` -- growth happens inline in the touch handlers.
#
# Every wisp and every candy layer is a TintedIV with blend mode 3 (overlay);
# their colours are baked with ccSugarTint, the port of -[TintedIV
# changeColor:] (0x47304), not a plain modulate, which cannot reproduce
# these blend modes. Kept under Make, with viewWillDisappear:'s teardown and
# no instruction slide.

extends "res://core/Screen.gd"

const ccSugarTint := preload("res://screens/ccSugarTint.gd")

# -- the tub -----------------------------------------------------------

## ccMachineMiddle (cc_spinner_center, nib frame (88,168,144,144)); every
## particle position and the stick direction measure from its centre.
const MIDDLE_CENTER := Vector2(160, 240)
## runSpinAnimationOnView:ccMachineMiddle duration:1 rotations:4 repeat:0
## repeatForever:YES (call site 0x7EC7E: r3=0x3f800000, sp0=0x40800000,
## sp8=1). toValue = 2*pi*rotations*duration (DAT_0007c708 = 6.2831853),
## cumulative, forever -- a constant 4 rev/s.
const SPIN_ROTATIONS_PER_SECOND := 4.0

# -- the wisps (0x7DAE0 / 0x7D8F8 / 0x7D860) ---------------------------

## Three rings: (ring id, count). Angles are i * (360 / count) degrees.
const RINGS := [[0, 4], [1, 12], [2, 10]]
## Ring 1 -> 100 (DAT_0007d940); ring 2 -> 123 (DAT_0007d944); ring 0 draws
## from the float table at 0x682AC4: {75, 100, 123}, arc4random() % 3.
const RING0_DISTANCES := [75.0, 100.0, 123.0]
const RING1_DISTANCE := 100.0
const RING2_DISTANCE := 123.0
## Ring 0: cc_inner_01..05; ring 1: cc_center_01..05; ring 2: cc_outer_01..08
## (rand%5+1, rand%5+1, (rand&7)+1).
const RING_ART := {0: ["cc_inner_0%d", 5], 1: ["cc_center_0%d", 5],
	2: ["cc_outer_0%d", 8]}
## Wisp i of each ring takes selectedColors[i] while i < count-1; the rest
## are arc4random() % count (0x7DAE0).
## Grab box: tip +/- 15, i.e. CGRect(tip-15, tip-15, 30, 30) (0xc1700000 /
## 0x41f00000, grabCottonCandyParticles 0x7D2C4); the "tip" is the stick
## container's centre, which the touch handlers pin to the touch point.
const GRAB_HALF := 15.0
## One grab fades the wisp out over 0.5s (setAnimationDuration: 0.5, no curve
## set -> UIViewAnimationCurveEaseInOut) and removes it from its superview at
## 0.7s (performSelector:afterDelay: 0x3fe6666660000000); only the FIRST wisp
## in the box goes per event (the fast enumeration at 0x7D4E8 is an `if`, it
## never loops back).
const GRAB_FADE := 0.5
const GRAB_REMOVE := 0.7

# -- the stick rig (viewDidLoad) ---------------------------------------

## The stick image arrives from StickSelect and is resized by 1/1.4
## (DAT_0007e740). Its container is a (w, 2h) UIView with frame origin
## (205, -50) (0x434d0000 / 0xc2480000); the stick occupies the container's
## bottom half (frame (0, h, w, h)), so the container centre -- the rotation
## pivot and the "tip" -- sits at the stick's top.
const STICK_SCALE := 1.0 / 1.4
const STICK_RIG_ORIGIN := Vector2(205, -50)
## ccsOnStickContainer (the candy blob, cc_comp art) is centred at
## (w/2, packOffset + h) in container coords = (0, packOffset) from the
## pivot. packID "0" -> 50 (DAT_0007e748), "1" -> 30 (DAT_0007ee1c),
## anything else -> 0 (DAT_0007ee18).
const PACK_BLOB_OFFSET := {"0": 50.0, "1": 30.0}
## Blob scale: 0 at load (CGAffineTransformScale args at 0x7EB62..0x7EB70 are
## literal zeros); each touch event sets it to grabbedFraction / 2.5
## absolutely (identity-then-scale, 0x7F6F0/0x7F938). Godot rejects a
## singular transform, so "zero" is an epsilon -- sub-pixel either way.
const BLOB_SCALE_DIVISOR := 2.5
const BLOB_SCALE_EPSILON := 0.001
## The blob stacks cc_comp01 untinted at the bottom, then cc_comp01..04 as
## the four colourable layers (viewDidLoad loop, i-1 for i in 2..5).
const BLOB_LAYER_COUNT := 4

## Direction from the hub to a point: atan2(dy,dx) * 180/pi - 90
## (DAT_0007cab0/b8/c0; the offset is -90.0). The container's rotation is
## that many degrees (deg->rad 0.0174533 at 0x7F928); the original also
## stores stickCurrentDirectionInDegrees = 180 - deg (0x7F930), which
## nothing reads back -- not carried.
const DIRECTION_OFFSET_DEG := -90.0

# -- the colouring (0x7CCF4 / 0x7CE00) ---------------------------------

## getNewAlpha bases: colour-order 0 -> 0.5 (0x7cdfc), later -> 0.25
## (0x7cdf8). First grab of a colour tints its layer(s) and returns the
## base; after that alpha = base + (1-base) * grabbed/total for that colour.
const ALPHA_BASE_FIRST := 0.5
const ALPHA_BASE_LATER := 0.25

## Fallback only: advancing with Nav.next() alone skips the
## screens' own hand-off, so custom_categories can arrive empty. The
## stand-ins are the
## originals' own defaults, not inventions: StickSelect's COTTON_CANDY
## starting pack is 1 (cones) with cc_cone17 at index 0, and the sugar
## screen's skipClick: (0x846B8) ships flavours 0, 1, 2 + purpleColor.
const FALLBACK_STICK := "cc_cone17"
const FALLBACK_PACK_ID := "1"
const FALLBACK_COLORS := [
	Color(1.0, 0.392157, 0.686275, 0.392157),   # classicpink
	Color(0.0, 0.490196, 1.0, 0.392157),        # classicblue
	Color(1.0, 1.0, 0.0, 0.392157),             # yellow
	Color(0.5, 0.0, 0.5, 1.0),                  # +[UIColor purpleColor]
]

var _selected_colors: Array = []       # deduped, order preserved (0x7C488)
var _color_totals: Array[int] = []     # selectedColorsCount
var _color_grabbed: Array[int] = []    # selectedColorsRunningCount
var _color_order: Array = []           # colorOrder: first-grab order
var _particles: Array = []             # {node, color}
var _total_particles := 0
var _rig: Node2D
var _stick_tex: Texture2D = null       # ccStickImgOrig, at natural size
var _blob: Node2D
var _blob_layers: Array = []           # {sprite, art: Texture2D, tint: Color}
var _tint_cache := {}                  # ccSugarTint bakes, by art + colour
var _middle: Sprite2D
var _touching := false
var _skipped_first_move := false       # didSkippedLastMove
var _shown_next := false               # hasShownNextButton
var _fading: Array = []                # {node, tween}: grabbed wisps fading out


func on_enter() -> void:
	# initWithDictionary: (0x7DD54) stores the infoDict StickSelect passed;
	# the port's carrier is GameState.custom_categories (colors from the
	# sugar picker; stickImg and packID from StickSelect).
	var info: Dictionary = GameState.custom_categories

	# viewDidLoad: selectedColors = removeDuplicateColors(parameters[colors]).
	# The original compares by pointer; its colours are shared UIColor
	# constants, so value equality here selects the identical set.
	var raw: Array = info.get("colors", FALLBACK_COLORS)
	_selected_colors.clear()
	for c in raw:
		if not _selected_colors.has(c):
			_selected_colors.append(c)
	_color_totals.clear()
	_color_grabbed.clear()
	for i in _selected_colors.size():
		_color_totals.append(0)
		_color_grabbed.append(0)
	_color_order.clear()

	_setup_middle_spin()
	_build_stick_rig(info)
	_build_particles()
	var n := outlet("nextButton")
	if n != null and n != self:
		n.set("disabled", true)    # alpha 0 comes from the nib
	_show_instruction_in_place()
	set_process(true)


## viewDidLoad: instIV setHidden:NO. This class has no changeInstruction:,
## so the banner just sits where the nib put it; undo the generic
## first-appearance slide Screen._place_instruction starts.
func _show_instruction_in_place() -> void:
	if _instruction_tween != null and _instruction_tween.is_valid():
		_instruction_tween.kill()
	var inst := _instruction_node()
	if inst == null:
		return
	if _instruction_home_set:
		inst.position = _instruction_home
	inst.visible = true


## Nav keeps this controller alive under
## MakeViewController, as the UINavigationController does.
func keeps_state_on_push() -> bool:
	return true


## Back from Make. viewWillAppear: (0x7DDA8) only writes the analytics
## defaults; viewDidAppear: (0x7DF74) starts cc_machine_on again. What
## viewWillDisappear: tore down stays torn down (see on_exit): no stick, no
## more grabbing; the next button is still up, and next bakes the same candy
## again (the layers outlive their removed container).
func on_resume() -> void:
	pass   # viewDidAppear:'s loop restarts in on_did_appear(), after the slide


## viewDidAppear: runs when the push / pop slide is over: the machine
## hum starts after the slide, as on the phone, on every appearance.
func on_did_appear() -> void:
	_view_did_appear()


## viewWillDisappear: (0x7DEC8), on the way to Make as much as on back:
##  * stopPlayerForFile cc_machine_on;
##  * cottonCandyParticles released and set to nil -- the wisp VIEWS stay on
##    screen, but no touch can grab one again (grabCottonCandyParticles
##    counts a nil array as empty);
##  * [ccStickContainer removeFromSuperview] -- the stick and the candy on it
##    vanish from this screen for good (nothing re-adds the container).
## A wisp still fading out is removed by its 0.7 s performSelector while
## Make is up; the port, whose tweens pause off-tree, removes it here.
func on_exit() -> void:
	Audio.stop("cc_machine_on")
	_touching = false
	_particles.clear()
	for f: Dictionary in _fading:
		var tw: Tween = f["tween"]
		if tw != null and tw.is_valid():
			tw.kill()
		var node: Variant = f["node"]
		if is_instance_valid(node):
			(node as Node).queue_free()
	_fading.clear()
	if _rig != null:
		# removeFromSuperview; hidden rather than detached so the layers stay
		# owned by the tree (nextClick: still reads them).
		_rig.visible = false


## viewDidAppear: (0x7DF74): cc_machine_on.m4a, loop forever, volume 0.25.
func _view_did_appear() -> void:
	Audio.loop("cc_machine_on", linear_to_db(0.25))


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


# -- construction -----------------------------------------------------

## The nib's ccMachineMiddle is a top-left sprite; re-anchor it so the spin
## happens about its centre, as a layer rotation does.
func _setup_middle_spin() -> void:
	var m := outlet("ccMachineMiddle")
	if m == null or m == self or not (m is Sprite2D):
		return
	_middle = m as Sprite2D
	if not _middle.centered:
		_middle.centered = true
		_middle.position += Vector2(_middle.texture.get_size()) * 0.5


## The stick rig: a pivot Node2D standing in for ccStickContainer. Frame
## (205, -50, w, 2h) -> pivot (centre) at (205 + w/2, -50 + h). The stick
## sprite hangs below the pivot; the blob centre sits packOffset below it.
## Inserted above ccSpinnerBG (the full-screen overlay with the tub cut-out).
func _build_stick_rig(info: Dictionary) -> void:
	var stick_tex: Texture2D = info.get("stickImg") \
		if info.get("stickImg") is Texture2D else null
	var pack_id: String = str(info.get("packID", FALLBACK_PACK_ID))
	if stick_tex == null:
		stick_tex = _tex(FALLBACK_STICK + ".png")
		pack_id = FALLBACK_PACK_ID
	_stick_tex = stick_tex
	var size := Vector2.ZERO if stick_tex == null \
		else Vector2(stick_tex.get_size()) * STICK_SCALE

	_rig = Node2D.new()
	_rig.position = STICK_RIG_ORIGIN + Vector2(size.x * 0.5, size.y)
	add_child(_rig)
	var bg := outlet("ccSpinnerBG")
	if bg != null and bg != self and bg.get_parent() == self:
		move_child(_rig, bg.get_index() + 1)

	if stick_tex != null:
		var stick := Sprite2D.new()
		stick.texture = stick_tex
		stick.centered = false
		stick.position = Vector2(-size.x * 0.5, 0)
		stick.scale = Vector2(STICK_SCALE, STICK_SCALE)
		_rig.add_child(stick)

	_blob = Node2D.new()
	_blob.position = Vector2(0, float(PACK_BLOB_OFFSET.get(pack_id, 0.0)))
	_blob.scale = Vector2(BLOB_SCALE_EPSILON, BLOB_SCALE_EPSILON)
	_rig.add_child(_blob)          # insertSubview:aboveSubview:ccStick

	# Bottom of the stack: cc_comp01 with a clear tint = the art untinted
	# (insertSubview:atIndex:0, after the loop).
	_blob_layers.clear()
	var base_tex := _tex("cc_comp01.png")
	if base_tex != null:
		var base := Sprite2D.new()
		base.texture = base_tex
		base.centered = true
		_blob.add_child(base)
	# The four colourable layers: cc_comp01..cc_comp04 (loop i = 2..5, art
	# index i-1), TintedIV(clearColor, blend 3) until a colour first lands.
	# changeColor:(clearColor) fills nothing, so they start as the bare art.
	for i in BLOB_LAYER_COUNT:
		var tex := _tex("cc_comp0%d.png" % (i + 1))
		if tex == null:
			continue
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = true
		_blob.add_child(s)
		_blob_layers.append({"sprite": s, "art": tex, "tint": Color(0, 0, 0, 0)})

	# viewDidLoad's initial rotation: the direction the rig's start position
	# already faces from the hub.
	_rig.rotation = deg_to_rad(_direction_deg(_rig.position))


## addCottonCandyParticles:frequency: for rings (0,4), (1,12), (2,10) --
## call site constants at 0x7EC14..0x7EC52. 26 wisps total.
func _build_particles() -> void:
	_particles.clear()
	for ring_def in RINGS:
		var ring: int = ring_def[0]
		var count: int = ring_def[1]
		var step := 360 / count      # integer division, as ___divsi3 does
		for i in count:
			var angle_deg := float(i * step)
			var dist := _ring_distance(ring)
			var art: Array = RING_ART[ring]
			var tex := _tex((art[0] % (randi() % int(art[1]) + 1)) + ".png")
			var ci := randi() % _selected_colors.size()
			if i < _selected_colors.size() - 1:
				ci = i
			var color: Color = _selected_colors[ci]
			_color_totals[ci] += 1
			if tex == null:
				continue
			# addCottonCandyParticle: (0x7D948): the art is rotated by the
			# ring angle (rotateUIImage: 0x7D648, degrees * 0.0174533; its
			# CTM flip keeps the art upright, so clockwise like Godot) and
			# centred on the ring point; TintedIV blend 3 with the flavour.
			# The overlay bake is per pixel, so tinting the unrotated art and
			# rotating the sprite gives the same pixels as the original's
			# rotate-then-tint, up to resampling.
			var s := Sprite2D.new()
			s.texture = ccSugarTint.overlay_texture(tex, color, _tint_cache)
			s.centered = true
			s.position = MIDDLE_CENTER \
				+ Vector2(cos(deg_to_rad(angle_deg)), sin(deg_to_rad(angle_deg))) * dist
			s.rotation = deg_to_rad(angle_deg)
			# insertSubview:belowSubview:ccMachineMiddle -- under the centre
			# cap and the cut-out overlay, over the tub art.
			add_child(s)
			if _middle != null and _middle.get_parent() == self:
				move_child(s, _middle.get_index())
			_particles.append({"node": s, "color": color})
	_total_particles = _particles.size()


func _ring_distance(ring: int) -> float:
	match ring:
		1:
			return RING1_DISTANCE
		0:
			return RING0_DISTANCES[randi() % 3]
		_:
			return RING2_DISTANCE


# -- the spin ----------------------------------------------------------

func _process(delta: float) -> void:
	if _middle != null:
		_middle.rotation += TAU * SPIN_ROTATIONS_PER_SECOND * delta


# -- the drag (0x7F6F0 / 0x7F938) --------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		_touching = mb.pressed
		if mb.pressed:
			_move_stick(mb.position)
	elif event is InputEventMouseMotion and _touching:
		# iOS delivered touchesMoved: at most once per frame (60 Hz); see
		# Screen.accept_touch_move. Added because the funnel cake
		# mix and drain ran far too fast on a high-refresh monitor.
		if not accept_touch_move():
			get_viewport().set_input_as_handled()
			return
		# didSkippedLastMove: the very first move event is dropped, once.
		if not _skipped_first_move:
			_skipped_first_move = true
			return
		_move_stick((event as InputEventMouseMotion).position)


func _direction_deg(p: Vector2) -> float:
	var d := p - MIDDLE_CENTER
	return rad_to_deg(atan2(d.y, d.x)) + DIRECTION_OFFSET_DEG


func _move_stick(pos: Vector2) -> void:
	if _rig == null:
		return
	_rig.position = pos                     # setCenter: the raw touch point
	_rig.rotation = deg_to_rad(_direction_deg(pos))
	var grabbed := 1.0 - float(_particles.size()) / float(max(_total_particles, 1))
	var s := grabbed / BLOB_SCALE_DIVISOR
	if s <= 0.0:
		s = BLOB_SCALE_EPSILON
	_blob.scale = Vector2(s, s)             # identity-then-scale: absolute
	_grab_particles(pos)


## grabCottonCandyParticles (0x7D2C4): sweep a 30x30 box about the tip (the
## rig centre = the touch), take the FIRST wisp inside, colour the candy with
## its tint, fade it out and drop it from the list; when the list empties,
## show next.
func _grab_particles(pos: Vector2) -> void:
	var box := Rect2(pos - Vector2(GRAB_HALF, GRAB_HALF),
		Vector2(GRAB_HALF * 2.0, GRAB_HALF * 2.0))
	for i in _particles.size():
		var p: Dictionary = _particles[i]
		if not box.has_point((p["node"] as Node2D).position):
			continue
		# loopFile:cc_roll_up withLoopCount:0 -- once, a fresh player per
		# grab (AudioManager 0xE873C), so overlapping is the original's too.
		Audio.play("cc_roll_up")
		_color_candy(p["color"])
		var node := p["node"] as Node2D
		var tw := create_tween()
		tw.tween_property(node, "modulate:a", 0.0, GRAB_FADE) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_interval(GRAB_REMOVE - GRAB_FADE)
		tw.tween_callback(node.queue_free)
		_fading = _fading.filter(func(f: Dictionary) -> bool:
			return is_instance_valid(f["node"]))
		_fading.append({"node": node, "tween": tw})
		_particles.remove_at(i)
		break
	if _particles.is_empty():
		_has_finished()


# -- the colouring (0x7CE00 / 0x7CCF4) ---------------------------------

func _color_candy(color: Color) -> void:
	var first := not _color_order.has(color)   # isFirstTimeGrabbingColor:
	if first:
		_color_order.append(color)             # getOrderFromColor: appends
	var order := _color_order.find(color)
	var ci := _color_index(color)
	_color_grabbed[ci] += 1                    # selectedColorsRunningCount

	# Which layers this colour owns, by how many colours are in play
	# (the 1/2/3/4-colour ladder in colorCottonCandyOnStick:).
	var layers: Array = []
	var order_idx := order
	match _selected_colors.size():
		1:
			layers = [0, 1, 2, 3]
		2:
			if order == 0:
				layers = [0, 1]
			elif order == 1:
				layers = [2, 3]
		3:
			if order == 0:
				layers = [0]
			elif order == 1:
				layers = [1, 2]
			elif order == 2:
				layers = [3]
		4:
			if order >= 0 and order <= 3:
				layers = [order]
	for li in layers:
		if li >= _blob_layers.size():
			continue
		var layer: Dictionary = _blob_layers[li]
		var a := _new_alpha(color, first, order_idx, ci)
		var sprite := layer["sprite"] as Sprite2D
		if first:
			# getNewAlpha's first-grab branch: [layer changeColor:colour] --
			# the overlay bake of this layer's cc_comp art.
			layer["tint"] = color
			sprite.texture = ccSugarTint.overlay_texture(layer["art"], color,
				_tint_cache)
		# ...and setAlpha: on the TintedIV view, the returned alpha.
		sprite.modulate = Color(1, 1, 1, a)


## getNewAlpha (0x7CCF4): first grab returns the base; afterwards
## base + (1 - base) * grabbed/total for that colour.
func _new_alpha(color: Color, first: bool, order_idx: int, ci: int) -> float:
	var base := ALPHA_BASE_FIRST if order_idx == 0 else ALPHA_BASE_LATER
	if first:
		return base
	var total := float(max(_color_totals[ci], 1))
	return base + (1.0 - base) * float(_color_grabbed[ci]) / total


func _color_index(color: Color) -> int:
	var i := _selected_colors.find(color)
	return i if i >= 0 else 0                  # 0x7CB00 falls through to 0


## hasFinishedGrabbingAllCottonCandyParticles (0x7C818): once. instIV hides,
## the next button gets alpha 1, enabled, and the +500px (DAT_0007c9e8)
## 0.25s ease-in-out slide-in. The scene's next button is a Control, which
## Screen.show_next_button's Node2D slide skips, so the slide runs here.
func _has_finished() -> void:
	if _shown_next:
		return
	_shown_next = true
	dismiss_instruction()
	var n := outlet("nextButton")
	if n == null or n == self:
		return
	n.set("disabled", false)
	if n is CanvasItem:
		var m: Color = (n as CanvasItem).modulate
		(n as CanvasItem).modulate = Color(m.r, m.g, m.b, 1.0)
	var btn := n as Control
	if btn == null:
		return
	var home := btn.position
	btn.visible = true
	btn.position = home + Vector2(SLIDE_OFFSET, 0)
	create_tween().tween_property(btn, "position", home, NEXT_SLIDE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# -- navigation --------------------------------------------------------

## nextClick: (0x7EFA8): bake the candy and the stick into the two custom
## categories MakeViewController consumes, plus the {selectedColors, stickImg}
## infoDict, and move on.
##
##  * "CottonCandy": the four ccsOnStick layers -- fresh TintedIVs of
##    cc_comp01..04 in each layer's CURRENT tintColor (clearColor if never
##    grabbed), blend 3, at full alpha (the layers' view alpha is NOT carried)
##    and WITHOUT the untinted cc_comp01 base -- added at (0,0) (zero-frame)
##    to a 320x320 view (0x43a00000) and rendered with renderInContext:.
##    Properties IsEdible YES, ViewIndex 2, Type Stationary, ItemCenter
##    (0.0, 70.0) (0x428c0000).
##  * "CottonCandyStick": the original stick image resized x2 (size + size).
##    IsEdible NO, ViewIndex 1, Type Stationary, ItemCenterX =
##    (320 - w*2)/2 (DAT_0007f66c = 320.0), ItemCenterY = 175.0 (0x432f0000).
##
## The original hands Make the infoDict and the customCategories separately
## (initWithClassStr:"COTTON_CANDY" andInfoDict:, setCustomCategories:); the
## port carries both in GameState.custom_categories, and
## MakeViewController._add_custom_categories skips the non-layer keys.
## Make reads ItemCenterX/Y as the layer's TOP-LEFT (its zero-frame
## DecorateItemView rule).
func _on_nextClick() -> void:
	Audio.play("button_press")
	var info: Dictionary = {
		"selectedColors": _selected_colors.duplicate(),
		"stickImg": _stick_tex,
	}
	var candy := _bake_candy()
	if candy != null:
		info["CottonCandy"] = {
			"Properties": {
				"IsEdible": true, "ViewIndex": 2, "Type": "Stationary",
				"ItemCenterX": 0.0, "ItemCenterY": 70.0,
			},
			"Image": candy,
		}
	if _stick_tex != null:
		var img := _stick_tex.get_image()
		if img != null:
			img = img.duplicate()
			if img.is_compressed():
				img.decompress()
			# resizedImage:interpolationQuality:3 (kCGInterpolationHigh).
			# PORT CHOICE: Godot's cubic filter stands in for CG's "high".
			img.resize(img.get_width() * 2, img.get_height() * 2,
				Image.INTERPOLATE_CUBIC)
			info["CottonCandyStick"] = {
				"Properties": {
					"IsEdible": false, "ViewIndex": 1, "Type": "Stationary",
					"ItemCenterX": (320.0 - float(img.get_width())) * 0.5,
					"ItemCenterY": 175.0,
				},
				"Image": img,
			}
	GameState.custom_categories = info
	Nav.next()


## The 320x320 composite: cc_comp01..04, each with changeColor:'s overlay
## bake in its layer's tint (the same bake the on-screen layer shows, so the
## cached texture is reused), source-over in z order at (0,0). A layer never
## coloured still has clearColor, which leaves its art unchanged.
const CANDY_CANVAS := Vector2i(320, 320)

func _bake_candy() -> Image:
	var out := Image.create(CANDY_CANVAS.x, CANDY_CANVAS.y, false,
		Image.FORMAT_RGBA8)
	for layer in _blob_layers:
		var tex := ccSugarTint.overlay_texture(layer["art"], layer["tint"],
			_tint_cache)
		if tex == null:
			continue
		var img := tex.get_image()
		if img == null:
			continue
		if img.is_compressed():
			img.decompress()
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		out.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i.ZERO)
	return out


## backClick: (0x7F670): click, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


## skipClick: (0x7F6E0), the invisible dev button at (200, 393, 120, 40):
## straight to nextClick:.
func _on_skipClick() -> void:
	_on_nextClick()
