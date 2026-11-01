# Funnel Cake step 4 -- tip the bowl and pour the batter into the funnel.
#
# GROUNDED from initWithBatterID: (0x982E0), viewDidLoad (0x9858C),
# viewWillAppear: (0x98B18), accelerometer:didAccelerate: (0x98D98),
# startBatterFlowForDuration: (0x98158), stopBatterFlow (0x98024),
# levelTheBowl (0x97F50), finishedPouringBatter (0x97F40), nextClick:
# (0x99338), backClick: (0x992A4, disassembly) and viewWillDisappear:
# (0x98C90, disassembly: it only zeroes the filter state and stops the
# accelerometer). Read from the original binary; SpriteSheetView semantics from
# initWithFrame:andContentView:andColumns:andRows: (0x47770) and tick
# (0x47910): a clipped strip whose tick shows currentFrameIdx then increments.
#
# Mechanic, as read -- a TILT pour, not a drawing screen: the filtered device
# roll (low-pass 0.05/0.95, angle = x*6) rotates the whole side-view bowl,
# clamped to [-45, 0] deg. The moment the clamped angle reaches -45 deg,
# bowlTiltedAt45Degree latches, the bowl pins there and
# startBatterFlowForDuration:3.0 runs; the pour is IRREVERSIBLE from then on.
# PORT CHOICE: the tilt becomes press-and-hold. Holding tips the bowl toward
# -45 deg, releasing early tips it back, and reaching -45 deg starts the
# grounded 3.0s flow.
#
# The flow (0x98158): loop fc_batter_pour_loop, fade the 4-frame stream strip
# in over 0.2s linear, tick it at +0.2/+0.5/+0.8 (frames 1..3; frame 0 was
# shown by viewWillAppear's single tick), stopBatterFlow at +3.0.
# stopBatterFlow (0x98024): stop the sound; over 0.5s linear the stream and
# the bowl's batter fade out while the funnel's batter fades in; levelTheBowl
# at +0.5. levelTheBowl (0x97F50): bowl back to 0 deg over 0.5s linear and
# showNextButton IMMEDIATELY (finishedPouringBatter does not wait).
#
# The buy-skip consumable (initWithBatterID: 0x982E0, buyClick: 0x99238) is
# a 3-coin consumable, not IAP; ported, see the skip block.

extends "res://core/Screen.gd"

## Skip consumable (ported; the original shows its badge):
## initWithBatterID: 0x982E0 builds Consumable DM_CONSUMABLE_SKIP / Skip_40Pour,
## cost = the dead server table GameData.CoinCosts ... SkipPour, 3 when
## absent; first-time message below. viewDidLoad 0x9858C builds the
## ConsumableButton (btn_skip, label offsets (0,-25), cost offsets (65,3)) at
## centre (50, 350.5) and wires buyClick: 0x99238 ("store" sound,
## purchaseConsumable). consumablePurchased: 0x98FB8 calls nextClick: with the badge as sender -- the same path as the next button.
## consumablePurchaseFailed:error: 0x99164 (error 2) shows "You do not
## have enough coins." (the port's Consumable raises that in place of the
## original's not-enough-coins ad).
const ConsumableScript := preload("res://core/Consumable.gd")
const ConsumableButtonScript := preload("res://core/ConsumableButton.gd")
const SKIP_KEY := "DM_CONSUMABLE_SKIP"
const SKIP_NAME := "Skip_40Pour"
const SKIP_COST := 3
const SKIP_MESSAGE := "Try out a skip of the current screen! Hurry up and move on to your favorite part of the maker! Try it for FREE now!"
const SKIP_ART := "btn_skip.png"
const SKIP_CENTER := Vector2(50, 350.5)

var _skip: RefCounted
var _skip_button: TextureButton

## Nib: the bowl container UIView is (79, 71, 231, 143); UIKit rotates about
## its centre (194.5, 142.5). Children (back / batterSide / front) keep their
## nib offsets; the wrapper below re-centres them so rotation matches.
const BOWL_FRAME := Rect2(79, 71, 231, 143)

## viewDidLoad (0x9858C): per-batter art. IDs from fcMixBatterVC
## setIngredients (0x89938): 0 original, 1 strawberry, 2 caramel, 3 chocolate.
const ART := {
	0: {"stream": "fc_batter_stream_orig1-4.png",
		"side": "fc_batter_original_for_Side_Bowel.png",
		"funnel": "fc_batter_original_for_Funnel.png"},
	1: {"stream": "fc_batter_stream_straw1-4.png",
		"side": "fc_batter_strawberry_for_Side_Bowel.png",
		"funnel": "fc_batter_strawberry_for_Funnel.png"},
	2: {"stream": "fc_batter_stream_car1-4.png",
		"side": "fc_batter_caramel_for_Side_Bowel.png",
		"funnel": "fc_batter_caramel_for_Funnel.png"},
	3: {"stream": "fc_batter_stream_choc1-4.png",
		"side": "fc_batter_choc_for_Side_Bowel.png",
		"funnel": "fc_batter_choc_for_Funnel.png"},
}

## SpriteSheetView frame (64, 144, 79, 219), 4 columns x 1 row (0x9858C,
## bits 0x42800000/0x43100000/0x429E0000/0x435B0000). The strip is 316x219,
## so each cell is exactly 79x219.
const STREAM_RECT := Rect2(64, 144, 79, 219)
const STREAM_COLS := 4

## Tilt clamp: [-0.785398163, -0.0] rad (0x98D98). Reaching the -45 deg end
## latches the pour.
const TILT_LIMIT := -0.785398163
## PORT CHOICE: time for the held bowl to reach -45 deg. The
## original's rate came from the device roll through the low-pass filter;
## 0.35s matches the remap used on the other pour screens.
const TILT_SECONDS := 0.35
## startBatterFlowForDuration: is always called with 3.0 (0x98D98).
const FLOW_SECONDS := 3.0
## Stream fade-in 0.2s linear (double (0x9999999A, 0x3FC99999), 0x98158).
const STREAM_FADE_IN := 0.2
## Tick delays 0.2 / 0.5 / 0.8 (doubles in 0x98158).
const TICK_TIMES := [0.2, 0.5, 0.8]
## stopBatterFlow crossfade and levelTheBowl delay/duration: 0.5s linear.
const END_FADE := 0.5

var _batter := 0
var _bowl: Node2D
var _stream: Sprite2D
var _stream_frame := 0
var _batter_side: CanvasItem
var _batter_final: CanvasItem
var _holding := false
var _latched := false
var _tilt_tween: Tween
## The flow's own tweens (stream fade-in, end crossfade, levelling) and a
## generation counter that retires its pending timers on a return.
var _flow_tweens: Array[Tween] = []
var _flow_gen := 0


func on_enter() -> void:
	# viewDidLoad built the badge before any viewWillAppear content.
	_build_skip()
	_batter = int(GameState.custom_categories.get("batter", 0))
	var art: Dictionary = ART.get(_batter, ART[0])

	# viewDidLoad: batterSide / batterFinal get the batter's art. The scene
	# ships the nib's strawberry placeholders; swap per batter.
	_batter_side = outlet("batterSide") as CanvasItem
	if _batter_side is Sprite2D:
		(_batter_side as Sprite2D).texture = _tex(art["side"])
	_batter_final = outlet("batterFinal") as CanvasItem
	if _batter_final is Sprite2D:
		(_batter_final as Sprite2D).texture = _tex(art["funnel"])

	_recenter_bowl()
	_build_stream(art["stream"])
	_view_will_appear()


## UINavigationController keeps this controller alive under fcFry (Nav.gd's
## opt-in). On back viewWillAppear: runs again and RE-ARMS the pour: the
## bowl's batter is back (alpha 1), the funnel's gone (alpha 0),
## bowlTiltedAt45Degree = NO, next hidden -- so the batter can be poured
## again, as on the device.
func keeps_state_on_push() -> bool:
	return true


## INFERRED (port limit): stopBatterFlow / levelTheBowl are
## performSelector:afterDelay: calls the original never cancels, so a flow
## cut short by the skip badge finished while covered: bowl level, stream
## faded out. The port retires those timers on the way out of the tree and
## applies their end state here. The bowl is levelled unconditionally:
## viewWillDisappear: zeroed the tilt filter, which then rises from 0.
func on_resume() -> void:
	_flow_gen += 1
	_kill_flow_tweens()
	if _tilt_tween != null and _tilt_tween.is_valid():
		_tilt_tween.kill()
	_holding = false
	if _bowl != null:
		_bowl.rotation = 0.0
	if _stream != null:
		_stream.modulate.a = 0.0
	_view_will_appear()


## viewWillAppear: (0x98B18): batterSide alpha 1, batterFinal alpha 0, one
## SpriteSheetView tick, bowlTiltedAt45Degree = NO, next hidden, instIV
## shown, startAccelerometer, buySkip unhidden.
func _view_will_appear() -> void:
	if _batter_side != null:
		_batter_side.modulate.a = 1.0
	if _batter_final != null:
		_batter_final.modulate.a = 0.0
	_tick_stream()
	_latched = false
	var n := outlet("nextButton")
	if n != null and n != self:
		(n as CanvasItem).visible = false
	# viewWillAppear: only unhides instIV -- fcPourBatterVC has NO
	# changeInstruction: method, so its banner never slides in. Cancel the
	# base class's generic first-appearance slide (Screen._place_instruction).
	var iv := outlet("instIV") as Node2D
	if iv != null:
		if _instruction_tween != null and _instruction_tween.is_valid():
			_instruction_tween.kill()
		if _instruction_home_set:
			iv.position = _instruction_home
		iv.visible = true
		iv.modulate.a = 1.0
	if _skip_button != null:
		_skip_button.visible = true


func _kill_flow_tweens() -> void:
	for t: Tween in _flow_tweens:
		if t != null and t.is_valid():
			t.kill()
	_flow_tweens.clear()


func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


## The generated bowl node's origin is the nib frame's top-left; UIKit's
## setTransform: rotates about the frame centre. Move the node to the centre
## and shift its children back so the pivot matches.
func _recenter_bowl() -> void:
	var b := outlet("bowl")
	if not (b is Node2D):
		return
	_bowl = b as Node2D
	var half := BOWL_FRAME.size * 0.5
	_bowl.position = BOWL_FRAME.position + half
	for child in _bowl.get_children():
		if child is Node2D:
			(child as Node2D).position -= half


## The stream: one 79x219 cell of the 4-frame strip, clipped exactly as the
## SpriteSheetView clipped its content, sitting between funnelBack and
## batterFinal (insertSubview:aboveSubview:funnelBack, 0x9858C), alpha 0.
func _build_stream(strip_file: String) -> void:
	var strip := _tex(strip_file)
	if strip == null:
		return
	var cell := Vector2(strip.get_size().x / float(STREAM_COLS),
		float(strip.get_size().y))
	var atlas := AtlasTexture.new()
	atlas.atlas = strip
	atlas.region = Rect2(Vector2.ZERO, cell)
	_stream = Sprite2D.new()
	_stream.texture = atlas
	_stream.centered = false
	_stream.position = STREAM_RECT.position
	_stream.modulate.a = 0.0
	var back := outlet("funnelBack")
	if back != null and back != self and back.get_parent() != null:
		back.get_parent().add_child(_stream)
		back.get_parent().move_child(_stream, back.get_index() + 1)
	else:
		add_child(_stream)


## -[SpriteSheetView tick] (0x47910): show currentFrameIdx, then increment,
## wrapping at columns * rows.
func _tick_stream() -> void:
	if _stream == null:
		return
	var atlas := _stream.texture as AtlasTexture
	var cell := atlas.region.size
	atlas.region = Rect2(Vector2(cell.x * _stream_frame, 0), cell)
	_stream_frame = (_stream_frame + 1) % STREAM_COLS


# -- the tilt (press-and-hold remap of 0x98D98) -----------------------

func _unhandled_input(event: InputEvent) -> void:
	if _latched or _bowl == null:
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_set_holding((event as InputEventMouseButton).pressed)


func _set_holding(value: bool) -> void:
	if _holding == value:
		return
	_holding = value
	if _tilt_tween != null and _tilt_tween.is_valid():
		_tilt_tween.kill()
	if value:
		_tilt_tween = create_tween()
		_tilt_tween.tween_property(_bowl, "rotation", TILT_LIMIT,
			TILT_SECONDS * absf(TILT_LIMIT - _bowl.rotation) / absf(TILT_LIMIT))
		_tilt_tween.tween_callback(_latch)
	else:
		# Original: the bowl follows the filtered angle back up as long as
		# the latch has not fired.
		_tilt_tween = create_tween()
		_tilt_tween.tween_property(_bowl, "rotation", 0.0,
			TILT_SECONDS * absf(_bowl.rotation) / absf(TILT_LIMIT))


## The angle hit -45 deg: bowlTiltedAt45Degree latches and the flow starts
## (0x98D98). From here the bowl no longer follows input.
func _latch() -> void:
	if _latched:
		return
	_latched = true
	_start_batter_flow(FLOW_SECONDS)


# -- the flow ---------------------------------------------------------

## startBatterFlowForDuration: (0x98158).
func _start_batter_flow(duration: float) -> void:
	Audio.loop("fc_batter_pour_loop")
	var gen := _flow_gen
	if _stream != null:
		var tw := create_tween()
		tw.tween_property(_stream, "modulate:a", 1.0,
			STREAM_FADE_IN).set_trans(Tween.TRANS_LINEAR)
		_flow_tweens.append(tw)
	for t: float in TICK_TIMES:
		get_tree().create_timer(t).timeout.connect(func() -> void:
			if gen == _flow_gen:
				_tick_stream())
	get_tree().create_timer(duration).timeout.connect(_stop_batter_flow.bind(gen))


## stopBatterFlow (0x98024): sound off; stream and bowl batter fade out while
## the funnel batter fades in, 0.5s linear; levelTheBowl 0.5s later.
func _stop_batter_flow(gen: int) -> void:
	if not is_inside_tree() or gen != _flow_gen:
		return
	Audio.stop("fc_batter_pour_loop")
	var tw := create_tween().set_parallel(true)
	_flow_tweens.append(tw)
	if _stream != null:
		tw.tween_property(_stream, "modulate:a", 0.0, END_FADE) \
			.set_trans(Tween.TRANS_LINEAR)
	if _batter_side != null:
		tw.tween_property(_batter_side, "modulate:a", 0.0, END_FADE) \
			.set_trans(Tween.TRANS_LINEAR)
	if _batter_final != null:
		tw.tween_property(_batter_final, "modulate:a", 1.0, END_FADE) \
			.set_trans(Tween.TRANS_LINEAR)
	get_tree().create_timer(END_FADE).timeout.connect(_level_the_bowl.bind(gen))


## levelTheBowl (0x97F50): back to 0 deg over 0.5s linear, and the next
## button slides in immediately (finishedPouringBatter 0x97F40).
func _level_the_bowl(gen: int) -> void:
	if not is_inside_tree() or gen != _flow_gen:
		return
	if _bowl != null:
		var tw := create_tween()
		tw.tween_property(_bowl, "rotation", 0.0, END_FADE) \
			.set_trans(Tween.TRANS_LINEAR)
		_flow_tweens.append(tw)
	show_next_button()   # 0x97DF0, the standard +500/0.25 slide


# -- hand-off ---------------------------------------------------------

## nextClick: (0x99338): stop the loop, button_press, push fcFryBatterVC
## initWithBatterID:. The carrier already holds the batter id.
func _on_nextClick() -> void:
	Audio.stop("fc_batter_pour_loop")
	Audio.play("button_press")
	GameState.custom_categories = {"batter": _batter}
	Nav.next()


## skipClick: (0x9941C) just calls nextClick:. Its sender is the nib's
## "Debug Skip" UIRoundedRectButton (200, 369, 120, 40), alpha 0.3, which
## ships UIHidden=YES and has no outlet, so nothing ever shows it -- the
## generated scene hides it too, and it is unreachable. (An older reading
## of "never hidden" came from swapped NIBArchive bool tags.)
func _on_skipClick() -> void:
	_on_nextClick()


func _on_backClick() -> void:
	# backClick: (0x992A4) stops fc_batter_pour_loop before popping.
	Audio.stop("fc_batter_pour_loop")
	Audio.play("button_press")
	Nav.back()


## viewWillDisappear: (0x98C90): zero the low-pass filter state and stop the
## accelerometer -- the hold remap lets go. viewDidDisappear: is super only.
## The pour loop is stopped by nextClick:/backClick:; stopping it here too
## changes nothing on those paths. Retiring the flow timers is the port's
## side of on_resume's INFERRED note.
func on_exit() -> void:
	_holding = false
	if _tilt_tween != null and _tilt_tween.is_valid():
		_tilt_tween.kill()
	_flow_gen += 1
	Audio.stop("fc_batter_pour_loop")


# -- skip consumable ----------------------------------------------------

## viewDidLoad's ConsumableButton and the init's Consumable (see header).
func _build_skip() -> void:
	_skip = ConsumableScript.new(SKIP_KEY, SKIP_NAME, SKIP_COST)
	_skip.set("first_time_message", SKIP_MESSAGE)
	_skip.set("on_purchased", _on_skip_purchased)
	_skip.set("on_failed", func() -> void:
		show_alert(ConsumableScript.NO_COINS_MESSAGE, ["OK"], Callable()))
	var b: TextureButton = ConsumableButtonScript.new()
	b.name = "buySkip"
	b.call("setup", SKIP_ART, 0, -25, SKIP_COST, 65, 3)
	b.position = SKIP_CENTER - b.size * 0.5
	b.pressed.connect(_on_buyClick)
	add_child(b)
	_skip_button = b


## buyClick: -- "store" sound, purchaseConsumable.
func _on_buyClick() -> void:
	Audio.play("store")
	_skip.call("purchase", self)


## consumablePurchased: -> nextClick: (see header).
func _on_skip_purchased(_free: bool) -> void:
	_on_nextClick()
