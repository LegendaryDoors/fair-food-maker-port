# Downloads iOS 6's UIKit art -- the eight images in UIKitArtwork.NAMES: the
# alert box, its buttons, the dimming spotlight and the scroll indicators --
# so every player gets the real iOS 6 pop-ups without owning an iOS 6 device.
#
# Source: Apple's Xcode 4.6.3 disk image as kept by the Internet Archive
# (SOURCE_URL). Nothing of it is in the repo or the builds; it is fetched
# once into the player's own import cache (Importer.gd), like the game itself.
# Only ~6.9 MB of the 1.7 GB image is read, with HTTP Range requests:
#
#   UDIF disk image
#     koly trailer, last 512 bytes: XML plist offset/length at 0xD8 (BE u64),
#       data fork offset at 0x18
#     plist resource-fork/blkx, the "Apple_HFS" partition's mish Data:
#       chunk count at 0xC8, 40-byte entries from 0xCC: type u32, comment
#       u32, sector start u64, sector count u64, comp offset u64, comp length
#       u64 (BE); types 0x80000005 zlib, 1 raw, 0/2 zeros, 0xffffffff end
#   HFS+ volume in that partition
#     volume header at 1024: 'H+', block size (0x28), catalog fork (0x110)
#     catalog B-tree (header node 0: root at 16, node size at 32): the path
#       below one name at a time from the root folder (CNID 2); keys are
#       (parent CNID, name), names compared case-insensitively
#   ARTWORK_PATH, an HFS-compressed file (decmpfs type 4): empty data fork;
#     resource fork = resource header (BE data offset) -> BE u32 length ->
#     block table (LE u32 count, count x {LE u32 offset, LE u32 size}, offsets
#     from the table) -> 64 KiB blocks, each zlib, or stored after a 0xFF byte
#
# Godot's COMPRESSION_DEFLATE is zlib-wrapped (RFC 1950, "78 9c"; raw deflate
# is refused), which is exactly what both UDIF chunks and decmpfs blocks hold,
# so they are inflated as they are.
#
# The rebuilt file must be ARTWORK_SIZE bytes with SHA-256 ARTWORK_SHA256:
# the Shared@2x.artwork of an iPhone 4 running iOS 6.1.3, byte for
# byte. Anything else is refused before UIKitArtwork.extract() looks at it.
#
# Speed. archive.org takes one to three seconds to answer each range request
# (the seek, not the transfer), and the walk above needs ~40 of them one
# after another: ~45 s. PLAN lists the byte ranges that walk reads (recorded
# from it, neighbours merged); they are fetched first,
# CONNECTIONS at a time, so the walk then runs from memory: 5-8 s in all.
# PLAN is only a prefetch: the walk still works everything out from the
# image itself, fetches whatever the plan did not cover, and the hash decides.
#
# Servers. archive.org keeps the item on several storage servers, and any
# one of them may answer 500 or stall for a while. _discover() asks the
# item's metadata (METADATA_URL: "workable_servers" / d1, d2, "dir", and
# "alternate_locations") and where /download/ redirects, both at once; the
# ranges are dealt out over the metadata's working servers, and a range
# that fails (5xx, 404, timeout, broken connection, wrong answer) moves to
# the next server in the list after 0.5, 1 or 2 s, keeping what it has (a
# server that has failed three times in a row is passed over). The fetch
# gives up only when one range has failed on every server three times, or
# after a minute without bytes still arriving. Offline (neither the metadata
# nor /download/ reached: no lookup, no connection, no answer, 5 s each) it
# gives up at once. Whichever servers the bytes came from, the size and
# SHA-256 check is the same.
#
# Blocking; meant for a worker thread. Create it anywhere, use it once.
# fetch() calls progress.call(bytes_so_far, bytes_expected) from the thread it
# runs on. cancel() may be called from any thread, even before fetch().

extends RefCounted

const UIKitArtwork := preload("res://core/import/UIKitArtwork.gd")

const ITEM := "xcode4630916281a"
const FILE := ITEM + ".dmg"
const SOURCE_URL := "https://archive.org/download/" + ITEM + "/" + FILE
const METADATA_URL := "https://archive.org/metadata/" + ITEM
const ARTWORK_PATH := ("Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/"
	+ "Developer/SDKs/iPhoneSimulator6.1.sdk/System/Library/Frameworks/UIKit.framework/"
	+ "Shared@2x.artwork")
const ARTWORK_SIZE := 39067948
const ARTWORK_SHA256 := "3119929f27aa42e5a595daccc877ad80b1dd21346db03f1f03a6c507782fc412"

## [offset, length] in the .dmg (1,723,816,316 bytes), the order they are
## started in: the resource fork (chunks 6124-6145), plist + koly, then the
## volume header and catalog nodes (chunks 0, 281-286, 324-328, 1972,
## 4146-4149, 4164-4168, 5858-5862, 6862, 6883). 6,925,094 bytes.
const PLAN: Array = [
	[1348441627, 5705997], [1723345226, 471090], [306, 1391],
	[62267684, 165033], [63406548, 155629], [346745688, 28782],
	[876186632, 111247], [876610370, 128866], [1289920842, 109008],
	[1523564138, 29127], [1524121794, 18924],
]

const CONNECTIONS := 6                 # in all, spread over the servers
const RETRY_ROUNDS := 3                # a range gives up after failing on every server this often
const SKIP_AFTER := 3                  # failures in a row before a server is passed over
const BACKOFF_MS := [500, 1000, 2000]  # before the next server: 1st, 2nd, 3rd round
const RESOLVE_TIMEOUT_MS := 5000       # looking the name up
const CONNECT_TIMEOUT_MS := 5000       # then TCP + TLS
const ANSWER_TIMEOUT_MS := 5000        # metadata / probe: no answer or no new bytes
const STALL_TIMEOUT_MS := 15000        # a range: no answer / no new bytes: next server
const IDLE_SLEEP_USEC := 2000          # nothing moved this pass (offline: ~no CPU)
const GIVE_UP_MS := 60000              # whole fetch, unless bytes are still arriving
const MAX_REDIRECTS := 5
const MERGE_GAP := 65536               # fetch the gap rather than seek again
const MAX_METADATA := 1 << 20
const USER_AGENT := "FairFoodMakerPort/1 (Godot; one-time fetch of iOS 6 UIKit art)"

const ZLIB := 0x80000005
const RAW := 0x1
const ZEROS_A := 0x0
const ZEROS_B := 0x2

## Where the file is: archive.org's /download/ address (redirects to a
## storage server) and the item's metadata (names all of them). Tests point
## both at a dead address.
var url := SOURCE_URL
var metadata_url := METADATA_URL
## Prefetch PLAN first (off = let the walk fetch everything on demand).
var use_plan := true
## Print each request and each stage's time.
var verbose := false
## Tests: the first this many servers answer every request with HTTP 500.
var test_fail_servers := 0
## Tests: read no faster than this (bytes/s; 0 = as fast as it comes).
var test_bytes_per_sec := 0
## Tests: start this much later, and hold the metadata / probe answers
## this long (a slow first contact: the import may end before it is over).
var test_start_delay_ms := 0
var test_hold_answers_ms := 0
## Read from other threads (Importer decides from them whether to wait):
## true once every byte is in (what remains is checking it, well under a
## second);
var received_all := false
## ticks (ms) of the last sign the network works: a name looked up, a
## connection made, any HTTP answer or bytes (0 = none yet);
var progress_ms := 0
## ticks (ms) of the last attempt that failed short of an HTTP answer.
var net_fail_ms := 0

var _cancel := false
var _progress := Callable()
var _t0 := 0
var _error := ""

# HTTP
var _cands: Array = []                 # servers, best first: {host, port, tls, path}
var _primary := 1                      # the first this many share the ranges out
var _spread := 0
var _failing := {}                     # test_fail_servers' hosts
var _meta_text := ""
var _probe_target := {}
var _conns: Array = []                 # of _Conn
var _ranges: Array = []                # [[dmg offset, PackedByteArray]]
var _dmg_size := -1                    # from the metadata / Content-Range
var _bytes := 0
var _last_byte_ms := 0
var _requests := 0
var _failovers := 0
var _last_why := ""
var _streak := {}                      # host -> failures in a row (0 after a success)
var _failed_on := {}                   # host -> failures in all
var _expected := 0
var _misses := 0                       # ranges the walk had to fetch itself

# UDIF / HFS+
var _base := 0                         # koly data fork offset + mish data offset
var _cs := PackedInt64Array()          # chunk: first sector (partition-relative)
var _cn := PackedInt64Array()          # chunk: sector count
var _ct := PackedInt64Array()          # chunk: type
var _co := PackedInt64Array()          # chunk: compressed offset
var _cl := PackedInt64Array()          # chunk: compressed length
var _chunks := {}                      # chunk index -> inflated bytes
var _bs := 4096
var _cat_ext: Array = []               # [[start block, block count]]
var _ns := 8192
var _root := 0
var _binary_names := false             # HFSX with binary compare
var _nodes := {}


class _Conn:
	var http := HTTPClient.new()
	var host := ""
	var port := 0
	var tls := true
	var since := 0                     # current connect stage began (ms)
	var looked_up := false             # this attempt went through RESOLVING
	var connecting := false            # ... and has reached CONNECTING
	var job: Dictionary = {}
	var buf := PackedByteArray()      # the job's bytes so far (kept across retries)
	var phase := 0
	var t := 0                         # last sign of life (ms)
	var wake := 0                      # retry not before (ms)
	var reused := false

	func _init() -> void:
		http.read_chunk_size = 262144


const PH_IDLE := 0
const PH_WAIT := 1
const PH_CONNECT := 2
const PH_REQUEST := 3
const PH_BODY := 4

const STEP_IDLE := 0
const STEP_MOVED := 1
const STEP_FATAL := 2


func cancel() -> void:
	_cancel = true


## Bytes fetch() expects to download (for a progress bar).
func expected_bytes() -> int:
	if not use_plan:
		return 7000000
	var n := 0
	for r: Array in PLAN:
		n += int(r[1])
	return n


## -> {ok, error, cancelled, images: {name: Image}, bytes_downloaded,
##     requests, failovers (attempts moved to another server), servers (in
##     the order tried), failed_on {host: failures}, msec, misses, sha256}
func fetch(progress: Callable = Callable()) -> Dictionary:
	_progress = progress
	_t0 = Time.get_ticks_msec()
	_error = ""
	_bytes = 0
	_requests = 0
	_failovers = 0
	_streak = {}
	_failed_on = {}
	_misses = 0
	_dmg_size = -1
	_last_byte_ms = _t0
	_cs = PackedInt64Array()
	_cn = PackedInt64Array()
	_ct = PackedInt64Array()
	_co = PackedInt64Array()
	_cl = PackedInt64Array()
	_expected = expected_bytes()
	var out := {"ok": false, "error": "", "cancelled": false, "images": {},
		"bytes_downloaded": 0, "requests": 0, "failovers": 0, "servers": [], "failed_on": {},
		"msec": 0, "misses": 0, "sha256": ""}
	while Time.get_ticks_msec() - _t0 < test_start_delay_ms and not _cancel:
		OS.delay_msec(10)
	var art := _artwork()
	received_all = not art.is_empty()
	_trace("walk done, %d bytes" % art.size())
	_close_all()
	_ranges.clear()
	_chunks.clear()
	_nodes.clear()
	out.bytes_downloaded = _bytes
	out.requests = _requests
	out.failovers = _failovers
	out.failed_on = _failed_on.duplicate()
	out.misses = _misses
	for c: Dictionary in _cands:
		out.servers.append(c.host)
	out.msec = Time.get_ticks_msec() - _t0
	if _cancel:
		out.cancelled = true
		out.error = "cancelled"
		return out
	if art.is_empty():
		out.error = _error if _error != "" else "the download failed"
		return out
	if art.size() != ARTWORK_SIZE:
		out.error = "the file from the Internet Archive is %d bytes, not %d" % [art.size(), ARTWORK_SIZE]
		return out
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(art)
	out.sha256 = h.finish().hex_encode()
	_trace("sha256")
	if out.sha256 != ARTWORK_SHA256:
		out.error = "the file from the Internet Archive is not the expected one (SHA-256 %s)" % out.sha256
		return out
	var ex := UIKitArtwork.extract(art)
	if not ex.ok:
		out.error = "the artwork file could not be read: %s" % ex.error
		return out
	out.images = ex.images
	_trace("8 images cut out")
	out.ok = true
	out.msec = Time.get_ticks_msec() - _t0
	return out


# -- the walk -------------------------------------------------------------------

## The rebuilt Shared@2x.artwork, or empty with _error set.
func _artwork() -> PackedByteArray:
	var none := PackedByteArray()
	if not _discover():
		return none
	if use_plan and not _get_ranges(PLAN, true):
		return none
	_trace("plan fetched")

	# UDIF trailer and its plist.
	var koly: PackedByteArray
	if _dmg_size < 0:
		if not _get_ranges([[-1, 512]], false):
			return none
		_misses += 1
	koly = _read(_dmg_size - 512, 512)
	if koly.is_empty():
		return none
	if koly.size() != 512 or koly.slice(0, 4).get_string_from_ascii() != "koly":
		return _fail("the download is not an Apple disk image (no koly trailer)")
	var xml := _read(_be64(koly, 0xD8), _be64(koly, 0xE0))
	if xml.is_empty():
		return none
	var mish := _hfs_mish(xml)
	if mish.size() < 0xCC or mish.slice(0, 4).get_string_from_ascii() != "mish":
		return _fail(_error if _error != "" else "the disk image has no HFS+ partition table")
	_base = _be64(koly, 0x18) + _be64(mish, 0x18)
	var n := _be32(mish, 0xC8)
	if 0xCC + n * 40 > mish.size():
		return _fail("the disk image's chunk table is truncated")
	for i in n:
		var e := 0xCC + i * 40
		var t := _be32(mish, e)
		var count := _be64(mish, e + 16)
		if t == 0xFFFFFFFF or t == 0x7FFFFFFE or count == 0:
			continue
		_ct.append(t)
		_cs.append(_be64(mish, e + 8))
		_cn.append(count)
		_co.append(_be64(mish, e + 24))
		_cl.append(_be64(mish, e + 32))
	if _cs.is_empty():
		return _fail("the disk image's chunk table is empty")

	# HFS+ volume header and the catalog B-tree's header node.
	var vh := _part_read(1024, 512)
	if vh.size() != 512:
		return none
	var sig := vh.slice(0, 2).get_string_from_ascii()
	if sig != "H+" and sig != "HX":
		return _fail("the disk image's partition is not HFS+")
	_bs = _be32(vh, 0x28)
	var cat_size := _be64(vh, 0x110)
	_cat_ext = _extents(vh, 0x110 + 16)
	if not _covers(_cat_ext, cat_size):
		return _fail("the volume's catalog is fragmented beyond 8 extents (not supported)")
	var hdr := _fork_read(_cat_ext, 0, 512)
	if hdr.size() != 512:
		return none
	_root = _be32(hdr, 14 + 2)
	_ns = _be16(hdr, 14 + 18)
	_binary_names = sig == "HX" and hdr[14 + 37] == 0xBC
	if _ns < 512 or _root == 0:
		return _fail("the volume's catalog header is unreadable")

	# Folder by folder to the file.
	var pid := 2
	var parts := ARTWORK_PATH.split("/")
	for i in parts.size():
		var rec := _lookup(pid, parts[i])
		if rec.is_empty():
			return _fail(_error if _error != "" else "%s is not in Xcode 4.6.3's disk image" % parts[i])
		var nd: PackedByteArray = rec[0]
		var dp: int = rec[1]
		var rtype := _be16(nd, dp)
		if i < parts.size() - 1:
			if rtype != 1:
				return _fail("%s is not a folder in the disk image" % parts[i])
			pid = _be32(nd, dp + 8)
			continue
		if rtype != 2:
			return _fail("%s is not a file in the disk image" % parts[i])
		var rsize := _be64(nd, dp + 168)
		var rext := _extents(nd, dp + 168 + 16)
		if rsize < 16 or not _covers(rext, rsize):
			return _fail("Shared@2x.artwork's resource fork is missing or fragmented")
		# The whole fork at once, in parallel, before it is read.
		var want: Array = []
		var left := rsize
		for ex: Array in rext:
			var len := mini(left, int(ex[1]) * _bs)
			want.append_array(_chunk_ranges(int(ex[0]) * _bs, len))
			left -= len
		if not _get_ranges(_merge(want), false):
			return none
		var rsrc := _fork_read(rext, 0, rsize)
		if rsrc.size() != rsize:
			return none
		_trace("catalog walked, resource fork read")
		_ranges.clear()
		_chunks.clear()
		return _decmpfs(rsrc)
	return none


## decmpfs type 4: the file's bytes from its resource fork.
func _decmpfs(rsrc: PackedByteArray) -> PackedByteArray:
	var doff := _be32(rsrc, 0)
	if doff + 8 > rsrc.size():
		return _fail("Shared@2x.artwork's resource fork has no data")
	var res := rsrc.slice(doff + 4, doff + 4 + _be32(rsrc, doff))
	if res.size() < 4:
		return _fail("Shared@2x.artwork's compressed data is truncated")
	var count := res.decode_u32(0)
	if 4 + count * 8 > res.size():
		return _fail("Shared@2x.artwork's block table is truncated")
	var out := PackedByteArray()
	for k in count:
		if _cancel:
			return PackedByteArray()
		var o := res.decode_u32(4 + 8 * k)
		var l := res.decode_u32(8 + 8 * k)
		if l == 0 or o + l > res.size():
			return _fail("Shared@2x.artwork's block %d is out of range" % k)
		var blk := res.slice(o, o + l)
		var data: PackedByteArray
		if blk[0] == 0xFF:
			data = blk.slice(1)
		else:
			if not _is_zlib(blk):
				return _fail("Shared@2x.artwork's block %d is not zlib data" % k)
			data = blk.decompress(65536, FileAccess.COMPRESSION_DEFLATE)
			if data.is_empty():
				return _fail("Shared@2x.artwork's block %d did not inflate" % k)
		if k < count - 1 and data.size() != 65536:
			return _fail("Shared@2x.artwork's block %d is %d bytes, not 64 KiB" % [k, data.size()])
		out.append_array(data)
	return out


## The base64 mish table of the plist's Apple_HFS partition.
func _hfs_mish(xml: PackedByteArray) -> PackedByteArray:
	var text := xml.get_string_from_utf8()
	var at := text.find("<key>blkx</key>")
	if at < 0:
		_error = "the disk image's partition list is missing"
		return PackedByteArray()
	var stop := text.find("</array>", at)
	var pos := at
	while true:
		var ds := text.find("<dict>", pos)
		if ds < 0 or (stop >= 0 and ds > stop):
			break
		var de := text.find("</dict>", ds)
		if de < 0:
			break
		var entry := text.substr(ds, de - ds)
		if _plist_value(entry, "Name", "string").contains("Apple_HFS"):
			var b64 := _plist_value(entry, "Data", "data")
			for ws: String in ["\n", "\r", "\t", " "]:
				b64 = b64.replace(ws, "")
			return Marshalls.base64_to_raw(b64)
		pos = de
	_error = "the disk image has no HFS+ partition"
	return PackedByteArray()


static func _plist_value(entry: String, key: String, tag: String) -> String:
	var k := entry.find("<key>%s</key>" % key)
	if k < 0:
		return ""
	var a := entry.find("<%s>" % tag, k)
	var b := entry.find("</%s>" % tag, a)
	if a < 0 or b < 0:
		return ""
	return entry.substr(a + tag.length() + 2, b - a - tag.length() - 2)


## Catalog lookup of (parent CNID, name) -> [leaf node bytes, record data
## offset], or [] when absent.
func _lookup(pid: int, name: String) -> Array:
	var i := _root
	for depth in 16:
		var nd := _node(i)
		if nd.is_empty():
			return []
		var kind := nd[8] - 256 if nd[8] >= 128 else nd[8]
		var offs := _record_offsets(nd)
		if kind == 0:                                   # index node
			var child := -1
			for o in offs:
				var key := _key(nd, o)
				if _cmp(key[0], key[1], pid, name) <= 0:
					child = _be32(nd, key[2])
				else:
					break
			if child < 0:
				return []
			i = child
		elif kind == -1:                                # leaf: this one and the next two
			for hop in 3:
				for o in offs:
					var key := _key(nd, o)
					if key[0] == pid and key[1] == name:
						return [nd, key[2]]
				var flink := _be32(nd, 0)
				if flink == 0:
					break
				nd = _node(flink)
				if nd.is_empty():
					return []
				offs = _record_offsets(nd)
			return []
		else:
			_error = "the volume's catalog is damaged (node %d)" % i
			return []
	return []


func _record_offsets(nd: PackedByteArray) -> PackedInt64Array:
	var offs := PackedInt64Array()
	for k in _be16(nd, 10):
		offs.append(_be16(nd, _ns - 2 - 2 * k))
	return offs


## [parent CNID, name, record data offset]
func _key(nd: PackedByteArray, o: int) -> Array:
	var kl := _be16(nd, o)
	var nl := _be16(nd, o + 6)
	var s := ""
	for c in nl:
		s += String.chr(_be16(nd, o + 8 + 2 * c))
	return [_be32(nd, o + 2), s, o + 2 + kl]


func _cmp(p1: int, n1: String, p2: int, n2: String) -> int:
	if p1 != p2:
		return -1 if p1 < p2 else 1
	var a := n1 if _binary_names else n1.to_lower()
	var b := n2 if _binary_names else n2.to_lower()
	if a == b:
		return 0
	return -1 if a < b else 1


func _node(i: int) -> PackedByteArray:
	if not _nodes.has(i):
		var nd := _fork_read(_cat_ext, i * _ns, _ns)
		if nd.size() != _ns:
			return PackedByteArray()
		_nodes[i] = nd
	return _nodes[i]


func _extents(d: PackedByteArray, at: int) -> Array:
	var out: Array = []
	for k in 8:
		var c := _be32(d, at + 8 * k + 4)
		if c > 0:
			out.append([_be32(d, at + 8 * k), c])
	return out


func _covers(exts: Array, size: int) -> bool:
	var blocks := 0
	for e: Array in exts:
		blocks += int(e[1])
	return blocks * _bs >= size


## Bytes [off, off+len) of a fork, through its extents.
func _fork_read(exts: Array, off: int, len: int) -> PackedByteArray:
	var out := PackedByteArray()
	for e: Array in exts:
		var elen := int(e[1]) * _bs
		if off < elen:
			var take := mini(len, elen - off)
			var got := _part_read(int(e[0]) * _bs + off, take)
			if got.size() != take:
				return PackedByteArray()
			out.append_array(got)
			len -= take
			off = 0
			if len == 0:
				break
		else:
			off -= elen
	return out if len == 0 else PackedByteArray()


## Bytes [off, off+len) of the HFS+ partition.
func _part_read(off: int, len: int) -> PackedByteArray:
	var out := PackedByteArray()
	while len > 0:
		@warning_ignore("integer_division")
		var ci := _cs.bsearch(off / 512, false) - 1
		if ci < 0:
			return _fail("read before the start of the partition")
		var d := _chunk(ci)
		if d.is_empty():
			return PackedByteArray()
		var o := off - _cs[ci] * 512
		if o >= d.size():
			return _fail("read beyond the end of the partition")
		var take := mini(len, d.size() - o)
		out.append_array(d.slice(o, o + take))
		off += take
		len -= take
	return out


## [[dmg offset, length]] of the stored chunks behind partition bytes
## [off, off+len) that are not inflated yet.
func _chunk_ranges(off: int, len: int) -> Array:
	var out: Array = []
	if len <= 0:
		return out
	@warning_ignore("integer_division")
	var first := _cs.bsearch(off / 512, false) - 1
	@warning_ignore("integer_division")
	var last := _cs.bsearch((off + len - 1) / 512, false) - 1
	for ci in range(maxi(first, 0), last + 1):
		if not _chunks.has(ci) and (_ct[ci] == ZLIB or _ct[ci] == RAW):
			out.append([_base + _co[ci], _cl[ci]])
	return out


## One stored chunk, inflated.
func _chunk(ci: int) -> PackedByteArray:
	if _chunks.has(ci):
		return _chunks[ci]
	var n := _cn[ci] * 512
	var d := PackedByteArray()
	match _ct[ci]:
		ZLIB:
			var src := _read(_base + _co[ci], _cl[ci])
			if src.is_empty():
				return src
			if not _is_zlib(src):
				return _fail("disk image chunk %d is not zlib data" % ci)
			d = src.decompress(n, FileAccess.COMPRESSION_DEFLATE)
			if d.size() != n:
				return _fail("disk image chunk %d did not inflate to %d bytes" % [ci, n])
		RAW:
			d = _read(_base + _co[ci], _cl[ci])
			if d.is_empty():
				return d
		ZEROS_A, ZEROS_B:
			d.resize(n)
		_:
			return _fail("disk image chunk %d uses compression 0x%x (not supported)" % [ci, _ct[ci]])
	_chunks[ci] = d
	return d


static func _is_zlib(b: PackedByteArray) -> bool:
	return b.size() >= 2 and (b[0] & 0x0F) == 8 and ((b[0] << 8) | b[1]) % 31 == 0


func _fail(msg: String) -> PackedByteArray:
	if _error == "":
		_error = msg
	return PackedByteArray()


# -- where the file is ----------------------------------------------------------

## The servers to read from, best first. archive.org's metadata for the item
## names its storage servers ("workable_servers", else d1/d2) and the copies'
## folder ("dir"), plus alternate copies ("alternate_locations"); /download/
## redirects to one of them (asked once here; its target is kept); /download/
## itself comes last. Both questions go out at once. If the metadata cannot
## be had, /download/ alone is used. Ranges are dealt out over the metadata's
## working servers; a range that fails moves on down the list (_failover).
func _discover() -> bool:
	_cands = []
	_primary = 1
	_meta_text = ""
	_probe_target = {}
	var src := _parse_url(url)
	var meta := _parse_url(metadata_url) if metadata_url != "" else {}
	var jobs: Array = []
	if not meta.is_empty():
		jobs.append(_job("get", meta, -1, 0, 0, 2))
	if not src.is_empty():
		jobs.append(_job("probe", src, -1, 0, 1, 2))
	# Whichever answers first, the other gets a little longer, not its whole
	# timeout: metadata alone is enough (it lists the redirect's server too),
	# and so is the redirect.
	var meta_job: Dictionary = jobs[0] if not meta.is_empty() else {}
	var probe_job: Dictionary = jobs[-1] if not src.is_empty() else {}
	var settled := [0, 0]
	var enough := func() -> bool:
		var now := Time.get_ticks_msec()
		if settled[0] == 0 and _meta_text != "":
			settled[0] = now
		if settled[1] == 0 and (not _probe_target.is_empty() or _cached(0, 1).size() == 1):
			settled[1] = now
		return (settled[0] > 0 and (probe_job.is_empty() or now - settled[0] > 1000)) \
			or (settled[1] > 0 and (meta_job.is_empty() or now - settled[1] > 2000))
	if not _run(jobs, enough):
		return false
	# Neither question reached archive.org at all (no name lookup, no
	# connection, no answer): offline. Say so now rather than trying every
	# server in turn.
	var reached := _meta_text != "" or not _probe_target.is_empty() or _cached(0, 1).size() == 1
	var net_only := not jobs.is_empty()
	for j: Dictionary in jobs:
		net_only = net_only and int(j.fails) > 0 and int(j.net_fails) == int(j.fails)
	if not reached and net_only:
		return _fail_bool("couldn't reach archive.org (%s)" % _last_why)
	var m: Variant = JSON.parse_string(_meta_text) if _meta_text != "" else null
	if m is Dictionary:
		var dir := str(m.get("dir", ""))
		var servers: Variant = m.get("workable_servers", [])
		if not (servers is Array) or (servers as Array).is_empty():
			servers = [m.get("d1", ""), m.get("d2", "")]
		for host: Variant in servers:
			if str(host) != "" and dir != "":
				_add_cand(_parse_url("https://%s%s/%s" % [host, dir, FILE]))
		_primary = maxi(_cands.size(), 1)
		var alt: Variant = m.get("alternate_locations", {})
		if alt is Dictionary:
			var where: Variant = alt.get("workable", alt.get("servers", []))
			for a: Variant in (where if where is Array else []):
				if a is Dictionary and str(a.get("server", "")) != "":
					_add_cand(_parse_url("https://%s%s/%s" % [a.server, a.get("dir", ""), FILE]))
		for f: Variant in m.get("files", []):
			if f is Dictionary and f.get("name") == FILE and str(f.get("size", "")).is_valid_int():
				_dmg_size = str(f.size).to_int()
	_add_cand(_probe_target)
	_add_cand(src)
	if _cands.is_empty():
		return _fail_bool("bad download address: " + url)
	for i in mini(test_fail_servers, _cands.size()):
		_failing[_cands[i].host] = true
	var names := PackedStringArray()
	for c: Dictionary in _cands:
		names.append(c.host)
	_trace("servers: %s (ranges dealt over the first %d)%s" % [", ".join(names), _primary,
		"; metadata unavailable" if not (m is Dictionary) else ""])
	return true


## Server i, or the next after it (among the first `among`) that has not
## just failed SKIP_AFTER times in a row; i itself when all of them have.
func _usable(i: int, among: int) -> int:
	for k in among:
		var c := (i + k) % among
		if int(_streak.get(_cands[c].host, 0)) < SKIP_AFTER:
			return c
	return i


func _add_cand(t: Dictionary) -> void:
	if t.is_empty():
		return
	for c: Dictionary in _cands:
		if c.host == t.host and c.path == t.path and c.port == t.port:
			return
	_cands.append(t)


## {host, port, tls, path}, or {} for an address it cannot use.
static func _parse_url(u: String) -> Dictionary:
	var m := RegEx.create_from_string("^(https?)://([^/:]+)(?::(\\d+))?(/.*)?$").search(u)
	if m == null:
		return {}
	var tls := m.get_string(1) == "https"
	return {"host": m.get_string(2), "tls": tls,
		"port": m.get_string(3).to_int() if m.get_string(3) != "" else (443 if tls else 80),
		"path": m.get_string(4) if m.get_string(4) != "" else "/"}


# -- byte ranges over HTTP ------------------------------------------------------

## dmg bytes [start, start+len) from what has been fetched; fetches them
## first when not (a miss the plan did not cover).
func _read(start: int, len: int) -> PackedByteArray:
	var got := _cached(start, len)
	if got.size() == len:
		return got
	_misses += 1
	if not _get_ranges([[start, len]], false):
		return PackedByteArray()
	got = _cached(start, len)
	return got if got.size() == len else _fail("the server sent the wrong part of the file")


func _cached(start: int, len: int) -> PackedByteArray:
	for r: Array in _ranges:
		var s: int = r[0]
		var b: PackedByteArray = r[1]
		if start >= s and start + len <= s + b.size():
			return b.slice(start - s, start - s + len)
	return PackedByteArray()


## Sorted, with ranges closer than MERGE_GAP joined.
static func _merge(list: Array) -> Array:
	var sorted := list.duplicate()
	sorted.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out: Array = []
	for r: Array in sorted:
		if not out.is_empty() and int(r[0]) <= int(out[-1][0]) + int(out[-1][1]) + MERGE_GAP:
			var end := maxi(int(out[-1][0]) + int(out[-1][1]), int(r[0]) + int(r[1]))
			out[-1] = [out[-1][0], end - int(out[-1][0])]
		else:
			out.append([r[0], r[1]])
	return out


## Fetches every [start, length] not held yet (start -1 = the last `length`
## bytes). optional: a range beyond the file (416) is skipped instead of
## failing. false (with _error) on failure or cancel.
func _get_ranges(list: Array, optional: bool) -> bool:
	var jobs: Array = []
	for r: Array in list:
		if int(r[0]) >= 0 and _cached(int(r[0]), int(r[1])).size() == int(r[1]):
			continue
		var cand := _usable(_spread % _primary, _primary)
		_spread += 1
		var j := _job("range", _cands[cand], cand, int(r[0]), int(r[1]),
			RETRY_ROUNDS * _cands.size())
		j.optional = optional
		jobs.append(j)
	return _run(jobs)


## kind: "range" (a part of the file, from server `cand` on), "probe" (one
## byte from /download/: only its redirect is kept) or "get" (the metadata).
## Probe and get are soft: when they fail the fetch goes on without them.
func _job(kind: String, target: Dictionary, cand: int, start: int, len: int, max_fails: int) -> Dictionary:
	return {"kind": kind, "target": target, "cand": cand, "start": start, "len": len,
		"fails": 0, "net_fails": 0, "max_fails": max_fails, "soft": kind != "range", "redirects": 0,
		"optional": false, "stale_retry": false}


## Runs the jobs, CONNECTIONS at a time. false (with _error) on failure,
## cancel or GIVE_UP_MS. enough (optional): true = stop now, dropping what
## is still running.
func _run(jobs: Array, enough: Callable = Callable()) -> bool:
	var queue := jobs.duplicate()
	while _conns.size() < mini(CONNECTIONS, queue.size()):
		_conns.append(_Conn.new())
	while true:
		if _cancel:
			_close_all()
			return false
		var now := Time.get_ticks_msec()
		if now - _t0 > GIVE_UP_MS and now - _last_byte_ms > 5000:
			_close_all()
			return _fail_bool("gave up after a minute%s" % [
				" (last problem: %s)" % _last_why if _last_why != "" else ""])
		var busy := false
		var moved := false
		for c: _Conn in _conns:
			if c.job.is_empty():
				if queue.is_empty():
					continue
				c.job = queue.pop_front()
				c.buf = PackedByteArray()
				c.phase = PH_IDLE
			busy = true
			var r := _step(c)
			if r == STEP_FATAL:
				_close_all()
				return false
			if r == STEP_MOVED:
				moved = true
		if not busy:
			return true
		if enough.is_valid() and enough.call():
			_close_all()
			return true
		if not moved:
			OS.delay_usec(IDLE_SLEEP_USEC)
	return false


func _close_all() -> void:
	for c: _Conn in _conns:
		c.http.close()
		c.job = {}
		c.phase = PH_IDLE
	_conns.clear()


func _step(c: _Conn) -> int:
	var now := Time.get_ticks_msec()
	match c.phase:
		PH_IDLE:
			return _begin(c)
		PH_WAIT:
			return _begin(c) if now >= c.wake else STEP_IDLE
		PH_CONNECT:
			c.http.poll()
			var st := c.http.get_status()
			if st == HTTPClient.STATUS_CONNECTED:
				progress_ms = now                          # a connection made
				return _send(c)
			if st == HTTPClient.STATUS_RESOLVING:
				c.looked_up = true
				if now - c.since > RESOLVE_TIMEOUT_MS:
					return _failover(c, "couldn't look up %s within %d s" % [c.host, RESOLVE_TIMEOUT_MS / 1000], true)
				return STEP_IDLE
			if st == HTTPClient.STATUS_CONNECTING:
				if not c.connecting:
					c.connecting = true
					c.since = now                          # resolved: the connect clock starts
					if c.looked_up:
						progress_ms = now                  # a name looked up (not an IP given)
				if now - c.since > CONNECT_TIMEOUT_MS:
					return _failover(c, "couldn't connect to %s within %d s" % [c.host, CONNECT_TIMEOUT_MS / 1000], true)
				return STEP_IDLE
			return _failover(c, _status_text(st, c.host), true)
		PH_REQUEST:
			c.http.poll()
			var st := c.http.get_status()
			if st == HTTPClient.STATUS_REQUESTING:
				if now - c.t > (ANSWER_TIMEOUT_MS if c.job.soft else STALL_TIMEOUT_MS):
					return _failover(c, "%s did not answer" % c.host, true)
				return STEP_IDLE
			if st != HTTPClient.STATUS_BODY and st != HTTPClient.STATUS_CONNECTED:
				return _failover(c, _status_text(st, c.host), true)
			if c.job.soft and now - c.t < test_hold_answers_ms:
				return STEP_IDLE                           # test_hold_answers_ms
			return _on_response(c, st)
		PH_BODY:
			c.http.poll()
			var st := c.http.get_status()
			var j := c.job
			if st == HTTPClient.STATUS_BODY:
				if test_bytes_per_sec > 0 and _bytes * 1000 > (now - _t0) * test_bytes_per_sec:
					c.t = now                              # held back on purpose, not stalled
					return STEP_IDLE
				var chunk := c.http.read_response_body_chunk()
				if chunk.is_empty():
					if now - c.t > (ANSWER_TIMEOUT_MS if j.soft else STALL_TIMEOUT_MS):
						return _failover(c, "the download from %s stalled" % c.host, true)
					return STEP_IDLE
				c.buf.append_array(chunk)
				c.t = now
				progress_ms = now
				if j.kind == "get":
					if c.buf.size() > MAX_METADATA:
						return _failover(c, "%s sent too much" % c.host)
					return STEP_MOVED
				_bytes += chunk.size()
				_last_byte_ms = now
				if _progress.is_valid():
					_progress.call(_bytes, maxi(_expected, _bytes))
				if c.buf.size() > int(j.len):
					return _failover(c, "%s sent more than was asked for" % c.host)
				return STEP_MOVED
			if j.kind == "get" and (st == HTTPClient.STATUS_CONNECTED or st == HTTPClient.STATUS_DISCONNECTED):
				_meta_text = c.buf.get_string_from_utf8()
				_trace("metadata: %d bytes from %s" % [c.buf.size(), c.host])
				return _done(c)
			if j.kind != "get" and c.buf.size() == int(j.len):
				_streak[c.host] = 0
				_trace("got %d bytes at %d from %s (%d ms)" % [j.len, j.start, c.host,
					now - int(j.get("t0", now))])
				_ranges.append([int(j.start), c.buf])
				return _done(c)
			return _failover(c, "the download from %s was cut short" % c.host)
	return STEP_IDLE


func _done(c: _Conn) -> int:
	c.buf = PackedByteArray()
	c.job = {}
	c.phase = PH_IDLE
	return STEP_MOVED


func _begin(c: _Conn) -> int:
	var t: Dictionary = c.job.target
	c.http.poll()
	if c.http.get_status() == HTTPClient.STATUS_CONNECTED and c.host == t.host \
			and c.port == t.port and c.tls == t.tls:
		c.reused = true
		return _send(c)
	c.http.close()
	c.reused = false
	c.host = t.host
	c.port = t.port
	c.tls = t.tls
	if test_bytes_per_sec > 0:
		c.http.read_chunk_size = 16384                # an even trickle, not bursts
	var e := c.http.connect_to_host(c.host, c.port, TLSOptions.client() if c.tls else null)
	if e != OK:
		return _failover(c, "couldn't start a connection to %s (error %d)" % [c.host, e], true)
	c.phase = PH_CONNECT
	c.t = Time.get_ticks_msec()
	c.since = c.t
	c.looked_up = false
	c.connecting = false
	return STEP_MOVED


func _send(c: _Conn) -> int:
	var j := c.job
	var headers := PackedStringArray(["User-Agent: " + USER_AGENT, "Accept: */*"])
	if j.kind == "get" or int(j.start) < 0:
		c.buf = PackedByteArray()                     # asked for whole
	var have := c.buf.size()
	if j.kind != "get":
		headers.append("Range: " + ("bytes=-%d" % j.len if int(j.start) < 0 else
			"bytes=%d-%d" % [int(j.start) + have, int(j.start) + int(j.len) - 1]))
	var e := c.http.request(HTTPClient.METHOD_GET, j.target.path, headers)
	_requests += 1
	_trace("GET %s %s%s" % [c.host, headers[-1].trim_prefix("Range: ") if j.kind != "get" else j.target.path,
		" (kept-alive)" if c.reused else ""])
	if not j.has("t0"):
		j.t0 = Time.get_ticks_msec()
	if e != OK:
		return _failover(c, "couldn't send a request to %s (error %d)" % [c.host, e], true)
	c.phase = PH_REQUEST
	c.t = Time.get_ticks_msec()
	return STEP_MOVED


func _on_response(c: _Conn, st: int) -> int:
	var j := c.job
	progress_ms = Time.get_ticks_msec()                # an HTTP answer, whatever it says
	var code := c.http.get_response_code()
	if _failing.has(c.host):
		code = 500                                     # test_fail_servers
	var hdr := {}
	for line in c.http.get_response_headers():
		var colon := line.find(":")
		if colon > 0:
			hdr[line.substr(0, colon).strip_edges().to_lower()] = line.substr(colon + 1).strip_edges()
	if code in [301, 302, 303, 307, 308]:
		c.http.close()
		var loc: String = hdr.get("location", "")
		if loc.begins_with("/"):
			loc = "%s://%s:%d%s" % ["https" if c.tls else "http", c.host, c.port, loc]
		var to := _parse_url(loc)
		if to.is_empty() or int(j.redirects) >= MAX_REDIRECTS:
			return _failover(c, "%s redirected to an unusable address" % c.host)
		if j.kind == "probe":
			_probe_target = to                         # where /download/ sends people
			return _done(c)
		j.redirects = int(j.redirects) + 1
		j.target = to
		c.phase = PH_IDLE
		return STEP_MOVED
	if j.kind == "get":
		if code == 200 and st == HTTPClient.STATUS_BODY:
			c.phase = PH_BODY
			c.t = Time.get_ticks_msec()
			return STEP_MOVED
		c.http.close()
		return _failover(c, "%s answered HTTP %d" % [c.host, code])
	if code == 206:
		var m := RegEx.create_from_string("bytes\\s+(\\d+)-(\\d+)/(\\d+)").search(hdr.get("content-range", ""))
		if m == null:
			return _failover(c, "%s sent a part without saying which" % c.host)
		var a := m.get_string(1).to_int()
		var b := m.get_string(2).to_int()
		var total := m.get_string(3).to_int()
		if _dmg_size >= 0 and total != _dmg_size:
			return _failover(c, "%s has a different file (%d bytes, not %d)" % [c.host, total, _dmg_size])
		_dmg_size = total
		if int(j.start) < 0:
			j.start = a
		var have := c.buf.size()
		if a != int(j.start) + have or b != int(j.start) + int(j.len) - 1:
			return _failover(c, "%s sent bytes %d-%d instead of the part asked for" % [c.host, a, b])
		if st != HTTPClient.STATUS_BODY:
			return _failover(c, "%s sent an empty part" % c.host)
		c.phase = PH_BODY
		c.t = Time.get_ticks_msec()
		return STEP_MOVED
	c.http.close()
	if code == 416 and j.optional:
		return _done(c)                                # beyond this file: not needed
	if code == 200:
		return _failover(c, "%s sent the whole file instead of a part" % c.host)
	return _failover(c, "%s answered HTTP %d" % [c.host, code])


## This attempt failed (HTTP error, timeout, broken connection, wrong
## answer): the range moves to the next server after BACKOFF_MS, keeping the
## bytes it has (every server holds the same file: same size, and the hash
## decides). Only after failing RETRY_ROUNDS times on every server does the
## fetch give up.
## net: it never got as far as an HTTP answer (lookup, connect, broken or
## silent connection) -- what being offline looks like.
func _failover(c: _Conn, why: String, net: bool = false) -> int:
	c.http.close()
	var j := c.job
	_trace("failed: " + why)
	_last_why = why
	# A kept-alive connection the server had already closed: once, at once.
	if c.reused and c.phase == PH_REQUEST and not j.stale_retry:
		j.stale_retry = true
		c.reused = false
		c.phase = PH_IDLE
		return STEP_MOVED
	j.fails = int(j.fails) + 1
	if net:
		j.net_fails = int(j.net_fails) + 1
		net_fail_ms = Time.get_ticks_msec()
	_streak[c.host] = int(_streak.get(c.host, 0)) + 1
	_failed_on[c.host] = int(_failed_on.get(c.host, 0)) + 1
	if int(j.fails) >= int(j.max_fails):
		if j.soft:
			_trace("going on without the %s" % j.kind)
			return _done(c)
		return _fatal(c, "%s failed on every server, %d times in all (last: %s)" % [
			"the download" if int(j.start) < 0 else "bytes %d-%d" % [j.start, int(j.start) + int(j.len) - 1],
			j.fails, why])
	var n := 1
	if int(j.cand) >= 0:
		n = _cands.size()
		j.cand = _usable((int(j.cand) + 1) % n, n)
		j.target = _cands[j.cand]
		j.redirects = 0
		_failovers += 1
	@warning_ignore("integer_division")
	var rnd := (int(j.fails) - 1) / n
	c.wake = Time.get_ticks_msec() + int(BACKOFF_MS[mini(rnd, BACKOFF_MS.size() - 1)])
	c.phase = PH_WAIT
	return STEP_MOVED


func _trace(what: String) -> void:
	if verbose:
		print("  %6d ms  %s" % [Time.get_ticks_msec() - _t0, what])


func _fatal(c: _Conn, why: String) -> int:
	c.http.close()
	_fail(why)
	return STEP_FATAL


func _fail_bool(msg: String) -> bool:
	_fail(msg)
	return false


static func _status_text(st: int, host: String) -> String:
	match st:
		HTTPClient.STATUS_CANT_RESOLVE:
			return "couldn't find %s (no internet connection?)" % host
		HTTPClient.STATUS_CANT_CONNECT:
			return "couldn't connect to %s" % host
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			return "the secure connection to %s failed" % host
		HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_DISCONNECTED:
			return "the connection to %s broke" % host
	return "the connection to %s failed (status %d)" % [host, st]


static func _be16(d: PackedByteArray, o: int) -> int:
	return (d[o] << 8) | d[o + 1]


static func _be32(d: PackedByteArray, o: int) -> int:
	return (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3]


static func _be64(d: PackedByteArray, o: int) -> int:
	return (_be32(d, o) << 32) | _be32(d, o + 4)
