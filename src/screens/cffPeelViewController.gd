# Curly Fries step 1 -- scrub the skin off the potato with the peeler.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithNibName: 0x138000 (bare super), viewDidLoad 0x138030,
#   viewWillAppear: 0x138418, viewDidAppear: 0x1387C0 (re-centres peelPotato
#   on originalPotato -- a no-op, both share the nib frame),
#   viewWillDisappear: 0x138844, grateTick 0x1388F0, countTick 0x138EF8,
#   drag: 0x1392E0, draggableTouchMoved: 0x139464, draggableTouchEnded:
#   0x139964, animationDidStop: 0x138EA4, changeInstruction: 0x139A64 and
#   showNextButton 0x139148 (both the standard +500/0.25s slide),
#   nextClick: 0x139D28.
#
# Mechanic, as read -- a SCRATCH-OFF, not a swipe accumulator: the peeler is
# a DraggableIV (snapTime 0.25, 0x138098). Every draggableTouchMoved: stamps
# brushFile ("cff_white_rect1.png", set 0x13804E -- a uniform OPAQUE WHITE
# 20x20 rect, channel-checked) into a CGImageMask over the potato at
# peeler.center + (-10, -50), and re-composites originalPotato's image as
# the skin art clipped to the unbrushed mask. The (H - y) pre-flip in the
# stamp cancels CGContextClipToMask's UIKit flip exactly, so the erase lands
# at the touch point; with an all-white opaque brush the stamp is a hard
# 20x20 erase, which is what the port performs directly on the skin image.
#
# countTick (0.6s, bits 0x3FE33333/0x40000000): counts pixels of the
# composited image with alpha/255 < 0.75 over the FIRST w*h - 1 pixels
# (original off-by-one, kept); ratio > 0.998 stops both timers, hides
# originalPotato and shows next. The port tracks the count incrementally
# (the 0.6s cadence only decides WHEN the finish test runs).
#
# grateTick (0.5s): while the peeler overlaps the potato and next is hidden,
# a cff_potatoCover.png flake spawns at the potato centre -- setCenter: then
# setFrame: keeping the ORIGIN and halving the size (0x1389C0 block) -- then
# a 1.0s paced path drops it 200px (0x43480000) from beside the blade while a
# second random rotation animates ("RotateKernel", curve 1); its completion
# removes it (0x138EA4). The keyframe path (fillMode forwards) owns the
# position from t = 0, so the flake appears at the path start and the
# setFrame: quirk never shows; the port spawns it there. Random terms are
# (arc4random() % n) * (random() * 2^-30 - 1), i.e. signed -- the port used
# to draw them from [-1, 0] only -- and the rotation animates through the
# shorter arc (see cffSelectSlicer.shortest_target).
#
# MOVE EVENTS: every draggableTouchMoved: stamps one brush, and
# iOS delivered at most one move per 60 Hz frame, so a fast stroke on the
# phone leaves gaps between 20px stamps that a 144 Hz PC stroke would fill.
# The stamp path is gated on Screen.accept_touch_move() (the banana-peel
# fix); this screen is a scratch-off, not the banana's swipe accumulator.
#
# Z-order: viewWillAppear: brings the peeler to the front -- above the
# instruction and buttons -- and flakes are inserted just below it.
#
# The peeler's transform is CGAffineTransformMakeRotation(270.0) (0x138112,
# movt r1,#0x4387 in the disassembly): 270 *radians*, degrees fed to a
# radians API. Effective angle 270 mod 2pi ~ -10.15 deg. Ported verbatim.
#
# PORT NOTE: draggableTouchEnded: (0x139964) animates the peeler home with
# curve 0 (ease-in-out) while DraggableIV's own snapTime-0.25 snap (linear)
# also runs; both end at origCenter. The port keeps the DraggableSprite2D
# linear snap only.
#
# KEEP-STATE: the controller survives the push to
# cffSelectSlicer (keeps_state_on_push). viewDidLoad's work (peeler, brush,
# timer objects) runs once in on_enter; viewWillAppear:'s (skin, next,
# instruction, timers) runs on entry AND in on_resume -- which restarts the
# peel from an unpeeled potato on every return, as the original does.
# on_exit = viewWillDisappear: only (sound off, timers invalidated).

extends "res://core/Screen.gd"

const DraggableSprite := preload("res://core/DraggableSprite2D.gd")
const cffSelectSlicer := preload("res://screens/cffSelectSlicer.gd")

## Nib: originalPotato / peelPotato UIImageView frames (93,50,140,252);
## cff_potato_original.png is exactly 140x252 (1x).
const POTATO_RECT := Rect2(93, 50, 140, 252)
## Nib: peeler DraggableIV frame (232,77,68,97) -- explicit frame, true
## geometry; cff_Potato_Peeler.png (180x238) scale-to-fills it.
const PEELER_RECT := Rect2(232, 77, 68, 97)
const PEELER_ART := Vector2(180, 238)
## viewDidLoad 0x138094: setSnapTime: 0x3E800000.
const PEELER_SNAP := 0.25
## viewDidLoad 0x138112: rotation 270.0 (0x43870000) RADIANS -- see header.
const PEELER_ROTATION := 270.0
## draggableTouchMoved: brush point = sender.center + (-10, -50)
## (0xC2480000 for the y; 0x139464).
const BRUSH_OFFSET := Vector2(-10, -50)
## brushFile (0x13804E); 20x20, uniform opaque white.
const BRUSH_FILE := "cff_white_rect1.png"
## countTick (0x138EF8): alpha/255 < 0.75 counts as peeled; done past 0.998
## of (w*h - 1) pixels.
const PEEL_ALPHA := 0.75
const DONE_RATIO := 0.998
## Timers (viewWillAppear: 0x138418): countTick 0.6s, grateTick 0.5s.
const COUNT_TICK_S := 0.6
const GRATE_TICK_S := 0.5
## grateTick flake: fall +200 (0x43480000) over 1.0s; x offset
## (rand%20) * signed, y start = peeler.center.y - frame.h/2 + rand%60.
const FLAKE_FALL := 200.0
const FLAKE_SECONDS := 1.0

var _peeler: DraggableSprite
var _skin: Image                 # originalPotato's composited image
var _skin_tex: ImageTexture
var _brush: Image
var _grating := false            # isGrating
var _peeled := 0                 # pixels with alpha < 0.75 (first w*h-1)
var _total := 0                  # w*h - 1, the original's loop count
var _done := false
var _count_timer: Timer
var _grate_timer: Timer


## UINavigationController keeps this controller alive under a push:
## Nav parks the instance and calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## viewDidLoad (0x138030) builds the peeler once; viewWillAppear: (0x138418)
## runs on every appearance -- see _will_appear().
func on_enter() -> void:
	_load_brush()
	_build_peeler()
	_count_timer = Timer.new()
	_count_timer.wait_time = COUNT_TICK_S   # 0x3FE3333340000000 = 0.6
	_count_timer.timeout.connect(_count_tick)
	add_child(_count_timer)
	_grate_timer = Timer.new()
	_grate_timer.wait_time = GRATE_TICK_S
	_grate_timer.timeout.connect(_grate_tick)
	add_child(_grate_timer)
	_will_appear()


## Back from cffSelectSlicer: viewWillAppear: runs again and RESTARTS the
## peel -- originalPotato gets cff_potato_original.png back and is unhidden,
## the potatoMask is a fresh black image, next is hidden and both timers are
## rescheduled. The step is peeled from scratch on every return, as shipped.
func on_resume() -> void:
	_will_appear()


## viewWillAppear: (0x138418): next hidden, isGrating NO, the instruction,
## the unpeeled skin, the peeler to the front, countTick 0.6s / grateTick
## 0.5s. (viewDidAppear: 0x1387C0 only re-centres peelPotato -- a no-op.)
func _will_appear() -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	_grating = false
	_done = false
	change_instruction("inst_peelpotato.png")
	_build_skin()
	var orig := outlet("originalPotato")
	if orig != null and orig != self:
		(orig as CanvasItem).visible = true          # setHidden:NO
	move_child(_peeler, -1)                           # bringSubviewToFront:
	_count_timer.start()
	_grate_timer.start()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## viewDidLoad (0x13804E): brushFile.
func _load_brush() -> void:
	var bt := _tex(BRUSH_FILE)
	_brush = bt.get_image() if bt != null else null
	if _brush != null and _brush.is_compressed():
		_brush.decompress()
	if _brush != null:
		_brush.convert(Image.FORMAT_RGBA8)


## viewWillAppear: originalPotato gets cff_potato_original.png; the port
## copies it into a mutable Image so stamps can erase alpha in place.
func _build_skin() -> void:
	var t := _tex("cff_potato_original.png")
	if t == null:
		return
	_skin = t.get_image()
	if _skin.is_compressed():
		_skin.decompress()
	_skin.convert(Image.FORMAT_RGBA8)
	_skin_tex = ImageTexture.create_from_image(_skin)
	var node := outlet("originalPotato")
	if node is Sprite2D:
		(node as Sprite2D).texture = _skin_tex

	# countTick's census: alpha/255 < 0.75 over the first w*h - 1 pixels.
	var w := _skin.get_width()
	var h := _skin.get_height()
	_total = w * h - 1
	_peeled = 0
	var data := _skin.get_data()
	for i in _total:
		if float(data[i * 4 + 3]) / 255.0 < PEEL_ALPHA:
			_peeled += 1


## The nib peeler is an empty placeholder Node2D in the generated scene; the
## real DraggableIV is rebuilt here, on top: viewWillAppear: (0x138418)
## bringSubviewToFront:peeler.
func _build_peeler() -> void:
	_peeler = DraggableSprite.new()
	_peeler.texture = _tex("cff_Potato_Peeler.png")
	_peeler.scale = PEELER_RECT.size / PEELER_ART
	_peeler.position = PEELER_RECT.get_center()      # (266, 125.5)
	_peeler.rotation = PEELER_ROTATION
	_peeler.snap_back = true
	_peeler.snap_time = PEELER_SNAP
	var placeholder := outlet("peeler")
	if placeholder != null and placeholder != self:
		(placeholder as Node).queue_free()
	add_child(_peeler)
	_peeler.capture_origin()                          # origCenter (0x1380B2)
	_peeler.drag_moved.connect(_on_peeler_moved)
	_peeler.drag_ended.connect(_on_peeler_ended)


## The peeler's axis-aligned frame, as UIKit computes it for the rotated,
## scaled view -- what drag: (0x1392E0) intersects with the potato.
func _peeler_frame() -> Rect2:
	var sz := PEELER_RECT.size
	var c := absf(cos(_peeler.rotation))
	var s := absf(sin(_peeler.rotation))
	var aabb := Vector2(c * sz.x + s * sz.y, s * sz.x + c * sz.y)
	return Rect2(_peeler.position - aabb * 0.5, aabb)


## drag: (0x1392E0) -- frame intersection gates the loop sound and isGrating.
func _drag_check() -> void:
	if _peeler_frame().intersects(POTATO_RECT):
		if not _grating:
			Audio.loop("cff_Potato_Peel")
		_grating = true
	else:
		if _grating:
			Audio.stop("cff_Potato_Peel")
		_grating = false


## draggableTouchMoved: (0x139464) -- one per iOS move event, hence the
## 60 Hz gate (header).
func _on_peeler_moved(center: Vector2) -> void:
	if not accept_touch_move():
		return
	_drag_check()
	var p := center + BRUSH_OFFSET
	if POTATO_RECT.has_point(p):
		_stamp(p - POTATO_RECT.position)


## One brush stamp: the 20x20 opaque-white rect becomes a hard erase of the
## skin's alpha, centred on the local point (flips cancel; see header).
func _stamp(local: Vector2) -> void:
	if _skin == null or _brush == null or _done:
		return
	var bw := _brush.get_width()
	var bh := _brush.get_height()
	var x0 := int(local.x - bw * 0.5)
	var y0 := int(local.y - bh * 0.5)
	var w := _skin.get_width()
	var h := _skin.get_height()
	var changed := false
	for by in bh:
		var y := y0 + by
		if y < 0 or y >= h:
			continue
		for bx in bw:
			var x := x0 + bx
			if x < 0 or x >= w:
				continue
			if _brush.get_pixel(bx, by).a <= 0.0:
				continue
			var c := _skin.get_pixel(x, y)
			if c.a <= 0.0:
				continue
			if c.a >= PEEL_ALPHA and (y * w + x) < _total:
				_peeled += 1
			c.a = 0.0
			_skin.set_pixel(x, y, c)
			changed = true
	if changed:
		_skin_tex.update(_skin)


## draggableTouchEnded: (0x139964): sound off; DraggableSprite2D snaps home.
func _on_peeler_ended(_pos: Vector2, _hit: bool) -> void:
	_grating = false
	Audio.stop("cff_Potato_Peel")


## countTick (0x138EF8) -- the finish test, on its original 0.6s cadence.
func _count_tick() -> void:
	if _done or _total <= 0:
		return
	if float(_peeled) / float(_total) > DONE_RATIO:
		_done = true
		_count_timer.stop()
		_grate_timer.stop()
		Audio.stop("cff_Potato_Peel")
		var node := outlet("originalPotato")
		if node != null and node != self:
			(node as CanvasItem).visible = false      # setHidden:1
		show_next_button()


## grateTick (0x1388F0) -- a skin flake falls beside the blade.
func _grate_tick() -> void:
	if not _grating or _done:
		return
	var t := _tex("cff_potatoCover.png")
	if t == null:
		return
	var flake := Sprite2D.new()
	flake.texture = t
	# setCenter: potato centre, then setFrame: keeps the ORIGIN and halves
	# the size -- centre shifts by a quarter of the art (original quirk).
	var art := Vector2(t.get_size())
	flake.scale = Vector2(0.5, 0.5)
	flake.position = POTATO_RECT.get_center() - art * 0.5 + art * 0.25
	flake.rotation = cffSelectSlicer.rand_chip_angle()
	add_child(flake)
	move_child(flake, _peeler.get_index())            # below the peeler

	# The CAKeyframe path snaps the layer to its start point immediately.
	var start := Vector2(
		_peeler.position.x + float(randi() % 20) * cffSelectSlicer.rand_signed(),
		_peeler.position.y - _peeler_frame().size.y * 0.5
			+ float(randi() % 60))
	flake.position = start
	var tw := create_tween().set_parallel(true)
	tw.tween_property(flake, "position:y", start.y + FLAKE_FALL,
		FLAKE_SECONDS).set_trans(Tween.TRANS_LINEAR)   # kCAAnimationPaced
	# "RotateKernel" curve 1 (ease-in) to a second random angle, shorter arc.
	tw.tween_property(flake, "rotation",
		cffSelectSlicer.shortest_target(flake.rotation,
			cffSelectSlicer.rand_chip_angle()), FLAKE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(flake):
			flake.queue_free())


## nextClick: (0x139D28): button_press, push cffSelectSlicer.
func _on_nextClick() -> void:
	Audio.play("button_press")
	Nav.next()


## backClick: (0x139C70): button_press, both timers invalidated, pop.
func _on_backClick() -> void:
	Audio.play("button_press")
	if _count_timer != null:
		_count_timer.stop()
	if _grate_timer != null:
		_grate_timer.stop()
	Nav.back()


## changeInstruction: (0x139A64) ends with nextButton setHidden:YES.
func instruction_hides_next() -> bool:
	return true


## viewWillDisappear: (0x138844): sound off, both timers invalidated. Nothing
## else -- the peeled state stays until viewWillAppear: resets it.
func on_exit() -> void:
	Audio.stop("cff_Potato_Peel")
	if _count_timer != null:
		_count_timer.stop()
	if _grate_timer != null:
		_grate_timer.stop()
