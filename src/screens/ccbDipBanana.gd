# Chocolate Covered Banana step 6 -- dip the banana-on-a-stick in the pot.
#
# From the original binary (entry points from the ObjC method list):
#   initWithNibName: 0xAD568 (hose consumable only), viewDidLoad 0xAD81C,
#   viewWillAppear: 0xADED0, viewWillDisappear: 0xAE090,
#   initLollipops 0xAE118, animationDidStop 0xAE740,
#   draggableTouchBegan/Moved/Ended 0xAED70/0xAEEE0/0xAF0D4,
#   backClick: 0xAF844, nextClick: 0xAF8D8, skipClick: 0xAF9BC (forwards to
#   nextClick:, no nib action reaches it), changeInstruction: 0xAF9CC,
#   showNextButton 0xAFBD4.
#
# Mechanic, as read (the free path -- the chocolate sprayer is a consumable):
#  * mix: nib UIImageView (34,245,253,109), image = Melted_Chocolate.png
#    through TintedIV's ALTERNATE tint (art as backdrop, infoDict[Color]
#    filled over it with CGBlendMode 3 / Overlay -- 0x4711C/0x474FC),
#    stretched to the nib frame. The bowl behind it is the nib's chgum_pot
#    stretched to (9,202,302,224).
#  * initLollipops (0xAE118) builds the banana-on-a-stick as one DraggableIV:
#    a clear 325x400 container (0x43A28000/0x43C80000), transform scale
#    0.45, home centre (160,140) (0x43200000/0x430C0000). Children, centres
#    in container coordinates:
#      stick   infoDict[Stick] at NATURAL size, (W/2, H - stickH);
#      banana  banana_for_stick.png rotated 3.1416 rad (the literal, not pi),
#              (W/2 - 8, H - stickH/2), above the stick;
#      coating alt-tinted cc_banana.png (blend 3), rotated 3.1416,
#              (banana.x, banana.y + 28), above the banana, HIDDEN.
#  * draggableTouchBegan (0xAED70, lollipop branch) plays "pickup".
#  * draggableTouchMoved (0xAEEE0): the lollipop's centre is pinned to
#    y <= mix.centre.y - 45 (0xC2340000) = 254.5 -- a drag-depth clamp the
#    Candy Apple dip does not have.
#  * Release with the lollipop's frame intersecting mix's (0xAF0D4), not
#    already coating/done: interaction off, "MoveLollipop" 0.25s curve 1
#    (ease-in) to (mix.centre.x, mix.centre.y - 45), coating shown at alpha
#    0.01 (0x3C23D70A) and faded to 1.0 over 8.0s ("ApplyCoating", curve 1).
#    Release anywhere else: the lollipop JUMPS home -- its snapTime is never
#    set and DraggableIV's default is 0.
#  * animationDidStop (0xAE740): ApplyCoating -> doneCoating, 0.2s curve-1
#    "MoveLollipop2" home; MoveLollipop2 -> an empty 0.2s "RotateLollipop"
#    block (sets no properties -- dead) and the next button slides in at
#    once. Both durations are the double literal at 0xAE960,
#    0x3FC99999A0000000 = 0.2 (vldr d16 at 0xAE80A / 0xAE8E4, read from the
#    disassembly). The port used to run 1.6 s.
#  * The touchEnded tail (not over mix, not coating, doneCoating, next
#    hidden -> showNextButton, 0xAF2C8) is reachable after all: showHose
#    builds a NEW lollipop with interaction on (only its X/Y movement is
#    locked), so dip, then buy the sprayer (which hides next), then tap the
#    lollipop -> next slides back in. Ported.
#
# nextClick: (0xAF8D8): button_press, hose quantity zeroed, push
# ccbFreezerViewController initWithDictionary:infoDict. NO BAKE here --
# unlike caDipApple, the ccb bake happens on the freezer screen.
#
# Sprayer consumable (ported; the original shows its badge on the phone):
#   initWithNibName: 0xAD568  Consumable DM_CONSUMABLE_BANANA_HOSE / Sprayer_60Dip, cost from the (dead)
#     server table GameData.CoinCosts."Chocolate Dipped Banana".ToolSprayGun, 11 when absent;
#     first-time message "Try out the Sprayer! Easily coat Chocolate Dipped Banana! Try it for FREE now!"; quantity 0.
#   viewDidLoad 0xAD81C  hose = DraggableIV ff_banana_chocolatesprayer_back.png, home centre (160,380)
#     (0x43200000/0x43BE0000), setFrame 71x176 (0x428E0000/0x43300000, the
#     art squashed to fill), re-centred at origCenter, snapTime 0.5; inserted
#     below instIV. coating = SpriteSheetView (0,0,124,240) over the
#     alt-tinted Chocolate_Spray_Sheet.png (372x480, blend 3) in 3 columns x
#     2 rows, inserted below the hose. buyHose = ConsumableButton
#     (chocolate_sprayer_upgrade.png, offsets (0,-25)/(65,3)) above instIV at centre (50, 350.5),
#     buyClick: on touch-up.
#   viewWillAppear: 0xADED0  hose hidden, badge shown, hoseTimer 0.1 s ->
#     hoseTick, coating hidden, hoseTime 0.
#   buyClick: 0xAF7D8  "store" sound, purchaseConsumable.
#   consumablePurchased: 0xAF524  quantity = 1, showHose, badge hidden.
#   showHose 0xAE968  changeInstruction: inst_spray_pops.png (NOT in the
#     bundle -> the banner shows nil, i.e. blank), initLollipops, doneHosing
#     and hoseTouched 0, hose and lollipop unhidden, the lollipop's layer
#     animations removed and its centre reset to origCenter (160,140), its X
#     and Y movement locked, lollipopCoating unhidden at alpha 0, hoseTime 0,
#     hose centre reset to origCenter.
#   draggableTouchBegan: 0xAED70 (hose)  loop spraying_loop.mp3, hoseTouched
#     1, coating unhidden at (hose.centre.x - 3, hose.centre.y - 157)
#     (0xC0400000/0xC31D0000). draggableTouchMoved: 0xAEEE0  the coating
#     follows the hose at that offset. draggableTouchEnded: 0xAF0D4  stop
#     spraying_loop, hoseTouched 0, coating hidden (DraggableIV then snaps the
#     hose home over 0.5 s).
#   hoseTick 0xAEB6C  while hoseTouched: lollipopCoating and lollipop
#     unhidden; if coating.frame intersects lollipop.frame, lollipopCoating
#     alpha += 0.05 (0x3D4CCCCD); hoseTime += 0.1; coating currentFrameIdx =
#     arc4random % 3 then tick (a random top-row cell); at alpha >= 1.0 and
#     not doneHosing: doneHosing, showNextButton.
#   consumablePurchaseFailed:error: 0xAF704  error 2 -> alert "You do not
#     have enough coins." (the port's Consumable shows it for too few coins
#     where the original showed an ad -- PORT CHOICE).
#   backClick: 0xAF844 / nextClick: 0xAF8D8  quantity 0.
#   viewWillDisappear: 0xAE090  stop spraying_loop, invalidate hoseTimer.
# No SSEmitter on this screen; the spray is the sprite sheet.
# With the hose out the lollipop is still touchable: lockX/YMovement keep
# it still, but draggableTouchBegan: plays "pickup" and draggableTouchEnded:
# runs as usual (jump home -- a no-op there -- and the tail above).
# (The port used to disable the touch outright.)
# Not ported: the AdColony video hook in viewDidLoad (0xAD9E8).

extends "res://core/Screen.gd"

const caSelectChocolate := preload("res://screens/caSelectChocolate.gd")

const MIX_RECT := Rect2(34, 245, 253, 109)      # nib id 3
const MIX_CENTER := Vector2(160.5, 299.5)
## initLollipops: clear container 325x400, scale 0.45, home (160,140).
const LOLLI_SIZE := Vector2(325, 400)
const LOLLI_SCALE := 0.45
const LOLLI_HOME := Vector2(160, 140)
## Children (container coords, relative to the UIKit centre) -- see header.
const BANANA_DX := -8.0
const COATING_DY := 28.0
const PART_ROTATION := 3.1416                   # the shipped literal
## Drag/dip depth: mix.centre.y - 45 (0xC2340000).
const DIP_OFFSET_Y := -45.0
const DIP_SECONDS := 0.25
## ApplyCoating: alpha 0.01 -> 1.0 over 8.0s, curve 1 (ease-in).
const COAT_ALPHA0 := 0.01
const COAT_SECONDS := 8.0
## MoveLollipop2: 0.2s ease-in back home (double 0x3FC99999A0000000 at
## 0xAE960).
const RETURN_SECONDS := 0.2

## Sprayer consumable (see header).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const HOSE_KEY := "DM_CONSUMABLE_BANANA_HOSE"
const HOSE_NAME := "Sprayer_60Dip"
const HOSE_COST := 11
const HOSE_MESSAGE := "Try out the Sprayer! Easily coat Chocolate Dipped Banana! Try it for FREE now!"
const HOSE_BADGE_ART := "chocolate_sprayer_upgrade.png"
const HOSE_BADGE_CENTER := Vector2(50, 350.5)
const HOSE_ART := "ff_banana_chocolatesprayer_back.png"
const HOSE_HOME := Vector2(160, 380)
const HOSE_SIZE := Vector2(71, 176)
const HOSE_SNAP := 0.5
const SPRAY_SHEET := "Chocolate_Spray_Sheet.png"
const SPRAY_CELL := Vector2(124, 240)
const SPRAY_COLUMNS := 3
const SPRAY_OFFSET := Vector2(-3, -157)
const HOSE_TICK_S := 0.1
const HOSE_COAT_STEP := 0.05
const HOSE_INSTRUCTION := "inst_spray_pops.png"   # absent from the bundle

var _hose: Node2D
var _hose_consumable: RefCounted
var _hose_button: TextureButton
var _spray: Sprite2D
var _hose_timer: Timer
var _hose_touched := false
var _done_hosing := false
var _hose_time := 0.0
var _hose_dragging := false
var _hose_grab := Vector2.ZERO
## The hose's SnapToOrig glide home (see _hose_input).
var _hose_snap: Tween
var _spray_alpha := 0.0     # stands in for lollipopCoating when no colour is carried

var _lolli: Node2D
var _coating: Sprite2D
var _is_coating := false
var _done_coating := false
var _drag_enabled := true
var _lolli_locked := false   # showHose: setLockXMovement/setLockYMovement YES
var _dragging := false
var _grab := Vector2.ZERO
## The shared infoDict (see ccbSelectStickViewController._info).
var _info: Dictionary = {}


func on_enter() -> void:
	_info = GameState.custom_categories
	_build_mix()
	_build_hose()                              # viewDidLoad: hose, sheet, badge
	_view_will_appear()


## viewWillAppear: (0xADED0) -- the first appearance and every return:
## "inst_dip_banana" slid in (next hidden), initLollipops (0xAE118: the old
## lollipop removed, a fresh uncoated, unlocked one at (160,140)),
## isCoating/doneCoating 0, the hose hidden, the sprayer badge unhidden, a
## NEW 0.1 s hoseTimer, the spray sheet hidden, hoseTime 0.
func _view_will_appear() -> void:
	change_instruction("inst_dip_banana.png")
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false     # changeInstruction: tail
	_build_lollipop()
	_restack()
	_dragging = false
	_drag_enabled = true
	_lolli_locked = false
	_is_coating = false
	_done_coating = false
	_hose_dragging = false
	if _hose != null:
		_hose.visible = false
	if _hose_button != null:
		_hose_button.visible = true
	_hose_timer.start()
	if _spray != null:
		_spray.visible = false
	_hose_time = 0.0


## UINavigationController keeps this controller alive under
## ccbFreezerViewController (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from ccbFreezerViewController: viewWillAppear: again -- the banana
## has to be dipped again before next returns. viewWillDisappear: (0xAE090)
## stops spraying_loop and invalidates the hose timer (on_exit).
func on_resume() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		# CoinHUD re-adds the panel after this; drop the first appearance's.
		remove_child(old)
		old.queue_free()
	_view_will_appear()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _color() -> Variant:
	return _info.get("Color")


## viewDidLoad (0xAD81C): mix = alt-tinted Melted_Chocolate.png stretched to
## the nib frame. Entered standalone with no Color, absent rather than
## invented.
func _build_mix() -> void:
	var c: Variant = _color()
	if not (c is Color):
		return
	var tinted := caSelectChocolate.bake_alt_tint(
		_tex("Melted_Chocolate.png"), c, 3)
	if tinted == null:
		return
	var mix := outlet("mix") as Sprite2D
	if mix == null:
		mix = Sprite2D.new()
		add_child(mix)
	mix.texture = tinted
	mix.centered = false
	mix.position = MIX_RECT.position
	mix.scale = MIX_RECT.size / Vector2(tinted.get_size())


## initLollipops (0xAE118). Children are positioned relative to the
## container's centre (Godot scales a Node2D about its origin; UIKit scales
## a view about its centre, so the origin sits at the UIKit centre).
func _build_lollipop() -> void:
	if _lolli != null:
		_lolli.queue_free()
	_lolli = Node2D.new()
	_lolli.position = LOLLI_HOME
	_lolli.scale = Vector2(LOLLI_SCALE, LOLLI_SCALE)
	add_child(_lolli)
	# insertSubview:belowSubview:coating -- under the (unported) spray layer,
	# i.e. above the mix; keep it below the chrome.
	var inst := outlet("instIV")
	if inst != null and inst != self:
		move_child(_lolli, (inst as Node).get_index())

	var half := LOLLI_SIZE * 0.5
	var stick_tex := _tex(str(_info.get("Stick", "")))
	var stick_h := 0.0
	if stick_tex != null:
		stick_h = stick_tex.get_size().y
		var stick := Sprite2D.new()
		stick.texture = stick_tex
		# centre (W/2, H - stickH), container coords, natural size --
		# Candy Apple scales its stick 1.25; this screen does not.
		stick.position = Vector2(0, (LOLLI_SIZE.y - stick_h) - half.y)
		_lolli.add_child(stick)

	var banana_local := Vector2(BANANA_DX, (LOLLI_SIZE.y - stick_h * 0.5) - half.y)
	var banana_tex := _tex("banana_for_stick.png")
	if banana_tex != null:
		var b := Sprite2D.new()
		b.texture = banana_tex
		b.position = banana_local
		b.rotation = PART_ROTATION      # CGAffineTransformRotate(.., 3.1416)
		_lolli.add_child(b)             # insertSubview:aboveSubview:stick

	var c: Variant = _color()
	if c is Color:
		var coat_tex := caSelectChocolate.bake_alt_tint(
			_tex("cc_banana.png"), c, 3)
		if coat_tex != null:
			_coating = Sprite2D.new()
			_coating.texture = coat_tex
			_coating.position = banana_local + Vector2(0, COATING_DY)
			_coating.rotation = PART_ROTATION
			_coating.visible = false
			_lolli.add_child(_coating)  # insertSubview:aboveSubview:banana


func _lolli_rect() -> Rect2:
	var size := LOLLI_SIZE * LOLLI_SCALE
	return Rect2(_lolli.position - size * 0.5, size)


func _unhandled_input(event: InputEvent) -> void:
	if _hose_input(event):
		return
	if _lolli == null or not _drag_enabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and not _dragging and _lolli_rect().has_point(mb.position):
			_dragging = true
			_grab = _lolli.position - mb.position
			Audio.play("pickup")          # draggableTouchBegan: 0xAED70
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			_released()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		if _lolli_locked:
			# lockX/lockYMovement: DraggableIV moves nothing; the delegate's
			# clamp (centre.y >= 254.5) cannot fire at home (y 140).
			get_viewport().set_input_as_handled()
			return
		var p: Vector2 = (event as InputEventMouseMotion).position + _grab
		_lolli.position = p
		# draggableTouchMoved: (0xAEEE0): pin the centre to
		# mix.centre.y - 45 -- the banana cannot sink past the surface.
		var limit := MIX_CENTER.y + DIP_OFFSET_Y
		if _lolli.position.y >= limit:
			_lolli.position.y = limit
		get_viewport().set_input_as_handled()


## draggableTouchEnded: (0xAF0D4), lollipop branch.
func _released() -> void:
	if _lolli_rect().intersects(MIX_RECT) and not _is_coating \
			and not _done_coating:
		_start_dip()
	else:
		# No snap tween: lollipop snapTime is never set (default 0 = jump).
		_lolli.position = LOLLI_HOME
	# The tail (0xAF2C8): not over mix, not coating, already coated, next
	# hidden -> showNextButton. Reached via the sprayer (see header).
	if not _lolli_rect().intersects(MIX_RECT) and not _is_coating \
			and _done_coating and not _next_visible():
		show_next_button()


func _next_visible() -> bool:
	var n := outlet("nextButton")
	return n != null and n != self and (n as CanvasItem).visible


func _start_dip() -> void:
	_is_coating = true
	_drag_enabled = false                 # setUserInteractionEnabled:0
	# "MoveLollipop": 0.25s curve 1 to (mix.centre.x, mix.centre.y - 45).
	create_tween().tween_property(_lolli, "position",
		Vector2(MIX_CENTER.x, MIX_CENTER.y + DIP_OFFSET_Y), DIP_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	# "ApplyCoating": alpha 0.01 -> 1.0 over 8.0s, then animationDidStop.
	if _coating != null:
		_coating.visible = true
		_coating.modulate.a = COAT_ALPHA0
		var tw := create_tween()
		tw.tween_property(_coating, "modulate:a", 1.0, COAT_SECONDS) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tw.tween_callback(_coating_done)
	else:
		# No colour carried (standalone entry): run the same clock so the
		# screen still completes.
		get_tree().create_timer(COAT_SECONDS).timeout.connect(_coating_done)


## animationDidStop "ApplyCoating" (0xAE740).
func _coating_done() -> void:
	_is_coating = false
	_done_coating = true
	_drag_enabled = false                 # lollipop setUserInteractionEnabled:0
	var tw := create_tween()
	tw.tween_property(_lolli, "position", LOLLI_HOME, RETURN_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	# "MoveLollipop2" -> "RotateLollipop" is an empty animation block (dead)
	# followed by showNextButton.
	tw.tween_callback(show_next_button)


## nextClick: (0xAF8D8): button_press, hose quantity zeroed (IAP), push
## ccbFreezerViewController with the same infoDict. The bake happens THERE.
func _on_nextClick() -> void:
	Audio.play("button_press")
	_hose_consumable.set("quantity", 0)   # nextClick: setQuantity:0
	GameState.custom_categories = _info
	Nav.next()


## skipClick: (0xAF9BC) forwards to nextClick: -- no nib action reaches it.
func _on_skipClick() -> void:
	_on_nextClick()


## viewWillDisappear:: stop spraying_loop, invalidate hoseTimer.
func on_exit() -> void:
	Audio.stop("spraying_loop")
	if _hose_timer != null:
		_hose_timer.stop()


# -- the sprayer consumable ------------------------------------------------

## viewDidLoad (hose, coating, badge); viewWillAppear: hides the hose and
## starts the timer (_view_will_appear).
func _build_hose() -> void:
	_hose_consumable = ConsumableScript.new(HOSE_KEY, HOSE_NAME, HOSE_COST)
	_hose_consumable.set("first_time_message", HOSE_MESSAGE)
	_hose_consumable.set("on_purchased", _on_hose_purchased)
	_hose_consumable.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))

	var c: Variant = _color()
	var sheet: Texture2D = _tex(SPRAY_SHEET)
	if c is Color and sheet != null:
		sheet = caSelectChocolate.bake_alt_tint(sheet, c, 3)
	_spray = Sprite2D.new()
	_spray.texture = sheet
	_spray.region_enabled = true
	_spray.region_rect = Rect2(Vector2.ZERO, SPRAY_CELL)
	_spray.visible = false
	add_child(_spray)

	_hose = Node2D.new()
	_hose.position = HOSE_HOME
	_hose.visible = false
	var art := Sprite2D.new()
	art.texture = _tex(HOSE_ART)
	if art.texture != null:
		# UIImageView scale-to-fill into the 71x176 frame.
		art.scale = HOSE_SIZE / art.texture.get_size()
	_hose.add_child(art)
	add_child(_hose)
	_restack()

	_hose_button = ConsumableButtonScript.new()
	_hose_button.name = "buyHose"
	_hose_button.call("setup", HOSE_BADGE_ART, 0, -25, HOSE_COST, 65, 3)
	_hose_button.position = HOSE_BADGE_CENTER - _hose_button.size * 0.5
	_hose_button.pressed.connect(_on_buyClick)
	add_child(_hose_button)

	_hose_timer = Timer.new()
	_hose_timer.wait_time = HOSE_TICK_S
	_hose_timer.timeout.connect(_hose_tick)
	add_child(_hose_timer)


## Nib order below instIV: lollipop, then coating, then hose.
func _restack() -> void:
	var inst := outlet("instIV")
	if inst == null or inst == self:
		return
	for n in [_spray, _hose]:
		if n != null and n.get_parent() == self:
			move_child(n, (inst as Node).get_index())


func _on_buyClick() -> void:
	Audio.play("store")
	_hose_consumable.call("purchase", self)


## consumablePurchased:.
func _on_hose_purchased(_free: bool) -> void:
	_hose_consumable.set("quantity", 1)
	_show_hose()
	_hose_button.visible = false


## showHose.
func _show_hose() -> void:
	change_instruction(HOSE_INSTRUCTION)
	# inst_spray_pops.png does not ship, so the original's banner carries a
	# nil image from here on; blank it rather than keep the dip art.
	if not Assets.has_image(HOSE_INSTRUCTION):
		var iv := _instruction_node()
		if iv is Sprite2D:
			(iv as Sprite2D).texture = null
	_build_lollipop()
	_restack()
	_done_hosing = false
	_hose_touched = false
	_hose.visible = true
	_lolli.visible = true
	_lolli.position = LOLLI_HOME
	# The new lollipop keeps interaction ON with X and Y movement locked.
	_drag_enabled = true
	_lolli_locked = true
	if _coating != null:
		_coating.visible = true
		_coating.modulate.a = 0.0
	_spray_alpha = 0.0
	_hose_time = 0.0
	_hose.position = HOSE_HOME


func _hose_rect() -> Rect2:
	return Rect2(_hose.position - HOSE_SIZE * 0.5, HOSE_SIZE)


func _hose_snapping() -> bool:
	return _hose_snap != null and _hose_snap.is_valid() and _hose_snap.is_running()


func _spray_rect() -> Rect2:
	return Rect2(_spray.position - SPRAY_CELL * 0.5, SPRAY_CELL)


## The hose branches of draggableTouchBegan/Moved/Ended:. Returns true when
## the event belonged to the hose.
func _hose_input(event: InputEvent) -> bool:
	if _hose == null or not _hose.visible:
		return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		# The 0.5 s SnapToOrig glide (DraggableIV touchesEnded: 0x46860) is
		# +beginAnimations:/commitAnimations: the hose stays touchable on the
		# way home, hit-tested at its MODEL centre (origCenter), and a grab
		# takes it over from there -- touchBegan (0xAED70) puts the spray at
		# hose.center (the model) + (-3, -157). The port used to hit-test the
		# drawn hose and leave the snap tween running under the finger, so the
		# hose glided home while the spray stayed with the finger.
		# PORT CHOICE: the hose lands on the model at once instead of gliding
		# on toward the finger for the rest of the 0.5 s.
		var snapping := _hose_snapping()
		var hit_rect := Rect2(HOSE_HOME - HOSE_SIZE * 0.5, HOSE_SIZE) \
			if snapping else _hose_rect()
		if mb.pressed and not _hose_dragging and hit_rect.has_point(mb.position):
			if snapping:
				_hose_snap.kill()
				_hose.position = HOSE_HOME
			_hose_dragging = true
			_hose_grab = _hose.position - mb.position
			Audio.loop("spraying_loop")
			_hose_touched = true
			_spray.visible = true
			_spray.position = _hose.position + SPRAY_OFFSET
			get_viewport().set_input_as_handled()
			return true
		if not mb.pressed and _hose_dragging:
			_hose_dragging = false
			Audio.stop("spraying_loop")
			_hose_touched = false
			_spray.visible = false
			# DraggableIV touchesEnded: snapTime 0.5, linear.
			_hose_snap = create_tween()
			_hose_snap.tween_property(_hose, "position", HOSE_HOME, HOSE_SNAP) \
				.set_trans(Tween.TRANS_LINEAR)
			get_viewport().set_input_as_handled()
			return true
	elif event is InputEventMouseMotion and _hose_dragging:
		_hose.position = (event as InputEventMouseMotion).position + _hose_grab
		_spray.position = _hose.position + SPRAY_OFFSET
		get_viewport().set_input_as_handled()
		return true
	return false


## hoseTick, on the 0.1 s timer.
func _hose_tick() -> void:
	if not _hose_touched or _lolli == null:
		return
	if _coating != null:
		_coating.visible = true
	_lolli.visible = true
	if _spray_rect().intersects(_lolli_rect()):
		if _coating != null:
			_coating.modulate.a = clampf(_coating.modulate.a + HOSE_COAT_STEP, 0.0, 1.0)
		_spray_alpha = clampf(_spray_alpha + HOSE_COAT_STEP, 0.0, 1.0)
	_hose_time += HOSE_TICK_S
	var idx := randi() % SPRAY_COLUMNS
	_spray.region_rect = Rect2(Vector2(SPRAY_CELL.x * idx, 0), SPRAY_CELL)
	var a: float = _coating.modulate.a if _coating != null else _spray_alpha
	if a >= 1.0 and not _done_hosing:
		_done_hosing = true
		show_next_button()


## backClick:: button_press, quantity 0, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	if _hose_consumable != null:
		_hose_consumable.set("quantity", 0)
	Nav.back()


## This screen's changeInstruction: hides nextButton (read from the
## original binary); Screen.change_instruction honours it when given an image.
func instruction_hides_next() -> bool:
	return true
