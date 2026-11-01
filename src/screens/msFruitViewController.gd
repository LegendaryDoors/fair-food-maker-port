# Milkshake step 3 -- tap fruit, candy or nuts to add them to the blender.
#
# Ported from viewWillAppear: (0x4B4F0), loadFruitItemsToScrollview:
# (0x4B8A0), loadCandyItemsToScrollview: (0x4C780), loadNutItemsToScrollview:
# (0x4D964), initFlavors (0x4E2D8), consumablePurchased: (0x4E774),
# touchesBegan:withEvent: (0x4F11C), clearScrollViewItems (0x4F324),
# flavorItemClicked: (0x4F404), addExtra:tag:animate: (0x4F6B8) and
# sendSplash (0x4FB68), checked line by line against the original code.
# Kept alive under the push: viewWillAppear: (0x4B4F0) re-runs in
# on_resume(), viewDidAppear: (0x4B808) in on_did_appear(), and the nib's
# `splash` SSEmitter is wired.
#
# The picker's UIScrollView never scrolls: each loader's contentSize
# ((320,200) fruit / nuts, (320,280) candy) equals the frame it opens to, so
# _canScrollY is false and the vertical indicator (nib default on) never
# shows. Its touches are taps.
#
# Tap-to-add, not drag: this class's Draggable delegate methods are empty
# stubs (0x4F3F8/0x4F3FC/0x4F400). The step is optional, but next is NOT live
# from the start: viewWillAppear: hides it and schedules showNextButton at
# +3.0s; the first item, the first stray touch or a mystery purchase shows it
# sooner. (The port used to show it at once.)

extends "res://core/Screen.gd"

const UIKit := preload("res://screens/msUIKit.gd")
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
const SSEmitterConfigs := preload("res://core/particles/SSEmitterConfigs.gd")

## The nib's SSEmitter (id 2, frame (20,90,279,250), second subview: above
## bg_milkshake, below the picker, the milk and the jar). viewDidLoad
## (0x4B0A0, call 0x4B3E0) configures it once with milkColor: four
## Milk_Shake_Splash_PS frames, 0.02s apart, fading out in place, repeat:NO.
## Started by sendSplash and by consumablePurchased:; it stops itself.
const SPLASH := "msFruitViewController.splash"

## = the nib's blenderDetectionView frame.
const BLENDER_RECT := Rect2(40, 309, 240, 171)

# -- picker geometry, read from the three loaders -----------------------

const BTN_SIZE := Vector2(80, 80)
const BTN_COLS := 4
## Buttons sit at x = 0, 80, 160, 240 and y = 10, 90 (, 170 for candy).
const BTN_ROW_Y := 10.0
const ICON_RECT := Rect2(10, 10, 60, 60)

## LoadedSection values: fruit 1, nuts 2, candy 3; 0 = nothing open. A loader
## closes the panel only when ITS OWN section is open; any other value opens
## it (switching category is a straight re-open).
const SECTION := {"Fruit": 1, "Nuts": 2, "Candy": 3}
## Scroll view frames. viewWillAppear: parks it at centre (160,-100) of the
## nib's 320x100 frame and animates to (0,-100,320,100) -- off screen either
## way. A loader that opens sets (0,-280,320,280) at once, then animates to
## (0,52,320,200) -- (0,52,320,280) for candy, whose third row needs it.
## A loader that closes animates to (0,-300,320,280); an item tap and a stray
## touch animate to (0,-200,320,200). All 0.5s.
const NIB_SCROLL_SIZE := Vector2(320, 100)
const PANEL_ENTER_CENTER := Vector2(160, -100)
const PANEL_PARKED := Rect2(0, -100, 320, 100)
const PANEL_OPEN_FROM := Rect2(0, -280, 320, 280)
const PANEL_OPEN := Rect2(0, 52, 320, 200)
const PANEL_OPEN_CANDY := Rect2(0, 52, 320, 280)
const PANEL_CLOSE_TOGGLE := Rect2(0, -300, 320, 280)
const PANEL_CLOSE := Rect2(0, -200, 320, 200)
const PANEL_SLIDE := 0.5
## clearScrollViewItems is delayed 0.4s after an item tap (double
## 0x3FD99999A0000000) and 0.6s after a stray touch (0x3FE3333340000000).
const CLEAR_AFTER_ITEM := 0.4
const CLEAR_AFTER_TOUCH := 0.6
## viewWillAppear: performSelector:showNextButton afterDelay: 3.0 (double
## 0x4008000000000000).
const NEXT_DELAY := 3.0

## Tag -> art. Order is the order the buttons are created in, and the tag is
## what GameState stores. Read directly out of each loader.
const CATEGORIES := {
	"Fruit": [
		{"tag": "0", "art": "ms_Strawberry"},
		{"tag": "1", "art": "ms_Rasberry"},
		{"tag": "2", "art": "ms_Orange"},
		{"tag": "3", "art": "ms_Mango"},
		{"tag": "4", "art": "ms_Lychees"},
		{"tag": "5", "art": "ms_Yogurt"},
		{"tag": "6", "art": "ms_banana"},
		{"tag": "7", "art": "ms_Blueberry"},
	],
	"Candy": [
		{"tag": "100", "art": "ms_Chocolate"},
		{"tag": "101", "art": "ms_Cinnamon_Imperials"},
		{"tag": "102", "art": "ms_Gummi_Bears"},
		{"tag": "103", "art": "ms_M_Ms"},
		{"tag": "104", "art": "ms_Peppermints"},
		{"tag": "105", "art": "ms_Spice_Drops"},
		{"tag": "106", "art": "ms_Butter_Cups"},
		{"tag": "107", "art": "ms_Chocolate_Kisses"},
		{"tag": "108", "art": "ms_Chocolete_Candies"},
		{"tag": "109", "art": "ms_chocCookies"},
	],
	"Nuts": [
		{"tag": "200", "art": "ms_Chopped_Peanuts"},
		{"tag": "201", "art": "ms_Roasted_Cashews"},
		{"tag": "202", "art": "ms_Pistachios"},
		{"tag": "203", "art": "ms_Walnuts"},
	],
}

# -- addExtra:tag:animate: (0x4F6B8) -----------------------------------

## The piece is a UIImageView added to blenderDetectionView; its layer
## position is animated, so every path point is the piece's CENTRE in
## blenderDetectionView-LOCAL coordinates. In root space the path runs from
## (120,129) up through the control (160,-11) into the jar. (The port used
## to parent the piece to the screen root and use these local numbers as
## root coordinates, so pieces started 309px too high.)
const ADD_FROM := Vector2(80, -180)
const ADD_CONTROL := Vector2(120, -320)
const ADD_SECONDS := 0.75
const ADD_START_SCALE := 0.66
const ADD_FINAL_SCALE := 0.4
## Landing spot, blenderDetectionView-local: (40 + 170r, 70 + 80r),
## r = random() * 2^-31.
const ADD_RANDOM_BASE := Vector2(40, 70)
const ADD_RANDOM_SPAN := Vector2(170, 80)
## sendSplash at +0.75s (double 0x3FE8000000000000).
const SPLASH_DELAY := 0.75

# -- initFlavors (0x4E2D8): the jar tableau, rebuilt on every appearance -----

## Six full-size UIImageViews of ms_icscoops<iceCreamNum> -- true CENTRES,
## blenderDetectionView-local (third centre read from the registers at
## 0x4E500: 0x42F00000/0x435C0000 = (120,220)). UIKit does not clip
## subviews: the y=220 row sits below the 480px screen.
const TABLEAU_CENTERS := [
	Vector2(50, 220), Vector2(190, 220), Vector2(120, 220),
	Vector2(120, 160), Vector2(190, 160), Vector2(50, 160),
]
## milkView: TintedIV(ms_Blender_Top_View_Milk, milkColor, 1) at art
## top-left (0,315), inserted below blenderDetectionView.
const MILK_TOP_LEFT := Vector2(0, 315)

var _panel: UIKit.ScrollFrame
var _loaded_section := 0              # LoadedSection
var _buttons: Array = []
var _pressed_item: Node2D
var _jar: Node2D                      # blenderDetectionView
var _next_home := Vector2.ZERO
var _milk: Sprite2D                   # milkView
## milkColor: the init argument (initWithMilk:iceCream:iceCreamNum: 0x4AE6C).
## GameState.milk_color stands in for it on the way in, but a later syrup pour
## folds into GameState's copy -- this screen keeps its own, as the ivar does.
var _milk_color := Color.WHITE
var _splash: SSEmitter

## Mystery extras:
##   initWithMilk:iceCream:iceCreamNum: 0x4AE6C  Consumable
##     DM_CONSUMABLE_MYSTERY_EXTRA / MysteryExtra_30Decorate, cost =
##     CoinCosts."Milkshake".MysteryExtras, 11 when absent; first-time message.
##   viewDidLoad 0x4B0A0  ConsumableButton(btn_mystery_extras, (0,-25) /
##     (65,3)) at centre (50, 350.5), layer zPosition 100; buyMysteryExtraClick:.
##   viewWillAppear: 0x4B4F0  badge unhidden.
##   buyMysteryExtraClick: 0x4EF08  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x4E774  showNextButton if hidden; EVERY subview of
##     blenderDetectionView removed (the six tableau balls too), addedFruits
##     emptied, fruitCount 0, the picker's alpha 0; five times: arc4random()
##     % 3 picks fruit (tags 0-7) / candy (100-109) / nuts (200-203), a random
##     item of that list, addExtra:tag:animate:NO; then [splash start] (the
##     SSEmitter) and the picker's alpha back to 1.
##     No sound: sendSplash belongs to the animated path only. (The port
##     used to play ms_splash here and keep the tableau balls.)
##   consumablePurchaseFailed:error:2 0x4EE34  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_EXTRA"
const MYSTERY_NAME := "MysteryExtra_30Decorate"
const MYSTERY_COST := 11
const MYSTERY_MESSAGE := "Try out mystery extras! A random combo of who knows what! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_extras.png"
const MYSTERY_CENTER := Vector2(50, 350.5)
const MYSTERY_EXTRAS := 5

var _mystery: RefCounted
var _mystery_button: TextureButton


func on_enter() -> void:
	_milk_color = GameState.milk_color
	_next_home = UIKit.next_home(self)
	_jar = _jar_node()
	_build_splash()
	_panel = UIKit.scroll_frame(self, outlet("aScrollView"),
		Rect2(PANEL_ENTER_CENTER - NIB_SCROLL_SIZE * 0.5, NIB_SCROLL_SIZE))
	_panel.animate_frame(PANEL_PARKED, PANEL_SLIDE)
	# initFlavors empties addedFruits and zeroes fruitCount before rebuilding
	# the tableau, so a re-entry starts the ingredient list over.
	GameState.reset_fruits()
	_build_tableau()
	_build_mystery()
	_set_next_enabled(false)
	UIKit.park_instruction(self)
	_after(NEXT_DELAY, _show_next)


## viewDidAppear: (0x4B808), after the push / pop slide:
## changeInstruction:@"inst_add_to_blender.png" -- on every appearance.
func on_did_appear() -> void:
	change_instruction("inst_add_to_blender.png")


## performSelector:withObject:afterDelay:. A run-loop timer: it keeps running
## while a pushed screen covers this one (a child Timer node would pause out
## of the tree), and it is dropped when the screen is freed -- the timeout is
## connected to a method of this node, which Godot disconnects on free, as a
## popped controller's pending selectors die with it.
func _after(secs: float, fn: Callable) -> void:
	get_tree().create_timer(secs).timeout.connect(_run_after.bind(fn))


func _run_after(fn: Callable) -> void:
	fn.call()


func _jar_node() -> Node2D:
	var jar := outlet("blenderDetectionView")
	if jar != null and jar != self and jar is Node2D:
		return jar as Node2D
	var n := Node2D.new()
	n.position = BLENDER_RECT.position
	_insert_behind_rim(n)
	return n


## showNextButton. A pending call that fires while a pushed screen covers
## this one is skipped: on the phone it animates a hidden-from-view button,
## and viewWillAppear: hides next again on the way back anyway.
func _show_next() -> void:
	if not is_inside_tree():
		return
	UIKit.show_next_from_home(self, _next_home)


func _next_hidden() -> bool:
	var n := outlet("nextButton")
	return n != null and n != self and not (n as CanvasItem).visible


## viewDidLoad: the ConsumableButton (zPosition 100: above everything), and
## init's Consumable.
func _build_mystery() -> void:
	_mystery = ConsumableScript.new(MYSTERY_KEY, MYSTERY_NAME, MYSTERY_COST)
	_mystery.set("first_time_message", MYSTERY_MESSAGE)
	_mystery.set("on_purchased", _on_mystery_purchased)
	_mystery.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyMysteryExtra"
	b.call("setup", MYSTERY_ART, 0, -25, MYSTERY_COST, 65, 3)
	b.position = MYSTERY_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyMysteryExtraClick)
	add_child(b)
	_mystery_button = b


func _on_buyMysteryExtraClick() -> void:
	Audio.play("store")
	_mystery.call("purchase", self)


## consumablePurchased: (0x4E774).
func _on_mystery_purchased(_free: bool) -> void:
	if _next_hidden():
		_show_next()
	if _jar != null:
		for c in _jar.get_children():
			c.queue_free()
	GameState.reset_fruits()
	var lists := ["Fruit", "Candy", "Nuts"]
	for i in MYSTERY_EXTRAS:
		var items: Array = CATEGORIES[lists[randi() % 3]]
		_add_extra(items[randi() % items.size()], false)
	# [splash start] -- no ms_splash sound on this path.
	if _splash != null:
		_splash.start()


func _tex(art: String) -> Texture2D:
	return Assets.texture(art + ".png")


## The jar as this screen finds it: tinted milk behind the detection view, and
## six balls of the chosen ice cream inside it (initFlavors 0x4E2D8). Run on
## EVERY appearance (viewWillAppear:): first every subview of
## blenderDetectionView is removed -- the pieces a previous visit added -- and
## a new milkView is made (nextClick: removed the last one).
func _build_tableau() -> void:
	if _jar == null:
		return
	for c in _jar.get_children():
		c.queue_free()
	# milkView is a sibling inserted *below* the detection view, so its
	# top-left is in root space, not jar-local. Tinted with this screen's own
	# milkColor (see _milk_color).
	var milk_tex := _tex("ms_Blender_Top_View_Milk")
	var parent := _jar.get_parent()
	if milk_tex != null and parent != null:
		_milk = Sprite2D.new()
		_milk.texture = milk_tex
		_milk.centered = false
		_milk.position = MILK_TOP_LEFT
		_milk.modulate = _milk_color
		parent.add_child(_milk)
		parent.move_child(_milk, _jar.get_index())

	if GameState.ice_cream_texture == "" or not Assets.has_image(GameState.ice_cream_texture):
		return
	var ball_tex: Texture2D = Assets.texture(GameState.ice_cream_texture)
	for c: Vector2 in TABLEAU_CENTERS:
		var ball := Sprite2D.new()
		ball.texture = ball_tex
		ball.centered = true
		ball.position = c
		_jar.add_child(ball)


# -- the nib's own category buttons -----------------------------------

func _on_loadFruitItemsToScrollview() -> void:
	_toggle_category("Fruit")


func _on_loadNutItemsToScrollview() -> void:
	_toggle_category("Nuts")


func _on_loadCandyItemsToScrollview() -> void:
	_toggle_category("Candy")


## The three loaders share one shape: clearScrollViewItems FIRST (so a
## closing panel slides away empty), button_press, then close if this
## section is the open one, else open it with fresh items.
func _toggle_category(cat: String) -> void:
	_clear_panel()
	Audio.play("button_press")
	var section: int = SECTION[cat]
	if _loaded_section == section:
		_panel.animate_frame(PANEL_CLOSE_TOGGLE, PANEL_SLIDE)
		_loaded_section = 0
		return
	_loaded_section = section
	_panel.set_frame(PANEL_OPEN_FROM)
	_panel.animate_frame(PANEL_OPEN_CANDY if cat == "Candy" else PANEL_OPEN,
		PANEL_SLIDE)
	_build_panel(cat)


## clearScrollViewItems (0x4F324). The delayed calls are not cancelled by a
## later open -- in the original a category opened within 0.4s of an item tap
## (0.6s of a stray touch) loses its fresh items to the pending clear and
## slides in empty. Reproduced as read.
func _clear_panel() -> void:
	for b in _buttons:
		if is_instance_valid(b):
			b.queue_free()
	_buttons.clear()


func _clear_panel_later(secs: float) -> void:
	_after(secs, _clear_panel)


## Rebuild the grid. Each button: setImage: Sub_Button_Background (91x90 in an
## 80x80 button -- INFERRED UIKit fit, see UIKit.fit_button_image) and the
## item art as a UIImageView setFrame:(10,10,60,60) on top.
func _build_panel(cat: String) -> void:
	var bg := _tex("Sub_Button_Background")
	var items: Array = CATEGORIES[cat]
	for i in items.size():
		var item: Dictionary = items[i]
		var col := i % BTN_COLS
		var row := i / BTN_COLS
		var origin := Vector2(col * BTN_SIZE.x, BTN_ROW_Y + row * BTN_SIZE.y)

		var btn := Node2D.new()
		btn.position = origin
		btn.set_meta("rect", Rect2(origin, BTN_SIZE))
		btn.set_meta("item", item)
		_panel.content.add_child(btn)
		_buttons.append(btn)

		if bg != null:
			var fit: Array = UIKit.fit_button_image(bg.get_size(), BTN_SIZE)
			var frame := Sprite2D.new()
			frame.texture = bg
			frame.centered = false
			frame.position = fit[0]
			frame.scale = fit[1]
			btn.add_child(frame)

		var icon_tex := _tex(item["art"])
		if icon_tex != null:
			var icon := Sprite2D.new()
			icon.texture = icon_tex
			icon.centered = false
			icon.position = ICON_RECT.position
			var s := icon_tex.get_size()
			if s.x > 0 and s.y > 0:
				icon.scale = Vector2(ICON_RECT.size.x / s.x, ICON_RECT.size.y / s.y)
			btn.add_child(icon)


# -- touches -----------------------------------------------------------

## Items are UIButtons (touchUpInside): press and release on the same item.
## A press inside the open scroll view that misses every item is swallowed by
## the UIScrollView (it does not forward touchesBegan:). Anything else -- not
## a nib button, not the badge -- is the view controller's touchesBegan:.
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var item := _item_at(mb.position)
	if mb.pressed:
		_pressed_item = item
		if item == null and not (_loaded_section != 0
				and _panel.model_has_point(mb.position)):
			_touches_began()
		return
	if item != null and item == _pressed_item:
		_pressed_item = null
		_on_item_tapped(item.get_meta("item"))
		get_viewport().set_input_as_handled()
	_pressed_item = null


func _item_at(p: Vector2) -> Node2D:
	if _loaded_section == 0 or not _panel.model_has_point(p):
		return null
	var local := _panel.to_content(p)
	for btn in _buttons:
		if is_instance_valid(btn) and (btn.get_meta("rect") as Rect2).has_point(local):
			return btn
	return null


## touchesBegan:withEvent: (0x4F11C): with next hidden, "cancel" and show it.
## Then, unless the scroll view is parked (frame.y < -1), "cancel" again,
## slide it to (0,-200,320,200), LoadedSection 0, clear after 0.6s.
func _touches_began() -> void:
	if _next_hidden():
		Audio.play("cancel")
		_show_next()
	if _panel.model.position.y < -1.0:
		return
	Audio.play("cancel")
	_panel.animate_frame(PANEL_CLOSE, PANEL_SLIDE)
	_loaded_section = 0
	_clear_panel_later(CLEAR_AFTER_TOUCH)


## flavorItemClicked: (0x4F404): LoadedSection 0, show next if hidden,
## button_press, slide the picker away, clear it after 0.4s, fly the item in.
func _on_item_tapped(item: Dictionary) -> void:
	_loaded_section = 0
	if _next_hidden():
		_show_next()
	Audio.play("button_press")
	_panel.animate_frame(PANEL_CLOSE, PANEL_SLIDE)
	_clear_panel_later(CLEAR_AFTER_ITEM)
	_add_extra(item)


## addExtra:tag:animate: (0x4F6B8). Recorded by tag (capped round-robin at
## 20 in GameState.add_fruit), drawn as a UIImageView at natural size with a
## 0.66 scale, added to blenderDetectionView (so under the rim, the buttons
## and the instruction, and above the picker).
func _add_extra(item: Dictionary, animate: bool = true) -> void:
	GameState.add_fruit(str(item["tag"]))

	var tex := _tex(item["art"])
	if tex == null or _jar == null:
		return
	var piece := Sprite2D.new()
	piece.texture = tex
	piece.centered = true
	piece.scale = Vector2(ADD_START_SCALE, ADD_START_SCALE)
	piece.position = ADD_FROM
	_jar.add_child(piece)

	var target := ADD_RANDOM_BASE + Vector2(
		randf() * ADD_RANDOM_SPAN.x, randf() * ADD_RANDOM_SPAN.y)
	if not animate:
		# setCenter: + setTransform:(scale 0.4), no flight and no splash.
		piece.position = target
		piece.scale = Vector2(ADD_FINAL_SCALE, ADD_FINAL_SCALE)
		return

	# Paced keyframe "position" over 0.75s, and a 0.75s UIView animation of
	# the transform to scale 0.4 (default ease-in-out curve).
	UIKit.fly_paced(piece, ADD_FROM, ADD_CONTROL, target, ADD_SECONDS)
	piece.create_tween().tween_property(piece, "scale",
		Vector2(ADD_FINAL_SCALE, ADD_FINAL_SCALE), ADD_SECONDS) \
		.set_trans(UIKit.TRANS).set_ease(UIKit.EASE)

	# performSelector:sendSplash afterDelay:0.75.
	_after(SPLASH_DELAY, _send_splash)


## sendSplash (0x4FB68): ms_splash.mp3, then [splash start]. PORT CHOICE: a
## call that fires while a pushed screen covers this one plays the sound (the
## phone would) but does not start the emitter -- the port's emitter is paused
## out of the tree and would replay the splash on the way back, where the
## phone's four 0.02s frames are long gone (and initFlavors has emptied the
## jar by then).
func _send_splash() -> void:
	Audio.play("ms_splash")
	if _splash != null and is_inside_tree():
		_splash.start()


## viewDidLoad (0x4B0A0): setParticles:... on the nib's `splash` view with
## milkColor. Configured once; a return visit does not re-run it.
func _build_splash() -> void:
	var host := outlet("splash")
	if host == null or host == self:
		return
	_splash = SSEmitter.attach(host, SSEmitterConfigs.frame_size(SPLASH)) as SSEmitter
	SSEmitterConfigs.apply(_splash, SPLASH, _milk_color)


func _insert_behind_rim(node: Node2D) -> void:
	var top := outlet("TopBlenderView")
	if top != null and top != self and top.get_parent() != null:
		top.get_parent().add_child(node)
		top.get_parent().move_child(node, top.get_index())
	else:
		add_child(node)


func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.disabled = not on


## backClick: (0x4EF74) / nextClick: (0x4EFE4): button_press, then pop /
## push msSelectSyrup(milkColor, iceCreamColor, iceCreamNum, addedFruits).
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


## nextClick: also removes milkView before the push; the controller stays
## alive under it, and the next appearance's initFlavors makes a new one.
func _on_nextClick() -> void:
	Audio.play("button_press")
	if _milk != null:
		_milk.queue_free()
		_milk = null
	Nav.next()


## UINavigationController keeps this controller alive under msSelectSyrup
## (nextClick: pushes), so back shows the same instance (Nav.gd opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from msSelectSyrup. This screen does its whole setup in
## viewWillAppear: (0x4B4F0), so a return re-runs nearly all of it:
##   initFlavors (0x4E2D8): addedFruits emptied, fruitCount 0, the jar
##     emptied and refilled with the six balls, a new milkView;
##   nextButton hidden; backButton disabled with enableBackButton at +0.5s;
##   the picker re-parked with setCenter:(160,-100) at whatever size it was
##   left and slid to (0,-100,320,100) over 0.5s; showNextButton at +3.0s;
##   buyMysteryExtra unhidden;
## then viewDidAppear: (0x4B808) changeInstruction:@"inst_add_to_blender.png"
## (on_did_appear, after the slide).
## LoadedSection and the picker's items are NOT reset there -- kept as read.
## The splash emitter (viewDidLoad) is not reconfigured.
func on_resume() -> void:
	UIKit.drop_coin_view(self)
	# PORT CHOICE: GameState carries the init arguments the original passes
	# down the chain. msSelectSyrup (now popped) folded its syrup into
	# GameState.milk_color; this controller's milkColor never changed, and the
	# fresh msSelectSyrup the next push makes must start from it.
	GameState.milk_color = _milk_color
	GameState.syrup_color = Color.WHITE
	GameState.syrup_poured = false
	GameState.reset_fruits()
	_build_tableau()
	_set_next_enabled(false)
	lock_back_button()
	_panel.set_center(PANEL_ENTER_CENTER)
	_panel.animate_frame(PANEL_PARKED, PANEL_SLIDE)
	_after(NEXT_DELAY, _show_next)
	if _mystery_button != null:
		_mystery_button.visible = true
	# viewDidAppear:'s changeInstruction: follows in on_did_appear(), when
	# the pop slide ends.

# NOT PORTED, deliberately, rather than guessed:
#
#  * Lock overlays (black_lock.png at (2,2,75,75), tag 1000, plus the
#    Sub_Button_Background_Locked image) and lockedFlavorButtonClicked: --
#    the port ships everything unlocked, so contentLocked is 0. Free items
#    are fruit 0-1, candy 100-101 and nut 200.
#  * skipClick: (0x4F118) is an empty method; no nib or code wires it.
#  * Analytics (endMkrDate, DataLogging) -- nothing a player sees.
