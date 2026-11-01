# Reader for Apple's NIBArchive container: a GDScript port of the Python
# NIBArchive reader for the in-game IPA importer.
#
# Layout: a 50-byte header ('NIBArchive', two format words, then count/offset
# pairs for the objects, keys, values and class-name tables). Objects index
# into the value table by (start, count); each value names a key and carries
# a typed payload; object references are indices back into the object table.
#
# Table integers are little-endian base-128 varints whose FINAL byte has the
# high bit set -- the opposite of protobuf.
#
# Value tags: 0 int8, 1 int16, 2 int32, 3 int64, 4 FALSE, 5 TRUE, 6 float32,
# 7 float64, 8 data, 9 nil, 10 object reference. (4/5 were swapped in the
# Python reader at first, which hid 60 views the device shows hidden.) An
# unknown tag decodes to an Unknown marker without consuming a payload,
# exactly like the Python's ('<unknown type N>',) tuple.
#
# Payload types: ints -> int, floats -> float (float32 widened exactly), data
# -> PackedByteArray, nil -> null, references -> NibArchive.Ref.
extends RefCounted

const MAGIC := "NIBArchive"

const T_INT8 := 0
const T_INT16 := 1
const T_INT32 := 2
const T_INT64 := 3
const T_FALSE := 4
const T_TRUE := 5
const T_FLOAT := 6
const T_DOUBLE := 7
const T_DATA := 8
const T_NIL := 9
const T_OBJECT := 10


## The Python reader's ObjectRef.
class Ref extends RefCounted:
	var index: int

	func _init(i: int = 0) -> void:
		index = i


## The Python's ('<unknown type N>',) placeholder.
class Unknown extends RefCounted:
	var text: String

	func _init(t: String = "") -> void:
		text = t


## The Python reader's NIBObject. `values` is the ordered list of [key,
## value] pairs; val() returns the first match, as NIBObject.get() does.
## (Not named get(): that would shadow Object.get.)
class NibObject extends RefCounted:
	var cls: String
	var values: Array

	var _first: Dictionary = {}
	var _indexed := false

	func _init(c: String = "", v: Array = []) -> void:
		cls = c
		values = v

	func val(key: String, default: Variant = null) -> Variant:
		# First match wins, as in the Python's linear scan; indexed once since
		# the value list never changes after construction.
		if not _indexed:
			_indexed = true
			for kv in values:
				if not _first.has(kv[0]):
					_first[kv[0]] = kv[1]
		return _first.get(key, default)

	func keys() -> PackedStringArray:
		var out := PackedStringArray()
		for kv in values:
			out.append(str(kv[0]))
		return out


var objects: Array = []                 # NibObject
var class_names := PackedStringArray()
var keys := PackedStringArray()
var values: Array = []                  # [key, value]
## Empty on success; set when the bytes are not a readable NIBArchive (the
## Python raises in the same places).
var error := ""

var _d: PackedByteArray


static func is_nib_archive(data: PackedByteArray) -> bool:
	return data.size() >= 10 and data.slice(0, 10).get_string_from_ascii() == MAGIC


## Parse `data`. Check `error` afterwards.
func load_bytes(data: PackedByteArray) -> void:
	if not is_nib_archive(data):
		error = "not a NIBArchive"
		return
	if data.size() < 50:
		error = "truncated header"
		return
	_d = data
	var h: Array[int] = []
	for i in 10:
		h.append(data.decode_u32(10 + i * 4))
	# fmt, coder, obj_n, obj_off, key_n, key_off, val_n, val_off, cls_n, cls_off
	class_names = _read_class_names(h[9], h[8])
	if error == "":
		keys = _read_keys(h[5], h[4])
	if error == "":
		values = _read_values(h[7], h[6])
	if error == "":
		objects = _read_objects(h[3], h[2])


func resolve(v: Variant) -> Variant:
	if v is Ref:
		if v.index < 0 or v.index >= objects.size():
			if error == "":
				error = "object reference %d out of range" % v.index
			return null
		return objects[v.index]
	return v


# -- primitives -----------------------------------------------------------------

var _i := 0       # read cursor


func _fail(msg: String) -> void:
	if error == "":
		error = msg


func _varint() -> int:
	var v := 0
	var shift := 0
	while true:
		if _i < 0 or _i >= _d.size():
			_fail("varint runs past end of data")
			return 0
		var b := _d[_i]
		_i += 1
		v |= (b & 0x7F) << shift
		if b & 0x80:
			return v
		shift += 7
		if shift > 56:                          # keep it a non-negative int64
			_fail("varint too long")
			return 0
	return v


func _need(n: int) -> bool:
	if _i < 0 or n < 0 or n > _d.size() - _i:          # overflow-safe
		_fail("value runs past end of data")
		return false
	return true


# -- tables ---------------------------------------------------------------------

func _read_class_names(off: int, n: int) -> PackedStringArray:
	var out := PackedStringArray()
	_i = off
	for k in n:
		var length := _varint()
		var n_extra := _varint()
		if error != "" or n_extra > _d.size():
			_fail("class name trailer runs past end of data")
			return out
		_i += n_extra * 4                         # ivar-ish trailer, unused
		if not _need(length):
			return out
		var raw := _d.slice(_i, _i + length)
		var end := raw.size()
		while end > 0 and raw[end - 1] == 0:      # rstrip(b'\0')
			end -= 1
		out.append(raw.slice(0, end).get_string_from_utf8())
		_i += length
	return out


func _read_keys(off: int, n: int) -> PackedStringArray:
	var out := PackedStringArray()
	_i = off
	for k in n:
		var length := _varint()
		if error != "" or not _need(length):
			return out
		out.append(_d.slice(_i, _i + length).get_string_from_utf8())
		_i += length
	return out


func _read_values(off: int, n: int) -> Array:
	var out: Array = []
	_i = off
	for k in n:
		var key_idx := _varint()
		if error != "":
			return out
		if key_idx >= keys.size():
			_fail("key index %d out of range" % key_idx)
			return out
		if not _need(1):
			return out
		var t := _d[_i]
		_i += 1
		var v: Variant = null
		match t:
			T_INT8:
				if not _need(1): return out
				v = _d.decode_s8(_i); _i += 1
			T_INT16:
				if not _need(2): return out
				v = _d.decode_s16(_i); _i += 2
			T_INT32:
				if not _need(4): return out
				v = _d.decode_s32(_i); _i += 4
			T_INT64:
				if not _need(8): return out
				v = _d.decode_s64(_i); _i += 8
			T_TRUE:
				v = true
			T_FALSE:
				v = false
			T_FLOAT:
				if not _need(4): return out
				v = _d.decode_float(_i); _i += 4
			T_DOUBLE:
				if not _need(8): return out
				v = _d.decode_double(_i); _i += 8
			T_DATA:
				var length := _varint()
				if error != "":
					return out
				if _i > _d.size() or length > _d.size():
					_fail("data value runs past end of data")
					return out
				var end := mini(_i + length, _d.size())       # Python slices clamp
				v = _d.slice(_i, end); _i += length
			T_NIL:
				v = null
			T_OBJECT:
				if not _need(4): return out
				v = Ref.new(_d.decode_u32(_i)); _i += 4
			_:
				v = Unknown.new("<unknown type %d>" % t)
		out.append([keys[key_idx], v])
	return out


func _read_objects(off: int, n: int) -> Array:
	var out: Array = []
	_i = off
	for k in n:
		var cls_idx := _varint()
		var val_start := _varint()
		var val_count := _varint()
		if error != "":
			return out
		if cls_idx >= class_names.size():
			_fail("class index %d out of range" % cls_idx)
			return out
		# values[val_start:val_start + val_count], clamped like a Python slice
		var vs := mini(val_start, values.size())
		var ve := mini(vs + mini(val_count, values.size()), values.size())
		out.append(NibObject.new(class_names[cls_idx], values.slice(vs, ve)))
	return out
