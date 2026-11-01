# The game's only door to the original app's content: the import cache.
#
# Nothing of the shipped game lives in res:// any more. On first launch the
# player's own IPA is converted (core/import/Importer.gd) into the user data
# directory, and everything the game draws, plays, reads or lays out comes
# from there:
#
#     user://import/manifest.json      written last; its presence = ready
#     user://import/images/<File>.png  bundle art (+ port_inst_* banners)
#     user://import/audio/<name>.mp3   one-shots, bundle bytes
#     user://import/audio/<name>.wav   the .m4a loops, decoded to PCM16
#                        <name>.ogg   (development seed only; the importer never writes these)
#     user://import/data/<Table>.json  the plist tables as JSON
#     user://import/nibs/<Screen>.json the nib layouts as JSON -> SceneBuilder
#     user://import/uikit/<File>.png   OPTIONAL iOS 6 UIKit art
#
# What it hands back is built to be indistinguishable from what Godot's
# importer gave the game when the same files were imported into the project:
#
#   * Textures reproduce ResourceImporterTexture with this project's settings
#     (every .import: compress/mode 0 lossless, no mipmaps, fix_alpha_border
#     true, premult off, identity channel remap): the PNG is decoded with the
#     same loader and Image.fix_alpha_edges() runs on it. They are cached per
#     file the way ResourceCache caches a load(): one shared instance while
#     anything holds it. A development check confirms pixel equality with
#     the imported CompressedTexture2D.
#   * Each texture's resource_path is the cache file it came from (so code
#     that keys caches on resource_path, or asks resource_path.get_file(),
#     behaves as before) and resource_name its file name; texture_name() is
#     the supported way to ask "which art is this?".
#   * Lookups are exact-case, as res:// was: on a case-insensitive file
#     system (Windows, macOS) user:// would otherwise start finding art the
#     game never found.
#   * Audio streams are the same classes with the importer's defaults
#     (loop off); Audio.gd switches looping on, as it always did.
#   * Screens come from SceneBuilder, which reproduces the scene generator's
#     .tscn files node for node, and bindings() reproduces its bindings file.
#
# Boot runs the importer when is_ready() is false and calls invalidate()
# afterwards; autoloads that read tables at start-up listen to cache_changed.

extends Node

## Emitted by invalidate(): the cache was (re)written; re-read what you hold.
signal cache_changed

const ROOT := "user://import/"
const MANIFEST := "manifest.json"
const FORMAT := 1

const SceneBuilder := preload("res://core/import/SceneBuilder.gd")

var _manifest: Variant = null           # Dictionary once read ({} = absent)
var _dir_index: Dictionary = {}         # subdir -> {file name: true}
var _textures: Dictionary = {}          # "images/X.png" -> WeakRef
var _audio: Dictionary = {}             # basename -> WeakRef
var _nibs: Dictionary = {}              # screen -> Dictionary
var _screens: Variant = null            # PackedStringArray once listed
var _all_bindings: Variant = null       # Dictionary once built


# -- the cache as a whole ----------------------------------------------------

func root() -> String:
	return ROOT


## True once an import has completed (the importer writes the manifest last).
func is_ready() -> bool:
	var m := manifest()
	return int(m.get("format", 0)) == FORMAT


func manifest() -> Dictionary:
	if _manifest == null:
		_manifest = {}
		var text := FileAccess.get_file_as_string(ROOT + MANIFEST) \
			if FileAccess.file_exists(ROOT + MANIFEST) else ""
		if text != "":
			var parsed: Variant = JSON.parse_string(text)
			if parsed is Dictionary:
				_manifest = parsed
	return _manifest


## Forget everything read so far (call after the importer has written the
## cache) and tell listeners. Textures still on screen stay valid; the next
## request loads afresh.
func invalidate() -> void:
	_manifest = null
	_dir_index.clear()
	_textures.clear()
	_audio.clear()
	_nibs.clear()
	_screens = null
	_all_bindings = null
	SceneBuilder.clear_cache()
	cache_changed.emit()


## Exact-case directory listing of one cache subfolder, read once.
func _index(sub: String) -> Dictionary:
	if not _dir_index.has(sub):
		var names := {}
		var dir := ROOT + sub
		if DirAccess.dir_exists_absolute(dir):
			for f in DirAccess.get_files_at(dir):
				names[f] = true
		_dir_index[sub] = names
	return _dir_index[sub]


func _has(sub: String, file: String) -> bool:
	return file != "" and _index(sub).has(file)


## Is `file` in cache folder `sub` ("images", "audio", "data", "nibs",
## "uikit")? Exact case.
func has_file(sub: String, file: String) -> bool:
	return _has(sub, file)


## The file names in cache folder `sub`, sorted.
func files(sub: String) -> PackedStringArray:
	var out := PackedStringArray(_index(sub).keys())
	out.sort()
	return out


# -- images ------------------------------------------------------------------

func has_image(file: String) -> bool:
	return _has("images", file)


## The cache file behind an image (for code that needs bytes, not a texture).
func image_path(file: String) -> String:
	return ROOT + "images/" + file


## The art as a Texture2D, or null when the bundle has no such file: what
## loading the same art from the project with load() used to answer.
func texture(file: String) -> Texture2D:
	return _texture("images", file)


func has_uikit(file: String) -> bool:
	return _has("uikit", file)


## iOS 6 UIKit art (only present when the player supplied Shared@2x.artwork);
## null when absent -- callers keep their drawn fallback.
func uikit_texture(file: String) -> Texture2D:
	return _texture("uikit", file)


## Which file a texture was loaded from ("btn_back.png"), or "" for one made
## in code. Replaces `texture.resource_path.get_file()`.
func texture_name(tex: Texture2D) -> String:
	if tex == null:
		return ""
	if tex.resource_name != "":
		return tex.resource_name
	return tex.resource_path.get_file()


func _texture(sub: String, file: String) -> Texture2D:
	if not _has(sub, file):
		return null
	var key := sub + "/" + file
	var ref: WeakRef = _textures.get(key)
	if ref != null:
		var alive: Variant = ref.get_ref()
		if alive != null:
			return alive
	var path := ROOT + key
	var img := Image.new()
	if img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK or img.is_empty():
		push_error("Assets: %s is not a readable PNG" % path)
		return null
	as_imported(img)
	var tex := ImageTexture.create_from_image(img)
	tex.resource_name = file
	tex.set_path_cache(path)
	_textures[key] = weakref(tex)
	return tex


## What ResourceImporterTexture does to an image under this project's import
## settings before storing it. Of the [params] every .import file carries,
## only process/fix_alpha_border = true changes pixels: lossless compression
## round-trips exactly (the stored format is restored on load), mipmaps are
## off, premult_alpha / normal_map_invert_y / hdr_* are off, size_limit is 0
## and the channel remap is the identity.
static func as_imported(img: Image) -> void:
	img.fix_alpha_edges()


# -- audio -------------------------------------------------------------------

func has_audio(basename: String) -> bool:
	for ext: String in [".wav", ".ogg", ".mp3"]:
		if _has("audio", basename + ext):
			return true
	return false


## The sound called `basename`: the decoded loop (.wav), else the dev seed's
## Vorbis loop (.ogg), else the one-shot (.mp3); null if none. Cached the way
## ResourceCache cached the imported resource: one shared stream while
## anything holds it, a fresh one (loop off) once nothing does. That matters:
## Audio.loop() switches looping on the shared stream, and a one-shot of the
## same name played while the loop runs loops too, but one played after the
## loop's player is gone does not -- as before.
func audio(basename: String) -> AudioStream:
	var ref: WeakRef = _audio.get(basename)
	if ref != null:
		var alive: Variant = ref.get_ref()
		if alive != null:
			return alive
	var s: AudioStream = null
	if _has("audio", basename + ".wav"):
		s = _wav(FileAccess.get_file_as_bytes(ROOT + "audio/" + basename + ".wav"))
	elif _has("audio", basename + ".ogg"):
		s = AudioStreamOggVorbis.load_from_buffer(
			FileAccess.get_file_as_bytes(ROOT + "audio/" + basename + ".ogg"))
	elif _has("audio", basename + ".mp3"):
		var mp3 := AudioStreamMP3.new()
		mp3.data = FileAccess.get_file_as_bytes(ROOT + "audio/" + basename + ".mp3")
		s = mp3
	if s != null:
		s.resource_name = basename
		_audio[basename] = weakref(s)
	return s


## A RIFF/WAVE PCM 16-bit file (what the importer writes for each .m4a) as an
## AudioStreamWAV with the importer's defaults: no loop. Read directly rather
## than through load_from_buffer() so no import option (QOA compression,
## loop detection) can creep in.
static func _wav(bytes: PackedByteArray) -> AudioStreamWAV:
	if bytes.size() < 12 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF" \
			or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		return null
	var channels := 0
	var rate := 0
	var bits := 0
	var fmt_tag := 0
	var pcm := PackedByteArray()
	var at := 12
	while at + 8 <= bytes.size():
		var id := bytes.slice(at, at + 4).get_string_from_ascii()
		var size := bytes.decode_u32(at + 4)
		var body := at + 8
		if id == "fmt " and size >= 16:
			fmt_tag = bytes.decode_u16(body)
			channels = bytes.decode_u16(body + 2)
			rate = bytes.decode_u32(body + 4)
			bits = bytes.decode_u16(body + 14)
		elif id == "data":
			pcm = bytes.slice(body, mini(body + size, bytes.size()))
		at = body + size + (size & 1)
	if fmt_tag != 1 or bits != 16 or channels < 1 or channels > 2 or rate <= 0:
		push_error("Assets: unsupported WAV (format %d, %d bit, %d ch)" % [fmt_tag, bits, channels])
		return null
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = channels == 2
	w.data = pcm
	return w


## Switch looping on, the way the game always has: an MP3 / Ogg stream's
## `loop` (the whole file, loop_offset 0), and for a decoded loop (.wav) the
## same thing in AudioStreamWAV's terms -- forward over every frame.
static func enable_loop(stream: AudioStream) -> void:
	if stream is AudioStreamMP3 or stream is AudioStreamOggVorbis:
		stream.set("loop", true)
	elif stream is AudioStreamWAV:
		var w := stream as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = wav_frames(w)


## Frames in a 16-bit AudioStreamWAV.
static func wav_frames(w: AudioStreamWAV) -> int:
	return w.data.size() / (4 if w.stereo else 2)


# -- data tables ---------------------------------------------------------------

func has_json(table: String) -> bool:
	return _has("data", _json_file(table))


## data/<table>.json parsed afresh on every call (callers own the result, as
## they did when each read the file itself); null when absent or unparsable.
func json(table: String) -> Variant:
	var file := _json_file(table)
	if not _has("data", file):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(ROOT + "data/" + file))


static func _json_file(table: String) -> String:
	return table if table.ends_with(".json") else table + ".json"


# -- screens -------------------------------------------------------------------

## A screen's nib JSON (shared, read-only), or {} if there is none.
func nib(screen: String) -> Dictionary:
	if not _nibs.has(screen):
		var d: Variant = null
		if _has("nibs", screen + ".json"):
			d = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "nibs/" + screen + ".json"))
		_nibs[screen] = d if d is Dictionary else {}
	return _nibs[screen]


## Every screen that has a scene, under its nib name (variants such as
## `dicFrostingViewController~iphone` included), sorted: the keys the scene
## generator's bindings file had.
func screen_names() -> PackedStringArray:
	if _screens == null:
		# Sorted by FILE name, as the generator's sorted(glob('*.json')) was:
		# "MainWindow-iPad.json" sorts before "MainWindow.json".
		var files := PackedStringArray()
		for f: String in _index("nibs").keys():
			if f.ends_with(".json"):
				files.append(f)
		files.sort()
		var with_scene := PackedStringArray()
		for f in files:
			var n := f.trim_suffix(".json")
			if SceneBuilder.has_scene(nib(n)):
				with_scene.append(n)
		_screens = with_scene
	return _screens


func has_screen(screen: String) -> bool:
	return _has("nibs", screen + ".json") and SceneBuilder.has_scene(nib(screen))


## The screen's node tree, freshly built: what instantiating the scene
## generator's .tscn for it returned. null if absent.
func instantiate_screen(screen: String) -> Node:
	if not has_screen(screen):
		return null
	return SceneBuilder.new(nib(screen), self).build()


## {outlets, actions} for one screen key, exactly as in the bindings file; {} if
## absent. The same dictionary on every call (as Bindings always served).
func bindings(screen: String) -> Dictionary:
	return all_bindings().get(screen, {})


## Every screen's bindings, keyed like the scene generator's bindings file.
func all_bindings() -> Dictionary:
	if _all_bindings == null:
		var all := {}
		for n in screen_names():
			all[n] = SceneBuilder.new(nib(n), self).bindings()
		_all_bindings = all
	return _all_bindings
