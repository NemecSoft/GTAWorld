extends Node
## modules/missions —— 出租车任务（单人）+ 合作运货（多人）（#20）
##
## 设计：docs/DESIGN_coins_taxi_cargo.md §3-A / §4-A。
## 职责切分：
##   * module.gd（本文件）：侦测都市场景、挂 HUD、承载全部 @rpc
##     （模块节点在两端的路径一致：/root/Modules/Mod_missions，RPC 按路径寻址成立）；
##   * taxi_mission.gd：纯逻辑 RefCounted，状态机 IDLE→COOLDOWN→HAILING→PICKED_UP→SETTLE；
##   * cargo_mission.gd：纯逻辑 RefCounted，host 权威计数 + 全量状态广播。
## 金币只发 EventBus 事件（coin_earn），由 economy 模块落地——模块间不互抓节点。
##
## 4.7 语法备忘：无 `..` 区间语法，循环一律 range(a, b + 1)。

const TaxiMission := preload("res://modules/missions/taxi_mission.gd")
const CargoMission := preload("res://modules/missions/cargo_mission.gd")
const DefenseMission := preload("res://modules/missions/defense_mission.gd")
const CARGO_HB := 4.0

var _bus: Node = null
var _game: Node3D = null
var _taxi: RefCounted = null
var _cargo: RefCounted = null
var _defense: RefCounted = null
var _info: Label = null
var _hb: float = 0.0


func mod_setup(ctx: Node) -> void:
	_bus = ctx.get_node_or_null("EventBus")
	_taxi = TaxiMission.new()
	_cargo = CargoMission.new()
	_defense = DefenseMission.new()
	_taxi.mod = self
	_cargo.mod = self
	_defense.mod = self
	multiplayer.peer_disconnected.connect(_on_peer_left)
	_build_hud()
	print("[missions] 模块已挂上（出租车 + 合作运货 + 守夜讨伐）")


# ---------------------------------------------------------------- 场景侦测

func _process(delta: float) -> void:
	var cs: Node = get_tree().current_scene
	var g: Node3D = null
	if cs != null and String(cs.name) == "Urban":
		g = cs as Node3D
	if g != _game:
		_game = g
		_taxi.leave()
		_cargo.leave()
		_defense.leave()
		if _game != null:
			_taxi.enter(_game)
			_cargo.enter(_game)
			_defense.enter(_game)
	if _game != null:
		_taxi.tick(delta)
		_cargo.tick(delta)
		_defense.tick(delta)
		_refresh_info()
	elif _info != null and _info.text != "":
		_info.text = ""
	# host 心跳：晚进房的人最多 4 秒对齐货区计数
	if _game != null and is_auth() and net_on():
		_hb += delta
		if _hb >= CARGO_HB:
			_hb = 0.0
			_cargo.broadcast()


func _refresh_info() -> void:
	_info.text = _taxi.hud_line() + "\n" + _cargo.hud_line() + "\n" + _defense.hud_line()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "MissionsHud"
	layer.layer = 4
	add_child(layer)
	_info = Label.new()
	_info.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_info.offset_top = 12.0
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_info.add_theme_font_size_override("font_size", 18)
	_info.add_theme_color_override("font_color", Color("#cfe3ff"))
	_info.add_theme_color_override("font_outline_color", Color("#10141c"))
	_info.add_theme_constant_override("outline_size", 5)
	layer.add_child(_info)


# ---------------------------------------------------------------- 子模块借用的公共口

func my_id() -> int:
	return multiplayer.get_unique_id()


func net_on() -> bool:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer is OfflineMultiplayerPeer:
		return false
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func is_auth() -> bool:
	return multiplayer.is_server()


func bus() -> Node:
	return _bus


func emit_mission_state(mid: String, st: String) -> void:
	if _bus != null:
		_bus.mission_state_changed.emit(mid, st)


func emit_cargo_progress(delivered: int, total: int) -> void:
	if _bus != null:
		_bus.cargo_progress_changed.emit(delivered, total)


func _on_peer_left(id: int) -> void:
	# 掉线回退货物是 host 的职责；客机跟着心跳快照对齐（设计 §4-A 坑②）
	if is_auth():
		_cargo.server_peer_left(id)


# ---------------------------------------------------------------- 运货 RPC
# kind: 0=装货 1=卸货。car_name 只用于各端显隐货箱，权威在计数不在名字。

@rpc("any_peer", "reliable")
func _rpc_cargo_intent(kind: int, car_name: String) -> void:
	if not is_auth():
		return
	var who: int = multiplayer.get_remote_sender_id()
	if who <= 0:
		return
	_cargo.server_intent(kind, who, car_name)


@rpc("authority", "reliable")
func _rpc_cargo_state(stock: int, delivered: int, loaded_by: Dictionary, contributors: Array) -> void:
	_cargo.apply_state(stock, delivered, loaded_by, contributors)


## host 推全量货况：联机走 RPC（各端 apply_state），单机直接本地应用
func broadcast_cargo(stock: int, delivered: int, loaded_by: Dictionary, contributors: Array) -> void:
	if net_on():
		rpc("_rpc_cargo_state", stock, delivered, loaded_by, contributors)
	else:
		_cargo.apply_state(stock, delivered, loaded_by, contributors)


# ---------------------------------------------------------------- 讨伐 RPC（#21）
# intent kind: 0=开枪(from=相机位,dir=视线) 1=近战(from=人物位,dir=朝向) 2=接任务 3=交付

@rpc("any_peer", "reliable")
func _rpc_defense_intent(kind: int, from: Vector3, dir: Vector3) -> void:
	if not is_auth():
		return
	var who: int = multiplayer.get_remote_sender_id()
	if who <= 0:
		return
	_defense.server_intent(who, kind, from, dir)


@rpc("authority", "reliable")
func _rpc_defense_state(phase: int, wave: int, deaths: int, hp: Dictionary, zs: Array) -> void:
	_defense.apply_state(phase, wave, deaths, hp, zs)


@rpc("authority", "reliable")
func _rpc_defense_respawn(who: int) -> void:
	_defense.local_respawn(who)


## host 推讨伐全量：rpc 不回首包，host 自己也要过一遍 apply_state（否则 host 看不见怪）
func broadcast_defense(phase: int, wave: int, deaths: int, hp: Dictionary, zs: Array) -> void:
	if net_on():
		rpc("_rpc_defense_state", phase, wave, deaths, hp, zs)
	_defense.apply_state(phase, wave, deaths, hp, zs)


func send_defense_respawn(who: int) -> void:
	if net_on():
		rpc("_rpc_defense_respawn", who)
	else:
		_defense.local_respawn(who)
