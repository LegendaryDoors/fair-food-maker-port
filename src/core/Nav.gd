# Screen stack, standing in for UINavigationController.
#
# Screens are built from the import cache (Assets.instantiate_screen, the
# runtime form of the generated scenes) and carry no script, so this attaches
# one on load: a bespoke controller from res://screens/<Name>.gd if it exists,
# otherwise the generic Screen base. That is what lets every screen be opened and navigated before
# any gameplay is written.
#
# `next()` walks the current food's step list from data/flows.json.
#
# PUSH / POP TRANSITION (read from iOS 6.1.3 UIKit).
# -[UINavigationTransitionView transition:
# fromView:toView:] (0x32FA8B00):
#   * push (transition 1): the new view starts one screen width to the right
#     and the old one ends one width to the left; pop (2) is the mirror.
#     Both views move the full 320 pt together -- no parallax, no fade.
#   * +defaultDurationForTransition: (0x32FAA6D0) 0.35 s; UIView's default
#     curve, EaseInOut (0.42, 0, 0.58, 1); setAnimationRoundsToInteger:YES.
#   * -[UIApplication beginIgnoringInteractionEvents] for the whole slide;
#     _cleanupTransition (0x32FB0EBC) ends it.
#   * Order (_startTransition:fromViewController:toViewController:
#     0x32FA5598, navigationTransitionView:didEndTransition:fromView:toView:
#     0x32FB14C0): old viewWillDisappear: and new viewWillAppear: at the
#     start; old viewDidDisappear:, new viewDidAppear: and the delegate's
#     navigationController:didShowViewController:animated: at the end.
#     Here: on_exit() / on_enter() / on_resume() at the start (as before),
#     the optional on_did_appear() and `transition_finished` at the end.
#     `screen_changed` keeps its old timing (start) so nothing listening to it
#     changes behaviour.
#   * animated:NO swaps at once (no slide, no lockout); on_did_appear() and
#     transition_finished still fire, immediately.

extends Node

signal screen_changed(screen_name: String)
## navigationController:didShowViewController:animated: -- after the slide.
signal transition_finished(screen_name: String)

const UIScrollSim := preload("res://core/UIScrollSim.gd")

const SCRIPT_DIR := "res://screens/%s.gd"
const FLOWS := "res://data/flows.json"

## +[UINavigationTransitionView defaultDurationForTransition:] (0x32FAA6D0):
## 0x3FD6666666666666 for transitions 1-4 and 7.
const TRANSITION_DURATION := 0.35
## The transition view's bounds width -- the whole screen on this app.
const SCREEN_WIDTH := 320.0

## Steps whose nextClick: passes animated:NO to pushViewController:
## (addresses are the nextClick: IMPs in the game binary). next() looks the
## CURRENT screen up here. dicMixIngredientsViewController's nextScreen
## (0xB74C8) is animated:NO too but calls Nav.push() itself -- it must pass
## animated = false there.
const NEXT_NOT_ANIMATED := {
	"caSelectChocolate": 0x1579BC,
	"ccSugarPickerViewController": 0x845C4,
	"ccbSelectChocolate": 0xC060C,
	"cdMixIngredientsViewController": 0x85CB0,
	"cffAddWaterViewController": 0x13F7D4,
	"cffFrySliceViewController": 0x141E1C,
	"cffSelectSlicer": 0x145F6C,
	"fcMixBatterVC": 0x8A654,
	"kcPourOilViewController": 0x10677C,
	"kcSelectSugarViewController": 0x110070,
	"kcShakeToFlattenKernelsViewController": 0x109068,
	"scCrushIceViewController": 0x70F1C,
}
## Screens whose backClick: passes animated:NO to popViewControllerAnimated:.
## back() looks the CURRENT screen up here.
const BACK_NOT_ANIMATED := {
	"caStirIngredients": 0x15B904,
	"ccbStirIngredients": 0x1E330,
	"cdStirViewController": 0x131CEC,
	"cffAddWaterViewController": 0x13F89C,
	"cffPeelViewController": 0x139C70,
	"fcStirViewController": 0x1363E0,
	"kcSelectSugarViewController": 0x110000,
	"kcShakeToColorKernelsViewController": 0x114408,
	"kcShakeToFlattenKernelsViewController": 0x108FF8,
}

var flows: Dictionary = {}

## Master switch for the UIKit animations that hold up interaction: the
## push/pop slide here and UIAlertView's pop-out (Screen.show_alert).
## null (default) = automatic: ON when the running scene is the game's main
## scene (Boot), OFF under a dev harness, whose assertions (a covered screen
## out of the tree, a tap landing on the next frame) predate them. A harness
## that wants the real thing sets it true.
## PORT CHOICE for the harnesses; the game itself always animates.
var animate_transitions: Variant = null


func animations_enabled() -> bool:
	if animate_transitions != null:
		return bool(animate_transitions)
	var cs := get_tree().current_scene if is_inside_tree() else null
	return cs != null and cs.scene_file_path \
		== str(ProjectSettings.get_setting("application/run/main_scene", ""))

var _stack: Array[String] = []
var _current: Node = null
var _root: Node = null
## Food prefix whose step list next() is walking, e.g. "ms".
var _flow_key: String = ""
var _flow_index: int = -1
## _flow_index while each stack entry was on top, parallel to _stack. back()
## restores the index of the entry it lands on instead of decrementing: a
## non-step screen pushed over a step (GET COINS -> CoinStore, the prize
## shelf) used to take the index one short, so next() re-pushed the current
## step.
var _flow_at: Array[int] = []
## Screens kept alive under a pushed screen, by stack index (see push()).
var _kept: Dictionary = {}

## The slide in progress (empty when none).
var _transition: Dictionary = {}
var _transition_tween: Tween
## beginIgnoringInteractionEvents nesting, and the gate that enforces it.
var _ignore_count := 0
var _ignore_gate: Node = null


func _ready() -> void:
	var f := FileAccess.open(FLOWS, FileAccess.READ)
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if typeof(parsed) == TYPE_DICTIONARY:
			flows = parsed
	else:
		push_warning("no %s -- next() will not advance" % FLOWS)


## The node new screens are parented to. Set once by the boot scene.
func set_root(root: Node) -> void:
	_root = root


## Flow keys, excluding the metadata entries in flows.json.
func flow_keys() -> Array[String]:
	var keys: Array[String] = []
	for k: String in flows.keys():
		var v: Variant = flows[k]
		if typeof(v) == TYPE_DICTIONARY and v.has("steps"):
			keys.append(k)
	keys.sort()
	return keys


func exists(screen_name: String) -> bool:
	return resolve(screen_name) != ""


## Some screens only ship as iOS device variants (dicFrostingViewController
## exists solely as ~iphone and ~ipad). Fall back the way UIKit would.
## Returns the nib the screen is built from ("X", "X~iphone", "X~ipad"), or
## "" when there is none.
func resolve(screen_name: String) -> String:
	for candidate in [screen_name, screen_name + "~iphone", screen_name + "~ipad"]:
		if Assets.has_screen(candidate):
			return candidate
	return ""


## The live screen instance, for tests and debug tooling.
func current_node() -> Node:
	return _current


func current_name() -> String:
	return _stack.back() if not _stack.is_empty() else ""


func depth() -> int:
	return _stack.size()


## navigationController.viewControllers, as class names, bottom first.
func stack_names() -> Array[String]:
	return _stack.duplicate()


## True while a push/pop slide is running.
func is_transitioning() -> bool:
	return not _transition.is_empty()


## popToViewController:animated: -- pop until `target_depth` screens remain,
## building only the screen that ends up on top (back() in a loop would
## instantiate and on_enter every screen in between).
func pop_to_depth(target_depth: int, animated: bool = true) -> void:
	target_depth = clampi(target_depth, 1, _stack.size())
	if target_depth == _stack.size():
		return
	_stack.resize(target_depth)
	_flow_at.resize(target_depth)
	_flow_index = _flow_at.back() if not _flow_at.is_empty() else -1
	var top := _stack.size() - 1
	if _kept.has(top):
		_restore_kept(top, animated)
	else:
		_load(_stack.back(), false, animated, -1)
	_drop_kept_from(_stack.size())


## Push a screen. `flow` names the food step list next() should follow.
## `animated` is pushViewController:animated:'s BOOL (every push in the game
## passes YES except the NEXT_NOT_ANIMATED steps).
##
## UINavigationController keeps the covered controller alive, so popping back
## shows it exactly as it was left. Nav normally rebuilds a screen on back();
## a screen that must survive (MakeViewController: the decorated food under
## Eat) opts in by defining `keeps_state_on_push() -> bool` returning true.
## It is then taken out of the tree -- not freed -- on push, and back() puts
## the same instance back and calls its `on_resume()` if it has one (its
## _ready/on_enter do not run again). Screens without the method behave as
## before. (Opt-in, so no existing screen changes.)
func push(screen_name: String, flow: String = "", animated: bool = true) -> bool:
	_drop_kept_from(_stack.size())
	if not _load(screen_name, true, animated, 1):
		return false
	_stack.append(screen_name)
	if flow != "":
		_set_flow(flow, screen_name)
	_flow_at.append(_flow_index)
	return true


## Replace the top of the stack rather than growing it. Never animated
## (setViewControllers:animated: is not used by the game).
func replace(screen_name: String) -> bool:
	_drop_kept_from(maxi(_stack.size() - 1, 0))
	if not _load(screen_name):
		return false
	if _stack.is_empty():
		_stack.append(screen_name)
		_flow_at.append(_flow_index)
	else:
		_stack[-1] = screen_name
		if _flow_at.is_empty():
			_flow_at.append(_flow_index)
		else:
			_flow_at[-1] = _flow_index
	return true


## popViewControllerAnimated:. `animated` defaults to what the current
## screen's backClick: passes (BACK_NOT_ANIMATED), so callers need not say.
func back(animated: Variant = null) -> void:
	if _stack.size() <= 1:
		print("[Nav] at root, nothing to pop")
		return
	var anim: bool = (not BACK_NOT_ANIMATED.has(current_name())) if animated == null \
		else bool(animated)
	_stack.pop_back()
	_flow_at.pop_back()
	_flow_index = _flow_at.back() if not _flow_at.is_empty() else -1
	var top := _stack.size() - 1
	if _kept.has(top):
		_restore_kept(top, anim)
	else:
		_load(_stack.back(), false, anim, -1)
	_drop_kept_from(_stack.size())


## popToRootViewControllerAnimated: -- straight back to the first screen with
## nothing in between shown (EatViewController startOver: 0xA2958, animated
## YES). Calling back() in a loop instead instantiated every intermediate
## screen and ran its on_enter (sounds, timers) on the way down.
func pop_to_root(animated: bool = true) -> void:
	if _stack.size() <= 1:
		return
	_stack.resize(1)
	_flow_at.resize(1)
	_flow_key = ""
	_flow_index = -1
	_flow_at[0] = -1
	if _kept.has(0):
		_restore_kept(0, animated)
	else:
		_load(_stack[0], false, animated, -1)
	_drop_kept_from(1)


func _restore_kept(index: int, animated: bool = false) -> void:
	var node: Node = _kept[index]
	_kept.erase(index)
	if not is_instance_valid(node):
		_load(_stack[index], false, animated, -1)
		return
	_complete_transition_now()
	var old := _current
	if old != null and old.has_method("on_exit"):
		old.on_exit()
	_drop_stale_coin_panel(node)
	_root.add_child(node)
	_current = node
	if node.has_method("on_resume"):
		node.on_resume()
	_show(old, false, node, str(_stack[index]), animated, -1)
	screen_changed.emit(str(_stack[index]))


## The coins panel is ONE window-level view in the original:
## navigationController:didShowViewController:animated: (0x1AC3C) removes it
## from wherever it is and re-adds it to the screen being shown. The port's
## CoinHUD builds a fresh "CoinInfoView" on every screen_changed instead, so a
## kept screen came back carrying the panel from its first appearance plus a
## new one on top (two labels, the old one stale after a coin purchase).
## Drop the old one before the screen is shown again; CoinHUD then adds the
## current one. (A kept screen that already
## removes it in on_resume -- MakeViewController -- simply finds nothing.)
func _drop_stale_coin_panel(node: Node) -> void:
	var old := node.get_node_or_null("CoinInfoView")
	if old != null:
		node.remove_child(old)
		old.queue_free()


func _exit_tree() -> void:
	_complete_transition_now()
	_drop_kept_from(0)
	if _ignore_gate != null and is_instance_valid(_ignore_gate):
		_ignore_gate.queue_free()


## Free kept screens at stack index >= `from` (popped, replaced or stale).
func _drop_kept_from(from: int) -> void:
	for i: int in _kept.keys():
		if i >= from:
			var n: Node = _kept[i]
			_kept.erase(i)
			if is_instance_valid(n):
				if n.is_inside_tree():
					n.get_parent().remove_child(n)
				n.queue_free()


## Advance within the current food's step list; falls off the end to the
## decorate screen, mirroring the original flow.
##
## Every food step's nextClick: PUSHES its successor
## (pushViewController:animated:, checked for all 12 foods), so
## back from a step returns to the previous step, not out of the food. This
## used to replace() the top of the stack, which made every back button
## inside a food leave the whole food.
##
## `animated` defaults to the current step's nextClick: BOOL
## (NEXT_NOT_ANIMATED).
func next(animated: Variant = null) -> void:
	if _flow_key == "" or not flows.has(_flow_key):
		print("[Nav] no flow for current screen; next() is a no-op")
		return
	var anim: bool = (not NEXT_NOT_ANIMATED.has(current_name())) if animated == null \
		else bool(animated)
	var steps: Array = flows[_flow_key].get("steps", [])
	_flow_index += 1
	if _flow_index < steps.size():
		push(steps[_flow_index], "", anim)
	else:
		_flow_index = steps.size()
		if exists("MakeViewController"):
			push("MakeViewController", "", anim)


func start_food(flow: String) -> void:
	if not flows.has(flow):
		push_error("unknown flow: %s" % flow)
		return
	var steps: Array = flows[flow].get("steps", [])
	if steps.is_empty():
		return
	_flow_key = flow
	_flow_index = 0
	# Starting a food resets its state. This used to be left to each food's
	# first screen calling GameState.begin() itself, which meant any harness
	# that walked a flow directly got an empty food prefix -- MakeViewController
	# then had no classStr and could not tell which food it was finishing.
	# Nav knows the flow key, so it belongs here; screens may still call
	# begin() and the second reset is harmless at step 0.
	GameState.begin(flow)
	push(steps[0])


func _set_flow(flow: String, screen_name: String) -> void:
	_flow_key = flow
	var steps: Array = flows.get(flow, {}).get("steps", [])
	_flow_index = steps.find(screen_name)


## `direction` 1 = push (new screen comes in from the right), -1 = pop.
func _load(screen_name: String, pushing: bool = false, animated: bool = false,
		direction: int = 1) -> bool:
	var nib := resolve(screen_name)
	if nib == "":
		push_error("no scene for %s (tried plain, ~iphone, ~ipad)" % screen_name)
		return false
	if _root == null:
		push_error("Nav.set_root() was never called")
		return false

	_complete_transition_now()
	var old := _current
	var keep_old := false
	if old != null:
		if old.has_method("on_exit"):
			old.on_exit()
		keep_old = pushing and old.has_method("keeps_state_on_push") \
				and bool(old.call("keeps_state_on_push")) and not _stack.is_empty()
		if keep_old:
			_kept[_stack.size() - 1] = old
	_current = null

	var inst: Node = Assets.instantiate_screen(nib)

	# Bespoke controller if one exists, generic Screen otherwise. A script that
	# fails to parse must complain rather than silently leave the scene
	# scriptless -- that failure mode once passed the whole test suite.
	var script: Script = load("res://core/Screen.gd")
	var script_path := SCRIPT_DIR % screen_name
	if ResourceLoader.exists(script_path):
		# A script with a parse error still loads as a non-null GDScript; only
		# can_instantiate() distinguishes it, and attaching one surfaces later
		# as a baffling "Nonexistent function 'new' in base 'GDScript'".
		var custom: Script = load(script_path)
		if custom == null or (custom is GDScript and not (custom as GDScript).can_instantiate()):
			push_error("%s failed to parse; falling back to Screen" % script_path)
		else:
			script = custom
	inst.set_script(script)
	inst.set("screen_name", screen_name)

	# UINavigationTransitionView adds the incoming view on top of the old one.
	_root.add_child(inst)
	_current = inst
	_show(old, keep_old, inst, screen_name, animated, direction)
	screen_changed.emit(screen_name)
	return true


# -- the slide ------------------------------------------------------------

## Bring `to_node` on screen over `from_node` (which leaves: freed, or kept
## out of the tree when `keep_from`).
func _show(from_node: Node, keep_from: bool, to_node: Node, to_name: String,
		animated: bool, direction: int) -> void:
	if not animated or not animations_enabled() or from_node == null \
			or not is_instance_valid(from_node) \
			or not (to_node is Node2D) or not (from_node is Node2D):
		_retire(from_node, keep_from)
		_did_appear(to_node, to_name)
		return
	var layers := {}
	for n: Node in [from_node, to_node]:
		for l: Node in n.find_children("*", "CanvasLayer", true, false):
			# Alerts are a separate UIWindow in UIKit: they do not slide.
			if not l.has_meta("uikit_window"):
				layers[l] = (l as CanvasLayer).offset
	_transition = {
		"from": from_node, "to": to_node, "to_name": to_name,
		"keep_from": keep_from, "dir": float(direction), "layers": layers,
	}
	begin_ignoring_interaction()
	_apply_slide(0.0)
	_transition_tween = create_tween()
	_transition_tween.tween_method(_apply_slide, 0.0, 1.0, TRANSITION_DURATION)
	_transition_tween.finished.connect(_complete_transition_now)


## Position both screens `t` (linear time, 0..1) through the slide.
func _apply_slide(t: float) -> void:
	if _transition.is_empty():
		return
	var p := UIScrollSim.curve(t, UIScrollSim.AnimCurve.EASE_IN_OUT)
	var dir: float = _transition["dir"]
	# setAnimationRoundsToInteger:YES -- whole points.
	var from_x := roundf(-dir * SCREEN_WIDTH * p)
	var to_x := roundf(dir * SCREEN_WIDTH * (1.0 - p))
	var from_node: Node = _transition["from"]
	var to_node: Node = _transition["to"]
	if is_instance_valid(from_node):
		(from_node as Node2D).position.x = from_x
	if is_instance_valid(to_node):
		(to_node as Node2D).position.x = to_x
	var layers: Dictionary = _transition["layers"]
	for l: Node in layers.keys():
		if not is_instance_valid(l):
			continue
		var base: Vector2 = layers[l]
		var owner_x := from_x if is_instance_valid(from_node) and from_node.is_ancestor_of(l) \
			else to_x
		(l as CanvasLayer).offset = Vector2(base.x + owner_x, base.y)


## Finish the running slide at once (its own end, or a new navigation that
## starts before it is over).
func _complete_transition_now() -> void:
	if _transition.is_empty():
		return
	var tr := _transition
	_transition = {}
	if _transition_tween != null and _transition_tween.is_valid():
		_transition_tween.kill()
	_transition_tween = null
	var from_node: Node = tr["from"]
	var to_node: Node = tr["to"]
	var layers: Dictionary = tr["layers"]
	for l: Node in layers.keys():
		if is_instance_valid(l):
			(l as CanvasLayer).offset = layers[l]
	if is_instance_valid(from_node):
		(from_node as Node2D).position.x = 0.0
	if is_instance_valid(to_node):
		(to_node as Node2D).position.x = 0.0
	_retire(from_node, tr["keep_from"])
	end_ignoring_interaction()
	_did_appear(to_node, tr["to_name"])


func _retire(node: Node, keep: bool) -> void:
	if node == null or not is_instance_valid(node):
		return
	if keep:
		if node.is_inside_tree():
			node.get_parent().remove_child(node)
	else:
		node.queue_free()


## viewDidAppear: + navigationController:didShowViewController:animated:.
func _did_appear(node: Node, screen_name: String) -> void:
	if node != null and is_instance_valid(node) and node == _current \
			and node.has_method("on_did_appear"):
		node.call("on_did_appear")
	transition_finished.emit(screen_name)


# -- ignoring interaction ---------------------------------------------------

## -[UIApplication beginIgnoringInteractionEvents]: no touch reaches anything
## until the matching end. Nested calls count, as UIKit's do. Used by the
## navigation slide and by Screen.show_alert's pop-in / pop-out.
func begin_ignoring_interaction() -> void:
	_ignore_count += 1
	if _ignore_count == 1:
		_ignore_gate = add_touch_gate(Callable())


func end_ignoring_interaction() -> void:
	if _ignore_count == 0:
		return
	_ignore_count -= 1
	if _ignore_count == 0 and _ignore_gate != null:
		if is_instance_valid(_ignore_gate):
			_ignore_gate.set("active", false)
			_ignore_gate.queue_free()
		_ignore_gate = null


func is_ignoring_interaction() -> bool:
	return _ignore_count > 0


## A node that swallows every pointer event before anything else sees it
## (it sits last under the root viewport, and _input runs last-node-first),
## handing each to `handler` (if valid). Free it to lift the block. Screen's
## alerts use one to take all touches the way UIKit's alert window does.
func add_touch_gate(handler: Callable) -> Node:
	var gate := TouchGate.new()
	gate.name = "UIKitTouchGate"
	gate.handler = handler
	get_tree().root.add_child.call_deferred(gate)
	return gate


class TouchGate extends Node:
	var handler: Callable
	## Cleared when the gate is released (it may outlive that by a frame).
	var active := true

	func _input(event: InputEvent) -> void:
		if not active:
			return
		if not (event is InputEventMouseButton or event is InputEventMouseMotion \
				or event is InputEventScreenTouch or event is InputEventScreenDrag):
			return
		if handler.is_valid():
			handler.call(event)
		var vp := get_viewport()
		if vp != null:
			vp.set_input_as_handled()
