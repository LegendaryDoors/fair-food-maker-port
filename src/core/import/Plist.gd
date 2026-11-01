# Property-list reader for the in-game IPA importer: a GDScript port of
# what the Python plist converter gets from CPython's plistlib.
#
#   parse(bytes)          binary 'bplist00' or XML plist -> Variant
#   to_json_value(v)      == the plist converter's jsonable(): data ->
#                            {'__data__': base64}, dates ->
#                            datetime.isoformat()
#   manifest_entry(v)     == the plist converter's summarize(), for
#                            _manifest.json
#
# Value mapping (plistlib -> GDScript):
#   dict -> Dictionary (file order kept)   array -> Array
#   str  -> String                          int   -> int (64-bit)
#   float-> float                           bool  -> bool
#   bytes-> PackedByteArray                 None  -> null (bplist token 0x00)
#   datetime -> Plist.Date (naive, microseconds since 2001-01-01T00:00:00)
#   plistlib.UID -> Plist.Uid (keyed archives only)
#
# The binary reader follows plistlib._BinaryPlistParser token for token,
# including its quirks: ints of 1/2/4 bytes are unsigned and 8/16 bytes
# signed, 0x0F decodes as b'', 1- and 2-byte reals are rejected, and a
# date's fractional seconds round to the microsecond exactly the way
# datetime.timedelta(seconds=f) does.
#
# The XML reader is a small tokenizer (Godot's XMLParser drops whitespace-only
# text shorter than three characters, which would turn <string> </string> into
# '') driving the same element handlers as plistlib._PlistParser.
#
# Stateless and static: safe to call from the importer's worker thread.
# Strings containing U+0000 are truncated there (Godot strings are
# NUL-terminated); no plist in the bundle has one.
extends RefCounted

const PyJson := preload("res://core/import/PyJson.gd")

const _UNIX_2001 := 978307200     # 2001-01-01T00:00:00Z as a Unix time


## plistlib.UID
class Uid extends RefCounted:
	var value: int

	func _init(v: int = 0) -> void:
		value = v


## A naive datetime, as plistlib returns it (aware_datetime=False).
class Date extends RefCounted:
	## Microseconds since 2001-01-01T00:00:00.
	var usec: int

	func _init(u: int = 0) -> void:
		usec = u

	## datetime.isoformat(): 'YYYY-MM-DDTHH:MM:SS', plus '.ffffff' when the
	## microseconds are non-zero.
	func isoformat() -> String:
		var s := usec / 1000000
		var us := usec % 1000000
		if us < 0:
			us += 1000000
			s -= 1
		var d := Time.get_datetime_dict_from_unix_time(s + 978307200)
		var out := "%04d-%02d-%02dT%02d:%02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]
		if us != 0:
			out += ".%06d" % us
		return out


# --- public API ---------------------------------------------------------------

## The decoded plist, or null if the bytes are not a readable plist (a plist
## whose root is <null/>-token 0x00 also yields null; use parse_result() to
## tell them apart).
static func parse(bytes: PackedByteArray) -> Variant:
	return parse_result(bytes).value


## {ok: bool, value: Variant, error: String}
static func parse_result(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() >= 8 and bytes.slice(0, 8).get_string_from_ascii() == "bplist00":
		var br := _Binary.new(bytes)
		var v: Variant = br.parse()
		if br.error != "":
			return {"ok": false, "value": null, "error": "bplist: " + br.error}
		return {"ok": true, "value": v, "error": ""}
	var text: Variant = _xml_text(bytes)
	if text != null:
		var xr := _Xml.new()
		var v2: Variant = xr.parse(text)
		if xr.error != "":
			return {"ok": false, "value": null, "error": "xml plist: " + xr.error}
		return {"ok": true, "value": v2, "error": ""}
	return {"ok": false, "value": null, "error": "not a property list (neither bplist00 nor XML)"}


## The plist converter's jsonable(): containers recursively, bytes ->
## {'__data__': base64}, datetimes -> isoformat(); everything else as is.
## Dictionary keys come out as json.dumps would write them (int 5 -> '5').
## A UID has no JSON form (the plist converter would raise); it maps to null.
static func to_json_value(v: Variant, _depth: int = 0) -> Variant:
	if _depth > 400:
		# Only a self-containing (cyclic) plist gets here; jsonable() would
		# raise RecursionError.
		push_error("Plist.to_json_value: nesting too deep (cyclic plist?)")
		return null
	match typeof(v):
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[_json_key(k)] = to_json_value(v[k], _depth + 1)
			return out
		TYPE_ARRAY:
			var arr := []
			arr.resize(v.size())
			for i in v.size():
				arr[i] = to_json_value(v[i], _depth + 1)
			return arr
		TYPE_PACKED_BYTE_ARRAY:
			# raw_to_base64() logs an error for b''; base64 of b'' is ''.
			return {"__data__": Marshalls.raw_to_base64(v) if v.size() > 0 else ""}
		TYPE_OBJECT:
			if v is Date:
				return v.isoformat()
			if v is Uid:
				push_error("Plist.to_json_value: UID %d is not JSON serializable" % v.value)
				return null
			return null
	return v


## The plist converter's summarize(): the shape line it writes to
## _manifest.json.
static func manifest_entry(data: Variant) -> Dictionary:
	if typeof(data) == TYPE_ARRAY:
		var seen := {}
		for it in data:
			if typeof(it) == TYPE_DICTIONARY:
				for k in it:
					seen[k] = true
		var keys: Array = seen.keys()
		keys.sort()
		return {"kind": "array", "count": data.size(), "fields": keys}
	if typeof(data) == TYPE_DICTIONARY:
		var keys2: Array = data.keys()
		keys2.sort()
		return {"kind": "dict", "count": data.size(), "fields": keys2.slice(0, 20)}
	return {"kind": py_type_name(data)}


## type(v).__name__ of the plistlib value v maps to.
static func py_type_name(v: Variant) -> String:
	match typeof(v):
		TYPE_NIL: return "NoneType"
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "str"
		TYPE_PACKED_BYTE_ARRAY: return "bytes"
		TYPE_ARRAY: return "list"
		TYPE_DICTIONARY: return "dict"
		TYPE_OBJECT:
			if v is Date: return "datetime"
			if v is Uid: return "UID"
	return type_string(typeof(v))


static func _json_key(k: Variant) -> Variant:
	match typeof(k):
		TYPE_STRING: return k
		TYPE_BOOL: return "true" if k else "false"
		TYPE_NIL: return "null"
		TYPE_INT: return str(k)
		TYPE_FLOAT: return PyJson.repr_float(k)
	return str(k)


## datetime(2001, 1, 1) + timedelta(seconds=f), in microseconds since the
## epoch (see _U.date_usec).
static func date_usec_from_seconds(f: float) -> int:
	return _U.date_usec(f)


# --- XML detection (plistlib._is_fmt_xml) -------------------------------------

## The document as a String if it looks like an XML plist, else null.
static func _xml_text(b: PackedByteArray) -> Variant:
	if _starts(b, [0x3C, 0x3F, 0x78, 0x6D, 0x6C]) or _starts(b, [0x3C, 0x70, 0x6C, 0x69, 0x73, 0x74]):
		return b.get_string_from_utf8()                       # '<?xml' / '<plist'
	if _starts(b, [0xEF, 0xBB, 0xBF]):
		var t := b.slice(3).get_string_from_utf8()
		if t.begins_with("<?xml") or t.begins_with("<plist"):
			return t
		return null
	if _starts(b, [0xFE, 0xFF]) or _starts(b, [0xFF, 0xFE]):
		var be := b[0] == 0xFE
		var t2: Variant = _U.utf16(b, 2, (b.size() - 2) / 2, be)
		if t2 != null and (t2.begins_with("<?xml") or t2.begins_with("<plist")):
			return t2
	return null


static func _starts(b: PackedByteArray, prefix: Array) -> bool:
	if b.size() < prefix.size():
		return false
	for i in prefix.size():
		if b[i] != prefix[i]:
			return false
	return true


# Helpers shared by the outer script and the inner readers (an inner class
# cannot call the outer script's static functions, but can reach a sibling's).
class _U:
	## datetime(2001, 1, 1) + timedelta(seconds=f), in microseconds since the
	## epoch. Follows CPython's delta_new/accum: the integer seconds are exact,
	## the fraction is scaled by 1e6 in double arithmetic and the leftover below
	## one microsecond is rounded half-to-even against the running total.
	static func date_usec(f: float) -> int:
		var ip := floorf(f) if f >= 0.0 else ceilf(f)
		var fr := f - ip
		var total := int(ip) * 1000000
		if fr != 0.0:
			var dn := 1000000.0 * fr
			var ip2 := floorf(dn) if dn >= 0.0 else ceilf(dn)
			var left := dn - ip2
			total += int(ip2)
			if left != 0.0:
				var w := roundf(left)                      # C round(): half away from 0
				if absf(w - left) == 0.5:
					var odd := total & 1
					w = 2.0 * roundf((left + odd) * 0.5) - odd
				total += int(w)
		return total

	## UTF-16 code units -> String, strictly (a lone surrogate -> null, as
	## CPython's utf-16 codec raises).
	static func utf16(b: PackedByteArray, off: int, count: int, big_endian: bool) -> Variant:
		var out := PackedByteArray()
		out.resize(count * 4)
		var n := 0
		var i := 0
		while i < count:
			var p := off + i * 2
			var u: int = (b[p] << 8 | b[p + 1]) if big_endian else (b[p + 1] << 8 | b[p])
			i += 1
			if u >= 0xD800 and u <= 0xDBFF:
				if i >= count:
					return null
				var p2 := off + i * 2
				var u2: int = (b[p2] << 8 | b[p2 + 1]) if big_endian else (b[p2 + 1] << 8 | b[p2])
				if u2 < 0xDC00 or u2 > 0xDFFF:
					return null
				i += 1
				u = 0x10000 + ((u - 0xD800) << 10) + (u2 - 0xDC00)
			elif u >= 0xDC00 and u <= 0xDFFF:
				return null
			out.encode_u32(n * 4, u)
			n += 1
		out.resize(n * 4)
		return out.get_string_from_utf32()


# --- binary plist (plistlib._BinaryPlistParser) -------------------------------

class _Binary:
	var d: PackedByteArray
	var offsets := PackedInt64Array()
	var ref_size := 0
	var cache: Array = []
	var done := PackedByteArray()
	var error := ""
	var _p := 0           # read cursor

	func _init(data: PackedByteArray) -> void:
		d = data

	func _fail(msg: String) -> Variant:
		if error == "":
			error = msg
		return null

	## Big-endian unsigned (8 bytes: two's complement, i.e. signed) integer.
	func _be(off: int, size: int) -> int:
		if off < 0 or size < 0 or size > d.size() or off > d.size() - size:
			_fail("read past end of data at %d" % off)
			return 0
		var v := 0
		for i in size:
			v = (v << 8) | d[off + i]
		return v

	func parse() -> Variant:
		var n := d.size()
		if n < 40:
			return _fail("truncated (%d bytes)" % n)
		var t := n - 32
		var offset_size := d[t + 6]
		ref_size = d[t + 7]
		var num_objects := _be(t + 8, 8)
		var top := _be(t + 16, 8)
		var table := _be(t + 24, 8)
		if offset_size == 0:
			return _fail("offset size 0")
		if num_objects < 0 or table < 0 or num_objects > n or table > n \
				or num_objects * offset_size > n - table:
			return _fail("offset table out of range")
		offsets.resize(num_objects)
		for i in num_objects:
			offsets[i] = _be(table + i * offset_size, offset_size)
		cache.resize(num_objects)
		done.resize(num_objects)
		done.fill(0)
		return _obj(top, 0)

	## _get_size(): a length nibble, or 0xF followed by an int object.
	func _size(lo: int) -> int:
		if lo != 0xF:
			return lo
		if _p >= d.size():
			_fail("truncated length")
			return 0
		var s := 1 << (d[_p] & 0x3)
		var v := _be(_p + 1, s)
		_p += 1 + s
		return v

	func _bytes(count: int) -> PackedByteArray:
		if count < 0 or _p < 0 or count > d.size() - _p:
			_fail("object runs past end of data")
			return PackedByteArray()
		var out := d.slice(_p, _p + count)
		_p += count
		return out

	func _refs(count: int) -> PackedInt64Array:
		var out := PackedInt64Array()
		if count < 0 or _p < 0 or count > d.size() or (ref_size == 0 and count > 0) \
				or count * ref_size > d.size() - _p:
			_fail("reference list runs past end of data")
			return out
		out.resize(count)
		for i in count:
			out[i] = _be(_p + i * ref_size, ref_size)
		_p += count * ref_size
		return out

	func _obj(ref: int, depth: int) -> Variant:
		if error != "":
			return null
		if ref < 0 or ref >= offsets.size():
			return _fail("object reference %d out of range" % ref)
		if done[ref] != 0:
			return cache[ref]
		if depth > 400:
			return _fail("nesting too deep")
		var off: int = offsets[ref]
		if off < 0 or off >= d.size():
			return _fail("object offset out of range")
		var token := d[off]
		var hi := token & 0xF0
		var lo := token & 0x0F
		_p = off + 1
		var result: Variant = null
		if token == 0x00:
			result = null
		elif token == 0x08:
			result = false
		elif token == 0x09:
			result = true
		elif token == 0x0F:
			result = PackedByteArray()
		elif hi == 0x10:                                   # int
			var size := 1 << lo
			if size <= 8:
				result = _be(_p, size)                     # 8 bytes wrap to signed
			elif size == 16:
				var high := _be(_p, 8)
				var low := _be(_p + 8, 8)
				if not ((high == 0 and low >= 0) or (high == -1 and low < 0)):
					return _fail("128-bit integer out of range")
				result = low
			else:
				return _fail("integer of %d bytes" % size)
		elif token == 0x22:                                # float32
			var b4 := _bytes(4)
			if error != "":
				return null
			b4.reverse()
			result = b4.decode_float(0)
		elif token == 0x23:                                # float64
			var b8 := _bytes(8)
			if error != "":
				return null
			b8.reverse()
			result = b8.decode_double(0)
		elif token == 0x33:                                # date
			var bd := _bytes(8)
			if error != "":
				return null
			bd.reverse()
			result = Date.new(_U.date_usec(bd.decode_double(0)))
		elif hi == 0x40:                                   # data
			var s := _size(lo)
			result = _bytes(s)
		elif hi == 0x50:                                   # ASCII string
			var s2 := _size(lo)
			var raw := _bytes(s2)
			for c in raw:
				if c > 0x7F:
					return _fail("non-ASCII byte in ASCII string")
			result = raw.get_string_from_ascii()
		elif hi == 0x60:                                   # UTF-16BE string
			var units := _size(lo)
			if units < 0 or units > d.size() or units * 2 > d.size() - _p:
				return _fail("string runs past end of data")
			var u: Variant = _U.utf16(d, _p, units, true)
			if u == null:
				return _fail("invalid UTF-16 string")
			result = u
		elif hi == 0x80:                                   # UID
			result = Uid.new(_be(_p, 1 + lo))
		elif hi == 0xA0:                                   # array
			var s3 := _size(lo)
			var refs := _refs(s3)
			if error != "":
				return null
			var arr := []
			cache[ref] = arr
			done[ref] = 1
			for r in refs:
				arr.append(_obj(r, depth + 1))
			result = arr
		elif hi == 0xD0:                                   # dict
			var s4 := _size(lo)
			var krefs := _refs(s4)
			var vrefs := _refs(s4)
			if error != "":
				return null
			var dict := {}
			cache[ref] = dict
			done[ref] = 1
			for i in s4:
				var k: Variant = _obj(krefs[i], depth + 1)
				var v: Variant = _obj(vrefs[i], depth + 1)
				if typeof(k) == TYPE_ARRAY or typeof(k) == TYPE_DICTIONARY:
					return _fail("unhashable dictionary key")
				dict[k] = v
			result = dict
		else:
			return _fail("unsupported object token 0x%02x" % token)
		if error != "":
			return null
		cache[ref] = result
		done[ref] = 1
		return result


# --- XML plist (plistlib._PlistParser over expat) ------------------------------

class _Xml:
	var error := ""
	var stack: Array = []
	var current_key: Variant = null
	var root: Variant = null
	var data := PackedStringArray()
	var _open := PackedStringArray()        # element names, for well-formedness

	func _fail(msg: String) -> Variant:
		if error == "":
			error = msg
		return null

	func parse(src: String) -> Variant:
		var text := src.replace("\r\n", "\n").replace("\r", "\n")   # expat's newline normalisation
		var i := 0
		var n := text.length()
		var seen_root := false
		while i < n and error == "":
			var lt := text.find("<", i)
			if lt < 0:
				_text(text.substr(i))
				break
			if lt > i:
				_text(text.substr(i, lt - i))
			if text.substr(lt, 4) == "<!--":
				var e := text.find("-->", lt + 4)
				if e < 0:
					return _fail("unterminated comment")
				i = e + 3
			elif text.substr(lt, 9) == "<![CDATA[":
				var e2 := text.find("]]>", lt + 9)
				if e2 < 0:
					return _fail("unterminated CDATA")
				if _open.is_empty():
					return _fail("CDATA outside the root element")
				data.append(text.substr(lt + 9, e2 - lt - 9))
				i = e2 + 3
			elif text.substr(lt, 2) == "<?":
				var e3 := text.find("?>", lt + 2)
				if e3 < 0:
					return _fail("unterminated processing instruction")
				i = e3 + 2
			elif text.substr(lt, 2) == "<!":
				# <!DOCTYPE ...> with an optional [internal subset]. plistlib
				# rejects entity declarations outright.
				var j := lt + 2
				var depth := 0
				while j < n:
					var c := text[j]
					if c == "[":
						depth += 1
					elif c == "]":
						depth -= 1
					elif c == ">" and depth <= 0:
						break
					j += 1
				if j >= n:
					return _fail("unterminated declaration")
				if text.substr(lt, j - lt).find("<!ENTITY") >= 0:
					return _fail("XML entity declarations are not supported in plist files")
				i = j + 1
			elif text.substr(lt, 2) == "</":
				var e4 := text.find(">", lt)
				if e4 < 0:
					return _fail("unterminated end tag")
				var name := text.substr(lt + 2, e4 - lt - 2).strip_edges()
				if _open.is_empty() or _open[_open.size() - 1] != name:
					return _fail("mismatched end tag </%s>" % name)
				_open.remove_at(_open.size() - 1)
				_end(name)
				i = e4 + 1
			else:
				var e5 := _tag_end(text, lt + 1)
				if e5 < 0:
					return _fail("unterminated start tag")
				var inner := text.substr(lt + 1, e5 - lt - 1)
				var self_closing := inner.ends_with("/")
				if self_closing:
					inner = inner.substr(0, inner.length() - 1)
				var name2 := inner.strip_edges()
				for ws in [" ", "\t", "\n"]:
					var k := name2.find(ws)
					if k >= 0:
						name2 = name2.substr(0, k)
				if name2.is_empty():
					return _fail("empty tag name")
				if _open.is_empty() and seen_root:
					return _fail("junk after document element")
				seen_root = true
				_open.append(name2)
				_begin(name2)
				if self_closing:
					_open.remove_at(_open.size() - 1)
					_end(name2)
				i = e5 + 1
		if error != "":
			return null
		if not _open.is_empty():
			return _fail("unclosed element <%s>" % _open[_open.size() - 1])
		if not seen_root:
			return _fail("no element found")
		return root

	## Index of the '>' closing a start tag, skipping quoted attribute values.
	func _tag_end(text: String, from: int) -> int:
		var q := ""
		var j := from
		while j < text.length():
			var c := text[j]
			if q != "":
				if c == q:
					q = ""
			elif c == "\"" or c == "'":
				q = c
			elif c == ">":
				return j
			j += 1
		return -1

	func _text(raw: String) -> void:
		if _open.is_empty():
			if raw.strip_edges() != "":
				_fail("text outside the root element")
			return
		var decoded: Variant = _entities(raw)
		if decoded == null:
			_fail("undefined entity")
			return
		data.append(decoded)

	func _entities(s: String) -> Variant:
		if s.find("&") < 0:
			return s
		var out := PackedStringArray()
		var i := 0
		while i < s.length():
			var a := s.find("&", i)
			if a < 0:
				out.append(s.substr(i))
				break
			out.append(s.substr(i, a - i))
			var semi := s.find(";", a)
			if semi < 0:
				return null
			var ent := s.substr(a + 1, semi - a - 1)
			match ent:
				"lt": out.append("<")
				"gt": out.append(">")
				"amp": out.append("&")
				"quot": out.append("\"")
				"apos": out.append("'")
				_:
					if ent.begins_with("#x") or ent.begins_with("#X"):
						var hx := ent.substr(2)
						if hx.is_empty() or not hx.is_valid_hex_number(false):
							return null
						out.append(String.chr(hx.hex_to_int()))
					elif ent.begins_with("#"):
						var dc := ent.substr(1)
						if dc.is_empty() or not dc.is_valid_int() or dc.begins_with("-") or dc.begins_with("+"):
							return null
						out.append(String.chr(dc.to_int()))
					else:
						return null
			i = semi + 1
		return "".join(out)

	func _get_data() -> String:
		var s := "".join(data)
		data.clear()
		return s

	func _add(value: Variant) -> void:
		if current_key != null:
			if stack.is_empty() or typeof(stack[-1]) != TYPE_DICTIONARY:
				_fail("unexpected element")
				return
			stack[-1][current_key] = value
			current_key = null
		elif stack.is_empty():
			root = value
		else:
			if typeof(stack[-1]) != TYPE_ARRAY:
				_fail("unexpected element")
				return
			stack[-1].append(value)

	func _begin(name: String) -> void:
		data.clear()
		if name == "dict":
			var dct := {}
			_add(dct)
			stack.append(dct)
		elif name == "array":
			var arr := []
			_add(arr)
			stack.append(arr)

	func _end(name: String) -> void:
		match name:
			"dict":
				if current_key != null and current_key != "":
					_fail("missing value for key '%s'" % current_key)
					return
				if stack.is_empty():
					_fail("unbalanced </dict>")
					return
				stack.pop_back()
			"key":
				if (current_key != null and current_key != "") or stack.is_empty() \
						or typeof(stack[-1]) != TYPE_DICTIONARY:
					_fail("unexpected key")
					return
				current_key = _get_data()
			"array":
				if stack.is_empty():
					_fail("unbalanced </array>")
					return
				stack.pop_back()
			"true":
				_add(true)
			"false":
				_add(false)
			"integer":
				var raw := _get_data()
				var v: Variant = _py_int(raw)
				if v == null:
					_fail("invalid integer '%s'" % raw)
					return
				_add(v)
			"real":
				var rawf := _get_data()
				var f: Variant = PyJson.parse_float(rawf)
				if f == null:
					_fail("invalid real '%s'" % rawf)
					return
				_add(f)
			"string":
				_add(_get_data())
			"data":
				var b: Variant = _a2b_base64(_get_data())
				if b == null:
					_fail("invalid base64 data")
					return
				_add(b)
			"date":
				var usec: Variant = _date(_get_data())
				if usec == null:
					_fail("invalid date")
					return
				_add(Date.new(usec))

	## int(raw) / int(raw, 16) as plistlib's end_integer calls them.
	func _py_int(raw: String) -> Variant:
		var hex := raw.begins_with("0x") or raw.begins_with("0X")
		var t := raw.strip_edges()
		var neg := false
		if not hex and (t.begins_with("+") or t.begins_with("-")):
			neg = t.begins_with("-")
			t = t.substr(1)
		if hex:
			t = t.substr(2)
		if t.begins_with("_") or t.ends_with("_") or t.find("__") >= 0:
			return null
		t = t.replace("_", "")
		if t.is_empty():
			return null
		var v := 0
		for c in t:
			var dgt := -1
			var u := c.unicode_at(0)
			if u >= 48 and u <= 57:
				dgt = u - 48
			elif hex and u >= 97 and u <= 102:
				dgt = u - 87
			elif hex and u >= 65 and u <= 70:
				dgt = u - 55
			if dgt < 0:
				return null
			var base := 16 if hex else 10
			if v > (0x7FFFFFFFFFFFFFFF - dgt) / base:
				return null                           # beyond int64
			v = v * base + dgt
		return -v if neg else v

	## binascii.a2b_base64 in its default (non-strict) mode.
	func _a2b_base64(s: String) -> Variant:
		var out := PackedByteArray()
		var quad_pos := 0
		var pads := 0
		var left := 0
		for i in s.length():
			var c := s.unicode_at(i)
			if c == 0x3D:                                     # '='
				if quad_pos >= 2:
					pads += 1
					if quad_pos + pads >= 4:
						return out
				continue
			var v := -1
			if c >= 65 and c <= 90: v = c - 65
			elif c >= 97 and c <= 122: v = c - 71
			elif c >= 48 and c <= 57: v = c + 4
			elif c == 43: v = 62
			elif c == 47: v = 63
			if v < 0:
				continue
			pads = 0
			match quad_pos:
				0:
					quad_pos = 1
					left = v
				1:
					quad_pos = 2
					out.append(((left << 2) | (v >> 4)) & 0xFF)
					left = v & 0x0F
				2:
					quad_pos = 3
					out.append(((left << 4) | (v >> 2)) & 0xFF)
					left = v & 0x03
				3:
					quad_pos = 0
					out.append(((left << 6) | v) & 0xFF)
					left = 0
		if quad_pos != 0:
			return null
		return out

	## plistlib._date_from_string -> microseconds since 2001-01-01.
	func _date(s: String) -> Variant:
		var re := RegEx.create_from_string(
			"^(\\d\\d\\d\\d)(?:-(\\d\\d)(?:-(\\d\\d)(?:T(\\d\\d)(?::(\\d\\d)(?::(\\d\\d))?)?)?)?)?Z")
		var m := re.search(s)
		if m == null:
			return null
		var lst: Array[int] = []
		for g in range(1, 7):
			if m.get_start(g) < 0:
				break
			lst.append(m.get_string(g).to_int())
		if lst.size() < 3:
			return null                       # datetime() needs year, month, day
		while lst.size() < 6:
			lst.append(0)
		var y := lst[0]
		var mo := lst[1]
		var dd := lst[2]
		if y < 1 or mo < 1 or mo > 12 or dd < 1 or lst[3] > 23 or lst[4] > 59 or lst[5] > 59:
			return null
		var mdays := [31, 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28,
			31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
		if dd > mdays[mo - 1]:
			return null
		var unix := Time.get_unix_time_from_datetime_dict({
			"year": y, "month": mo, "day": dd, "hour": lst[3], "minute": lst[4], "second": lst[5]})
		return (int(unix) - 978307200) * 1000000
