# Port of Board (0x16F0E0..0x16FD24): lays out the whack-a-mole holes.
#
# wm_hitmole startGame: (0x16BA14) is its only client, and it calls exactly one
# entry point: getRandomCenters:3 noOfMole:<6..9> screenWidth:320
# screenHeight:480. That picks `noOfMole` distinct cells of a 3x3 grid and
# returns their centres in grid (row-major) order, each cell jittered by a
# random row-specific offset.
#
# makeCentersRandom (0x16F204) was read instruction by instruction, because
# its per-row offsets sit in cascaded IT blocks; every constant below is from
# that disassembly.
#
# NOT PORTED, deliberately: getCenters:screenWidth:screenHeight: (0x16FBB0),
# getFrames:screenWidth:screenHeight: (0x16F998) and the makeCentersAll /
# makeFrames helpers they call. Neither public selector has a selRef anywhere
# in the binary -- nothing can call them -- so they have no behaviour to port.
#
# Loaded by path (class_name does not work in this project).

extends RefCounted

# File-scope statics of the original (__bss), shared by every Board instance.
static var _no_of_mole := 0       # dword_7A8EC0 -- written, never read
static var _screen_height := 0.0  # flt_7A8EC4
static var _screen_width := 0.0   # flt_7A8EC8
static var _row_y := 0            # dword_7A8ECC -- running row base y
static var _col_pitch := 0        # dword_7A8ED0 -- column pitch of this row

var random_array: Array = []
var sorted_array: Array = []
var metrix := 0


## -[Board getRandomNumber:from:to:] (0x16F0E0): `count` distinct values of
## arc4random() % to + from. Returns null when the range cannot hold them.
func get_random_number_from_to(count: int, from: int, to: int) -> Variant:
	if 1 - from + to < count:
		return null
	var arr: Array = []
	while arr.size() < count:
		var v: int = _arc4random() % to + from
		if not arr.has(v):
			arr.append(v)
	return arr


## -[Board getRandomNumberUniqe:to:] (0x16F1E8): inclusive a..b.
func get_random_number_uniqe_to(a: int, b: int) -> int:
	return _arc4random() % (1 - a + b) + a


## -[Board getRandomCenters:noOfMole:screenWidth:screenHeight:] (0x16FA80).
func get_random_centers_no_of_mole_screen_width_screen_height(
		m: int, no_of_mole: int, width: int, height: int) -> Array:
	metrix = m
	_no_of_mole = no_of_mole
	_screen_width = float(width)
	_screen_height = float(height)
	var picked: Variant = get_random_number_from_to(no_of_mole, 1, metrix * metrix)
	random_array = (picked as Array).duplicate() if picked is Array else []
	sorted_array = random_array.duplicate()
	sorted_array.sort()                    # sortedArrayUsingSelector:compare:
	return make_centers_random().duplicate()


## -[Board makeCentersRandom] (0x16F204). Walks the metrix x metrix cells in
## row-major order, numbering them 1..9, and emits a centre for each cell
## whose number is in sorted_array.
##
## Per cell, a roll r = getRandomNumberUniqe:1 to:3 picks (all ints):
##   row 1: x jitter += {18,25,20}[r]  x extra 30  y extra {-5,-5,5}[r]
##   row 2: x jitter += {15,10,5}[r]   x extra 30  y extra {10,5,15}[r]
##   row 3: x jitter += {15,15,20}[r]  x extra 20  y extra {35,35,30}[r]
## (rows past 3 would reuse the previous cell's extras; metrix is always 3.)
## The x jitter ACCUMULATES along a row and resets to 0 at each new row.
##
##   x = jitter + xextra + pitch*(col-1) + pitch/2 + 10            (int)
##   y = yextra + (rowstep*0.5 + rowY)                             (float)
##
## rowstep = 134/metrix (+3.0 when metrix == 3) = 47.0; rowY starts at 150
## and after each row becomes int(rowstep + rowY) - 10 (the -10 only when
## metrix == 3). pitch is 150/metrix = 50 for row 1, then 250/metrix - 20 = 63.
func make_centers_random() -> Array:
	var out: Array = []
	_row_y = 150
	var pitch: int = 150 / metrix
	var row_step: float = float(134 / metrix)
	if metrix == 3:
		row_step += 3.0
	var half_step: float = row_step * 0.5
	var x_extra := 80          # var_3C, initial 0x50 -- overwritten before use
	var y_extra := 0           # var_38
	var counter := 0           # R5
	var row := 1               # var_40
	while true:
		var col := 1           # var_2C
		var x_jitter := 0      # var_30
		while true:
			if counter >= metrix * metrix:
				return out
			_col_pitch = pitch
			if row == 3:
				var r := get_random_number_uniqe_to(1, 3)
				if r == 1: x_jitter += 15
				if r == 2: x_jitter += 15
				if r == 3: x_jitter += 20
				if r == 1 or r == 2 or r == 3: x_extra = 20
				if r == 1: y_extra = 35
				if r == 2: y_extra = 35
				if r == 3: y_extra = 30
			elif row == 2:
				var r := get_random_number_uniqe_to(1, 3)
				if r == 1: x_jitter += 15
				if r == 2: x_jitter += 10
				if r == 3: x_jitter += 5
				if r == 1 or r == 2 or r == 3: x_extra = 30
				if r == 1: y_extra = 10
				if r == 2: y_extra = 5
				if r == 3: y_extra = 15
			elif row == 1:
				var r := get_random_number_uniqe_to(1, 3)
				if r == 1: x_jitter += 18
				if r == 2: x_jitter += 25
				if r == 3: x_jitter += 20
				if r == 1 or r == 2 or r == 3: x_extra = 30
				if r == 1: y_extra = -5
				if r == 2: y_extra = -5
				if r == 3: y_extra = 5
			var x: int = x_jitter + x_extra + _col_pitch * (col - 1) \
				+ _col_pitch / 2 + 10
			var y_base: float = half_step + float(_row_y)
			counter += 1
			if not sorted_array.is_empty():
				var y: float = float(y_extra) + y_base
				for v: Variant in sorted_array:
					if int(v) == counter:
						out.append(Vector2(float(x), y))
						break
			col += 1
			if counter % metrix == 0:
				_row_y = int(row_step + float(_row_y))   # VCVT.S32.F32 truncates
				pitch = 250 / metrix - 20
				row += 1
				if metrix == 3:
					_row_y -= 10
				break
	return out


func _arc4random() -> int:
	return randi()      # uniform 0..2^32-1, as arc4random()
