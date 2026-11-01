# Port of MaskedIV, the original's most-used view primitive.
#
# MaskedIV held a base image and a CGImage mask and composited them in
# drawRect: via CGContextClipToMask. It appears on ~20 screens and is behind
# every pour, fill, gauge and progressive reveal in the game.
#
# This adds `fill`, which the original achieved by moving the mask view between
# two anchor points (ipPourViewController interpolates getMaskStart:/getMaskEnd:
# from ipMaskPoints.plist). Expressing it as a normalised 0..1 boundary means
# one node covers both the static shape mask and the animated fill.
#
#   var cup := MaskedSprite2D.new()
#   cup.texture = Assets.texture("lsu_liquid.png")
#   cup.mask    = Assets.texture("lsu_cup_mask_full.png")
#   cup.mask_mode = MaskedSprite2D.MaskMode.LUMINANCE   # grayscale mask
#   cup.fill = 0.0
#   create_tween().tween_property(cup, "fill", 1.0, 2.0)

@tool
extends Sprite2D

const SHADER := preload("res://core/masked_sprite.gdshader")

enum MaskMode {
	## Mask's alpha channel selects what shows (RGBA masks).
	ALPHA = 0,
	## Inverted luminance selects what shows -- black shows through. This is
	## how Core Graphics treats a grayscale image mask.
	LUMINANCE = 1,
}

enum FillDir { UP = 0, DOWN = 1, RIGHT = 2, LEFT = 3 }


@export var mask: Texture2D:
	set(value):
		mask = value
		_apply()

@export var mask_mode: MaskMode = MaskMode.ALPHA:
	set(value):
		mask_mode = value
		_apply()

## Visible fraction along fill_dir. 1.0 disables the fill boundary.
@export_range(0.0, 1.0) var fill: float = 1.0:
	set(value):
		fill = clampf(value, 0.0, 1.0)
		_apply()

@export var fill_dir: FillDir = FillDir.UP:
	set(value):
		fill_dir = value
		_apply()

## Softens the fill edge. 0 matches the original's hard clip.
@export_range(0.0, 0.2) var fill_feather: float = 0.0:
	set(value):
		fill_feather = value
		_apply()

## Apply the mask upside down. From the original binary: -[MaskedIV drawRect:]
## (0x46E68) calls CGContextClipToMask with the CGImageMask it built in
## initWithBaseImg:andMaskImg: (0x46CE0) inside UIKit's flipped context and
## never flips the CTM, so the original draws every mask vertically
## mirrored. Seen on the phone on ccbSelectChocolate (the pot mask's bowl
## sits at the TOP of the view, hiding the pile until it rises). Symmetric
## masks are unaffected; check each asymmetric one on hardware before
## flipping it.
@export var mask_flip_v: bool = false:
	set(value):
		mask_flip_v = value
		_apply()


func _ready() -> void:
	_apply()


func _apply() -> void:
	if material == null or not (material is ShaderMaterial) \
			or (material as ShaderMaterial).shader != SHADER:
		var m := ShaderMaterial.new()
		m.shader = SHADER
		material = m
	var sm := material as ShaderMaterial
	sm.set_shader_parameter("mask_tex", mask)
	sm.set_shader_parameter("mask_mode", int(mask_mode))
	sm.set_shader_parameter("fill", fill)
	sm.set_shader_parameter("fill_dir", int(fill_dir))
	sm.set_shader_parameter("fill_feather", fill_feather)
	sm.set_shader_parameter("mask_flip_v", mask_flip_v)


## Guess the encoding from the image's channels. Grayscale/RGB masks with no
## usable alpha are Core Graphics image masks; anything with real alpha is not.
static func detect_mask_mode(tex: Texture2D) -> MaskMode:
	if tex == null:
		return MaskMode.ALPHA
	var img := tex.get_image()
	if img == null:
		return MaskMode.ALPHA
	return MaskMode.ALPHA if img.detect_alpha() != Image.ALPHA_NONE \
		else MaskMode.LUMINANCE
