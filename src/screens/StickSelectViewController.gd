# Shared stick / cone / straw picker, reached by milkshake, lemon shake up,
# cotton candy and corn dog.
#
# Read from initWithClassStr:andInfoDict: (0x6164C), viewDidLoad
# (0x61798), +stickNamesForPack: (0x611D8), addButtonForStickPack: (0x65FF8,
# tbb table at 0x660F6), changeToStickPack: (0x66158), setup (0x62FAC),
# viewDidAppear: (0x636AC), the drag handlers (0x665F8 / 0x666C8 / 0x667F8),
# rotateFromTouchPt: (0x66320), trackTouch: (0x66288), getCurrentStickIV
# (0x65CF0), lower/raiseCurrentStick (0x65DA8 / 0x65EBC), categoryClick:
# (0x654EC), nextClick: (0x646A0) and backClick: (0x6462C).
#
# This replaces the scaffolding wheel (invented WHEEL_CENTER (160,372), hit
# radius, momentum and per-food backgrounds keyed by guesswork). The extracted
# nib JSON was also nearly empty; re-reading the raw NIBArchive
# (StickSelectViewController.nib/objects-8.0+.nib) recovered every frame:
# the nib really does hold background, arch, categorySV, instIV, back/next and
# buyAll -- the earlier extraction had simply lost them. Frames below cite
# their nib object index. All nib views are UIImageView / UIButton /
# UIScrollView (self-sizing classes), so every nib centre is a true centre;
# no TintedIV appears anywhere on this screen.
#
# Known divergence of a recorded gameplay frame: a recording of the original
# shows BOTH category buttons side by side and no surprise-spin button. The
# 1.27 binary provably sets both category buttons to the SAME frame
# (104,0,112,65) -- both setFrame: calls read at instruction level, second
# call's x reg traced through `mov r5, r2` at 0x62026 -- hides the current
# pack's button (0x62316..0x62326), and unconditionally builds the spin button
# (0x624xx). That recording is therefore from some other release; the binary
# wins for v1.27.
#
# The surprise spin's finish slides next in as showNextButton (0x65938)
# does (it used to just appear).
# Kept alive under the screens it pushes; see
# keeps_state_on_push / on_exit / on_resume for viewDidDisappear: (0x636EC)
# and viewWillAppear: / viewDidAppear: (0x62F6C / 0x636AC).
#
# Not ported, deliberately:
#  * showLockedMessage (0x65A88) and the lock gate in nextClick: -- the port
#    ships everything unlocked (FF_KEY_EVERYTHING true), so setup (0x62FAC)
#    hides every lock overlay and the gate can never fire. The overlays are
#    still built, as the original builds them, and then hidden.
#  * statusStick / statusCone bookkeeping (16 named cone + stick entries into
#    NSUserDefaults, 0x61798 tail) -- prize/unlock metadata with no consumer
#    in the port yet.

extends "res://core/Screen.gd"

# -- class strings, as initWithClassStr: receives them ------------------

const CLASS_BY_FOOD := {
	"ms": "MILK_SHAKE", "lsu": "LEMON_SHAKE_UP",
	"cc": "COTTON_CANDY", "cd": "CORN_DOG",
}

## viewDidLoad's class branch: background image, the two category packs
## (first listed = the starting pack, whose button starts hidden 0x62316),
## per branch at 0x61798.
const FOODS := {
	"MILK_SHAKE": {"bg": "bg_milkshake.png", "packs": [2, 3]},
	"LEMON_SHAKE_UP": {"bg": "bg_lemon.png", "packs": [2, 3]},
	"COTTON_CANDY": {"bg": "cc_bg.png", "packs": [1, 0]},
	"CORN_DOG": {"bg": "bg_corndogs.png", "packs": [0, 2]},
}

## +stickNamesForPack: (0x611D8). Order is the initWithObjects: argument
## order. Packs 0/1 lead with their highest-numbered file and then run
## 0..14 / 1..15 -- cc_stix15 and cc_cone16 ship in the bundle but are in
## no pack. That is the original's own list, kept as read.
const PACKS := {
	0: ["cc_stix16", "cc_stix0", "cc_stix1", "cc_stix2", "cc_stix3",
		"cc_stix4", "cc_stix5", "cc_stix6", "cc_stix7", "cc_stix8",
		"cc_stix9", "cc_stix10", "cc_stix11", "cc_stix12", "cc_stix13",
		"cc_stix14"],
	1: ["cc_cone17", "cc_cone1", "cc_cone2", "cc_cone3", "cc_cone4",
		"cc_cone5", "cc_cone6", "cc_cone7", "cc_cone8", "cc_cone9",
		"cc_cone10", "cc_cone11", "cc_cone12", "cc_cone13", "cc_cone14",
		"cc_cone15"],
	2: ["lsu_Straw_Straight-1", "lsu_Straw_Straight-2", "lsu_Straw_Straight-3",
		"lsu_Straw_Straight-4", "lsu_Straw_Straight-5", "lsu_Straw_Straight-6",
		"lsu_Straw_Straight-7", "lsu_Straw_Straight-8", "lsu_Straw_Straight-9",
		"lsu_Straw_Straight-10", "lsu_Straw_Straight-11",
		"lsu_Straw_Straight-12", "lsu_Straw_Straight-13",
		"lsu_Straw_Straight-14", "lsu_Straw_Straight-15",
		"lsu_Straw_Straight-16"],
	3: ["lsu_Straw-1", "lsu_Straw-2", "lsu_Straw-3", "lsu_Straw-4",
		"lsu_Straw-5", "lsu_Straw-6", "lsu_Straw-7", "lsu_Straw-8",
		"lsu_Straw-9", "lsu_Straw-10", "lsu_Straw-11", "lsu_Straw-12",
		"lsu_Straw-13", "lsu_Straw-14", "lsu_Straw-15", "lsu_Straw-16"],
}

## addButtonForStickPack: (0x65FF8) -- CFStrings 0x6BA974..0x6BA9A4 selected
## by the tbb at 0x660F6 (bytes [19, 2, 8, 14]).
const PACK_BUTTON_ART := {
	0: "Sub_Cat_Sticks.png", 1: "Sub_Cat_Cones.png",
	2: "Sub_Cat_Straws.png", 3: "Sub_Cat_Crazy_Straws.png",
}

# -- nib geometry (raw NIBArchive; UIKit self-sizing views) --------------

## nib object 74: background UIImageView, frame (0,0,320,480), no image --
## viewDidLoad picks it per food.
## nib object 67: arch UIImageView, frame (0,219,320,283), arch.png (native).
const ARCH_RECT := Rect2(0, 219, 320, 283)
## nib object 30: spinView, an 800x800 UIControl at (-240, 80). Its local
## (400,400) -- where both 250x250 pinwheel views are centred (objects 21/57,
## frames (275,275,250,250)) -- is therefore root (160, 480): the hub.
const SPIN_VIEW_ORIGIN := Vector2(-240, 80)
const HUB := Vector2(160, 480)
const PINWHEEL_SIZE := Vector2(250, 250)
## nib object 53: categorySV UIScrollView, frame (0,0,320,80). viewDidLoad
## (0x61798) sets its contentSize to its own frame size, and the raw nib has
## no UIAlwaysBounce* keys, so it can never scroll (UIKit's pan only starts
## along an axis whose content is larger than the view, or alwaysBounce) --
## the category buttons are its only content and it is ported as a plain
## container. Its indicators are off in the nib anyway
## (UIShowsHorizontal/VerticalScrollIndicator NO).
## nib object 18/27: back/next UIButtons, 94x63, centres (47,446.5)/(273,446.5)
## -> frames (0,415,94,63) and (226,415,94,63), btn_back/btn_next backgrounds.
const BACK_RECT := Rect2(0, 415, 94, 63)
const NEXT_RECT := Rect2(226, 415, 94, 63)
## nib object 17: instIV, frame (102,426,218,40) -- imageless in the nib and
## no code on this screen ever sets it, so this screen shows no instruction.
## nib object 10: buyAllBtn (190,320,135,96) -- hidden under FF_KEY_EVERYTHING
## (0x617C8), which is the port's permanent state, so it is not built.

# -- the wheel (viewDidLoad loop, 0x61798) -------------------------------

const STICK_COUNT := 16
## Rotation step per stick: double at 0x61C20 = pi/8 (22.5 deg).
const STICK_STEP := PI / 8.0
## Each stick: UIImageView frame (0,0,25,300) (0x41C80000/0x43960000), layer
## anchorPoint (0.5, 1.0), setCenter:(400,400) -- for UIKit, `center` is where
## the anchor point lands, so the frame's BOTTOM-CENTRE sits on the hub and
## the 300pt frame extends straight up. contentMode 4 (Center) draws the art
## at natural size centred in that frame: art centre = hub + (0,-150), both
## axes, whatever the art's own size.
const STICK_ART_CENTER := Vector2(0, -150)
## Lock overlay (round_black_lock.png, i >= 3): setCenter:(frame.size * 0.5)
## = (12.5, 150) stick-local = the same frame-centre point.
const LOCK_TAG_FIRST_UNLOCKED := 3
## lower/raiseCurrentStick (0x65DA8/0x65EBC): translate (0,+50)/(0,-50) in
## the stick's own (rotated) space, 0.25s, UIViewAnimationCurve 3 (linear).
const STICK_SLIDE := 50.0
const STICK_SLIDE_SECONDS := 0.25

## Category buttons: BOTH get frame (104, 0, 112, 65) inside categorySV --
## instruction-verified for both calls (0x61E0A..0x61E4C; the second call's
## x comes through `mov r5, r2` holding 104.0). One is visible at a time:
## the current pack's button is hidden (0x62316, and categoryClick: 0x654EC
## hides the tapped one and shows the rest).
const CATEGORY_RECT := Rect2(104, 0, 112, 65)

# -- spin physics (dragEnded: 0x667F8) -----------------------------------

## trackTouch: (0x66288) re-samples the touch every 0.25s (0x3FD0... dbl).
const TRACK_INTERVAL := 0.25
## Release velocity (px/s) over the last tracked sample: extra notches
## n = trunc(v / 111.0) (0x66C40), and any v > 777.0 (0x66C44) pins n = 7.
const SPIN_VELOCITY_DIV := 111.0
const SPIN_VELOCITY_CAP := 777.0
const SPIN_NOTCH_CAP := 7.0
## Detent: +/- pi/8 by drag sign (floats 0x66C48/0x66C4C); the coast is
## n*M - fmod(r, M) -- snap back to the last passed detent, then n more.
## Index delta = degrees(total)/22.5 (180.0 at 0x66C50, pi dbl at 0x66C38,
## 22.5 at 0x66C54). Animation runs n*0.25 + 0.5 s (0x3E800000/0x3F000000),
## UIViewAnimationCurve 2 (ease out); raiseCurrentStick fires when it ends.
const COAST_SECONDS_PER_NOTCH := 0.25
const COAST_SECONDS_BASE := 0.5
const DEGREES_PER_NOTCH := 22.5

## nextClick: (0x646A0) straw hand-off: ItemCenterX = 250.0 (dbl 0x64EC8)
## - art width / 2; ItemCenterY 30.0 (ms, 0x41F00000) or 70.0 (lsu,
## 0x428C0000); Rotation 15.0 (0x41700000); IsEdible NO, ViewIndex 2,
## Type "Stationary". Consumed by MakeViewController (not yet ported), so
## these are stored as data; which view class anchors them is that screen's
## question.
const STRAW_CENTER_X_BASE := 250.0
const STRAW_CENTER_Y := {"MILK_SHAKE": 30.0, "LEMON_SHAKE_UP": 70.0}
const STRAW_ROTATION := 15.0

var _class_str := ""
## infoDict, retained by initWithClassStr:andInfoDict: (0x6164C): what the
## previous step handed over. nextClick: copies THIS dict every time
## (initWithDictionary: self->infoDict), so a second next after coming back
## builds from the same input, not from whatever a later screen left in
## GameState.custom_categories.
var _info_dict: Dictionary = {}
var _wheel: Node2D
var _sticks: Array = []          # per stick: {slide, sprite, lock}
var _category_buttons: Array = []
var _current_pack := -1
var _current_stick_idx := 0
var _running_stick_idx := 0
var _total_rot := 0.0

var _dragging := false
var _coasting := false
var _orig_pt := Vector2.ZERO     # origPt: window point at dragBegan
var _gesture_rot := 0.0          # currentRot: this gesture's angle delta
var _wheel_base_rot := 0.0
var _latest_pos := Vector2.ZERO  # the touch's current location
var _last_position := Vector2.ZERO   # trackTouch:'s 0.25s-old sample
var _last_timestamp := 0.0
var _track_accum := 0.0

## Surprise spin:
##   initWithClassStr:andInfoDict: 0x6164C  Consumable DM_CONSUMABLE_SPIN /
##     Spin_Stick; first-time message.
##   viewDidLoad 0x61798  cost = CoinCosts.<food>.MysteryStick, 6 when
##     absent; ConsumableButton(btn_surprise_spin, (0,-25) / (65,3)) at
##     centre (50, 350.5); buyClick: on touch-up.
##   buyClick: 0x65674  "button_press" (not "store"), purchaseConsumable.
##   consumablePurchased: 0x63F7C  lowerCurrentStick (0x65DA8, 0.25 s), hide
##     nextBtn, every lock (tag 888) hidden, startSpin after 0.25 s.
##   startSpin 0x638FC  "tick_multiple", badge / wheel / category strip
##     untouchable, wheel transform reset to identity, currentStickIdx 0,
##     "startRot": rotation 0 -> 2pi, ease-in, 2.0 s.
##   animationDidStop:finished: 0x63B10  after the 2.0 s one: "repeatRot"
##     0 -> 2pi linear 1.5 s, repeatCount arc4random() % 3 + 1; after the
##     1.5 s one: k = arc4random() & 0xF, "stopRot" 0 -> k*22.5 deg ease-out
##     2.5 s, the model transform rotated by k*22.5 deg, currentStickIdx = -k;
##     after the 2.5 s one: raiseCurrentStick (0x65EBC), badge and category
##     strip re-enabled, showNextButton.
##   consumablePurchaseFailed:error:2 0x6442C  "You do not have enough coins."
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SPIN_KEY := "DM_CONSUMABLE_SPIN"
const SPIN_NAME := "Spin_Stick"
const SPIN_COST := 6
const SPIN_MESSAGE := "Try out a surprise spin! A chance to get any of the sticks, even the locked ones! Try it for FREE now!"
const SPIN_ART := "btn_surprise_spin.png"
const SPIN_CENTER := Vector2(50, 350.5)
const SPIN_START_DELAY := 0.25
const SPIN_START_SECONDS := 2.0        # "startRot", ease-in, one turn
const SPIN_REPEAT_SECONDS := 1.5       # "repeatRot", linear, per turn
const SPIN_STOP_SECONDS := 2.5         # "stopRot", ease-out, to k * 22.5 deg

var _spin: RefCounted
var _spin_button: TextureButton
var _next_button: TextureButton
var _spinning := false
var _spin_deferred := false
var _coast_tween: Tween


func on_enter() -> void:
	_class_str = str(CLASS_BY_FOOD.get(GameState.food, "MILK_SHAKE"))
	_info_dict = GameState.custom_categories.duplicate(true)
	var food: Dictionary = FOODS[_class_str]

	# The .tscn's two pinwheel sprites sit at the extractor's spinView-local
	# coords and would not rotate; the wheel is rebuilt whole instead.
	for child in get_children():
		if child is Sprite2D and str(child.name).begins_with("pinwheel"):
			child.visible = false

	_add_background(str(food["bg"]))
	_add_arch()
	_build_wheel()
	_build_category_buttons(food["packs"])
	_change_to_stick_pack(int(food["packs"][0]))
	_add_nav_buttons()
	_build_spin()

	# setup (0x62FAC): isPurchased = FF_KEY_<food> || FF_KEY_EVERYTHING; the
	# port ships everything unlocked, so every lock overlay ends hidden.
	for s in _sticks:
		if s["lock"] != null:
			s["lock"].visible = false

	# viewDidAppear: (0x636AC) raises the current stick -- on_did_appear,
	# once the push slide is over.
	set_process(true)


## Kept under the screen nextClick: pushes (MakeViewController for ms / lsu,
## ccMachine, cdBatterCoating) and under the coin store:
## back shows the same wheel, pack and stick. Only these re-run:
##   viewDidDisappear: (0x636EC) -> lowerCurrentStick (0x65DA8), on_exit;
##   viewWillAppear: (0x62F6C)   -> setup (0x62FAC): lock overlays re-evaluated
##                                  (all hidden: everything owned);
##   viewDidAppear: (0x636AC)    -> raiseCurrentStick (0x65EBC), user
##                                  interaction back on.
## So on return the chosen stick, sitting at neutral, rises 50 px again over
## 0.25 s.
func keeps_state_on_push() -> bool:
	return true


## viewDidDisappear: (0x636EC): lowerCurrentStick. It runs once the push has
## finished, i.e. with the screen already covered, so its 0.25 s slide is
## never seen -- applied at once here (an animation left on a node out of the
## tree would pause and replay on return, fighting the raise). The
## COTTON_CANDY branch's "previousItem" default feeds only the stores'
## purchase analytics -- not ported.
func on_exit() -> void:
	if _sticks.is_empty():
		return
	_lower_current_stick(false)


func on_resume() -> void:
	# A fresh appearance: no gesture in progress.
	_dragging = false
	_track_accum = 0.0
	# setup (0x62FAC): isPurchased (FF_KEY_<food> || FF_KEY_EVERYTHING) hides
	# every lock overlay in the port.
	for s in _sticks:
		if s["lock"] != null:
			s["lock"].visible = false


## viewDidAppear: (0x636AC): raiseCurrentStick -- after the push / pop slide
## (Nav calls this when it ends, at once when unanimated), on the first
## appearance and on every return. The stick used to rise at the start of
## the slide.
func on_did_appear() -> void:
	if _sticks.is_empty():
		return
	_raise_current_stick()
	# raiseCurrentStick re-enables the VIEW; spinView itself stays untouchable
	# while a spin or a release coast is still running (startSpin 0x638FC /
	# dragEnded: 0x667F8), and their completions raise the stick they land on.
	if _spinning or (_coast_tween != null and _coast_tween.is_valid()
			and _coast_tween.is_running()):
		_coasting = true
	if _spin_deferred:
		_spin_deferred = false
		_start_spin()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _add_background(image: String) -> void:
	var tex := _tex(image)
	if tex == null:
		return
	var bg := Sprite2D.new()
	bg.texture = tex
	bg.centered = false
	add_child(bg)
	move_child(bg, 0)


func _add_arch() -> void:
	var tex := _tex("arch.png")     # 320x283 native = nib frame
	if tex == null:
		return
	var arch := Sprite2D.new()
	arch.texture = tex
	arch.centered = false
	arch.position = ARCH_RECT.position
	add_child(arch)


## The wheel: 16 stick pivots around the hub, then the two pinwheel views on
## top -- viewDidLoad addSubviews each stick and sends it to back, so sticks
## render under the nib's pinwheel/pinwheel_overlay pair.
func _build_wheel() -> void:
	_wheel = Node2D.new()
	_wheel.position = HUB
	add_child(_wheel)

	_sticks.clear()
	for i in STICK_COUNT:
		var pivot := Node2D.new()
		pivot.rotation = STICK_STEP * float(i)
		_wheel.add_child(pivot)

		# lower/raiseCurrentStick translate the stick's transform along its
		# own axis; that lives on this intermediate node.
		var slide := Node2D.new()
		pivot.add_child(slide)

		var sprite := Sprite2D.new()
		sprite.centered = true
		sprite.position = STICK_ART_CENTER
		slide.add_child(sprite)

		var lock: Sprite2D = null
		if i >= LOCK_TAG_FIRST_UNLOCKED:
			lock = Sprite2D.new()
			lock.texture = _tex("round_black_lock.png")
			lock.centered = true
			lock.position = STICK_ART_CENTER
			slide.add_child(lock)

		_sticks.append({"slide": slide, "sprite": sprite, "lock": lock,
			"offset_y": 0.0})

	for img in ["pinwheel.png", "pinwheel_overlay.png"]:
		var tex := _tex(img)
		if tex == null:
			continue
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = true
		s.scale = PINWHEEL_SIZE / Vector2(tex.get_size())
		_wheel.add_child(s)


## changeToStickPack: (0x66158): swap all 16 images in place from
## +stickNamesForPack:.
func _change_to_stick_pack(pack: int) -> void:
	if _current_pack != pack:
		var names: Array = PACKS[pack]
		for i in STICK_COUNT:
			_sticks[i]["sprite"].texture = _tex(str(names[i]) + ".png")
	_current_pack = pack


## Two buttons in categorySV (frame (0,0,320,80)), both at CATEGORY_RECT;
## the current pack's is hidden. categoryClick: hides the tapped one, shows
## the other, and switches packs.
func _build_category_buttons(packs: Array) -> void:
	_category_buttons.clear()
	for k in packs.size():
		var pack := int(packs[k])
		var tex := _tex(str(PACK_BUTTON_ART[pack]))
		if tex == null:
			continue
		var b := TextureButton.new()
		b.texture_normal = tex
		b.ignore_texture_size = true
		b.stretch_mode = TextureButton.STRETCH_SCALE
		b.position = CATEGORY_RECT.position
		b.size = CATEGORY_RECT.size
		b.visible = k != 0        # starting pack's button hidden (0x62316)
		b.pressed.connect(_on_category_click.bind(pack, b))
		add_child(b)
		_category_buttons.append(b)


func _on_category_click(pack: int, button: TextureButton) -> void:
	Audio.play("button_press")
	for b in _category_buttons:
		b.visible = b != button
	_change_to_stick_pack(pack)


## The nib's back/next buttons. Next is visible from the start on this
## screen -- nothing hides it, and its only slide-in (showNextButton 0x65938)
## belongs to the unported surprise spin.
func _add_nav_buttons() -> void:
	_add_button("btn_back.png", BACK_RECT, func() -> void:
		Audio.play("button_press")     # backClick: 0x6462C
		Nav.back())
	_next_button = _add_button("btn_next.png", NEXT_RECT, _on_next_click)


func _add_button(image: String, rect: Rect2, on_press: Callable) -> TextureButton:
	var tex := _tex(image)
	if tex == null:
		return null
	var b := TextureButton.new()
	b.texture_normal = tex
	b.position = rect.position
	b.pressed.connect(on_press)
	add_child(b)
	return b


# -- the surprise spin --------------------------------------------------

## viewDidLoad: the ConsumableButton, and init's Consumable.
func _build_spin() -> void:
	_spin = ConsumableScript.new(SPIN_KEY, SPIN_NAME, SPIN_COST)
	_spin.set("first_time_message", SPIN_MESSAGE)
	_spin.set("on_purchased", _on_spin_purchased)
	# consumablePurchaseFailed:error: (0x6442C): delegate nil -> a silent OK.
	_spin.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable(), false))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buySpin"
	b.call("setup", SPIN_ART, 0, -25, SPIN_COST, 65, 3)
	b.position = SPIN_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyClick)
	add_child(b)
	_spin_button = b


## buyClick: (0x65674).
func _on_buyClick() -> void:
	if _spinning or _dragging:
		return
	Audio.play("button_press")
	_spin.call("purchase", self)


## consumablePurchased: (0x63F7C).
func _on_spin_purchased(_free: bool) -> void:
	_lower_current_stick()
	if _next_button != null:
		_next_button.visible = false
	for s in _sticks:
		if s["lock"] != null:
			s["lock"].visible = false
	_spinning = true
	get_tree().create_timer(SPIN_START_DELAY).timeout.connect(_start_spin)


## startSpin (0x638FC) and the three-stage animationDidStop: chain (0x63B10).
func _start_spin() -> void:
	if not is_inside_tree():
		# performSelector:afterDelay: fires whether or not the screen is
		# covered (the coins panel's GET COINS can push the coin store inside
		# the 0.25 s). INFERRED: a covered node cannot run the port's tweens,
		# so the spin starts when the screen is shown again (on_did_appear)
		# rather than being lost -- which left the wheel locked, next hidden.
		_spin_deferred = true
		return
	Audio.play("tick_multiple")
	_spin_button.disabled = true
	for b in _category_buttons:
		if b is BaseButton:
			(b as BaseButton).disabled = true
	_coasting = true                     # the wheel ignores touches
	_wheel.rotation = 0.0                # setTransform:identity
	_wheel_base_rot = 0.0
	_total_rot = 0.0
	_current_stick_idx = 0
	_running_stick_idx = 0
	var repeats := randi() % 3 + 1
	var k := randi() & 0xF
	var stop_angle := deg_to_rad(float(k) * DEGREES_PER_NOTCH)
	var tw := create_tween()
	tw.tween_property(_wheel, "rotation", TAU, SPIN_START_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.tween_property(_wheel, "rotation", TAU * (1 + repeats),
		SPIN_REPEAT_SECONDS * repeats).set_trans(Tween.TRANS_LINEAR)
	tw.tween_property(_wheel, "rotation", TAU * (1 + repeats) + stop_angle,
		SPIN_STOP_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func() -> void: _finish_spin(k, stop_angle))


func _finish_spin(k: int, stop_angle: float) -> void:
	# The model transform is rotate(identity, k * 22.5 deg).
	_wheel.rotation = stop_angle
	_wheel_base_rot = stop_angle
	_total_rot = stop_angle
	_current_stick_idx = -k
	_running_stick_idx = 0
	_raise_current_stick()               # also clears _coasting
	_spin_button.disabled = false
	for b in _category_buttons:
		if b is BaseButton:
			(b as BaseButton).disabled = false
	_spinning = false
	_show_next_button()


## showNextButton (0x65938): instIV hidden (it is imageless here), next
## parked 500 px right of its centre, unhidden, and slid home over 0.25 s,
## UIViewAnimationCurve 0 (ease-in-out). The port used to just unhide it.
func _show_next_button() -> void:
	if _next_button == null:
		return
	var home := NEXT_RECT.position
	_next_button.position = home + Vector2(SLIDE_OFFSET, 0)
	_next_button.visible = true
	create_tween().tween_property(_next_button, "position", home, NEXT_SLIDE) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# -- current stick ----------------------------------------------------

## getCurrentStickIV (0x65CF0): stickArr[currentStickIdx floored-mod 16].
func _current_stick() -> Dictionary:
	return _sticks[posmod(_current_stick_idx, STICK_COUNT)]


## lower/raiseCurrentStick are CGAffineTransformTranslate on the stick's
## transform -- relative moves: dragBegan lowers the raised stick back to
## neutral (+50 onto -50), and the raise after a spin takes the new stick
## from neutral to -50. UIView animations compose against the MODEL layer,
## so a lower issued mid-raise still lands on exactly 0; the logical offset
## is tracked per stick and tweened to, rather than reading the on-screen
## position, to keep that semantics.
func _slide_current_stick(offset_y: float, animated: bool = true) -> void:
	var stick := _current_stick()
	stick["offset_y"] = float(stick["offset_y"]) + offset_y
	var target := Vector2(0, stick["offset_y"])
	if not animated:
		var old: Variant = stick.get("tween")
		if old is Tween and (old as Tween).is_valid():
			(old as Tween).kill()
		(stick["slide"] as Node2D).position = target
		return
	var tw := create_tween()
	tw.tween_property(stick["slide"], "position", target, STICK_SLIDE_SECONDS)
	stick["tween"] = tw


func _lower_current_stick(animated: bool = true) -> void:
	_slide_current_stick(STICK_SLIDE, animated)


func _raise_current_stick() -> void:
	_slide_current_stick(-STICK_SLIDE)
	_coasting = false


# -- the drag (0x665F8 / 0x666C8 / 0x667F8) ---------------------------

## The original's touch angles are measured about spinView.center, which is
## the hub (spinView frame (-240,80,800,800) -> centre (160,480) root).
func _angle_about_hub(p: Vector2) -> float:
	return (p - HUB).angle()


func _unhandled_input(event: InputEvent) -> void:
	if _wheel == null or _coasting:
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var pos: Vector2 = event.position
		if event.pressed:
			# spinView's root-space frame starts at y = 80; anything the
			# nib's buttons did not consume above that line starts a drag.
			if pos.y < SPIN_VIEW_ORIGIN.y:
				return
			_drag_began(pos)
		elif _dragging:
			_drag_ended(pos)
	elif event is InputEventMouseMotion and _dragging:
		_drag_moved(event.position)


func _drag_began(pos: Vector2) -> void:
	_dragging = true
	_orig_pt = pos
	_gesture_rot = 0.0
	_wheel_base_rot = _wheel.rotation
	_latest_pos = pos
	_last_position = pos
	_last_timestamp = Time.get_ticks_msec() / 1000.0
	_track_accum = 0.0
	_lower_current_stick()


## rotateFromTouchPt: -- the wheel follows the finger's angle about the hub
## relative to where the gesture started. The raw atan2 difference can jump
## by 2*pi crossing the branch cut; the original leaves that in, and every
## consumer is invariant mod 2*pi (16 notches), so the port leaves it in too.
func _drag_moved(pos: Vector2) -> void:
	_latest_pos = pos
	var delta := _angle_about_hub(pos) - _angle_about_hub(_orig_pt)
	_wheel.rotation = _wheel_base_rot + delta
	_gesture_rot = delta

	# dragMoved: (0x666C8): runningStickIdx = round((currentRot + totalRot)
	# / -pi/8) (dbl 0x667F0); a tick per detent crossed.
	var running := roundi((_gesture_rot + _total_rot) / -STICK_STEP)
	if running != _running_stick_idx:
		Audio.play("tick_single")
	_running_stick_idx = running


func _process(delta: float) -> void:
	if not _dragging:
		return
	# trackTouch: re-reads the touch's location every 0.25s, keeping an up-to
	# 0.25s-old sample for the release velocity. The touch's position, not a
	# global cursor query -- synthetic test input never moves the OS cursor.
	_track_accum += delta
	if _track_accum >= TRACK_INTERVAL:
		_track_accum = 0.0
		_last_position = _latest_pos
		_last_timestamp = Time.get_ticks_msec() / 1000.0


func _drag_ended(pos: Vector2) -> void:
	_dragging = false
	_drag_moved(pos)               # the original re-runs rotateFromTouchPt:
	var r := _gesture_rot

	var now := Time.get_ticks_msec() / 1000.0
	var dt := maxf(now - _last_timestamp, 0.000001)
	var v := pos.distance_to(_last_position) / dt
	# truncf in the original; v is non-negative, so floor is the same.
	var notches := floorf(v / SPIN_VELOCITY_DIV)
	if v > SPIN_VELOCITY_CAP:
		notches = SPIN_NOTCH_CAP

	var m := STICK_STEP if r >= 0.0 else -STICK_STEP
	var coast := notches * m - fmod(r, m)
	var total := r + coast         # an exact multiple of pi/8

	_current_stick_idx -= roundi(rad_to_deg(total) / DEGREES_PER_NOTCH)
	_total_rot += total

	var seconds := notches * COAST_SECONDS_PER_NOTCH + COAST_SECONDS_BASE
	_coasting = true
	var tw := create_tween()
	_coast_tween = tw
	tw.tween_property(_wheel, "rotation", _wheel_base_rot + total, seconds) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_raise_current_stick)

	if absi(int(notches)) > 0:
		Audio.play("tick_multiple")


# -- next (0x646A0) ---------------------------------------------------

## Builds the original's hand-off dictionary and moves on. The lock gate
## (viewWithTag:888 visible -> showLockedMessage) can never fire in the port,
## where every lock is hidden; it is checked anyway so the code shape matches.
func _on_next_click() -> void:
	Audio.play("button_press")
	var stick := _current_stick()
	if stick["lock"] != null and stick["lock"].visible:
		print("[StickSelect] locked stick -- original shows the buy alert")
		return

	var tex: Texture2D = stick["sprite"].texture
	# The making screen before this one left its baked layers in infoDict;
	# this screen adds one and passes the whole dict on.
	var info: Dictionary = _info_dict.duplicate(true)

	match _class_str:
		"MILK_SHAKE", "LEMON_SHAKE_UP":
			var w := 0.0 if tex == null else float(tex.get_width())
			info["Straw"] = {
				"Properties": {
					"IsEdible": false,
					"ViewIndex": 2,
					"Type": "Stationary",
					"ItemCenterX": STRAW_CENTER_X_BASE - w * 0.5,
					"ItemCenterY": STRAW_CENTER_Y[_class_str],
					"Rotation": STRAW_ROTATION,
				},
				"Image": tex,
			}
		"COTTON_CANDY":
			# ccMachine gets the raw stick image plus the pack id (0x646A0).
			info["stickImg"] = tex
			info["packID"] = str(_current_pack)
		"CORN_DOG":
			info["stickImg"] = tex

	# For the next screen: MakeViewController (ms, lsu), ccMachine (cc) or
	# cdBatterCoating (cd).
	GameState.custom_categories = info
	Nav.next()
