# GDScript port of tiff_to_png() in the Python asset extractor.
#
# One bundle file needs it: ca_waterdrop.png is really a big-endian TIFF
# (magic "MM\0*") under a .png name, and SSEmitter loads it by that name, so
# the importer writes a real PNG under the same name.
#
# Only what that file is: a baseline, uncompressed, 8-bit RGB/RGBA, chunky
# TIFF. decode() returns null for anything else -- exactly the cases where the
# Python returns False -- so the caller can keep the raw bytes as .tiff
# instead of guessing. Associated (premultiplied) alpha is turned straight
# with the same integer formula.
#
# Verified pixel-equal to the Python output.

extends RefCounted


static func is_tiff(d: PackedByteArray) -> bool:
	return d.size() >= 4 and ((d[0] == 0x4D and d[1] == 0x4D) or (d[0] == 0x49 and d[1] == 0x49))


## The decoded image (RGBA8 for 4 samples, RGB8 for 3), or null.
@warning_ignore("integer_division")
static func decode(d: PackedByteArray) -> Image:
	if d.size() < 8 or not is_tiff(d):
		return null
	var be := d[0] == 0x4D
	var off := _u32(d, 4, be)
	if off + 2 > d.size():
		return null
	var n := _u16(d, off, be)
	# tag -> Array[int]; only SHORT (3) and LONG (4) entries, as in the Python.
	var tags := {}
	for i in n:
		var e := off + 2 + i * 12
		if e + 12 > d.size():
			return null
		var tag := _u16(d, e, be)
		var typ := _u16(d, e + 2, be)
		var cnt := _u32(d, e + 4, be)
		if typ != 3 and typ != 4:
			continue
		var w := 2 if typ == 3 else 4
		var size := w * cnt
		var at := e + 8 if size <= 4 else _u32(d, e + 8, be)
		if at + size > d.size():
			return null
		var vals: Array[int] = []
		for k in cnt:
			vals.append(_u16(d, at + k * 2, be) if typ == 3 else _u32(d, at + k * 4, be))
		tags[tag] = vals
	var width := _tag0(tags, 256, 0)
	var height := _tag0(tags, 257, 0)
	var spp := _tag0(tags, 277, 1)
	var bits: Array = tags.get(258, [8])
	for b: int in bits:
		if b != 8:
			return null
	if (_tag0(tags, 259, 1) != 1 or _tag0(tags, 262, 0) != 2
			or (spp != 3 and spp != 4) or _tag0(tags, 284, 1) != 1):
		return null
	if not (tags.has(273) and tags.has(279)) or width <= 0 or height <= 0:
		return null
	var pix := PackedByteArray()
	var offs: Array = tags[273]
	var counts: Array = tags[279]
	for i in mini(offs.size(), counts.size()):    # zip() stops at the shorter
		var o: int = offs[i]
		pix.append_array(d.slice(o, o + int(counts[i])))
	var stride := width * spp
	if pix.size() < stride * height:
		return null
	pix = pix.slice(0, stride * height)
	if spp == 4 and _tag0(tags, 338, 2) == 1:     # associated alpha -> straight
		for i in range(0, pix.size(), 4):
			var a := pix[i + 3]
			if a:
				for k in 3:
					pix[i + k] = mini(255, pix[i + k] * 255 / a)
	return Image.create_from_data(width, height, false,
		Image.FORMAT_RGBA8 if spp == 4 else Image.FORMAT_RGB8, pix)


## PNG file bytes, or empty when decode() fails.
static func to_png(d: PackedByteArray) -> PackedByteArray:
	var img := decode(d)
	return img.save_png_to_buffer() if img != null else PackedByteArray()


static func _tag0(tags: Dictionary, tag: int, default: int) -> int:
	var v: Array = tags.get(tag, [default])
	return v[0] if not v.is_empty() else default


static func _u16(d: PackedByteArray, at: int, be: bool) -> int:
	return (d[at] << 8 | d[at + 1]) if be else (d[at] | d[at + 1] << 8)


static func _u32(d: PackedByteArray, at: int, be: bool) -> int:
	if be:
		return d[at] << 24 | d[at + 1] << 16 | d[at + 2] << 8 | d[at + 3]
	return d[at] | d[at + 1] << 8 | d[at + 2] << 16 | d[at + 3] << 24
