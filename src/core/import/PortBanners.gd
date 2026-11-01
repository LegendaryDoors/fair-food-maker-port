# GDScript port of the Python banner generator: the port's reworded pour
# banners (a port choice: tilt-to-pour became click-and-hold).
#
# No font is involved. Every letter of the new wording is cut out of the
# game's own banners and set with the spacing measured from them, as the
# Python generator did. This file follows it line for line,
# including Python's round-half-to-even (_py_round) and its dictionary
# orders, so the output is pixel-identical to the port_inst_*.png images
# the Python generator wrote.
#
#   port_inst_pour.png         CLICK AND HOLD / TO POUR!
#   port_inst_pour_batter.png  CLICK AND HOLD TO POUR / INTO THE FUNNEL!
#
# Input: the four source banners as decoded Images (8-bit RGBA PNGs).

extends RefCounted

const FG := [238, 199, 0]
const ROW0 := 11                   # TEXT_ROWS = range(11, 48)
const ROW1 := 48
const COL0 := 18                   # TEXT_COLS = range(18, 202)
const COL1 := 202
const SAFE_COLS := [22, 198]

# Transcriptions of the source banners, line by line. Order matters: the
# first glyph found for a letter is the one that gets used.
const SOURCES := {
	"inst_pour.png": ["TILT YOUR DEVICE", "TO POUR!"],
	"inst_shake.png": ["SHAKE YOUR DEVICE", "TO FINISH MIXING!"],
	"inst_add_water.png": ["PULL THE HANDLE", "TO ADD WATER!"],
	"inst_pour_batter.png": ["TILT TO POUR THE BATTER", "INTO THE FUNNEL!"],
}

# target -> [output file, new lines (null keeps the original line)]
const TARGETS := {
	"inst_pour.png": ["port_inst_pour.png", ["CLICK AND HOLD", null]],
	"inst_pour_batter.png": ["port_inst_pour_batter.png", ["CLICK AND HOLD TO POUR", null]],
}


## True when the PNG is what read_png() accepts: 8-bit RGBA, non-interlaced.
static func png_ok(bytes: PackedByteArray) -> bool:
	return (bytes.size() > 33 and bytes[12] == 0x49 and bytes[13] == 0x48
		and bytes[24] == 8 and bytes[25] == 6 and bytes[28] == 0)


## sources: {file name: Image} for every key of SOURCES.
## -> {ok, error, images: {output name: Image}}
static func build_all(sources: Dictionary) -> Dictionary:
	var out := {"ok": false, "error": "", "images": {}}
	var lib := _library(sources)
	if lib.error != "":
		out.error = lib.error
		return out
	for src: String in TARGETS:
		var res := _build(sources[src], src, TARGETS[src][1], lib)
		if res.error != "":
			out.error = res.error
			return out
		out.images[TARGETS[src][0]] = res.image
	out.ok = true
	return out


# --- one analysed banner -----------------------------------------------------

class _Px:
	var w := 0
	var h := 0
	var data := PackedByteArray()     # RGBA8

	func _init(img: Image) -> void:
		var im := img.duplicate() as Image
		if im.get_format() != Image.FORMAT_RGBA8:
			im.convert(Image.FORMAT_RGBA8)
		w = im.get_width()
		h = im.get_height()
		data = im.get_data()

	func g(x: int, y: int) -> int:
		return data[(y * w + x) * 4 + 1]

	func key(x: int, y: int) -> int:
		var i := (y * w + x) * 4
		return data[i] << 24 | data[i + 1] << 16 | data[i + 2] << 8 | data[i + 3]

	func put(x: int, y: int, c: Array) -> void:
		var i := (y * w + x) * 4
		for k in 4:
			data[i + k] = c[k]

	func image() -> Image:
		return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)


## Per-row background colour: the most common pixel with G < 20 in x 25..194
## (Counter.most_common(1): ties go to the colour seen first).
static func _background(px: _Px) -> Dictionary:
	var bg := {}
	for y in range(ROW0, ROW1):
		var counts := {}
		for x in range(25, 195):
			if px.g(x, y) < 20:
				var k := px.key(x, y)
				counts[k] = counts.get(k, 0) + 1
		if counts.is_empty():
			return {}
		var best := -1
		var best_n := 0
		for k: int in counts:
			if counts[k] > best_n:
				best = k
				best_n = counts[k]
		bg[y] = [best >> 24 & 255, best >> 16 & 255, best >> 8 & 255, best & 255]
	return bg


## Text coverage on TEXT_ROWS x TEXT_COLS, row-major from (COL0, ROW0).
static func _coverage(px: _Px, bg: Dictionary) -> PackedFloat64Array:
	var cov := PackedFloat64Array()
	cov.resize((ROW1 - ROW0) * (COL1 - COL0))
	var i := 0
	for y in range(ROW0, ROW1):
		var bgg: int = bg[y][1]
		for x in range(COL0, COL1):
			cov[i] = clampf(float(px.g(x, y) - bgg) / float(FG[1] - bgg), 0.0, 1.0)
			i += 1
	return cov


static func _cov(cov: PackedFloat64Array, x: int, y: int) -> float:
	if y < ROW0 or y >= ROW1 or x < COL0 or x >= COL1:
		return 0.0
	return cov[(y - ROW0) * (COL1 - COL0) + (x - COL0)]


static func _bands(cov: PackedFloat64Array) -> Array:
	var out: Array = []
	for y in range(ROW0, ROW1):
		var hit := false
		for x in range(COL0, COL1):
			if _cov(cov, x, y) > 0.05:
				hit = true
				break
		if not hit:
			continue
		if not out.is_empty() and y == out[-1][1] + 1:
			out[-1][1] = y
		else:
			out.append([y, y])
	return out


## Connected (4-way) letter cores in a line, as [x0, x1, {Vector2i: true}],
## sorted by x0; a "!" (bar + dot) is merged. Components that tie on x0 are
## the "!" halves, which have identical boxes, so their order cannot matter.
static func _cores(cov: PackedFloat64Array, band: Array, thr: float) -> Array:
	var pts := {}
	for y in range(band[0], band[1] + 1):
		for x in range(COL0, COL1):
			if _cov(cov, x, y) >= thr:
				pts[Vector2i(x, y)] = true
	var boxes: Array = []
	var seen := {}
	for p: Vector2i in pts:
		if seen.has(p):
			continue
		var comp := {p: true}
		seen[p] = true
		var stack: Array[Vector2i] = [p]
		while not stack.is_empty():
			var q: Vector2i = stack.pop_back()
			for n: Vector2i in [q + Vector2i(1, 0), q + Vector2i(-1, 0), q + Vector2i(0, 1), q + Vector2i(0, -1)]:
				if pts.has(n) and not seen.has(n):
					seen[n] = true
					comp[n] = true
					stack.append(n)
		var x0 := 1 << 30
		var x1 := -1
		for c: Vector2i in comp:
			x0 = mini(x0, c.x)
			x1 = maxi(x1, c.x)
		boxes.append([x0, x1, comp])
	boxes.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var merged: Array = []
	for b: Array in boxes:
		if (not merged.is_empty() and b[0] <= merged[-1][1]
				and mini(b[1], merged[-1][1]) - b[0] >= (b[1] - b[0]) * 0.6):
			merged[-1][1] = maxi(merged[-1][1], b[1])
			merged[-1][2].merge(b[2])
		else:
			merged.append(b)
	return merged


## Letter boxes for one line, matched to its transcription; [] on failure.
static func _segment(cov: PackedFloat64Array, band: Array, text: String) -> Array:
	var want := text.replace(" ", "").length()
	var m: Array = []
	for t in range(50, 96, 5):
		m = _cores(cov, band, float(t) / 100.0)
		if m.size() == want:
			break
	if m.size() != want:
		return []
	var letters: Array = []
	var i := 0
	var words := text.split(" ")
	for wi in words.size():
		var word := words[wi]
		for ci in word.length():
			letters.append({"ch": word[ci], "x0": m[i][0], "x1": m[i][1],
				"core": m[i][2], "word_start": ci == 0 and wi > 0})
			i += 1
	return letters


## The letter's coverage: core box plus one column of edge AA each side,
## keeping only edge pixels that touch this letter's own core. px is a list
## of [dx, dy, v] in the Python dict's insertion order (rows, then columns).
static func _glyph(cov: PackedFloat64Array, band: Array, letter: Dictionary) -> Dictionary:
	var x0: int = letter.x0
	var x1: int = letter.x1
	var core: Dictionary = letter.core
	var px: Array = []
	for y in range(band[0], band[1] + 1):
		for x in range(x0 - 1, x1 + 2):
			var v := _cov(cov, x, y)
			if v <= 0:
				continue
			var keep := x0 <= x and x <= x1
			if not keep:
				for dx in [-1, 0, 1]:
					for dy in [-1, 0, 1]:
						if core.has(Vector2i(x + dx, y + dy)):
							keep = true
			if keep:
				px.append([x - x0, y - band[0], v])
	return {"ch": letter.ch, "w": x1 - x0 + 1, "px": px}


# The glyph library: {by_height: {band height: {ch: [glyph]}},
# pairs: {"height|a|b": [core gap]}, lines: {"file|index": {band, letters,
# cov, bg}}}, or {error} when a source banner cannot be read.
static func _library(sources: Dictionary) -> Dictionary:
	var by_height := {}
	var pairs := {}
	var lines := {}
	for name: String in SOURCES:
		if not sources.has(name) or sources[name] == null:
			return {"error": "%s is missing" % name}
		var texts: Array = SOURCES[name]
		var px := _Px.new(sources[name])
		var bg := _background(px)
		if bg.is_empty():
			return {"error": "%s: no background on a text row" % name}
		var cov := _coverage(px, bg)
		var bs := _bands(cov)
		if bs.size() != texts.size():
			return {"error": "%s: %d text lines, expected %d" % [name, bs.size(), texts.size()]}
		for i in bs.size():
			var band: Array = bs[i]
			var letters := _segment(cov, band, texts[i])
			if letters.is_empty():
				return {"error": 'could not split "%s" into letters' % texts[i]}
			var hgt: int = band[1] - band[0] + 1
			lines["%s|%d" % [name, i]] = {"band": band, "letters": letters, "cov": cov, "bg": bg}
			var lib: Dictionary = by_height.get_or_add(hgt, {})
			for k in letters.size():
				var lt: Dictionary = letters[k]
				(lib.get_or_add(lt.ch, []) as Array).append(_glyph(cov, band, lt))
				if k > 0 and not lt.word_start:
					var prev: Dictionary = letters[k - 1]
					(pairs.get_or_add("%d|%s|%s" % [hgt, prev.ch, lt.ch], []) as Array).append(
						int(lt.x0) - int(prev.x1) - 1)
	return {"error": "", "by_height": by_height, "pairs": pairs, "lines": lines}


## [placed: [[x, glyph]], width], or [] when a letter is unavailable.
static func _set_line(lib: Dictionary, text: String, hgt: int, gap: int, space: int) -> Array:
	var glyphs: Dictionary = lib.by_height.get(hgt, {})
	var placed: Array = []
	var x := 0
	var prev := ""
	var words := text.split(" ")
	for wi in words.size():
		var word := words[wi]
		for ci in word.length():
			var ch := word[ci]
			if not glyphs.has(ch):
				return []
			var g: Dictionary = glyphs[ch][0]
			if prev != "":
				if ci == 0:
					x += space
				else:
					var seen: Array = lib.pairs.get("%d|%s|%s" % [hgt, prev, ch], [])
					if seen.is_empty():
						x += gap
					else:
						var total := 0
						for s: int in seen:
							total += s
						x += _py_round(float(total) / float(seen.size()))
			placed.append([x, g])
			x += int(g.w)
			prev = ch
	return [placed, x]


static func _build(src_img: Image, src: String, new_lines: Array, lib: Dictionary) -> Dictionary:
	var px := _Px.new(src_img)
	for i in new_lines.size():
		var text: Variant = new_lines[i]
		if text == null:
			continue
		var line: Dictionary = lib.lines["%s|%d" % [src, i]]
		var band: Array = line.band
		var letters: Array = line.letters
		var bg: Dictionary = line.bg
		var hgt: int = band[1] - band[0] + 1
		var gaps: Array = []
		var spaces: Array = []
		for k in range(1, letters.size()):
			var d: int = int(letters[k].x0) - int(letters[k - 1].x1) - 1
			(spaces if letters[k].word_start else gaps).append(d)
		if gaps.is_empty():
			return {"error": '"%s" has no letter gaps to measure' % text, "image": null}
		var gap := _median(gaps)
		var space := 0
		if not spaces.is_empty():
			space = _median(spaces)
		else:
			var all: Array = []
			for key: String in lib.lines:
				var ls: Array = lib.lines[key].letters
				for k in range(1, ls.size()):
					if ls[k].word_start:
						all.append(int(ls[k].x0) - int(ls[k - 1].x1) - 1)
			space = _median(all)
		var line_set := _set_line(lib, text, hgt, gap, space)
		if line_set.is_empty():
			return {"error": 'a letter of "%s" is not in the source banners' % text, "image": null}
		var placed: Array = line_set[0]
		var width: int = line_set[1]
		var old_x0: int = letters[0].x0
		var old_x1: int = letters[-1].x1
		var left := _py_round(float(old_x0 + old_x1 + 1) / 2.0 - float(width) / 2.0)
		if left < SAFE_COLS[0] or left + width > SAFE_COLS[1]:
			return {"error": '"%s" is %d px wide: does not fit the banner' % [text, width], "image": null}
		# Erase the old line to its row's background, then set the new one.
		for y in range(band[0] - 1, band[1] + 2):
			for x in range(mini(old_x0, left) - 2, maxi(old_x1, left + width) + 3):
				px.put(x, y, bg[y])
		var acc := {}
		for pg: Array in placed:
			var gx: int = pg[0]
			for e: Array in pg[1].px:
				var k := Vector2i(left + gx + int(e[0]), int(band[0]) + int(e[1]))
				acc[k] = minf(1.0, float(acc.get(k, 0.0)) + float(e[2]))
		for k: Vector2i in acc:
			var v: float = acc[k]
			var b: Array = bg[k.y]
			var c := [0, 0, 0, 255]
			for ch in 3:
				c[ch] = _py_round(float(b[ch]) + float(int(FG[ch]) - int(b[ch])) * v)
			px.put(k.x, k.y, c)
	return {"error": "", "image": px.image()}


@warning_ignore("integer_division")
static func _median(v: Array) -> int:
	var s := v.duplicate()
	s.sort()
	return s[s.size() / 2]


## Python 3 round(): nearest integer, ties to even. x - floor(x) is exact for
## doubles of this size, so the tie test is exact too.
static func _py_round(x: float) -> int:
	var f := floorf(x)
	var diff := x - f
	if diff > 0.5:
		return int(f) + 1
	if diff < 0.5:
		return int(f)
	return int(f) if int(f) % 2 == 0 else int(f) + 1
