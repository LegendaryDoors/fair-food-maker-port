# UIScrollView's scroll indicator (iOS 6.1.3 UIKit), for the port's scroll views.
#
# Constants read from the iPhone 4's UIKit (iOS 6.1.3):
#   art  UIScrollerIndicatorDefault.png (14 px @2x) / Black / White (10 px @2x),
#        stretchable at half its size (CreateScrollIndicator 0x32FA1EA0)
#   length = max(36, visible fraction * track)      (_adjustScrollerIndicators:
#   inset  1 pt (default style) / 2 pt (black, white) from the edge  0x32FA08F0)
#   fade out over 0.5 s after scrolling stops (_hideScrollIndicators 0x32FB62CC)
#   flashScrollIndicators holds 1.0 s before fading
# Art lives in the import cache's uikit/ folder (from the player's
# Shared@2x.artwork, core/import/UIKitArtwork.gd; absent -> no indicator art).
# The port is 1x, so the @2x art is drawn at half scale.
#
# INFERRED: while rubber-banding past an edge the indicator shrinks by the
# overshoot (never below 36 - UIKit's minimum also clamps there) and stays
# pinned to that edge. The exact shrink curve was not read.
#
# Use: add as a child of the node the scroll view's content is clipped by,
# set `track` to the scroll view's frame in that node's coordinates, then call
# `update(offset, min_offset, max_offset, view_len)` every time the offset
# changes, `begin()` when dragging starts and `end()` when the view stops.

extends Node2D

enum Style { DEFAULT, BLACK, WHITE }

const ART := {
	Style.DEFAULT: "UIScrollerIndicatorDefault.png",
	Style.BLACK: "UIScrollerIndicatorBlack.png",
	Style.WHITE: "UIScrollerIndicatorWhite.png",
}
const MIN_LENGTH := 36.0
const FADE := 0.5
const FLASH_HOLD := 1.0

var vertical := true
var style: int = Style.DEFAULT
## The scroll view's frame, in this node's parent coordinates.
var track := Rect2(0, 0, 320, 480)

var _patch: NinePatchRect
var _tween: Tween
var _thickness := 7.0


func _ready() -> void:
	var tex: Texture2D = Assets.uikit_texture(ART[style])
	_patch = NinePatchRect.new()
	_patch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if tex != null:
		_patch.texture = tex
		var half := int(tex.get_width() / 2)
		_patch.patch_margin_left = half
		_patch.patch_margin_right = tex.get_width() - half - 1 if tex.get_width() - half - 1 > 0 else half
		_patch.patch_margin_top = half
		_patch.patch_margin_bottom = _patch.patch_margin_right
		_thickness = tex.get_width() * 0.5
	_patch.scale = Vector2(0.5, 0.5)
	add_child(_patch)
	modulate.a = 0.0


func _inset() -> float:
	return 1.0 if style == Style.DEFAULT else 2.0


## Lay the indicator out for a content offset along this axis.
func update(offset: float, min_offset: float, max_offset: float, view_len: float) -> void:
	if _patch == null:
		return
	var content_len := view_len + (max_offset - min_offset)
	var inset := _inset()
	var track_len := (track.size.y if vertical else track.size.x) - 2.0 * inset
	var length := maxf(MIN_LENGTH, track_len * view_len / maxf(content_len, 1.0))
	var over := 0.0
	if offset < min_offset:
		over = min_offset - offset
	elif offset > max_offset:
		over = offset - max_offset
	length = maxf(MIN_LENGTH, length - over)            # INFERRED shrink
	var span := maxf(track_len - length, 0.0)
	var t := 0.0
	if max_offset > min_offset:
		t = clampf((offset - min_offset) / (max_offset - min_offset), 0.0, 1.0)
	var along := inset + span * t
	if vertical:
		position = Vector2(track.end.x - inset - _thickness, track.position.y + along)
		_patch.size = Vector2(_thickness, length) * 2.0
	else:
		position = Vector2(track.position.x + along, track.end.y - inset - _thickness)
		_patch.size = Vector2(length, _thickness) * 2.0


## Scrolling started (drag or programmatic): show at once.
func begin() -> void:
	if _tween != null:
		_tween.kill()
	modulate.a = 1.0


## Scrolling stopped: fade out over 0.5 s.
func end() -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 0.0, FADE)


## flashScrollIndicators: show, hold 1.0 s, then fade.
func flash() -> void:
	if _tween != null:
		_tween.kill()
	modulate.a = 1.0
	_tween = create_tween()
	_tween.tween_interval(FLASH_HOLD)
	_tween.tween_property(self, "modulate:a", 0.0, FADE)
