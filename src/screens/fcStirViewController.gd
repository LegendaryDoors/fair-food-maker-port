# Funnel Cake step 3 -- stir the bowl until the batter comes together.
#
# GROUNDED from initWithBatter: (0x1347A0), viewDidLoad (0x134AB8),
# viewWillAppear: (0x135248), showSpoon (0x135450), draggableTouchBegan/Moved/
# Ended (0x135BCC / 0x135CB8 / 0x135F98), nextClick: (0x136490) and
# viewWillDisappear: (0x13539C, read from the disassembly; it stops
# fire_loop, stirring, mixer and stir_unfinished). Everything else read from
# the original binary.
#
# Mechanic, as read: the bowl UIImageView shows the image rendered by
# fcMixBatterVC's nextClick: (0x8A654). A batter-coloured top view
# (fc_batter_*_top.png) sits over it at alpha 0, centred on the bowl.
# Dragging the spoon with its frame intersecting the bowl's adds 0.0025
# (double at 0x135F80) to that alpha PER MOVE EVENT. Unlike cdStir there is
# NO y >= 180 gate -- the intersect test alone decides (0x135CB8). At
# alpha >= 1.0 the stirring loop stops and the next button slides in if it
# was hidden.
#
# The white/pink mixer consumables (initWithBatter: 0x1347A0, buyClick:
# 0x136308, buyPinkClick: 0x136374, showSpoon 0x135450) are coin
# consumables and ARE ported (see the mixer block below).
# Not ported:
#  * batterColor (viewDidLoad 0x134AB8) is set but never read -- the getter
#    (0x137224) has no xref -- so it is recorded here, not built: default
#    AND original (1.0, 0.8824, 0.5686), caramel (0.9216, 0.8196, 0.5490),
#    chocolate (0.7765, 0.5412, 0.3569); the strawberry case's channels
#    beyond r=0.8745 were not recovered and, being dead code, were not
#    chased further.
#
# Next button: changeInstruction: (0x136CD0) ends with nextButton
# setHidden:YES, and viewWillAppear: (0x135248) runs it (and showSpoon runs it
# again), so next is hidden on entry -- instruction_hides_next() below. The
# move handler shows it whenever alpha >= 1.0 AND the button is hidden
# (`nextButton isHidden` test in 0x135CB8, no latch), so a mixer bought after
# finishing -- showSpoon re-hides next and zeroes the alpha -- needs the bowl
# stirred again before next returns.
#
# Rate: +0.0025 per draggableTouchMoved: (double at
# 0x135F80 read from the binary: 0.0025; mixer 0.01 at 0x135F88; pink 0.02
# inline), gated only by CGRectIntersectsRect(spoon.frame, bowl.frame).
# DraggableIV touchesMoved: (0x46614) forwards every move unconditionally.
# In float32 the alpha reaches 1.0 on the 401st counted move -- 6.7 s of
# continuous stirring at the 60 Hz move gate (Screen.accept_touch_move).

extends "res://core/Screen.gd"

## Nib frames: bowl (38, 203, 244, 244); spoon DraggableIV (210, 8, 57, 207)
## -> true centre (238.5, 111.5), which viewDidLoad stores as origCenter.
const BOWL_RECT := Rect2(38, 203, 244, 244)
const SPOON_CENTER := Vector2(238.5, 111.5)
const SPOON_SIZE := Vector2(57, 207)
## setSnapTime: 0.25 (bits 0x3E800000, viewDidLoad and again in showSpoon).
const SPOON_SNAP := 0.25

## Mixers: ported (the original shows both badges). Shared
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
## Spoon rest transform: rotation 0.5236 rad = 30 deg (viewDidLoad/showSpoon).
const SPOON_ROTATION := 0.5236
## No-mixer alpha step per touch-move event (double at 0x135F80).
const STIR_STEP := 0.0025

## viewDidLoad (0x134AB8): batterView image by batterID. Same table as
## fcMixBatterVC setIngredients (0x89938).
const BATTER_TOP := {0: "fc_batter_original_top.png",
	1: "fc_batter_strawberry_top.png", 2: "fc_batter_caramel_top.png",
	3: "fc_batter_choc_top.png"}

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


## UINavigationController keeps this controller alive under fcPour (Nav.gd's
## opt-in). On back only viewWillAppear: runs again, and its showSpoon RESETS
## the stir: batter alpha 0, spoon (nextClick: zeroed the mixers) back at
## origCenter, badges shown, next hidden by changeInstruction:.
func keeps_state_on_push() -> bool:
	return true


func on_resume() -> void:
	_dragging = false
	_view_will_appear()


## viewWillAppear: (0x135248): changeInstruction(inst_mix_ingreds.png) --
## the nib already carries that art -- then showSpoon (0x135450).
func _view_will_appear() -> void:
	change_instruction("inst_mix_ingreds.png")
	_show_spoon()


## showSpoon (0x135450): the owned tool (pink, then white, else the spoon)
## at origCenter, unhidden; badges hidden for a mixer, shown for the spoon;
## batterView alpha 0; addSubview: brings the tool to the front;
## changeInstruction: again (hides next). fcStir has no tip emitter.
func _show_spoon() -> void:
	var k := int(_mixers.call("kind"))
	_spoon.call("show_kind", k)
	_mixers.call("set_badges_visible", k == StirToolScript.Kind.SPOON)
	if _batter_view != null:
		_batter_view.modulate.a = 0.0
	move_child(_spoon, -1)
	change_instruction("inst_mix_ingreds.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## viewDidLoad: bowl.image = the picture fcMixBatterVC rendered. Entered
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


## batterView: UIImageView(fc_batter_*_top) inserted above the bowl, centred
## on the bowl's centre (viewDidLoad tail), alpha 0 (showSpoon 0x135450).
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
	# initWithBatter: (0x1347A0) ends with setQuantity:0 on BOTH mixers, as
	# cdStir's does, so a mixer left over from another stir screen never
	# carries in here.
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
			# draggableTouchBegan: (0x135BCC): the "mixer" loop with a mixer owned, else
			# stir_unfinished; the frame animation starts either way.
			Audio.loop("mixer" if _mixers.call("any_owned") else "stir_unfinished")
			_spoon.set("animating", true)
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			# draggableTouchEnded: (0x135F98) stops mixer, stir_unfinished
			# and stirring; only the two the port plays exist to stop.
			Audio.stop("mixer")
			Audio.stop("stir_unfinished")
			Audio.stop("stirring")
			_spoon.set("animating", false)
			_snap_spoon_home()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		# iOS delivered touchesMoved: at most once per frame (60 Hz); see
		# Screen.accept_touch_move. Without it the funnel cake mix and drain
		# ran far too fast on a high-refresh monitor.
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


## draggableTouchMoved: (0x135CB8). The frame test uses the rotated spoon's
## bounding box, exactly what CGRectIntersectsRect saw on a transformed view.
## No y threshold -- the fc stir counts anywhere the frames overlap.
func _stir_move() -> void:
	var frame: Rect2 = _spoon.call("frame_rect")
	var step := _stir_step()
	if frame.intersects(BOWL_RECT):
		if _batter_view != null:
			_batter_view.modulate.a += step
		var a := 1.0 if _batter_view == null else _batter_view.modulate.a
		if a < 1.0:
			Audio.loop("stirring")   # loopFile "stirring"/"mp3" (0x135CB8)
		else:
			Audio.stop("stirring")
			# `if (nextButton.isHidden) showNextButton` -- no latch (0x135CB8).
			var nb := outlet("nextButton") as CanvasItem
			if nb != null and not nb.visible:
				show_next_button()   # 0x136B6C, the standard +500/0.25 slide
	else:
		Audio.stop("stirring")


## nextClick: (0x136490): button_press, push fcPourBatterVC initWithBatterID:.
## The batter id stays in the carrier; the bowl image is no longer needed
## downstream and is dropped, as the original's init chain does.
func _on_nextClick() -> void:
	_mixers.call("reset_quantities")   # setQuantity:0 on both mixers
	Audio.play("button_press")
	GameState.custom_categories = {"batter": _batter}
	Nav.next()


## backClick: (0x1363E0): both mixer quantities to 0, button_press, pop
## (animated NO). (The base Screen back pops silently and keeps the
## mixers.)
func _on_backClick() -> void:
	_mixers.call("reset_quantities")
	Audio.play("button_press")
	Nav.back()


func on_exit() -> void:
	# viewWillDisappear: (0x13539C) stops fire_loop, stirring, mixer and
	# stir_unfinished -- nothing else; the stir state is left for the return.
	Audio.stop("fire_loop")
	Audio.stop("mixer")
	Audio.stop("stirring")
	Audio.stop("stir_unfinished")


## This screen's changeInstruction: hides nextButton (read from the
## binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
