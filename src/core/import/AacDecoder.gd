# AAC-LC decoder in pure GDScript (ISO/IEC 14496-3 subpart 4), for the
# first-run importer: the game's sustained sound loops ship as AAC-LC .m4a,
# which Godot cannot play, and players must not need ffmpeg installed.
#
#   const AacDecoder = preload("res://core/import/AacDecoder.gd")
#   var r := AacDecoder.decode_m4a(bytes)
#   # r.ok, r.error, r.mix_rate, r.channels, r.frames (per channel),
#   # r.pcm16 (PackedByteArray, interleaved signed 16-bit little-endian)
#   var wav := AacDecoder.wav_bytes(r)          # RIFF/WAVE PCM-16 file bytes
#
# Supported: object type 2 (AAC-LC), 1024-sample frames, mono (SCE) and
# stereo (CPE), the 12 standard sample rates. Tools: ics_info, section data,
# scalefactors, spectral Huffman codebooks 1-11 with escapes, pulse data,
# TNS, M/S and intensity stereo, PNS, ONLY_LONG / LONG_START / EIGHT_SHORT /
# LONG_STOP windows with sine and KBD shapes, IMDCT + overlap-add.
# Refused with an error rather than guessed: SBR / PS (HE-AAC), Main-profile
# prediction, LTP, gain control, coupling channels, 960-sample frames and
# layouts other than one SCE or one CPE.
# PNS noise comes from a textbook LCG (1664525, 1013904223) whose seed and
# draw order were chosen so the noise equals ffmpeg's (verified on ffmpeg-
# encoded PNS streams). Not implemented: the correlated-noise case (PNS in
# both channels of an M/S band; never occurs in any tested stream). Intensity
# sign with ms_mask_present == 2 follows the spec (untested: never occurs).
# None of the game's 22 loops uses PNS, intensity, KBD, pulses or edit lists.
#
# Gapless trimming follows what ffmpeg does with these files, so the output
# sample count equals ffmpeg's: edit list if present, else the iTunSMPB
# priming / valid-sample counts, else (FAAC files) the 1024-sample skip that
# a "libfaac" EXT_FILL signature in the first frame implies plus the stts
# end trim.
#
# Written for this port from the ISO/IEC 14496-3 decoding process. No code
# from ffmpeg, faad2 or aac.js (all (L)GPL) was used; ffmpeg served only as a
# black-box reference for the output. Constant tables: AacTables.gd (MIT,
# credit in that file).
extends RefCounted

const M4a = preload("res://core/import/M4a.gd")
const T = preload("res://core/import/AacTables.gd")

const ONLY_LONG := 0
const LONG_START := 1
const EIGHT_SHORT := 2
const LONG_STOP := 3

const NOISE_HCB := 13
const INTENSITY_HCB2 := 14
const INTENSITY_HCB := 15

static var _lock := Mutex.new()
static var _tables := {}


## Decodes a whole .m4a file. Never throws; check r.ok / r.error.
static func decode_m4a(bytes: PackedByteArray) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var res := {"ok": false, "error": "", "mix_rate": 0, "channels": 0, "frames": 0,
		"pcm16": PackedByteArray(), "trim": "", "stats": {}}
	var info := M4a.parse(bytes)
	if not info.ok:
		res.error = "m4a: " + str(info.error)
		return res
	var asc := _parse_asc(info.asc)
	if asc.error != "":
		res.error = asc.error
		return res
	var nch: int = asc.channels
	var sizes: PackedInt32Array = info.sizes
	var offsets: PackedInt64Array = info.offsets
	var n := sizes.size()
	if n == 0:
		res.error = "no audio samples"
		return res

	var dec := _Dec.new()
	dec.setup(_get_tables(), asc.sfi, nch)
	var pcm := PackedByteArray()
	pcm.resize(n * 1024 * nch * 2)
	dec.out = pcm
	for i in n:
		var off: int = offsets[i]
		var sz: int = sizes[i]
		var frame := bytes.slice(off, off + sz)
		# Zero tail: valid streams only need 4 bytes for the 32-bit peeks; 2 KB
		# keeps a corrupt one inside the buffer until the next overread check.
		frame.resize(sz + 2048)
		dec.out_base = i * 1024
		var err := dec.decode_frame(frame, sz, i)
		if err != "":
			res.error = "frame %d of %d: %s" % [i, n, err]
			return res

	# --- priming / padding trim (ffmpeg-equivalent, see header) -------------
	var total := n * 1024
	var skip := 0
	var length := total
	var trim := ""
	var smpb := _parse_itunsmpb(info.itunsmpb)
	var edit := _first_edit(info.elst)
	if not edit.is_empty() and info.movie_timescale > 0:
		skip = maxi(0, edit[1])
		length = int(round(float(edit[0]) * info.timescale / info.movie_timescale))
		trim = "edit list: skip %d, keep %d" % [skip, length]
	elif not smpb.is_empty() and smpb[0] > 0 and smpb[0] < 16384:
		skip = smpb[0]
		length = smpb[2] if smpb[2] > 0 else total - smpb[0] - smpb[1]
		trim = "iTunSMPB: skip %d, keep %d (padding %d)" % [skip, length, smpb[1]]
	else:
		var stts_sum := 0
		for e: Array in info.stts:
			stts_sum += int(e[0]) * int(e[1])
		var end_trim := maxi(0, total - stts_sum) if stts_sum > 0 else 0
		if dec.libfaac_frame == 0:
			skip = 1024
		length = total - skip - end_trim
		trim = "%s, stts end trim %d" % ["libfaac FIL: skip 1024" if skip else "no priming info", end_trim]
	length = clampi(length, 0, total - skip)
	res.pcm16 = pcm.slice(skip * nch * 2, (skip + length) * nch * 2)
	res.ok = true
	res.mix_rate = asc.rate
	res.channels = nch
	res.frames = length
	res.trim = trim
	dec.stats["access_units"] = n
	dec.stats["decode_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	res.stats = dec.stats
	return res


## RIFF/WAVE (PCM, 16-bit LE) bytes for a decode_m4a() result.
static func wav_bytes(result: Dictionary) -> PackedByteArray:
	var pcm: PackedByteArray = result.get("pcm16", PackedByteArray())
	var ch: int = result.get("channels", 1)
	var rate: int = result.get("mix_rate", 44100)
	var w := PackedByteArray()
	w.resize(44)
	w.encode_u32(0, 0x46464952)  # "RIFF"
	w.encode_u32(4, 36 + pcm.size())
	w.encode_u32(8, 0x45564157)  # "WAVE"
	w.encode_u32(12, 0x20746d66)  # "fmt "
	w.encode_u32(16, 16)
	w.encode_u16(20, 1)  # PCM
	w.encode_u16(22, ch)
	w.encode_u32(24, rate)
	w.encode_u32(28, rate * ch * 2)
	w.encode_u16(32, ch * 2)
	w.encode_u16(34, 16)
	w.encode_u32(36, 0x61746164)  # "data"
	w.encode_u32(40, pcm.size())
	w.append_array(pcm)
	return w


# --- configuration -----------------------------------------------------------

static func _parse_asc(a: PackedByteArray) -> Dictionary:
	var r := {"error": "", "sfi": 0, "rate": 0, "channels": 0}
	if a.size() < 2:
		r.error = "AudioSpecificConfig too short"
		return r
	var br := _Bits.new(a)
	var aot := br.read(5)
	if aot == 31:
		aot = 32 + br.read(6)
	var sfi := br.read(4)
	var rate := 0
	if sfi == 15:
		rate = br.read(24)
	elif sfi < 13:
		rate = T.SAMPLE_RATES[sfi]
	var chc := br.read(4)
	if aot == 5 or aot == 29:
		r.error = "HE-AAC (SBR%s) is not supported" % ("/PS" if aot == 29 else "")
		return r
	if aot != 2:
		r.error = "audio object type %d is not AAC-LC" % aot
		return r
	if sfi > 11:
		r.error = "unsupported sampling frequency index %d" % sfi
		return r
	if br.read(1) != 0:
		r.error = "960-sample frames are not supported"
		return r
	if br.read(1) != 0:
		br.read(14)  # coreCoderDelay
	br.read(1)  # extensionFlag (0 for AAC-LC)
	if chc == 0:
		# Layout given by a program_config_element: accept a lone SCE or CPE.
		br.read(4 + 2 + 4)
		var nf := br.read(4)
		var ns := br.read(4)
		var nb := br.read(4)
		var nl := br.read(2)
		var na := br.read(3)
		var nc := br.read(4)
		if br.read(1):
			br.read(4)
		if br.read(1):
			br.read(4)
		if br.read(1):
			br.read(3)
		var cpe := 0
		for i in nf + ns + nb:
			cpe = br.read(1)
			br.read(4)
		br.pos += 4 * (nl + na) + 5 * nc
		br.pos = (br.pos + 7) & ~7
		br.pos += 8 * br.read(8)
		if nf + ns + nb != 1 or nl + nc != 0:
			r.error = "program config with %d front/side/back, %d LFE, %d CC elements is not supported" % [nf + ns + nb, nl, nc]
			return r
		chc = 2 if cpe else 1
	if chc < 1 or chc > 2:
		r.error = "channel configuration %d is not supported (mono/stereo only)" % chc
		return r
	# Backward-compatible explicit SBR signalling (sync extension 0x2b7).
	if br.left() >= 16 and br.peek(11) == 0x2b7:
		br.read(11)
		if br.read(5) == 5 and br.read(1) == 1:
			r.error = "HE-AAC (SBR signalled in AudioSpecificConfig) is not supported"
			return r
	r.sfi = sfi
	r.rate = rate
	r.channels = chc
	return r


static func _parse_itunsmpb(s: String) -> Array:
	var parts := s.strip_edges().split(" ", false)
	if parts.size() < 4:
		return []
	return [parts[1].hex_to_int(), parts[2].hex_to_int(), parts[3].hex_to_int()]


static func _first_edit(elst: Array) -> Array:
	for e: Array in elst:
		if int(e[1]) >= 0:
			return e
	return []


# --- constant tables (built once, shared, read-only afterwards) --------------

static func _get_tables() -> Dictionary:
	_lock.lock()
	if _tables.is_empty():
		_tables = _build_tables()
	_lock.unlock()
	return _tables


static func _build_tables() -> Dictionary:
	var t := {}
	# Scalefactor codebook: symbol = index (delta + 60).
	var sf_syms := PackedInt32Array()
	for i in 121:
		sf_syms.append(i)
	t.sf_bits = 10
	t.sf_tab = _build_huff(T.SF_HUFF, sf_syms, 10)
	# Spectral codebooks: symbol = the decoded tuple, one 5-bit field per
	# coefficient (dim 4: base-3 digits; dim 2: base 9 / 8 / 13 / 17 digits).
	var mods := [0, 3, 3, 3, 3, 9, 9, 8, 8, 13, 13, 17]
	var cb_tab := [PackedInt32Array()]
	var cb_bits := PackedInt32Array([0])
	for cb in range(1, 12):
		var flat: Array = T.SPEC_HUFF[cb]
		var m: int = mods[cb]
		var syms := PackedInt32Array()
		var maxlen := 0
		for i in flat.size() / 2:
			maxlen = maxi(maxlen, flat[2 * i])
			if cb <= 4:
				syms.append((i / 27) | (((i / 9) % 3) << 5) | (((i / 3) % 3) << 10) | ((i % 3) << 15))
			else:
				syms.append((i / m) | ((i % m) << 5))
		var l1 := mini(maxlen, 10)
		cb_bits.append(l1)
		cb_tab.append(_build_huff(flat, syms, l1))
	t.cb_tab = cb_tab
	t.cb_bits = cb_bits
	# |q|^(4/3) and 2^((sf - 100) / 4).
	var p43 := PackedFloat64Array()
	p43.resize(8192 + 32)
	for i in p43.size():
		p43[i] = pow(float(i), 4.0 / 3.0)
	t.pow43 = p43
	var p2 := PackedFloat64Array()
	p2.resize(256)
	for i in 256:
		p2[i] = pow(2.0, 0.25 * (i - 100))
	t.pow2sf = p2
	# Rising window halves, [shape] with 0 = sine, 1 = KBD (alpha 4 / 6).
	t.win_long = [_sine_half(2048), _kbd_half(2048, 4.0)]
	t.win_short = [_sine_half(256), _kbd_half(256, 6.0)]
	t.imdct_long = _imdct_tables(1024)
	t.imdct_short = _imdct_tables(128)
	return t


# Two-level lookup: the first `l1` bits index the table; codes longer than
# that land on a pointer entry (-1 - (sub_start << 5 | extra_bits)) to a
# sub-table indexed by the following bits. Leaf = symbol << 5 | code length.
static func _build_huff(flat: Array, syms: PackedInt32Array, l1: int) -> PackedInt32Array:
	var n := flat.size() / 2
	var ext := {}
	for i in n:
		var ln: int = flat[2 * i]
		if ln > l1:
			var pre: int = flat[2 * i + 1] >> (ln - l1)
			ext[pre] = maxi(ext.get(pre, 0), ln - l1)
	var size := 1 << l1
	var base := {}
	var tab := PackedInt32Array()
	tab.resize(size)
	for pre: int in ext:
		base[pre] = size
		tab[pre] = -1 - ((size << 5) | int(ext[pre]))
		size += 1 << int(ext[pre])
	tab.resize(size)
	for i in n:
		var ln: int = flat[2 * i]
		var code: int = flat[2 * i + 1]
		var leaf := (syms[i] << 5) | ln
		if ln <= l1:
			var s := code << (l1 - ln)
			for k in 1 << (l1 - ln):
				tab[s + k] = leaf
		else:
			var pre := code >> (ln - l1)
			var e: int = ext[pre]
			var rest := ln - l1
			var s: int = int(base[pre]) + ((code & ((1 << rest) - 1)) << (e - rest))
			for k in 1 << (e - rest):
				tab[s + k] = leaf
	return tab


static func _sine_half(n: int) -> PackedFloat64Array:
	var w := PackedFloat64Array()
	w.resize(n / 2)
	for i in n / 2:
		w[i] = sin(PI / n * (i + 0.5))
	return w


# Kaiser-Bessel-derived window, rising half (ISO/IEC 14496-3 4.6.11.3.2).
static func _kbd_half(n: int, alpha: float) -> PackedFloat64Array:
	var half := n / 2
	var kern := PackedFloat64Array()
	kern.resize(half + 1)
	var total := 0.0
	for p in half + 1:
		var t := (p - n / 4.0) / (n / 4.0)
		kern[p] = _bessel_i0(PI * alpha * sqrt(maxf(0.0, 1.0 - t * t)))
		total += kern[p]
	var w := PackedFloat64Array()
	w.resize(half)
	var acc := 0.0
	for i in half:
		acc += kern[i]
		w[i] = sqrt(acc / total)
	return w


static func _bessel_i0(x: float) -> float:
	var sum := 1.0
	var term := 1.0
	var q := x * x / 4.0
	for k in range(1, 100):
		term *= q / float(k * k)
		sum += term
		if term < sum * 1e-17:
			break
	return sum


# IMDCT of M coefficients through an M/4-point complex FFT:
#   u = DCT-IV(X) with v[k] = (X[2k] + jX[M-1-2k]) * c_k, V = FFT(v),
#   Z[p] = V[p] * c_p, u[2p] = Re Z, u[M-1-2p] = -Im Z,
#   c_k = exp(-j pi (8k + 1) / (8M)); the 2/N = 1/M scale is folded into the
#   post-twiddle. The 2M-point IMDCT output is a signed rearrangement of u.
static func _imdct_tables(m: int) -> Dictionary:
	var q := m / 2
	var pc := PackedFloat64Array()
	var ps := PackedFloat64Array()
	var qc := PackedFloat64Array()
	var qs := PackedFloat64Array()
	for k in q:
		var a := PI * (8 * k + 1) / (8.0 * m)
		pc.append(cos(a))
		ps.append(sin(a))
		qc.append(cos(a) / m)
		qs.append(sin(a) / m)
	var twr := PackedFloat64Array()
	var twi := PackedFloat64Array()
	for j in q / 2:
		twr.append(cos(-TAU * j / q))
		twi.append(sin(-TAU * j / q))
	var bits := 0
	while (1 << bits) < q:
		bits += 1
	var rev := PackedInt32Array()
	for k in q:
		var r := 0
		for b in bits:
			if k & (1 << b):
				r |= 1 << (bits - 1 - b)
		rev.append(r)
	return {"pc": pc, "ps": ps, "qc": qc, "qs": qs, "twr": twr, "twi": twi, "rev": rev}


# --- small MSB-first reader for the config ----------------------------------

class _Bits:
	var b: PackedByteArray
	var pos := 0

	func _init(data: PackedByteArray) -> void:
		b = data

	func left() -> int:
		return b.size() * 8 - pos

	func peek(n: int) -> int:
		var v := 0
		for i in n:
			var p := pos + i
			var bit := 0 if (p >> 3) >= b.size() else (b[p >> 3] >> (7 - (p & 7))) & 1
			v = (v << 1) | bit
		return v

	func read(n: int) -> int:
		var v := peek(n)
		pos += n
		return v


# --- per-channel state --------------------------------------------------------

class _Chan:
	var spec := PackedFloat64Array()
	var q := PackedInt32Array()
	var overlap := PackedFloat64Array()
	var last_shape := 0
	var last_seq := ONLY_LONG
	# ics_info
	var window_sequence := ONLY_LONG
	var window_shape := 0
	var max_sfb := 0
	var num_groups := 1
	var group_len := PackedInt32Array()
	var swb := PackedInt32Array()
	var num_swb := 0
	# per [group * 64 + sfb]
	var band_type := PackedInt32Array()
	var sf := PackedInt32Array()
	# pulse
	var pulse_n := 0
	var pulse_pos := PackedInt32Array()
	var pulse_amp := PackedInt32Array()
	# TNS, per [window * 4 + filter]
	var tns_present := false
	var tns_nfilt := PackedInt32Array()
	var tns_len := PackedInt32Array()
	var tns_order := PackedInt32Array()
	var tns_dir := PackedInt32Array()
	var tns_coef := PackedFloat64Array()  # [(w * 4 + f) * 32 + i]

	func _init() -> void:
		spec.resize(1024)
		q.resize(1024)
		overlap.resize(1024)
		group_len.resize(8)
		band_type.resize(8 * 64)
		sf.resize(8 * 64)
		pulse_pos.resize(4)
		pulse_amp.resize(4)
		tns_nfilt.resize(8)
		tns_len.resize(32)
		tns_order.resize(32)
		tns_dir.resize(32)
		tns_coef.resize(32 * 32)

	func copy_info(o: _Chan) -> void:
		window_sequence = o.window_sequence
		window_shape = o.window_shape
		max_sfb = o.max_sfb
		num_groups = o.num_groups
		for g in 8:
			group_len[g] = o.group_len[g]
		swb = o.swb
		num_swb = o.num_swb


# --- the decoder --------------------------------------------------------------

class _Dec:
	var sfi := 4
	var nch := 1
	var swb_long := PackedInt32Array()
	var swb_short := PackedInt32Array()
	var tns_max_long := 0
	var tns_max_short := 0
	var sf_tab := PackedInt32Array()
	var sf_bits := 10
	var cb_tab: Array = []
	var cb_bits := PackedInt32Array()
	var pow43 := PackedFloat64Array()
	var pow2sf := PackedFloat64Array()
	var win_long: Array = []
	var win_short: Array = []
	var il: Dictionary
	var ish: Dictionary

	var ch: Array = []  # [_Chan, _Chan]
	var ms_used := PackedInt32Array()
	var rand_state := 0x1f2e3d4c
	# scratch
	var u := PackedFloat64Array()
	var re := PackedFloat64Array()
	var im := PackedFloat64Array()
	var z := PackedFloat64Array()
	var o := PackedFloat64Array()
	var lpc := PackedFloat64Array()
	var lpc_b := PackedFloat64Array()

	# bit reader over the current access unit
	var buf := PackedByteArray()
	var pos := 0
	var end_bits := 0

	# output
	var out := PackedByteArray()
	var out_base := 0
	var libfaac_frame := -1
	var frame_index := 0
	var stats := {
		"seq": [0, 0, 0, 0], "kbd_frames": 0, "ms_bands": 0, "is_bands": 0, "is_ms2_bands": 0,
		"pns_bands": 0, "pns_ms_bands": 0, "tns_filters": 0, "pulses": 0, "fil": {}, "dse": 0, "pce": 0,
		"odd_transitions": 0, "esc": 0,
	}

	func setup(t: Dictionary, sf_index: int, channels: int) -> void:
		sfi = sf_index
		nch = channels
		swb_long = PackedInt32Array(T.SWB_LONG[sfi])
		swb_short = PackedInt32Array(T.SWB_SHORT[sfi])
		tns_max_long = T.TNS_MAX_BANDS_LONG[sfi]
		tns_max_short = T.TNS_MAX_BANDS_SHORT[sfi]
		sf_tab = t.sf_tab
		sf_bits = t.sf_bits
		cb_tab = t.cb_tab
		cb_bits = t.cb_bits
		pow43 = t.pow43
		pow2sf = t.pow2sf
		win_long = t.win_long
		win_short = t.win_short
		il = t.imdct_long
		ish = t.imdct_short
		ch = [_Chan.new(), _Chan.new()]
		ms_used.resize(8 * 64)
		u.resize(1024)
		re.resize(512)
		im.resize(512)
		z.resize(2048)
		o.resize(1024)
		lpc.resize(33)
		lpc_b.resize(33)

	# -- bits --
	func bits(n: int) -> int:
		var p := pos >> 3
		var v: int = (((buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3]) << (pos & 7)) & 0xFFFFFFFF
		pos += n
		return v >> (32 - n)

	func huff_sf() -> int:
		var p := pos >> 3
		var v: int = (((buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3]) << (pos & 7)) & 0xFFFFFFFF
		var e: int = sf_tab[v >> (32 - sf_bits)]
		if e < 0:
			var t := -1 - e
			var x := t & 31
			e = sf_tab[(t >> 5) + ((v >> (32 - sf_bits - x)) & ((1 << x) - 1))]
		pos += e & 31
		return (e >> 5) - 60

	# -- raw_data_block --
	func decode_frame(frame: PackedByteArray, size: int, index: int) -> String:
		buf = frame
		pos = 0
		end_bits = size * 8
		frame_index = index
		var got_audio := false
		while true:
			if pos + 3 > end_bits:
				return "access unit ends without an END element"
			var id := bits(3)
			if id == 7:
				break
			var err := ""
			match id:
				0:
					bits(4)
					if nch != 1 or got_audio:
						return "unexpected single channel element"
					var c: _Chan = ch[0]
					err = ics(c, false)
					if err == "":
						apply_tns(c)
						filterbank(c, 0)
					got_audio = true
				1:
					bits(4)
					if nch != 2 or got_audio:
						return "unexpected channel pair element"
					err = cpe()
					got_audio = true
				2:
					return "coupling channel element is not supported"
				3:
					return "LFE element is not supported"
				4:
					bits(4)
					var align := bits(1)
					var cnt := bits(8)
					if cnt == 255:
						cnt += bits(8)
					if align:
						pos = (pos + 7) & ~7
					pos += cnt * 8
					stats.dse += 1
				5:
					skip_pce()
					stats.pce += 1
				6:
					err = fil()
			if err != "":
				return err
			if pos > end_bits:
				return "bitstream overread"
		if not got_audio:
			return "access unit carries no audio element"
		return ""

	func skip_pce() -> void:
		bits(4)
		bits(2)
		bits(4)
		var nf := bits(4)
		var ns := bits(4)
		var nb := bits(4)
		var nl := bits(2)
		var na := bits(3)
		var nc := bits(4)
		if bits(1):
			bits(4)
		if bits(1):
			bits(4)
		if bits(1):
			bits(3)
		pos += (nf + ns + nb) * 5 + nl * 4 + na * 4 + nc * 5
		pos = (pos + 7) & ~7
		pos += bits(8) * 8

	func fil() -> String:
		var cnt := bits(4)
		if cnt == 15:
			cnt += bits(8) - 1
		if cnt <= 0:
			return ""
		var start := pos
		var et := bits(4)
		stats.fil[et] = int(stats.fil.get(et, 0)) + 1
		if et == 13 or et == 14:
			return "SBR extension payload (HE-AAC) is not supported"
		if et == 0:
			# An encoder signature; ffmpeg skips 1024 samples when it reads
			# "libfaac <major>.<minor>" here (FAAC primes one frame).
			var left := 8 * cnt - 4
			if left >= 13 + 7 * 8:
				pos += 13
				left -= 13
				var s := PackedByteArray()
				while s.size() < 255 and left >= 8:
					s.append(bits(8))
					left -= 8
				if _is_libfaac(s) and libfaac_frame < 0:
					libfaac_frame = frame_index
		pos = start + cnt * 8
		return ""

	static func _is_libfaac(s: PackedByteArray) -> bool:
		var nul := s.find(0)
		var txt := (s if nul < 0 else s.slice(0, nul)).get_string_from_ascii()
		if not txt.begins_with("libfaac"):
			return false
		var rest := txt.substr(7).strip_edges(true, false)
		var dot := rest.find(".")
		if dot <= 0:
			return false
		var major := rest.substr(0, dot)
		var minor := rest.substr(dot + 1)
		if major.begins_with("+") or major.begins_with("-"):
			major = major.substr(1)
		return major.is_valid_int() and minor.length() > 0 and minor.substr(0, 1).is_valid_int()

	func cpe() -> String:
		var c0: _Chan = ch[0]
		var c1: _Chan = ch[1]
		var common := bits(1)
		var ms := 0
		var err := ""
		if common:
			err = ics_info(c0)
			if err != "":
				return err
			c1.copy_info(c0)
			ms = bits(2)
			if ms == 3:
				return "reserved ms_mask_present value"
			for g in c0.num_groups:
				for sfb in c0.max_sfb:
					ms_used[g * 64 + sfb] = bits(1) if ms == 1 else (1 if ms == 2 else 0)
		err = ics(c0, common == 1)
		if err != "":
			return err
		err = ics(c1, common == 1)
		if err != "":
			return err
		if common and ms:
			apply_ms(c0, c1)
		apply_is(c0, c1, ms)
		apply_tns(c0)
		apply_tns(c1)
		filterbank(c0, 0)
		filterbank(c1, 1)
		return ""

	func ics_info(c: _Chan) -> String:
		if bits(1):
			return "ics_reserved_bit set"
		c.window_sequence = bits(2)
		c.window_shape = bits(1)
		if c.window_sequence == EIGHT_SHORT:
			c.max_sfb = bits(4)
			var grouping := bits(7)
			c.num_groups = 1
			c.group_len[0] = 1
			for i in 7:
				if grouping & (1 << (6 - i)):
					c.group_len[c.num_groups - 1] += 1
				else:
					c.group_len[c.num_groups] = 1
					c.num_groups += 1
			c.swb = swb_short
		else:
			c.max_sfb = bits(6)
			c.num_groups = 1
			c.group_len[0] = 1
			c.swb = swb_long
			if bits(1):
				return "predictor data in an AAC-LC stream"
		c.num_swb = c.swb.size() - 1
		if c.max_sfb > c.num_swb:
			return "max_sfb %d exceeds %d bands" % [c.max_sfb, c.num_swb]
		return ""

	# -- individual_channel_stream --
	func ics(c: _Chan, common: bool) -> String:
		var global_gain := bits(8)
		var err := ""
		if not common:
			err = ics_info(c)
			if err != "":
				return err
		var short := c.window_sequence == EIGHT_SHORT
		# section_data
		var sbits := 3 if short else 5
		var esc := (1 << sbits) - 1
		var bt := c.band_type
		for g in c.num_groups:
			var k := 0
			while k < c.max_sfb:
				var cb := bits(4)
				if cb == 12:
					return "reserved codebook 12"
				var n := 0
				var inc := bits(sbits)
				while inc == esc:
					n += esc
					inc = bits(sbits)
					if pos > end_bits:
						return "section data overread"
				n += inc
				if k + n > c.max_sfb:
					return "section exceeds max_sfb"
				for s in n:
					bt[g * 64 + k + s] = cb
				k += n
		# scale_factor_data
		var off_sf := global_gain
		var off_noise := global_gain - 90
		var off_is := 0
		var noise_first := true
		var sf := c.sf
		for g in c.num_groups:
			for sfb in c.max_sfb:
				var idx := g * 64 + sfb
				var cb: int = bt[idx]
				if cb == 0:
					sf[idx] = 0
				elif cb == INTENSITY_HCB or cb == INTENSITY_HCB2:
					off_is += huff_sf()
					sf[idx] = off_is
				elif cb == NOISE_HCB:
					if noise_first:
						noise_first = false
						off_noise += bits(9) - 256
					else:
						off_noise += huff_sf()
					sf[idx] = off_noise
				else:
					off_sf += huff_sf()
					if off_sf < 0 or off_sf > 255:
						return "scalefactor out of range"
					sf[idx] = off_sf
		if pos > end_bits:
			return "scalefactor data overread"
		# pulse_data
		c.pulse_n = 0
		if bits(1):
			if short:
				return "pulse data in a short-window frame"
			c.pulse_n = bits(2) + 1
			var start_sfb := bits(6)
			if start_sfb >= c.num_swb:
				return "pulse_start_sfb out of range"
			var k: int = c.swb[start_sfb]
			for i in c.pulse_n:
				k += bits(5)
				if k >= 1024:
					return "pulse offset out of range"
				c.pulse_pos[i] = k
				c.pulse_amp[i] = bits(4)
			stats.pulses += c.pulse_n
		# tns_data
		c.tns_present = bits(1) == 1
		if c.tns_present:
			err = tns_data(c, short)
			if err != "":
				return err
		if bits(1):
			return "gain control data in an AAC-LC stream"
		err = spectral(c)
		if err != "":
			return err
		dequant(c)
		return ""

	func tns_data(c: _Chan, short: bool) -> String:
		var nwin := 8 if short else 1
		for w in nwin:
			var nf := bits(1 if short else 2)
			c.tns_nfilt[w] = nf
			var coef_res := 0
			if nf:
				coef_res = bits(1)
			for f in nf:
				var fi := w * 4 + f
				c.tns_len[fi] = bits(4 if short else 6)
				var order := bits(3 if short else 5)
				c.tns_order[fi] = order
				if order == 0:
					continue
				stats.tns_filters += 1
				c.tns_dir[fi] = bits(1)
				var compress := bits(1)
				var nb := 3 + coef_res - compress
				var res_bits := 3 + coef_res
				var iq_pos := ((1 << (res_bits - 1)) - 0.5) / (PI / 2.0)
				var iq_neg := ((1 << (res_bits - 1)) + 0.5) / (PI / 2.0)
				for i in order:
					var raw := bits(nb)
					if raw & (1 << (nb - 1)):
						raw -= 1 << nb
					c.tns_coef[fi * 32 + i] = sin(raw / (iq_pos if raw >= 0 else iq_neg))
		return ""

	# -- spectral_data: Huffman decode into c.q --
	func spectral(c: _Chan) -> String:
		var q := c.q
		q.fill(0)
		var b := buf
		var p := 0
		var v := 0
		var e := 0
		var t := 0
		var x := 0
		var bp := pos
		var swb := c.swb
		var bt := c.band_type
		var win := 0
		for g in c.num_groups:
			var glen: int = c.group_len[g]
			for sfb in c.max_sfb:
				var cb: int = bt[g * 64 + sfb]
				if cb == 0 or cb > 11:
					continue
				var tab: PackedInt32Array = cb_tab[cb]
				var sh: int = 32 - cb_bits[cb]
				var start: int = swb[sfb]
				var width: int = swb[sfb + 1] - start
				for w in glen:
					var k: int = (win + w) * 128 + start
					var kend := k + width
					if cb <= 2:
						while k < kend:
							p = bp >> 3
							v = (((b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]) << (bp & 7)) & 0xFFFFFFFF
							e = tab[v >> sh]
							if e < 0:
								t = -1 - e
								x = t & 31
								e = tab[(t >> 5) + ((v >> (sh - x)) & ((1 << x) - 1))]
							bp += e & 31
							q[k] = ((e >> 5) & 31) - 1
							q[k + 1] = ((e >> 10) & 31) - 1
							q[k + 2] = ((e >> 15) & 31) - 1
							q[k + 3] = ((e >> 20) & 31) - 1
							k += 4
					elif cb <= 4:
						while k < kend:
							p = bp >> 3
							v = (((b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]) << (bp & 7)) & 0xFFFFFFFF
							e = tab[v >> sh]
							if e < 0:
								t = -1 - e
								x = t & 31
								e = tab[(t >> 5) + ((v >> (sh - x)) & ((1 << x) - 1))]
							bp += e & 31
							for d in 4:
								var m := (e >> (5 + 5 * d)) & 31
								if m != 0:
									if (b[bp >> 3] >> (7 - (bp & 7))) & 1:
										m = -m
									bp += 1
								q[k + d] = m
							k += 4
					elif cb <= 6:
						while k < kend:
							p = bp >> 3
							v = (((b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]) << (bp & 7)) & 0xFFFFFFFF
							e = tab[v >> sh]
							if e < 0:
								t = -1 - e
								x = t & 31
								e = tab[(t >> 5) + ((v >> (sh - x)) & ((1 << x) - 1))]
							bp += e & 31
							q[k] = ((e >> 5) & 31) - 4
							q[k + 1] = ((e >> 10) & 31) - 4
							k += 2
					else:
						while k < kend:
							p = bp >> 3
							v = (((b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]) << (bp & 7)) & 0xFFFFFFFF
							e = tab[v >> sh]
							if e < 0:
								t = -1 - e
								x = t & 31
								e = tab[(t >> 5) + ((v >> (sh - x)) & ((1 << x) - 1))]
							bp += e & 31
							var y := (e >> 5) & 31
							var zz := (e >> 10) & 31
							var ny := false
							var nz := false
							if y != 0:
								ny = ((b[bp >> 3] >> (7 - (bp & 7))) & 1) == 1
								bp += 1
							if zz != 0:
								nz = ((b[bp >> 3] >> (7 - (bp & 7))) & 1) == 1
								bp += 1
							if cb == 11:
								if y == 16:
									pos = bp
									y = escape()
									bp = pos
								if zz == 16:
									pos = bp
									zz = escape()
									bp = pos
								if y < 0 or zz < 0:
									return "escape sequence overflow"
							q[k] = -y if ny else y
							q[k + 1] = -zz if nz else zz
							k += 2
					if bp > end_bits:
						return "spectral data overread"
			win += glen
		pos = bp
		# pulse_data adds to the quantised magnitudes.
		for i in c.pulse_n:
			var k: int = c.pulse_pos[i]
			if q[k] > 0:
				q[k] += c.pulse_amp[i]
			else:
				q[k] -= c.pulse_amp[i]
		return ""

	func escape() -> int:
		var n := 0
		while bits(1) == 1:
			n += 1
			if n > 8:
				return -1
		stats.esc += 1
		return (1 << (n + 4)) + bits(n + 4)

	# -- inverse quantisation, rescaling, PNS --
	func dequant(c: _Chan) -> void:
		var spec := c.spec
		spec.fill(0.0)
		var q := c.q
		var p43 := pow43
		var swb := c.swb
		var bt := c.band_type
		var win := 0
		for g in c.num_groups:
			var glen: int = c.group_len[g]
			for sfb in c.max_sfb:
				var idx := g * 64 + sfb
				var cb: int = bt[idx]
				var start: int = swb[sfb]
				var width: int = swb[sfb + 1] - start
				if cb >= 1 and cb <= 11:
					var gain: float = pow2sf[c.sf[idx]]
					for w in glen:
						var k: int = (win + w) * 128 + start
						for i in width:
							var qv: int = q[k + i]
							if qv > 0:
								spec[k + i] = p43[qv] * gain
							elif qv < 0:
								spec[k + i] = -p43[-qv] * gain
				elif cb == NOISE_HCB:
					stats.pns_bands += 1
					var nrg := pow(2.0, 0.25 * c.sf[idx])
					for w in glen:
						var k: int = (win + w) * 128 + start
						var energy := 0.0
						for i in width:
							rand_state = (rand_state * 1664525 + 1013904223) & 0xFFFFFFFF
							var r := float(rand_state - 0x100000000 if rand_state >= 0x80000000 else rand_state)
							spec[k + i] = r
							energy += r * r
						var sc := nrg / sqrt(energy) if energy > 0.0 else 0.0
						for i in width:
							spec[k + i] *= sc
			win += glen

	func apply_ms(c0: _Chan, c1: _Chan) -> void:
		var s0 := c0.spec
		var s1 := c1.spec
		var swb := c0.swb
		var win := 0
		for g in c0.num_groups:
			var glen: int = c0.group_len[g]
			for sfb in c0.max_sfb:
				var idx := g * 64 + sfb
				if ms_used[idx] == 0 or c0.band_type[idx] >= NOISE_HCB or c1.band_type[idx] >= NOISE_HCB:
					if ms_used[idx] and c0.band_type[idx] == NOISE_HCB and c1.band_type[idx] == NOISE_HCB:
						stats.pns_ms_bands += 1
					continue
				stats.ms_bands += 1
				var start: int = swb[sfb]
				var width: int = swb[sfb + 1] - start
				for w in glen:
					var k: int = (win + w) * 128 + start
					for i in width:
						var l: float = s0[k + i]
						var r: float = s1[k + i]
						s0[k + i] = l + r
						s1[k + i] = l - r
			win += glen

	func apply_is(c0: _Chan, c1: _Chan, ms: int) -> void:
		var s0 := c0.spec
		var s1 := c1.spec
		var swb := c1.swb
		var win := 0
		for g in c1.num_groups:
			var glen: int = c1.group_len[g]
			for sfb in c1.max_sfb:
				var idx := g * 64 + sfb
				var cb: int = c1.band_type[idx]
				if cb != INTENSITY_HCB and cb != INTENSITY_HCB2:
					continue
				stats.is_bands += 1
				var sign := 1.0 if cb == INTENSITY_HCB else -1.0
				if ms == 1 and ms_used[idx]:
					sign = -sign
				elif ms == 2:
					stats.is_ms2_bands += 1
				var scale := sign * pow(0.5, 0.25 * c1.sf[idx])
				var start: int = swb[sfb]
				var width: int = swb[sfb + 1] - start
				for w in glen:
					var k: int = (win + w) * 128 + start
					for i in width:
						s1[k + i] = s0[k + i] * scale
			win += glen

	# -- temporal noise shaping (all-pole filter over the spectrum) --
	func apply_tns(c: _Chan) -> void:
		if not c.tns_present:
			return
		var spec := c.spec
		var short := c.window_sequence == EIGHT_SHORT
		var nwin := 8 if short else 1
		var max_order := 7 if short else 12
		var mmm := mini(tns_max_short if short else tns_max_long, c.max_sfb)
		var swb := c.swb
		var a := lpc
		var bb := lpc_b
		for w in nwin:
			var bottom := c.num_swb
			for f in c.tns_nfilt[w]:
				var fi := w * 4 + f
				var top := bottom
				bottom = maxi(0, top - c.tns_len[fi])
				var order := mini(c.tns_order[fi], max_order)
				if order == 0:
					continue
				a[0] = 1.0
				for m in range(1, order + 1):
					var kk: float = c.tns_coef[fi * 32 + m - 1]
					for i in range(1, m):
						bb[i] = a[i] + kk * a[m - i]
					for i in range(1, m):
						a[i] = bb[i]
					a[m] = kk
				var start: int = swb[mini(bottom, mmm)]
				var stop: int = swb[mini(top, mmm)]
				var size := stop - start
				if size <= 0:
					continue
				var inc := 1
				if c.tns_dir[fi]:
					inc = -1
					start = stop - 1
				start += w * 128
				for m in size:
					var y: float = spec[start]
					for i in range(1, mini(m, order) + 1):
						y -= spec[start - i * inc] * a[i]
					spec[start] = y
					start += inc

	# -- IMDCT (see _imdct_tables) of spec[off .. off+m) into self.u[0 .. m) --
	func imdct(spec: PackedFloat64Array, off: int, m: int) -> void:
		var tb: Dictionary = il if m == 1024 else ish
		var pc: PackedFloat64Array = tb.pc
		var ps: PackedFloat64Array = tb.ps
		var qc: PackedFloat64Array = tb.qc
		var qs: PackedFloat64Array = tb.qs
		var twr: PackedFloat64Array = tb.twr
		var twi: PackedFloat64Array = tb.twi
		var rev: PackedInt32Array = tb.rev
		var r := re
		var i_ := im
		var uu := u
		var n := m >> 1
		for k in n:
			var a: float = spec[off + 2 * k]
			var b: float = spec[off + m - 1 - 2 * k]
			var cc: float = pc[k]
			var ss: float = ps[k]
			var j: int = rev[k]
			r[j] = a * cc + b * ss
			i_[j] = b * cc - a * ss
		# radix-2 stage 1 (twiddle 1)
		var k2 := 0
		while k2 < n:
			var ar: float = r[k2]
			var ai: float = i_[k2]
			var br: float = r[k2 + 1]
			var bi: float = i_[k2 + 1]
			r[k2] = ar + br
			i_[k2] = ai + bi
			r[k2 + 1] = ar - br
			i_[k2 + 1] = ai - bi
			k2 += 2
		var size := 4
		while size <= n:
			var half := size >> 1
			var step := n / size
			for j in half:
				var wr: float = twr[j * step]
				var wi: float = twi[j * step]
				var a := j
				while a < n:
					var bidx := a + half
					var br: float = r[bidx]
					var bi: float = i_[bidx]
					var xr := br * wr - bi * wi
					var xi := br * wi + bi * wr
					var ar: float = r[a]
					var ai: float = i_[a]
					r[bidx] = ar - xr
					i_[bidx] = ai - xi
					r[a] = ar + xr
					i_[a] = ai + xi
					a += size
			size <<= 1
		for p in n:
			var vr: float = r[p]
			var vi: float = i_[p]
			var cc: float = qc[p]
			var ss: float = qs[p]
			uu[2 * p] = vr * cc + vi * ss
			uu[m - 1 - 2 * p] = vr * ss - vi * cc

	# -- windowing + overlap-add, then 16-bit output for channel `ci` --
	func filterbank(c: _Chan, ci: int) -> void:
		var seq := c.window_sequence
		var ov := c.overlap
		var oo := o
		var uu := u
		var prev_shape := c.last_shape
		var cur_shape := c.window_shape
		stats.seq[seq] += 1
		if cur_shape == 1:
			stats.kbd_frames += 1
		var prev_right_long := c.last_seq == ONLY_LONG or c.last_seq == LONG_STOP
		var cur_left_long := seq == ONLY_LONG or seq == LONG_START
		if prev_right_long != cur_left_long:
			stats.odd_transitions += 1
		if seq != EIGHT_SHORT:
			imdct(c.spec, 0, 1024)
			# rising half: y[n] = u[n + 512] (n < 512), -u[1535 - n] (512 <= n < 1024)
			if cur_left_long:
				var wl: PackedFloat64Array = win_long[prev_shape]
				for n in 512:
					oo[n] = ov[n] + uu[n + 512] * wl[n]
				for n in range(512, 1024):
					oo[n] = ov[n] - uu[1535 - n] * wl[n]
			else:
				var ws: PackedFloat64Array = win_short[prev_shape]
				for n in 448:
					oo[n] = ov[n]
				for n in range(448, 512):
					oo[n] = ov[n] + uu[n + 512] * ws[n - 448]
				for n in range(512, 576):
					oo[n] = ov[n] - uu[1535 - n] * ws[n - 448]
				for n in range(576, 1024):
					oo[n] = ov[n] - uu[1535 - n]
			# falling half: y[n] = -u[1535 - n] (n < 1536), -u[n - 1536]
			if seq == LONG_START:
				var ws: PackedFloat64Array = win_short[cur_shape]
				for n in range(1024, 1472):
					ov[n - 1024] = -uu[1535 - n]
				for n in range(1472, 1536):
					ov[n - 1024] = -uu[1535 - n] * ws[1599 - n]
				for n in range(1536, 1600):
					ov[n - 1024] = -uu[n - 1536] * ws[1599 - n]
				for n in range(1600, 2048):
					ov[n - 1024] = 0.0
			else:
				var wr: PackedFloat64Array = win_long[cur_shape]
				for n in range(1024, 1536):
					ov[n - 1024] = -uu[1535 - n] * wr[2047 - n]
				for n in range(1536, 2048):
					ov[n - 1024] = -uu[n - 1536] * wr[2047 - n]
		else:
			var zz := z
			zz.fill(0.0)
			var spec := c.spec
			var cur: PackedFloat64Array = win_short[cur_shape]
			for j in 8:
				imdct(spec, j * 128, 128)
				var left: PackedFloat64Array = win_short[prev_shape] if j == 0 else cur
				var b0 := 448 + 128 * j
				# y[n] = u[n + 64] (n < 64), -u[191 - n] (64 <= n < 192), -u[n - 192]
				for n in 64:
					zz[b0 + n] += uu[n + 64] * left[n]
				for n in range(64, 128):
					zz[b0 + n] -= uu[191 - n] * left[n]
				for n in range(128, 192):
					zz[b0 + n] -= uu[191 - n] * cur[255 - n]
				for n in range(192, 256):
					zz[b0 + n] -= uu[n - 192] * cur[255 - n]
			for n in 1024:
				oo[n] = ov[n] + zz[n]
			for n in 1024:
				ov[n] = zz[n + 1024]
		c.last_shape = cur_shape
		c.last_seq = seq
		# float -> s16 (round to nearest, saturate), interleaved
		var dst := out
		var stride := nch * 2
		var at := (out_base * nch + ci) * 2
		for n in 1024:
			var s := roundi(oo[n])
			if s > 32767:
				s = 32767
			elif s < -32768:
				s = -32768
			dst.encode_s16(at, s)
			at += stride
