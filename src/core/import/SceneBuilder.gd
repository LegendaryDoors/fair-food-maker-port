# Builds a screen's node tree at run time from its nib JSON: the GDScript
# port of the scene generator, which wrote the same tree out as one .tscn
# per screen. Only the target moved: instead of text that Godot
# parses into nodes, this makes the nodes, with the same names, classes,
# scripts, properties (set in the same order), metadata and art, and owner =
# the root, as PackedScene.instantiate() did. bindings() is the screen's
# entry of the generator's old bindings file.
#
# The generator is the spec; every rule below is its rule, and its comments
# explain why each mapping is what it is (UIView -> Node2D, UIImageView ->
# Sprite2D, UIButton -> TextureButton, UILabel/UITextView -> Label, NibView /
# NibImageView / NibLabel for the state those lack, NibBackgroundColor for the
# root's colour). A development check compares this against the .tscn
# files the generator wrote, node by node and property by property.
#
# Numbers follow the .tscn round trip exactly: where the generator wrote a
# Python round(v, n) into the file, this formats the same decimal digits
# (String.num rounds the binary value half-to-even, as Python's round does)
# and parses them back with the same String.to_float the scene parser used;
# Python's int(round(x)) is banker's rounding, reproduced in _py_round_int.
#
# Art comes from the Assets autoload (the import cache), handed in by the
# caller so this file has no compile-time tie to it; an image the cache lacks
# degrades exactly as a missing file did for the generator.

extends RefCounted

const NIB_VIEW := preload("res://core/NibView.gd")
const NIB_IMAGE_VIEW := preload("res://core/NibImageView.gd")
const NIB_LABEL := preload("res://core/NibLabel.gd")

# UIViewContentMode.
const SCALE_TO_FILL := 0
const ASPECT_FIT := 1
const ASPECT_FILL := 2
const NATIVE_SIZE_ALIGN := {
	4: Vector2(0.5, 0.5), 5: Vector2(0.5, 0.0), 6: Vector2(0.5, 1.0),
	7: Vector2(0.0, 0.5), 8: Vector2(1.0, 0.5),
	9: Vector2(0.0, 0.0), 10: Vector2(1.0, 0.0),
	11: Vector2(0.0, 1.0), 12: Vector2(1.0, 1.0),
}

# TextureButton.stretch_mode
const STRETCH_SCALE := 0
const STRETCH_KEEP_CENTERED := 3
const STRETCH_KEEP_ASPECT_CENTERED := 5

const FONT_NAMES := ["Helvetica Neue", "Helvetica", "Nimbus Sans", "Liberation Sans", "Arial"]

const CLASS_MAP := {
	"UIView": "Node2D",
	"UIImageView": "Sprite2D",
	"UIButton": "TextureButton",
	"UIRoundedRectButton": "TextureButton",
	"UILabel": "Label",
	"UITextView": "Label",
	"UIScrollView": "Node2D",
	"UIWindow": "Node2D",
}

const SCREEN_SIZE := [320.0, 480.0]

const OVERRUN_TRIM_ELLIPSIS := 3
const AUTOWRAP_ARBITRARY := 1
const AUTOWRAP_WORD_SMART := 3
const LINE_BREAK_DEFAULT := 4
const MOUSE_FILTER_IGNORE := 2

## A resource in the plan, made real by build(): a texture (by file name), or
## a font / label style shared by every node that plans the same `key` -- the
## generated scene's sub_resources.
class Res:
	var kind: String
	var arg: Variant
	var key: Variant

	func _init(kind_: String, arg_: Variant, key_: Variant = null) -> void:
		kind = kind_
		arg = arg_
		key = key_

static var _invalid_name: RegEx
static var _png_sizes: Dictionary = {}

var _scene: Dictionary
## The Assets autoload: has_image(), texture(), image_path().
var _assets: Object
var _outlet_names: Dictionary = {}
var _vc_view_id: Variant = null
var _paths: Dictionary = {}
## [{name, type, parent, script, props: [[property, value], ...]}] in .tscn order.
var _nodes: Array = []
var _fonts: Dictionary = {}      # weight -> Res
var _styles: Dictionary = {}     # raw rgba (as bytes) -> Res
var _walked := false
var _has_root := false
var missing: Dictionary = {}     # image names the cache lacks


## Does this nib produce a scene at all (the generator skips a null root)?
static func has_scene(nib: Dictionary) -> bool:
	return _truthy(nib.get("root"))


## Forget cached PNG sizes (on Assets.invalidate()).
static func clear_cache() -> void:
	_png_sizes.clear()


func _init(nib: Dictionary, assets: Object) -> void:
	_scene = nib
	_assets = assets
	for o: Dictionary in _scene.get("outlets", []):
		if o.get("viewId") != null and _truthy(o.get("name")):
			_outlet_names[o["viewId"]] = o["name"]
	var root: Variant = _scene.get("root")
	var root_d: Dictionary = root if root is Dictionary else {}
	var views: Array = []
	for o: Dictionary in _scene.get("outlets", []):
		if o.get("name") == "view":
			views.append(o)
	_vc_view_id = views[0].get("viewId") if not views.is_empty() else root_d.get("id")


# -- public ---------------------------------------------------------------

## The node tree (null for a nib without a root).
func build() -> Node:
	if not _walk():
		return null
	var root := Node2D.new()
	root.name = _sanitize(_scene.get("name"))
	var made := {".": root}
	var shared := {}
	for n: Dictionary in _nodes:
		var node: Node = ClassDB.instantiate(n["type"])
		if n["script"] != null:
			node.set_script(n["script"])
		for p: Array in n["props"]:
			node.set(p[0], _resolve(p[1], shared, _assets))
		node.name = n["name"]
		var parent: Node = made[n["parent"]]
		parent.add_child(node)
		node.owner = root
		made[n["path"]] = node
	return root


## {outlets: {name: path}, actions: [{selector, node, sourceClass, events}]}.
func bindings() -> Dictionary:
	if not _walk():
		return {}
	var outlets := {}
	for o: Dictionary in _scene.get("outlets", []):
		if _truthy(o.get("name")) and _paths.has(o.get("viewId")):
			outlets[o["name"]] = _paths[o["viewId"]]
	var actions := []
	for a: Dictionary in _scene.get("actions", []):
		if _paths.has(a.get("viewId")):
			actions.append({
				"selector": a["selector"],
				"node": _paths[a["viewId"]],
				"sourceClass": a.get("sourceClass"),
				"events": a["events"],
			})
	return {"outlets": outlets, "actions": actions}


## The planned nodes (for dev checks): see _nodes.
func plan() -> Array:
	_walk()
	return _nodes


# -- the walk (SceneWriter.render / emit) ----------------------------------

func _walk() -> bool:
	if _walked:
		return _has_root
	_walked = true
	var root: Variant = _scene.get("root")
	_has_root = _truthy(root)
	if not _has_root:
		return false
	_paths[root["id"]] = "."
	var used := {}
	for child: Dictionary in root.get("subviews", []):
		_emit(child, ".", used)
	_emit_root_state(root, used)
	return true


func _emit(node: Dictionary, parent: String, used: Dictionary) -> void:
	var cls: String = node["class"]
	var gd_type: String = CLASS_MAP.get(cls, "Node2D")
	var image: Variant = node.get("image")

	if _truthy(image) and not _assets.has_image(image):
		missing[image] = true
		image = null
		if gd_type == "Sprite2D":
			gd_type = "Node2D"

	var name := _name_for(node, used)
	var frame: Array = node.get("frame") if _truthy(node.get("frame")) else [0, 0, 0, 0]
	var x: float = frame[0]
	var y: float = frame[1]
	var w: float = frame[2]
	var h: float = frame[3]

	var props: Array = []
	var script: Script = null
	var script_props: Array = []
	var meta: Array = []

	if gd_type == "TextureButton":
		props += [["anchors_preset", 0],
			["offset_left", x], ["offset_top", y],
			["offset_right", x + w], ["offset_bottom", y + h]]
		props += _button_art(node, image, w, h)
		meta += _button_meta(node)
	elif gd_type == "Sprite2D" and _truthy(image):
		var placed := _place_sprite(x, y, w, h, _tex_size(image),
			_int(node.get("contentMode", SCALE_TO_FILL)))
		var px: float = placed[0]
		var py: float = placed[1]
		var scale: Variant = placed[2]
		props.append(["position", Vector2(_py_round(px, 3), _py_round(py, 3))])
		props += [["centered", false], ["texture", Res.new("texture", image)]]
		if scale != null and (absf(scale[0] - 1.0) > 1e-4 or absf(scale[1] - 1.0) > 1e-4):
			props.append(["scale", Vector2(_py_round(scale[0], 5), _py_round(scale[1], 5))])
		if _truthy(node.get("clipsToBounds")):
			# The frame in the sprite's local space (texture pixels), from the
			# unrounded position and scale.
			var sx: float = scale[0] if scale != null else 1.0
			var sy: float = scale[1] if scale != null else 1.0
			var local := [(x - px) / sx, (y - py) / sy, w / sx, h / sy]
			script = NIB_IMAGE_VIEW
			script_props += [["clip_rect", Rect2(_py_round(local[0], 4), _py_round(local[1], 4),
					_py_round(local[2], 4), _py_round(local[3], 4))],
				["clips_to_bounds", true]]
	elif gd_type == "Label":
		var grow_h: int = {1: 2, 2: 0}.get(_int(node.get("textAlignment")), 1)
		props += [["anchors_preset", 0],
			["offset_left", x], ["offset_top", y],
			["offset_right", x + w], ["offset_bottom", y + h],
			["grow_horizontal", grow_h], ["grow_vertical", 2]]
		if _truthy(node.get("text")):
			props.append(["text", node["text"]])
		props += _label_style(node)
		props += _label_layout(node)
		if _truthy(node.get("adjustsFontSizeToFitWidth")) \
				and _int(node.get("numberOfLines", 1)) == 1:
			script = NIB_LABEL
			script_props += [["adjusts_font_size_to_fit_width", true],
				["minimum_font_size", node.get("minimumFontSize", 0.0)],
				["minimum_scale_factor", node.get("minimumScaleFactor", 0.0)]]
	else:
		props.append(["position", Vector2(x, y)])
		var vs := _view_state(node, w, h)
		script = vs[0]
		script_props = vs[1]

	if _truthy(node.get("hidden")):
		props.append(["visible", false])
	if node.get("alpha") != null:
		props.append(["modulate", Color(1, 1, 1, node["alpha"])])

	if node.get("userInteractionEnabled") is bool and node["userInteractionEnabled"] == false:
		if gd_type == "TextureButton":
			props.append(["mouse_filter", MOUSE_FILTER_IGNORE])
		elif gd_type == "Label":
			pass
		else:
			meta.append(["metadata/uikit_user_interaction_enabled", false])
	if _truthy(node.get("tag")):
		meta.append(["metadata/uikit_tag", int(node["tag"])])
	if _truthy(node.get("customClass")):
		meta.append(["metadata/uikit_class", str(node["customClass"])])

	var path := name if parent == "." else "%s/%s" % [parent, name]
	_nodes.append({"name": name, "type": gd_type, "parent": parent, "path": path,
		"script": script, "props": props + script_props + meta})
	_paths[node["id"]] = path

	var child_used := {}
	for child: Dictionary in node.get("subviews", []):
		_emit(child, path, child_used)


func _name_for(node: Dictionary, used: Dictionary) -> String:
	var base: String
	var outlet: Variant = _outlet_names.get(node["id"])
	if _truthy(outlet):
		base = _sanitize(outlet)
	elif _truthy(node.get("image")):
		base = _sanitize(_py_stem(node["image"]))
	else:
		base = _sanitize(node["class"])
	var name := base
	var n := 2
	while used.has(name):
		name = "%s_%d" % [base, n]
		n += 1
	used[name] = true
	return name


## [x, y, scale pair or null]: place_sprite(), placing a texture in a frame
## under a UIViewContentMode.
static func _place_sprite(x: float, y: float, fw: float, fh: float, tex: Array,
		mode: int) -> Array:
	var tw := float(tex[0])
	var th := float(tex[1])
	if tw == 0.0 or th == 0.0:
		return [x, y, null]
	if mode == ASPECT_FIT or mode == ASPECT_FILL:
		var s := minf(fw / tw, fh / th) if mode == ASPECT_FIT else maxf(fw / tw, fh / th)
		return [x + (fw - tw * s) / 2.0, y + (fh - th * s) / 2.0, [s, s]]
	if NATIVE_SIZE_ALIGN.has(mode):
		var a: Vector2 = NATIVE_SIZE_ALIGN[mode]
		return [x + (fw - tw) * float(a.x), y + (fh - th) * float(a.y), null]
	# ScaleToFill, and anything unrecognised.
	return [x, y, [fw / tw, fh / th]]


func _view_state(node: Dictionary, w: float, h: float) -> Array:
	var is_vc_view: bool = _vc_view_id != null and node["id"] == _vc_view_id
	var size := Vector2(SCREEN_SIZE[0], SCREEN_SIZE[1]) if is_vc_view else Vector2(w, h)
	var bg: Variant = node.get("backgroundColor")
	if bg is Dictionary:
		bg = null
	var clip := _truthy(node.get("clipsToBounds"))
	var scroll: bool = node["class"] == "UIScrollView" or node.get("originalClass") == "UIScrollView"
	var props: Array = []
	var meta: Array = []
	if clip and scroll:
		clip = false
		meta.append(["metadata/uikit_clips_to_bounds", true])
	if not (_truthy(bg) or clip):
		return [null, meta]
	props.append(["nib_size", size])
	if _truthy(bg):
		props.append(["background_color", _color(bg)])
	if clip:
		props.append(["clips_to_bounds", true])
	return [NIB_VIEW, props + meta]


func _button_art(node: Dictionary, image: Variant, w: float, h: float) -> Array:
	var states: Dictionary = node.get("states", {})
	var bg: Variant = node.get("backgroundImage")
	if _truthy(bg) and not _assets.has_image(bg):
		missing[bg] = true
		bg = null
	var key: String
	var normal: String
	var stretch: int
	if _truthy(bg):
		key = "backgroundImage"
		normal = bg
		stretch = STRETCH_SCALE
	elif _truthy(image):
		var ts := _tex_size(image)
		var fits: bool = float(ts[0]) <= w + 0.5 and float(ts[1]) <= h + 0.5
		key = "image"
		normal = image
		stretch = STRETCH_KEEP_CENTERED if fits else STRETCH_KEEP_ASPECT_CENTERED
	else:
		return []
	var lines: Array = [["texture_normal", Res.new("texture", normal)]]
	for pair: Array in [["highlighted", "texture_pressed"], ["disabled", "texture_disabled"]]:
		var st: Dictionary = states.get(pair[0], {})
		var art: Variant = st.get(key)
		if not _truthy(art):
			continue
		if not _assets.has_image(art):
			missing[art] = true
			continue
		lines.append([pair[1], Res.new("texture", art)])
	lines += [["ignore_texture_size", true], ["stretch_mode", stretch]]
	if node.get("enabled") is bool and node["enabled"] == false:
		lines.append(["disabled", true])
	return lines


func _button_meta(node: Dictionary) -> Array:
	var states: Dictionary = node.get("states", {})
	var meta: Array = []
	for pair: Array in [["adjustsImageWhenHighlighted", "uikit_adjusts_highlighted"],
			["adjustsImageWhenDisabled", "uikit_adjusts_disabled"]]:
		var v: Variant = node.get(pair[0])
		meta.append(["metadata/" + pair[1], not (v is bool and v == false)])
	for pair: Array in [["highlighted", "uikit_has_highlighted_art"],
			["disabled", "uikit_has_disabled_art"]]:
		var st: Dictionary = states.get(pair[0], {})
		if _truthy(st.get("image")) or _truthy(st.get("backgroundImage")):
			meta.append(["metadata/" + pair[1], true])
	return meta


## `.HelveticaNeueInterface-MediumP4` is the medium weight; everything else in
## these nibs is regular (font_resource()).
func _font(font_name: Variant) -> Res:
	var fname: String = font_name if font_name is String else ""
	var weight := 500 if "Medium" in fname else 700 if "Bold" in fname else 400
	if not _fonts.has(weight):
		_fonts[weight] = Res.new("font", weight, "font%d" % weight)
	return _fonts[weight]


func _label_style(node: Dictionary) -> Array:
	var lines: Array = [["theme_override_fonts/font", _font(node.get("fontName"))]]
	var size: Variant = node.get("fontSize")
	if _truthy(size):
		lines.append(["theme_override_font_sizes/font_size", _py_round_int(size)])
	var color: Variant = node.get("textColor")
	if _truthy(color):
		lines.append(["theme_override_colors/font_color",
			Color(color[0], color[1], color[2], color[3])])
	var align: Variant = node.get("textAlignment")
	if align != null and (_int(align) == 1 or _int(align) == 2):
		lines.append(["horizontal_alignment", _int(align)])
	if node["class"] == "UITextView":
		lines.append(["vertical_alignment", 0])
	else:
		lines.append(["vertical_alignment", 1])
	return lines


func _label_layout(node: Dictionary) -> Array:
	var lines: Array = []
	if _truthy(node.get("clipsToBounds")):
		lines.append(["clip_text", true])
	if node["class"] == "UITextView":
		lines.append(["autowrap_mode", AUTOWRAP_WORD_SMART])
	else:
		var lines_n := _int(node.get("numberOfLines", 1))
		var mode := _int(node.get("lineBreakMode", LINE_BREAK_DEFAULT))
		if lines_n != 1:
			lines.append(["autowrap_mode", AUTOWRAP_ARBITRARY if mode == 1 else AUTOWRAP_WORD_SMART])
			if lines_n > 1:
				lines.append(["max_lines_visible", lines_n])
		if mode == LINE_BREAK_DEFAULT:
			lines.append(["text_overrun_behavior", OVERRUN_TRIM_ELLIPSIS])
	var shadow: Variant = node.get("shadowColor")
	if _truthy(shadow) and float(shadow[3]) > 0.0:
		var off: Array = node.get("shadowOffset", [0.0, -1.0])
		lines += [["theme_override_colors/font_shadow_color", _color(shadow)],
			["theme_override_constants/shadow_offset_x", _py_round_int(off[0])],
			["theme_override_constants/shadow_offset_y", _py_round_int(off[1])]]
	var bg: Variant = node.get("backgroundColor")
	if bg is Array:
		# One StyleBoxFlat per distinct raw colour, as the generator keyed
		# its sub_resources on tuple(bg) before rounding.
		var key := var_to_bytes(bg)
		if not _styles.has(key):
			_styles[key] = Res.new("style", _color(bg), "style%d" % (_styles.size() + 1))
		lines.append(["theme_override_styles/normal", _styles[key]])
	return lines


func _emit_root_state(root: Dictionary, used: Dictionary) -> void:
	if _vc_view_id != null and root["id"] != _vc_view_id:
		return
	var bg: Variant = root.get("backgroundColor")
	if not (bg is Array):
		return
	var name := "NibBackgroundColor"
	var n := 2
	while used.has(name):
		name = "NibBackgroundColor_%d" % n
		n += 1
	used[name] = true
	_nodes.append({"name": name, "type": "Node2D", "parent": ".", "path": name,
		"script": NIB_VIEW, "props": [["show_behind_parent", true],
			["nib_size", Vector2(SCREEN_SIZE[0], SCREEN_SIZE[1])],
			["background_color", _color(bg)]]})


# -- resources ----------------------------------------------------------------

## Turn a planned value into what goes on the node.
static func _resolve(v: Variant, shared: Dictionary, assets: Object) -> Variant:
	if not (v is Res):
		return v
	var r := v as Res
	if r.kind == "texture":
		return assets.texture(r.arg)
	if not shared.has(r.key):
		match r.kind:
			"font":
				var f := SystemFont.new()
				f.font_names = PackedStringArray(FONT_NAMES)
				if int(r.arg) != 400:
					f.font_weight = int(r.arg)
				shared[r.key] = f
			"style":
				var st := StyleBoxFlat.new()
				st.bg_color = r.arg
				shared[r.key] = st
	return shared[r.key]


func _tex_size(image: String) -> Array:
	if not _png_sizes.has(image):
		_png_sizes[image] = _png_size(_assets.image_path(image))
	return _png_sizes[image]


## Width/height from a PNG header without decoding (png_size()); [0, 0] when
## the file is not a PNG.
static func _png_size(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return [0, 0]
	var head := f.get_buffer(33)
	if head.size() < 24 or head.slice(0, 8) != PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
		return [0, 0]
	var off := 24 if head.slice(12, 16).get_string_from_ascii() == "CgBI" else 8
	if head.size() < off + 16 or head.slice(off + 4, off + 8).get_string_from_ascii() != "IHDR":
		return [0, 0]
	var be := head.slice(off + 8, off + 16)
	be.reverse()
	return [be.decode_u32(4), be.decode_u32(0)]


# -- Python semantics -----------------------------------------------------------

## Python truthiness for JSON values.
static func _truthy(v: Variant) -> bool:
	match typeof(v):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING, TYPE_STRING_NAME:
			return str(v) != ""
		TYPE_ARRAY:
			return not (v as Array).is_empty()
		TYPE_DICTIONARY:
			return not (v as Dictionary).is_empty()
	return true


static func _int(v: Variant) -> int:
	return int(v) if v != null else -1


## round(v, n) as it reached the scene: the decimal string Python printed,
## parsed by Godot.
static func _py_round(v: float, digits: int) -> float:
	return String.num(v, digits).to_float()


## int(round(v)): round half to even.
static func _py_round_int(v: Variant) -> int:
	var f := float(v)
	var fl := floorf(f)
	var d := f - fl
	if d > 0.5:
		return int(fl) + 1
	if d < 0.5:
		return int(fl)
	return int(fl) if int(fl) % 2 == 0 else int(fl) + 1


## SceneWriter.color(): each component round(c, 4).
static func _color(rgba: Array) -> Color:
	var c := []
	for v in rgba:
		c.append(_py_round(float(v), 4))
	if c.size() == 3:
		return Color(c[0], c[1], c[2])
	return Color(c[0], c[1], c[2], c[3])


## sanitize(): non [A-Za-z0-9_] -> "_", strip "_" at both ends, "N" before a
## leading digit, "Node" if nothing is left.
static func _sanitize(text: Variant, fallback := "Node") -> String:
	if _invalid_name == null:
		_invalid_name = RegEx.create_from_string("[^A-Za-z0-9_]")
	var s := _invalid_name.sub(str(text), "_", true)
	s = s.lstrip("_").rstrip("_")
	if s == "":
		return fallback
	var c := s.unicode_at(0)
	return "N" + s if c >= 48 and c <= 57 else s


## pathlib's Path(p).stem.
static func _py_stem(p: String) -> String:
	var name := p.rstrip("/")
	var slash := name.rfind("/")
	if slash >= 0:
		name = name.substr(slash + 1)
	var dot := name.rfind(".")
	if dot > 0 and dot < name.length() - 1:
		return name.substr(0, dot)
	return name
