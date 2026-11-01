# Candy Apple step 1 -- pick an apple from the horizontal strip.
#
# From the original binary (IMPs from the ObjC method list):
#   initWithNibName: 0x14C1DC, viewDidLoad 0x14C20C, viewWillAppear: 0x14C608,
#   viewDidAppear: 0x14C6D0, viewWillDisappear: 0x14C7F0, screenSetup 0x14C864,
#   initFlavors 0x14C9C4, appleClicked: 0x14CF9C, nextClick: 0x14D1A8,
#   showNextButton 0x14D28C, changeInstruction: 0x14D3F0.
#
# Mechanic, as read: six molds from the bundled CandyApples.plist
# (CandyApples.json once imported) become 82x164 buttons on a 100pt pitch in
# the nib's aScrollView (frame (0,0,320,150)). viewDidAppear drops the strip
# from centre (160,-250) to (160,100) over 0.5s and initFlavors scrolls the
# content from offset 640 to 0 over 2.0s. Tapping a thumbnail merges that
# mold's dict into infoDict and paints appleImage (a code-built UIImageView,
# frame (25,175,269,258), transform scale 0.6 -- true centre (159.5,304)).
# initFlavors auto-selects index 1 while building (0x14CF7A: `if (i == 1)
# appleClicked:`), so the next button slides in as soon as viewDidAppear: runs.
#
# flavorClicked: (0x14D134) is a `bx lr` stub -- dead, not ported.
#
# SCROLLING: the strip is a real UIScrollView (kcScrollView.gd over
# core/UIScrollSim.gd): 10 pt drag hysteresis, release velocity,
# deceleration 0.998, rubber band and bounce at both ends; nothing sets
# decelerationRate, bounces or paging, and viewDidAppear: turns both
# indicators off. contentSize is (700, 150) -- the strip's own height, so it
# only scrolls sideways. The 640 -> 0 entrance is setContentOffset: inside a
# 2.0 s +beginAnimations: block: the model offset is 0 at once (taps hit the
# buttons where they end up), only the drawing glides, on the UIView
# default curve (EaseInOut bezier, no longer a sine stand-in). The
# viewDidAppear: work now runs in on_did_appear() -- after the push / pop
# slide, as on the phone; the strip stays hidden until then (its buttons do
# not exist before initFlavors on the first appearance, and
# viewWillDisappear: hid it before a return).
#
# Not ported (everything-unlocked policy): contentLocked, the
# round_black_lock.png overlays on molds 2..5 (initFlavors 0x14CB6E, frame
# (7,5,43,45) tag 1000), lockedFlavorButtonClicked: 0x14D5E0, the IAP alert
# 0x14D670 and BuyAllClick:/productPurchased: 0x14D75C/0x14D894.

extends "res://core/Screen.gd"

const UIScrollSim := preload("res://core/UIScrollSim.gd")
const ScrollView := preload("res://screens/kcScrollView.gd")

## Bundled table CandyApples.plist, converted to CandyApples.json on import.
## Keys per mold: Image, Image_fg, Image_bg, Thumbnail.
## The import cache's data/CandyApples.json (Assets).
const MOLDS_JSON := "CandyApples"

## appleImage: UIImageView frame (25,175,269,258) (0x41C80000/0x432F0000/
## 0x43868000/0x43810000, viewDidLoad), CGAffineTransformMakeScale(0.6,0.6)
## -- a transform scales about the view centre, so the art stays centred at
## (159.5, 304).
const APPLE_CENTER := Vector2(159.5, 304.0)
const APPLE_SCALE := 0.6

## initFlavors button loop: frame (40 + 100*i, 50, 82, 164) inside
## aScrollView (x from `v21-160`, v21 = 200 + 100*i; 0x42480000 = 50,
## 0x42A40000 = 82, 0x43248000 = 164). Thumbnail UIImageView initWithImage:
## sits at the button's (0,0) at natural size (54x52).
const BTN_X0 := 40.0
const BTN_PITCH := 100.0
const BTN_SIZE := Vector2(82, 164)
const MOLD_COUNT := 6

## Strip: nib frame (0,0,320,150); viewDidAppear parks centre at (160,-250)
## (0xC37A0000) and animates to (160,100) (0x42C80000) over 0.5s. Final
## frame is therefore (0,25,320,150) -- the MODEL frame, which takes the
## touches from the moment the drop starts.
const STRIP_SIZE := Vector2(320, 150)
const STRIP_HIDDEN_Y := -325.0        # centre -250 - 75
const STRIP_FINAL_Y := 25.0           # centre  100 - 75
const STRIP_DROP_SECONDS := 0.5
const STRIP_FRAME := Rect2(0, STRIP_FINAL_Y, 320, 150)
## initFlavors: contentSize (700,150) (the running setContentSize:(v,150),
## 0x43160000, last v = 700), contentOffset jumps to (640,0) (0x44200000)
## then animates to (0,0) over 2.0s ("Animate_To_First_Item").
const CONTENT_W := 700.0
const OFFSET_START := 640.0
const OFFSET_SECONDS := 2.0

## screenSetup (0x14C864): back disabled, re-enabled 0.5s later.
const BACK_LOCKOUT_S := 0.5

var _molds: Array = []
var _info: Dictionary = {}            # infoDict, merged by appleClicked:
var _apple_image: Sprite2D
var _strip: Control
var _content: Node2D
var _sv: Node                         # kcScrollView (aScrollView)
var _strip_tween: Tween


func on_enter() -> void:
	_molds = _load_molds()
	# viewDidLoad: fresh infoDict, appleImage, next hidden, first instruction.
	_info = {}
	_build_apple_image()
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	change_instruction("inst_select_apple.png")
	# viewWillAppear: -> screenSetup: back locked out for 0.5s.
	lock_back_button()
	# The strip's views, built once (initFlavors re-adds identical buttons on
	# every viewDidAppear:); hidden until on_did_appear.
	_build_strip()


## viewDidAppear: (0x14C6D0): initFlavors (auto-select + the 2.0 s scroll),
## then the strip drop. Nav calls this after the push / pop slide (at once
## when unanimated), on the first appearance and on every return.
func on_did_appear() -> void:
	_view_did_appear()


## UINavigationController keeps this controller alive under caCleanDirt
## (Nav.gd's opt-in); back shows it again and only viewWillAppear: /
## viewDidAppear: re-run.
func keeps_state_on_push() -> bool:
	return true


## Back from caCleanDirt:
##  * viewWillAppear: (0x14C608) -> screenSetup (0x14C864): back disabled,
##    re-enabled 0.5 s later (performSelector afterDelay: 0x3FE00000 00000000).
##  * viewDidAppear: (0x14C6D0) -> initFlavors (0x14C9C4) AGAIN: the strip
##    already holds its buttons (subviews >= 3), so it removes the tag-1000
##    lock overlays (none -- everything unlocked), sets every subview's alpha
##    to 1, re-reads CandyApples.plist and adds six NEW buttons over the old
##    ones (same frames and art -- not reproduced, nothing visible changes),
##    auto-clicks mold 1 again (button_press, mold 1 merged into the shared
##    infoDict, appleImage back to mold 1 -- the earlier pick is LOST; next
##    is already showing so no slide), jumps the content to offset 640 and
##    animates it to 0 over 2.0 s; then the strip is re-parked at centre
##    (160,-250), unhidden and dropped to (160,100) over 0.5 s.
func on_resume() -> void:
	_drop_stale_coin_panel()
	lock_back_button()
	if _sv != null:
		_sv.call("cancel_tracking")


## AppDelegate re-adds the one coins panel on every appearance (CoinHUD
## builds a new one on Nav.screen_changed, which fires after on_resume); the
## copy left from the first appearance must go, as MakeViewController does.
func _drop_stale_coin_panel() -> void:
	var old := get_node_or_null("CoinInfoView")
	if old != null:
		remove_child(old)
		old.queue_free()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## The plist ships in the app bundle; the importer converts it to
## data/CandyApples.json in the import cache, read here through Assets.
func _load_molds() -> Array:
	var parsed: Variant = Assets.json(MOLDS_JSON)
	if parsed is Array:
		return parsed
	push_warning("caSelectApple: CandyApples table not found")
	return []


func _build_apple_image() -> void:
	_apple_image = Sprite2D.new()
	_apple_image.position = APPLE_CENTER
	_apple_image.scale = Vector2(APPLE_SCALE, APPLE_SCALE)
	add_child(_apple_image)


func _build_strip() -> void:
	# UIScrollView clips to bounds by default; a Control with clip stands in.
	_strip = Control.new()
	_strip.clip_contents = true
	_strip.position = Vector2(0, STRIP_HIDDEN_Y)
	_strip.size = STRIP_SIZE
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.visible = false
	add_child(_strip)

	_content = Node2D.new()
	_strip.add_child(_content)

	# Horizontal only (content height = bounds height); indicators off.
	_sv = ScrollView.new()
	_sv.name = "aScrollViewSim"
	add_child(_sv)
	_sv.call("configure", false, STRIP_FRAME, CONTENT_W)
	_sv.set("content", _content)
	_sv.connect("tapped", _strip_tapped)

	for i in mini(MOLD_COUNT, _molds.size()):
		var item := Node2D.new()
		item.position = Vector2(BTN_X0 + BTN_PITCH * i, 50.0)
		_content.add_child(item)
		var thumb := _tex(str((_molds[i] as Dictionary).get("Thumbnail", "")))
		if thumb != null:
			var s := Sprite2D.new()
			s.texture = thumb
			s.centered = false     # initWithImage: at the button's (0,0)
			item.add_child(s)


## viewDidAppear: (0x14C6D0): initFlavors' auto-select and scroll, then the
## strip drop. Runs on the first appearance and on every return.
func _view_did_appear() -> void:
	# initFlavors: `if (i == 1) appleClicked:` -- auto-select mold 1.
	if _molds.size() > 1:
		_apple_clicked(1)
	# Entrance: strip parked at centre y -250, unhidden, dropped to y 100
	# over 0.5s, while the content scrolls 640 -> 0 over 2.0s (UIView
	# default curve, ease-in-out).
	if _strip_tween != null and _strip_tween.is_valid():
		_strip_tween.kill()
	# setContentOffset:(640,0), then setContentOffset:CGPointZero inside the
	# 2.0 s "Animate_To_First_Item" block.
	_sv.call("set_offset", OFFSET_START)
	_sv.call("set_offset_in_animation_block", 0.0, OFFSET_SECONDS)
	_strip.visible = true
	_strip.position.y = STRIP_HIDDEN_Y
	_strip_tween = create_tween()
	_strip_tween.tween_property(_strip, "position:y", STRIP_FINAL_Y,
		STRIP_DROP_SECONDS).set_custom_interpolator(func(t: float) -> float:
			return UIScrollSim.curve(t))


## appleClicked: (0x14CF9C).
func _apple_clicked(i: int) -> void:
	Audio.play("button_press")
	if i < 0 or i >= _molds.size():
		return
	_info.merge(_molds[i] as Dictionary, true)   # addEntriesFromDictionary:
	var art := _tex(str(_info.get("Image", "")))
	if art != null and _apple_image != null:
		_apple_image.texture = art
	var n := outlet("nextButton")
	if n != null and n != self and not (n as CanvasItem).visible:
		show_next_button()


# -- strip input (the scroll view: drag / flick, tap to pick) ------------

func _unhandled_input(event: InputEvent) -> void:
	# A hidden view takes no touches (viewWillDisappear: hides it).
	if _sv == null or _strip == null or not _strip.visible:
		return
	if _sv.call("handle_input", event):
		get_viewport().set_input_as_handled()


## A touch that never became a drag reaches the button under it
## (touchUpInside: the release must stay within its bounds + 70 pt).
func _strip_tapped(press: Vector2, release: Vector2) -> void:
	for i in MOLD_COUNT:
		var rect := Rect2(Vector2(BTN_X0 + BTN_PITCH * i, 50.0), BTN_SIZE)
		if rect.has_point(press):
			if ScrollView.release_inside(rect, release):
				_apple_clicked(i)
			return


## nextClick: (0x14D1A8): button_press, push a NEW caCleanDirt with
## setInfoDict:infoDict -- the same mutable dictionary, not a copy: every
## later step writes into it (Stick, Color), and a return here sees those
## keys. The port's carrier is GameState.custom_categories; it is handed the
## same Dictionary object (it used to get a duplicate).
func _on_nextClick() -> void:
	Audio.play("button_press")
	GameState.custom_categories = _info
	Nav.next()


## viewWillDisappear: (0x14C7F0) hides the strip.
func on_exit() -> void:
	if _strip != null:
		_strip.visible = false
	if _sv != null:
		_sv.call("settle")


## backClick: (0x14D138): button_press, then pop. Screen's default pops
## silently, so every original back press was missing its click.
func _on_backClick() -> void:
	Audio.play("button_press")
	Nav.back()
