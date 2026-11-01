# Read-only view of the player's .ipa (a zip) for the in-game importer.
# Wraps Godot's ZIPReader; the IPA itself is never modified.
#
#     var ipa := ZipIpa.new()
#     if ipa.open(path) != OK: ...                 # not a zip
#     if ipa.app_prefix() == "": ...               # zip, but no Payload/X.app
#     var info := ipa.info()                       # Info.plist as a Dictionary
#     for name in ipa.top_level(".plist"): ipa.read(ipa.app_prefix() + name)
#     ipa.close()
#
# The v1.27 IPA (55 MB, 3,084 deflated entries, no directory entries) opens
# in a few milliseconds: ZIPReader only reads the central directory up front
# and inflates one entry per read().
#
# One instance per thread: ZIPReader is not meant to be shared between threads.
extends RefCounted

const Plist := preload("res://core/import/Plist.gd")

var _zip: ZIPReader = null
var _files := PackedStringArray()
var _index := {}          # path -> true
var _prefix := ""


## Open the zip at `path`. Returns ZIPReader's error (OK on success).
func open(path: String) -> Error:
	close()
	var z := ZIPReader.new()
	var err := z.open(path)
	if err != OK:
		return err
	_zip = z
	_files = z.get_files()
	for f in _files:
		_index[f] = true
	_prefix = _find_app_prefix()
	return OK


## "Payload/<X>.app/" -- the bundle whose Info.plist sits directly inside it
## -- or "" if the zip holds no iOS app.
func app_prefix() -> String:
	return _prefix


## Every entry path in the zip, in central-directory order.
func files() -> PackedStringArray:
	return _files


func has(path: String) -> bool:
	return _index.has(path)


## The inflated bytes of one entry; empty if there is no such entry.
func read(path: String) -> PackedByteArray:
	if _zip == null or not _index.has(path):
		return PackedByteArray()
	return _zip.read_file(path)


## Names directly inside the app bundle (no '/') ending in `suffix`, without
## dot-files, sorted by code point -- what sorted(app.glob('*' + suffix))
## yields in the Python tools.
func top_level(suffix: String) -> PackedStringArray:
	var out := PackedStringArray()
	if _prefix == "":
		return out
	for f in _files:
		if not f.begins_with(_prefix):
			continue
		var rel := f.substr(_prefix.length())
		if rel.is_empty() or rel.find("/") >= 0 or rel.begins_with(".") or not rel.ends_with(suffix):
			continue
		out.append(rel)
	out.sort()
	return out


## The app's Info.plist parsed, or {} if missing/unreadable. Keys of note:
## CFBundleIdentifier ("com.sunstorm.ff"), CFBundleShortVersionString ("1.27").
func info() -> Dictionary:
	if _prefix == "":
		return {}
	var v: Variant = Plist.parse(read(_prefix + "Info.plist"))
	return v if typeof(v) == TYPE_DICTIONARY else {}


func close() -> void:
	if _zip != null:
		_zip.close()
	_zip = null
	_files = PackedStringArray()
	_index = {}
	_prefix = ""


func _find_app_prefix() -> String:
	var found := PackedStringArray()
	for f in _files:
		if not f.begins_with("Payload/") or not f.ends_with(".app/Info.plist"):
			continue
		var mid := f.substr(8, f.length() - 8 - "/Info.plist".length())   # "<X>.app"
		if mid.find("/") < 0 and mid.length() > 4:
			found.append("Payload/" + mid + "/")
	if found.is_empty():
		return ""
	found.sort()
	return found[0]
