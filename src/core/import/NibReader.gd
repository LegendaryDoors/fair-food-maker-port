# Compiled .nib -> scene description, for the in-game IPA importer: a
# GDScript port of the Python nib converter. The output Dictionary is the
# one that converter writes as <Screen>.json (verified 86/86 identical
# against the Python, values and bytes):
#
#     {name, designSize: [320, 480], root: {id, class, frame, ...,
#      subviews: [...]}, outlets: [{name, class, viewId}],
#      actions: [{selector, sourceClass, sourceImage, viewId, events}]}
#
# This file follows the Python nib converter line for line, including its
# Python semantics: truthiness tests (`if tag:`),
# `is True` / `is False` identity tests on archived flags, int-vs-float
# distinctions (alpha must be a float, numberOfLines an int), CPython's
# round(x, n) via PyJson.round_ndigits, max() keeping the first widest root
# and sorted()'s stability for outlets and actions.
#
# Usage (from the importer):
#
#     var groups := NibReader.nib_groups(zip.files(), zip.app_prefix())
#     for screen in groups:                     # {screen: {file: zip path}}
#         var src := NibReader.source_name(groups[screen])
#         var r := NibReader.convert_result({src: zip.read(groups[screen][src])}, screen)
#         if r.ok: write PyJson.dumps(r.value) to nibs/<screen>.json
#
# Where the Python would raise on a malformed archive this returns
# {ok: false, error}; it never raises a GDScript runtime error on bad input.
# Static/stateless -- safe on the importer's worker thread.
extends RefCounted

const NibArchive := preload("res://core/import/NibArchive.gd")
const KeyedArchive := preload("res://core/import/KeyedArchive.gd")
const Plist := preload("res://core/import/Plist.gd")
const PyJson := preload("res://core/import/PyJson.gd")

# UIControlEvents bits seen in this app, in the nib converter's dict order.
const EVENT_MASKS := [
	[1 << 0, "touchDown"],
	[1 << 1, "touchDownRepeat"],
	[1 << 2, "touchDragInside"],
	[1 << 3, "touchDragOutside"],
	[1 << 4, "touchDragEnter"],
	[1 << 5, "touchDragExit"],
	[1 << 6, "touchUpInside"],
	[1 << 7, "touchUpOutside"],
	[1 << 8, "touchCancel"],
	[1 << 12, "valueChanged"],
]

# UIControlState values used as UIButtonStatefulContent keys. Combined states
# (e.g. 5 = highlighted|selected) keep their number as the name.
const BUTTON_STATES := {0: "normal", 1: "highlighted", 2: "disabled", 4: "selected"}

# UIButtonContent key -> JSON field, in the nib converter's order.
const BUTTON_CONTENT_KEYS := [
	["UIImage", "image"],
	["UIBackgroundImage", "backgroundImage"],
	["UITitle", "title"],
	["UITitleColor", "titleColor"],
	["UIShadowColor", "titleShadowColor"],
]

const _IMAGE_WALK_KEYS := ["UIImage", "UIButtonStatefulContent", "UINibEncoderEmptyKey",
	"UINormalImage", "UIHighlightedImage"]


# --- public API ----------------------------------------------------------------

## The app's top-level *.nib entries as the nib converter's
## sorted(app.glob('*.nib')) sees them: {screen: {file name: zip path}},
## screens sorted. A directory nib lists its direct members (objects.nib,
## runtime.nib, objects-8.0+.nib); a flat nib file (MainWindow-iPad.nib in
## v1.27) maps its own name to itself.
static func nib_groups(paths: PackedStringArray, app_prefix: String) -> Dictionary:
	var tmp := {}
	for p in paths:
		if not p.begins_with(app_prefix):
			continue
		var rel := p.substr(app_prefix.length())
		var top := rel.get_slice("/", 0)
		if not top.ends_with(".nib") or top.begins_with(".") or top.length() <= 4:
			continue
		var screen := top.substr(0, top.length() - 4)        # Path.stem
		if not tmp.has(screen):
			tmp[screen] = {}
		if rel == top:
			tmp[screen][top] = p
		else:
			var member := rel.substr(top.length() + 1)
			if member.find("/") < 0 and not member.is_empty():
				tmp[screen][member] = p
	var names: Array = tmp.keys()
	names.sort()
	var out := {}
	for n in names:
		out[n] = tmp[n]
	return out


## The file the nib converter reads from a nib: objects.nib (the encoder writes the
## same graph into runtime.nib and objects-8.0+.nib), else the first *.nib --
## which, for a flat nib, is the nib itself. "" if there is none.
static func source_name(files: Dictionary) -> String:
	if files.has("objects.nib"):
		return "objects.nib"
	var names: Array = []
	for k in files:
		if typeof(k) == TYPE_STRING and k.ends_with(".nib"):
			names.append(k)
	names.sort()
	return names[0] if not names.is_empty() else ""


## The nib converter's output for one nib, or {} on failure (see
## convert_result).
## `files` maps the nib's file names to their bytes; only source_name(files)
## is read, so passing just that one entry is enough.
static func nib_to_dict(files: Dictionary, screen_name: String) -> Dictionary:
	var r := convert_result(files, screen_name)
	if not r.ok:
		push_error("NibReader: %s: %s" % [screen_name, r.error])
		return {}
	return r.value


## {ok: bool, value: Dictionary, error: String}
static func convert_result(files: Dictionary, screen_name: String) -> Dictionary:
	var src := source_name(files)
	if src == "":
		return {"ok": false, "value": {}, "error": "no objects.nib"}
	var data: Variant = files[src]
	if typeof(data) != TYPE_PACKED_BYTE_ARRAY:
		return {"ok": false, "value": {}, "error": "%s is not bytes" % src}
	return convert_bytes(data, screen_name)


## {ok, value, error} for the bytes of one compiled nib file.
static func convert_bytes(data: PackedByteArray, screen_name: String) -> Dictionary:
	var archive: Variant
	if NibArchive.is_nib_archive(data):
		archive = NibArchive.new()
	else:
		archive = KeyedArchive.new()
	archive.load_bytes(data)
	if archive.error != "":
		return {"ok": false, "value": {}, "error": archive.error}
	var conv := _Converter.new(archive)
	var scene: Dictionary = conv.convert(screen_name)
	var err: String = conv.error if conv.error != "" else archive.error
	if err != "":
		return {"ok": false, "value": {}, "error": err}
	return {"ok": true, "value": scene, "error": ""}


## CGPoint/CGRect payload -> flat Array of floats, or null (decode_geometry).
## NIBArchive tags the component width in byte 0: 0x06 float32 (iOS 5 SDK),
## 0x07 float64 (iOS 8 SDK), then a bare little-endian array. NSKeyedArchiver
## stores the AppKit string form, '{{0, 0}, {320, 480}}'.
static func decode_geometry(blob: Variant) -> Variant:
	return _Converter.decode_geometry(blob)


# --- the converter (the Python NibConverter) ----------------------------------

class _Converter:
	var a: Variant               # NibArchive or KeyedArchive
	## View object -> the id it got during the tree walk, so outlet and action
	## connections can name a concrete node.
	var ids := {}
	var next_id := 0
	var error := ""

	func _init(archive: Variant) -> void:
		a = archive

	func _fail(msg: String) -> void:
		if error == "":
			error = msg

	# -- Python semantics ---------------------------------------------------

	## bool(v)
	static func truthy(v: Variant) -> bool:
		match typeof(v):
			TYPE_NIL:
				return false
			TYPE_BOOL:
				return v
			TYPE_INT:
				return v != 0
			TYPE_FLOAT:
				return v != 0.0
			TYPE_STRING:
				return not (v as String).is_empty()
			TYPE_ARRAY, TYPE_DICTIONARY, TYPE_PACKED_BYTE_ARRAY:
				return v.size() > 0
		return true                    # objects (no __len__/__bool__ in the Python)

	## isinstance(v, (int, float)) and not isinstance(v, bool)
	static func is_num(v: Variant) -> bool:
		return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT

	## isinstance(v, (int, float)) -- bool is an int subclass in Python
	static func is_num_or_bool(v: Variant) -> bool:
		return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_BOOL

	## v is True
	static func is_true(v: Variant) -> bool:
		return typeof(v) == TYPE_BOOL and v

	## v is False
	static func is_false(v: Variant) -> bool:
		return typeof(v) == TYPE_BOOL and not v

	static func r(x: Variant, n: int) -> float:
		return PyJson.round_ndigits(float(x), n)

	# -- helpers --------------------------------------------------------------

	func deref(v: Variant) -> Variant:
		return a.resolve(v)

	func array_items(obj: Variant) -> Array:
		if obj == null:
			return []
		if not (obj is NibArchive.NibObject):
			_fail("expected an archived object, got %s" % type_string(typeof(obj)))
			return []
		var out: Array = []
		for kv in obj.values:
			if typeof(kv[0]) == TYPE_STRING and kv[0] == "UINibEncoderEmptyKey":
				out.append(kv[1])
		return out

	func string(v: Variant) -> Variant:
		var o: Variant = deref(v)
		if o == null:
			return null
		if not (o is NibArchive.NibObject):
			_fail("string() of a non-object")
			return null
		var raw: Variant = o.val("NS.bytes")
		if typeof(raw) == TYPE_PACKED_BYTE_ARRAY:
			return (raw as PackedByteArray).get_string_from_utf8()
		return null

	## A geometry key, following a reference if the encoder used one (keyed
	## archives point at a '{{x, y}, {w, h}}' string).
	func geom(obj: Variant, key: String) -> Variant:
		var v: Variant = obj.val(key)
		if v is NibArchive.Ref:
			var resolved: Variant = deref(v)
			v = string(v) if resolved is NibArchive.NibObject else resolved
		return decode_geometry(v)

	static func decode_geometry(blob: Variant) -> Variant:
		if typeof(blob) == TYPE_STRING:
			var s: String = blob.replace("{", " ").replace("}", " ").replace(",", " ")
			var out: Array = []
			for tok in _split_ws(s):
				var f: Variant = PyJson.parse_float(tok)
				if f == null:
					return null
				out.append(f)
			return out
		if typeof(blob) != TYPE_PACKED_BYTE_ARRAY or (blob as PackedByteArray).is_empty():
			return null
		var b: PackedByteArray = blob
		var tag := b[0]
		var body := b.slice(1)
		var out2: Array = []
		if tag == 0x06:
			for i in body.size() / 4:
				out2.append(body.decode_float(i * 4))
		elif tag == 0x07:
			for i in body.size() / 8:
				out2.append(body.decode_double(i * 8))
		else:
			return null
		return out2

	## str.split() on ASCII whitespace.
	static func _split_ws(s: String) -> PackedStringArray:
		for ws in ["\t", "\n", "\r", "\u000b", "\u000c"]:
			s = s.replace(ws, " ")
		return s.split(" ", false)

	## The first image resource name reachable from obj. Buttons nest their
	## art two or three levels down, so this walks rather than reading a path.
	func image_name(obj: Variant, depth: int = 0) -> Variant:
		if obj == null or depth > 4:
			return null
		if not (obj is NibArchive.NibObject):
			_fail("image_name() of a non-object")
			return null
		var name: Variant = obj.val("UIResourceName")
		if name != null:
			return string(name)
		for kv in obj.values:
			if typeof(kv[0]) == TYPE_STRING and _IMAGE_WALK_KEYS.has(kv[0]):
				var found: Variant = image_name(deref(kv[1]), depth + 1)
				if truthy(found):
					return found
		return null

	func _num(c: NibArchive.NibObject, k: String) -> Variant:
		var x: Variant = c.val(k)
		return x if is_num(x) else null

	## An archived UIColor: {rgba: [r, g, b, a]} plus 'pattern' (image name)
	## and 'system' (named system colour), or null.
	func color(v: Variant) -> Variant:
		var c: Variant = deref(v)
		if not (c is NibArchive.NibObject):
			return null
		var out := {}
		var alpha: Variant = _num(c, "UIAlpha")
		var rgba: Variant = null
		if _num(c, "UIRed") != null:
			var g: Variant = _num(c, "UIGreen")
			var bl: Variant = _num(c, "UIBlue")
			rgba = [_num(c, "UIRed"), g if truthy(g) else 0.0, bl if truthy(bl) else 0.0]
		elif _num(c, "UIWhite") != null:
			var w: Variant = _num(c, "UIWhite")
			rgba = [w, w, w]
		else:
			for pair in [["NSRGB", 3], ["NSWhite", 1]]:
				var raw: Variant = c.val(pair[0])
				if typeof(raw) != TYPE_PACKED_BYTE_ARRAY:
					continue
				var vals: Variant = _bytes_floats(raw)
				if vals == null:
					continue                     # ValueError
				if not vals.is_empty():
					var comps: int = pair[1]
					rgba = vals.slice(0, 3) if comps == 3 else [vals[0], vals[0], vals[0]]
					if alpha == null and vals.size() > comps:
						alpha = vals[comps]
					break
		if rgba != null:
			var arr: Array = []
			for x in rgba:
				arr.append(r(x, 4))
			arr.append(r(1.0 if alpha == null else alpha, 4))
			out["rgba"] = arr
		var pattern: Variant = image_name(c)
		if truthy(pattern):
			out["pattern"] = pattern
		var sys: Variant = string(c.val("UISystemColorName"))
		if truthy(sys):
			out["system"] = sys
		return out if not out.is_empty() else null

	## [float(x) for x in raw.rstrip(b'\0').split()], or null on ValueError.
	static func _bytes_floats(raw: PackedByteArray) -> Variant:
		var end := raw.size()
		while end > 0 and raw[end - 1] == 0:
			end -= 1
		var out: Array = []
		var tok := PackedByteArray()
		for i in end + 1:
			var c: int = raw[i] if i < end else 0x20
			if c == 0x20 or (c >= 0x09 and c <= 0x0D):
				if not tok.is_empty():
					for b in tok:
						if b < 0x21 or b > 0x7E:
							return null
					var f: Variant = PyJson.parse_float(tok.get_string_from_ascii())
					if f == null:
						return null
					out.append(f)
					tok = PackedByteArray()
			else:
				tok.append(c)
		return out

	func rgba_of(v: Variant) -> Variant:
		var c: Variant = color(v)
		return c.get("rgba") if truthy(c) else null

	## (key, value) pairs of an archived NSDictionary. NIBArchive interleaves
	## keys and values under UINibEncoderEmptyKey; NSKeyedArchiver keeps the
	## keys in NS.keys and only the values in NS.objects.
	func dict_items(obj: Variant) -> Array:
		if obj == null:
			return []
		var items: Array = []
		for v in array_items(obj):
			items.append(deref(v))
		if not (obj is NibArchive.NibObject):
			return []
		var keys: Variant = obj.val("NS.keys")
		var out: Array = []
		if typeof(keys) == TYPE_ARRAY:
			for i in mini(keys.size(), items.size()):
				var k: Variant = keys[i]
				var idx: Variant = k.value if k is Plist.Uid else k
				if typeof(idx) != TYPE_INT or idx < -a.objects.size() or idx >= a.objects.size():
					_fail("NS.keys entry out of range")
					return []
				out.append([a.objects[idx], items[i]])
			return out
		for i in items.size() / 2:
			out.append([items[2 * i], items[2 * i + 1]])
		return out

	## UIButtonStatefulContent as {state name: {image, title, ...}}.
	func button_states(obj: Variant) -> Dictionary:
		var states := {}
		var stateful: Variant = deref(obj.val("UIButtonStatefulContent"))
		for pair in dict_items(stateful):
			var key: Variant = pair[0]
			var content: Variant = pair[1]
			if not (content is NibArchive.NibObject) or content.cls != "UIButtonContent":
				continue
			var n: Variant = key.val("NS.intval") if key is NibArchive.NibObject else null
			if typeof(n) == TYPE_BOOL:
				n = int(n)                      # isinstance(True, int); True == 1
			if typeof(n) != TYPE_INT:
				continue
			var entry := {}
			for kf in BUTTON_CONTENT_KEYS:
				var k: String = kf[0]
				var field: String = kf[1]
				var v: Variant = content.val(k)
				if v == null:
					continue
				if k == "UIImage" or k == "UIBackgroundImage":
					var ph: Variant = deref(v)
					var name: Variant = null
					if truthy(ph):
						if not (ph is NibArchive.NibObject):
							_fail("button image is not an object")
							continue
						name = string(ph.val("UIResourceName"))
					if truthy(name):
						entry[field] = name
				elif k == "UITitle":
					var t: Variant = string(v)
					if t != null:
						entry[field] = t
				else:
					var rgba: Variant = rgba_of(v)
					if truthy(rgba):
						entry[field] = rgba
			if not entry.is_empty():
				states[BUTTON_STATES.get(n, str(n))] = entry
		return states

	## [name, point size] of the object's archived UIFont.
	func font(obj: Variant) -> Array:
		var f: Variant = deref(obj.val("UIFont"))
		if f == null:
			return [null, null]
		if not (f is NibArchive.NibObject):
			_fail("UIFont is not an object")
			return [null, null]
		var size: Variant = f.val("UIFontPointSize")
		return [string(f.val("UIFontName")), r(size, 2) if is_num_or_bool(size) else null]

	## Font size/name, alignment and colour of a UILabel / UITextView.
	func label_style(obj: Variant, node: Dictionary) -> void:
		var f: Variant = deref(obj.val("UIFont"))
		if f != null:
			if not (f is NibArchive.NibObject):
				_fail("UIFont is not an object")
				return
			var size: Variant = f.val("UIFontPointSize")
			if is_num_or_bool(size):
				node["fontSize"] = r(size, 2)
			var name: Variant = string(f.val("UIFontName"))
			if truthy(name):
				node["fontName"] = name
		# UITextAlignment: 0 left (the default, omitted), 1 centre, 2 right.
		var align: Variant = obj.val("UITextAlignment")
		if truthy(align):
			node["textAlignment"] = align
		var rgba: Variant = rgba_of(obj.val("UITextColor"))
		if truthy(rgba):
			node["textColor"] = rgba

	## UILabel sizing, line-break and shadow keys, as archived.
	func label_layout(obj: Variant, node: Dictionary) -> void:
		if is_true(obj.val("UIAdjustsFontSizeToFit")):
			node["adjustsFontSizeToFitWidth"] = true
		for kf in [["UIMinimumFontSize", "minimumFontSize"],
				["UIMinimumScaleFactor", "minimumScaleFactor"]]:
			var v: Variant = obj.val(kf[0])
			if is_num(v):
				node[kf[1]] = r(v, 4)
		for kf2 in [["UINumberOfLines", "numberOfLines"],
				["UILineBreakMode", "lineBreakMode"],
				["UIBaselineAdjustment", "baselineAdjustment"]]:
			var v2: Variant = obj.val(kf2[0])
			if typeof(v2) == TYPE_INT:
				node[kf2[1]] = v2
		var shadow: Variant = rgba_of(obj.val("UIShadowColor"))
		if truthy(shadow):
			node["shadowColor"] = shadow
		var offset: Variant = geom(obj, "UIShadowOffset")
		if offset != null and offset.size() >= 2:
			node["shadowOffset"] = [r(offset[0], 2), r(offset[1], 2)]
		var hl: Variant = rgba_of(obj.val("UIHighlightedColor"))
		if truthy(hl):
			node["highlightedTextColor"] = hl

	# -- view tree ------------------------------------------------------------

	func view(obj: Variant) -> Variant:
		if obj == null:
			return null
		if not (obj is NibArchive.NibObject):
			_fail("view() of a non-object")
			return null
		# A view that is its own ancestor (only in a corrupt archive) would
		# recurse forever; CPython stops there with RecursionError.
		if _active.has(obj) or _active.size() > 200:
			_fail("cyclic or too deeply nested view tree")
			return null
		if error != "":
			return null
		_active[obj] = true
		var node: Variant = _view(obj)
		_active.erase(obj)
		return node

	var _active := {}

	func _view(obj: NibArchive.NibObject) -> Dictionary:
		var bounds: Variant = geom(obj, "UIBounds")
		var center: Variant = geom(obj, "UICenter")
		var node := {"id": next_id, "class": obj.cls}
		ids[obj] = next_id
		next_id += 1

		if bounds != null and center != null and bounds.size() >= 4 and center.size() >= 2:
			var w: float = bounds[2]
			var h: float = bounds[3]
			node["frame"] = [r(center[0] - w / 2, 2), r(center[1] - h / 2, 2), r(w, 2), r(h, 2)]

		if obj.cls == "UIClassSwapper":
			# A custom class (DraggableIV, TintedIV, SSEmitter, ...) standing in
			# for a UIKit view; `class` stays UIClassSwapper.
			for kf in [["UIClassName", "customClass"], ["UIOriginalClassName", "originalClass"]]:
				var cname: Variant = string(obj.val(kf[0]))
				if truthy(cname):
					node[kf[1]] = cname

		# runtime.nib archives the 18 debug-skip buttons as UIRoundedRectButton;
		# objects.nib, read here, says UIButton + UIButtonType 1.
		var is_button: bool = obj.cls == "UIButton" or obj.cls == "UIRoundedRectButton"
		var states: Dictionary = button_states(obj) if is_button else {}
		if is_button:
			# `image` / `backgroundImage` are the NORMAL state's.
			if not states.is_empty():
				node["states"] = states
			if truthy(states.get("normal", {}).get("image")):
				node["image"] = states["normal"]["image"]
		else:
			var img: Variant = image_name(obj)
			if truthy(img):
				node["image"] = img

		if is_button:
			var bg: Variant = states.get("normal", {}).get("backgroundImage")
			if truthy(bg):
				node["backgroundImage"] = bg
			var btype: Variant = obj.val("UIButtonType")
			if typeof(btype) == TYPE_INT and btype != 0:
				node["buttonType"] = btype
			if is_true(obj.val("UIDisabled")):
				node["enabled"] = false
			for kf2 in [["UISelected", "selected"], ["UIHighlighted", "highlighted"]]:
				if is_true(obj.val(kf2[0])):
					node[kf2[1]] = true
			# UIKit's darken-on-highlight / dim-when-disabled switches; default
			# YES, always recorded.
			for kf3 in [["UIAdjustsImageWhenHighlighted", "adjustsImageWhenHighlighted"],
					["UIAdjustsImageWhenDisabled", "adjustsImageWhenDisabled"]]:
				var v: Variant = obj.val(kf3[0])
				node[kf3[1]] = true if v == null else truthy(v)
			if is_true(obj.val("UIShowsTouchWhenHighlighted")):
				node["showsTouchWhenHighlighted"] = true
			var fnt := font(obj)
			if truthy(fnt[1]):
				node["titleFont"] = {"name": fnt[0], "size": fnt[1]}

		if obj.cls == "UILabel" or obj.cls == "UITextView":
			label_style(obj, node)
		if obj.cls == "UILabel":
			label_layout(obj, node)

		var text: Variant = obj.val("UIText")
		if text != null:
			node["text"] = string(text)

		# UIViewContentMode; absent means 0 (ScaleToFill).
		var mode: Variant = obj.val("UIContentMode")
		if truthy(mode):
			node["contentMode"] = mode

		# Only non-default view state.
		if is_true(obj.val("UIHidden")):
			node["hidden"] = true
		var alpha: Variant = obj.val("UIAlpha")
		if typeof(alpha) == TYPE_FLOAT and alpha != 1.0:
			node["alpha"] = r(alpha, 3)
		var tag: Variant = obj.val("UITag")
		if truthy(tag):
			node["tag"] = tag
		var mask: Variant = obj.val("UIAutoresizingMask")
		if truthy(mask):
			node["autoresizingMask"] = mask
		if is_true(obj.val("UIUserInteractionDisabled")):
			node["userInteractionEnabled"] = false
		# backgroundColor: clear (alpha 0) is left out; a pattern colour is
		# kept whole ({rgba, pattern}).
		var bgc: Variant = color(obj.val("UIBackgroundColor"))
		if truthy(bgc) and truthy(bgc.get("pattern")):
			node["backgroundColor"] = bgc
		elif truthy(bgc) and truthy(bgc.get("rgba")) and bgc["rgba"][3] > 0:
			node["backgroundColor"] = bgc["rgba"]
		if is_true(obj.val("UIClipsToBounds")):
			node["clipsToBounds"] = true
		if is_true(obj.val("UIOpaque")):
			node["opaque"] = true
		var stretch: Variant = geom(obj, "UIContentStretch")
		if stretch != null and stretch.size() >= 4 and not (stretch[0] == 0.0 and stretch[1] == 0.0
				and stretch[2] == 1.0 and stretch[3] == 1.0):
			node["contentStretch"] = [r(stretch[0], 4), r(stretch[1], 4), r(stretch[2], 4), r(stretch[3], 4)]
		for kf4 in [["UIShowsHorizontalScrollIndicator", "showsHorizontalScrollIndicator"],
				["UIShowsVerticalScrollIndicator", "showsVerticalScrollIndicator"]]:
			if is_false(obj.val(kf4[0])):
				node[kf4[1]] = false

		var kids: Array = []
		for ref in array_items(deref(obj.val("UISubviews"))):
			kids.append(view(deref(ref)))
		var live: Array = []
		for k in kids:
			if truthy(k):
				live.append(k)
		if not live.is_empty():
			node["subviews"] = live
		return node

	func convert(name: String) -> Dictionary:
		if a.objects.is_empty():
			_fail("archive has no objects")
			return {}
		var root_obj: Variant = a.objects[0]
		var objects := array_items(deref(root_obj.val("UINibObjectsKey")))

		# The file's owner is a proxy; the screen is the widest top-level UI*
		# view (max() keeps the first of equal areas).
		var best: Variant = null
		var best_area := 0.0
		var found := false
		for ref in objects:
			var o: Variant = deref(ref)
			if not (o is NibArchive.NibObject) or not o.cls.begins_with("UI"):
				continue
			var g: Variant = geom(o, "UIBounds")
			if g != null and g.size() >= 4:
				var area: float = g[2] * g[3]
				if not found or area > best_area:
					best = o
					best_area = area
					found = true

		# Walk the tree first so every view has an id to point connections at.
		var root: Variant = view(best)

		# Nibs whose views are top-level siblings rather than nested under the
		# widest view (fcFryBatterVC, cffFrySliceViewController, fbtThrowballVC,
		# ftTossBallVC, mb_ThrowBallVC): if the walk produced no subviews at
		# all, adopt the unvisited sibling views.
		if root != null and not root.has("subviews"):
			var adopted: Array = []
			for ref in objects:
				var o: Variant = deref(ref)
				if o == null or is_same(o, best) or ids.has(o):
					continue
				if not (o is NibArchive.NibObject) or not o.cls.begins_with("UI"):
					continue
				var g: Variant = geom(o, "UIBounds")
				if not (g != null and g.size() >= 4):
					continue          # no geometry: not a placed view
				var node: Variant = view(o)
				if truthy(node):
					adopted.append(node)
			if not adopted.is_empty():
				root["subviews"] = adopted

		var outlets: Array = []
		var actions: Array = []
		for ref in array_items(deref(root_obj.val("UINibConnectionsKey"))):
			var c: Variant = deref(ref)
			if c == null:
				continue
			if not (c is NibArchive.NibObject):
				_fail("connection is not an object")
				continue
			var label: Variant = string(c.val("UILabel"))
			var dest: Variant = deref(c.val("UIDestination"))
			if c.cls == "UIRuntimeOutletConnection":
				outlets.append({
					"name": label,
					"class": _cls_or_null(dest),
					# null when the outlet points at the controller or a
					# non-view object rather than something in the tree.
					"viewId": ids.get(dest) if truthy(dest) else null,
				})
			elif c.cls == "UIRuntimeEventConnection":
				var src: Variant = deref(c.val("UISource"))
				var mask: Variant = c.val("UIEventMask")
				if not truthy(mask):
					mask = 0
				var events: Array = []
				if typeof(mask) == TYPE_INT or typeof(mask) == TYPE_BOOL:
					for em in EVENT_MASKS:
						if int(mask) & em[0]:
							events.append(em[1])
				else:
					_fail("UIEventMask is not an int")
				actions.append({
					"selector": label,
					"sourceClass": _cls_or_null(src),
					"sourceImage": image_name(src) if truthy(src) else null,
					"viewId": ids.get(src) if truthy(src) else null,
					"events": events if not events.is_empty() else mask,
				})

		return {
			"name": name,
			"designSize": [320, 480],
			"root": root,
			"outlets": _sorted_by(outlets, "name"),
			"actions": _sorted_by(actions, "selector"),
		}

	func _cls_or_null(o: Variant) -> Variant:
		if not truthy(o):
			return null
		if not (o is NibArchive.NibObject):
			_fail("connection end is not an object")
			return null
		return o.cls

	## sorted(items, key=lambda d: d[field] or '') -- stable.
	static func _sorted_by(items: Array, field: String) -> Array:
		var dec: Array = []
		for i in items.size():
			var k: Variant = items[i][field]
			dec.append([k if (typeof(k) == TYPE_STRING and k != "") else "", i, items[i]])
		dec.sort_custom(func(x: Array, y: Array) -> bool:
			return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
		var out: Array = []
		for d in dec:
			out.append(d[2])
		return out
