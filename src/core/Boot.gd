# Entry point. Hosts the screen stack and a debug overlay.
#
# First launch: until the player's IPA has been imported into the user data
# folder (Assets.is_ready() is false) this shows ui/FirstRunScreen.gd instead
# of the game, then continues into the main menu.
#
# The iOS 6 pop-up look: the import downloads it (core/import/IOS6Look.gd).
# If that failed (offline at first launch), every later launch tries again
# quietly in the background; alerts built after it lands use it.
#
# Automation (headless):
#   <game> --headless -- --import-ipa <Fair Food Maker.ipa> [--uikit-artwork <Shared@2x.artwork>] [--no-download]
#   <game> --headless -- --uikit-artwork <Shared@2x.artwork>     (add to an existing import)
# imports and quits: exit code 0 = done, 1 = the import failed, 2 = bad usage.
# --import-ipa also downloads the iOS 6 look unless an artwork file is given
# or --no-download is (then later launches do not fetch it either). A failed
# download never fails the import.
#
# The overlay is the point of Phase 1: it lists every food flow and every one
# of the 86 extracted screens, so the layout conversion can be inspected before
# any gameplay exists.
#
#   F1     toggle the browser
#   F2     toggle the status line (screen name, stack depth) -- off by default
#          so the window shows only what the game shows
#   Esc    back / reopen browser
#   Left   back
#   Right  next step (skips the step's own work)
#
# All of that is DEVELOPER-ONLY: it exists only when res://dev/ (the test
# harnesses) is present. The release leaves dev/ out, so players get exactly
# what the phone offers -- the main menu and the on-screen buttons, no keys.

extends Node

const FirstRunScreen := preload("res://ui/FirstRunScreen.gd")
const Importer := preload("res://core/import/Importer.gd")

## True in the development tree (res://dev/ exists), false in the release.
var dev_tools := DirAccess.dir_exists_absolute("res://dev")

const OVERLAY_FONT_SIZE := 9

var _root: Node2D
var _overlay: CanvasLayer
var _browser: Control
var _status: Label
var _status_visible := false
var _first_run: Control
var _look_importer: RefCounted         # background fetch of the iOS 6 look
var _look_thread: Thread


func _ready() -> void:
	var cli := _cli_options()
	if cli.has("--import-ipa") or cli.has("--uikit-artwork"):
		_cli_import(cli)
		return

	_root = Node2D.new()
	_root.name = "ScreenRoot"
	add_child(_root)
	Nav.set_root(_root)
	Nav.screen_changed.connect(_on_screen_changed)

	# The port's name on the window (Godot run from its editor binary would
	# title it "... (DEBUG)").
	get_window().title = str(ProjectSettings.get_setting("application/config/name"))

	if not _assets_ready():
		_first_run = FirstRunScreen.new()
		_first_run.finished.connect(_on_first_run_finished)
		add_child(_first_run)
		return
	_start_game()
	_fetch_look_in_background()


func _exit_tree() -> void:
	if _look_thread != null:
		_look_importer.call("cancel")
		_look_thread.wait_to_finish()
		_look_thread = null


func _on_first_run_finished() -> void:
	_first_run.queue_free()
	_first_run = null
	var assets := _assets()
	if assets != null:
		assets.call("invalidate")
	_start_game()


func _start_game() -> void:
	print("%s: game files from %s" % [ProjectSettings.get_setting("application/config/name"),
		ProjectSettings.globalize_path(Importer.ROOT)])

	# Start on the real main menu; the browser is a debug tool behind F1.
	if not dev_tools:
		if not Nav.push("MainMenuViewController"):
			push_error("Boot: the main menu did not load")
		else:
			print("Boot: main menu")
		return
	_build_overlay()
	if not Nav.push("MainMenuViewController"):
		_show_browser(true)
	else:
		print("Boot: main menu")
		_show_browser(false)


# -- imported game files ------------------------------------------------------

## The Assets autoload (core/Assets.gd), looked up by path so this file does
## not depend on it being registered.
func _assets() -> Node:
	return get_node_or_null("/root/Assets")


func _assets_ready() -> bool:
	var assets := _assets()
	return assets != null and bool(assets.call("is_ready"))


# -- the iOS 6 look, later --------------------------------------------------

## The first import could not download the iOS 6 look (offline, archive.org
## down): try again now, off the main thread, without a word to the player.
## Screens already up keep what they have; alerts built afterwards use it.
func _fetch_look_in_background() -> void:
	if not Importer.wants_ios6_look():
		return
	_look_importer = Importer.new()
	_look_thread = Thread.new()
	_look_thread.start(func() -> void:
		var r: Dictionary = _look_importer.call("fetch_look")
		_on_look_fetched.call_deferred(r))


func _on_look_fetched(r: Dictionary) -> void:
	if _look_thread == null:
		return
	_look_thread.wait_to_finish()
	_look_thread = null
	if r.get("ok", false):
		var assets := _assets()
		if assets != null:
			assets.call("invalidate")
		print("Boot: added the iOS 6 pop-up look (%.1f MB in %.1f s)" % [
			int(r.look.bytes) / 1e6, int(r.look.msec) / 1000.0])
	elif not r.get("cancelled", false):
		print("Boot: iOS 6 pop-up look still unavailable: %s" % r.get("error", "?"))


# -- command line -------------------------------------------------------------

## Options after "--" (or, in an exported build, anywhere on the line):
## {"--import-ipa": path, "--uikit-artwork": path, "--no-download": ""}; a
## value of "" means the option was given without one.
func _cli_options() -> Dictionary:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()
	var out := {}
	for i in args.size():
		if args[i] in ["--import-ipa", "--uikit-artwork"]:
			out[args[i]] = args[i + 1] if i + 1 < args.size() and not args[i + 1].begins_with("--") else ""
		elif args[i] == "--no-download":
			out[args[i]] = ""
	return out


func _cli_import(cli: Dictionary) -> void:
	var ipa: String = cli.get("--import-ipa", "")
	var art: String = cli.get("--uikit-artwork", "")
	if (cli.has("--import-ipa") and ipa == "") or (cli.has("--uikit-artwork") and art == ""):
		printerr("usage: --import-ipa <Fair Food Maker 1.27 .ipa> [--uikit-artwork <Shared@2x.artwork>] [--no-download]")
		get_tree().quit(2)
		return
	var importer := Importer.new()
	var t0 := Time.get_ticks_msec()
	var last := [""]
	var r: Dictionary
	if ipa != "":
		print("Importing %s into %s" % [ipa, ProjectSettings.globalize_path(Importer.ROOT)])
		importer.download_look = art == "" and not cli.has("--no-download")
		importer.look_opt_out = art == "" and cli.has("--no-download")
		if importer.download_look:
			print("  and downloading the iOS 6 pop-up look from the Internet Archive")
		r = importer.run(ipa, art, func(f: float, text: String) -> void:
			var head := text.get_slice("…", 0)
			if head != last[0]:
				last[0] = head
				print("  %3d%%  %s" % [roundi(f * 100.0), text]))
	else:
		print("Adding iOS 6 UIKit art from %s" % art)
		r = importer.import_uikit(art)
	for w: String in r.get("warnings", []):
		print("  note: " + w)
	var ok: bool = r.get("ok", false)
	if ok:
		print("Import OK in %.1f s: %s" % [(Time.get_ticks_msec() - t0) / 1000.0,
			JSON.stringify(r.get("counts", {}))])
		if r.has("look"):
			print("  iOS 6 look: %s, %d bytes in %d requests, %.1f s" % [
				"downloaded" if r.get("uikit", false) else "NOT downloaded",
				int(r.look.bytes), int(r.look.requests), int(r.look.msec) / 1000.0])
	else:
		printerr("Import FAILED: " + str(r.get("error", "internal error")))
	get_tree().quit(0 if ok else 1)


# -- overlay ----------------------------------------------------------

func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 100
	add_child(_overlay)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", OVERLAY_FONT_SIZE)
	_status.add_theme_color_override("font_color", Color(1, 1, 0.4))
	_status.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_status.add_theme_constant_override("shadow_offset_x", 1)
	_status.add_theme_constant_override("shadow_offset_y", 1)
	_status.position = Vector2(3, 2)
	_overlay.add_child(_status)

	_browser = _build_browser()
	_overlay.add_child(_browser)


func _build_browser() -> Control:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.06, 0.05, 0.09, 0.97)
	panel.add_theme_stylebox_override("panel", bg)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_child(scroll)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 1)
	scroll.add_child(col)

	col.add_child(_heading("FOOD FLOWS  (F1 toggles this)"))
	for key: String in Nav.flow_keys():
		var flow: Dictionary = Nav.flows[key]
		var steps: Array = flow.get("steps", [])
		col.add_child(_row("%s  (%d steps)" % [flow.get("food", key), steps.size()],
			func() -> void: Nav.start_food(key); _show_browser(false)))

	col.add_child(_heading("ALL SCREENS"))
	for screen_name in Bindings.screen_names():
		if not Nav.exists(screen_name):
			continue
		col.add_child(_row(screen_name,
			func() -> void: Nav.push(screen_name); _show_browser(false)))

	return panel


func _heading(text: String) -> Control:
	var l := Label.new()
	l.text = "  " + text
	l.add_theme_font_size_override("font_size", OVERLAY_FONT_SIZE + 1)
	l.add_theme_color_override("font_color", Color(1, 0.75, 0.2))
	l.custom_minimum_size.y = 18
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return l


func _row(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = "  " + text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.flat = true
	b.add_theme_font_size_override("font_size", OVERLAY_FONT_SIZE)
	b.add_theme_color_override("font_color", Color(0.85, 0.88, 1.0))
	b.custom_minimum_size.y = 13
	b.pressed.connect(on_press)
	return b


func _show_browser(visible_: bool) -> void:
	_browser.visible = visible_
	_update_status()


func _on_screen_changed(_screen_name: String) -> void:
	if dev_tools and _browser != null:
		_update_status()


func _update_status() -> void:
	if _browser.visible or not _status_visible:
		_status.text = ""
		return
	_status.text = "%s   [depth %d]   Esc=browser" % [Nav.current_name(), Nav.depth()]


# -- input ------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not dev_tools or _browser == null:     # no overlay during the first run
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_F1:
			_show_browser(not _browser.visible)
		KEY_F2:
			_status_visible = not _status_visible
			_update_status()
		KEY_ESCAPE:
			if _browser.visible:
				_show_browser(false)
			elif Nav.depth() > 1:
				Nav.back()
			else:
				_show_browser(true)   # at the menu, Esc opens the browser
		KEY_LEFT:
			if not _browser.visible:
				Nav.back()
		KEY_RIGHT:
			if not _browser.visible:
				Nav.next()
