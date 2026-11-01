# Funnel Cake step 1 -- pick a batter bowl.
#
# GROUNDED from batter1Click: (0xDC1C0), batter2Click: (0xDC2E8), batter3Click:
# (0xDC430), batter4Click: (0xDC578), hideAllGlows (0xDBF98), showNextButton
# (0xDC018), viewWillAppear: (0xDC840), nextClick: (0xDC72C) and viewDidLoad
# (0xDCAB4, analytics only). Read from the original binary; hideAllGlows
# cross-checked at instruction level in the disassembly.
#
# The nib supplies four batter bowls with a glow behind each and a lock badge
# on bowls 2-4. viewWillAppear: (0xDC840) hides the locks when
# FF_KEY_FUNNEL_CAKE or FF_KEY_EVERYTHING is set; the port ships everything
# unlocked (Screen.gd), so showLockedMessage (0xDBF08) and its UIAlertView
# (alertView:clickedButtonAtIndex: 0xDBE60) are unreachable and not ported.

extends "res://core/Screen.gd"

## The batter id each bowl button stores into batterID. NOT sequential:
## button 3 stores 3 (chocolate) and button 4 stores 2 (caramel) -- the id
## meanings come from fcMixBatterVC setIngredients (0x89938): 0 original,
## 1 strawberry, 2 caramel, 3 chocolate. Read from the four click handlers.
const BATTER_FOR_BUTTON := {1: 0, 2: 1, 3: 3, 4: 2}

## setAnimationDuration for the glow fade-in: 0.3 (double (0x33333333,
## 0x3FD33333) in all four click handlers), UIViewAnimationCurve 3 = linear,
## alpha 0 -> 1.
const GLOW_FADE := 0.3

var _batter := 0
var _picked := false
## The 0.3s glow fade. Killed by viewWillAppear:'s hideAllGlows so a fade
## left running under a push cannot re-light a glow on the way back.
var _glow_tween: Tween


func on_enter() -> void:
	GameState.begin("fc")
	_view_will_appear()


## UINavigationController keeps this controller alive under the pushed mix
## screen (Nav.gd's opt-in); back shows it again and only viewWillAppear:
## re-runs.
func keeps_state_on_push() -> bool:
	return true


## Back from the mix screen: viewWillAppear: (0xDC840) runs again -- every glow
## to alpha 0, next back to alpha 0 and hasShownNextButton = 0, so the arrow
## returns only with the next pick. The chosen batter id is NOT reset.
## (viewDidDisappear: is super only, so there is no on_exit work.)
func on_resume() -> void:
	_picked = false
	_view_will_appear()


## viewWillAppear: (0xDC840).
func _view_will_appear() -> void:
	if _glow_tween != null and _glow_tween.is_valid():
		_glow_tween.kill()
	# hideAllGlows (0xDBF98) zeroes every glow's alpha; viewWillAppear: calls
	# it before anything is picked.
	for i in range(1, 5):
		var g := outlet("batter%dGlow" % i)
		if g != null and g != self:
			(g as CanvasItem).modulate.a = 0.0
	# isPurchased branch of viewWillAppear: (0xDC840): all three locks hidden.
	for lock_name in ["lock2", "lock3", "lock4"]:
		var l := outlet(lock_name)
		if l != null and l != self:
			(l as CanvasItem).visible = false
	# nextButton: setEnabled:1, setAlpha:0, hasShownNextButton = 0.
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false


func _on_batter1Click() -> void:
	_pick(1)


func _on_batter2Click() -> void:
	_pick(2)


func _on_batter3Click() -> void:
	_pick(3)


func _on_batter4Click() -> void:
	_pick(4)


## Shared body of the four click handlers: play button_press, store the batter
## id, hide all glows, fade the picked bowl's glow in over 0.3s linear, and
## slide the next button in the first time only (hasShownNextButton).
func _pick(button: int) -> void:
	Audio.play("button_press")
	_batter = BATTER_FOR_BUTTON[button]
	for i in range(1, 5):
		var g := outlet("batter%dGlow" % i)
		if g == null or g == self:
			continue
		var ci := g as CanvasItem
		ci.modulate.a = 0.0
		if i == button:
			_glow_tween = create_tween()
			_glow_tween.tween_property(ci, "modulate:a", 1.0, GLOW_FADE) \
				.set_trans(Tween.TRANS_LINEAR)
	if not _picked:
		_picked = true
		# showNextButton (0xDC018): centre + (500, 0), back over 0.25s curve 0
		# -- exactly Screen.show_next_button's grounded numbers.
		show_next_button()


## nextClick: (0xDC72C) pushes fcMixBatterVC initWithBatter:batterID. The
## port's carrier for that init argument is GameState.custom_categories.
## The original has no pick guard: next itself is unreachable until a pick
## (alpha 0 until showNextButton), but skip reaches it at any time.
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.custom_categories = {"batter": _batter}
	Nav.next()


## skipClick: (0xDC7EC) calls nextClick: -- with no pick, batterID is still
## its zeroed ivar, i.e. 0 = original batter. Its sender is the nib's
## "Debug Skip" UIRoundedRectButton (99, 375, 106, 37), alpha 0.6, which
## ships UIHidden=YES and has no outlet, so nothing ever shows it -- the
## generated scene hides it too, and it is unreachable. (An older reading
## of "never hidden" came from swapped NIBArchive bool tags.)
func _on_skipClick() -> void:
	_on_nextClick()


## backClick: (0xDC6C0): pop, then button_press. (The base Screen back is
## silent.)
func _on_backClick() -> void:
	Nav.back()
	Audio.play("button_press")
