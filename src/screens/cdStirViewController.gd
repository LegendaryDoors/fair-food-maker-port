# Corn Dog step 3 -- stir the bowl until the batter comes together.
#
# GROUNDED from initWithBatter: (0x12FD08), viewDidLoad (0x130020),
# viewWillAppear: (0x130844), showSpoon (0x130A88), draggableTouchBegan/Moved/
# Ended (0x13143C / 0x131528 / 0x131874), showNextButton (0x1324E0),
# changeInstruction: (0x132644), viewWillDisappear: (0x130998), backClick:
# (0x131CEC) and nextClick: (0x131DD0).
#
# Mechanic, as read: the bowl UIImageView shows the image rendered by
# cdMixIngredients' nextClick: (setIngredients:, 0x85CB0). A batter-coloured
# top view (cd_batter_*_top.png) sits over it at alpha 0, centred on the bowl.
# Dragging the spoon inside the bowl with its centre below y = 180
# (float 0x131870) adds 0.0025 (double 0x131858) to that alpha PER MOVE EVENT.
# At alpha >= 1.0 the stir sound stops and the next button slides in.
#
# The white/pink mixer consumables (0.01 / 0.02 per event) are ported, see
# below. The SSEmitter on the spoon tip (tag 326, viewDidLoad 0x130020 at
# (10, 130) in the spoon; StirTool.tip_emitter) is CONFIGURED in showSpoon
# with Hot_Dog_Mixer_White/Pink_PS_1..3 tinted batterColor, and stopped where
# the original stops it -- but never started: its only `start` is
# startBurner (0x131400), which no cdStir method calls (the selector is only
# performed by cdFry, on itself), so it never emits in v1.27 (wired as
# configure-only).
# batterColor, for the record: original AND honey (250,217,138)/255 -- the
# same colour twice, an original quirk -- chocolate (140,92,54)/255, spicy
# (207,138,92)/255.
#
# Next button: changeInstruction: (0x132644) ends with nextButton
# setHidden:YES, and viewWillAppear: calls it, so next is hidden on entry and
# again whenever showSpoon re-runs (mixer bought); draggableTouchMoved: shows
# it only while it is hidden and the batter alpha has reached 1.

extends "res://core/Screen.gd"

## Nib frames: bowl (38, 198, 244, 244); spoon DraggableIV (210, 8, 57, 207)
## -> true centre (238.5, 111.5), which viewDidLoad stores as origCenter.
const BOWL_RECT := Rect2(38, 198, 244, 244)
const SPOON_CENTER := Vector2(238.5, 111.5)
const SPOON_SIZE := Vector2(57, 207)
## setSnapTime: 0.25 (0x3E800000, viewDidLoad and again in showSpoon).
const SPOON_SNAP := 0.25

## Mixers, PORTED (the phone shows both badges). Shared
## logic in core/StirMixers.gd and core/StirTool.gd; this screen's own
## numbers: consumable names Mixer_30Mix / PinkMixer_30Mix, and the per-move
## crossfade step with the white mixer 0.01 and the pink one 0.02
## (draggableTouchMoved:, the two constants next to the no-mixer one plus
## the inline pink literal). Buying one swaps the tool in place (showSpoon),
## which also resets the stir progress and re-shows the instruction, and
## hides both badges; nextClick: zeroes the quantities.
const StirToolScript := preload("res://core/StirTool.gd")
const StirMixersScript := preload("res://core/StirMixers.gd")
const MIXER_NAME := "Mixer_30Mix"
const PINK_MIXER_NAME := "PinkMixer_30Mix"
const STIR_STEP_MIXER := 0.01
const STIR_STEP_PINK := 0.02

var _mixers: RefCounted
## Spoon rest transform: rotation 0.5236 rad = 30 deg (0x3F060A92).
const SPOON_ROTATION := 0.523599
## Stir threshold: spoon.center.y >= 180.0 (float 0x131870).
const STIR_MIN_Y := 180.0
## No-mixer alpha step per touch-move event (double 0x131858).
const STIR_STEP := 0.0025
## batterColor, the tip emitter's tint (viewDidLoad 0x130020): original and
## honey (0.980392, 0.85098, 0.541176), chocolate (0.54902, 0.360784,
## 0.211765), spicy (0.811765, 0.541176, 0.360784).
const BATTER_COLOR := {0: Color(0.980392, 0.85098, 0.541176),
	1: Color(0.980392, 0.85098, 0.541176), 2: Color(0.54902, 0.360784, 0.211765),
	3: Color(0.811765, 0.541176, 0.360784)}
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")

const BATTER_TOP := {0: "cd_batter_original_top.png",
	1: "cd_batter_honey_top.png", 2: "cd_batter_choc_top.png",
	3: "cd_batter_spicy_top.png"}

var _batter := 0
var _spoon: Node2D
var _batter_view: Sprite2D
var _dragging := false
var _grab := Vector2.ZERO
## The spoon's SnapToOrig glide home (see _spoon_hit).
var _spoon_snap: Tween


func on_enter() -> void:
	_batter = int(GameState.custom_categories.get("batter", 0))
	_setup_bowl()
	_build_batter_view()
	_build_spoon()
	_view_will_appear()


## UINavigationController keeps this controller alive under cdRollDog
## (Nav.gd's opt-in). On back only viewWillAppear: runs again, and its
## showSpoon RESETS the stir: batter alpha 0, spoon (nextClick: zeroed the
## mixers) back at origCenter, badges shown, next hidden by
## changeInstruction:. So a return from cdRollDog means stirring again.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	_dragging = false
	_view_will_appear()


## viewWillAppear: (0x130844): changeInstruction(inst_mix_ingreds.png) --
## the nib already carries that art -- then showSpoon.
func _view_will_appear() -> void:
	change_instruction("inst_mix_ingreds.png")
	_show_spoon()


## showSpoon (0x130A88): stop the tip emitter; the owned tool (pink first,
## then white, else the spoon) at origCenter, unhidden, snapTime 0.25; for a
## mixer the tip emitter is configured (but never started in v1.27, see
## header) and both badges hide,
## for the spoon both badges show; batterView alpha 0; addSubview: brings
## the tool to the front; changeInstruction: again (hides next).
func _show_spoon() -> void:
	var tip := _spoon.get("tip_emitter") as Node
	if tip != null:
		tip.call("stop")
	var k := int(_mixers.call("kind"))
	_spoon.call("show_kind", k)
	if tip != null and k != StirToolScript.Kind.SPOON:
		var key := "cdStirViewController.spoonTip.pink" \
			if k == StirToolScript.Kind.PINK_MIXER \
			else "cdStirViewController.spoonTip.white"
		SSEmitterConfigs.apply(tip, key, BATTER_COLOR.get(_batter, BATTER_COLOR[0]))
	_mixers.call("set_badges_visible", k == StirToolScript.Kind.SPOON)
	if _batter_view != null:
		_batter_view.modulate.a = 0.0
	move_child(_spoon, -1)
	change_instruction("inst_mix_ingreds.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## viewDidLoad: bowl.image = the picture cdMixIngredients rendered. Entered
## standalone (dev tools), the carrier is empty and the bowl stays blank --
## absent rather than invented.
func _setup_bowl() -> void:
	var bowl := outlet("bowl")
	if not (bowl is Sprite2D):
		return
	var s := bowl as Sprite2D
	s.centered = false
	s.position = BOWL_RECT.position
	var img: Variant = GameState.custom_categories.get("ingredientsImg")
	if img is Texture2D:
		s.texture = img


## batterView: UIImageView(cd_batter_*_top) inserted above the bowl, centred
## on the bowl's centre, alpha 0 (viewDidLoad tail + showSpoon 0x130A88).
func _build_batter_view() -> void:
	var tex := _tex(BATTER_TOP.get(_batter, BATTER_TOP[0]))
	if tex == null:
		return
	_batter_view = Sprite2D.new()
	_batter_view.texture = tex
	_batter_view.position = BOWL_RECT.position + BOWL_RECT.size * 0.5
	_batter_view.modulate.a = 0.0
	var bowl := outlet("bowl")
	if bowl != null and bowl != self and bowl.get_parent() != null:
		bowl.get_parent().add_child(_batter_view)
		bowl.get_parent().move_child(_batter_view, bowl.get_index() + 1)
	else:
		add_child(_batter_view)


## showSpoon (see StirTool): the spoon, or the owned mixer, at origCenter.
## The mixer badges come from StirMixers.
func _build_spoon() -> void:
	var o := outlet("spoon")
	if o != null and o != self:
		(o as CanvasItem).visible = false
	_mixers = StirMixersScript.new()
	_mixers.call("setup", self, MIXER_NAME, PINK_MIXER_NAME, _on_mixer_bought)
	# initWithBatter: (0x12FD08) ends with setQuantity:0 on BOTH mixers, so a
	# mixer left over from another food's stir screen never carries in here.
	_mixers.call("reset_quantities")
	_spoon = StirToolScript.new()
	_spoon.set("home", SPOON_CENTER)
	_spoon.set("kind", _mixers.call("kind"))
	add_child(_spoon)
	if _mixers.call("any_owned"):
		_mixers.call("set_badges_visible", false)


## consumablePurchased: -- quantity is already bumped by StirMixers; the
## screen re-runs showSpoon when the tool is showing and this is
## the first unit, which swaps the implement, resets the progress, re-shows
## the instruction and hides both badges.
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
			# draggableTouchBegan: (0x13143C): the "mixer" loop with a mixer owned, else
			# stir_unfinished; the frame animation starts either way.
			Audio.loop("mixer" if _mixers.call("any_owned") else "stir_unfinished")
			_spoon.set("animating", true)
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			# draggableTouchEnded: (0x131874) stops mixer/stir_unfinished and
			# the emitter; the trailing stop is the stirring loop.
			Audio.stop("mixer")
			Audio.stop("stir_unfinished")
			Audio.stop("stirring")
			_spoon.set("animating", false)
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


## draggableTouchMoved: (0x131528). The frame test uses the rotated spoon's
## bounding box, exactly what CGRectIntersectsRect saw on a transformed view.
func _stir_move() -> void:
	var frame: Rect2 = _spoon.call("frame_rect")
	var step := _stir_step()
	if frame.intersects(BOWL_RECT) and _spoon.position.y >= STIR_MIN_Y:
		if _batter_view != null:
			# UIView clamps alpha to [0, 1]; reading it back gives at most 1.
			_batter_view.modulate.a = minf(_batter_view.modulate.a + step, 1.0)
		var a := 1.0 if _batter_view == null else _batter_view.modulate.a
		if a < 1.0:
			Audio.loop("stirring")   # 0x6B7924, only while unfinished
		else:
			Audio.stop("stirring")
			# `if nextButton.isHidden -> showNextButton`: keyed on the button,
			# not a once-only flag, because a mixer bought after the first
			# finish re-runs showSpoon -> changeInstruction:, which hides next
			# and zeroes the batter again; the next finish must show it again.
			var nb := first_outlet(NEXT_OUTLETS)
			if nb != null and not (nb as CanvasItem).visible:
				show_next_button()   # 0x1324E0, the standard +500/0.25 slide
	else:
		Audio.stop("stirring")


## nextClick: (0x131DD0): button_press, push cdRollDogViewController
## initWithBatter:. The batter id stays in the carrier; the bowl image is no
## longer needed downstream and is dropped, as the original's init chain does.
func _on_nextClick() -> void:
	_mixers.call("reset_quantities")   # setQuantity:0 on both mixers
	Audio.play("button_press")
	GameState.custom_categories = {"batter": _batter}
	Nav.next()


## backClick: (0x131CEC): setQuantity:0 on both mixers, stop the emitter,
## button_press, pop (unanimated).
func _on_backClick() -> void:
	_mixers.call("reset_quantities")
	_stop_tip()
	Audio.play("button_press")
	Nav.back()


## viewWillDisappear: (0x130998): stop the tip emitter (tag 326), then
## fire_loop, stirring, mixer and stir_unfinished.
func on_exit() -> void:
	_stop_tip()
	Audio.stop("fire_loop")
	Audio.stop("mixer")
	Audio.stop("stirring")
	Audio.stop("stir_unfinished")


func _stop_tip() -> void:
	if _spoon == null:
		return
	var tip := _spoon.get("tip_emitter") as Node
	if tip != null:
		tip.call("stop")


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
