extends Node
## core/event_bus.gd —— 全局事件总线（autoload 名：EventBus）
##
## 模块化契约（总纲 §3.3）：
##   1. 任何模块之间**不许**用 get_nodes_in_group() 互抓节点，只能走这里的事件。
##   2. 事件名是字符串常量，写错只会在运行时报一次警告，不会拖垮整个游戏。
##   3. 事件只传**纯数据**（int / float / String / Vector3 / 枚举），不传 Node 引用，
##      这样断线重连、场景切换、模块热插拔都不会炸。
##
## 4.7 语法备忘：本 build 不支持 `..` 区间语法，循环一律写 range(a, b + 1)。

## ---- 常用信号（走 Godot 的静态信号，编辑器可跳定义、参数有类型检查）----
signal vehicle_spawned(owner_id: int, kind: String, pos: Vector3)
signal vehicle_destroyed(owner_id: int, kind: String, pos: Vector3)
signal actor_damaged(actor_id: int, amount: float, source_id: int)
signal actor_died(actor_id: int, faction: String)
signal heat_changed(actor_id: int, stars: int)
signal territory_captured(territory_id: int, faction: String)
signal unit_order_issued(squad_id: int, order_type: String, target_id: int)
signal unit_died(unit_id: int, faction: String)
signal phase_changed(phase: String)
signal session_mode_changed(mode: String)

## ---- #20 金币 / 任务 / 商店 ----
## 钱包变动（host 权威结算后广播给订阅者：HUD、存档）
signal coins_changed(who_id: int, total: int, delta: int)
## 任何模块想发钱/扣钱只许发这两个意图事件，由 economy 模块（权威端）落地
signal coin_earn(who_id: int, amount: int, reason: String)
signal coin_spend(who_id: int, amount: int, reason: String)
## 车辆最小伤害模型（vehicle_arcade 撞击时发；出租车任务订阅它算扣减）
signal vehicle_damaged(car_name: String, amount: float, health: float)
## 上下车通知（economy 借此把能力倍率写到刚上手的车上）
signal vehicle_boarded(car_name: String)
## 任务状态机 / 运货进度（missions 模块发，HUD 订阅）
signal mission_state_changed(mission_id: String, state: String)
signal cargo_progress_changed(delivered: int, total: int)

## ---- 通用事件通道 ----
## 给还没确定的模块用：按名字 connect / emit，避免到处 new Signal。
## 注意：字符串拼错只在运行时警告一次，不会拖垮游戏（模块化要的就是这个隔离）。
func emit_event(name: String, args: Array = []) -> void:
	if not has_signal(name):
		push_warning("[EventBus] 未知事件：%s（参数 %d 个）" % [name, args.size()])
		return
	emit_signal(name, args)


func connect_event(name: String, callable: Callable) -> void:
	if not has_signal(name):
		push_warning("[EventBus] 连接失败，未知事件：%s" % name)
		return
	if not callable.is_valid():
		push_warning("[EventBus] 连接目标已失效：%s" % name)
		return
	# SIGNAL_ONE_SHOT 用不上，默认多次触发；重复连接 Godot 会自动忽略
	var sig := Signal(self, name)
	for c in sig.get_connections():
		if c.callable == callable:
			return
	sig.connect(callable)


func known_events() -> Array:
	var out: Array = []
	for s in get_signal_list():
		out.append(String(s["name"]))
	out.sort()
	return out


func emit_vehicle_spawned(owner_id: int, kind: String, pos: Vector3) -> void:
	vehicle_spawned.emit(owner_id, kind, pos)
