# Candy Apple step 7 -- dip the apple in the pot, then hand the finished
# food to MakeViewController.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithNibName: 0x15C348, viewDidLoad 0x15C5FC, viewWillAppear: 0x15CD18,
#   viewWillDisappear: 0x15CF50, initLollipops 0x15CFD8, animationDidStop
#   0x15D680, draggableTouchBegan/Moved/Ended 0x15DCB0/0x15DE20/0x15DEF4,
#   nextClick: 0x15E6F4, skipClick: 0x15EFF8, changeInstruction: 0x15F008,
#   showNextButton 0x15F210.
#
# Mechanic, as read (the free path -- the spray gun is a consumable):
#  * mix: nib UIImageView (34,245,253,109), image = Melted_Chocolate.png
#    through TintedIV's ALTERNATE tint (art as backdrop, infoDict[Color]
#    filled over it with CGBlendMode 3 / Overlay -- 0x4711C/0x474FC),
#    stretched to the nib frame.
#  * initLollipops builds the apple-on-a-stick as one DraggableIV: a clear
#    325x400 container, transform scale 0.35, centre (160,140)
#    (0x43A38000/0x43C80000; 0x430C0000 home y). Children, in container
#    coordinates: the stick (infoDict[Stick], scale 1.25) centred at
#    (W/2, H - scaledStickH); apple back/front (Image_bg/Image_fg) centred
#    at (W/2, H - scaledStickH/2); the coating (chocolate_dip.png,
#    alternate-tinted) at the apple's centre, hidden.
#  * Release the drag with the lollipop's frame intersecting mix's and the
#    dip runs (draggableTouchEnded 0x15DEF4): interaction off, 0.25s ease-in
#    to (mix.centre.x, mix.centre.y - 25), coating shown at alpha 0.01 and
#    faded to 1.0 over 8.0 seconds ("ApplyCoating", curve 1). Release
#    anywhere else and the lollipop jumps straight home (no snap tween --
#    lollipop snapTime is never set and DraggableIV's default is 0).
#  * animationDidStop (0x15D680): ApplyCoating -> lollipop interaction off,
#    0.2s ease-in back to (160,140) ("MoveLollipop2": VLDR D16 =
#    0.200000003 at 0x15D74A -- the double is 0x3FC99999A0000000; the port
#    used to read it as 1.6 s); MoveLollipop2 -> an empty "RotateLollipop"
#    animation block (0.2 s, sets no properties -- dead) and the next button
#    slides in at once.
#  * View order (viewDidLoad / initLollipops): bowl, mix, lollipop (inserted
#    below the spray sheet), spray sheet (below the hose), hose (below
#    instIV), instIV, the sprayer badge (above instIV), back, next.
#  * touchBegan on the lollipop plays "pickup" (0x15DCB0 else-branch).
#
# nextClick: (0x15E6F4) bakes five layers into MakeViewController's
# customCategories (the port's GameState.custom_categories), each
# {Properties, Image}. ItemCenterX/Y are the art's TOP-LEFT (zero-frame
# DecorateItemView; see MakeViewController's header) and each UIImage is
# rebuilt with an explicit scale, i.e. displayed at pixels/scale:
#   EatingPlate       candyappleplate.png, scale 1,   VI 2, (0,290),  inedible
#   CandyStick        infoDict[Stick],     scale 2.0, VI 4, (135,50), inedible
#   AppleBack         Image_bg,            scale 1.3, VI 3, (62,175), edible
#   AppleFront        Image_fg,            scale 1.3, VI 5, (62,175), edible
#   ChocolateCoating  chocolate_dip_plate.png alternate-tinted with Color,
#                                          scale 1.3, VI 6, (62,175), edible
# (floats 0x43910000=290, 0x43070000=135, 0x42480000=50, 0x42780000=62,
# 0x432F0000=175; scales 0x40000000=2.0, 0x3FA66666=1.3.) The AppleBack/
# Front/Coating entries also carry Layer 2/2/1, which MakeViewController
# ignores; kept for fidelity.
#
# Sprayer consumable, PORTED (the phone shows the badge):
#   initWithNibName: 0x15C348  Consumable DM_CONSUMABLE_HOSE / Sprayer_70Dip, cost from the (dead)
#     server table GameData.CoinCosts."Candy Apple".ToolSprayGun, 11 when absent;
#     first-time message "Try out the Sprayer! Easily coat Candy Apple! Try it for FREE now!"; quantity 0.
#   viewDidLoad 0x15C5FC  hose = DraggableIV Chocolate_Spray_Gun.png, home centre (160,380)
#     (0x43200000/0x43BE0000), setFrame 71x176 (0x428E0000/0x43300000, the
#     art squashed to fill), re-centred at origCenter, snapTime 0.5; inserted
#     below instIV. coating = SpriteSheetView (0,0,124,240) over the
#     alt-tinted Chocolate_Spray_Sheet.png (372x480, blend 3) in 3 columns x
#     2 rows, inserted below the hose. buyHose = ConsumableButton
#     (btn_IAP_chocolate_gun.png, offsets (0,-25)/(65,3)) above instIV at centre (50, 350.5),
#     buyClick: on touch-up.
#   viewWillAppear: 0x15CD18  hose hidden, badge shown, hoseTimer 0.1 s ->
#     hoseTick, coating hidden, hoseTime 0.
#   buyClick: 0x15E5F4  "store" sound, purchaseConsumable.
#   consumablePurchased: 0x15E340  quantity = 1, showHose, badge hidden.
#   showHose 0x15D8A8  changeInstruction: inst_spray_pops.png (NOT in the
#     bundle -> the banner shows nil, i.e. blank), initLollipops, doneHosing
#     and hoseTouched 0, hose and lollipop unhidden, the lollipop's layer
#     animations removed and its centre reset to origCenter (160,140), its X
#     and Y movement locked, lollipopCoating unhidden at alpha 0, hoseTime 0,
#     hose centre reset to origCenter.
#   draggableTouchBegan: 0x15DCB0 (hose)  loop spraying_loop.mp3, hoseTouched
#     1, coating unhidden at (hose.centre.x - 3, hose.centre.y - 157)
#     (0xC0400000/0xC31D0000). draggableTouchMoved: 0x15DE20  the coating
#     follows the hose at that offset. draggableTouchEnded: 0x15DEF4  stop
#     spraying_loop, hoseTouched 0, coating hidden (DraggableIV then snaps the
#     hose home over 0.5 s).
#   hoseTick 0x15DAAC  while hoseTouched: lollipopCoating and lollipop
#     unhidden; if coating.frame intersects lollipop.frame, lollipopCoating
#     alpha += 0.05 (0x3D4CCCCD); hoseTime += 0.1; coating currentFrameIdx =
#     arc4random % 3 then tick (a random top-row cell); at alpha >= 1.0 and
#     not doneHosing: doneHosing, showNextButton.
#   consumablePurchaseFailed:error: 0x15E520  error 2 -> alert "You do not
#     have enough coins." (the port's Consumable shows it for too few coins
#     where the original showed an ad -- PORT CHOICE).
#   backClick: 0x15E660 / nextClick: 0x15E6F4  quantity 0.
#   viewWillDisappear: 0x15CF50  stop spraying_loop, invalidate hoseTimer.
# No SSEmitter on this screen; the spray is the sprite sheet.
# The lollipop rebuilt by showHose keeps userInteractionEnabled YES with
# lockX/YMovement set: a touch still plays "pickup" and its release still
# runs draggableTouchEnded:'s lollipop branch (home, and -- if a dip had
# already finished -- the tail's showNextButton). Ported as a locked drag
# (the port used to disable the lollipop outright).
# Not ported: the AdColony video hook in viewDidLoad (0x15CBF4).
#
# KEEP STATE: the controller survives under MakeViewController. On
# return viewWillAppear: (0x15CD18) re-runs: "inst_dip_apple" slid in (next
# hidden), initLollipops (0x15CFD8: the old lollipop removed, a fresh,
# uncoated, unlocked one at (160,140)), isCoating/doneCoating 0, the hose
# hidden, the sprayer badge unhidden, a NEW 0.1 s hoseTimer, the spray sheet
# hidden, hoseTime 0 -- the apple must be dipped again before next returns.
# viewWillDisappear: (0x15CF50) stops spraying_loop and invalidates the
# timer. The lollipop is built from this screen's own infoDict, so a return
# from Make (whose carrier is the bake) still finds Stick/Image_bg/fg/Color.

extends "res://core/Screen.gd"

const caSelectChocolate := preload("res://screens/caSelectChocolate.gd")

const MIX_RECT := Rect2(34, 245, 253, 109)      # nib id 3
const MIX_CENTER := Vector2(160.5, 299.5)
## initLollipops: clear container 325x400, scale 0.35, home (160,140).
const LOLLI_SIZE := Vector2(325, 400)
const LOLLI_SCALE := 0.35
const LOLLI_HOME := Vector2(160, 140)
const STICK_SCALE := 1.25
## The dip: 0.25s ease-in to mix centre + (0,-25) (0xC1C80000).
const DIP_SECONDS := 0.25
const DIP_OFFSET_Y := -25.0
## ApplyCoating: alpha 0.01 -> 1.0 over 8.0s, curve 1 (ease-in).
const COAT_ALPHA0 := 0.01
const COAT_SECONDS := 8.0
## MoveLollipop2: 0.2s ease-in back home (double 0x3FC99999A0000000).
const RETURN_SECONDS := 0.2

## Sprayer consumable (see header).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const HOSE_KEY := "DM_CONSUMABLE_HOSE"
const HOSE_NAME := "Sprayer_70Dip"
const HOSE_COST := 11
const HOSE_MESSAGE := "Try out the Sprayer! Easily coat Candy Apple! Try it for FREE now!"
const HOSE_BADGE_ART := "btn_IAP_chocolate_gun.png"
const HOSE_BADGE_CENTER := Vector2(50, 350.5)
const HOSE_ART := "Chocolate_Spray_Gun.png"
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
## The hose's SnapToOrig glide home, while it runs (see _hose_input).
var _hose_snap: Tween
var _spray_alpha := 0.0     # stands in for lollipopCoating when no colour is carried

## The bake (nextClick: 0x15E6F4) -- see header for the address of every
## number here.
const PLATE_TOP_LEFT := Vector2(0, 290)
const STICK_TOP_LEFT := Vector2(135, 50)
const STICK_IMG_SCALE := 2.0
const APPLE_TOP_LEFT := Vector2(62, 175)
const APPLE_IMG_SCALE := 1.3

var _lolli: Node2D
var _coating: Sprite2D
var _is_coating := false
var _done_coating := false
var _drag_enabled := true
var _lolli_locked := false   # showHose: lockXMovement + lockYMovement
var _dragging := false
var _grab := Vector2.ZERO
## The shared infoDict (see caSelectStick._info).
var _info: Dictionary = {}


func on_enter() -> void:
	_info = GameState.custom_categories
	_build_mix()
	_build_hose()                              # viewDidLoad: hose, sheet, badge
	_view_will_appear()


## viewWillAppear: (0x15CD18) -- the first appearance and every return.
func _view_will_appear() -> void:
	change_instruction("inst_dip_apple.png")
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false     # changeInstruction: tail
	_build_lollipop()                          # initLollipops
	_restack()
	_dragging = false
	_drag_enabled = true                       # the new lollipop is interactive
	_lolli_locked = false                      # ... and not locked
	_is_coating = false
	_done_coating = false
	_hose_dragging = false
	if _hose != null:
		_hose.visible = false
	if _hose_button != null:
		_hose_button.visible = true
	_hose_timer.start()                        # a new 0.1 s hoseTimer
	if _spray != null:
		_spray.visible = false
	_hose_time = 0.0


## UINavigationController keeps this controller alive under
## MakeViewController (Nav.gd's opt-in).
func keeps_state_on_push() -> bool:
	return true


## Back from MakeViewController: viewWillAppear: again (see header).
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


func _build_mix() -> void:
	var c: Variant = _color()
	if not (c is Color):
		return          # standalone entry: absent rather than invented
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


## initLollipops (0x15CFD8). Children are positioned relative to the
## container's centre (Godot scales a Node2D about its origin; UIKit scales
## a view about its centre, so the origin is placed at the UIKit centre).
func _build_lollipop() -> void:
	if _lolli != null:
		_lolli.queue_free()
	_lolli = Node2D.new()
	_lolli.position = LOLLI_HOME
	_lolli.scale = Vector2(LOLLI_SCALE, LOLLI_SCALE)
	add_child(_lolli)

	var half := LOLLI_SIZE * 0.5
	var stick_tex := _tex(str(_info.get("Stick", "")))
	var stick_h := 0.0
	if stick_tex != null:
		stick_h = stick_tex.get_size().y * STICK_SCALE
		var stick := Sprite2D.new()
		stick.texture = stick_tex
		stick.scale = Vector2(STICK_SCALE, STICK_SCALE)
		# centre (W/2, H - scaledStickH), container coords.
		stick.position = Vector2(0, (LOLLI_SIZE.y - stick_h) - half.y)
		_lolli.add_child(stick)

	var apple_local := Vector2(0, (LOLLI_SIZE.y - stick_h * 0.5) - half.y)
	var back_tex := _tex(str(_info.get("Image_bg", "")))
	if back_tex != null:
		var b := Sprite2D.new()
		b.texture = back_tex
		b.position = apple_local
		_lolli.add_child(b)
		# insertSubview:belowSubview:stick -- back sits under the stick.
		_lolli.move_child(b, 0)

	var front_tex := _tex(str(_info.get("Image_fg", "")))
	if front_tex != null:
		var f := Sprite2D.new()
		f.texture = front_tex
		f.position = apple_local
		_lolli.add_child(f)

	var c: Variant = _color()
	if c is Color:
		var coat_tex := caSelectChocolate.bake_alt_tint(
			_tex("chocolate_dip.png"), c, 3)
		if coat_tex != null:
			_coating = Sprite2D.new()
			_coating.texture = coat_tex
			_coating.position = apple_local
			_coating.visible = false
			_lolli.add_child(_coating)


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
			Audio.play("pickup")          # draggableTouchBegan: 0x15DD70
			get_viewport().set_input_as_handled()
		elif not mb.pressed and _dragging:
			_dragging = false
			_released()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		if not _lolli_locked:
			_lolli.position = (event as InputEventMouseMotion).position + _grab
		get_viewport().set_input_as_handled()


## draggableTouchEnded: (0x15DEF4), lollipop branch.
func _released() -> void:
	if _lolli_rect().intersects(MIX_RECT) and not _is_coating \
			and not _done_coating:
		_start_dip()
	else:
		# No snap tween: lollipop snapTime is never set (default 0 = jump).
		_lolli.position = LOLLI_HOME
	# The tail: not over mix, not coating, a dip already done, next hidden
	# -> showNextButton. Reachable only through the hose's locked lollipop
	# (after a finished dip, showHose's changeInstruction: hid next).
	var n := outlet("nextButton")
	if not _lolli_rect().intersects(MIX_RECT) and not _is_coating \
			and _done_coating and n != null and n != self \
			and not (n as CanvasItem).visible:
		show_next_button()


func _start_dip() -> void:
	_is_coating = true
	_drag_enabled = false
	# "MoveLollipop": 0.25s curve 1 to (mix.centre.x, mix.centre.y - 25).
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
		# No colour was carried (standalone entry): run the same clock so
		# the screen still completes.
		get_tree().create_timer(COAT_SECONDS).timeout.connect(_coating_done)


## animationDidStop "ApplyCoating" (0x15D680).
func _coating_done() -> void:
	_is_coating = false
	_done_coating = true
	var tw := create_tween()
	tw.tween_property(_lolli, "position", LOLLI_HOME, RETURN_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	# "MoveLollipop2" -> "RotateLollipop" is an empty animation block (dead)
	# followed by showNextButton.
	tw.tween_callback(show_next_button)


# -- the bake (nextClick: 0x15E6F4) --------------------------------------

## A UIImage rebuilt with scale s renders at pixels/s; reproduce by
## resampling the Image (bilinear, as CG would).
func _img_scaled(tex: Texture2D, s: float) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	if s != 1.0:
		img.resize(int(round(img.get_width() / s)),
			int(round(img.get_height() / s)), Image.INTERPOLATE_BILINEAR)
	return img


func _layer(image: Image, edible: bool, view_index: int, top_left: Vector2,
		extra: Dictionary = {}) -> Dictionary:
	var props := {
		"IsEdible": edible, "ViewIndex": view_index, "Type": "Stationary",
		"ItemCenterX": top_left.x, "ItemCenterY": top_left.y,
	}
	props.merge(extra)
	return {"Properties": props, "Image": image}


func _on_nextClick() -> void:
	Audio.play("button_press")
	_hose_consumable.set("quantity", 0)   # nextClick: setQuantity:0
	var stick_file := str(_info.get("Stick", ""))
	var bg_file := str(_info.get("Image_bg", ""))
	var fg_file := str(_info.get("Image_fg", ""))
	var c: Variant = _color()

	var out := {}
	var plate := _img_scaled(_tex("candyappleplate.png"), 1.0)
	if plate != null:
		out["EatingPlate"] = _layer(plate, false, 2, PLATE_TOP_LEFT)
	var stick := _img_scaled(_tex(stick_file), STICK_IMG_SCALE)
	if stick != null:
		out["CandyStick"] = _layer(stick, false, 4, STICK_TOP_LEFT)
	var back := _img_scaled(_tex(bg_file), APPLE_IMG_SCALE)
	if back != null:
		out["AppleBack"] = _layer(back, true, 3, APPLE_TOP_LEFT, {"Layer": 2})
	var front := _img_scaled(_tex(fg_file), APPLE_IMG_SCALE)
	if front != null:
		out["AppleFront"] = _layer(front, true, 5, APPLE_TOP_LEFT, {"Layer": 2})
	if c is Color:
		var coat := _img_scaled(caSelectChocolate.bake_alt_tint(
			_tex("chocolate_dip_plate.png"), c, 3), APPLE_IMG_SCALE)
		if coat != null:
			out["ChocolateCoating"] = _layer(coat, true, 6, APPLE_TOP_LEFT,
				{"Layer": 1})
	GameState.custom_categories = out
	Nav.next()


## skipClick: (0x15EFF8) forwards to nextClick: -- no nib action reaches it.
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
	_hose_consumable.set("quantity", 0)      # initWithNibName: setQuantity:0
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
	_restack()

	_hose_timer = Timer.new()
	_hose_timer.wait_time = HOSE_TICK_S
	_hose_timer.timeout.connect(_hose_tick)
	add_child(_hose_timer)


## Nib order below instIV: lollipop, then the spray sheet, then the hose;
## the badge sits just above instIV (insertSubview:aboveSubview:).
func _restack() -> void:
	var inst := outlet("instIV")
	if inst == null or inst == self:
		return
	for n in [_lolli, _spray, _hose]:
		if n != null and n.get_parent() == self:
			move_child(n, (inst as Node).get_index())
	if _hose_button != null and _hose_button.get_parent() == self:
		move_child(_hose_button, (inst as Node).get_index() + 1)


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
	# The new lollipop is interactive again (initLollipops) but locked.
	_drag_enabled = true
	_lolli_locked = true
	if _coating != null:
		_coating.visible = true
		_coating.modulate.a = 0.0
	_spray_alpha = 0.0
	_hose_time = 0.0
	if _hose_snapping():
		_hose_snap.kill()     # a snap still running would pull it off again
	_hose.position = HOSE_HOME


func _hose_rect() -> Rect2:
	return Rect2(_hose.position - HOSE_SIZE * 0.5, HOSE_SIZE)


func _hose_snapping() -> bool:
	return _hose_snap != null and _hose_snap.is_valid()


## Where a touch finds the hose. SnapToOrig (DraggableIV touchesEnded:
## 0x46860) is +beginAnimations:/commitAnimations, so the hose stays
## touchable on its way home -- hit-tested at origCenter, its model, not
## where it is drawn (UIKit, see core/DraggableSprite2D.gd).
func _hose_hit_rect() -> Rect2:
	if _hose_snapping():
		return Rect2(HOSE_HOME - HOSE_SIZE * 0.5, HOSE_SIZE)
	return _hose_rect()


func _spray_rect() -> Rect2:
	return Rect2(_spray.position - SPRAY_CELL * 0.5, SPRAY_CELL)


## The hose branches of draggableTouchBegan/Moved/Ended:. Returns true when
## the event belonged to the hose.
func _hose_input(event: InputEvent) -> bool:
	if _hose == null or not _hose.visible:
		return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and not _hose_dragging and _hose_hit_rect().has_point(mb.position):
			if _hose_snapping():
				# Grabbed on the way home: the drag takes over from the model
				# (origCenter). The port used to leave the snap running, so
				# the drawn hose slid home under the finger while the spray
				# -- and the coating hoseTick reads from it -- stayed with
				# the finger.
				# PORT CHOICE: UIKit's presentation would glide on toward
				# the finger for the rest of the 0.5 s; the port lands it.
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
