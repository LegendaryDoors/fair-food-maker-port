# Donut Ice Cream Sandwich step 2 (of the 4-round mix/stir loop) -- stir the
# round's ingredients until the batter fades in.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithDonutMixture: 0x94030, viewDidLoad 0x942BC, viewWillAppear:
#   0x94878, setupBowl 0x94A28, showSpoon 0x94BA8, startBurner 0x95330,
#   draggableTouchBegan/Moved/Ended 0x9536C / 0x95458 / 0x957FC, nextClick:
#   0x95E2C, skipClick: 0x95FF4, backClick: 0x95C74, viewWillDisappear:
#   0x948E8, viewDidDisappear: 0x949D4; alpha-step doubles at 0x957E0/0x957E8.
#
# Mechanic, as read: the same bowl as dicMix, showing this round's mixed
# views (setupBowl 0x94A28 = dicMix resetIngredients in reverse). A
# batterView is built in code (viewDidLoad 0x942BC): "dis_batter%d.png"
# (round+1) for rounds 0..2, "dis_dough_01.png" for round 3, at natural size
# centred on the bowl's centre, alpha 0, inserted below the spoon. Dragging
# the spoon with its frame intersecting the bowl AND its centre below
# y = 180 (0x95458) adds 0.005 (double 0x957E0) to that alpha PER MOVE
# EVENT -- double cdStir's 0.0025. Round 3 also *subtracts* 0.005 from
# bowlA and bowlB each event, crossfading the batter bowls into the dough
# ball. At alpha >= 1 the stir loop stops.
#
# NEXT BUTTON (corrected): this class's changeInstruction:
# (0x9619C) ENDS with `nextButton setHidden:YES`, and viewWillAppear: /
# showSpoon both call it, so the arrow is hidden from the first frame. The
# alpha>=1 branch of draggableTouchMoved: (0x95458) then finds it hidden and
# runs showNextButton (0x96004: instIV hidden, +500 slide, 0.25s) -- the
# step can NOT be skipped. The port used to claim the opposite ("nothing
# hides it") and left the arrow up before any stirring.
#
# QUIRKS, kept:
#  * The spoon is a plain cd_spoon at rotation 0.5236 rad (30 deg), snapTime
#    0.25 (0x3E800000), origCenter = nib centre (238.5, 111.5) -- identical
#    geometry to cdStir's spoon.
#
# nextClick: (0x95E2C): rounds 0..2 push dicMixIngredients(round+1); round 3
# pushes dicRollCut. backClick: (0x95C74) is a plain pop on the normal path
# (navStack[count-3] is the previous stir); after a skip-consumable round it
# IS a mix and the original pops two -- see _on_backClick.
#
# The white/pink mixer consumables (initWithDonutMixture: 0x94030,
# buyClick:/buyPinkClick:, showSpoon's Mixer_Upgrade_* swaps, the "mixer"
# loop, steps 0.02 = double 0x957E8 and 0.04 inline) are ported through
# core/StirTool.gd + core/StirMixers.gd -- see the block below.
# No particles here: the class stops/starts `spoon viewWithTag:326` in seven
# places, but nothing in dicStir ever creates that view (unlike ccbStir's
# showSpoon), so every call messages nil.
#
# KEEP-STATE: kept alive under its push. viewDidLoad's
# batter view, spoon and badges are built once; viewWillAppear: (setupBowl,
# instruction, showSpoon) runs on entry and in on_resume. on_exit =
# viewWillDisappear: + viewDidDisappear:.

extends "res://core/Screen.gd"

const DicMix := preload("res://screens/dicMixIngredientsViewController.gd")

## Nib frames: bowl (38,198,244,244); spoon DraggableIV (210,8,57,207) ->
## true centre (238.5, 111.5), stored as origCenter (viewDidLoad 0x942BC).
const BOWL_RECT := Rect2(38, 198, 244, 244)
const SPOON_CENTER := Vector2(238.5, 111.5)
const SPOON_SIZE := Vector2(57, 207)
## setSnapTime: 0.25 (0x3E800000, viewDidLoad and showSpoon).
const SPOON_SNAP := 0.25

## Mixers, PORTED (the phone shows both badges). Shared
## logic in core/StirMixers.gd and core/StirTool.gd; this screen's own
## numbers: consumable names Mixer_30Mix / PinkMixer_30Mix, and the per-move
## crossfade step with the white mixer 0.02 and the pink one 0.04
## (draggableTouchMoved:, the two constants next to the no-mixer one plus
## the inline pink literal). Buying one swaps the tool in place (showSpoon),
## which also resets the stir progress and re-shows the instruction, and
## hides both badges; nextClick: zeroes the quantities.
const StirToolScript := preload("res://core/StirTool.gd")
const StirMixersScript := preload("res://core/StirMixers.gd")
const MIXER_NAME := "Mixer_30Mix"
const PINK_MIXER_NAME := "PinkMixer_30Mix"
const STIR_STEP_MIXER := 0.02
const STIR_STEP_PINK := 0.04

var _mixers: RefCounted
## Spoon rest rotation 0.5236 rad (CGAffineTransformMakeRotation literal).
const SPOON_ROTATION := 0.5236
## Stir threshold: spoon.center.y >= 180.0 (0x95458).
const STIR_MIN_Y := 180.0
## No-mixer alpha step per touch-move event (double 0x957E0). cdStir's
## counterpart is 0.0025 -- this screen stirs twice as fast.
const STIR_STEP := 0.005

## viewDidLoad (0x942BC): round -> batter art, natural size, centred on the
## bowl centre (160, 320).
const BATTER_ART := {0: "dis_batter1.png", 1: "dis_batter2.png",
	2: "dis_batter3.png", 3: "dis_dough_01.png"}
const BOWL_CENTER := Vector2(160, 320)

## Same nib mixed-view table as dicMix (the two nibs share every frame).
const MIXED := {
	"yeast": {"frame": Rect2(83, 250, 60, 60), "mode": "center"},
	"water": {"frame": Rect2(124, 291, 105, 105), "mode": "center"},
	"flour": {"frame": Rect2(102, 233, 105, 50), "mode": "center"},
	"milk": {"frame": Rect2(124, 314, 105, 105), "mode": "center"},
	"egg": {"frame": Rect2(102, 227, 105, 105), "mode": "center"},
	"butter": {"frame": Rect2(151, 267, 105, 105), "mode": "center"},
	"sugar": {"frame": Rect2(116, 300, 105, 105), "mode": "center"},
	"salt": {"frame": Rect2(75, 308, 77, 36), "mode": "fill"},
	"bowlA": {"frame": Rect2(143, 239, 105, 105), "mode": "fill"},
	"bowlB": {"frame": Rect2(73, 296, 105, 105), "mode": "fill"},
}
const ROUNDS := {
	0: ["water", "yeast"],
	1: ["flour", "milk"],
	2: ["egg", "butter", "sugar", "salt"],
	3: ["bowlA", "bowlB"],
}

var _round := 0
var _spoon: Node2D
var _batter: Sprite2D
var _dragging := false
var _grab := Vector2.ZERO
## The spoon's SnapToOrig glide home (see _spoon_hit).
var _spoon_snap: Tween


## changeInstruction: (0x9619C) ends with nextButton setHidden:YES.
func instruction_hides_next() -> bool:
	return true


## UINavigationController keeps this controller alive under a push; Nav
## calls on_resume() on back. (No back path in the dic
## loop actually returns to a stir -- every backClick: above one pops to
## the mix two below -- but the screen behaves correctly if one did.)
func keeps_state_on_push() -> bool:
	return true


## initWithDonutMixture: (0x94030) + viewDidLoad (0x942BC) once, then
## viewWillAppear: (0x94878).
func on_enter() -> void:
	_round = int(GameState.custom_categories.get("donutMixture", 0))
	_layout_mixed()
	_build_batter_view()
	_build_spoon()
	_will_appear()


func on_resume() -> void:
	_will_appear()


## viewWillAppear: (0x94878): setupBowl, changeInstruction:, showSpoon --
## the stir starts over (batter alpha 0, next hidden). setupBowl only sets
## `hidden`, so on a round-3 return bowlA / bowlB keep the alpha the last
## stir faded them to.
func _will_appear() -> void:
	_setup_bowl()
	change_instruction("inst_mix_ingreds.png")
	_show_spoon()


## showSpoon (0x94BA8): the implement for the owned mixer (or the spoon),
## batter alpha 0, unhidden, snapTime 0.25, at origCenter, addSubview: (to
## the front); the badges show only with no mixer owned; then
## changeInstruction: again (the same slide, restarted).
func _show_spoon() -> void:
	_spoon.call("show_kind", _mixers.call("kind"))
	_spoon.set("animating", false)
	if _batter != null:
		_batter.modulate.a = 0.0
	move_child(_spoon, -1)
	_mixers.call("set_badges_visible", not bool(_mixers.call("any_owned")))
	change_instruction("inst_mix_ingreds.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## The nib mixed views drawn per contentMode (same table as dicMix).
func _layout_mixed() -> void:
	for n: String in MIXED:
		var s := outlet(n) as Sprite2D
		if s == null or s.texture == null:
			continue
		var frame: Rect2 = MIXED[n]["frame"]
		var art := Vector2(s.texture.get_size())
		if MIXED[n]["mode"] == "center":
			s.scale = Vector2.ONE
			s.position = frame.position + (frame.size - art) * 0.5
		else:
			s.position = frame.position
			s.scale = frame.size / art


## setupBowl (0x94A28): only this round's mixed views are visible. Hidden
## flags only -- alphas are left alone.
func _setup_bowl() -> void:
	var shown: Array = ROUNDS.get(_round, ROUNDS[0])
	for n: String in MIXED:
		var s := outlet(n) as Sprite2D
		if s != null:
			s.visible = shown.has(n)


## viewDidLoad tail (0x942BC): batterView inserted BELOW the spoon -- which
## puts it ABOVE every mixed view, so at full alpha it covers them -- centred
## on the bowl centre; showSpoon (0x94BA8) zeroes its alpha.
func _build_batter_view() -> void:
	var tex := _tex(BATTER_ART.get(_round, BATTER_ART[0]))
	if tex == null:
		return
	_batter = Sprite2D.new()
	_batter.texture = tex
	_batter.position = BOWL_CENTER
	_batter.modulate.a = 0.0
	add_child(_batter)
	var spoon_slot := outlet("spoon")
	if spoon_slot != null and spoon_slot != self \
			and spoon_slot.get_parent() == self:
		move_child(_batter, spoon_slot.get_index())


## showSpoon (see StirTool): the spoon, or the owned mixer, at origCenter.
## The mixer badges come from StirMixers.
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


## consumablePurchased: -- quantity is already bumped by StirMixers; the
## screen re-runs showSpoon when the tool is showing and this is
## the first unit, which swaps the implement, resets the progress, re-shows
## the instruction and hides both badges.
func _on_mixer_bought(c: RefCounted) -> void:
	if _spoon != null and _spoon.visible and int(c.get("quantity")) == 1:
		_spoon.call("show_kind", _mixers.call("kind"))
		if _batter != null:
			_batter.modulate.a = 0.0
		change_instruction("inst_mix_ingreds.png")
		_mixers.call("set_badges_visible", false)


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
			# draggableTouchBegan: (0x9536C): the "mixer" loop with a mixer owned, else
			# stir_unfinished; the frame animation starts either way.
			Audio.loop("mixer" if _mixers.call("any_owned") else "stir_unfinished")
			_spoon.set("animating", true)
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			# draggableTouchEnded: (0x957FC) stops mixer / stir_unfinished /
			# stirring; DraggableIV touchesEnded: snaps 0.25s linear.
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
## itself and can stop it.
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


## draggableTouchMoved: (0x95458). The frame test sees the rotated spoon's
## bounding box, as CGRectIntersectsRect did on the transformed view.
func _stir_move() -> void:
	var frame: Rect2 = _spoon.call("frame_rect")
	var step := _stir_step()
	if not (frame.intersects(BOWL_RECT) and _spoon.position.y >= STIR_MIN_Y):
		# Out of the bowl / too high: emitter + "stirring" stop.
		Audio.stop("stirring")
		return
	if _batter != null:
		_batter.modulate.a += step
	if _round == 3:
		# Round 3 crossfades the two batter bowls into the dough ball.
		for n: String in ["bowlA", "bowlB"]:
			var s := outlet(n) as Sprite2D
			if s != null:
				s.modulate.a -= step
	var a := 1.0 if _batter == null else _batter.modulate.a
	if a >= 1.0:
		Audio.stop("stirring")
		# showNextButton only while the arrow is hidden -- i.e. once; the
		# changeInstruction: calls on entry hid it (see header).
		var nb := first_outlet(NEXT_OUTLETS)
		if nb is CanvasItem and not (nb as CanvasItem).visible:
			show_next_button()
	else:
		Audio.loop("stirring")


## nextClick: (0x95E2C): rounds 0..2 -> next mix round; round 3 -> RollCut.
func _on_nextClick() -> void:
	_mixers.call("reset_quantities")   # setQuantity:0 on both mixers
	Audio.play("button_press")
	if _round < 3:
		var info: Dictionary = GameState.custom_categories.duplicate(true)
		info["donutMixture"] = _round + 1
		GameState.custom_categories = info
		Nav.push("dicMixIngredientsViewController", "dic")
	else:
		Nav.push("dicRollCutViewController", "dic")


## backClick: (0x95C74): zeroes both mixer quantities, button_press, then
## if count-4 >= 0 and navStack[count-3] is a dicMix, popToViewController: it,
## else a plain pop. On the normal path count-3 is the previous round's stir,
## so it is a plain pop to this round's mix; after a skip-consumable push
## (mix(r-1) -> mix(r) -> stir(r)) count-3 IS mix(r-1) and the original pops
## two. Shared helper in dicMixIngredientsViewController.dic_back.
func _on_backClick() -> void:
	_mixers.call("reset_quantities")
	Audio.play("button_press")
	DicMix.dic_back(4)


## viewWillDisappear: (0x948E8): [spoon viewWithTag:326 stop] (nil -- no
## emitter in dicStir), fire_loop / stirring / mixer / stir_unfinished off;
## viewDidDisappear: (0x949D4) hides instIV. Nothing else.
func on_exit() -> void:
	Audio.stop("fire_loop")
	Audio.stop("stirring")
	Audio.stop("mixer")
	Audio.stop("stir_unfinished")
	dismiss_instruction()
