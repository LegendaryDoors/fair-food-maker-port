# First launch: asks for the player's own Fair Food Maker 1.27 .ipa and
# imports it (core/import/Importer.gd) into the user data folder.
#
# Shown by Boot while Assets.is_ready() is false. This is the port's own
# screen, not the game's -- none of the game's art exists yet when it shows --
# so it is plain Godot UI laid out in the 320x480 design space (3x on screen).
#
#   * drop the .ipa on the window, or choose it with the system file dialog
#   * the import also downloads the iOS 6 pop-up look (core/import/
#     IOS6Look.gd, ~7 MB from the Internet Archive); one line under the bar
#     says so and how far it is. If the IPA part finishes first the screen
#     waits for it (up to Importer.look_wait_ms, 30 s), showing its progress.
#     If it fails the import still completes and Boot retries on a later
#     launch.
#   * a Shared@2x.artwork dropped on the window is still taken, unasked, as
#     the offline way to the same look (before the import: no download; during
#     it: used if the download fails). Nothing on screen mentions it.
#   * progress bar + status while the import runs on a worker thread
#   * plain-language errors (not an .ipa / not Fair Food Maker / wrong
#     version, naming the version found); the player just tries again
#
# Emits `finished` once the import is in place; Boot then starts the game.

extends Control

signal finished

const Importer := preload("res://core/import/Importer.gd")

const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans", "Liberation Sans", "Arial"]
const BG := Color("fff6e6")
const INK := Color("3b2a1d")
const MUTED := Color("7a6656")
const ACCENT := Color("c8372d")
const ERROR := Color("b3261e")
const ICON_SIZE := 72
const OK_GREEN := Color("2e7d32")

enum State { IDLE, IMPORTING, DONE }

# The download line. Plain words; no dashes.
## Nothing is said about the pop-up style until it is actually downloading.
const LOOK_IDLE := ""
const LOOK_DONE := "Got the classic iPhone pop-up style."
const LOOK_FAILED := "Couldn't download the classic pop-up style. The game will try again next time."

var state := State.IDLE

var _importer: RefCounted
var _thread: Thread
## Passed to the importer's look_options (tests only: a dead address, a
## failing server, a slow line).
var look_options := {}

var _artwork := ""            # validated Shared@2x.artwork path, or ""
var _artwork_pending := false # dropped while the IPA import was running
var _look_seen := ""          # last download state shown

var _ipa_button: Button
var _look_line: Label         # the iOS 6 look: what will happen / how far / result
var _progress_box: VBoxContainer
var _bar: ProgressBar
var _status: Label
var _error: Label
var _dialog: FileDialog


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = _make_theme()
	_build()
	get_window().files_dropped.connect(_on_files_dropped)


func _exit_tree() -> void:
	# Closing the window mid-import: stop at the next file and wait, so the
	# thread never outlives the tree. The previous cache (if any) is untouched.
	if _thread != null and _thread.is_started():
		if _importer != null:
			_importer.cancel()
		_thread.wait_to_finish()
		_thread = null


# -- input ----------------------------------------------------------------------

func _on_files_dropped(files: PackedStringArray) -> void:
	var ipa := ""
	for f in files:
		if f.get_extension().to_lower() == "artwork":
			_take_artwork(f)
		elif ipa == "":
			ipa = f
	if ipa != "":
		_take_ipa(ipa)


func _take_ipa(path: String) -> void:
	if state != State.IDLE:
		return
	if DirAccess.dir_exists_absolute(path):
		_show_error("That's a folder. Drop the .ipa file itself.")
		return
	_start_import(path)


## A dropped Shared@2x.artwork: taken without a word (the download line just
## goes away, since nothing will be downloaded). Only a file that is not one
## gets a reply, as the player clearly meant something by it.
func _take_artwork(path: String) -> void:
	if state == State.DONE:
		return
	var err := Importer.check_artwork(path)
	if err != "":
		_set_look_line(err, ERROR)
		return
	_artwork = path
	if state == State.IMPORTING:
		_artwork_pending = true          # used after the import if the download failed
	else:
		_set_look_line("", MUTED)


func _choose() -> void:
	_dialog.filters = PackedStringArray(["*.ipa ; iPhone app (.ipa)"])
	_dialog.title = "Choose your Fair Food Maker .ipa"
	_dialog.popup_centered()


func _on_dialog_file(path: String) -> void:
	_take_ipa(path)


# -- import -----------------------------------------------------------------------

func _start_import(ipa: String) -> void:
	state = State.IMPORTING
	_error.visible = false
	_ipa_button.disabled = true
	_progress_box.visible = true
	_bar.value = 0.0
	_status.text = "Opening %s…" % ipa.get_file()
	_artwork_pending = false
	_look_seen = ""
	_importer = Importer.new()
	_importer.set("download_look", _artwork == "")
	_importer.set("look_options", look_options)
	_thread = Thread.new()
	_thread.start(_work.bind(ipa, _artwork))


## Worker thread.
func _work(ipa: String, artwork: String) -> void:
	var r: Dictionary = _importer.run(ipa, artwork,
		func(f: float, text: String) -> void: _on_progress.call_deferred(f, text))
	_on_done.call_deferred(r, artwork)


## Worker thread, for an artwork dropped while the IPA import ran.
func _work_uikit(artwork: String) -> void:
	var r: Dictionary = _importer.import_uikit(artwork)
	_on_uikit_done.call_deferred(r)


func _on_progress(f: float, text: String) -> void:
	_bar.value = f
	_status.text = text


func _process(_delta: float) -> void:
	if state == State.IMPORTING and _importer != null:
		_show_look(_importer.call("look_state"))


## The download line, from the importer's look_state().
func _show_look(s: Dictionary) -> void:
	match str(s.get("state", "off")):
		"fetching":
			_set_look_line("Getting the classic iPhone pop-up style: %.1f of %.1f MB"
				% [int(s.bytes) / 1e6, maxi(int(s.total), int(s.bytes)) / 1e6], MUTED)
		"done":
			_set_look_line(LOOK_DONE, OK_GREEN)
		"failed":
			if _look_seen != "failed":
				_set_look_line(LOOK_FAILED, ERROR)
	_look_seen = str(s.get("state", "off"))


func _set_look_line(text: String, color: Color) -> void:
	_look_line.text = text
	_look_line.visible = text != ""
	_look_line.add_theme_color_override("font_color", color)


func _on_done(r: Dictionary, used_artwork: String) -> void:
	_thread.wait_to_finish()
	_thread = null
	if not r.get("ok", false):
		state = State.IDLE
		_ipa_button.disabled = false
		_progress_box.visible = false
		_set_look_line("" if _artwork != "" else LOOK_IDLE, MUTED)
		if not r.get("cancelled", false):
			_show_error(str(r.get("error", "The import failed.")))
		return
	for w: String in r.get("warnings", []):
		push_warning("import: " + w)
	if r.has("look"):
		_show_look(_importer.call("look_state"))
	if not r.get("uikit", false) and _artwork_pending and _artwork != "" and _artwork != used_artwork:
		_status.text = "Adding the iOS 6 alert look…"
		_thread = Thread.new()
		_thread.start(_work_uikit.bind(_artwork))
		return
	_finish(r.get("uikit_error", "") != "")


func _on_uikit_done(r: Dictionary) -> void:
	_thread.wait_to_finish()
	_thread = null
	if r.get("ok", false):
		_set_look_line(LOOK_DONE, OK_GREEN)
		_finish(false)
	else:
		_set_look_line(LOOK_FAILED, ERROR)
		_finish(true)


## linger: leave the download's failure line up long enough to be read.
func _finish(linger: bool) -> void:
	state = State.DONE
	_bar.value = 1.0
	_status.text = "All set! Starting the game…"
	await get_tree().create_timer(3.0 if linger else 0.8).timeout
	finished.emit()


func _show_error(text: String) -> void:
	_error.text = text + "\n\nDrop or choose another file to try again."
	_error.visible = true


# -- layout -----------------------------------------------------------------------

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	# Everything fits 320x480 in every state; the scroll
	# container is only a guard for an unusually long message (a deep path).
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(col)

	# The port's own icon, rendered from the SVG at on-screen size (the window
	# shows this 320x480 screen at 3x) so it stays sharp.
	var icon := TextureRect.new()
	icon.texture = _icon_texture(ICON_SIZE)
	icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(icon)

	var title := _label("Fair Food Maker Port", 20, ACCENT, true)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	var intro := _label("You need your own copy of Fair Food Maker 1.27 (an .ipa file).", 10, INK)
	intro.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(intro)

	# The drop zone.
	var zone := PanelContainer.new()
	zone.add_theme_stylebox_override("panel", _box(Color.WHITE, ACCENT, 2, 10))
	col.add_child(zone)
	var zcol := VBoxContainer.new()
	zcol.add_theme_constant_override("separation", 6)
	zone.add_child(zcol)
	var drop := _label("Drop your Fair Food Maker 1.27 .ipa on this window", 12, INK, true)
	drop.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zcol.add_child(drop)
	var or_l := _label("or", 10, MUTED)
	or_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zcol.add_child(or_l)
	_ipa_button = _button("Choose .ipa…", 12)
	_ipa_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_ipa_button.custom_minimum_size.x = 150
	_ipa_button.pressed.connect(_choose)
	zcol.add_child(_ipa_button)

	# Progress (while importing) and errors share the space under the zone.
	_progress_box = VBoxContainer.new()
	_progress_box.add_theme_constant_override("separation", 4)
	_progress_box.visible = false
	col.add_child(_progress_box)
	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.show_percentage = false
	_bar.custom_minimum_size.y = 12
	_bar.add_theme_stylebox_override("background", _box(Color("ead9c4"), Color.TRANSPARENT, 0, 0))
	_bar.add_theme_stylebox_override("fill", _box(ACCENT, Color.TRANSPARENT, 0, 0))
	_progress_box.add_child(_bar)
	_status = _label("", 10, INK)
	_progress_box.add_child(_status)

	_error = _label("", 10, ERROR, true)
	_error.visible = false
	col.add_child(_error)

	# The iOS 6 pop-up look, downloaded alongside the import.
	_look_line = _label(LOOK_IDLE, 9, MUTED)
	_look_line.visible = LOOK_IDLE != ""
	col.add_child(_look_line)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)

	var where := _label("The imported files are kept in:\n%s" % _friendly_path(
		ProjectSettings.globalize_path("user://")), 8, MUTED)
	where.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	col.add_child(where)

	_dialog = FileDialog.new()
	_dialog.use_native_dialog = true
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.size = Vector2i(310, 440)     # the built-in fallback, inside the 320x480 window
	_dialog.file_selected.connect(_on_dialog_file)
	add_child(_dialog)


func _label(text: String, size: int, color: Color, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_font_override("font", _font(700))
	return l


func _button(text: String, size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_font_override("font", _font(700))
	for s: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(s, Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.6))
	b.add_theme_stylebox_override("normal", _box(ACCENT, Color.TRANSPARENT, 0, 5, 4))
	b.add_theme_stylebox_override("hover", _box(ACCENT.lightened(0.12), Color.TRANSPARENT, 0, 5, 4))
	b.add_theme_stylebox_override("pressed", _box(ACCENT.darkened(0.15), Color.TRANSPARENT, 0, 5, 4))
	b.add_theme_stylebox_override("focus", _box(Color.TRANSPARENT, ACCENT.darkened(0.3), 1, 5, 4))
	b.add_theme_stylebox_override("disabled", _box(ACCENT.lerp(BG, 0.5), Color.TRANSPARENT, 0, 5, 4))
	return b


func _box(fill: Color, border: Color, width: int, pad: int, radius := 6) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = border
	s.set_border_width_all(width)
	s.set_corner_radius_all(radius)
	s.set_content_margin_all(pad)
	s.content_margin_top = maxf(pad - 2, 0)
	s.content_margin_bottom = maxf(pad - 2, 0)
	s.anti_aliasing = true
	return s


static var _fonts := {}

func _font(weight: int) -> Font:
	if not _fonts.has(weight):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(FONT_NAMES)
		f.font_weight = weight
		_fonts[weight] = f
	return _fonts[weight]


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = _font(400)
	t.default_font_size = 10
	return t


## The user folder with the home directory shown as "~" (shorter, and a
## screenshot of this screen does not carry the player's account name).
static func _friendly_path(path: String) -> String:
	var home := OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	if home != "" and path.begins_with(home):
		return "~" + path.substr(home.length())
	return path


## The icon at `size` design pixels, drawn from res://icon.svg at 3x that so
## it is sharp in the 3x window (falls back to the imported texture).
static func _icon_texture(size: int) -> Texture2D:
	var svg := FileAccess.get_file_as_string("res://icon.svg")
	if svg != "":
		var img := Image.new()
		if img.load_svg_from_string(svg, size * 3.0 / 1024.0) == OK:
			return ImageTexture.create_from_image(img)
	return load("res://icon.svg") if ResourceLoader.exists("res://icon.svg") else null
