# Donut Ice Cream Sandwich step 1 (of a 4-round loop) -- drag this round's
# ingredients into the bowl.
#
# From the original binary (IMPs from the ObjC method list, Thumb-cleared):
#   initWithDonutMixture: 0xB7E04, initialize 0xB7E64, viewDidLoad 0xB7FA8,
#   viewWillAppear: 0xB82A8, viewDidAppear: 0xB85F0, resetIngredients 0xB6A90,
#   resetBowl 0xB6F3C, addIngredient:ivCenter: 0xB6C10, stopPouringSound
#   0xB6EFC, draggableTouchEnded:fromSender: 0xB79F0, nextClick: 0xB746C,
#   nextScreen 0xB74C8, skipClick: 0xB7548, backClick: 0xB732C,
#   viewWillDisappear: 0xB863C, viewDidDisappear: 0xB86BC.
#
# Mechanic, as read -- NOT one screen but a LOOP. currentDonutMixture (0..3)
# selects which draggables resetIngredients (0xB6A90) unhides:
#   round 0: water + yeast     round 1: flour + milk
#   round 2: egg + butter + sugar + salt
#   round 3: bowlA + bowlB (two bowls of pre-made batter)
# The flow is mix(0) -> stir(0) -> mix(1) -> stir(1) -> ... -> mix(3) ->
# stir(3) -> dicRollCut; flows.json's single mix->stir pair is the compressed
# form. The port carries the round in
# GameState.custom_categories["donutMixture"] where the original threads it
# through initWithDonutMixture:.
#
#  * Drop test is *frame intersects bowl.frame* (0xB79F0), same as cdMix.
#  * A landed ingredient is NOT composited or jittered (unlike cdMix's
#    addIngredient) -- addIngredient:ivCenter: (0xB6C10) simply unhides the
#    nib-authored mixed view (its ivCenter argument is computed at the call
#    site and then never used) and plays a sound: water/milk "pouring" (m4a)
#    with stopPouringSound scheduled 0.5s later (double 0x3FE0000000000000),
#    egg "egg_crack", everything else "drop". The draggable is hidden and
#    reset to origCenter.
#  * Off-bowl release: 0.2s linear snap to origCenter (duration double
#    0x3FC99999A0000000, curve 3; tail of 0xB79F0).
#  * When every mixed view of the round is visible the screen AUTO-ADVANCES
#    (nextScreen, 0xB74C8, pushes dicStir initWithDonutMixture:round with
#    animated:NO). The next button is hidden by viewWillAppear: (0xB82A8) and
#    nothing on the free path ever shows it -- showNextButton's only caller
#    is the IAP consumablePurchased: chain.
#  * backClick: (0xB732C): if navStack[count-3] is a dicMix popToViewController
#    it -- TWO screens back, normally the previous round's mix -- else a plain
#    pop. Ported as the same stack test (dic_back below), with the landing
#    screen's round recomputed from the stack.
#
# The DM_CONSUMABLE_SKIP consumable (initialize 0xB7E64, buyClick: 0xB72C0,
# consumablePurchased: 0xB7058 -> skipClick: 0xB7548 which jumps a whole
# round) is a 3-coin consumable, not IAP; PORTED, see the skip
# block. The nib ships skipButton hidden; only the code-built
# ConsumableButton reached skipClick:.
#
# Mixed views are drawn per the nib's contentMode: cm=4 (center) views whose
# art differs from the frame are re-anchored (egg 90x72, butter 100x56,
# sugar 110x82 in 105x105 frames); salt / bowlA / bowlB have no contentMode
# (scaleToFill) and are scaled to their frames.
#
# KEEP-STATE: every mix round is kept alive under its
# push (keeps_state_on_push). viewDidLoad's badge / mixed-view layout /
# draggables are built once; viewWillAppear: + viewDidAppear: run on entry
# and in on_resume, which resets the round (see on_resume). A returned-to
# round keeps its own _round, so dic_back's GameState round write only
# matters for a screen Nav has to rebuild.

extends "res://core/Screen.gd"

## park_instruction.
const UIKit := preload("res://screens/msUIKit.gd")

## Skip consumable (PORTED; the phone shows the badge):
## initialize 0xB7E64 builds Consumable DM_CONSUMABLE_SKIP / Skip_10Ingredients,
## cost = the dead server table GameData.CoinCosts ... SkipIngredients, 3 when
## absent; first-time message below. viewDidLoad 0xB7FA8 builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0xB72C0 ("store" sound,
## purchaseConsumable). consumablePurchased: 0xB7058 calls skipClick: 0xB7548 -- button_press, then push dicRollCut when the round is 3, else the next round's mix.
## consumablePurchaseFailed:error: 0xB71EC (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_10Ingredients"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton

const DraggableSprite2D := preload("res://core/DraggableSprite2D.gd")

## Nib frame of the bowl (id 2).
const BOWL_RECT := Rect2(38, 198, 244, 244)

## resetIngredients (0xB6A90): round -> the draggables it unhides.
const ROUNDS := {
	0: ["water", "yeast"],
	1: ["flour", "milk"],
	2: ["egg", "butter", "sugar", "salt"],
	3: ["bowlA", "bowlB"],
}

## Draggable nib frames + art (nib ids 14..23). UIImageView scaleToFill: art scaled to the frame.
const DRAGGABLES := {
	"water": {"frame": Rect2(190, 55, 73, 135), "art": "cff_water_bottle.png"},
	"yeast": {"frame": Rect2(57, 53, 76, 137), "art": "dis_ingred_yeast_01.png"},
	"flour": {"frame": Rect2(57, 55, 87, 135), "art": "dis_ingred_flour_01.png"},
	"milk": {"frame": Rect2(190, 55, 73, 135), "art": "cd_ingred_milk.png"},
	"egg": {"frame": Rect2(71, 42, 62, 76), "art": "cd_ingred_egg.png"},
	"butter": {"frame": Rect2(177, 53, 104, 65), "art": "dis_ingred_butter_01.png"},
	"sugar": {"frame": Rect2(207, 114, 65, 76), "art": "lsu_sugar_bag.png"},
	"salt": {"frame": Rect2(38, 126, 133, 53), "art": "dis_ingred_salt.png"},
	"bowlA": {"frame": Rect2(64, 86, 80, 80), "art": "dis_ingred_bowl_a.png"},
	"bowlB": {"frame": Rect2(177, 86, 80, 80), "art": "dis_ingred_bowl_b.png"},
}

## Mixed-view nib frames (ids 4..13) and contentMode: "center" (cm=4) draws
## the art at natural size centred in the frame; "fill" (no cm) scales it.
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

## addIngredient:ivCenter: (0xB6C10): the per-ingredient sound.
const SOUND := {
	"water": "pouring", "milk": "pouring", "egg": "egg_crack",
	"yeast": "drop", "flour": "drop", "butter": "drop", "sugar": "drop",
	"salt": "drop", "bowlA": "drop", "bowlB": "drop",
}
## stopPouringSound scheduled 0.5s after the pour (double 0x3FE0000000000000
## in 0xB6C10).
const POUR_STOP_DELAY := 0.5
## Off-bowl snap: 0.2s (double 0x3FC99999A0000000), curve 3 = linear.
const SNAP_SECONDS := 0.2

var _round := 0
var _needed: Array = []
var _drags: Dictionary = {}


## UINavigationController keeps this controller alive under a push; Nav
## calls on_resume() on back, including the
## popToViewController: from the next round's mix, which lands on THIS
## instance with its own currentDonutMixture.
func keeps_state_on_push() -> bool:
	return true


## initWithDonutMixture: (0xB7E04) + viewDidLoad (0xB7FA8) once, then
## viewWillAppear: (0xB82A8) and viewDidAppear: (0xB85F0).
func on_enter() -> void:
	# viewDidLoad built the badge before any viewWillAppear content.
	_build_skip()
	_round = int(GameState.custom_categories.get("donutMixture", 0))
	_needed = ROUNDS.get(_round, ROUNDS[0])

	_layout_mixed_views()
	_build_draggables()
	_will_appear()
	UIKit.park_instruction(self, true)   # nib: hidden


## viewDidAppear: runs when the push / pop slide is over.
func on_did_appear() -> void:
	_did_appear()


## Back to this round (popToViewController: from the next round's mix or
## the roll-cut, or a plain pop): viewWillAppear: RESETS the round --
## resetIngredients unhides this round's draggables (addIngredient left them
## hidden at origCenter), resetBowl hides every mixed view, next stays
## hidden -- and viewDidAppear: re-slides the instruction. The player adds
## the round's ingredients again and the screen auto-advances to a NEW stir.
func on_resume() -> void:
	_will_appear()
	# _did_appear() follows from on_did_appear(), after the slide.


## viewWillAppear: (0xB82A8): next hidden; ingredientAlpha 1 on every
## DraggableIV; milk's mixed view alpha 1 (flourAlpha 0.5 is written and
## never read); resetIngredients; resetBowl; the skip badge shown.
func _will_appear() -> void:
	var next := first_outlet(NEXT_OUTLETS)
	if next != null:
		(next as CanvasItem).visible = false
	var milk := outlet("milk")
	if milk != null and milk != self:
		(milk as CanvasItem).modulate.a = 1.0
	_reset_ingredients()
	_reset_bowl()
	if _skip_button != null:
		_skip_button.visible = true


## viewDidAppear: (0xB85F0).
func _did_appear() -> void:
	change_instruction("inst_add_to_bowl.png")


## viewWillDisappear: (0xB863C) stops stir_finished / stir_unfinished;
## viewDidDisappear: (0xB86BC) removes the bowl's subviews (the port adds
## none) and hides instIV. Nothing else -- the round's state stays.
func on_exit() -> void:
	Audio.stop("stir_finished")
	Audio.stop("stir_unfinished")
	dismiss_instruction()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## Re-anchor / scale the nib mixed views per contentMode (see header).
func _layout_mixed_views() -> void:
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


## resetBowl (0xB6F3C): every mixed view hidden.
func _reset_bowl() -> void:
	for n: String in MIXED:
		var s := outlet(n)
		if s != null and s != self:
			(s as CanvasItem).visible = false


## resetIngredients (0xB6A90): this round's draggables shown (and, from
## viewWillAppear:'s DraggableIV loop, alpha 1); addIngredient: already put
## each one back at origCenter when it landed.
func _reset_ingredients() -> void:
	for n: String in _drags:
		var s: DraggableSprite2D = _drags[n]
		s.visible = true
		s.enabled = true
		s.modulate.a = 1.0


## Only this round's draggables exist (resetIngredients hides the rest). The scene's
## outlet nodes are empty Node2Ds; the art sprites are built beside them, at
## the outlet's place in the nib order -- above the mixed views, BELOW instIV,
## back, next and the skip badge (nib ids 14..23 precede 24..27), which the
## port used to invert by appending them last.
func _build_draggables() -> void:
	for n: String in _needed:
		var d: Dictionary = DRAGGABLES[n]
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
		var slot := outlet(n + "Draggable")
		if slot != null and slot != self and slot.get_parent() == self:
			slot.add_sibling(s)
		else:
			add_child(s)
		_drags[n] = s


## draggableTouchEnded: (0xB79F0): frame-intersects-bowl adds the ingredient;
## anything else animates back to origCenter over 0.2s linear.
func _on_ingredient_released(_pos: Vector2, _on_target: bool, n: String) -> void:
	var s: DraggableSprite2D = _drags[n]
	var frame_now := Rect2(s.position, (DRAGGABLES[n]["frame"] as Rect2).size)
	if frame_now.intersects(BOWL_RECT):
		_add_ingredient(n, s)
	else:
		s.return_to_origin(SNAP_SECONDS)


## addIngredient:ivCenter: (0xB6C10): unhide the nib mixed view, play the
## sound, hide the draggable. Then the tail of 0xB79F0: auto-advance when the
## whole round is in.
func _add_ingredient(n: String, s: DraggableSprite2D) -> void:
	var mixed := outlet(n)
	if mixed != null and mixed != self:
		(mixed as CanvasItem).visible = true
	var snd: String = SOUND[n]
	# playFile:ofType: for every ingredient -- "pouring" included (it is a
	# one-shot; the port used to loop it). Audio.stop cuts the newest
	# one-shot of a name, as stopPlayerForFile: did.
	Audio.play(snd)
	if snd == "pouring":
		# performSelector:stopPouringSound afterDelay:0.5. A scene-tree timer
		# outlives the screen, as the original's retained selector did.
		get_tree().create_timer(POUR_STOP_DELAY).timeout.connect(
			func() -> void: Audio.stop("pouring"))
	s.visible = false
	s.enabled = false
	s.return_to_origin(0.0)

	for k: String in _needed:
		var mv := outlet(k)
		if mv == null or mv == self or not (mv as CanvasItem).visible:
			return
	# PORT CHOICE: deferred to the end of this frame. The original pushes
	# synchronously inside draggableTouchEnded:; here that call is inside the
	# DraggableSprite2D's own _unhandled_input, and Nav now takes a kept
	# screen OUT of the tree immediately, after which the draggable's
	# get_viewport() is null. Nothing is drawn in between.
	_next_screen.call_deferred()


## nextScreen (0xB74C8): push dicStir with the same round --
## pushViewController:animated:NO, so no slide. Nav.push keeps the stack
## shape of pushViewController:.
## skipClick: (0xB7548) pushes animated:YES and keeps the default.
func _next_screen() -> void:
	var info: Dictionary = GameState.custom_categories.duplicate(true)
	info["donutMixture"] = _round
	GameState.custom_categories = info
	Nav.push("dicStirViewController", "dic", false)


## nextClick: (0xB746C): button_press + nextScreen. Unreachable on the free
## path (the button stays hidden) but kept faithful.
func _on_nextClick() -> void:
	Audio.play("button_press")
	_next_screen()


## backClick: (0xB732C): if navStack[count-3] isKindOfClass dicMix,
## popToViewController: it (TWO screens back), else a plain pop. The test is
## on the STACK, not on the round: after a skip-consumable push
## (mix(r-1) -> mix(r) with no stir between) count-3 is stir(r-2), so the
## original does a plain pop to mix(r-1). The port used to pop two whenever
## round > 0, landing on stir(r-2) in that case.
func _on_backClick() -> void:
	Audio.play("button_press")
	dic_back(3)


# -- the mix/stir loop's back navigation (shared with dicStir, dicRollCut) --

const MIX_SCREEN := "dicMixIngredientsViewController"
const STIR_SCREEN := "dicStirViewController"


## navigationController.viewControllers as screen names, bottom first
## (Nav.stack_names()).
static func nav_stack() -> Array:
	return Nav.stack_names()


## The round a mix/stir screen at stack index `t` was built with. Rounds are
## sequential in push order -- every dicMix push (stir nextClick:, mix
## skipClick:) is round+1, every stir push keeps its mix's round -- so the
## round is the count of mixes in the contiguous mix/stir run up to `t`, -1.
static func round_at(st: Array, t: int) -> int:
	var start := t
	while start > 0 and str(st[start - 1]) in [MIX_SCREEN, STIR_SCREEN]:
		start -= 1
	var mixes := 0
	for i in range(start, t + 1):
		if str(st[i]) == MIX_SCREEN:
			mixes += 1
	return maxi(mixes - 1, 0)


## The three classes' backClick: share one shape: if count - `min_back` >= 0
## and navStack[count-3] is a dicMix, popToViewController: it; else pop one.
## (dicMix and dicRollCut test count-3 >= 0, dicStir count-4 >= 0.) A kept
## screen comes back with its own round; the GameState write below
## only matters when Nav has to rebuild the landing screen.
## popToViewController: is Nav.pop_to_depth(): it builds only the
## landing screen -- two back() calls used to build, and on_enter, the one
## in between.
static func dic_back(min_back: int) -> void:
	var st := nav_stack()
	var n := st.size()
	var target := n - 2
	var pop_to := false
	if n - min_back >= 0 and n >= 3 and str(st[n - 3]) == MIX_SCREEN:
		target = n - 3
		pop_to = true
	if target >= 0 and target < n and str(st[target]) in [MIX_SCREEN, STIR_SCREEN]:
		var info: Dictionary = GameState.custom_categories.duplicate(true)
		info["donutMixture"] = round_at(st, target)
		GameState.custom_categories = info
	if pop_to:
		Nav.pop_to_depth(target + 1)
	else:
		Nav.back()


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
	# viewDidLoad: insertSubview:buySkip aboveSubview:instIV -- above the
	# banner, below back / next / the nib's hidden skipButton.
	var inst := outlet("instIV")
	if inst != null and inst != self and inst.get_parent() == self:
		inst.add_sibling(b)
	else:
		add_child(b)
	_skip_button = b


## buyClick: -- "store" sound, purchaseConsumable.
func _on_buyClick() -> void:
	Audio.play("store")
	_skip.call("purchase", self)


## consumablePurchased: -> skipClick: (see header).
func _on_skip_purchased(_free: bool) -> void:
	_on_skipClick()


## skipClick: (0xB7548): button_press; round 3 -> dicRollCut, else the next
## round's mix. Same Nav.push stack shape as pushViewController:.
func _on_skipClick() -> void:
	Audio.play("button_press")
	if _round == 3:
		Nav.push("dicRollCutViewController", "dic")
	else:
		var info: Dictionary = GameState.custom_categories.duplicate(true)
		info["donutMixture"] = _round + 1
		GameState.custom_categories = info
		Nav.push("dicMixIngredientsViewController", "dic")
