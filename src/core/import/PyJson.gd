# Python-compatible numbers and JSON text, for the in-game IPA importer.
#
# The importer replaces the Python nib and plist converters, whose output
# is the reference. Matching it *exactly* needs three pieces of CPython
# behaviour that GDScript does not have:
#
#   round_ndigits(x, n)  == round(x, n): the double nearest to x correctly
#                           rounded to n decimals, ties to even on the EXACT
#                           binary value (round(2.675, 2) == 2.67,
#                           round(0.125, 2) == 0.12). snappedf() is not this.
#   parse_float(s)       == float(s) for the decimal strings archives carry
#                           ('{{0, 0}, {320, 480}}' geometry, NSRGB colours).
#   dumps(v)             == json.dumps(v, indent=1): ensure_ascii escapes,
#                           ', ' / ': ' separators, float repr ('1.0', '1e-05',
#                           '1e+16'), ints without a decimal point.
#
# All static and stateless, so the importer can call them from its thread.
extends RefCounted


# --- round(x, n) ------------------------------------------------------------

## CPython's round(x, n) for 0 <= n <= 22.
##
## x = m * 2^e exactly (m a 53-bit integer). For e >= 0 x is an integer and
## round() returns it unchanged. Otherwise x * 10^n = m * 5^n / 2^(-e-n), and
## m * 5^n stays below 2^63 for n <= 4 (5^4 * 2^53 < 2^63), so the quotient and
## remainder are exact integers -- the tie test is exact, not a float compare.
## The result q / 10^n is one IEEE division of two exactly representable
## integers, i.e. correctly rounded: the same double CPython's dtoa/strtod round
## trip produces. Larger n falls back to a float path (unused by the importer).
static func round_ndigits(x: float, n: int) -> float:
	if is_nan(x) or is_inf(x) or x == 0.0:
		return x
	if n < 0 or n > 4:
		return _round_fallback(x, n)
	var b := PackedByteArray()
	b.resize(8)
	b.encode_double(0, x)
	var bits := b.decode_s64(0)
	var neg := bits < 0
	var exp_bits := (bits >> 52) & 0x7FF
	var mant := bits & 0xFFFFFFFFFFFFF
	var m: int
	var e: int
	if exp_bits == 0:
		m = mant
		e = -1074
	else:
		m = mant | (1 << 52)
		e = exp_bits - 1075
	if e >= 0:
		return x                       # an integer already
	var num := m * _pow5(n)            # < 2^63 for n <= 4
	var s := -e - n                    # x * 10^n = num / 2^s
	if s <= 0:
		return x                       # exactly representable with n decimals
	var q: int
	if s >= 64:
		q = 0                          # num < 2^63 <= 2^(s-1): below one half
	else:
		q = num >> s
		var r := num - (q << s)
		var half := 1 << (s - 1)
		if r > half or (r == half and (q & 1) == 1):
			q += 1
	if q >= (1 << 53):
		return x                       # beyond double precision at n decimals
	var out := float(q) / _pow10(n)
	return -out if neg else out


static func _round_fallback(x: float, n: int) -> float:
	if n < 0:
		var p := _pow10(-n)
		return roundf(x / p) * p
	var p2 := _pow10(n)
	return roundf(x * p2) / p2


static func _pow5(n: int) -> int:
	var p := 1
	for i in n:
		p *= 5
	return p


## 10^n as a double; exact for n <= 22 (5^22 < 2^53).
static func _pow10(n: int) -> float:
	var p := 1.0
	for i in n:
		p *= 10.0
	return p


# --- float(s) ---------------------------------------------------------------

## CPython float(s): surrounding whitespace, sign, digits with one optional
## '.', optional exponent, 'inf'/'infinity'/'nan', PEP 515 underscores between
## digits. Returns null where CPython raises ValueError.
##
## Up to 15 significant digits and |exponent| <= 22 the value is computed as
## one IEEE multiply/divide of exact operands (Clinger's fast path), which is
## correctly rounded. Longer inputs fall back to String.to_float().
static func parse_float(s: String) -> Variant:
	var t := s.strip_edges()
	if t.is_empty():
		return null
	var i := 0
	var neg := false
	if t[0] == "+" or t[0] == "-":
		neg = t[0] == "-"
		i = 1
	var rest := t.substr(i).to_lower()
	if rest == "inf" or rest == "infinity":
		return -INF if neg else INF
	if rest == "nan":
		return NAN
	var digits := ""
	var frac_digits := 0
	var seen_dot := false
	var n_digits := 0
	var L := t.length()
	while i < L:
		var c := t.unicode_at(i)
		if c >= 48 and c <= 57:
			digits += t[i]
			n_digits += 1
			if seen_dot:
				frac_digits += 1
		elif c == 46 and not seen_dot:        # '.'
			seen_dot = true
		elif c == 95:                         # '_' only between two digits
			if i == 0 or i + 1 >= L or not _is_digit(t.unicode_at(i - 1)) \
					or not _is_digit(t.unicode_at(i + 1)):
				return null
		else:
			break
		i += 1
	if n_digits == 0:
		return null
	var exp10 := 0
	if i < L and (t[i] == "e" or t[i] == "E"):
		i += 1
		var eneg := false
		if i < L and (t[i] == "+" or t[i] == "-"):
			eneg = t[i] == "-"
			i += 1
		var estart := i
		var ev := 0
		while i < L:
			var c2 := t.unicode_at(i)
			if _is_digit(c2):
				ev = mini(ev * 10 + (c2 - 48), 100000)
			elif c2 == 95 and i > estart and i + 1 < L and _is_digit(t.unicode_at(i + 1)):
				pass
			else:
				break
			i += 1
		if i == estart:
			return null
		exp10 = -ev if eneg else ev
	if i != L:
		return null
	# Normalise: strip leading zeros of the mantissa.
	var j := 0
	while j < digits.length() - 1 and digits[j] == "0":
		j += 1
	digits = digits.substr(j)
	var e := exp10 - frac_digits
	var value: float
	if digits.length() <= 15 and e >= -22 and e <= 22:
		var m := float(digits.to_int())
		if e >= 0:
			value = m * _pow10(e)
		else:
			value = m / _pow10(-e)
	else:
		value = t.replace("_", "").to_float()
		return value                          # sign already in t
	return -value if neg else value


static func _is_digit(c: int) -> bool:
	return c >= 48 and c <= 57


# --- repr(float) -------------------------------------------------------------

## CPython's float repr ('r' format): shortest round-trip digits, fixed
## notation for 1e-4 <= |x| < 1e16 (always with a '.0' or fraction), otherwise
## 'd[.ddd]e[+-]XX'. String.num_scientific() supplies the shortest digits.
static func repr_float(x: float) -> String:
	if is_nan(x):
		return "NaN"
	if is_inf(x):
		return "Infinity" if x > 0 else "-Infinity"
	var sb := PackedByteArray()
	sb.resize(8)
	sb.encode_double(0, x)
	var neg := sb.decode_s64(0) < 0             # sign bit, so -0.0 -> '-0.0'
	var s := String.num_scientific(absf(x))
	var mant := s
	var ex := 0
	var epos := s.find("e")
	if epos >= 0:
		mant = s.substr(0, epos)
		ex = s.substr(epos + 1).to_int()
	var ip := mant
	var fp := ""
	var dot := mant.find(".")
	if dot >= 0:
		ip = mant.substr(0, dot)
		fp = mant.substr(dot + 1)
	var digits := ip + fp
	var decpt := ip.length() + ex
	var k := 0
	while k < digits.length() and digits[k] == "0":
		k += 1
	digits = digits.substr(k)
	decpt -= k
	while digits.length() > 0 and digits[digits.length() - 1] == "0":
		digits = digits.substr(0, digits.length() - 1)
	if not digits.is_empty():
		var fixed := _tie_fix(absf(x), digits, decpt)
		digits = fixed[0]
		decpt = fixed[1]
	var out: String
	if digits.is_empty():
		out = "0.0"
	elif decpt <= -4 or decpt > 16:
		var e := decpt - 1
		out = digits[0]
		if digits.length() > 1:
			out += "." + digits.substr(1)
		out += ("e-" if e < 0 else "e+") + ("%02d" % absi(e))
	elif decpt <= 0:
		out = "0." + "0".repeat(-decpt) + digits
	elif decpt >= digits.length():
		out = digits + "0".repeat(decpt - digits.length()) + ".0"
	else:
		out = digits.substr(0, decpt) + "." + digits.substr(decpt)
	return ("-" + out) if neg else out


## num_scientific() finds the shortest round-trip length L but breaks an
## exact tie between two L-digit candidates upwards ('559.6592407226563'),
## where CPython's dtoa picks the even one ('559.6592407226562'). A tie needs
## the exact decimal expansion of x to have L+1 digits ending in 5, i.e.
## x = N / 10^k with N = m * 5^k below 10^18 -- small enough to test exactly
## in int64. Anything longer cannot tie and is returned unchanged.
static func _tie_fix(ax: float, digits: String, decpt: int) -> Array:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_double(0, ax)
	var bits := b.decode_s64(0)
	var exp_bits := (bits >> 52) & 0x7FF
	var mant := bits & 0xFFFFFFFFFFFFF
	if exp_bits == 0 or exp_bits == 0x7FF:
		return [digits, decpt]                 # subnormal / special: leave
	var m := mant | (1 << 52)
	var e := exp_bits - 1075
	var pow2 := mant == 0
	while (m & 1) == 0:
		m >>= 1
		e += 1
	if e >= 0:
		return [digits, decpt]                 # integer: its expansion is exact
	var k := -e
	var n := m
	for i in k:
		if n > 200000000000000000:             # 10^18 / 5: no tie possible
			return [digits, decpt]
		n *= 5
	var ns := str(n)
	var L := digits.length()
	if ns.length() != L + 1 or not ns.ends_with("5"):
		return [digits, decpt]
	var lower := n / 10
	var pick := lower if (lower & 1) == 0 else lower + 1
	# At a power of two the gap below x is half the gap above, so the lower
	# candidate only round-trips once 5^(k-1) >= 2^54, i.e. k >= 25.
	if pick == lower and pow2 and k < 25:
		pick = lower + 1
	var nd := ns.length() - k                  # decpt of x itself
	var ps := str(pick)
	if ps.length() > L:                        # carry: 99..9 -> 100..0
		nd += 1
	while ps.length() > 1 and ps.ends_with("0"):
		ps = ps.substr(0, ps.length() - 1)
	return [ps, nd]


# --- json.dumps(v, indent=1) --------------------------------------------------

## json.dumps(v, indent=indent) as CPython writes it (ensure_ascii, no
## trailing newline). Dictionary order is preserved; non-String keys are
## stringified the way json does (int -> '5', float -> repr, bool -> 'true',
## null -> 'null').
static func dumps(v: Variant, indent: int = 1) -> String:
	var parts := PackedStringArray()
	var esc := RegEx.create_from_string("[^\\x20-\\x7e]|[\"\\\\]")
	_dump(v, indent, 0, parts, esc)
	return "".join(parts)


static func _dump(v: Variant, indent: int, level: int, parts: PackedStringArray, esc: RegEx) -> void:
	if level > 400:
		push_error("PyJson.dumps: nesting too deep (circular reference?)")
		parts.append("null")
		return
	match typeof(v):
		TYPE_NIL:
			parts.append("null")
		TYPE_BOOL:
			parts.append("true" if v else "false")
		TYPE_INT:
			parts.append(str(v))
		TYPE_FLOAT:
			parts.append(repr_float(v))
		TYPE_STRING, TYPE_STRING_NAME:
			parts.append(quote(String(v), esc))
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, \
				TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			if v.size() == 0:
				parts.append("[]")
				return
			var pad := "\n" + " ".repeat((level + 1) * indent)
			parts.append("[")
			var first := true
			for item in v:
				parts.append(pad if first else "," + pad)
				first = false
				_dump(item, indent, level + 1, parts, esc)
			parts.append("\n" + " ".repeat(level * indent) + "]")
		TYPE_DICTIONARY:
			if v.is_empty():
				parts.append("{}")
				return
			var pad2 := "\n" + " ".repeat((level + 1) * indent)
			parts.append("{")
			var first2 := true
			for k in v:
				parts.append(pad2 if first2 else "," + pad2)
				first2 = false
				parts.append(quote(_key_string(k), esc))
				parts.append(": ")
				_dump(v[k], indent, level + 1, parts, esc)
			parts.append("\n" + " ".repeat(level * indent) + "}")
		_:
			push_error("PyJson.dumps: value of type %s is not JSON serializable" % type_string(typeof(v)))
			parts.append("null")


static func _key_string(k: Variant) -> String:
	match typeof(k):
		TYPE_STRING, TYPE_STRING_NAME:
			return String(k)
		TYPE_BOOL:
			return "true" if k else "false"
		TYPE_NIL:
			return "null"
		TYPE_INT:
			return str(k)
		TYPE_FLOAT:
			return repr_float(k)
	return str(k)


## A JSON string literal with json's ensure_ascii escaping.
static func quote(s: String, esc: RegEx = null) -> String:
	if esc == null:
		esc = RegEx.create_from_string("[^\\x20-\\x7e]|[\"\\\\]")
	if esc.search(s) == null:
		return "\"" + s + "\""
	var out := PackedStringArray()
	out.append("\"")
	for i in s.length():
		var c := s.unicode_at(i)
		if c == 0x22:
			out.append("\\\"")
		elif c == 0x5C:
			out.append("\\\\")
		elif c >= 0x20 and c <= 0x7E:
			out.append(s[i])
		elif c == 0x0A:
			out.append("\\n")
		elif c == 0x0D:
			out.append("\\r")
		elif c == 0x09:
			out.append("\\t")
		elif c == 0x08:
			out.append("\\b")
		elif c == 0x0C:
			out.append("\\f")
		elif c > 0xFFFF:
			var u := c - 0x10000
			out.append("\\u%04x\\u%04x" % [0xD800 | (u >> 10), 0xDC00 | (u & 0x3FF)])
		else:
			out.append("\\u%04x" % c)
	out.append("\"")
	return "".join(out)
