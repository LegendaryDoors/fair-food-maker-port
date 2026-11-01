# An NSKeyedArchiver .nib presented through the NibArchive interface: a
# GDScript port of the Python keyed-archive reader for the in-game IPA
# importer.
#
# Fourteen of the v1.27 nibs are binary plists written by NSKeyedArchiver
# rather than NIBArchive containers. Same object graph, same UIKit keys; only
# the container differs:
#
#     NIBArchive              NSKeyedArchiver
#     object index            plist UID
#     tagged float blob       '{{0, 0}, {320, 480}}' string
#     UINibEncoderEmptyKey    NS.objects array
#
# Wrapping it in the same objects / resolve() / NibObject shape lets
# NibReader walk either format with one code path. Kept faithful to the
# Python, quirks included: objects[0] (the '$null' slot) is replaced by a
# synthesised root carrying $top, so a UID(0) resolves to that root; bare
# strings in $objects become NSString {NS.bytes: utf-8}; other bare values
# become NSValue {NS.intval: value}; NS.keys stays a raw list of Plist.Uid.
extends RefCounted

const Plist := preload("res://core/import/Plist.gd")
const NibArchive := preload("res://core/import/NibArchive.gd")

var objects: Array = []          # NibArchive.NibObject
var error := ""
var _raw: Array = []


func load_bytes(data: PackedByteArray) -> void:
	var r := Plist.parse_result(data)
	if not r.ok:
		error = r.error
		return
	var plist: Variant = r.value
	if typeof(plist) != TYPE_DICTIONARY or not _is_str(plist.get("$archiver"), "NSKeyedArchiver"):
		error = "not an NSKeyedArchiver plist"
		return
	if typeof(plist.get("$objects")) != TYPE_ARRAY:
		error = "keyed archive has no $objects"
		return
	_raw = plist["$objects"]
	objects = []
	for o in _raw:
		objects.append(_wrap(o))
		if error != "":
			return

	# NibReader expects objects[0] to carry the UINib* top-level keys. In a
	# keyed archive those live under $top, so synthesise that root.
	var top: Variant = plist.get("$top", {})
	var vals: Array = []
	if typeof(top) == TYPE_DICTIONARY:
		for k in top:
			var v: Variant = top[k]
			if not (v is Plist.Uid):
				error = "$top value for %s is not a UID" % k
				return
			vals.append([k, NibArchive.Ref.new(v.value)])
	if objects.is_empty():
		error = "keyed archive has an empty $objects"
		return
	objects[0] = NibArchive.NibObject.new("NSObject", vals)


func resolve(v: Variant) -> Variant:
	if v is NibArchive.Ref:
		if v.index < 0 or v.index >= objects.size():
			if error == "":
				error = "object reference %d out of range" % v.index
			return null
		return objects[v.index]
	return v


func _class_name(obj: Dictionary) -> String:
	var ref: Variant = obj.get("$class")
	if ref == null:
		return "NSObject"
	if not (ref is Plist.Uid) or ref.value < 0 or ref.value >= _raw.size() \
			or typeof(_raw[ref.value]) != TYPE_DICTIONARY:
		if error == "":
			error = "bad $class reference"
		return "NSObject"
	return str(_raw[ref.value].get("$classname", "NSObject"))


func _wrap(obj: Variant) -> NibArchive.NibObject:
	if typeof(obj) != TYPE_DICTIONARY:
		# Bare strings/numbers in the pool. Expose strings the way NibReader's
		# string() reads them, so NS.bytes stays the one path.
		if typeof(obj) == TYPE_STRING:
			return NibArchive.NibObject.new("NSString", [["NS.bytes", (obj as String).to_utf8_buffer()]])
		return NibArchive.NibObject.new("NSValue", [["NS.intval", obj]])

	var values: Array = []
	for k in obj:
		if _is_str(k, "$class"):
			continue
		var v: Variant = obj[k]
		if v is Plist.Uid:
			values.append([k, NibArchive.Ref.new(v.value)])
		elif _is_str(k, "NS.objects") and typeof(v) == TYPE_ARRAY:
			# Flatten array members onto the key NibReader iterates.
			for item in v:
				values.append(["UINibEncoderEmptyKey",
					NibArchive.Ref.new(item.value) if item is Plist.Uid else item])
		else:
			values.append([k, v])
	return NibArchive.NibObject.new(_class_name(obj), values)


## v == s without GDScript's runtime error for mismatched operand types.
static func _is_str(v: Variant, s: String) -> bool:
	return typeof(v) == TYPE_STRING and v == s
