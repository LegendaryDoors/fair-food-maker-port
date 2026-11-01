# MP4 / M4A container reader (ISO/IEC 14496-12 / -14) for the importer's AAC
# decoder. Pulls out of the first sound track exactly what AacDecoder.gd
# needs: the AudioSpecificConfig (esds), the sample table (stsz / stsc /
# stco|co64 -> per-access-unit file offset + size), stts / ctts timing, the
# edit list (edts/elst) and the iTunes gapless tag (iTunSMPB).
#
# Written for this port from the ISO box definitions; no third-party code.
#
#   var info := M4a.parse(bytes)
#   info.ok, info.error, info.asc (PackedByteArray), info.offsets
#   (PackedInt64Array), info.sizes (PackedInt32Array), info.timescale (mdhd),
#   info.movie_timescale (mvhd), info.stts ([[count, delta], ...]),
#   info.ctts ([[count, offset], ...]), info.elst ([[duration, media_time,
#   rate], ...]), info.itunsmpb (String, "" if absent), info.channels and
#   info.sample_rate (from the mp4a sample entry), info.duration (mdhd).
extends RefCounted


static func parse(b: PackedByteArray) -> Dictionary:
	var r := {
		"ok": false, "error": "", "asc": PackedByteArray(), "offsets": PackedInt64Array(),
		"sizes": PackedInt32Array(), "timescale": 0, "movie_timescale": 0, "duration": 0,
		"stts": [], "ctts": [], "elst": [], "itunsmpb": "", "channels": 0, "sample_rate": 0,
	}
	var moov := _find(b, 0, b.size(), "moov")
	if moov.is_empty():
		r.error = "no moov box"
		return r
	var mvhd := _find(b, moov.body, moov.end, "mvhd")
	if not mvhd.is_empty():
		r.movie_timescale = _u32(b, mvhd.body + (20 if b[mvhd.body] == 1 else 12))
	r.itunsmpb = _find_itunsmpb(b, moov)

	var trak_found := false
	for trak: Dictionary in _boxes(b, moov.body, moov.end):
		if trak.type != "trak":
			continue
		var mdia := _find(b, trak.body, trak.end, "mdia")
		if mdia.is_empty():
			continue
		var hdlr := _find(b, mdia.body, mdia.end, "hdlr")
		if hdlr.is_empty() or _fourcc(b, hdlr.body + 8) != "soun":
			continue
		trak_found = true
		var mdhd := _find(b, mdia.body, mdia.end, "mdhd")
		if not mdhd.is_empty():
			if b[mdhd.body] == 1:
				r.timescale = _u32(b, mdhd.body + 20)
				r.duration = _u64(b, mdhd.body + 24)
			else:
				r.timescale = _u32(b, mdhd.body + 12)
				r.duration = _u32(b, mdhd.body + 16)
		var edts := _find(b, trak.body, trak.end, "edts")
		if not edts.is_empty():
			var elst := _find(b, edts.body, edts.end, "elst")
			if not elst.is_empty():
				r.elst = _read_elst(b, elst)
		var minf := _find(b, mdia.body, mdia.end, "minf")
		var stbl := {} if minf.is_empty() else _find(b, minf.body, minf.end, "stbl")
		if stbl.is_empty():
			r.error = "sound track has no stbl"
			return r
		var err := _read_stbl(b, stbl, r)
		if err != "":
			r.error = err
			return r
		break
	if not trak_found:
		r.error = "no sound track"
		return r
	r.ok = true
	return r


# --- sample table -----------------------------------------------------------

static func _read_stbl(b: PackedByteArray, stbl: Dictionary, r: Dictionary) -> String:
	var stsd := _find(b, stbl.body, stbl.end, "stsd")
	if stsd.is_empty():
		return "no stsd"
	var entry: int = stsd.body + 8
	if entry + 8 > stsd.end or _fourcc(b, entry + 4) != "mp4a":
		return "first sample entry is not mp4a"
	var entry_end: int = mini(entry + _u32(b, entry), stsd.end)
	# SampleEntry (8 + 8) + AudioSampleEntry (20); QuickTime sound description
	# versions 1 and 2 append 16 / 36 bytes.
	var ver := _u16(b, entry + 16)
	r.channels = _u16(b, entry + 24)
	r.sample_rate = _u32(b, entry + 32) >> 16
	var kids: int = entry + 36 + (16 if ver == 1 else (36 if ver == 2 else 0))
	var esds := _find(b, kids, entry_end, "esds")
	if esds.is_empty():
		return "mp4a entry has no esds"
	r.asc = _esds_asc(b, esds.body + 4, esds.end)
	if r.asc.is_empty():
		return "esds has no DecoderSpecificInfo"

	var stsz := _find(b, stbl.body, stbl.end, "stsz")
	var stsc := _find(b, stbl.body, stbl.end, "stsc")
	var stco := _find(b, stbl.body, stbl.end, "stco")
	var co64 := _find(b, stbl.body, stbl.end, "co64")
	if stsz.is_empty() or stsc.is_empty() or (stco.is_empty() and co64.is_empty()):
		return "incomplete sample table"
	var fixed := _u32(b, stsz.body + 4)
	var count := _u32(b, stsz.body + 8)
	if fixed == 0 and stsz.body + 12 + 4 * count > stsz.end:
		return "stsz is truncated"
	var sizes := PackedInt32Array()
	sizes.resize(count)
	for i in count:
		sizes[i] = fixed if fixed != 0 else _u32(b, stsz.body + 12 + 4 * i)

	var chunks := PackedInt64Array()
	if not stco.is_empty():
		var n := _u32(b, stco.body + 4)
		if stco.body + 8 + 4 * n > stco.end:
			return "stco is truncated"
		chunks.resize(n)
		for i in n:
			chunks[i] = _u32(b, stco.body + 8 + 4 * i)
	else:
		var n := _u32(b, co64.body + 4)
		if co64.body + 8 + 8 * n > co64.end:
			return "co64 is truncated"
		chunks.resize(n)
		for i in n:
			chunks[i] = _u64(b, co64.body + 8 + 8 * i)

	var sc_n := _u32(b, stsc.body + 4)
	if stsc.body + 8 + 12 * sc_n > stsc.end:
		return "stsc is truncated"
	var offsets := PackedInt64Array()
	offsets.resize(count)
	var s := 0
	for e in sc_n:
		var first := _u32(b, stsc.body + 8 + 12 * e) - 1
		var per := _u32(b, stsc.body + 12 + 12 * e)
		var last := chunks.size() if e + 1 == sc_n else _u32(b, stsc.body + 8 + 12 * (e + 1)) - 1
		for c in range(first, mini(last, chunks.size())):
			var off: int = chunks[c]
			for k in per:
				if s >= count:
					break
				offsets[s] = off
				off += sizes[s]
				s += 1
	if s != count:
		return "sample table maps %d of %d samples" % [s, count]
	for i in count:
		if offsets[i] + sizes[i] > b.size():
			return "sample %d lies outside the file" % i
	r.offsets = offsets
	r.sizes = sizes

	var stts := _find(b, stbl.body, stbl.end, "stts")
	if not stts.is_empty():
		if stts.body + 8 + 8 * _u32(b, stts.body + 4) > stts.end:
			return "stts is truncated"
		for e in _u32(b, stts.body + 4):
			r.stts.append([_u32(b, stts.body + 8 + 8 * e), _u32(b, stts.body + 12 + 8 * e)])
	var ctts := _find(b, stbl.body, stbl.end, "ctts")
	if not ctts.is_empty():
		if ctts.body + 8 + 8 * _u32(b, ctts.body + 4) > ctts.end:
			return "ctts is truncated"
		for e in _u32(b, ctts.body + 4):
			r.ctts.append([_u32(b, ctts.body + 8 + 8 * e), _s32(b, ctts.body + 12 + 8 * e)])
	return ""


static func _read_elst(b: PackedByteArray, elst: Dictionary) -> Array:
	var out := []
	var v1 := b[elst.body] == 1
	var p: int = elst.body + 8
	if p + (20 if v1 else 12) * _u32(b, elst.body + 4) > elst.end:
		return out
	for e in _u32(b, elst.body + 4):
		if v1:
			out.append([_u64(b, p), _u64(b, p + 8), _s32(b, p + 16) / 65536.0])
			p += 20
		else:
			out.append([_u32(b, p), _s32(b, p + 4), _s32(b, p + 8) / 65536.0])
			p += 12
	return out


# ES_Descriptor (0x03) > DecoderConfigDescriptor (0x04) > DecoderSpecificInfo (0x05)
static func _esds_asc(b: PackedByteArray, p: int, end: int) -> PackedByteArray:
	while p + 2 <= end:
		var tag := b[p]
		p += 1
		var dlen := 0
		for i in 4:
			var c := b[p]
			p += 1
			dlen = (dlen << 7) | (c & 0x7F)
			if c & 0x80 == 0:
				break
		match tag:
			0x03:
				var flags := b[p + 2]
				p += 3
				if flags & 0x80:
					p += 2
				if flags & 0x40:
					p += 1 + b[p]
				if flags & 0x20:
					p += 2
			0x04:
				p += 13
			0x05:
				return b.slice(p, p + dlen) if p + dlen <= end else PackedByteArray()
			_:
				p += dlen
	return PackedByteArray()


# moov/udta/meta/ilst/---- {mean "com.apple.iTunes", name "iTunSMPB", data}
static func _find_itunsmpb(b: PackedByteArray, moov: Dictionary) -> String:
	var udta := _find(b, moov.body, moov.end, "udta")
	if udta.is_empty():
		return ""
	var meta := _find(b, udta.body, udta.end, "meta")
	if meta.is_empty():
		return ""
	# ISO meta is a full box; QuickTime's is not. Tell them apart by looking for
	# the hdlr child where the first child would start.
	var kids: int = meta.body if _fourcc(b, meta.body + 4) == "hdlr" else meta.body + 4
	var ilst := _find(b, kids, meta.end, "ilst")
	if ilst.is_empty():
		return ""
	for item: Dictionary in _boxes(b, ilst.body, ilst.end):
		if item.type != "----":
			continue
		var name := ""
		var data := ""
		for sub: Dictionary in _boxes(b, item.body, item.end):
			if sub.type == "name":
				name = b.slice(sub.body + 4, sub.end).get_string_from_utf8()
			elif sub.type == "data":
				data = b.slice(sub.body + 8, sub.end).get_string_from_utf8()
		if name == "iTunSMPB":
			return data
	return ""


# --- box walking ------------------------------------------------------------

static func _boxes(b: PackedByteArray, start: int, end: int) -> Array:
	var out := []
	var p := start
	while p + 8 <= end:
		var size := _u32(b, p)
		var hdr := 8
		if size == 1:
			size = _u64(b, p + 8)
			hdr = 16
		elif size == 0:
			size = end - p
		if size < hdr or p + size > end:
			break
		out.append({"type": _fourcc(b, p + 4), "start": p, "body": p + hdr, "end": p + size})
		p += size
	return out


static func _find(b: PackedByteArray, start: int, end: int, type: String) -> Dictionary:
	for box: Dictionary in _boxes(b, start, end):
		if box.type == type:
			return box
	return {}


static func _fourcc(b: PackedByteArray, p: int) -> String:
	if p + 4 > b.size():
		return ""
	return b.slice(p, p + 4).get_string_from_ascii()


static func _u16(b: PackedByteArray, p: int) -> int:
	return (b[p] << 8) | b[p + 1]


static func _u32(b: PackedByteArray, p: int) -> int:
	return (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]


static func _s32(b: PackedByteArray, p: int) -> int:
	var v := _u32(b, p)
	return v - 0x100000000 if v >= 0x80000000 else v


static func _u64(b: PackedByteArray, p: int) -> int:
	return (_u32(b, p) << 32) | _u32(b, p + 4)
