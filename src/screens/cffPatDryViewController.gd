# Curly Fries step 4 -- pat the washed slices dry with the tissue paper.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithInfoDict: 0x140374, viewDidLoad 0x1403A8, viewWillAppear:
#   0x1405AC, draggableTouchMoved: 0x140820, draggableTouchEnded: 0x140B74,
#   changeInstruction: 0x140BB4 / showNextButton 0x140EDC (standard
#   +500/0.25s slide), nextBtnClicked: 0x140E14, backBtnClicked: 0x140DA4.
#
# Mechanic, as read -- a MOVE-EVENT accumulator with NO position gate (unlike
# cdStir's y >= 180): while the tissue's frame merely INTERSECTS the
# waterDrops frame (both straight CGRects), every draggableTouchMoved: event
# subtracts 0.004 (0xBB83126F) from waterDrops.alpha and adds 0.004
# (0x3B83126F) to the dirty-tissue overlay's alpha -- 250 events start to
# finish. "cff_pat_dry" loops while drying; alpha <= 0 stops it, clears
# isWaterDrop and slides next in. Moving OFF the drops stops the sound but
# keeps the progress. The tissue is a DraggableIV with snapTime 0.25
# (0x1403C4), so it snaps home on release; touchesEnded only stops the sound.
#
# MOVE EVENTS: the 250 steps are per draggableTouchMoved:, and
# iOS delivered at most one move per 60 Hz frame; Godot delivers one per PC
# frame. The handler is gated on Screen.accept_touch_move(), so a full dry
# takes >= 4.2 s of continuous scrubbing, as on the phone (it took 1-2 s on
# a 144-240 Hz monitor before).
#
# The dirty overlay (viewDidLoad 0x1403F8) is cff_dirty_tissue_paper.png as
# a subview of the tissue at (0,0), tag 100, alpha 0 -- reset to 0 on every
# appearance (0x14064C loop). potatoSlice gets infoDict["RawPile_Image"]
# (250x250, exactly its (40,160,250,250) nib frame).
#
# KEEP-STATE: kept alive under the push to cffFrySlice.
# The tissue and its overlay are built once (viewDidLoad); viewWillAppear:'s
# reset runs on entry and in on_resume. The class has no viewWillDisappear:.

extends "res://core/Screen.gd"

const DraggableSprite := preload("res://core/DraggableSprite2D.gd")
const cffSelectSlicer := preload("res://screens/cffSelectSlicer.gd")

## Nib: waterDrops UIImageView (40,160,250,250) -- the intersect target.
const DROPS_RECT := Rect2(40, 160, 250, 250)
## Nib: tissuePaper DraggableIV (196,30,104,150); cff_tissue_paper.png is
## exactly 104x150, so it renders at natural size. Centre (248,105).
const TISSUE_RECT := Rect2(196, 30, 104, 150)
## setSnapTime: 0x3E800000 (0x1403C4).
const TISSUE_SNAP := 0.25
## draggableTouchMoved: +-0.004 per event (0x3B83126F / 0xBB83126F).
const DRY_STEP := 0.004

var _tissue: DraggableSprite
var _dirty: Sprite2D
var _water_alpha := 1.0
var _is_water := true            # isWaterDrop
var _info: Dictionary = {}


## UINavigationController keeps this controller alive under the push to
## cffFrySlice; Nav calls on_resume() on back.
func keeps_state_on_push() -> bool:
	return true


## initWithInfoDict: (0x140374) + viewDidLoad (0x1403A8) once, then
## viewWillAppear: (0x1405AC).
func on_enter() -> void:
	_info = cffSelectSlicer.info_or_default(GameState.custom_categories)
	_build_tissue()
	_will_appear()


## Back from cffFrySlice: viewWillAppear: runs again and RESETS the step --
## waterDrops back to alpha 1, the dirty overlay to 0, isWaterDrop YES, next
## hidden. The slices are patted dry again, as on the phone.
func on_resume() -> void:
	_will_appear()


## viewWillAppear: (0x1405AC).
func _will_appear() -> void:
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	var drops := outlet("waterDrops")
	if drops != null and drops != self:
		(drops as CanvasItem).modulate.a = 1.0
	_water_alpha = 1.0
	_is_water = true
	_dirty.modulate.a = 0.0                    # the tag-100 subview loop
	# potatoSlice.image = infoDict["RawPile_Image"].
	var slice := outlet("potatoSlice")
	if slice is Sprite2D:
		var sp := slice as Sprite2D
		sp.texture = _tex(str(_info.get("RawPile_Image", "")))
		sp.centered = false                    # nib frame (40,160,250,250)
	change_instruction("inst_dragpaper.png")


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _build_tissue() -> void:
	_tissue = DraggableSprite.new()
	_tissue.texture = _tex("cff_tissue_paper.png")
	_tissue.position = TISSUE_RECT.get_center()
	_tissue.snap_back = true
	_tissue.snap_time = TISSUE_SNAP
	var placeholder := outlet("tissuePaper")
	add_child(_tissue)
	if placeholder != null and placeholder != self:
		move_child(_tissue, (placeholder as Node).get_index())
		(placeholder as Node).queue_free()
	_tissue.capture_origin()                   # origCenter = nib centre
	_tissue.drag_moved.connect(_on_tissue_moved)
	_tissue.drag_ended.connect(_on_tissue_ended)

	# viewDidLoad: the tag-100 dirty overlay at the tissue's (0,0), alpha 0.
	_dirty = Sprite2D.new()
	_dirty.texture = _tex("cff_dirty_tissue_paper.png")
	_dirty.modulate.a = 0.0
	_tissue.add_child(_dirty)                  # same centre, same size


## draggableTouchMoved: (0x140820) -- one per iOS move event, hence the
## 60 Hz gate (header).
func _on_tissue_moved(_center: Vector2) -> void:
	if not accept_touch_move():
		return
	var frame := Rect2(_tissue.position - TISSUE_RECT.size * 0.5,
		TISSUE_RECT.size)
	if frame.intersects(DROPS_RECT) and _is_water:
		_water_alpha -= DRY_STEP
		var drops := outlet("waterDrops")
		if drops != null and drops != self:
			# CALayer clamps stored opacity to [0,1]; mirror that.
			(drops as CanvasItem).modulate.a = clampf(_water_alpha, 0.0, 1.0)
		_dirty.modulate.a = clampf(_dirty.modulate.a + DRY_STEP, 0.0, 1.0)
		if _water_alpha <= 0.0:
			_is_water = false
			Audio.stop("cff_pat_dry")
			show_next_button()
		else:
			Audio.loop("cff_pat_dry")
	else:
		Audio.stop("cff_pat_dry")


## draggableTouchEnded: (0x140B74): sound off; DraggableSprite2D snaps home.
func _on_tissue_ended(_pos: Vector2, _hit: bool) -> void:
	Audio.stop("cff_pat_dry")


## nextBtnClicked: (0x140E14): button_press, push a NEW cffFrySlice
## initWithInfoDict: with this controller's infoDict (re-published: a later
## screen's bake may have replaced GameState.custom_categories meanwhile).
func _on_nextBtnClicked() -> void:
	Audio.play("button_press")
	GameState.custom_categories = _info.duplicate()
	Nav.next()


## backBtnClicked: (0x140DA4) -- named off Screen.gd's fallback map, so it
## needs an explicit override.
func _on_backBtnClicked() -> void:
	Audio.play("button_press")
	Nav.back()


## No viewWillDisappear: / viewDidDisappear: in this class. The PC's single
## pointer cannot press next or back while dragging the tissue, and the
## release already stopped cff_pat_dry, so this stop is a no-op kept only as
## a guard. PORT CHOICE.
func on_exit() -> void:
	Audio.stop("cff_pat_dry")
