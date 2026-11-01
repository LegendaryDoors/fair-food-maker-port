# Corn Dog step 1 -- pick a batter bowl.
#
# GROUNDED from batter1Click: (0xD8740), batter2Click: (0xD8868), batter3Click:
# (0xD89B0), batter4Click: (0xD8AF8), hideAllGlows (0xD8518), showNextButton
# (0xD8598), viewWillAppear: (0xD8DC0), nextClick: (0xD8CAC), skipClick:
# (0xD8D6C), backClick: (0xD8C40) and initWithNibName:bundle: (0xD8D80).
#
# The nib supplies four batter bowls with a glow sprite behind each and a lock
# badge on bowls 2-4. viewWillAppear: (0xD8DC0) hides the locks and sets
# isPurchased when FF_KEY_CORN_DOG or FF_KEY_EVERYTHING is set; the port ships
# everything unlocked (see Screen.gd), so the locked branch -- showLockedMessage
# (0xD8488), the "Go to Store" UIAlertView and alertView:clickedButtonAtIndex:
# (0xD83E0) -- is unreachable and not ported.

extends "res://core/Screen.gd"

## The batter id each bowl button stores into cornDogBatter. NOT sequential:
## button 2 stores 2 (chocolate), button 3 stores 3 (spicy), button 4 stores 1
## (honey). Read from the four click handlers listed above.
const BATTER_FOR_BUTTON := {1: 0, 2: 2, 3: 3, 4: 1}

## setAnimationDuration for the glow fade-in: 0.3 (doubles at 0xD8860 / 0xD89A8
## / 0xD8AF0 / 0xD8C38: lo 0x33333333 hi 0x3FD33333),
## UIViewAnimationCurve 3 = linear, alpha 0 -> 1.
const GLOW_FADE := 0.3

var _batter := 0
var _picked := false
## The 0.3s glow fade. Killed by viewWillAppear:'s hideAllGlows so a fade
## left running under a push cannot re-light a glow on the way back.
var _glow_tween: Tween


func on_enter() -> void:
	GameState.begin("cd")
	_view_will_appear()


## UINavigationController keeps this controller alive under the pushed mix
## screen (Nav.gd's opt-in); back shows it again and only viewWillAppear:
## re-runs.
func keeps_state_on_push() -> bool:
	return true


## Back from the mix screen: viewWillAppear: (0xD8DC0) runs again -- every glow
## to alpha 0, next back to alpha 0 and hasShownNextButton = 0, so the arrow
## returns only with the next pick. The chosen batter id is NOT reset.
## (viewDidDisappear: is super only, so there is no on_exit work.)
func on_resume() -> void:
	_picked = false
	_view_will_appear()


## viewWillAppear: (0xD8DC0).
func _view_will_appear() -> void:
	if _glow_tween != null and _glow_tween.is_valid():
		_glow_tween.kill()
	# hideAllGlows (0xD8518) zeroes every glow's alpha; viewWillAppear: calls
	# it before anything is picked.
	for i in range(1, 5):
		var g := outlet("batter%dGlow" % i)
		if g != null and g != self:
			(g as CanvasItem).modulate.a = 0.0
	# isPurchased branch of viewWillAppear: (0xD8DC0): all three locks hidden.
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
## show the next button the first time only (hasShownNextButton).
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
		# showNextButton (0xD8598): centre + (500, 0), slide back over 0.25s
		# curve 0 -- exactly Screen.show_next_button's grounded numbers.
		show_next_button()


## nextClick: (0xD8CAC) pushes cdMixIngredientsViewController initWithBatter:
## cornDogBatter. The port's carrier for that init argument is
## GameState.custom_categories, the same dictionary the original threads as
## its infoDict from cdRollDog onward.
##
## No pick guard: the next arrow sits at alpha 0 until a pick (UIKit does not
## hit-test it, the port hides it). skipClick: below would reach this with
## whatever cornDogBatter holds, but its button is hidden (see there).
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.custom_categories = {"batter": _batter}
	Nav.next()


## skipClick: (0xD8D6C) calls nextClick: unconditionally. Its button is the
## nib's 106x37 "Debug Skip" rounded-rect at (99, 375), alpha 0.6 -- which
## ships UIHidden=YES and has no outlet, so nothing ever shows it: dead on the
## device and in the port. (An earlier note called it live in v1.27; that was
## the swapped NIBArchive bool tags, since fixed.) Kept as read.
func _on_skipClick() -> void:
	_on_nextClick()


## backClick: (0xD8C40): pop, then button_press.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()
