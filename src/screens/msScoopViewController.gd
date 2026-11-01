# Milkshake step 2 -- pick an ice cream and scoop it into the blender.
#
# Rewritten from draggableTouchMoved:fromSender: (0x44F50), flavorClicked:
# (0x434EC), initFlavors (0x42BC0) and viewDidAppear: (0x42874). The mechanic
# is a TWO-PHASE drag:
#
#   phase 1  scoop is empty. When its hotspot enters the pickup rect, play
#            ms_ice_cream.mp3, rotate to 4.1888, un-hide the loaded ball and
#            remove one of the six scoops visible in the tub.
#   phase 2  scoop is loaded. When its hotspot enters blenderDetectionRect,
#            hide the load, rotate to 4.0143, and animate a ball of the chosen
#            flavour into the jar along a quadratic path.
#
# Kept alive under the push:
# nextClick: (0x44360) tears the tub and balls down, on_resume() re-runs
# viewWillAppear: (0x427AC) and on_did_appear() viewDidAppear: (0x42874).
#
# viewDidAppear:'s work runs in on_did_appear(), i.e. after the 0.35 s
# push / pop slide as on the phone,
# and the picker strip is a real UIScrollView (UIKit.ScrollPhysics).
#
# Everything here is grounded; the addresses are on each constant. Two earlier
# port inventions are gone:
#
#   * BALL_LIFT = 78.0 -- no such constant exists. It compensated for two
#     stacked misreadings (slots taken as centres rather than TintedIV
#     top-lefts, and blenderIV given a wrong origin). See BALL_SLOTS.
#   * a visible cream slab in the tub -- iceCreamIV is never added to the view
#     hierarchy at all. It exists only to anchor the pickup rect. What fills
#     the tub is the six mini scoops, which visibly deplete.
#
# READ THIS before touching any coordinate here: a zero-framed TintedIV's
# "centre" is its art's TOP-LEFT, while UIImageView and DraggableIV are
# self-sizing and use true centres.

extends "res://core/Screen.gd"

const DraggableSprite2D := preload("res://core/DraggableSprite2D.gd")
const ImageUtil := preload("res://core/ImageUtil.gd")
const UIKit := preload("res://screens/msUIKit.gd")

## blenderIV and blenderDetectionView are the SAME nib view (id 3).
const BLENDER_RECT := Rect2(40, 309, 240, 171)
const SCOOPS_REQUIRED := 6
const SWATCH_COUNT := 34

## scoopIV is a DraggableIV -- self-sizing, so this is a true centre (0x434EC).
const SCOOP_HOME := Vector2(240, 240)
const SCOOP_ANGLE := 3.8397
const LOAD_ROTATION := 4.1888
const DROP_ROTATION := 4.0143

## Fixed offset from the scoop's centre, never rotated (0x44F50).
const HOTSPOT := Vector2(-50, 65)

## (iceCreamIV.center.x, iceCreamIV.center.y, 180, 80). iceCreamIV is a
## zero-framed TintedIV, so its "centre" (10.5, 82) is the art's top-left --
## the dev pre-compensated with setCenter:(105 - w/2, 124 - h/2), which centres
## the 189x84 art on (105, 124). The rect is anchored at that top-left.
const PICKUP_RECT := Rect2(10.5, 82, 180, 80)

## Both bucket halves are UIImageViews: true centres.
const TUB_CENTER := Vector2(110, 160)
## Six mini scoops of the chosen flavour, UIImageView true centres. One is
## removed per pickup, in this order.
const TUB_SCOOPS := [
	Vector2(70, 114), Vector2(105, 104), Vector2(135, 114),
	Vector2(75, 134), Vector2(105, 154), Vector2(140, 144),
]

## Drop path, all blenderIV-local. The start is authored as
## scoop.center + (-150, -215) *expressed in blenderIV-local coords* -- it is
## not a space conversion, so in root space the ball begins at
## scoop.center + (-110, +94).
const BALL_PATH_START_OFFSET := Vector2(-150, -215)
const BALL_PATH_CONTROL := Vector2(120, -320)
const BALL_SECONDS := 0.5
const SPLASH_DELAY := 0.25

## Where each ball lands, blenderIV-local, as art TOP-LEFTS (the ball is a
## zero-framed TintedIV whose layer position is animated). Tables 0x682A90 /
## 0x682AB0, first drop uses the leading slot.
##
## The bottom row genuinely hangs below the 480px screen: UIKit does not clip
## subviews and the original leaves it that way. Recordings agree -- do not
## "fix" it by lifting the balls.
const BALL_SLOTS := [
	Vector2(-10, 160), Vector2(130, 160), Vector2(60, 160),
	Vector2(60, 100), Vector2(130, 100), Vector2(-10, 100),
]

# -- picker (initFlavors 0x42BC0) --------------------------------------

const BTN_SIZE := Vector2(90, 76)
const BTN_Y := 10.0
const BTN_X0 := 40.0
const BTN_PITCH := 100.0
## Set every iteration to (170 + 115i, 200) -- the 100-px placement pitch and
## the 115-px contentSize step disagree in the original. Ported as read.
const CONTENT_W := 3965.0
const CONTENT_H := 200.0
## viewDidAppear: (0x42874): setCenter:(160,-100) on the nib's 320x100 scroll
## view -- frame (0,-150,320,100) -- then setFrame:(0,0,w,202) over 0.5s; the
## frame's HEIGHT animates too. flavorClicked: animates (0,-100,w,100), 0.5s.
## (The port used to start the slide at y -100 and never clip.)
const NIB_SCROLL_SIZE := Vector2(320, 100)
const PANEL_RECT := Rect2(0, 0, 320, 202)
const PANEL_ENTER_CENTER := Vector2(160, -100)
const PANEL_EXIT := Rect2(0, -100, 320, 100)
const PANEL_SLIDE := 0.5

## milkView: TintedIV(ms_Blender_Top_View_Milk, milkColor, 1), setCenter:
## (0, 315) on a zero-framed TintedIV = art top-left, inserted below blenderIV
## (initFlavors 0x42BC0). (The port used to draw no milk on this screen.)
const MILK_TOP_LEFT := Vector2(0, 315)

## Draw the hit regions and the scoop hotspot: a debugging aid that shows
## why a hit did or did not register.
static var debug_hitboxes := false

var _panel: UIKit.ScrollFrame
var _buttons: Array = []
var _next_home := Vector2.ZERO
## The picker's UIScrollView physics (set up by initFlavors' first
## branch, in on_did_appear), and the press it is tracking.
var _physics: UIKit.ScrollPhysics
var _tracking := false
var _press_pos := Vector2.ZERO
## initFlavors has built the picker (its first-entry branch has run).
var _flavors_built := false

var _scoop: DraggableSprite2D
var _scoop_load: Sprite2D
var _tub: Node2D
var _tub_scoops: Array = []
var _jar: Node2D
var _count := 0
var _flavor_tex: Texture2D
var _chosen := false
var _loaded := false
var _debug_node: Node2D

## Mystery selection:
##   initWithMilk: 0x42278  Consumable DM_CONSUMABLE_MYSTERY_SELECT /
##     MysterySelect_20IceCreamFlavor, cost = CoinCosts."Milkshake".
##     MysteryIceCream, 6 when absent; first-time message.
##   viewDidLoad 0x42420  ConsumableButton(btn_mystery_selection, (0,-25) /
##     (65,3)) at centre (50, 350.5), layer zPosition 100 (above the picker
##     scroll view); buyMysterySelectClick:; buyAllBtn hidden.
##   buyMysterySelectClick: 0x43480  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x43290  quantity 0, then flavorClicked: with the
##     badge itself as sender.
##   flavorClicked: 0x434EC  button_press, hides the badge (every pick does),
##     and when the sender IS the badge picks a random UIButton among the
##     picker's subviews, then proceeds exactly as a tap on that button.
##   consumablePurchaseFailed:error:2 0x433AC  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_SELECT"
const MYSTERY_NAME := "MysterySelect_20IceCreamFlavor"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery selection! You never know what selection it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_selection.png"
const MYSTERY_CENTER := Vector2(50, 350.5)
## layer zPosition 100: above the picker (CanvasLayer 5 in the port).
const MYSTERY_LAYER := 6

var _mystery: RefCounted
var _mystery_button: TextureButton
var _mystery_layer: CanvasLayer


## viewDidLoad (0x42420): the mystery badge. The nib's aScrollView sits at
## (0,0,320,100), still empty; next shows as the nib has it and the banner
## sits at its nib spot until viewDidAppear: (on_did_appear).
func on_enter() -> void:
	_next_home = UIKit.next_home(self)
	_build_jar()
	_build_tub()
	_build_scoop()
	_panel = UIKit.scroll_frame(self, outlet("aScrollView"),
		Rect2(Vector2.ZERO, NIB_SCROLL_SIZE))
	_build_mystery()
	UIKit.park_instruction(self)
	if debug_hitboxes:
		_build_debug()


## viewDidAppear: (0x42874), after the push / pop slide: initFlavors
## (0x42BC0) -- first entry: the 34 buttons, contentSize, the scroll view's
## settings, the milk, next hidden; re-entry: next hidden -- then the picker
## parked at centre (160,-100) and slid to (0,0,320,202) over 0.5s, and
## changeInstruction:@"inst_select_ice_cream.png". Runs on every appearance,
## as viewDidAppear: does (the pop back from msFruit included).
func on_did_appear() -> void:
	if not _flavors_built:
		_flavors_built = true
		_build_picker()
		_build_milk()
	_set_next_enabled(false)
	_panel.set_center(PANEL_ENTER_CENTER)
	_panel.animate_frame(PANEL_RECT, PANEL_SLIDE)
	change_instruction("inst_select_ice_cream.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _process(_delta: float) -> void:
	if _debug_node != null:
		_debug_node.queue_redraw()


func _build_debug() -> void:
	var dbg := Node2D.new()
	dbg.z_index = 100
	dbg.draw.connect(func() -> void:
		dbg.draw_rect(PICKUP_RECT, Color(0, 1, 0, 0.85), false, 2.0)
		dbg.draw_rect(BLENDER_RECT, Color(0, 0.6, 1, 0.85), false, 2.0)
		if _scoop != null and _scoop.visible:
			dbg.draw_circle(_hotspot(), 6.0, Color(1, 0, 0, 0.9)))
	add_child(dbg)
	set_process(true)
	_debug_node = dbg


# -- construction -----------------------------------------------------

## milkView, below blenderIV. Blend 1 = multiply = modulate for opaque art.
func _build_milk() -> void:
	var tex := _tex("ms_Blender_Top_View_Milk.png")
	if tex == null:
		return
	var milk := Sprite2D.new()
	milk.texture = tex
	milk.centered = false
	milk.position = MILK_TOP_LEFT
	milk.modulate = GameState.milk_color
	var anchor := outlet("blenderIV")
	if anchor != null and anchor != self and anchor.get_parent() != null:
		anchor.get_parent().add_child(milk)
		anchor.get_parent().move_child(milk, anchor.get_index())
	else:
		_insert_behind_rim(milk)


## Dropped balls are subviews of blenderIV, so they live in a node at that
## frame's origin and are placed by their top-left.
func _build_jar() -> void:
	_jar = Node2D.new()
	_jar.position = BLENDER_RECT.position
	_insert_behind_rim(_jar)


func _insert_below_jar(node: Node2D) -> void:
	if _jar != null and _jar.get_parent() != null:
		_jar.get_parent().add_child(node)
		_jar.get_parent().move_child(node, _jar.get_index())
	else:
		_insert_behind_rim(node)


func _insert_behind_rim(node: Node2D) -> void:
	var top := outlet("TopBlenderView")
	if top != null and top != self and top.get_parent() != null:
		top.get_parent().add_child(node)
		top.get_parent().move_child(node, top.get_index())
	else:
		add_child(node)


## Bucket back, then the six scoops, then the bucket front on top. All are
## addSubview:'d in flavorClicked: and then blenderIV, TopBlenderView, back,
## next, skip, buyAll and instIV are brought to front -- so tub and scoop sit
## BELOW the blender rim and the buttons. (The port used to draw them on
## top of everything, so the scoop passed over the rim instead of into it.)
func _build_tub() -> void:
	_tub = Node2D.new()
	_tub.visible = false
	_insert_below_jar(_tub)

	var back := Sprite2D.new()
	back.texture = _tex("ms_IceCream_Back.png")
	back.centered = true
	back.position = TUB_CENTER
	_tub.add_child(back)

	for c: Vector2 in TUB_SCOOPS:
		var s := Sprite2D.new()
		s.centered = true
		s.position = c
		_tub.add_child(s)
		_tub_scoops.append(s)

	var front := Sprite2D.new()
	front.texture = _tex("ms_IceCream_Front.png")
	front.centered = true
	front.position = TUB_CENTER
	_tub.add_child(front)


func _build_scoop() -> void:
	_scoop = DraggableSprite2D.new()
	_scoop.texture = _tex("ms_Ice_Cream_Scoup.png")
	_scoop.centered = true
	_scoop.position = SCOOP_HOME
	_scoop.rotation = SCOOP_ANGLE
	# DraggableIV's snapTime is 0 and no ms screen sets it: released scoops
	# stay where they are left.
	_scoop.snap_back = false
	_scoop.visible = false
	_scoop.enabled = false
	# No instruction dismissal on drag: draggableTouchBegan: is
	# not implemented by this class; instIV stays until showNextButton.
	_scoop.drag_moved.connect(_on_scoop_moved)
	_insert_below_jar(_scoop)

	# iceCreamScoopIV: a zero-framed TintedIV child of scoopIV, rotated +90deg.
	# Its position is the art's top-left in scoopIV's coordinate space, whose
	# origin is the sprite's top-left -- Godot child coords are relative to the
	# sprite's centre, so shift by half the scoop art.
	_scoop_load = Sprite2D.new()
	_scoop_load.centered = true
	_scoop_load.rotation = 1.5708
	_scoop_load.visible = false
	_scoop.add_child(_scoop_load)


## Position the loaded ball once the flavour art (and so its size) is known.
##
## The original sets center (155 - W/2, 5 - H/2) on a zero-framed TintedIV that
## is already rotated +90deg, so the point is the art's pre-rotation top-left
## and the art sweeps left and down from it: x in [P.x - H, P.x],
## y in [P.y, P.y + W]. Expressed as a centre that resolves to
## (155 - (W+H)/2, 5 + (W-H)/2), scoop-local -- the same geometry, but stated
## as centre + rotation so Godot's rotate-about-origin cannot get it wrong.
##
## Scoop-local coordinates are measured from the sprite's top-left, while Godot
## child coordinates are measured from its centre, hence the half-size shift.
func _place_scoop_load() -> void:
	if _flavor_tex == null or _scoop.texture == null:
		return
	var art := _flavor_tex.get_size()
	var scoop_half := _scoop.texture.get_size() * 0.5
	var visual_center := Vector2(
		155.0 - (art.x + art.y) * 0.5,
		5.0 + (art.x - art.y) * 0.5)
	_scoop_load.position = visual_center - scoop_half


## 34 buttons, 90x76 at x = 40 + 100i, y = 10, inside a 320x202 panel that
## slides down from centre (160, -100) on appear.
## viewDidLoad: the ConsumableButton, and initWithMilk:'s Consumable.
func _build_mystery() -> void:
	_mystery = ConsumableScript.new(MYSTERY_KEY, MYSTERY_NAME, MYSTERY_COST)
	_mystery.set("first_time_message", MYSTERY_MESSAGE)
	_mystery.set("on_purchased", _on_mystery_purchased)
	_mystery.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	_mystery_layer = CanvasLayer.new()
	_mystery_layer.layer = MYSTERY_LAYER
	add_child(_mystery_layer)
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyMysterySelect"
	b.call("setup", MYSTERY_ART, 0, -25, MYSTERY_COST, 65, 3)
	b.position = MYSTERY_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyMysterySelectClick)
	_mystery_layer.add_child(b)
	_mystery_button = b


func _on_buyMysterySelectClick() -> void:
	if _chosen:
		return
	Audio.play("store")
	_mystery.call("purchase", self)


## consumablePurchased: (0x43290) -> flavorClicked: (0x434EC) with the badge
## as sender: a uniformly random picker button, then the normal pick.
func _on_mystery_purchased(_free: bool) -> void:
	if _buttons.is_empty() or _chosen:
		return
	_on_flavor_selected(_buttons[randi() % _buttons.size()])


func _build_picker() -> void:
	for i in SWATCH_COUNT:
		var art := "ms_icscoops%02d.png" % (i + 1)
		var t := _tex(art)
		if t == null:
			continue
		var origin := Vector2(BTN_X0 + BTN_PITCH * i, BTN_Y)
		var btn := Sprite2D.new()
		btn.texture = t
		btn.centered = false
		btn.position = origin
		var s := t.get_size()
		if s.x > 0 and s.y > 0:
			btn.scale = BTN_SIZE / s
		btn.set_meta("rect", Rect2(origin, BTN_SIZE))
		btn.set_meta("id", art)
		btn.set_meta("tex", t)
		_panel.content.add_child(btn)
		_buttons.append(btn)

	# setContentSize:(3965, 200), setShowsHorizontalScrollIndicator:NO,
	# setDecelerationRate:UIScrollViewDecelerationRateFast (0x42BC0). Bounces
	# and the vertical indicator keep the nib defaults (YES); the 200-high
	# content never exceeds the 202-high frame, so only x scrolls and the
	# vertical indicator never shows (visible fraction > 0.99).
	_physics = _panel.enable_scrolling(Vector2(CONTENT_W, CONTENT_H),
		func(ph: UIKit.ScrollPhysics) -> void:
			ph.shows_horizontal = false
			ph.set_deceleration_rate(UIKit.UIScrollSim.DECELERATION_RATE_FAST))


# -- interaction ------------------------------------------------------

## A press inside the picker's MODEL frame (UIKit hit-tests the
## target of a running frame animation) is the UIScrollView's. It becomes a
## drag after 10 pt; a release before that is a tap on the button the press
## landed on (flavorClicked:, touchUpInside). Moves and the release are read
## in _input so a drag keeps tracking over the nib's buttons.
func _unhandled_input(event: InputEvent) -> void:
	if _chosen or _physics == null:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if not _panel.model_has_point(mb.position):
		return
	_tracking = true
	_press_pos = mb.position
	_physics.touch_began(_panel.touch_point(mb.position))
	get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not _tracking:
		return
	if event is InputEventMouseMotion:
		_physics.touch_moved(_panel.touch_point((event as InputEventMouseMotion).position))
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT or mb.pressed:
			return
		_tracking = false
		var tap := _physics.touch_ended(_panel.touch_point(mb.position))
		if not tap or _chosen:
			return
		var btn := _button_at(_press_pos)
		if btn != null:
			_on_flavor_selected(btn)
			get_viewport().set_input_as_handled()


func _button_at(p: Vector2) -> Node:
	if not _panel.model_has_point(p):
		return null
	var local := _panel.to_content(p)
	for btn in _buttons:
		var r: Rect2 = btn.get_meta("rect")
		if r.has_point(local):
			return btn
	return null


func _on_flavor_selected(btn: Node) -> void:
	# flavorClicked: (0x434EC) plays button_press and hides the mystery badge
	# on every pick, the badge's own included.
	Audio.play("button_press")
	if _mystery_button != null:
		_mystery_button.visible = false
	_flavor_tex = btn.get_meta("tex")
	GameState.ice_cream_color = ImageUtil.average_color(_flavor_tex)
	GameState.ice_cream_texture = str(btn.get_meta("id"))
	_chosen = true

	# The picker slides up off screen (clipped, as a UIScrollView is).
	_panel.animate_frame(PANEL_EXIT, PANEL_SLIDE)
	change_instruction("inst_scoop_ice_cream.png")

	# flavorClicked: builds a NEW tub with six fresh scoops and a NEW scoopIV
	# at (240,240), rotated 3.8397, its ball hidden -- every time it runs.
	# On a return visit (on_resume) the port reuses its nodes, so restore them
	# to that freshly-built state rather than relying on first-build values.
	for s: Sprite2D in _tub_scoops:
		s.texture = _flavor_tex
		s.visible = true
	_scoop_load.texture = _flavor_tex
	_scoop_load.visible = false
	_place_scoop_load()
	_loaded = false
	_scoop.position = SCOOP_HOME
	_scoop.rotation = SCOOP_ANGLE

	_tub.visible = true
	_scoop.visible = true
	_scoop.enabled = true
	_scoop.capture_origin()


## The hotspot is a fixed offset from the scoop's centre and is NOT rotated
## with the sprite -- the port used to rotate it.
func _hotspot() -> Vector2:
	return _scoop.position + HOTSPOT


func _on_scoop_moved(_center: Vector2) -> void:
	if not _chosen:
		return
	var hp := _hotspot()
	if not _loaded:
		if PICKUP_RECT.has_point(hp):
			_load_scoop()
	elif BLENDER_RECT.has_point(hp) and _count < SCOOPS_REQUIRED:
		_drop_scoop()


func _load_scoop() -> void:
	_loaded = true
	Audio.play("ms_ice_cream", linear_to_db(0.75))
	_scoop_load.visible = true
	# setTransform: outside any animation block: instant. (The port used an
	# invented 0.15s tween.)
	_scoop.rotation = LOAD_ROTATION
	# One scoop leaves the tub per pickup, so the tub visibly empties.
	if _count < _tub_scoops.size():
		var s: Sprite2D = _tub_scoops[_count]
		if is_instance_valid(s):
			s.visible = false


func _drop_scoop() -> void:
	_loaded = false
	_scoop_load.visible = false
	_scoop.rotation = DROP_ROTATION          # instant, as above

	var slot: Vector2 = BALL_SLOTS[_count % BALL_SLOTS.size()]
	_count += 1
	GameState.ice_cream_scoops = _count
	_spawn_ball(slot)

	if _count >= SCOOPS_REQUIRED:
		_scoop.visible = false
		_scoop.enabled = false
		UIKit.show_next_from_home(self, _next_home)


## A ball of the chosen flavour arcing into the jar. Parented to _jar, so all
## three path points are blenderIV-local and are art TOP-LEFTS. The keyframe
## animation is kCAAnimationPaced: constant speed along the curve
## (the port used to walk the Bezier parameter linearly).
func _spawn_ball(slot: Vector2) -> void:
	var ball := Sprite2D.new()
	ball.texture = _flavor_tex if _flavor_tex != null else _tex("ms_Ice_Cream_Ball.png")
	ball.centered = false
	var start := _scoop.position + BALL_PATH_START_OFFSET
	_jar.add_child(ball)
	UIKit.fly_paced(ball, start, BALL_PATH_CONTROL, slot, BALL_SECONDS)

	await get_tree().create_timer(SPLASH_DELAY).timeout
	Audio.play("ms_splash")


func _set_next_enabled(on: bool) -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		n.visible = on
		n.disabled = not on


## backClick: (0x44144) / nextClick: (0x44360): button_press, tear-down, then
## pop / push msFruit(milkColor, currentColor, tagID).
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()


## nextClick: (0x44360) tears down before the push: bucketIV, frontBucketIV,
## iceCreamIV and the six tub scoops removeFromSuperview, EVERY subview of
## blenderIV (the dropped balls) removeFromSuperview, iceCreamBallCount = 0.
## scoopIV is left alone (hidden since the sixth drop). The controller stays
## alive under the push, so back finds an empty jar (milk only) and no tub.
func _on_nextClick() -> void:
	Audio.play("button_press")
	if _tub != null:
		_tub.visible = false
	if _jar != null:
		for c in _jar.get_children():
			c.queue_free()
	_count = 0
	Nav.next()


## UINavigationController keeps this controller alive under msFruit
## (nextClick: pushes), so back shows the same instance (Nav.gd opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from msFruit -- viewWillAppear: / viewDidAppear: on the loaded view:
##   viewWillAppear: (0x427AC) -> screenSetup (0x429F4): backButton
##     disabled, enableBackButton 0.5s later (double 0x3FE00000), and
##     buyMysterySelect setHidden:NO -- the badge every pick hid comes back.
##   viewDidAppear: (0x42874) -> initFlavors' RE-ENTRY branch (0x42BC0, the
##     scroll view already holds its buttons): nextButton (ivar +184) hidden.
##     Then setCenter:(160,-100) at the 320x100 size flavorClicked: left the
##     picker, a 0.5s slide to (0,0,320,202), and changeInstruction:
##     @"inst_select_ice_cream.png".
## The milk stays (built once); the tub and balls went in nextClick:. A new
## flavour is picked and six balls scooped again from a fresh tub.
## viewWillAppear: here, at the start of the pop slide; viewDidAppear:'s
## part (next hidden, the picker's slide, the banner) is on_did_appear().
func on_resume() -> void:
	UIKit.drop_coin_view(self)
	lock_back_button()
	if _mystery_button != null:
		_mystery_button.visible = true
	_chosen = false
	if _tracking and _physics != null:
		_physics.touch_cancelled()
	_tracking = false

# NOT PORTED, deliberately:
#
#  * The lock overlays (round_black_lock.png at (23,16,43,45), tag 1000, on
#    buttons with tag >= 4) never draw -- the port ships everything unlocked,
#    so contentLocked is false.
#  * initFlavors' re-entry branch hides the ivar at self+184 (0x42D70). The
#    class's ivar list (objc metadata) puts nextButton at 184, so
#    it is the same `nextButton setHidden:YES` as the first-entry branch.
#    Ported in on_resume(), which is when that branch runs.
#  * (The strip does scroll with UIKit's own physics: momentum at
#    UIScrollViewDecelerationRateFast, rubber band and bounce, through
#    UIKit.ScrollPhysics.)
#  * skipClick: (0x44604) is an empty method and no nib or code wires it.
