extends "res://modules/missions/mission_base.gd"
## modules/missions/cargo_mission.gd —— 合作运货（多人，也可单人跑）（设计 §4-A）
##
## 计数制：装货区 24 箱、每车一趟 6 箱 → 必须多趟；host 权威结算，
## 客机只上报意图（module.gd 的 _rpc_cargo_intent），全量状态 _rpc_cargo_state 广播。
## 货箱是纯显隐复制品（区堆 box.glb、车斗 BoxMesh），零物理。
## 掉线回退（坑②）：host 在 peer_disconnected 时把该车未卸的货退回装货区。
## 分红门槛（坑③）：contributors 记录「至少卸过一次」的人，完工只发给他们。
##
## 【#20 坑】门控传进来的 player_pos 是人物节点位置——开车时人物停在上车点不会跟车走
## （#18 的设计），所以装/卸的距离判定必须拿「正在开的车的真实位置」来比；
## 交互组件的父节点也得是货区自己的 Node3D，不然 InteractionGate 排序会拿
## 容器原点（0,0,0）算距离。
## 4.7 语法备忘：无 `..` 区间；GDScript4 的 `/` 恒出 float，取整一律 int(a / b)；
## 量包围盒必须等节点进树（city_builder 同款坑）。

const TOTAL := 24
const CAP := 6
const PAY_UNLOAD := 12
const PAY_DONE := 300
const LOAD_POS := Vector3(46, 0, 136)
const UNLOAD_POS := Vector3(-46, 0, -136)
const TRUCK_PATH := "res://models/cars/delivery.glb"
const TRUCK_NAME := "CargoTruck"
const BOX_PATH := "res://models/cars/box.glb"
const BOX_SIZE := 1.3

var stock: int = TOTAL
var delivered: int = 0
var loaded_by: Dictionary = {}    # peer_id -> {"n": int, "car": String}
var contributors: Array = []      # peer_id 列表（卸过货才有完工分红）
var _reset_t: float = 0.0
var _result: String = ""
var _result_t: float = 0.0

var _root: Node3D = null
var _load_boxes: Array = []
var _unload_boxes: Array = []
var _bed_piles: Dictionary = {}   # peer_id -> Node3D（挂在各车 Container 下）
var _load_spot: LoadSpot = null
var _unload_spot: UnloadSpot = null
var _box_sc: PackedScene = null


class LoadSpot extends Interactable:
	var owner_m: RefCounted = null

	func can_interact(player_pos: Vector3) -> bool:
		if not (is_ready and is_interactable) or owner_m == null:
			return false
		return owner_m.can_load(player_pos)

	func get_prompt(_player_pos: Vector3) -> String:
		return owner_m.load_prompt_text()

	func on_interact(_player_pos: Vector3) -> void:
		owner_m.do_load()


class UnloadSpot extends Interactable:
	var owner_m: RefCounted = null

	func can_interact(player_pos: Vector3) -> bool:
		if not (is_ready and is_interactable) or owner_m == null:
			return false
		return owner_m.can_unload(player_pos)

	func get_prompt(_player_pos: Vector3) -> String:
		return owner_m.unload_prompt_text()

	func on_interact(_player_pos: Vector3) -> void:
		owner_m.do_unload()


# ---------------------------------------------------------------- 生命周期

func enter(g: Node3D) -> void:
	leave()
	game = g
	if game == null:
		return
	_box_sc = load(BOX_PATH) as PackedScene
	_root = Node3D.new()
	_root.name = "CargoZones"
	game.add_child(_root)
	var load_zone: Node3D = _make_zone(LOAD_POS, Color(0.20, 0.85, 0.40, 0.35), tr("装货区"))
	var unload_zone: Node3D = _make_zone(UNLOAD_POS, Color(1.0, 0.55, 0.20, 0.35), tr("卸货区"))
	_load_boxes = _make_pile(LOAD_POS)
	_unload_boxes = _make_pile(UNLOAD_POS)
	game.call("spawn_city_car", TRUCK_NAME, TRUCK_PATH, LOAD_POS + Vector3(9, 0, 0), PI, {})
	_load_spot = LoadSpot.new()
	_load_spot.name = "LoadSpot"
	_load_spot.owner_m = self
	_load_spot.interact_radius = 8.0
	_load_spot.interact_priority = 10   # 压过「按 E 下车」：开车在货区刹停就该装货
	load_zone.add_child(_load_spot)
	_load_spot.mark_ready()   # 货区物件全部同步搭好（C2）
	_unload_spot = UnloadSpot.new()
	_unload_spot.name = "UnloadSpot"
	_unload_spot.owner_m = self
	_unload_spot.interact_radius = 9.0
	_unload_spot.interact_priority = 10
	unload_zone.add_child(_unload_spot)
	_unload_spot.mark_ready()
	if mod != null and mod.is_auth():
		broadcast()
	_refresh_visuals()


func leave() -> void:
	if _load_spot != null and is_instance_valid(_load_spot):
		_load_spot.owner_m = null
	if _unload_spot != null and is_instance_valid(_unload_spot):
		_unload_spot.owner_m = null
	_load_spot = null
	_unload_spot = null
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null
	_load_boxes.clear()
	_unload_boxes.clear()
	_bed_piles.clear()
	game = null


func tick(delta: float) -> void:
	if _result_t > 0.0:
		_result_t -= delta
	if _reset_t > 0.0:
		_reset_t -= delta
		if _reset_t <= 0.0:
			stock = TOTAL
			delivered = 0
			loaded_by.clear()
			contributors.clear()
			_reset_t = 0.0
			broadcast()


# ---------------------------------------------------------------- 交互条件（各端本地判）

func _driver() -> Node3D:
	if game == null:
		return null
	return game.call("get_driving") as Node3D


func _my_loaded() -> int:
	if mod == null:
		return 0
	return int((loaded_by.get(mod.my_id(), {}) as Dictionary).get("n", 0))


func _at_zone(car: Node3D, zone: Vector3, radius: float) -> bool:
	return _car_pos(car).distance_to(zone) <= radius


func can_load(_player_pos: Vector3) -> bool:
	if _reset_t > 0.0 or game == null or _load_spot == null:
		return false
	var car: Node3D = _driver()
	if car == null or not _stopped(car):
		return false
	if stock <= 0 or _my_loaded() > 0:
		return false
	return _at_zone(car, LOAD_POS, _load_spot.interact_radius)


func can_unload(_player_pos: Vector3) -> bool:
	if _reset_t > 0.0 or game == null or _unload_spot == null:
		return false
	var car: Node3D = _driver()
	if car == null or not _stopped(car):
		return false
	if _my_loaded() <= 0:
		return false
	return _at_zone(car, UNLOAD_POS, _unload_spot.interact_radius)


func load_prompt_text() -> String:
	return "%s ｜ %d/%d" % [tr("按 E 装货"), stock, TOTAL]


func unload_prompt_text() -> String:
	return "%s ｜ %d %s" % [tr("按 E 卸货"), _my_loaded(), tr("箱")]


## 按 E：host/单机直接结算，客机把意图（带车名，只作显隐用）发给 host
func do_load() -> void:
	var car: Node3D = _driver()
	if car == null or mod == null:
		return
	if mod.is_auth():
		server_intent(0, mod.my_id(), String(car.name))
	else:
		mod.rpc_id(1, "_rpc_cargo_intent", 0, String(car.name))


func do_unload() -> void:
	var car: Node3D = _driver()
	if car == null or mod == null:
		return
	if mod.is_auth():
		server_intent(1, mod.my_id(), String(car.name))
	else:
		mod.rpc_id(1, "_rpc_cargo_intent", 1, String(car.name))


# ---------------------------------------------------------------- host 权威结算

func server_intent(kind: int, who: int, car_name: String) -> void:
	if kind == 0:
		if stock <= 0 or loaded_by.has(who):
			return
		var n: int = mini(CAP, stock)
		stock -= n
		loaded_by[who] = {"n": n, "car": car_name}
	else:
		var entry: Dictionary = loaded_by.get(who, {}) as Dictionary
		var have: int = int(entry.get("n", 0))
		if have <= 0:
			return
		loaded_by.erase(who)
		delivered += have
		if not contributors.has(who):
			contributors.append(who)
		var bus: Node = mod.bus()
		if bus != null:
			bus.coin_earn.emit(who, PAY_UNLOAD, "cargo_unload")
		if delivered >= TOTAL:
			for c in contributors:
				bus.coin_earn.emit(int(c), PAY_DONE, "cargo_finale")
			_result = "%s %d ｜ %s +%d %s" % [tr("货场全部交付"), TOTAL, tr("参与者每人"), PAY_DONE, tr("币")]
			_result_t = 12.0
			_reset_t = 12.0
	broadcast()


func server_peer_left(who: int) -> void:
	if not loaded_by.has(who):
		return
	stock += int((loaded_by[who] as Dictionary).get("n", 0))
	loaded_by.erase(who)
	broadcast()


func broadcast() -> void:
	if mod == null:
		return
	mod.broadcast_cargo(stock, delivered, loaded_by.duplicate(true), contributors.duplicate())


## host/客机统一落地入口（RPC 与本地直调都走这）
func apply_state(s: int, d: int, lb: Dictionary, contr: Array) -> void:
	stock = s
	delivered = d
	loaded_by = lb
	contributors = contr
	_refresh_visuals()
	if mod != null:
		mod.emit_cargo_progress(delivered, TOTAL)


# ---------------------------------------------------------------- 视觉（纯显隐）

func _make_zone(pos: Vector3, color: Color, caption: String) -> Node3D:
	var zone := Node3D.new()
	zone.name = caption
	zone.position = pos
	_root.add_child(zone)
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(14, 10)
	mi.mesh = pm
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = m
	zone.add_child(mi)
	mi.position = Vector3(0, 0.06, 0)
	var tag := Label3D.new()
	tag.text = caption
	tag.position = Vector3(0, 3.0, 0)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 56
	tag.outline_size = 10
	tag.modulate = Color(color.r, color.g, color.b, 1.0)
	zone.add_child(tag)
	return zone


## 24 箱一堆：4 列 x 6 行。先 add_child 进树再测量缩放（4.7 量 AABB 的树内前提）
func _make_pile(center: Vector3) -> Array:
	var boxes: Array = []
	if _box_sc == null:
		return boxes
	var i: int = 0
	while i < TOTAL:
		var b: Node3D = _box_sc.instantiate() as Node3D
		var col: int = i % 4
		var row: int = int(i / 4)
		b.position = center + Vector3(float(col - 1) * 1.5 - 0.75, 0.0, float(row - 2) * 1.5)
		_root.add_child(b)
		_fit_box(b)   # 树内测量（4.7 量 AABB 前提）
		boxes.append(b)
		i += 1
	return boxes


func _fit_box(b: Node3D) -> void:
	var box: AABB = _world_aabb(b)
	var ext: float = maxf(box.size.x, maxf(box.size.y, box.size.z))
	if ext <= 0.001:
		return
	b.scale *= Vector3.ONE * (BOX_SIZE / ext)
	var box2: AABB = _world_aabb(b)
	b.global_position += Vector3(0, -box2.position.y, 0)   # 底沿贴地（货区地面恒平 y=0）


func _world_aabb(n: Node) -> AABB:
	var list: Array = []
	_collect(n, list)
	if list.is_empty():
		return AABB(Vector3.ZERO, Vector3.ZERO)
	var box: AABB = list[0]
	var i: int = 1
	while i < list.size():
		box = box.merge(list[i])
		i += 1
	return box


func _collect(n: Node, list: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null and n.is_inside_tree():
		var g: AABB = (n as MeshInstance3D).global_transform * (n as MeshInstance3D).mesh.get_aabb()
		if g.size.length() > 0.0001:
			list.append(g)
	for c in n.get_children():
		_collect(c, list)


func _refresh_visuals() -> void:
	var i: int = 0
	while i < _load_boxes.size():
		(_load_boxes[i] as Node3D).visible = i < stock
		i += 1
	var j: int = 0
	while j < _unload_boxes.size():
		(_unload_boxes[j] as Node3D).visible = j < delivered
		j += 1
	# 车斗货箱：先给 loaded_by 里每台车补齐货堆，再整表统一显隐——
	# loaded_by 里没有的人必须整堆藏掉，否则卸完货车斗复制品永远挂着。
	for who in loaded_by.keys():
		if _bed_piles.has(int(who)) and is_instance_valid(_bed_piles[int(who)]):
			continue
		var entry: Dictionary = loaded_by[who] as Dictionary
		var car: Node = _car_by_name(String(entry["car"]))
		if car == null:
			continue
		var pile: Node3D = _make_bed_pile(car, int(who))
		if pile != null:
			_bed_piles[int(who)] = pile
	for wk in _bed_piles.keys():
		var pl: Node3D = _bed_piles[wk] as Node3D
		if pl == null or not is_instance_valid(pl):
			continue
		var ent: Dictionary = loaded_by.get(int(wk), {}) as Dictionary
		var n: int = int(ent.get("n", 0))
		var k: int = 0
		while k < pl.get_child_count():
			(pl.get_child(k) as Node3D).visible = k < n
			k += 1


func _car_by_name(car_name: String) -> Node:
	if game == null or car_name == "":
		return null
	return game.find_child(car_name, true, false)


## 车斗 6 个箱位：不用 glb（车在动，树外测量不可靠），纯色 BoxMesh 一步到位
func _make_bed_pile(car: Node, who: int) -> Node3D:
	var container: Node3D = (car as Node).get_node_or_null("Container") as Node3D
	if container == null:
		return null
	var pile := Node3D.new()
	pile.name = "BedBoxes_%d" % who
	container.add_child(pile)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#b98b53")
	var i: int = 0
	while i < CAP:
		var b := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.05, 0.85, 1.15)
		b.mesh = bm
		b.material_override = mat
		var col: int = i % 2
		var row: int = int(i / 2)
		b.position = Vector3(float(col) * 1.15 - 0.575, 1.05, float(row - 1) * 1.3)
		pile.add_child(b)
		i += 1
	return pile


# ---------------------------------------------------------------- HUD

func hud_line() -> String:
	if _result_t > 0.0 and _result != "":
		return _result
	if game == null:
		return ""
	return "%s %d/%d ｜ %s %d" % [tr("合作运货：已交付"), delivered, TOTAL, tr("本车已装"), _my_loaded()]
