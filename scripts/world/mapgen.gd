extends GridMap

# =============================================================================
# Random race-track generator.
#
# Everything here is PURE TILE PLACEMENT.  No custom geometry, no custom
# material, no texture - the whole look comes from vendor/:
#   res://models/Library/mesh-library.tres
#     id 0 decoration-empty     id 1 decoration-forest   id 2 decoration-tents
#     id 3 track-corner         id 4 track-finish        id 5 track-ramp
#     id 6 track-straight
# Because the shipped map and this generator use the same tiles, the art style
# is identical by construction.
#
# Vendor map conventions that MUST hold (read off scenes/main.tscn):
#   cell_size      = (9.99, 1, 9.99)
#   transform      = (0, -0.5, 0)  ->  cell (0,0,0) is centred on the world origin
#   every tile     uses the shared "colormap" material
#   track is a 1-cell closed ring of straight/corner, 1 finish gate,
#   everything else is decoration (forest / tents / a few empty cells)
#
# Orientation table (measured with GridMap.get_cell_item_basis on 4.7):
#   orient  local Z -> world   local X -> world   corner arms
#     0         +Z                +X              +X / +Z
#    16         +X                -Z              +X / -Z
#    22         -X                +Z              -X / +Z
#    10         -Z                -X              -X / -Z
# Those four are the "upright" ones (basis.y == +Y).  A straight tile runs
# along its LOCAL Z, a corner joins LOCAL X to LOCAL Z, the finish arch spans
# LOCAL X, so a finish tile must keep the orientation of the straight it
# replaces.
# =============================================================================

const ITEM_EMPTY := 0
const ITEM_FOREST := 1
const ITEM_TENTS := 2
const ITEM_CORNER := 3
const ITEM_FINISH := 4
const ITEM_RAMP := 5
const ITEM_STRAIGHT := 6

const O_PZ := 0    # local Z -> world +Z
const O_PX := 16   # local Z -> world +X
const O_NX := 22   # local Z -> world -X
const O_NZ := 10   # local Z -> world -Z

const UPRIGHT := [O_PZ, O_PX, O_NX, O_NZ]

const META_SEED := "mapgen_seed"

## 关闭（默认）= 用 scenes/main.tscn 里**烤好的原版 Kenney 赛道**（GridMap 的 data 字段）。
## 打开 = 进图现拼一张随机闭环赛道，把烤好的那份覆盖掉。
##
## 【为什么留成开关而不是直接把脚本摘掉】
## 随机赛道生成器本身是好东西（generate() 是纯函数、可以离线 preload 调），
## 但主场景默认该跑原版那张 —— 想对比、想看随机图的时候在 GridMap 节点
## 属性面板里勾一下「Replace Map」即可，不用回头改场景。
@export var replace_map: bool = false

# Height the vehicle node is parked at.
#
# 【别再照着旧的注释改】旧注释写「路面顶 y=0.75，所以 1.3 让球刚贴着沥青」——
# 那个 0.75 是把瓦片 mesh 的**局部**尺寸（track-straight 的 slab 是 local y 0..0.75）
# 直接当成了世界高度，中间漏了 GridMap 的缩放。真实世界高度要这么算：
#     瓦片实例缩放 = 节点缩放(0.75) × cell_size.y(1) = 0.75
#     节点 origin.y = -0.5
#     => 路面顶面 = -0.5 + 0.75 × 0.75 = 0.0625   （约等于 0；兜底 plane 顶面就是 0）
#
# 【球半径到底是多少 —— 0.5，不是 1】
# vehicle.tscn 的 SphereShape3D 那一段**没写 radius 属性**（走默认），
# 但 drive_check 探针实际读出来是 0.5（打印 "半径=0.5"）。所以：
#     地面 y = 0（瓦片顶面 0.0625、兜底 plane 顶面 0，取 0）
#     => 球心静止高度 = 0 + 0.5 = 0.5
#     => Sphere 节点在载具原点上方 0.5（vehicle.tscn 里写死的），
#        所以载具节点 y = 0.5 - 0.5 = 0
#
# 【出生 y 必须正好等于静止高度，差多少就悬空多少】
# vehicle.gd 每帧把 sphere.linear_velocity 写成**水平**向量（y 恒为 0），
# 球体根本没有向下积累速度的能力：一帧内重力只来得及加出 g*dt*gravity_scale
# 那么点速度，下一帧又被清零 —— 于是表现为「开局缓慢往下蹭」而不是干脆落地。
# 放高 0.8 就要蹭 200 多帧（约 3 秒）才碰地，那段时间连探地射线都打不到地面、
# handle_input() 拿不到输入，车根本开不动。
const CAR_Y := 0.0


# -----------------------------------------------------------------------------
# Pure generator:  seed -> {cells, ascii, stats}.   No scene access needed.
# cells = Array of [x, z, item, orientation]
# -----------------------------------------------------------------------------
static func generate(p_seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed & 0x7fffffff
	var pick := func(p_arr: Array) -> Variant:
		return p_arr[rng.randi() % p_arr.size()]

	# 1) ring footprint -------------------------------------------------------
	var w := rng.randi_range(5, 10)     # cells along X (>=5 so both edges are straights)
	var d := rng.randi_range(5, 8)      # cells along Z
	var x0 := -(w / 2)
	var x1 := x0 + w - 1
	var z0 := -(d / 2)
	var z1 := z0 + d - 1

	# 2) the ring itself ------------------------------------------------------
	var cells := {}
	for i in range(0, w):
		var x := x0 + i
		cells[Vector3i(x, 0, z0)] = {"item": ITEM_STRAIGHT, "o": pick.call([O_PX, O_NX])}
		cells[Vector3i(x, 0, z1)] = {"item": ITEM_STRAIGHT, "o": pick.call([O_PX, O_NX])}
	for j in range(0, d):
		var z := z0 + j
		cells[Vector3i(x0, 0, z)] = {"item": ITEM_STRAIGHT, "o": pick.call([O_PZ, O_NZ])}
		cells[Vector3i(x1, 0, z)] = {"item": ITEM_STRAIGHT, "o": pick.call([O_PZ, O_NZ])}

	# corners replace whatever the loops left on the four corners
	cells[Vector3i(x0, 0, z0)] = {"item": ITEM_CORNER, "o": O_PZ}
	cells[Vector3i(x1, 0, z0)] = {"item": ITEM_CORNER, "o": O_NX}
	cells[Vector3i(x1, 0, z1)] = {"item": ITEM_CORNER, "o": O_NZ}
	cells[Vector3i(x0, 0, z1)] = {"item": ITEM_CORNER, "o": O_PX}

	# 2b) heal: a straight with no track neighbour at all is a loose stub that
	#     would just poke out of the asphalt ring - bury it back in the forest.
	var healed := 0
	var dirs := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	for k in cells.keys():
		var c: Dictionary = cells[k]
		if int(c["item"]) != ITEM_STRAIGHT:
			continue
		var kk: Vector3i = k
		var n := 0
		for dv in dirs:
			var nk: Vector3i = kk + dv
			if cells.has(nk) and int((cells[nk] as Dictionary)["item"]) >= ITEM_CORNER:
				n += 1
		if n == 0:
			cells[kk] = {"item": ITEM_FOREST, "o": int(c["o"])}
			healed += 1

	# 3) one finish gate on a straight ---------------------------------------
	var straights: Array = []
	for k in cells.keys():
		var c: Dictionary = cells[k]
		if int(c["item"]) == ITEM_STRAIGHT:
			straights.append(k)
	var fk: Vector3i = straights[rng.randi() % straights.size()]
	cells[fk] = {"item": ITEM_FINISH, "o": int(cells[fk]["o"])}

	# 4) centre the map on the origin so the hand-placed camera keeps working
	var shift := Vector3i(-fk.x, 0, -fk.z)
	var shifted := {}
	for k in cells.keys():
		shifted[(k as Vector3i) + shift] = cells[k]
	cells = shifted

	# 5) decoration -----------------------------------------------------------
	var minx := 99999
	var maxx := -99999
	var minz := 99999
	var maxz := -99999
	for k in cells.keys():
		var kk: Vector3i = k
		minx = min(minx, kk.x)
		maxx = max(maxx, kk.x)
		minz = min(minz, kk.z)
		maxz = max(maxz, kk.z)

	var margin := rng.randi_range(3, 5)          # forest skirt around the track
	var decor := {}
	var dx0 := minx - margin
	var dx1 := maxx + margin
	var dz0 := minz - margin
	var dz1 := maxz + margin
	for i in range(dx0, dx1 + 1):
		for j in range(dz0, dz1 + 1):
			var dc := Vector3i(i, 0, j)
			if cells.has(dc):
				continue
			decor[dc] = ITEM_FOREST

	# a couple of tent camps
	for _i in range(0, rng.randi_range(1, 3)):
		if decor.is_empty():
			break
		var sk: Vector3i = decor.keys()[rng.randi() % decor.size()]
		for a in range(-1, 2):
			for b in range(-1, 2):
				var tc := Vector3i(sk.x + a, 0, sk.z + b)
				if not cells.has(tc):
					decor[tc] = ITEM_TENTS

	# patchy clearing so the forest does not look like a printed texture
	for k in decor.keys():
		if rng.randf() < 0.18:
			decor[k] = ITEM_EMPTY

	for k in decor.keys():
		cells[k] = {"item": int(decor[k]), "o": UPRIGHT[rng.randi() % 4]}

	# 6) flatten + ascii + stats ---------------------------------------------
	var flat: Array = []
	var counts := {}
	var track_n := 0
	for k in cells.keys():
		var kk: Vector3i = k
		var c: Dictionary = cells[k]
		var it := int(c["item"])
		flat.append([kk.x, kk.z, it, int(c["o"])])
		counts[it] = int(counts.get(it, 0)) + 1
		if it >= ITEM_CORNER:
			track_n += 1

	var ascii := _ascii(flat, dx0, dx1, dz0, dz1)
	var stats := {
		"seed": p_seed,
		"ring": [w, d],
		"cells": flat.size(),
		"track": track_n,
		"items": counts,
		"finish": [fk.x + shift.x, fk.z + shift.z],
		"box": [dx0, dx1, dz0, dz1],
		"healed": healed,
	}
	return {"cells": flat, "ascii": ascii, "stats": stats}


# -----------------------------------------------------------------------------
# Node side: fill this GridMap, then park the cars on the start line.
# -----------------------------------------------------------------------------
func _ready() -> void:
	if not replace_map:
		return
	apply_seed(_resolve_seed())


func _resolve_seed() -> int:
	var v = get_meta(META_SEED, -1)
	if v is int and int(v) >= 0:
		return int(v)
	return randi()


func apply_seed(p_seed: int) -> void:
	var res := generate(p_seed)
	var flat: Array = res["cells"]
	clear()
	for e in flat:
		var v: Array = e
		set_cell_item(Vector3i(int(v[0]), 0, int(v[1])), int(v[2]), int(v[3]))
	set_meta(META_SEED, p_seed)
	var st: Dictionary = res["stats"]
	place_cars(int(st["finish"][0]), int(st["finish"][1]))


# Park every vehicle ON the road: walk backwards from the finish gate along the
# road itself and only ever use tiles that really are asphalt, so a car can
# never be left sitting on forest / empty ground (that used to read as "the car
# sank into the ground").
func place_cars(p_fx: int, p_fz: int) -> void:
	var parent := get_parent()
	if parent == null:
		return

	var here: Array = get_used_cells_by_item(ITEM_FINISH)
	if here.is_empty():
		return
	var orient := get_cell_item_orientation(here[0])
	var fwd := _road_dir(orient)
	var back := -fwd

	# Collect consecutive road tiles going away from the gate.  The ring is only
	# one cell wide, so we routinely run into a corner halfway down the straight
	# - when that happens, turn onto the other arm instead of giving up.
	var slots: Array = []
	var cur := Vector3i(int(p_fx), 0, int(p_fz))
	var stepv := Vector3i(int(round(back.x)), 0, int(round(back.z)))
	if stepv == Vector3i.ZERO:
		stepv = Vector3i(1, 0, 0)
	var prev_step := Vector3i.ZERO
	for _i in range(0, 10):
		var nxt := cur + stepv
		var turned := false
		if get_cell_item(nxt) < ITEM_CORNER:
			var left := Vector3i(stepv.z, 0, -stepv.x)
			var rightv := Vector3i(-stepv.z, 0, stepv.x)
			if left == Vector3i(-prev_step.x, 0, -prev_step.z):
				nxt = cur + rightv
			else:
				nxt = cur + left
				if get_cell_item(nxt) < ITEM_CORNER:
					nxt = cur + rightv
			turned = true
		if get_cell_item(nxt) < ITEM_CORNER:
			break
		slots.append(_slot_world(nxt.x, nxt.z))
		prev_step = Vector3i(nxt.x - cur.x, 0, nxt.z - cur.z)
		stepv = prev_step
		cur = nxt

	if slots.is_empty():
		slots.append(_slot_world(p_fx, p_fz))
	if slots.size() < 4:
		push_warning("[mapgen] only %d road slots found, cars may overlap" % slots.size())

	var right := fwd.cross(Vector3.UP).normalized()
	var names := ["Vehicle", "vehicle-truck-green", "vehicle-truck-purple", "vehicle-truck-red"]
	for i in range(0, names.size()):
		var n := parent.get_node_or_null(NodePath(names[i]))
		if n == null:
			continue
		var s: Vector3 = slots[snapped_index(i, slots.size())]
		var p := s + right * (float(i % 2) * 2.0 - 1.0) * 1.6
		n.global_transform = Transform3D(_basis_facing(fwd), Vector3(p.x, CAR_Y, p.z))


## 起点槽位在世界里的坐标：格 (gx,gz) 的**中心**。
##
## 千万别手写成 (格号 * cell_size)：本项目 GridMap 节点自带 0.75 缩放且原点
## 有 y 偏移，一格在世界上的实际间距是 0.75*9.99 = 7.49 而不是 9.99，
## 外加半格 3.75 的相位差。之前那么写，越远离原点偏得越多，
## 玩家车会直接停到隔壁装饰格（matrix 上看起来像"车在路外"）。
## 一律走 node transform 反算，缩放/位移怎么变都不会错。
func _slot_world(gx: int, gz: int) -> Vector3:
	var at: Vector3 = cell_size * Vector3(float(gx), 0.0, float(gz)) + cell_size * 0.5
	var w: Vector3 = transform * at
	w.y = CAR_Y
	return w


# Clamp to the last valid index (there is no clampi() that also accepts a
# runtime length in this build, so do it by hand).
static func snapped_index(p_i: int, p_len: int) -> int:
	if p_len <= 0:
		return 0
	return p_i if p_i < p_len else p_len - 1


# Which world axis does the road run through a tile with this orientation?
static func _road_dir(p_orient: int) -> Vector3:
	match p_orient:
		O_PX:
			return Vector3(1, 0, 0)
		O_NX:
			return Vector3(-1, 0, 0)
		O_NZ:
			return Vector3(0, 0, -1)
		_:
			return Vector3(0, 0, 1)


static func _basis_facing(p_fwd: Vector3) -> Basis:
	var fwd := p_fwd.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	# Basis(x_axis, y_axis, z_axis) - already orthonormal for a world axis pair,
	# so no orthogonalization is needed (Basis.orthogonalized does not exist).
	return Basis(right, Vector3.UP, -fwd)


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
static func _ascii(p_cells: Array, p_x0: int, p_x1: int, p_z0: int, p_z1: int) -> String:
	var glyph := {
		ITEM_EMPTY: ".", ITEM_FOREST: "T", ITEM_TENTS: "N",
		ITEM_CORNER: "C", ITEM_FINISH: "F", ITEM_STRAIGHT: "S",
	}
	var by_pos := {}
	for e in p_cells:
		var v: Array = e
		by_pos[Vector2i(int(v[0]), int(v[1]))] = str(glyph.get(int(v[2]), "?"))

	var lines: PackedStringArray = []
	var head := ""
	var tail := ""
	for x in range(p_x0, p_x1 + 1):
		head += str(absi(x) % 10)
		tail += "-"
	lines.append("      " + head)
	for z in range(p_z0, p_z1 + 1):
		var s := "%4d  " % z
		for x in range(p_x0, p_x1 + 1):
			s += by_pos.get(Vector2i(x, z), " ")
		lines.append(s)
	lines.append("      " + tail)
	return "\n".join(lines)
