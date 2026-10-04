extends Node
## modules/economy —— 金币钱包 + 车行商店 + 角色能力（#20，DESIGN_coins_taxi_cargo.md §2-A / §8）
##
## 契约：
##   * 钱包唯一真源在本模块。别的模块只发 EventBus 事件：
##       coin_earn / coin_spend（意图）→ 权威端（host 或单机）落地
##       coins_changed（结果广播）→ HUD/存档订阅
##   * 联机铁律：只有 host 能改数；客机改动一律走 _rpc_buy_intent 上报，
##     host 校验后 _rpc_snapshot 全量广播。
##   * 单人持久化：user://save.cfg（拍板：联机局也由 host 写同一份）。
##
## 4.7 坑（沿用 MEMORY）：无 `..` 区间语法；OfflineMultiplayerPeer 自称 CONNECTED，
## _net_on() 必须排掉；queue_free 是延迟删除，清空子节点必须 remove_child + queue_free。

const SHOP_POS := Vector3(92, 0, 128)
const LOT_Z := 134.0
const SLOT_DX := 6.5
const SAVE_PATH := "user://save.cfg"

## 车辆货架：买断制，底盘差异直接写街机参数（上车即生效）
##
## 【#36 按 #31 的新基准重标】原来这四条 stats 是 #31 提速之前抄下来的
## （max_speed 10.4~15.5 m/s），而 urban_game.spawn_city_car 会 car.set("max_speed", …)
## **覆盖**街机脚本里的默认 32.0 —— 结果花 1800 买的跑车只有 15.5，
## 比出生点那台免费起步车慢一半还多，经济闭环直接反向。
## 现在以 base 32.0 为锚拉开档次：便宜车慢但抓地稳（好开），贵车快但甩尾凶（难开）。
const CARS: Array = [
	{"id": "car_taxi", "name": "出租车", "path": "res://models/cars/taxi.glb",
		"price": 400, "stats": {"max_speed": 26.0, "engine_power": 1.0, "lateral_grip": 5.6}},
	{"id": "car_suv", "name": "SUV", "path": "res://models/cars/suv.glb",
		"price": 900, "stats": {"max_speed": 29.0, "engine_power": 1.05, "lateral_grip": 5.2}},
	{"id": "car_race", "name": "肌肉车", "path": "res://models/cars/race.glb",
		"price": 1200, "stats": {"max_speed": 36.0, "engine_power": 1.3, "lateral_grip": 4.6}},
	{"id": "car_sport", "name": "跑车", "path": "res://models/cars/sedan-sports.glb",
		"price": 1800, "stats": {"max_speed": 42.0, "engine_power": 1.45, "lateral_grip": 4.4}},
]
## 能力价目：索引 = 升到下一级所需的钱
const PRICE_SPEED: Array = [300, 600, 1200]
const PRICE_ARMOR: Array = [400, 800]
const SPEED_LV_MAX: int = 3
const ARMOR_LV_MAX: int = 2

var _bus: Node = null
var _wallet: Dictionary = {}       # peer_id -> int
var _owned: Array = []             # 已购车辆 id
var _abil: Dictionary = {"speed": 0, "armor": 0}
var _game: Node3D = null
var _world: Node3D = null          # 摊位（只在都市里显示）
var _panel: CanvasLayer = null
var _rows: VBoxContainer = null
var _hud: Label = null
var _spawned: Dictionary = {}      # 车 id -> 本端已 spawn 过
var _spot: ShopSpot = null
var _hb: float = 0.0               # host 快照心跳（晚进房的人靠它补数据）


class ShopSpot extends Interactable:
	var owner_mod: Node = null

	func can_interact(player_pos: Vector3) -> bool:
		if not (is_ready and is_interactable) or owner_mod == null:
			return false
		return owner_mod.spot_usable(player_pos)

	func get_prompt(_player_pos: Vector3) -> String:
		return tr("按 E 打开车行")

	func on_interact(_player_pos: Vector3) -> void:
		if owner_mod != null:
			owner_mod.open_panel()


func mod_setup(ctx: Node) -> void:
	_bus = ctx.get_node_or_null("EventBus")
	if _bus != null:
		_bus.coin_earn.connect(_on_coin_earn)
		_bus.coin_spend.connect(_on_coin_spend)
		_bus.vehicle_boarded.connect(_on_vehicle_boarded)
	_load_save()
	_build_world()
	_build_hud()
	_build_panel()
	print("[economy] 模块已挂上（金币 %d，已购车 %d）" % [_coins(_my_id()), _owned.size()])


# ---------------------------------------------------------------- 身份与权威

func _my_id() -> int:
	return multiplayer.get_unique_id()


func _net_on() -> bool:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return false
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## 权威端 = host；单机时 OfflineMultiplayerPeer 的 is_server() 为真，天然成立
func _is_auth() -> bool:
	return multiplayer.is_server()


func _coins(who: int) -> int:
	return int(_wallet.get(who, 0))


# ---------------------------------------------------------------- 金币事件

func _on_coin_earn(who: int, amount: int, _reason: String) -> void:
	if not _is_auth() or amount <= 0:
		return
	_wallet[who] = _coins(who) + amount
	_after_auth_change()


func _on_coin_spend(who: int, amount: int, _reason: String) -> void:
	if not _is_auth() or amount <= 0:
		return
	if _coins(who) < amount:
		push_warning("[economy] 余额不足，扣款被拒：%d < %d" % [_coins(who), amount])
		return
	_wallet[who] = _coins(who) - amount
	_after_auth_change()


## 权威端数据变了：刷 HUD、同步客机、存档
func _after_auth_change() -> void:
	_refresh_hud()
	if _is_auth():
		_save()
		if _net_on():
			rpc("_rpc_snapshot", _wallet.duplicate(true), _owned.duplicate(), _abil.duplicate(true))


@rpc("authority", "reliable")
func _rpc_snapshot(w: Dictionary, o: Array, a: Dictionary) -> void:
	# 客机收到全量：diff 出金币变化发事件，补 spawn 新购的车
	for k in w.keys():
		var who: int = int(k)
		var nv: int = int(w[k])
		var oldv: int = _coins(who)
		if nv != oldv:
			_wallet[who] = nv
			if _bus != null:
				_bus.coins_changed.emit(who, nv, nv - oldv)
	var gained: Array = []
	for cid in o:
		if not _owned.has(String(cid)):
			gained.append(String(cid))
	_owned = o
	_abil = a
	_refresh_hud()
	if _panel != null and _panel.visible:
		_rebuild_rows()
	for cid in gained:
		_spawn_owned_car(String(cid))


## 客机购买意图 → host 校验执行（身份只认信封上的 sender，不信自报）
@rpc("any_peer", "reliable")
func _rpc_buy_intent(kind: String, id: String) -> void:
	if not _is_auth():
		return
	var who: int = multiplayer.get_remote_sender_id()
	if who <= 0:
		return
	_do_buy(who, kind, id)


# ---------------------------------------------------------------- 购买

func _try_buy(kind: String, id: String) -> void:
	if _is_auth():
		_do_buy(_my_id(), kind, id)
	else:
		rpc_id(1, "_rpc_buy_intent", kind, id)


## kind: "car" | "speed" | "armor"
func _do_buy(who: int, kind: String, id: String) -> void:
	var price: int = 0
	match kind:
		"car":
			if _owned.has(id):
				return
			var cat: Dictionary = _car_cat(id)
			if cat.is_empty():
				return
			price = int(cat["price"])
		"speed":
			var lv: int = int(_abil.get("speed", 0))
			if lv >= SPEED_LV_MAX:
				return
			price = int(PRICE_SPEED[lv])
		"armor":
			var lva: int = int(_abil.get("armor", 0))
			if lva >= ARMOR_LV_MAX:
				return
			price = int(PRICE_ARMOR[lva])
		_:
			return
	if _coins(who) < price:
		push_warning("[economy] 买不起 %s/%s（要 %d，只有 %d）" % [kind, id, price, _coins(who)])
		return
	_wallet[who] = _coins(who) - price
	if _bus != null:
		_bus.coins_changed.emit(who, _coins(who), -price)
	match kind:
		"car":
			_owned.append(id)
		"speed":
			_abil["speed"] = int(_abil["speed"]) + 1
		"armor":
			_abil["armor"] = int(_abil["armor"]) + 1
	_after_auth_change()
	if kind == "car":
		# 客机自己走 snapshot 补 spawn；host/单机直接在这端出车
		_spawn_owned_car(id)


func _car_cat(id: String) -> Dictionary:
	for c in CARS:
		if String((c as Dictionary)["id"]) == id:
			return c
	return {}


# ---------------------------------------------------------------- 能力上车生效

func _on_vehicle_boarded(car_name: String) -> void:
	var car: Node = _car_by_name(car_name)
	if car == null:
		return
	car.set("ability_speed_mult", 1.0 + 0.10 * int(_abil.get("speed", 0)))
	car.set("armor_mult", 1.0 - 0.25 * int(_abil.get("armor", 0)))


func _car_by_name(car_name: String) -> Node:
	for c in get_tree().get_nodes_in_group("vehicles"):
		if c != null and String(c.name) == car_name:
			return c as Node
	return null


# ---------------------------------------------------------------- 已购车辆落地

func _slot_pos(idx: int) -> Vector3:
	var n: int = CARS.size()
	var x0: float = SHOP_POS.x - float(n - 1) * SLOT_DX * 0.5
	return Vector3(x0 + float(idx) * SLOT_DX, 0.0, LOT_Z)


func _spawn_owned_car(id: String) -> void:
	if _spawned.has(id) or _game == null:
		return
	var cat: Dictionary = _car_cat(id)
	if cat.is_empty():
		return
	var idx: int = 0
	for i in range(CARS.size()):
		if String((CARS[i] as Dictionary)["id"]) == id:
			idx = i
	var pos: Vector3 = _slot_pos(idx)
	var node_name: String = "ShopCar_" + id
	var car: Node3D = _game.call("spawn_city_car", node_name, String(cat["path"]), pos, PI, cat.get("stats", {})) as Node3D
	if car != null:
		_spawned[id] = true


func _spawn_all_owned() -> void:
	for id in _owned:
		_spawn_owned_car(String(id))


# ---------------------------------------------------------------- 场景侦测

func _process(delta: float) -> void:
	var cs: Node = get_tree().current_scene
	var g: Node3D = null
	if cs != null and String(cs.name) == "Urban":
		g = cs as Node3D
	if g != _game:
		_game = g
		_spawned.clear()
		if _world != null:
			_world.visible = _game != null
		if _game != null:
			_spawn_all_owned()
		elif _panel != null and _panel.visible:
			_close_panel()
	# host 心跳快照：晚进房的客机最多 3 秒拿到钱包/车库
	if _is_auth() and _net_on():
		_hb += delta
		if _hb >= 3.0:
			_hb = 0.0
			rpc("_rpc_snapshot", _wallet.duplicate(true), _owned.duplicate(), _abil.duplicate(true))


# ---------------------------------------------------------------- 摊位与世界物件

func _build_world() -> void:
	_world = Node3D.new()
	_world.name = "EconomyWorld"
	add_child(_world)
	_world.global_position = SHOP_POS
	var table := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.6, 1.1, 1.2)
	table.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#7a5b38")
	table.material_override = mat
	table.position = Vector3(0, 0.55, 0)
	_world.add_child(table)
	var sign_lbl := Label3D.new()
	sign_lbl.text = tr("车行")
	sign_lbl.position = Vector3(0, 2.5, 0)
	sign_lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sign_lbl.font_size = 72
	sign_lbl.outline_size = 12
	sign_lbl.modulate = Color("#ffd45e")
	_world.add_child(sign_lbl)
	_spot = ShopSpot.new()
	_spot.name = "ShopSpot"
	_spot.owner_mod = self
	_spot.interact_radius = 6.0
	_world.add_child(_spot)
	_spot.mark_ready()   # 摊位是本地同步搭的，模型即刻到位


func spot_usable(player_pos: Vector3) -> bool:
	if _game == null or (_panel != null and _panel.visible):
		return false
	if _game.call("get_driving") != null:
		return false
	return _world.global_position.distance_to(player_pos) <= _spot.interact_radius


# ---------------------------------------------------------------- 商店面板

func _build_panel() -> void:
	_panel = CanvasLayer.new()
	_panel.name = "ShopUI"
	_panel.layer = 6
	add_child(_panel)
	var dim := ColorRect.new()
	dim.color = Color(0.01, 0.02, 0.04, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(center)
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#10141c")
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(24)
	sb.border_color = Color(0.35, 0.42, 0.55)
	sb.set_border_width_all(2)
	box.add_theme_stylebox_override("panel", sb)
	box.custom_minimum_size = Vector2(430, 0)
	center.add_child(box)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	box.add_child(vb)
	var title := Label.new()
	title.text = tr("车行")
	title.add_theme_font_size_override("font_size", 26)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	_rows = vb
	_panel.visible = false


func _clear_rows() -> void:
	# 标题固定 0 号位，其余全是动态行。queue_free 是延迟删除，
	# 必须 remove_child 立刻摘出来，否则重建循环数不到头（4.7 坑）。
	var i: int = _rows.get_child_count() - 1
	while i >= 1:
		var c: Node = _rows.get_child(i)
		_rows.remove_child(c)
		c.queue_free()
		i -= 1


func _rebuild_rows() -> void:
	_clear_rows()
	var who: int = _my_id()
	var head := Label.new()
	head.text = tr("金币：%d") % _coins(who)
	head.add_theme_color_override("font_color", Color("#ffd45e"))
	_rows.add_child(head)
	_rows.add_child(_section_label(tr("—— 车辆 ——")))
	for cat in CARS:
		var d: Dictionary = cat
		var has_car: bool = _owned.has(String(d["id"]))
		var price: int = int(d["price"])
		var t: String
		if has_car:
			t = "%s ｜ %s" % [tr(String(d["name"])), tr("已购")]
		else:
			t = "%s ｜ %d %s" % [tr(String(d["name"])), price, tr("币")]
		var b := _row_button(t, (not has_car) and _coins(who) >= price)
		if not has_car:
			b.pressed.connect(_on_buy_car.bind(String(d["id"])))
		_rows.add_child(b)
	_rows.add_child(_section_label(tr("—— 角色能力 ——")))
	_rows.add_child(_ability_row(tr("驾驶训练（极速 +10%/级）"), int(_abil.get("speed", 0)),
		SPEED_LV_MAX, PRICE_SPEED, "speed"))
	_rows.add_child(_ability_row(tr("钣金强化（受伤 -25%/级）"), int(_abil.get("armor", 0)),
		ARMOR_LV_MAX, PRICE_ARMOR, "armor"))
	var close := _row_button(tr("关闭（Esc）"), true)
	close.pressed.connect(_close_panel)
	_rows.add_child(close)


func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color("#9fb0c8"))
	return l


func _ability_row(caption: String, lv: int, lv_max: int, prices: Array, kind: String) -> Button:
	var t: String
	var afford: bool = false
	if lv >= lv_max:
		t = "%s ｜ %s" % [caption, tr("已满级")]
	else:
		var price: int = int(prices[lv])
		afford = _coins(_my_id()) >= price
		t = "%s ｜ Lv%d→%d ｜ %d %s" % [caption, lv, lv + 1, price, tr("币")]
	var b := _row_button(t, afford)
	if afford:
		b.pressed.connect(_on_buy_ability.bind(kind))
	return b


func _on_buy_car(cid: String) -> void:
	_try_buy("car", cid)
	_rebuild_rows()


func _on_buy_ability(kind: String) -> void:
	_try_buy(kind, "")
	_rebuild_rows()


func _row_button(text: String, enabled: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.disabled = not enabled
	b.custom_minimum_size = Vector2(378, 38)
	return b


func open_panel() -> void:
	_rebuild_rows()
	_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close_panel() -> void:
	_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _input(event: InputEvent) -> void:
	if _panel != null and _panel.visible and event.is_action_pressed("ui_cancel"):
		_close_panel()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- HUD

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "EconomyHud"
	layer.layer = 4
	add_child(layer)
	_hud = Label.new()
	_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hud.offset_left = 16.0
	_hud.offset_top = 12.0
	_hud.add_theme_font_size_override("font_size", 22)
	_hud.add_theme_color_override("font_color", Color("#ffd45e"))
	_hud.add_theme_color_override("font_outline_color", Color("#10141c"))
	_hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hud)
	if _bus != null:
		_bus.coins_changed.connect(_on_coins_changed)
	_refresh_hud()


func _on_coins_changed(who: int, _total: int, _delta: int) -> void:
	if who == _my_id():
		_refresh_hud()


func _refresh_hud() -> void:
	if _hud == null:
		return
	_hud.text = "%s %d\n%s Lv%d ｜ %s Lv%d" % [
		tr("金币"), _coins(_my_id()),
		tr("驾驶训练"), int(_abil.get("speed", 0)),
		tr("钣金强化"), int(_abil.get("armor", 0))]


# ---------------------------------------------------------------- 存档（拍板：单人 user://save.cfg，host 写）

func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("economy", "coins", _coins(1))
	cf.set_value("garage", "owned", PackedStringArray(_owned))
	cf.set_value("ability", "speed", int(_abil.get("speed", 0)))
	cf.set_value("ability", "armor", int(_abil.get("armor", 0)))
	cf.save(SAVE_PATH)


func _load_save() -> void:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		_wallet[1] = 0
		return
	_wallet[1] = int(cf.get_value("economy", "coins", 0))
	var arr: PackedStringArray = cf.get_value("garage", "owned", PackedStringArray())
	_owned.clear()
	for s in arr:
		_owned.append(String(s))
	_abil["speed"] = int(cf.get_value("ability", "speed", 0))
	_abil["armor"] = int(cf.get_value("ability", "armor", 0))
