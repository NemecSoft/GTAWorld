extends Node3D

## 赛道生成器的 headless 探针：跑一遍 generate()，把结果写进
## res://Temp/track_probe.txt（GUI/stdout 常常被吞，落盘最稳）。
## 跑法：
##   Godot --headless --path . res://tools/track_probe.tscn

func _ready() -> void:

	# 别在这里声明 TrackGenerator 类型：class_name 是首次编译才注册的，
	# 探针脚本往往比它先编译，会报 "Could not find type TrackGenerator"
	var gen = get_node_or_null("GridMap")
	var lines: PackedStringArray = PackedStringArray()

	if gen == null:
		lines.append("[probe] 没找到 GridMap 节点")
		_dump(lines)
		get_tree().quit(2)
		return

	lines.append("[probe] seed=%d  width=%d  min=%d  max=%d  straight=%.2f" % [
		gen.seed, gen.track_width, gen.min_length, gen.max_length, gen.straight_ratio])

	var ok: bool = gen.generate()
	lines.append("[probe] generate() = %s" % str(ok))
	lines.append("[probe] 闭环中心线 %d 格" % (gen._route.size() if gen._route != null else -1))
	lines.append("[probe] 路面 tile %d 个" % (gen._tiles.size() if gen._tiles != null else -1))
	lines.append("[probe] 装饰物 %d 个" % (gen._decor.size() if gen._decor != null else -1))
	lines.append("[probe] GridMap 实际占用格子 %d 个" % gen.gridmap.get_used_cells().size())
	lines.append("[probe] MeshLibrary = %s" % str(gen.gridmap.mesh_library.resource_path))

	# 落盘结果体检：按 item / orientation 各做一张直方图
	_hist(gen, lines)

	# 掩码层验收（红警2 拼图法的核心）：把区块表、掩码直方图打出来，
	# 再从**落盘结果**反推一遍连接掩码，确认闭环里没有 deg==1 的断头路
	_mask_report(gen, lines)

	# 朝向表自检：4.7 上 orientation 是 int，索引 <-> Basis 的口子只在 GridMap 里，
	# 把 24 项全打出来，路面朝错方向时能一眼看出是哪一项错位
	_ensure_table(gen, lines)

	# 材质复检：路 tile 的材质必须是「内嵌在 mesh 里」的那一份
	var lib: MeshLibrary = gen.gridmap.mesh_library
	for item_id in [3, 4, 6]:
		var m: Mesh = lib.get_item_mesh(item_id)
		if m == null:
			lines.append("[P0] item %d 没有 mesh" % item_id)
			continue
		lines.append("[mat] item %d：surface %d 个，槽0 = %s" % [
			item_id, m.get_surface_count(), str(m.surface_get_material(0))])

	_dump(lines)
	get_tree().quit(0 if ok else 1)

## 落盘体检：每个 item 铺了几格、用了哪些 orientation、有没有铺到路面外面去。
## 如果 straight 的 orientation 只有 0 一个值，说明朝向换算挂了（整条路朝同一边）。
func _hist(gen, lines: PackedStringArray) -> void:

	if gen.gridmap == null:
		return

	var items: Dictionary = {}
	var orients: Dictionary = {}
	var deco_on_road: int = 0

	for cell in gen.gridmap.get_used_cells():
		var item: int = gen.gridmap.get_cell_item(cell)
		var orient: int = gen.gridmap.get_cell_item_orientation(cell)
		var key: String = "%d" % item
		items[key] = int(items.get(key, 0)) + 1
		var okey: String = "%d" % orient
		orients[okey] = int(orients.get(okey, 0)) + 1
		if item == 1 or item == 2:
			if gen._tiles.has("%d,%d" % [cell.x, cell.z]):
				deco_on_road += 1

	var names: Dictionary = {0: "empty", 1: "forest", 2: "tents", 3: "corner", 4: "finish", 5: "ramp", 6: "straight"}
	var rows: PackedStringArray = PackedStringArray()
	for k in items.keys():
		rows.append("  item %s(%s) = %d 格" % [str(k), str(names.get(int(k), "?")), int(items[k])])
	lines.append("[hist] 落盘明细")
	lines.append_array(rows)

	var orows: PackedStringArray = PackedStringArray()
	for k in orients.keys():
		orows.append("  orient %s -> %d 格" % [str(k), int(orients[k])])
	lines.append("[hist] 朝向分布（路 tile 应出现 0/10/16/22 四组值）")
	lines.append_array(orows)

	lines.append("[hist] deco_items 配置 = %s" % str(gen.deco_items))
	lines.append("[hist] 压在路面上的装饰物 = %d 个（必须是 0）" % deco_on_road)
	lines.append("[hist] 兜底地面 = %s" % ("有" if gen._floor != null and is_instance_valid(gen._floor) else "无"))

## ---------------------------
## 红警2 连接掩码层验收
## ---------------------------
## 两个层次：
##   1. 看生成器自己认出了哪些区块（_tile_table），以及铺出来的掩码长什么样
##   2. **从落盘结果反推**连接掩码，独立校验一遍
##      第 2 步才是真验收 —— 生成器内部说「我校验过了」不算数，
##      得看真写进 GridMap 的东西是不是一个「每格都跟邻居双向对上、没有 deg==1」的环。
func _mask_report(gen, lines: PackedStringArray) -> void:

	# 1. 区块表
	lines.append("[mask] 从 MeshLibrary 认出的路区块（红警2 的「文件名 = 连接类型」）")
	if gen._tile_table.is_empty():
		lines.append("   <空> —— 一个都没认出来，item 名字里得带 straight / curve / corner")
	for k in gen._tile_table.keys():
		var e: Dictionary = gen._tile_table[k]
		lines.append("   base mask %d -> item %d（base_orient %d）" % [
			int(k), int(e["item"]), int(e["base_orient"])])

	# 2. 从落盘结果反推掩码
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
	var mask: Dictionary = {}
	for key in gen._tiles.keys():
		mask[key] = 0

	var edges: int = 0
	for key in mask.keys():
		# 必须显式写 PackedStringArray：key 是 Variant，`:=` 推不出类型会 Parse Error
		var p: PackedStringArray = key.split(",")
		var c: Vector2i = Vector2i(int(p[0]), int(p[1]))
		for i in 4:
			var nb: Vector2i = c + dirs[i]
			var nkey: String = "%d,%d" % [nb.x, nb.y]
			if not mask.has(nkey):
				continue
			# 这条边同时记在本格朝 i、邻居朝 (i+2)，两边必须对称
			mask[key] = int(mask[key]) | (1 << i)
			mask[nkey] = int(mask[nkey]) | (1 << ((i + 2) % 4))
			edges += 1

	lines.append("[mask] 反推（只看中心线单线，宽路不适用）：连接边 %d 条" % (edges / 2))
	lines.append("[mask] deg==1 的格 = %d（闭环里必须是 0，1 就是断头路）" % _deg(gen, mask, 1))
	lines.append("[mask] deg==2 的格 = %d（每一格都正好接两条边，等于处处通畅）" % _deg(gen, mask, 2))

	# 3. 整块路面连通性：从任意一格 flood fill 走一遍，
	#    能走遍所有路面格 = 铺出来的是一整条路，没有孤立碎片
	_flood(gen, lines)

	# 4. 中心线掩码抽样：直道 / 弯道各该被认出来几个。
	#    这里要是 corner 一直等于 0，说明入向 / 出向算错了（铺出来会是直角墙）
	_sample_route(gen, lines)

	# 5. 多 seed 扫一遍：单个 seed 跑通说明不了生成器靠得住，
	#    seed 换一批必须次次成环（换 seed 撞运气是这类程序最大的坑）
	_sweep(gen, lines)

## 中心线掩码抽样：把 route 每格的「入向 / 出向 / mask / 认出哪个 item」列出来。
## corner 一格都没有 = 入向被当成出向的反向了（最典型的掩码 bug）。
func _sample_route(gen, lines: PackedStringArray) -> void:

	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]

	var hist: Dictionary = {}
	var rows: PackedStringArray = PackedStringArray()

	var n: int = gen._route.size()
	for i in n:
		var here: Vector2i = gen._route[i]
		var prev: Vector2i = gen._route[(i - 1 + n) % n]
		var next: Vector2i = gen._route[(i + 1) % n]

		var io: int = dirs.find(next - here)
		var ii: int = dirs.find(here - prev)
		if io < 0 or ii < 0:
			lines.append("[sample] route[%d] 入/出向不是四方向（环路断了）" % i)
			continue

		var m: int = (1 << io) | (1 << ((ii + 2) % 4))
		var t: Dictionary = gen._mask_tile(m)
		var item: int = int(t.get("item", -1))
		var hk: String = "%d" % m
		hist[hk] = int(hist.get(hk, 0)) + 1

		if i < 6:
			rows.append("   route[%d] 入%d 出%d mask=%d -> item %d" % [i, ii, io, m, item])

	for k in hist.keys():
		rows.append("   中心线上 mask %-3s 出现 %d 格" % [str(k), int(hist[k])])

	lines.append("[sample] 中心线掩码抽样（mask 3/6/12/9 = 弯道，5/10 = 直道）")
	lines.append_array(rows)

## 换 8 个 seed 各跑一遍，统计成功率。
## 只有一两个 seed 成功基本等于没验证 —— 自交、长度越界这类失败
## 在别的 seed 上照样会冒出来，不扫一遍根本发现不了。
func _sweep(gen, lines: PackedStringArray) -> void:

	var ok_n: int = 0
	var sizes: PackedStringArray = PackedStringArray()

	for s in range(1, 9):
		var s2: int = s * 1013
		var ok: bool = gen.generate_with_seed(s2)
		if ok:
			ok_n += 1
		sizes.append("s%d=%s/%d" % [s2, "✓" if ok else "✗", gen._tiles.size()])

	lines.append("[sweep] 8 个 seed：成功 %d / 8" % ok_n)
	lines.append("[sweep] 明细 %s" % " ".join(sizes))

## 统计掩码里「有几个方向是通的」等于 deg 的格子数。
func _deg(gen, mask: Dictionary, want: int) -> int:

	var n: int = 0
	for key in mask.keys():
		var m: int = int(mask[key])
		var pop: int = 0
		for i in 4:
			if (m & (1 << i)) != 0:
				pop += 1
		if pop == want:
			n += 1
	return n

## 路面连通性 flood fill：从第一格出发四邻扩散，看能不能走遍所有路面格。
## 铺出来如果是几段互不相通的路，车开到断口就会一头撞进虚空。
func _flood(gen, lines: PackedStringArray) -> void:

	if gen._tiles.is_empty():
		lines.append("[flood] 没有路面可查")
		return

	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]

	var seen: Dictionary = {}
	var stack: Array[Vector2i] = []
	var first: PackedStringArray = gen._tiles.keys()[0].split(",")
	stack.append(Vector2i(int(first[0]), int(first[1])))
	seen["%d,%d" % [stack[0].x, stack[0].y]] = true

	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		for d in dirs:
			var nb: Vector2i = c + d
			var nkey: String = "%d,%d" % [nb.x, nb.y]
			if seen.has(nkey) or not gen._tiles.has(nkey):
				continue
			seen[nkey] = true
			stack.append(nb)

	var reach: int = seen.size()
	var total: int = gen._tiles.size()
	lines.append("[flood] 从第一格能走到 %d / %d 格（必须相等，否则说明路面是几段断的）" % [
		reach, total])
	lines.append("[flood] 结果 = %s" % ("连通" if reach == total else "有 %d 格走不到（断头路）" % (total - reach)))

func _mask_desc(m: int) -> String:

	var parts: PackedStringArray = PackedStringArray()
	var names: PackedStringArray = PackedStringArray(["+X", "+Z", "-X", "-Z"])
	for i in 4:
		if (m & (1 << i)) != 0:
			parts.append(names[i])
	if parts.is_empty():
		return "<孤立>"
	return "".join(parts) + " 通"

## 打印 orientation 索引 -> tile 局部轴的世界指向。
## 重点看：有没有一批索引的 +Y 是朝天的（装饰物只能用那批，树不能倒着种）。
func _ensure_table(gen, lines: PackedStringArray) -> void:

	if gen.gridmap == null:
		return

	var flat: int = 0
	var rows: PackedStringArray = PackedStringArray()
	for i in 24:
		var b: Basis = gen.gridmap.get_basis_with_orthogonal_index(i)
		var up_ok: bool = b.y.dot(Vector3.UP) > 0.5
		if up_ok:
			flat += 1
		var mark: String = "" if up_ok else "   <-- 不是朝天"
		rows.append("  %2d  fwd=%s  up=%s%s" % [i, _fmt(b.z), _fmt(b.y), mark])
	lines.append("[orient] 24 项正交朝向（+Y 朝天的有 %d 项）" % flat)
	lines.append_array(rows)

	# 往返验证：索引 -> Basis -> 索引 必须还原成同一个数，
	# 这一步过了，_angle_index() 的结果就可以信
	var bad: int = 0
	for i in 24:
		var bb: Basis = gen.gridmap.get_basis_with_orthogonal_index(i)
		if gen.gridmap.get_orthogonal_index_from_basis(bb) != i:
			bad += 1
	lines.append("[orient] 往返一致性：%s" % ("全对" if bad == 0 else "%d 项对不上" % bad))

func _fmt(v: Vector3) -> String:
	return "(%+.0f,%+.0f,%+.0f)" % [v.x, v.y, v.z]

func _dump(lines: PackedStringArray) -> void:

	var f := FileAccess.open("res://Temp/track_probe.txt", FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	print("\n".join(lines))
