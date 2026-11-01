# GDScript port of the Python artwork extractor, for the eight images the
# port uses (the Python setup pipeline's UIKIT_ART): the iOS 6 alert box,
# its buttons, the dimming spotlight behind it, and the three
# scroll-indicator styles.
#
# iOS 6 packs most UIKit chrome into UIKit.framework/Shared@2x.artwork. The
# layout (read off the file):
#
#     u32 count, u32 entries_offset, u32 name_offset[count] -> "Name.png\0"
#     at entries_offset, count x {u32 format, u16 w, u16 h, u32 offset}
#     format 0 = BGRA premultiplied, 1 = BGRX opaque, 2 = gray8 (rows padded
#     to 4 bytes); pixels top row first
#
# Output is straight-alpha RGBA at the file's native (@2x) size, un-
# premultiplied with the Python's rounding: (c * 255 + a / 2) / a.
# Verified pixel-equal to the Python extractor's output.

extends RefCounted

const NAMES: PackedStringArray = [
	"UIAlertViewDimmingSpotlight.png", "UIPopupAlertSheetBackground.png",
	"UIPopupAlertSheetButton.png", "UIPopupAlertSheetButtonPress.png",
	"UIPopupAlertSheetDefaultButton.png", "UIScrollerIndicatorBlack.png",
	"UIScrollerIndicatorDefault.png", "UIScrollerIndicatorWhite.png",
]

const FMT_BGRA_PREMUL := 0
const FMT_BGRX := 1
const FMT_GRAY8 := 2


## Reads the entry table. {ok, error, entries: {name: {format, width, height,
## offset}}}. Cheap: touches only the header, so it is also the probe the
## first-run screen uses when the file is dropped.
static func read_index(d: PackedByteArray) -> Dictionary:
	var bad := {"ok": false, "error": "not an iOS .artwork file", "entries": {}}
	if d.size() < 8:
		return bad
	var count := d.decode_u32(0)
	var entries_off := d.decode_u32(4)
	if count == 0 or 8 + count * 4 > d.size() or entries_off + count * 12 > d.size():
		return bad
	var entries := {}
	for i in count:
		var no := d.decode_u32(8 + i * 4)
		var end := d.find(0, no)
		if no >= d.size() or end < 0:
			return bad
		var name := d.slice(no, end).get_string_from_utf8()
		var e := entries_off + 12 * i
		entries[name] = {
			"format": d.decode_u32(e), "width": d.decode_u16(e + 4),
			"height": d.decode_u16(e + 6), "offset": d.decode_u32(e + 8),
		}
	return {"ok": true, "error": "", "entries": entries}


## {ok, error, images: {name: Image}, missing: PackedStringArray}. ok is false
## when any wanted name is absent (the Python extractor exits 1 then, which
## stops the setup pipeline) or the file is not an artwork file.
static func extract(d: PackedByteArray, names: PackedStringArray = NAMES) -> Dictionary:
	var index := read_index(d)
	var out := {"ok": false, "error": index.error, "images": {}, "missing": PackedStringArray()}
	if not index.ok:
		return out
	var entries: Dictionary = index.entries
	for name in names:
		if not entries.has(name):
			out.missing.append(name)
			continue
		var img := _to_image(d, entries[name])
		if img == null:
			out.error = "%s is truncated or in an unknown format" % name
			return out
		out.images[name] = img
	if not out.missing.is_empty():
		out.error = "not in this artwork file: " + ", ".join(out.missing)
		return out
	out.ok = true
	return out


static func extract_file(path: String, names: PackedStringArray = NAMES) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "file not found", "images": {}, "missing": names}
	return extract(FileAccess.get_file_as_bytes(path), names)


@warning_ignore("integer_division")
static func _to_image(d: PackedByteArray, e: Dictionary) -> Image:
	var fmt: int = e.format
	var w: int = e.width
	var h: int = e.height
	var off: int = e.offset
	if fmt != FMT_BGRA_PREMUL and fmt != FMT_BGRX and fmt != FMT_GRAY8:
		return null
	if w == 0 or h == 0:
		return null
	var bpp := 1 if fmt == FMT_GRAY8 else 4
	var stride := (w * bpp + 3) / 4 * 4
	if off + stride * (h - 1) + w * bpp > d.size():
		return null
	var px := PackedByteArray()
	px.resize(w * h * 4)
	var o := 0
	for y in h:
		var r0 := off + y * stride
		if fmt == FMT_GRAY8:
			for x in w:
				var g := d[r0 + x]
				px[o] = g
				px[o + 1] = g
				px[o + 2] = g
				px[o + 3] = 255
				o += 4
			continue
		for x in w:
			var i := r0 + 4 * x
			var b := d[i]
			var g := d[i + 1]
			var r := d[i + 2]
			var a := d[i + 3]
			if fmt == FMT_BGRX:
				a = 255
			elif a > 0 and a < 255:
				var half := a / 2
				r = mini(255, (r * 255 + half) / a)
				g = mini(255, (g * 255 + half) / a)
				b = mini(255, (b * 255 + half) / a)
			px[o] = r
			px[o + 1] = g
			px[o + 2] = b
			px[o + 3] = a
			o += 4
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)
