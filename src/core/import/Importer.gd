# Builds the game's files from the player's own Fair Food Maker 1.27 IPA.
#
# The in-game replacement for the Python setup pipeline (its nib, plist and
# artwork converters, asset extractor and banner generator). The port ships
# code only; this writes everything else into the user data folder:
#
#   user://import/
#     images/<File>.png    every top-level bundle PNG the asset extractor kept
#                          (same ad filter, CgBI dropped), ca_waterdrop's TIFF
#                          converted, plus port_inst_pour*.png
#     audio/<name>.mp3     one-shots, bytes as in the bundle
#     audio/<name>.wav     each .m4a loop decoded to 16-bit PCM
#     data/<Table>.json    the plist converter's output (+ its _manifest.json)
#     nibs/<Screen>.json   the nib converter's output
#     uikit/<File>.png     8 images from iOS 6's Shared@2x.artwork: from a
#                          file the player gave, else downloaded (IOS6Look.gd)
#                          when download_look is on; absent = drawn fallback
#     manifest.json        written last; Assets.is_ready() keys off it
#
# The iOS 6 look is never required. With download_look on and no artwork
# file, IOS6Look fetches it on a second thread while the IPA is converted; if
# that fails (offline, archive.org down, wrong hash) the import still
# succeeds, with "uikit": false and "uikit_error" saying why, and Boot tries
# again on a later launch (wants_ios6_look() / fetch_look()).
#
# Everything is written to user://import.partial first and swapped in only
# when complete, so a failed or cancelled run leaves an existing cache as it
# was and a re-import replaces it whole. The IPA is only ever read, and only
# its resources: the executable is never touched, so it does not matter
# whether it is still FairPlay-encrypted.
#
# A development check proves the output equal to the Python pipeline's
# (bytes, or pixels where a PNG is re-encoded) and exercises the failure,
# re-import and cancel paths.
#
# Use from a worker thread (FirstRunScreen does) or synchronously (Boot's
# --import-ipa). Create the instance on the main thread: _init loads the
# reader scripts. progress is called from the running thread as
# progress.call(fraction 0..1, text) -- marshal it yourself (call_deferred).

extends RefCounted

const ROOT := "user://import"
const STAGING := "user://import.partial"
const OLD := "user://import.old"
const FORMAT := 1

const BUNDLE_ID := "com.sunstorm.ff"
const TARGET_VERSION := "1.27"

# The Python asset extractor's filter: filename prefixes owned by bundled
# SDKs, not the game.
const AD_PREFIXES := ["vg_", "vungle", "adc_", "admob", "gad_", "mb_ad", "cb_"]
const AD_EXACT := ["AppleIncRootCertificate.cer", "README.txt", "__vungle.db"]
# Skipped by the Python plist converter too: bundle metadata, not game content.
const PLIST_SKIP := ["Info.plist"]

const TiffToPng := preload("res://core/import/TiffToPng.gd")
const PortBanners := preload("res://core/import/PortBanners.gd")
const UIKitArtwork := preload("res://core/import/UIKitArtwork.gd")
const IOS6Look := preload("res://core/import/IOS6Look.gd")

# The format readers, loaded at run time so this file (and the boot
# path that preloads it) still compiles while one of them is missing.
const COMPONENTS := {
	"ZipIpa": "res://core/import/ZipIpa.gd",
	"Plist": "res://core/import/Plist.gd",
	"NibReader": "res://core/import/NibReader.gd",
	"AacDecoder": "res://core/import/AacDecoder.gd",
}
const PY_JSON := "res://core/import/PyJson.gd"    # optional: json.dumps(indent=1) text

# Share of the progress bar per phase: the share of the time each took on
# the 1.27 IPA (8 s in all on a desktop PC).
const PHASES := {
	"open": [0.00, 0.02], "images": [0.02, 0.62], "sounds": [0.62, 0.65],
	"loops": [0.65, 0.93], "data": [0.93, 0.94], "nibs": [0.94, 0.985],
	"banners": [0.985, 0.993], "look": [0.993, 0.993], "uikit": [0.993, 0.997],
	"finish": [0.997, 1.00],
}
## Share of the bar given to the download when it runs alongside: it mostly
## finishes inside the IPA's time, so it only shows when it is the slower.
const LOOK_SHARE := 0.15

## Fetch the iOS 6 look (IOS6Look.gd) during run() when no artwork file is
## given. Off by default, for tools and tests; the first-run screen and
## Boot's --import-ipa turn it on.
var download_look := false
## Properties set on the IOS6Look (tests: url / metadata_url at a dead
## address, test_fail_servers, test_bytes_per_sec, verbose).
var look_options := {}
## How long run() waits for a download still going when the IPA part is
## done (the first-run screen keeps showing its progress meanwhile); past
## it the import completes without the art and Boot fetches it next launch.
## Only a download that is getting somewhere is waited for: any sign the
## network works (a name looked up, a connection made, any HTTP answer or
## bytes: IOS6Look.progress_ms) within the last LOOK_STILL_MS, or all bytes
## in and being checked. With no such sign yet, only until its first
## attempt resolves or times out (at most LOOK_STILL_MS). Offline that is a
## few seconds at most; online it finishes with the art.
var look_wait_ms := 30000
const LOOK_STILL_MS := 5000
## Set when the player turned the download off (Boot --no-download): the
## manifest says so and Boot does not fetch it on later launches either.
var look_opt_out := false

var _c := {}                 # component name -> Script
var _missing := ""
var _py_json                # PyJson script, or null
var _cancel := false
var _progress := Callable()
var _last_f := 0.0
var _look: RefCounted = null          # IOS6Look while one runs
var _look_thread: Thread = null
var _look_mutex := Mutex.new()
var _look_info := {"state": "off", "bytes": 0, "total": 0, "error": "", "last_byte_ms": 0}
var _look_share := 0.0


func _init() -> void:
	for name: String in COMPONENTS:
		var path: String = COMPONENTS[name]
		var script: Script = load(path) if ResourceLoader.exists(path) else null
		# A script that failed to compile still loads, but cannot be used.
		if script != null and script.can_instantiate():
			_c[name] = script
		elif _missing == "":
			_missing = path
	if ResourceLoader.exists(PY_JSON):
		_py_json = load(PY_JSON)


## Ask a running import to stop at the next file. It returns {ok: false,
## cancelled: true} and leaves the previous cache untouched.
func cancel() -> void:
	_cancel = true
	var look := _look
	if look != null:
		look.cancel()


## The download's state, safe to poll from any thread while run() or
## fetch_look() runs: {state: "off" | "fetching" | "done" | "failed",
## bytes, total, error}.
func look_state() -> Dictionary:
	_look_mutex.lock()
	var d := _look_info.duplicate()
	_look_mutex.unlock()
	return d


## True when a complete import lacks the iOS 6 look and nobody turned the
## download off: Boot then fetches it in the background (fetch_look()).
static func wants_ios6_look() -> bool:
	var m := read_manifest()
	return not m.is_empty() and m.get("uikit") != true and m.get("uikit_download") != false


## True when a complete import is in place (the manifest is written last).
static func has_cache() -> bool:
	return FileAccess.file_exists(ROOT + "/manifest.json")


static func read_manifest() -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "/manifest.json")) \
		if has_cache() else null
	return v if v is Dictionary else {}


## Quick check of a dropped .artwork file, before any import: "" when it has
## all eight images, else a sentence for the player.
static func check_artwork(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "Couldn't find that file:\n%s" % path
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "Couldn't open that file (error %d)." % FileAccess.get_open_error()
	var index := UIKitArtwork.read_index(f.get_buffer(f.get_length()))
	if not index.ok:
		return ("That file isn't an iOS .artwork file. Use Shared@2x.artwork from "
			+ "iOS 6's UIKit.framework.")
	var missing := PackedStringArray()
	for n in UIKitArtwork.NAMES:
		if not index.entries.has(n):
			missing.append(n.get_basename())
	if not missing.is_empty():
		return ("That .artwork file doesn't have iOS 6's alert pictures (missing %s). "
			+ "Use Shared@2x.artwork from iOS 6's UIKit.framework.") % ", ".join(missing)
	return ""


## The whole import. -> {ok, error, cancelled, warnings: [], counts: {},
## uikit: bool, uikit_error: why not ("" if it was not tried), look: {bytes,
## requests, msec} when it was downloaded}
func run(ipa_path: String, artwork_path: String, progress: Callable = Callable()) -> Dictionary:
	_progress = progress
	_cancel = false
	_last_f = 0.0
	_look_share = LOOK_SHARE if download_look and artwork_path == "" else 0.0
	var out := {"ok": false, "error": "", "cancelled": false, "warnings": [], "counts": {},
		"uikit": false, "uikit_error": ""}
	if _missing != "":
		out.error = "This build of the port is missing part of its importer (%s)." % _missing
		return out
	_report("open", 0.0, "Opening your .ipa…")

	# Inputs first, so a wrong file fails in a second, not after a minute.
	var uikit_images := {}
	if artwork_path != "":
		var err := check_artwork(artwork_path)
		if err != "":
			out.error = err
			return out
		var art := UIKitArtwork.extract_file(artwork_path)
		if not art.ok:
			out.error = "Couldn't read the iOS 6 artwork: %s." % art.error
			return out
		uikit_images = art.images

	if not FileAccess.file_exists(ipa_path):
		out.error = "Couldn't find that file:\n%s" % ipa_path
		return out
	var zip: Object = _c.ZipIpa.new()
	if zip.call("open", ipa_path) != OK:
		out.error = ("That file isn't an .ipa: it can't be opened as one. Choose the "
			+ "Fair Food Maker .ipa file itself.")
		return out
	var result := _run_open(zip, uikit_images, out)
	zip.call("close")
	_stop_look()                     # only still running when the import failed
	if not result.has("ok"):
		# A script error inside a reader aborts _run_open with an empty result.
		result = out
		result.ok = false
		if result.error == "":
			result.error = "The importer hit an internal error (details are in the log)."
	if not result.ok:
		_remove_tree(STAGING)
	return result


func _run_open(zip: Object, uikit_images: Dictionary, out: Dictionary) -> Dictionary:
	var prefix: String = zip.call("app_prefix")
	if prefix == "":
		out.error = "That file isn't an iPhone app: there is no app inside it."
		return out
	_report("open", 0.5, "Checking it's Fair Food Maker %s…" % TARGET_VERSION)
	var info: Variant = _c.Plist.parse(zip.call("read", prefix + "Info.plist"))
	if not (info is Dictionary):
		out.error = "That app is damaged or incomplete: it has no readable Info.plist."
		return out
	var bundle_id := str(info.get("CFBundleIdentifier", ""))
	var version := str(info.get("CFBundleShortVersionString", ""))
	var shown_version := version if version != "" else str(info.get("CFBundleVersion", "?"))
	if bundle_id != BUNDLE_ID:
		var app_name := str(info.get("CFBundleDisplayName", info.get("CFBundleName", "another app")))
		out.error = ("That's not Fair Food Maker: it's \"%s\" (%s). The port needs "
			+ "Sunstorm's Fair Food Maker (%s).") % [app_name, bundle_id, BUNDLE_ID]
		return out
	if version != TARGET_VERSION:
		out.error = ("That's Fair Food Maker %s, but the port needs version %s. Other "
			+ "versions, including today's App Store version, aren't supported.") % [
			shown_version, TARGET_VERSION]
		return out
	if _look_share > 0.0:
		_start_look()

	# The app's files as the Python pipeline saw them: the asset extractor
	# walks app.iterdir() (every top-level file), the plist converter
	# sorted(app.glob('*.plist')) and the nib converter
	# sorted(app.glob('*.nib')), nib directories and the one flat nib alike
	# (NibReader.nib_groups).
	var top: Array[String] = []
	for path: String in zip.call("files"):
		if path.begins_with(prefix) and path.length() > prefix.length() \
				and path.find("/", prefix.length()) < 0:
			top.append(path.substr(prefix.length()))
	top.sort()
	var plists: PackedStringArray = zip.call("top_level", ".plist")
	var nibs: Dictionary = _c.NibReader.nib_groups(zip.call("files"), prefix)
	if nibs.is_empty():
		out.error = ("That copy of Fair Food Maker has no screen layouts. Is the .ipa "
			+ "complete?")
		return out

	_remove_tree(STAGING)
	for sub in ["images", "audio", "data", "nibs"]:
		var e := DirAccess.make_dir_recursive_absolute(STAGING + "/" + sub)
		if e != OK:
			out.error = _write_error(STAGING, e)
			return out

	var counts := {"png": 0, "cgbi_dropped": 0, "tiff_fixed": 0, "mp3": 0, "wav": 0,
		"ad_skipped": 0, "tables": 0, "nibs": 0, "banners": 0, "uikit": 0}
	out.counts = counts

	# -- pictures and sounds ----------------------------------------------------
	var pngs: Array[String] = []
	var mp3s: Array[String] = []
	var loops: Array[String] = []
	for n in top:
		if _is_ad_asset(n):
			counts.ad_skipped += 1
			continue
		match n.get_extension().to_lower():
			"png": pngs.append(n)
			"mp3": mp3s.append(n)
			"m4a": loops.append(n)

	for i in pngs.size():
		if _cancelled(out):
			return out
		var n := pngs[i]
		if i % 25 == 0:
			_report("images", float(i) / pngs.size(), "Copying pictures… %d of %d" % [i, pngs.size()])
		var bytes: PackedByteArray = zip.call("read", prefix + n)
		match _png_kind(bytes):
			"cgbi":
				counts.cgbi_dropped += 1     # Apple-crushed: the ad SDK's, not the game's
				continue
			"tiff":
				# ca_waterdrop.png: a TIFF under a .png name. SSEmitter asks for
				# the .png name, so a real PNG goes there.
				var png := TiffToPng.to_png(bytes)
				var dest := n if not png.is_empty() else n.get_basename() + ".tiff"
				if not _write(STAGING + "/images/" + dest, png if not png.is_empty() else bytes, out):
					return out
				counts.tiff_fixed += 1
			_:
				if not _write(STAGING + "/images/" + n, bytes, out):
					return out
				counts.png += 1

	for i in mp3s.size():
		if _cancelled(out):
			return out
		_report("sounds", float(i) / mp3s.size(), "Copying sounds… %d of %d" % [i, mp3s.size()])
		if not _write(STAGING + "/audio/" + mp3s[i], zip.call("read", prefix + mp3s[i]), out):
			return out
		counts.mp3 += 1

	# Loops: decoded here because Godot cannot play AAC. Progress by size,
	# since decoding is what takes the time.
	var loop_bytes := []
	var total := 0
	for n in loops:
		var b: PackedByteArray = zip.call("read", prefix + n)
		loop_bytes.append(b)
		total += b.size()
	var done := 0
	for i in loops.size():
		if _cancelled(out):
			return out
		_report("loops", float(done) / maxi(total, 1),
			"Converting music… %d of %d" % [i + 1, loops.size()])
		var dec: Dictionary = _c.AacDecoder.decode_m4a(loop_bytes[i])
		if not dec.get("ok", false):
			out.error = "Couldn't convert the music loop %s (%s)." % [loops[i], dec.get("error", "?")]
			return out
		if not _write(STAGING + "/audio/" + loops[i].get_basename() + ".wav",
				_c.AacDecoder.wav_bytes(dec), out):
			return out
		done += (loop_bytes[i] as PackedByteArray).size()
		loop_bytes[i] = PackedByteArray()
		counts.wav += 1

	# -- tables -----------------------------------------------------------------
	_report("data", 0.0, "Reading the game's tables…")
	var manifest := {}
	for n in plists:
		if _cancelled(out):
			return out
		if n in PLIST_SKIP:
			continue
		var stem := n.get_basename()
		# An unreadable table is recorded in _manifest.json and skipped, as the
		# Python plist converter did.
		var parsed: Dictionary = _c.Plist.parse_result(zip.call("read", prefix + n))
		if not parsed.ok:
			manifest[stem] = {"error": parsed.error}
			out.warnings.append("table %s could not be read (%s)" % [n, parsed.error])
			continue
		var value: Variant = _c.Plist.to_json_value(parsed.value)
		if not _write(STAGING + "/data/" + stem + ".json", _json(value).to_utf8_buffer(), out):
			return out
		manifest[stem] = _c.Plist.manifest_entry(parsed.value)
		counts.tables += 1
	if not _write(STAGING + "/data/_manifest.json", _json(manifest).to_utf8_buffer(), out):
		return out

	# -- screen layouts ---------------------------------------------------------
	# Like the nib converter, a screen that will not convert is reported and
	# skipped.
	var screens: Array = nibs.keys()
	for i in screens.size():
		if _cancelled(out):
			return out
		var screen: String = screens[i]
		if i % 4 == 0:
			_report("nibs", float(i) / screens.size(),
				"Reading screen layouts… %d of %d" % [i, screens.size()])
		var members: Dictionary = nibs[screen]
		var src: String = _c.NibReader.source_name(members)
		if src == "":
			out.warnings.append("screen %s has no objects.nib" % screen)
			continue
		var r: Dictionary = _c.NibReader.convert_result({src: zip.call("read", members[src])}, screen)
		if not r.ok:
			out.warnings.append("screen %s could not be read (%s)" % [screen, r.error])
			continue
		if not _write(STAGING + "/nibs/" + screen + ".json", _json(r.value).to_utf8_buffer(), out):
			return out
		counts.nibs += 1

	# -- the port's pour banners -------------------------------------------------
	# Never blocks an import, as in the asset extractor: without them the screens
	# show the original TILT banners.
	_report("banners", 0.0, "Rewording the pour banners…")
	var sources := {}
	for n: String in PortBanners.SOURCES:
		var bytes: PackedByteArray = zip.call("read", prefix + n)
		var img := Image.new()
		if PortBanners.png_ok(bytes) and img.load_png_from_buffer(bytes) == OK:
			sources[n] = img
	var banners := PortBanners.build_all(sources)
	if banners.ok:
		for n: String in banners.images:
			if not _write(STAGING + "/images/" + n, (banners.images[n] as Image).save_png_to_buffer(), out):
				return out
			counts.banners += 1
	else:
		out.warnings.append("pour banners not rebuilt (%s); the TILT originals will show" % banners.error)

	# -- iOS 6 UIKit art (from an artwork file, or downloaded) ------------------
	var uikit_extra := {"uikit_source": "file"} if not uikit_images.is_empty() else {}
	if _look_thread != null:
		var lr := _join_look(look_wait_ms)
		if _cancelled(out):
			return out
		out.look = {"bytes": lr.get("bytes_downloaded", 0), "requests": lr.get("requests", 0),
			"msec": lr.get("msec", 0), "waited_ms": lr.get("waited_ms", 0)}
		if lr.get("ok", false):
			uikit_images = lr.images
			uikit_extra = {"uikit_source": "download"}
		else:
			out.uikit_error = str(lr.get("error", "the download failed"))
			uikit_extra = {"uikit_error": out.uikit_error}
			out.warnings.append("iOS 6 look not downloaded (%s); alerts use the drawn fallback"
				% out.uikit_error)
	elif uikit_images.is_empty() and look_opt_out:
		uikit_extra = {"uikit_error": "not downloaded (turned off)", "uikit_download": false}
	if not uikit_images.is_empty():
		_report("uikit", 0.0, "Adding the iOS 6 alert look…")
		if not _write_uikit(STAGING + "/uikit", uikit_images, out):
			return out
		counts.uikit = uikit_images.size()

	if _cancelled(out):
		return out
	_report("finish", 0.0, "Finishing up…")
	if not _write(STAGING + "/manifest.json", _manifest_text(not uikit_images.is_empty(), counts,
			uikit_extra).to_utf8_buffer(), out):
		return out
	out.uikit = not uikit_images.is_empty()
	var swap := _swap_in()
	if swap != "":
		out.error = swap
		return out
	_report("finish", 1.0, "Done!")
	out.ok = true
	return out


## Adds (or replaces) the optional UIKit art in an existing cache. Used when
## the artwork arrives after the IPA import. -> {ok, error}
func import_uikit(artwork_path: String) -> Dictionary:
	var out := {"ok": false, "error": "", "warnings": [], "counts": {}}
	if not has_cache():
		out.error = "Import the Fair Food Maker .ipa first."
		return out
	var err := check_artwork(artwork_path)
	if err != "":
		out.error = err
		return out
	var art := UIKitArtwork.extract_file(artwork_path)
	if not art.ok:
		out.error = "Couldn't read the iOS 6 artwork: %s." % art.error
		return out
	out.ok = _install_uikit(art.images, "file", out)
	return out


## Downloads the iOS 6 look (IOS6Look.gd) into an existing cache: Boot's
## background retry when the first import could not. Blocking; run it on a
## thread. The cache is only touched once all eight images are in hand.
## -> {ok, error, cancelled, look: {bytes, requests, msec}}
func fetch_look(progress: Callable = Callable()) -> Dictionary:
	var out := {"ok": false, "error": "", "cancelled": false, "warnings": [], "counts": {}}
	if not has_cache():
		out.error = "Import the Fair Food Maker .ipa first."
		return out
	_progress = progress
	_last_f = 0.0
	_look_share = 1.0
	_start_look()
	var lr := _join_look()
	out.look = {"bytes": lr.get("bytes_downloaded", 0), "requests": lr.get("requests", 0),
		"msec": lr.get("msec", 0)}
	if _cancel or lr.get("cancelled", false):
		out.cancelled = true
		out.error = "cancelled"
		return out
	if not lr.get("ok", false):
		out.error = str(lr.get("error", "the download failed"))
		return out
	out.ok = _install_uikit(lr.images, "download", out)
	return out


# -- helpers --------------------------------------------------------------------

## The 8 images into ROOT/uikit (staged, then swapped in) and the manifest
## rewritten to say so, keeping its import time and counts.
func _install_uikit(images: Dictionary, source: String, out: Dictionary) -> bool:
	var tmp := ROOT + "/uikit.partial"
	_remove_tree(tmp)
	if not _write_uikit(tmp, images, out):
		_remove_tree(tmp)
		return false
	_remove_tree(ROOT + "/uikit")
	var e := DirAccess.rename_absolute(tmp, ROOT + "/uikit")
	if e != OK:
		out.error = _write_error(ROOT + "/uikit", e)
		return false
	var old := read_manifest()
	var counts := {}
	var old_counts: Variant = old.get("counts", {})
	if old_counts is Dictionary:
		for k: String in old_counts:
			counts[k] = int(old_counts[k])        # JSON gave them back as floats
	counts["uikit"] = images.size()
	out.counts = counts
	var text := _manifest_text(true, counts, {"uikit_source": source}, str(old.get("imported", "")))
	# Rewritten in place, so via a temporary: a crash mid-write must not
	# leave a cut manifest (that would send the player back to the first run).
	if not _write(ROOT + "/manifest.json.partial", text.to_utf8_buffer(), out):
		return false
	var e2 := DirAccess.rename_absolute(ROOT + "/manifest.json.partial", ROOT + "/manifest.json")
	if e2 != OK:
		out.error = _write_error(ROOT + "/manifest.json", e2)
		return false
	return true


func _start_look() -> void:
	_look = IOS6Look.new()
	for k: String in look_options:
		_look.set(k, look_options[k])
	if _cancel:
		_look.cancel()
	_set_look({"state": "fetching", "bytes": 0, "total": _look.call("expected_bytes"), "error": "",
		"last_byte_ms": 0})
	_look_thread = Thread.new()
	_look_thread.start(_look_worker)


## The download thread.
func _look_worker() -> Dictionary:
	var r: Dictionary = _look.call("fetch", func(b: int, total: int) -> void:
		_look_mutex.lock()
		_look_info.bytes = b
		_look_info.total = total
		_look_info.last_byte_ms = Time.get_ticks_msec()
		_look_mutex.unlock())
	var info := look_state()
	info.state = "done" if r.get("ok", false) else "failed"
	info.error = str(r.get("error", ""))
	_set_look(info)
	return r


## Waits for the download, reporting it on the bar; -> IOS6Look's result
## (+ waited_ms). cap_ms >= 0 (run(): the IPA part is done): wait while it
## is getting somewhere (see look_wait_ms), at most cap_ms; otherwise
## cancel it and say why. cap_ms -1 (Boot's background fetch_look): until
## IOS6Look ends by itself.
func _join_look(cap_ms: int = -1) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var stop := ""
	while _look_thread.is_alive():
		var s := look_state()
		var now := Time.get_ticks_msec()
		if cap_ms >= 0 and stop == "":
			var mb := "%.1f of %.1f MB" % [int(s.bytes) / 1e6, maxi(int(s.total), int(s.bytes)) / 1e6]
			var p := int(_look.get("progress_ms"))
			var moving: bool = bool(_look.get("received_all")) or now - maxi(p, t0) < LOOK_STILL_MS
			# Never a sign of a network yet, and an attempt has failed since:
			# that was the attempt being waited for.
			if p == 0 and int(_look.get("net_fail_ms")) > t0:
				moving = false
			if not moving and p == 0:
				stop = ("nothing had come from the Internet Archive by the end of the import "
					+ "(no internet connection?)")
			elif not moving:
				stop = "the download had stalled by the end of the import (%s)" % mb
			elif now - t0 > cap_ms:
				stop = "the download was still going %d s after the rest of the import (%s)" % [
					cap_ms / 1000, mb]
			if stop != "":
				_look.cancel()
		if stop == "":
			_report("look", 0.0, "Downloading the classic iPhone pop-up style… %.1f of %.1f MB" % [
				int(s.bytes) / 1e6, maxi(int(s.total), int(s.bytes)) / 1e6])
		OS.delay_msec(50 if stop == "" else 2)
	var r: Variant = _look_thread.wait_to_finish()
	_look_thread = null
	_look = null
	if not (r is Dictionary):
		r = {"ok": false, "error": "the download hit an internal error"}
	if stop != "" and not r.get("ok", false):
		r = {"ok": false, "cancelled": false, "bytes_downloaded": r.get("bytes_downloaded", 0),
			"requests": r.get("requests", 0), "msec": r.get("msec", 0), "error": stop}
	r["waited_ms"] = Time.get_ticks_msec() - t0
	return r


func _stop_look() -> void:
	if _look_thread == null:
		return
	_look.cancel()
	_look_thread.wait_to_finish()
	_look_thread = null
	_look = null


func _set_look(d: Dictionary) -> void:
	_look_mutex.lock()
	_look_info = d
	_look_mutex.unlock()


## The download's part of the bar, 0..1 (1 once it has ended either way).
func _look_fraction() -> float:
	var s := look_state()
	if s.state == "done" or s.state == "failed":
		return 1.0
	return clampf(float(s.bytes) / maxf(float(s.total), 1.0), 0.0, 1.0)

func _write_uikit(dir: String, images: Dictionary, out: Dictionary) -> bool:
	var e := DirAccess.make_dir_recursive_absolute(dir)
	if e != OK:
		out.error = _write_error(dir, e)
		return false
	for n: String in images:
		if not _write(dir + "/" + n, (images[n] as Image).save_png_to_buffer(), out):
			return false
	return true


## extra: uikit_source ("file" | "download") when uikit is true, else
## uikit_error (why not) and uikit_download: false (the player turned it off).
func _manifest_text(uikit: bool, counts: Dictionary, extra: Dictionary = {}, imported: String = "") -> String:
	var m := {"format": FORMAT, "bundle_id": BUNDLE_ID, "version": TARGET_VERSION, "uikit": uikit}
	m.merge(extra)
	m["imported"] = imported if imported != "" else Time.get_datetime_string_from_system(true) + "Z"
	m["counts"] = counts
	return JSON.stringify(m, " ", false)


## Staging -> ROOT. The old cache is moved aside first and deleted after, so
## at no point is a half-written folder called import/.
func _swap_in() -> String:
	_remove_tree(OLD)
	if DirAccess.dir_exists_absolute(ROOT):
		var e := DirAccess.rename_absolute(ROOT, OLD)
		if e != OK:
			return ("Couldn't replace the previous import in %s (error %d). Is the game "
				+ "running twice?") % [ProjectSettings.globalize_path(ROOT), e]
	var e2 := DirAccess.rename_absolute(STAGING, ROOT)
	if e2 != OK:
		if DirAccess.dir_exists_absolute(OLD):
			DirAccess.rename_absolute(OLD, ROOT)
		return _write_error(ROOT, e2)
	_remove_tree(OLD)
	return ""


func _write(path: String, bytes: PackedByteArray, out: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		out.error = _write_error(path, FileAccess.get_open_error())
		return false
	f.store_buffer(bytes)
	var e := f.get_error()
	f.close()
	if e != OK:
		out.error = _write_error(path, e)
		return false
	return true


static func _write_error(path: String, e: int) -> String:
	return ("Couldn't save the game files in %s (error %d). Is the disk full or "
		+ "the folder read-only?") % [ProjectSettings.globalize_path(path).get_base_dir(), e]


func _cancelled(out: Dictionary) -> bool:
	if _cancel:
		out.cancelled = true
		out.error = "Import cancelled."
	return _cancel


func _report(phase: String, within: float, text: String) -> void:
	if not _progress.is_valid():
		return
	var span: Array = PHASES[phase]
	var f := lerpf(span[0], span[1], clampf(within, 0.0, 1.0))
	if _look_share > 0.0:
		f = f * (1.0 - _look_share) + _look_share * _look_fraction()
	f = maxf(f, _last_f)                   # the download ending early must not jump back
	_last_f = f
	_progress.call(f, text)


func _json(v: Variant) -> String:
	if _py_json != null:
		return _py_json.call("dumps", v)
	return JSON.stringify(v, " ", false, true)


static func _is_ad_asset(name: String) -> bool:
	if name in AD_EXACT:
		return true
	var low := name.to_lower()
	for p: String in AD_PREFIXES:
		if low.begins_with(p):
			return true
	return false


## The Python asset extractor's png_info(): 'png', 'cgbi', 'tiff' or 'other'
## (copied as-is).
static func _png_kind(h: PackedByteArray) -> String:
	if h.size() >= 4 and h[0] == 0x4D and h[1] == 0x4D and h[2] == 0 and h[3] == 0x2A:
		return "tiff"
	if h.size() >= 4 and h[0] == 0x49 and h[1] == 0x49 and h[2] == 0x2A and h[3] == 0:
		return "tiff"
	if h.size() < 16 or h.slice(0, 8) != PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
		return "other"
	return "cgbi" if h.slice(12, 16).get_string_from_ascii() == "CgBI" else "png"


## Deletes a folder under user://import* and everything in it.
static func _remove_tree(path: String) -> void:
	if not path.begins_with("user://import") or not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_remove_tree(path + "/" + sub)
	DirAccess.remove_absolute(path)
