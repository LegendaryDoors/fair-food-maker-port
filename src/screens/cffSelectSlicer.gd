# Curly Fries step 2 -- pick a slicer, then grate the peeled potato on it.
#
# From the original binary (IMPs from the ObjC method list; constants
# checked in the disassembly):
#   initWithNibName: 0x144280 (loads frenchFriesItem.plist -> slicerList and
#   the MysterySelect consumable), viewDidLoad 0x144484, viewWillAppear:
#   0x144A44 -> screenSetup 0x144B98, viewWillDisappear: 0x144B0C,
#   addSlicerImage: 0x144EA4, grateTick 0x144FB4, animationDidStop: 0x1455CC,
#   draggableTouchMoved:/Ended: 0x145828/0x1459AC, selectSlicer: 0x145E7C,
#   selectedSlicerClick: 0x146124, potatoAnimation 0x146B1C, showNextButton
#   0x146C08, changeInstruction: 0x146DA0 (hides next), showScrollView
#   0x146FAC, hideScrollView 0x147670, nextClick: 0x145F6C.
#
# Mechanic, as read: the slicer picker (slicerButton -> selectSlicer: ->
# showScrollView) drops a thumbnail grid in from centre y - 500; choosing
# one drops the blade in from -165 ("MoveBlade", 0.25s ease-in-out), flies
# the potato in from +200 and rebinds the bowl pile's base image. Dragging
# the potato (DraggableIV, snapTime 0.25, 0x1444AC) over the blade's frame
# loops "grating" and, on the 0.1s grateTick, spawns half-scale Slice_Image
# chips that fall 1.0s paced paths into the bowl. Each chip's LANDING --
# only if still grating and next hidden (0x1455CC) -- raises the MaskedIV
# pile by baseImg.height * 0.0333333 (0x3D088889) from baseOrigPt
# (centred-x, 208) (0x43500000); y < 24.0 shows next and stops the sound.
#
# The pile is a MaskedIV, and MaskedIV applies its mask upside down
# (drawRect: 0x46E68 -- CGContextClipToMask in UIKit's flipped context,
# no CTM flip; the ccbSelectChocolate pot proved it on the phone). For
# cff_PileMask that turns the authored mound into the bowl's interior, so
# the fries rise out of the bowl's bottom and fill it. Ported flipped
# (MaskedIV below); the water layer on the next screen fits the flipped
# cff_bowl_Mask exactly, which corroborates it.
#
# Z-order, as built: viewDidLoad inserts slicer below potatoSlice (the
# nib's LAST view, above every button) and the pile below the slicer, then
# addSubview:s the mystery badge on top; every showScrollView (screenSetup
# runs one) brings aScrollView and then slicerButton to the front.
#
# nextClick: hands cffAddWater the CHOSEN slicerList row plus the pile's
# final baseOrigPt (setPotatoBaseOrig:, 0x145F6C) -- carried here in
# GameState.custom_categories (house convention).
#
# Not ported (IAP, unreachable with everything unlocked): lockedFlavorButton
# / alertView (0x1469A0/0x146A30), Sub_Button_Background_Locked + black_lock
# overlays (contentLocked is false under FF_KEY_EVERYTHING, 0x144CF8).
#
# KEEP-STATE: kept alive under the push to cffAddWater.
# viewDidLoad's views are built once in on_enter; screenSetup (called by
# viewWillAppear:) runs on entry and again in on_resume, so a return resets
# the step exactly as the original does. on_exit = viewWillDisappear:.

extends "res://core/Screen.gd"

const DraggableSprite := preload("res://core/DraggableSprite2D.gd")

## Bundled table frenchFriesItem.plist, converted to frenchFriesItem.json on
## import (initWithNibName: 0x144280). Five slicers, keys Slicer_Image, Slice_Image,
## BowlPile_Image, BowlPile_Mask_Image, RawPile_Image, FriedPile_Image,
## Fryer_RawPile_Image, Fryer_FriedPile_Image, Slicer_Thumb_Image.
## The import cache's data/frenchFriesItem.json (Assets).
const TABLE_JSON := "frenchFriesItem"

## viewDidLoad 0x1444C0: slicer = UIImageView initWithFrame:(120,70,88,200)
## (0x42F00000/0x428C0000/0x42B00000/0x43480000); the slicer art is 88x200,
## so it renders at natural size. originalSlicerCenter = (164,170).
const SLICER_FRAME := Rect2(120, 70, 88, 200)
## Nib: potatoSlice DraggableIV (211,40,76,137), cff_Peeled_Potato.png
## (140x252) scale-to-filled. originalPotatoCenter = (249, 108.5).
const POTATO_FRAME := Rect2(211, 40, 76, 137)
const POTATO_ART := Vector2(140, 252)
## setSnapTime: 0x3E800000 (0x1444AC).
const POTATO_SNAP := 0.25
## Nib: bowlView frame (0,226,320,192); the MaskedIV pile is centred on its
## centre (160,322) (viewDidLoad 0x144558).
const PILE_CENTER := Vector2(160, 322)
## screenSetup 0x144C4C: setBaseOrigPt:(pileW/2 - baseW/2, 208.0)
## (0x43500000).
const PILE_ORIG_Y := 208.0
## animationDidStop 0x1455CC: rise = baseImg.height * 0.0333333 (0x3D088889)
## per landed chip; next when baseOrigPt.y < 24.0.
const PILE_RISE_FRACTION := 0.0333333
const PILE_DONE_Y := 24.0
## grateTime += 0.1 (0x3DCCCCCD) per landing -- kept, though nothing reads it.
const GRATE_TIME_STEP := 0.1
## screenSetup: grateTick every 0.1s (0x3FB99999A0000000); the potato parks
## at original centre + 200 (0x43480000).
const GRATE_TICK_S := 0.1
const POTATO_PARK_X := 200.0
## addSlicerImage: (0x144EA4) blade drops in from centre.y - 165 (literal
## pool 0x144FB0 = 0xC3250000; the port had -166) over 0.25s, curve 0.
const BLADE_DROP := -165.0
const SLIDE_S := 0.25
## grateTick chip: spawn at slicer.centre, half scale; path x = slicer.frame.x
## + rand % int(88 - sliceW) + sliceW/2, y = slicer.centre.y + rand%20, ending
## at pile.centre.y + 10; 1.0s paced.
const CHIP_SECONDS := 1.0
const CHIP_END_Y_OFF := 10.0
## showScrollView 0x146FAC: buttons initWithFrame:(100*(i%3)+24, 100*row,
## 80, 80) (movt #0x42A0 at 0x1473C2 -- the port had 78); thumbnail at
## (15,15,50,50) (0x41700000/0x42480000); the grid drops from centre y - 500
## (literal 0x14766C = -500.0 -- the port had -2000) over 0.25s curve 2
## (ease-out); hideScrollView reverses it with the same curve.
const GRID_BTN := 80.0
const GRID_X0 := 24.0
const GRID_PITCH := 100.0
const THUMB_RECT := Rect2(15, 15, 50, 50)
const GRID_OFFSCREEN_Y := -500.0
## Nib: aScrollView frame origin (0,55).
const GRID_HOME := Vector2(0, 55)

var _slicer_list: Array = []
var _current := 0                 # currentSlicerIndex
var _slicer: Sprite2D
var _potato: DraggableSprite
var _pile: MaskedIV
var _grating := false
var _grate_time := 0.0
var _scroll_shown := false        # isScrollViewShown
var _done := false                # mirrors "nextButton is not hidden"
var _grate_timer: Timer
var _grid_tween: Tween

## Mystery selection (PORTED):
##   initWithNibName: 0x144280  Consumable DM_CONSUMABLE_MYSTERY_SELECT /
##     MysterySelect_20Slice, cost = CoinCosts."French Fries".MysterySlicer,
##     6 when absent; first-time message.
##   viewDidLoad 0x144484  ConsumableButton(btn_mystery_selection, (0,-25) /
##     (65,3)) at centre (50, 350.5); buyMysterySelectClick:.
##   buyMysterySelectClick: 0x1460B8  "store" sound, purchaseConsumable.
##   consumablePurchased: 0x145AAC  quantity 0; currentSlicerIndex =
##     arc4random() % count (ANY row, the current one included); then the
##     same tail as a grid tap minus the click sound and minus hiding the
##     grid: potatoAnimation (0x146B1C), addSlicerImage: (0x144EA4) with the
##     row's Slicer_Image, changeInstruction:inst_slicepotato, the pile's
##     baseImg = BowlPile_Image and baseOrigPt = (centre - half, 208).
##   consumablePurchaseFailed:error:2 0x145DA8  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const MYSTERY_KEY := "DM_CONSUMABLE_MYSTERY_SELECT"
const MYSTERY_NAME := "MysterySelect_20Slice"
const MYSTERY_COST := 6
const MYSTERY_MESSAGE := "Try out a mystery selection! You never know what selection it could be! Try it for FREE now!"
const MYSTERY_ART := "btn_mystery_selection.png"
const MYSTERY_CENTER := Vector2(50, 350.5)

var _mystery: RefCounted
var _mystery_button: TextureButton


# ======================================================================
# MaskedIV -- shared by the cff bowl screens (this one and cffAddWater).
#
#   initWithBaseImg:andMaskImg: 0x46CE0  view = mask-sized, clear; the mask
#       becomes a CGImageMask (sample 0 = paint, max = paint nothing).
#   drawRect: 0x46E68  CGContextClipToMask(ctx, rect, maskCG) inside
#       UIKit's flipped drawing context, then drawAtPoint:baseOrigPt. The
#       CTM is never flipped back, so the mask lands VERTICALLY MIRRORED --
#       the quirk MaskedSprite2D.mask_flip_v reproduces (ccbSelectChocolate,
#       seen on the phone). Applied here unconditionally, as the binary does.
#   setBaseOrigPt: 0x46EE4 / setBaseImg: 0x46F18.
#
# A local class rather than kcPourOil.MaskedIV: that one has no flip, and
# this screen should not depend on the kc screens' files.
# ======================================================================
class MaskedIV:
	extends Node2D

	var _clip: Sprite2D
	var _base: Sprite2D
	var _mask_size := Vector2.ZERO

	func _init(base_tex: Texture2D, mask_tex: Texture2D) -> void:
		_clip = Sprite2D.new()
		_clip.centered = false
		_clip.texture = _mask_to_alpha(mask_tex)
		_clip.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
		add_child(_clip)
		if mask_tex != null:
			_mask_size = mask_tex.get_size()
		_base = Sprite2D.new()
		_base.centered = false
		_base.texture = base_tex
		_clip.add_child(_base)

	## setCenter: -- a real centre, the view is mask-sized (0x46CE0).
	func set_center(c: Vector2) -> void:
		position = c - _mask_size * 0.5

	func get_center() -> Vector2:
		return position + _mask_size * 0.5

	func mask_size() -> Vector2:
		return _mask_size

	## setBaseOrigPt: (0x46EE4) -- the base art's top-left inside the view.
	func set_base_orig_pt(p: Vector2) -> void:
		_base.position = p

	func get_base_orig_pt() -> Vector2:
		return _base.position

	## setBaseImg: (0x46F18).
	func set_base_texture(t: Texture2D) -> void:
		_base.texture = t

	func base_size() -> Vector2:
		return _base.texture.get_size() if _base.texture != null else Vector2.ZERO

	## The cff masks (cff_PileMask, cff_bowl_Mask) are grey palette PNGs with
	## no usable alpha: black paints. Red inverted into alpha (kc
	## precedent), image flipped top-to-bottom for the drawRect: quirk.
	static func _mask_to_alpha(tex: Texture2D) -> Texture2D:
		if tex == null:
			return null
		var img := tex.get_image()
		if img == null:
			return tex
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		img.flip_y()
		var data := img.get_data()
		for i in range(0, data.size(), 4):
			data[i + 3] = 255 - data[i]
			data[i] = 255
			data[i + 1] = 255
			data[i + 2] = 255
		var out := Image.create_from_data(img.get_width(), img.get_height(),
			false, Image.FORMAT_RGBA8, data)
		return ImageTexture.create_from_image(out)


## random() * 2^-30 - 1 (0x30800000 is 2^-30): uniform over [-1, 1). The
## cff falling-chip and flake code multiplies its arc4random() terms by it.
## The port had randf() - 1.0, i.e. [-1, 0] -- every angle and x offset on
## one side only.
static func rand_signed() -> float:
	return randf_range(-1.0, 1.0)


## A chip's starting angle: (arc4random() % 360) * rand_signed(), RADIANS
## fed straight to CGAffineTransformMakeRotation.
static func rand_chip_angle() -> float:
	return float(randi() % 360) * rand_signed()


## The "RotateKernel" UIView animation sets one CGAffineTransform rotation
## then another inside the block. Core Animation interpolates the layer
## transform by decomposing the two matrices, so the chip turns through the
## SHORTER arc between the two angles (INFERRED: documented CA behaviour --
## a transform animation cannot spin past 180 degrees). Tweening the raw
## radian values instead spun chips up to ~100 turns a second.
static func shortest_target(from: float, to: float) -> float:
	return from + wrapf(to - from, -PI, PI)


## viewDidLoad: the ConsumableButton, and initWithNibName:'s Consumable.
func _build_mystery() -> void:
	_mystery = ConsumableScript.new(MYSTERY_KEY, MYSTERY_NAME, MYSTERY_COST)
	_mystery.set("first_time_message", MYSTERY_MESSAGE)
	_mystery.set("on_purchased", _on_mystery_purchased)
	_mystery.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buyMysterySelect"
	b.call("setup", MYSTERY_ART, 0, -25, MYSTERY_COST, 65, 3)
	b.position = MYSTERY_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyMysterySelectClick)
	add_child(b)                               # addSubview: -- on top
	_mystery_button = b


func _on_buyMysterySelectClick() -> void:
	Audio.play("store")
	_mystery.call("purchase", self)


## consumablePurchased: (0x145AAC).
func _on_mystery_purchased(_free: bool) -> void:
	if _slicer_list.is_empty():
		return
	_current = randi() % _slicer_list.size()
	var row := _row(_current)
	_potato_animation()
	_add_slicer_image(_tex(str(row.get("Slicer_Image", ""))))
	change_instruction("inst_slicepotato.png")
	_pile.set_base_texture(_tex(str(row.get("BowlPile_Image", ""))))
	_set_pile_orig_y(PILE_ORIG_Y)


## UINavigationController keeps this controller alive under the push to
## cffAddWater; Nav calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## initWithNibName: (0x144280) + viewDidLoad (0x144484) once, then
## viewWillAppear: (0x144A44) -> screenSetup.
func on_enter() -> void:
	_slicer_list = _load_table()
	_build_views()
	_build_mystery()
	_build_grid()
	_grate_timer = Timer.new()
	_grate_timer.wait_time = GRATE_TICK_S
	_grate_timer.timeout.connect(_grate_tick)
	add_child(_grate_timer)
	_screen_setup()


## Back from cffAddWater: viewWillAppear: runs screenSetup again, which
## RESETS the step -- blade art cleared, potato parked off-screen, the pile
## emptied back to y 208, next hidden. The player picks a slicer and grates
## again, as on the phone. (currentSlicerIndex and the pile's base image are
## NOT reset by screenSetup; they are overwritten by the next pick.)
func on_resume() -> void:
	_screen_setup()


## screenSetup (0x144B98): flags, badge shown, next hidden, blade art
## cleared, instruction, grate timer, pile origin, potato parked off right,
## then showScrollView + hideScrollView back to back: the first raises the
## grid (and slicerButton) to the front, the second snaps it home and
## animates it up out of view -- on every appearance the grid flies up from
## its home over 0.25s.
func _screen_setup() -> void:
	_grating = false
	_grate_time = 0.0
	_done = false
	if _mystery_button != null:
		_mystery_button.visible = true
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	_slicer.texture = null                     # slicer setImage:nil
	change_instruction("inst_selectslicer.png")
	_grate_timer.start()                       # a new 0.1s NSTimer
	_set_pile_orig_y(PILE_ORIG_Y)
	_potato.position = POTATO_FRAME.get_center() + Vector2(POTATO_PARK_X, 0)
	_show_scroll_view()
	_hide_scroll_view()


## changeInstruction: (0x146DA0) ends with nextButton setHidden:YES.
func instruction_hides_next() -> bool:
	return true


func change_instruction(image_name: String) -> void:
	super.change_instruction(image_name)
	if image_name != "":
		_done = false


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## res:// first, then the extraction tree (the caSelectApple fallback).
## Static so the later cff screens can share it.
static func load_table() -> Array:
	var parsed: Variant = Assets.json(TABLE_JSON)
	if parsed is Array:
		return parsed
	push_warning("cffSelectSlicer: frenchFriesItem table not found")
	return []


## The infoDict a later step should run with: the carried one if the slicer
## step filled it, else table row 0 -- the original's initial
## currentSlicerIndex, so a screen entered standalone shows the R slicer's
## art rather than inventing any.
static func info_or_default(info: Dictionary) -> Dictionary:
	if info.has("Slice_Image"):
		return info
	var table := load_table()
	if not table.is_empty() and table[0] is Dictionary:
		return table[0]
	return {}


func _load_table() -> Array:
	return load_table()


func _row(i: int) -> Dictionary:
	if i >= 0 and i < _slicer_list.size() and _slicer_list[i] is Dictionary:
		return _slicer_list[i]
	return {}


## viewDidLoad (0x144484). The generated potatoSlice is a bare placeholder;
## the DraggableIV is rebuilt in its slot -- the nib's topmost -- with the
## slicer and then the pile inserted below it, so all three sit ABOVE the
## nib's instruction and buttons, as in the original.
func _build_views() -> void:
	_pile = MaskedIV.new(_tex("cff_RSlicer_bowlPile.png"),
		_tex("cff_PileMask.png"))
	_pile.set_center(PILE_CENTER)
	add_child(_pile)

	_slicer = Sprite2D.new()
	_slicer.texture = null                     # initWithFrame:, no image yet
	_slicer.position = SLICER_FRAME.get_center()
	add_child(_slicer)

	_potato = DraggableSprite.new()
	_potato.texture = _tex("cff_Peeled_Potato.png")
	_potato.scale = POTATO_FRAME.size / POTATO_ART
	_potato.position = POTATO_FRAME.get_center()
	_potato.snap_back = true
	_potato.snap_time = POTATO_SNAP
	var placeholder := outlet("potatoSlice")
	add_child(_potato)
	if placeholder != null and placeholder != self:
		(placeholder as Node).queue_free()
	_potato.capture_origin()                   # origCenter = nib centre
	_potato.drag_moved.connect(_on_potato_moved)
	_potato.drag_ended.connect(_on_potato_ended)


## setBaseOrigPt x = pile.frame.width/2 - baseImg.width/2 (0x144C4C); the
## mask window (cff_PileMask, 229x192) and every bowlPile art are 229 wide,
## so x comes out 0 for all five slicers.
func _set_pile_orig_y(y: float) -> void:
	var x := (_pile.mask_size().x - _pile.base_size().x) * 0.5
	_pile.set_base_orig_pt(Vector2(x, y))


## draggableTouchMoved: (0x145828) -- potato frame vs slicer frame. A state
## toggle, not an accumulator, so no move-event gate.
func _on_potato_moved(_center: Vector2) -> void:
	var frame := Rect2(_potato.position - POTATO_FRAME.size * 0.5,
		POTATO_FRAME.size)
	if frame.intersects(SLICER_FRAME):
		if not _grating:
			Audio.loop("grating")
		_grating = true
	else:
		if _grating:
			Audio.stop("grating")
		_grating = false


## draggableTouchEnded: (0x1459AC): grating off, sound off; the slicer's own
## re-centre there is a no-op (it never moved). DraggableSprite2D snaps the
## potato home (snapTime 0.25).
func _on_potato_ended(_pos: Vector2, _hit: bool) -> void:
	_grating = false
	Audio.stop("grating")


## grateTick (0x144FB4): one falling chip per 0.1s while grating and next
## is hidden.
func _grate_tick() -> void:
	if not _grating or _done:
		return
	var row := _row(_current)
	var t := _tex(str(row.get("Slice_Image", "")))
	if t == null:
		return
	var chip := Sprite2D.new()
	chip.texture = t
	chip.scale = Vector2(0.5, 0.5)
	chip.rotation = rand_chip_angle()
	add_child(chip)
	move_child(chip, _pile.get_index())        # insertSubview:belowSubview:pile
	var sw := float(t.get_size().x)
	var span := maxi(int(SLICER_FRAME.size.x - sw), 1)
	# The paced keyframe path (fillMode forwards) owns the position from
	# t = 0, so the chip appears at the path's start.
	var start := Vector2(
		SLICER_FRAME.position.x + float(randi() % span) + sw * 0.5,
		_slicer.position.y + float(randi() % 20))
	chip.position = start
	var end_y := PILE_CENTER.y + CHIP_END_Y_OFF
	var tw := create_tween().set_parallel(true)
	tw.tween_property(chip, "position:y", end_y, CHIP_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)          # kCAAnimationPaced
	# "RotateKernel" (curve 1 = ease-in) to a second random angle.
	tw.tween_property(chip, "rotation",
		shortest_target(chip.rotation, rand_chip_angle()), CHIP_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(_chip_landed.bind(chip))


## animationDidStop "RotateKernel" (0x1455CC): remove; count the landing only
## while still grating and next hidden.
func _chip_landed(chip: Sprite2D) -> void:
	if is_instance_valid(chip):
		chip.queue_free()
	if _done or not _grating:
		return
	_grate_time += GRATE_TIME_STEP
	var p := _pile.get_base_orig_pt()
	p.y -= _pile.base_size().y * PILE_RISE_FRACTION   # 192/30 = 6.4
	_pile.set_base_orig_pt(p)
	if p.y < PILE_DONE_Y:
		_done = true
		Audio.stop("grating")
		show_next_button()


# -- the picker (selectSlicer: / show/hideScrollView) -------------------

## selectSlicer: (0x145E7C) -- the slicerButton toggles the grid.
func _on_selectSlicer() -> void:
	Audio.play("button_press")
	_show_scroll_view()


## setAlpha: on next/back/badge. UIKit's hit-testing skips views whose
## alpha is below 0.01, so at 0 they stop taking touches too; a Godot
## Control at modulate 0 would still be clickable.
func _set_chrome_alpha(a: float) -> void:
	for b: Variant in [outlet("nextButton"), outlet("backButton"),
			_mystery_button]:
		if b == null or b == self or not (b is CanvasItem):
			continue
		(b as CanvasItem).modulate.a = a
		if b is Control:
			(b as Control).mouse_filter = Control.MOUSE_FILTER_STOP \
				if a >= 0.01 else Control.MOUSE_FILTER_IGNORE


func _show_scroll_view() -> void:
	var sv := outlet("aScrollView") as Node2D
	var btn := outlet("slicerButton")
	# bringSubviewToFront: aScrollView, then slicerButton -- every call.
	if sv != null:
		move_child(sv, -1)
	if btn != null and btn != self:
		move_child(btn, -1)
	if _scroll_shown:
		_hide_scroll_view()
		return
	_set_chrome_alpha(0.0)
	if sv == null:
		return
	sv.visible = true
	sv.position = GRID_HOME + Vector2(0, GRID_OFFSCREEN_Y)
	_tween_grid(sv, GRID_HOME)
	_scroll_shown = true


func _hide_scroll_view() -> void:
	if not _scroll_shown:
		return
	_set_chrome_alpha(1.0)
	var sv := outlet("aScrollView") as Node2D
	if sv != null:
		sv.position = GRID_HOME                # setCenter: outside the block
		_tween_grid(sv, GRID_HOME + Vector2(0, GRID_OFFSCREEN_Y))
	_scroll_shown = false


## UIViewAnimationCurve 2 = ease-OUT, 0.25s, both directions. A new block
## on the same property replaces the in-flight one.
func _tween_grid(sv: Node2D, to: Vector2) -> void:
	if _grid_tween != null and _grid_tween.is_valid():
		_grid_tween.kill()
	_grid_tween = create_tween()
	_grid_tween.tween_property(sv, "position", to, SLIDE_S) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## showScrollView's button loop (0x146FAC): 80x80 buttons, three per row.
## The button art goes in with setImage:forState: -- a FOREGROUND image, so
## the 91x90 Sub_Button_Background is shrunk to fit and centred (the
## generator's oversized-foreground rule, INFERRED UIKit behaviour); the
## thumbnail is a plain scale-to-fill UIImageView subview at (15,15,50,50).
## The original rebuilds the buttons on every show; built once here.
func _build_grid() -> void:
	var sv := outlet("aScrollView") as Node2D
	if sv == null:
		return
	for c in sv.get_children():
		(c as Node).queue_free()
	var bg := _tex("Sub_Button_Background.png")
	for i in _slicer_list.size():
		var b := TextureButton.new()
		b.texture_normal = bg
		b.ignore_texture_size = true
		b.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		b.position = Vector2(GRID_PITCH * (i % 3) + GRID_X0,
			GRID_PITCH * floorf(i / 3.0))
		b.size = Vector2(GRID_BTN, GRID_BTN)
		var thumb := TextureRect.new()
		thumb.texture = _tex(str(_row(i).get("Slicer_Thumb_Image", "")))
		thumb.position = THUMB_RECT.position
		thumb.size = THUMB_RECT.size
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_SCALE
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(thumb)
		b.pressed.connect(_on_selectedSlicerClick.bind(i))
		sv.add_child(b)
	sv.position = GRID_HOME + Vector2(0, GRID_OFFSCREEN_Y)
	_scroll_shown = false


## selectedSlicerClick: (0x146124).
## hideScrollView (0x147670) moves the grid's centre 500 up inside a
## +beginAnimations: block, so the MODEL is off screen at once and UIKit's
## hit test (model geometry) finds no button there for the 0.25 s the grid
## is still drawn sliding away. The port's TextureButtons answer where they
## are drawn; a tap on one during the slide-out used to pick a second
## slicer. Only the grid buttons call this.
## (The slide-in is the mirror case: the phone takes taps at the cells'
## final places at once, the port where they are drawn -- 0.25 s, not
## reproduced.)
func _on_selectedSlicerClick(tag: int) -> void:
	if not _scroll_shown:
		return
	Audio.play("button_press")
	_potato_animation()
	_hide_scroll_view()
	_current = tag
	var row := _row(tag)
	_add_slicer_image(_tex(str(row.get("Slicer_Image", ""))))
	change_instruction("inst_slicepotato.png")
	_pile.set_base_texture(_tex(str(row.get("BowlPile_Image", ""))))
	_set_pile_orig_y(PILE_ORIG_Y)


## addSlicerImage: (0x144EA4): grateTime reset, blade drops in from -165
## ("MoveBlade", 0.25s, curve 0 = ease-in-out).
func _add_slicer_image(t: Texture2D) -> void:
	_grate_time = 0.0
	_slicer.texture = t
	var home := SLICER_FRAME.get_center()
	_slicer.position = home + Vector2(0, BLADE_DROP)
	create_tween().tween_property(_slicer, "position", home, SLIDE_S) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## potatoAnimation (0x146B1C): park at +200 then slide home over 0.25s.
## The slide ("MoveBlade") is +beginAnimations:/commitAnimations and leaves
## the potato DraggableIV touchable -- at its model centre (home) -- so it
## goes through animate_position(): a potato caught on the way is the
## drag's, not pulled home under the finger while it grates.
func _potato_animation() -> void:
	var home := POTATO_FRAME.get_center()
	_potato.cancel_position_animation()
	_potato.position = home + Vector2(POTATO_PARK_X, 0)
	_potato.animate_position(create_tween(), home, SLIDE_S) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## nextClick: (0x145F6C): button_press, hand the chosen row + the pile's
## baseOrigPt to cffAddWater (initWithInfoDict: / setPotatoBaseOrig:).
func _on_nextClick() -> void:
	Audio.play("button_press")
	var info: Dictionary = _row(_current).duplicate()
	var p := _pile.get_base_orig_pt()
	info["PotatoBaseOrigX"] = p.x
	info["PotatoBaseOrigY"] = p.y
	GameState.custom_categories = info
	Nav.next()


## backClick: (0x145ED8): button_press, grate timer off, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	if _grate_timer != null:
		_grate_timer.stop()
	Nav.back()


## viewWillDisappear: (0x144B0C): sound off, grate timer invalidated -- and
## nothing else; the grated pile stays until screenSetup resets it.
func on_exit() -> void:
	Audio.stop("grating")
	if _grate_timer != null:
		_grate_timer.stop()
