# The stirring implement of the five stir screens: the spoon, or one of the
# two mixer upgrades once bought.
#
# Read from -[ccbStirIngredients showSpoon] (0x1CD28); the
# other four stir screens' showSpoon bodies name the same images and numbers:
#   pink mixer owned  -> image Mixer_Upgrade_Pink_Off, animationImages
#                        [Pink_Off, Pink_On], animationDuration 0.1,
#                        transform identity, frame resized to the image
#   white mixer owned -> Mixer_Upgrade_Off / [Off, On], likewise
#   neither           -> cd_spoon.png, no animation images, rotation 0.5236
# then, for all three: unhidden, snapTime 0.25, centre = origCenter.
# The spoon-tip SSEmitter (tag 326, White_Electric_Hand_Mixer_PS_1..3 tinted
# with the food colour) is `tip_emitter` (core/particles/SSEmitter.gd); the
# stir screens configure, start and stop it.
# draggableTouchBegan: starts the frame animation, draggableTouchEnded: stops
# it; a UIImageView animation with two frames and duration 0.1 shows each
# frame for 0.05 s.

extends Node2D

enum Kind { SPOON = 0, WHITE_MIXER = 1, PINK_MIXER = 2 }

const SPOON_ART := "cd_spoon.png"
const SPOON_ROTATION := 0.5236
const MIXER_ART := {
	Kind.WHITE_MIXER: ["Mixer_Upgrade_Off.png", "Mixer_Upgrade_On.png"],
	Kind.PINK_MIXER: ["Mixer_Upgrade_Pink_Off.png", "Mixer_Upgrade_Pink_On.png"],
}
const ANIMATION_DURATION := 0.1     # setAnimationDuration: (double 0.1)
const SNAP_SECONDS := 0.25          # setSnapTime: 0x3E800000

var home := Vector2.ZERO            # DraggableIV origCenter
var kind: int = Kind.SPOON
var size := Vector2.ZERO            # the current image's size
var animating := false:
	set(value):
		animating = value
		_frame = 0
		_frame_clock = 0.0
		_apply_frame()

var _art: Sprite2D
## The spoon-tip SSEmitter (viewWithTag:326): created by the stir screens'
## viewDidLoad as a 1x1 subview of the spoon at spoon-bounds centre (10,130),
## drawn above the tool art and moving with it. Only caStir / ccbStir
## configure and start it, and only for the two mixers; cdStir configures it
## but never starts it; dicStir never makes it.
## Screens: SSEmitterConfigs.apply(tool.tip_emitter, "<screen>.spoonTip", colour)
## in their showSpoon path, then tip_emitter.start()/stop().
var tip_emitter: Node2D
const SSEmitter := preload("res://core/particles/SSEmitter.gd")
var _frames: Array[Texture2D] = []
var _frame := 0
var _frame_clock := 0.0


static func _tex(file: String) -> Texture2D:
	return Assets.texture(file)


func _ready() -> void:
	if _art == null:
		_art = Sprite2D.new()
		add_child(_art)
	_ensure_tip()
	show_kind(kind)


func _ensure_tip() -> void:
	if tip_emitter == null:
		# After _art, so it draws above the tool art.
		tip_emitter = SSEmitter.attach(self, Vector2(1, 1))
		tip_emitter.name = "SpoonTipEmitter"


## showSpoon: rebuild for the owned tool and return home.
func show_kind(k: int) -> void:
	kind = k
	if _art == null:
		_art = Sprite2D.new()
		add_child(_art)
	_frames.clear()
	if MIXER_ART.has(k):
		for f: String in MIXER_ART[k]:
			var t := _tex(f)
			if t != null:
				_frames.append(t)
		rotation = 0.0
	else:
		var t := _tex(SPOON_ART)
		if t != null:
			_frames.append(t)
		rotation = SPOON_ROTATION
	_frame = 0
	_apply_frame()
	size = _frames[0].get_size() if not _frames.is_empty() else Vector2.ZERO
	_ensure_tip()
	# StirTool's origin is the art centre; the UIKit emitter sits at
	# spoon-bounds (9.5,129.5) (1x1 frame centred on (10,130)).
	tip_emitter.position = Vector2(9.5, 129.5) - size * 0.5
	position = home
	visible = true


func _apply_frame() -> void:
	if _art != null and not _frames.is_empty():
		_art.texture = _frames[_frame % _frames.size()]


func _process(delta: float) -> void:
	if not animating or _frames.size() < 2:
		return
	_frame_clock += delta
	var per_frame := ANIMATION_DURATION / float(_frames.size())
	while _frame_clock >= per_frame:
		_frame_clock -= per_frame
		_frame = (_frame + 1) % _frames.size()
		_apply_frame()


## The UIKit frame: the rotated image's bounding box about the centre.
func frame_rect() -> Rect2:
	var c := absf(cos(rotation))
	var s := absf(sin(rotation))
	var half := Vector2(size.x * c + size.y * s, size.x * s + size.y * c) * 0.5
	return Rect2(position - half, half * 2.0)


func hit(p: Vector2) -> bool:
	return Rect2(-size * 0.5, size).has_point(to_local(p))


func snap_home() -> void:
	create_tween().tween_property(self, "position", home, SNAP_SECONDS) \
		.set_trans(Tween.TRANS_LINEAR)
