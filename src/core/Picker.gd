# Horizontal thumbnail strip, the game's tap-to-select picker.
#
# Eight of the make steps are a scroll view of options that swaps a tint or a
# texture on selection. In the original these were UIScrollViews populated in
# code; the nib carries only the empty scroll view and its frame, which is why
# this takes a rect and fills it.
#
#   var p := Picker.new()
#   p.setup(Rect2(0, 0, 320, 100), items)   # items: [{texture, color, id}]
#   p.selected.connect(_on_pick)

extends Control

signal selected(index: int, item: Dictionary)

const THUMB_PAD := 6.0

var items: Array = []
var selected_index := -1

var _row: HBoxContainer
var _buttons: Array[Button] = []


func setup(rect: Rect2, new_items: Array) -> void:
	items = new_items
	position = rect.position
	size = rect.size
	_build()


func _build() -> void:
	for c in get_children():
		c.queue_free()
	_buttons.clear()

	var scroll := ScrollContainer.new()
	scroll.size = size
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", int(THUMB_PAD))
	scroll.add_child(_row)

	for i in items.size():
		var item: Dictionary = items[i]
		var b := Button.new()
		b.custom_minimum_size = Vector2(size.y - THUMB_PAD * 2, size.y - THUMB_PAD * 2)
		b.flat = true
		b.icon = item.get("texture")
		b.expand_icon = true
		if item.has("color"):
			b.self_modulate = item["color"]
		b.tooltip_text = str(item.get("id", i))
		var idx := i
		b.pressed.connect(func() -> void: _pick(idx))
		_row.add_child(b)
		_buttons.append(b)


func _pick(index: int) -> void:
	if index < 0 or index >= items.size():
		return
	selected_index = index
	Audio.play("button_press")
	_refresh_highlight()
	selected.emit(index, items[index])


## Selection feedback: the original brightened the chosen swatch.
func _refresh_highlight() -> void:
	for i in _buttons.size():
		_buttons[i].modulate = Color(1, 1, 1) if i == selected_index \
			else Color(0.62, 0.62, 0.62)
