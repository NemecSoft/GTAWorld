extends Node3D

# 程序化都市棋盘（Phase 1）：草地底板 + 棋盘路网 + Kenney city-kit 建筑 + 可上手的停放车。
# 风格锁 Kenney（R5）：地面色板沿用 Temp/removed_city/city.gd 的那组色，
# 建筑与车辆用参考项目里的 CC0 GLB（models/city、models/cars），材质由 GLB 自带（colormap.png）。
#
# 布局：GRID x GRID 个街区，街区边长 BLOCK，街区之间是宽 ROAD_W 的马路。
# 竖路 i 的中心线 x = (i - GRID/2) * PERIOD，i 取 0..GRID（含边界外圈），PERIOD = BLOCK + ROAD_W。
#
# 碰撞约定（见 README 坑 3 / MEMORY）：静态几何一律 layer=11 / mask=11，
# 车球在 layer 8，人物在 layer 2 / mask 11。
#
# 路面视觉顶在 y≈0.02、碰撞地面顶在 y=0：车球静止球心 0.5，
# model_origin_y 的换算与 vehicle_picker.gd 同一套公式（-0.15 + bottom_c）。

const BLOCK: float = 34.0
const ROAD_W: float = 12.0
const PERIOD: float = BLOCK + ROAD_W
const CURB_H: float = 0.06

@export_range(2, 9, 1) var grid_count: int = 5
@export var seed_value: int = 20261003
@export var parked_cars: int = 12

var _rng := RandomNumberGenerator.new()
var _mats: Dictionary = {}
var _building_paths: Array = []
var _detail_paths: Array = []
var _car_paths: Array = []

const VEHICLE_SCENE := "res://scenes/vehicle.tscn"
const CAR_LEN_TARGET := 4.3
const LowPolyProps := preload("res://scripts/world/lowpoly_props.gd")
const STREET_TREE_GLBS: Array = [
	"res://models/nature/tree_pineDefaultA.glb",
	"res://models/nature/tree_oak.glb",
	"res://models/nature/tree_default.glb",
]


func _ready() -> void:
	_rng.seed = seed_value
	_make_materials()
	_scan_assets()
	_build_ground()
	_build_roads()
	_build_blocks()
	_spawn_cars()
	_spawn_street_trees()


func _mat(key: String, color: Color) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	_mats[key] = m
	return m


func _make_materials() -> void:
	# 色值取自 Temp/removed_city/city.gd（Kenney 色板）
	_mat("grass", Color(0.40, 0.72, 0.35))
	_mat("asphalt", Color(0.38, 0.39, 0.42))
	_mat("lane_yellow", Color(0.99, 0.80, 0.17))
	_mat("sidewalk", Color(0.66, 0.67, 0.70))


func _scan_assets() -> void:
	var dir := DirAccess.open("res://models/city")
	if dir != null:
		dir.list_dir_begin()
		var f: String = dir.get_next()
		while f != "":
			if f.ends_with(".glb"):
				if f.begins_with("building-"):
					_building_paths.append("res://models/city/" + f)
				elif f.begins_with("chimney-") or f.begins_with("shipping-container-") or f == "water-tower.glb" or f.begins_with("solar-panel"):
					_detail_paths.append("res://models/city/" + f)
			f = dir.get_next()
		dir.list_dir_end()
	_building_paths.sort()
	_detail_paths.sort()
	_car_paths = [
		"res://models/cars/sedan-sports.glb",
		"res://models/cars/hatchback-sports.glb",
		"res://models/cars/taxi.glb",
		"res://models/cars/police.glb",
		"res://models/cars/suv.glb",
		"res://models/cars/van.glb",
		"res://models/cars/race.glb",
		"res://models/cars/delivery.glb",
		"res://models/cars/ambulance.glb",
		"res://models/cars/firetruck.glb",
		"res://models/cars/truck.glb",
		"res://models/cars/suv-luxury.glb",
	]


func _add_box(root: Node3D, name: String, size: Vector3, center: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = center
	root.add_child(mi)
	return mi


func _build_ground() -> void:
	var span: float = float(grid_count + 1) * PERIOD + 120.0
	var body := StaticBody3D.new()
	body.name = "GroundBody"
	body.collision_layer = 11
	body.collision_mask = 9
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(span, 0.1, span)
	cs.shape = bs
	cs.position = Vector3(0, -0.05, 0)
	body.add_child(cs)
	add_child(body)
	var top := MeshInstance3D.new()
	top.name = "GrassTop"
	var pm := PlaneMesh.new()
	pm.size = Vector2(span, span)
	top.mesh = pm
	top.material_override = _mats["grass"]
	top.position = Vector3(0, 0.0, 0)
	add_child(top)


func _build_roads() -> void:
	var roads := Node3D.new()
	roads.name = "Roads"
	add_child(roads)
	var span: float = float(grid_count) * PERIOD + ROAD_W
	var i: int = 0
	while i <= grid_count:
		var c: float = (float(i) - float(grid_count) * 0.5) * PERIOD
		_add_box(roads, "RoadV%d" % i, Vector3(ROAD_W, 0.04, span), Vector3(c, 0.02, 0), _mats["asphalt"])
		_add_box(roads, "RoadH%d" % i, Vector3(span, 0.04, ROAD_W), Vector3(0, 0.02, c), _mats["asphalt"])
		# 双黄线 + 白色边线（纯视觉，不给碰撞）
		_add_box(roads, "LineV%d" % i, Vector3(0.16, 0.01, span), Vector3(c - 0.18, 0.045, 0), _mats["lane_yellow"])
		_add_box(roads, "LineVb%d" % i, Vector3(0.16, 0.01, span), Vector3(c + 0.18, 0.045, 0), _mats["lane_yellow"])
		_add_box(roads, "LineH%d" % i, Vector3(span, 0.01, 0.16), Vector3(0, 0.045, c - 0.18), _mats["lane_yellow"])
		_add_box(roads, "LineHb%d" % i, Vector3(span, 0.01, 0.16), Vector3(0, 0.045, c + 0.18), _mats["lane_yellow"])
		i += 1


func _build_blocks() -> void:
	var blocks := Node3D.new()
	blocks.name = "Blocks"
	add_child(blocks)
	var bodies := Node3D.new()
	bodies.name = "BlockBodies"
	add_child(bodies)
	var i: int = 0
	while i < grid_count:
		var j: int = 0
		while j < grid_count:
			var cx: float = (float(i) + 0.5 - float(grid_count) * 0.5) * PERIOD
			var cz: float = (float(j) + 0.5 - float(grid_count) * 0.5) * PERIOD
			_add_box(blocks, "Sidewalk_%d_%d" % [i, j], Vector3(BLOCK, 0.08, BLOCK), Vector3(cx, CURB_H - 0.02, cz), _mats["sidewalk"])
			_fill_block(blocks, bodies, i, j, cx, cz)
			j += 1
		i += 1


func _fill_block(blocks: Node3D, bodies: Node3D, bi: int, bj: int, cx: float, cz: float) -> void:
	if _building_paths.is_empty():
		return
	# 3x3 地块，每块一栋楼：5x5 街区 = 最多 225 栋，城市感靠密度
	var lot: float = BLOCK / 3.0
	var li: int = 0
	while li < 9:
		var ox: float = (float(li % 3) - 1.0) * lot
		var oz: float = (float(li / 3) - 1.0) * lot
		if _rng.randf() >= 0.06:
			var path: String = String(_building_paths[_rng.randi_range(0, _building_paths.size() - 1)])
			var sc: PackedScene = load(path)
			if sc != null:
				var m := sc.instantiate() as Node3D
				m.name = "Building_%d_%d_%d" % [bi, bj, li]
				m.position = Vector3(cx + ox, CURB_H, cz + oz)
				m.rotation.y = float(_rng.randi_range(0, 3)) * PI * 0.5
				blocks.add_child(m)
				_fit_building(m, bodies, lot * 0.95, _rng.randf_range(1.0, 2.4))
		li += 1
	# 街区留一条对角线小道具（水塔/集装箱/烟囱），工业城味
	if not _detail_paths.is_empty() and _rng.randf() < 0.75:
		var dp: String = String(_detail_paths[_rng.randi_range(0, _detail_paths.size() - 1)])
		var dsc: PackedScene = load(dp)
		if dsc != null:
			var d := dsc.instantiate() as Node3D
			d.name = "Detail_%d_%d" % [bi, bj]
			d.position = Vector3(cx + _rng.randf_range(-lot, lot), CURB_H, cz + _rng.randf_range(-lot, lot))
			d.rotation.y = _rng.randf_range(0.0, TAU)
			blocks.add_child(d)
			_fit_building(d, bodies, _rng.randf_range(3.0, 6.0), 1.0)


## 建筑：把最大水平边缩到目标边长（可再拉高），同时补一个盒碰撞。
## 【测量必须用引擎 global_transform】节点 add_child 后 is_inside_tree() 为真，
## 引擎的 global_transform * mesh.aabb 是准的；自制 transform 累乘实测会把
## 包围盒整体往下错算半个楼高，楼底悬空 11 米（截图实测）。
func _fit_building(m: Node3D, bodies: Node3D, target: float, h_mult: float) -> void:
	var box: AABB = _world_aabb(m)
	var ext: float = maxf(box.size.x, box.size.z)
	if ext <= 0.001:
		push_warning("[city] " + String(m.name) + " 量不出尺寸，保持原样")
		return
	var s: float = target / ext
	m.scale *= Vector3(s, s * h_mult, s)
	var box2: AABB = _world_aabb(m)
	m.position.y += CURB_H - box2.position.y
	var body := StaticBody3D.new()
	body.collision_layer = 11
	body.collision_mask = 9
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = box2.size
	cs.shape = bs
	body.position = Vector3(box2.position.x + box2.size.x * 0.5, 0.0, box2.position.z + box2.size.z * 0.5)
	cs.position = Vector3(0.0, box2.position.y + box2.size.y * 0.5, 0.0)
	body.add_child(cs)
	bodies.add_child(body)


## 街树（需求 #17 城内部分）：摆最外环路两侧的绿化带上；v1.5 起带树干碰撞。
## 【为什么不在街区人行道】_fill_block 的 3x3 地块铺到 ±16.7，人行道板
## （±17）和沥青（17..29）之间根本没有树位；硬摆要么穿楼要么站车道。
func _spawn_street_trees() -> void:
	var buckets_owner: Array = []
	var buckets: Array = []
	var bucket_scale: Array = []
	var bucket_ground: Array = []
	for pth in STREET_TREE_GLBS:
		var vs: Array = LowPolyProps.variants(pth)
		var bottom: float = 99999.0
		for v in vs:
			bottom = minf(bottom, float(v["xform"].origin.y))
		for v in vs:
			buckets_owner.append(v)
			buckets.append([])
			bucket_scale.append(LowPolyProps.fit_scale(v["mesh"], 4.5))
			bucket_ground.append(bottom)
	if buckets_owner.is_empty():
		return
	# 方环：最外路中心线在 half*PERIOD，沥青外沿再让 3m，就是草地
	var ring: float = float(grid_count) * 0.5 * PERIOD + ROAD_W * 0.5 + 3.0
	var t: float = -ring
	while t <= ring + 0.01:
		for side in range(4):
			var j0: float = _rng.randf_range(-1.5, 1.5)
			var j1: float = _rng.randf_range(-0.8, 0.8)
			var px: float = 0.0
			var pz: float = 0.0
			match side:
				0:
					px = t + j0
					pz = ring + j1
				1:
					px = t + j0
					pz = -ring - j1
				2:
					px = ring + j1
					pz = t + j0
				_:
					px = -ring - j1
					pz = t + j0
			var bi: int = int(_rng.randi() % buckets_owner.size())
			var v: Dictionary = buckets_owner[bi]
			var xf: Transform3D = v["xform"]
			var s: float = float(bucket_scale[bi]) * _rng.randf_range(0.82, 1.25)
			var rot := Basis.IDENTITY.rotated(Vector3.UP, _rng.randf() * TAU)
			var g: float = float(bucket_ground[bi])
			buckets[bi].append(Transform3D(rot.scaled(Vector3(s, s, s)),
				Vector3(px + xf.origin.x * s, (xf.origin.y - g) * s, pz + xf.origin.z * s)))
		t += 8.0
	var trees := Node3D.new()
	trees.name = "StreetTrees"
	add_child(trees)
	# v1.5：街树挂实体碰撞（用户点名「给物体做好碰撞」），layer 与建筑/地面同一套
	var tcols := StaticBody3D.new()
	tcols.name = "StreetTreesCols"
	tcols.collision_layer = 11
	tcols.collision_mask = 9
	trees.add_child(tcols)
	var trunk := CylinderShape3D.new()
	trunk.radius = 0.35
	trunk.height = 2.4
	for b in buckets:
		for tf in b:
			var cs := CollisionShape3D.new()
			cs.shape = trunk
			var o: Vector3 = (tf as Transform3D).origin
			cs.position = Vector3(o.x, 1.2, o.z)
			tcols.add_child(cs)
	for i in range(buckets.size()):
		if buckets[i].is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = buckets_owner[i]["mesh"]
		mm.instance_count = (buckets[i] as Array).size()
		for j in range(mm.instance_count):
			mm.set_instance_transform(j, buckets[i][j])
		var mi := MultiMeshInstance3D.new()
		mi.name = "Trees_%d" % i
		mi.multimesh = mm
		## albedo 是线性空间：(0.08,0.20,0.07) 渲出来才是肉眼 sRGB(80,122,75) 的绿
		mi.material_override = LowPolyProps.prop_material(buckets_owner[i]["material"],
			Color(0.08, 0.20, 0.07))
		trees.add_child(mi)


func _spawn_cars() -> void:
	if _car_paths.is_empty():
		return
	var vs: PackedScene = load(VEHICLE_SCENE)
	if vs == null:
		push_warning("[city] 读不到 scenes/vehicle.tscn")
		return
	var cars := Node3D.new()
	cars.name = "Cars"
	add_child(cars)
	# 保证出生点旁必有一台可开的车（随机车可能都刷在远处）
	if grid_count >= 2:
		var start: Node3D = vs.instantiate()
		start.name = "CarStarter"
		start.transform = Transform3D(Basis(Vector3.UP, PI), Vector3(-19.6, 0.0, 12.0))
		cars.add_child(start)
		_outfit_car(start, String(_car_paths[0]))
		start.add_to_group("vehicles")
	var n: int = 0
	while n < parked_cars:
		var road_idx: int = _rng.randi_range(0, grid_count)
		var along_h: bool = _rng.randf() < 0.5
		var rc: float = (float(road_idx) - float(grid_count) * 0.5) * PERIOD
		var span: float = float(grid_count) * PERIOD
		var t: float = _rng.randf_range(-span * 0.45, span * 0.45)
		var lane: float = 3.4 if _rng.randf() < 0.5 else -3.4
		var pos: Vector3 = Vector3(rc + lane, 0.0, t) if along_h else Vector3(t, 0.0, rc + lane)
		var yaw: float = (0.0 if lane > 0.0 else PI) if along_h else (PI * 0.5 if lane > 0.0 else -PI * 0.5)
		var car: Node3D = vs.instantiate()
		car.name = "Car%d" % n
		car.transform = Transform3D(Basis(Vector3.UP, yaw), pos)
		cars.add_child(car)
		_outfit_car(car, String(_car_paths[_rng.randi_range(0, _car_paths.size() - 1)]))
		car.add_to_group("vehicles")
		n += 1


## 换模型 + 归一化尺寸 + 关掉停放车的循环音效（进场由 urban_game.gd 恢复）。
func _outfit_car(car: Node, model_path: String) -> void:
	var container: Node = car.get_node_or_null("Container")
	if container == null:
		return
	var old: Node = container.get_node_or_null("Model")
	if old != null:
		container.remove_child(old)
		old.queue_free()
	var sc: PackedScene = load(model_path)
	if sc == null:
		push_warning("[city] 读不到车辆模型 " + model_path)
		return
	# 记下型号（任务/商店靠它认出出租车、货运车，不靠节点名）
	car.set_meta("car_model", model_path)
	var m := sc.instantiate() as Node3D
	m.name = "Model"
	container.add_child(m)
	if car.has_method("bind_nodes"):
		car.call("bind_nodes")
	# vehicle.gd 每帧强制 vehicle_model.position，测量前把 position 清零；
	# 尺寸与贴地高度全部用引擎 global_transform 量（见 _fit_building 注释的坑）。
	m.position = Vector3.ZERO
	var box: AABB = _world_aabb(m)
	var ext: float = maxf(box.size.x, maxf(box.size.y, box.size.z))
	if ext > 0.001:
		var s: float = CAR_LEN_TARGET / ext
		m.scale *= Vector3.ONE * s
		# 贴地基准取「轮子」的下沿：部分 Kenney 车的 body 网格带贴地裙边/阴影面，
		# 比轮底还低 ~0.2 米，按整体 AABB 对齐会让轮子悬空（实测橙色轿车）
		car.set("model_origin_y", -0.15 + _wheel_bottom(m))
	var eng: Node = container.get_node_or_null("EngineSound")
	if eng != null:
		eng.stop()
	var screech: Node = container.get_node_or_null("ScreechSound")
	if screech != null:
		screech.stop()


# ------------------------------------------------------------ 对外生成接口（#20）

## 商店 / 出租车 / 货运模块共用的生成车辆入口：摆一台指定型号的车进图。
## 节点名由调用方定死（两端同名才能走现有的按名快照同步），返回后由
## urban_game.spawn_city_car 补挂交互组件（门控绑定 + mark_ready）。
func build_car(node_name: String, model_path: String, pos: Vector3, yaw: float) -> Node3D:
	var vs: PackedScene = load(VEHICLE_SCENE)
	if vs == null:
		push_warning("[city] 读不到 scenes/vehicle.tscn")
		return null
	var cars: Node3D = get_node_or_null("Cars") as Node3D
	if cars == null:
		cars = Node3D.new()
		cars.name = "Cars"
		add_child(cars)
	if cars.get_node_or_null(NodePath(node_name)) != null:
		return null   # 同名车已存在（重复购买/重复初始化保护）
	var car: Node3D = vs.instantiate() as Node3D
	car.name = node_name
	car.transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	cars.add_child(car)
	_outfit_car(car, model_path)
	car.add_to_group("vehicles")
	return car


## 路网采样（货区/乘客/目的地的唯一点位真源）：随机挑一条路中心线，
## 沿路取一段，再向路肩方向偏 curb_offset 米（0~6 在沥青上，>6 到人行道侧）。
func sample_road_point(rng: RandomNumberGenerator, curb_offset: float = 0.0) -> Vector3:
	var road_idx: int = rng.randi_range(0, grid_count)
	var c: float = (float(road_idx) - float(grid_count) * 0.5) * PERIOD
	var span: float = float(grid_count) * PERIOD
	var t: float = rng.randf_range(-span * 0.45, span * 0.45)
	var side: float = curb_offset if rng.randf() < 0.5 else -curb_offset
	var vertical: bool = rng.randf() < 0.5
	if vertical:
		return Vector3(c + side, 0.0, t)
	return Vector3(t, 0.0, c + side)


## 采一个离 origin 距离在 [dmin, dmax] 的路网点；40 次采不到就退最近点。
func sample_road_point_away(rng: RandomNumberGenerator, origin: Vector3, dmin: float, dmax: float) -> Vector3:
	var best: Vector3 = sample_road_point(rng, 4.6)
	var best_err: float = INF
	var n: int = 0
	while n < 40:
		var p: Vector3 = sample_road_point(rng, 4.6)
		var d: float = Vector2(p.x - origin.x, p.z - origin.z).length()
		if d >= dmin and d <= dmax:
			return p
		var err: float = absf(d - (dmin + dmax) * 0.5)
		if err < best_err:
			best_err = err
			best = p
		n += 1
	return best


# ------------------------------------------------------------ 世界 AABB 测量
# 节点必须在树内：引擎的 global_transform * mesh.aabb 才是准的，
# 自制 transform 累乘实测会整体偏移半个楼高（楼底悬空 11 米，截图实证）。

func _world_aabb(n: Node3D) -> AABB:
	var list: Array = []
	_collect_aabb(n, list)
	if list.is_empty():
		return AABB(Vector3.ZERO, Vector3.ZERO)
	var box: AABB = list[0]
	var i: int = 1
	while i < list.size():
		box = box.merge(list[i])
		i += 1
	return box


func _collect_aabb(n: Node, list: Array) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null and mi.is_inside_tree():
			var g: AABB = mi.global_transform * mi.mesh.get_aabb()
			if g.size.x > 0.0 or g.size.y > 0.0 or g.size.z > 0.0:
				list.append(g)
	for c in n.get_children():
		_collect_aabb(c, list)


## 轮子网格的世界最低点；没有名字含 wheel 的网格就退回整体 AABB 下沿。
func _wheel_bottom(m: Node3D) -> float:
	var wheel_y: float = 999.0
	var stack: Array = [m]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null and mi.is_inside_tree() and String(n.name).to_lower().contains("wheel"):
				var g: AABB = mi.global_transform * mi.mesh.get_aabb()
				wheel_y = minf(wheel_y, g.position.y)
		for c in n.get_children():
			stack.append(c)
	if wheel_y < 900.0:
		return wheel_y
	return _world_aabb(m).position.y
