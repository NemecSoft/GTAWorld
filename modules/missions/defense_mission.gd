extends "res://modules/missions/mission_base.gd"
## modules/missions/defense_mission.gd —— 守夜讨伐：僵尸/妖怪波次防守（#21，设计 §3/§4）
##
## 循环：告示板接任务 → 天色压暗(4s) → 5 波怪 [4,6,8,10,12] → 每波全灭得 100×波号金币
##       → 全清天亮 → 回板交付 +1000；全队阵亡 3 次 = 任务失败（天亮清怪、每人扣 100）。
## 网络：全部 host 权威（同 #20 铁律）。客机只发意图（开枪 from+dir / 近战 / 交互），
##       host 判命中与咬伤，10Hz `_rpc_defense_state` 下发僵尸数组 + 血量表；
##       两端共用同一个 apply_state 建/删/挪「复制品」（host 联机时也要本地过一遍，
##       否则 rpc 不回首包，host 自己看不见怪）。
## 僵尸是无物理的纯运动学实体：位置由 ground_height + 形状查询避墙推进，
##       命中用数学射线（点到射线距离），不吃碰撞层。
## 坑（设计 §6）：graveyard GLB 动画可能带根位移 → 每帧把内层模型 x/z 归零，世界位置只写外节点；
##       昼夜压暗必须先 duplicate 环境，绝不让共享 main-environment.tres 变脏。
## 4.7 坑：无 `..`；tr("%d") 用 % 不用 .arg()。

const PHASES: Array = ["BOARD", "DUSK", "BREAK", "WAVE", "DAWN", "DELIVER", "FAIL", "COOLDOWN"]
const WAVES: Array = [4, 6, 8, 10, 12]
const KIND_PATHS: Array = [
	"res://models/characters/graveyard/character-zombie.glb",
	"res://models/characters/graveyard/character-skeleton.glb",
	"res://models/characters/graveyard/character-ghost.glb",
	"res://models/characters/graveyard/character-vampire.glb",
]
const KIND_SPEED: Array = [2.2, 2.6, 3.4, 3.0]
const KIND_POOL: Array = [[0, 1], [0, 1], [0, 1, 3], [0, 1, 2, 3], [0, 2, 3]]

const BOARD_POS := Vector3(100, 0, 122)
const HP_MAX := 100.0
const REGEN := 8.0
const REGEN_DELAY := 6.0
const GUN_DMG := 40.0
const GUN_CD := 0.35
const GUN_RANGE := 40.0
const GUN_HIT_R := 0.75   # v1.5：第三人称相机有视差（机位在人物后上方），
                          # 准星瞄得正 ≠ 射线贴得近，判定半径要比纯第一人称放宽
const GUN_SPREAD := 0.012  # 每发随机散布（Starter-Kit-FPS weapon.spread 思路）
const GUN_KNOCK := 0.55    # 中弹击退（demo knockback 思路，host 权威位移）
const MELEE_DMG := 55.0
const MELEE_CD := 0.7
const MELEE_R := 2.4
const ZHP := 100.0
const BITE_DMG := 12.0
const BITE_CD := 1.1
const BITE_R := 1.35
const Z_HEIGHT := 1.7
const DUSK_T := 4.0
const WAVE_GAP := 3.0
const COOLDOWN_T := 20.0
const FAIL_DEATHS := 3
const PAY_WAVE_BASE := 100
const PAY_DELIVER := 1000
const PAY_FAIL_CUT := 100
const GUN_PATH := "res://models/weapons/blaster-a.glb"
# 照抄 Starter-Kit-FPS：准星贴图 + 枪口火光（burst.png 两张 256×256 帧）
const CROSSHAIR_PATH := "res://assets/kenney-fps/crosshair.png"
const BURST_PATH := "res://assets/kenney-fps/burst.png"
const Z_ATK_ANIM_T := 0.6  # 咬人后「攻击动画」窗口（秒），随状态包下发

var _phase: String = "BOARD"
var _wave: int = 0
var _deaths: int = 0
var _t: float = 0.0
var _next_eid: int = 1
var _zombies: Dictionary = {}       # host: eid -> {pos,yaw,hp,kind,atk,walk}
var _hp: Dictionary = {}            # peer_id -> float
var _no_hit_t: Dictionary = {}      # peer_id -> float（脱战回血计时）
var _views: Dictionary = {}         # eid -> {node,...}（两端共用的复制品）
var _board: Node3D = null
var _spot: DefenseSpot = null
var _gun: Node3D = null
var _skel: Skeleton3D = null      # 本地玩家骨架（枪模手写同步用）
var _hand_bone: int = -1          # RightHand 骨索引
var _kick: float = 0.0              # 枪械后坐
var _lunge: float = 0.0             # 近战前扑
var _rng := RandomNumberGenerator.new()
var _result: String = ""
var _result_t: float = 0.0
var _night: float = 0.0             # 0=白昼 1=黑夜（两端按阶段码各自缓插）
var _sun: DirectionalLight3D = null
var _we: WorldEnvironment = null
var _env: Environment = null
var _env_shared: Environment = null
var _base := {}                     # 昼夜起点值缓存
var _snd: Dictionary = {}
var _last_gun: float = -9.0
var _last_melee: float = -9.0
var _sent_code: int = -1            # 上次同步的阶段码（阶段一变必补发一包，防客机卡旧阶段）
var _sync_t: float = 0.0            # 10Hz 状态包节流（单机/联机同一节奏）
var _combat_prev: bool = false      # 上一帧玩家是否处于战斗姿态（边沿触发才写 set_combat_mode）
var _ui: CanvasLayer = null         # 准星 + 受击红闪（Starter-Kit-FPS 反馈层）
var _cross: Control = null
var _flash: ColorRect = null


class DefenseSpot extends Interactable:
	var owner_m: RefCounted = null

	func can_interact(player_pos: Vector3) -> bool:
		if not (is_ready and is_interactable) or owner_m == null:
			return false
		return owner_m.can_board(player_pos)

	func get_prompt(_player_pos: Vector3) -> String:
		return owner_m.board_prompt()

	func on_interact(_player_pos: Vector3) -> void:
		if owner_m != null:
			owner_m.interact_local()


# ---------------------------------------------------------------- 生命周期

func enter(g: Node3D) -> void:
	leave()
	game = g
	if game == null or mod == null:
		return
	_rng.seed = 20261021
	_phase = "BOARD"
	_wave = 0
	_deaths = 0
	_t = 0.0
	_night = 0.0
	_sent_code = -1
	_build_board()
	_build_combat_ui()
	_cache_daynight()


func leave() -> void:
	_phase = "BOARD"
	_result = ""
	_result_t = 0.0
	_zombies.clear()
	_hp.clear()
	_no_hit_t.clear()
	_sent_code = -1
	if _spot != null and is_instance_valid(_spot):
		_spot.owner_m = null
	_spot = null
	if _board != null and is_instance_valid(_board):
		_spot = null
		# 必须先 remove_child 再 queue_free：否则同帧重建会撞名被引擎改名成 @N
		if _board.get_parent() != null:
			_board.get_parent().remove_child(_board)
		_board.queue_free()
	_board = null
	_clear_views()
	var pl: Node3D = _find_player()
	if pl != null and pl.has_method("set_combat_mode"):
		pl.call("set_combat_mode", false)
	_combat_prev = false
	_detach_gun()
	if _ui != null and is_instance_valid(_ui):
		_ui.get_parent().remove_child(_ui)
		_ui.free()
	_ui = null
	_cross = null
	_flash = null
	if _we != null and _env_shared != null:
		_we.environment = _env_shared
	_we = null
	_env = null
	_env_shared = null
	_sun = null
	game = null
	state = "OFF"


func tick(delta: float) -> void:
	if game == null or mod == null:
		return
	if _cross != null and is_instance_valid(_cross):
		_cross.visible = _combat_open()
	var plt: Node3D = _find_player()
	if plt != null and plt.has_method("set_combat_mode"):
		var co: bool = _combat_open()
		# 只在进出战斗的一刻切换，不每帧覆写：否则外部（探针/其它系统）设的姿态会被抹掉
		if co != _combat_prev:
			_combat_prev = co
			plt.call("set_combat_mode", co)
	_input_attacks()
	_night_logic(delta)
	_result_t -= delta
	_kick = maxf(_kick - delta * 6.0, 0.0)
	_lunge = maxf(_lunge - delta * 4.0, 0.0)
	if _gun != null and is_instance_valid(_gun):
		_sync_gun()
	if _lunge > 0.001:
		var pl: Node3D = _find_player()
		var mp: Node3D = pl.get("model_pivot") as Node3D
		if mp != null:
			mp.rotation.x = 0.3 * _lunge
	elif _find_player() != null:
		var mp2: Node3D = _find_player().get("model_pivot") as Node3D
		if mp2 != null:
			mp2.rotation.x = 0.0
	if mod.is_auth():
		server_tick(delta)
	_tick_views(delta)


func _input_attacks() -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	if Input.is_action_just_pressed("attack_gun") and now - _last_gun >= GUN_CD:
		try_shoot()
	if Input.is_action_just_pressed("attack_melee") and now - _last_melee >= MELEE_CD:
		try_melee()


# ---------------------------------------------------------------- host 权威模拟

func server_tick(delta: float) -> void:
	match _phase:
		"DUSK":
			_t -= delta
			if _t <= 0.0:
				server_spawn_wave()
		"BREAK":
			_t -= delta
			if _t <= 0.0:
				server_spawn_wave()
		"WAVE":
			_sim_zombies(delta)
			_regen(delta)
			if _zombies.is_empty():
				_earn(PAY_WAVE_BASE * (_wave + 1), "defense_wave")
				_result = "%s %d/%d +%d %s" % [tr("击退"), _wave + 1, WAVES.size(),
					PAY_WAVE_BASE * (_wave + 1), tr("金币")]
				_result_t = 5.0
				if _wave + 1 >= WAVES.size():
					_set_phase("DAWN")
					_t = DUSK_T
				else:
					_wave += 1
					_set_phase("BREAK")
					_t = WAVE_GAP
		"DAWN":
			_regen(delta)
			_t -= delta
			if _t <= 0.0:
				_set_phase("DELIVER")
		"COOLDOWN":
			_t -= delta
			if _t <= 0.0:
				_set_phase("BOARD")
		_:
			pass
	# 【坑·v1.5】以前只在「联机 或 阶段变化」时发包：单机复制品位置冻结在
	# 刷怪点、阶段一变整群瞬移（用户反馈「怪物到处跳」）。一律 10Hz 同步。
	_sync_t += delta
	if _sync_t >= 0.1 or _phase_code() != _sent_code:
		_sync_t = 0.0
		mod.broadcast_defense(_phase_code(), _wave, _deaths, _hp, _sync_zs())


func _set_phase(p: String) -> void:
	_phase = p


func _sim_zombies(delta: float) -> void:
	for eid in _zombies.keys():
		# 咬人可能触发失败清场（server_fail 会 clear），keys() 是快照，旧 eid 要先跳过
		if not _zombies.has(eid):
			continue
		var z: Dictionary = _zombies[eid]
		z["atka"] = maxf(float(z["atka"]) - delta, 0.0)
		var tgt: Dictionary = _nearest_target(z["pos"] as Vector3)
		var tp: Vector3 = tgt["pos"] as Vector3
		var to: Vector3 = tp - (z["pos"] as Vector3)
		to.y = 0.0
		var dist: float = to.length()
		var sp: float = float(KIND_SPEED[int(z["kind"])])
		if dist > 0.35:
			var dir: Vector3 = to / dist
			var old: Vector3 = z["pos"] as Vector3
			var moved: Array = _steer(old, dir, sp * delta)
			z["pos"] = moved[0]
			z["yaw"] = atan2((moved[1] as Vector3).x, (moved[1] as Vector3).z)
			z["walk"] = (moved[0] as Vector3) != old
		else:
			z["walk"] = false
		# 咬人：只咬步行状态的人
		if bool(tgt["foot"]) and dist <= BITE_R:
			var atk: float = float(z["atk"]) - delta
			if atk <= 0.0:
				z["atk"] = BITE_CD
				z["atka"] = Z_ATK_ANIM_T   # 开咬 → 攻击动画窗口（复制品据此播 attack 片段）
				server_damage(int(tgt["who"]), BITE_DMG)
			else:
				z["atk"] = atk
		else:
			z["atk"] = 0.35


## 向前推进；被墙挡住就左右 ±52°/±109° 绕。返回 [新位置, 实际朝向]
func _steer(pos: Vector3, dir: Vector3, step: float) -> Array:
	var cands: Array = [dir,
		Basis(Vector3.UP, 0.9) * dir, Basis(Vector3.UP, -0.9) * dir,
		Basis(Vector3.UP, 1.9) * dir, Basis(Vector3.UP, -1.9) * dir]
	for c in cands:
		var d: Vector3 = c as Vector3
		var nxt: Vector3 = pos + d * step
		var gy: float = _ground_y(nxt.x, nxt.z)
		if not _blocked(Vector3(nxt.x, gy + 0.9, nxt.z)):
			nxt.y = gy
			return [nxt, d]
	return [pos, dir]


func _blocked(p: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.4
	q.shape = sh
	q.transform = Transform3D(Basis.IDENTITY, p)
	q.collision_mask = 11
	return space.intersect_shape(q, 1).size() > 0


## 离僵尸最近的玩家：{pos, who, foot}。#19 铁律：开车态取被驾车真实位置。
func _nearest_target(from: Vector3) -> Dictionary:
	var best: Dictionary = {}
	for idv in _hp.keys():
		var who: int = int(idv)
		var foot: bool = true
		var p: Vector3 = Vector3.ZERO
		var found: bool = false
		if who == mod.my_id():
			var pl: Node3D = _find_player()
			if pl != null:
				var car: Node3D = game.call("get_driving") as Node3D
				if car != null:
					p = _car_pos(car)
					foot = false
				else:
					p = pl.global_position
				found = true
		else:
			var av: Node3D = game.get_node_or_null("Peer%d" % who) as Node3D
			if av != null:
				p = av.global_position
				found = true
		if found and (best.is_empty() or p.distance_squared_to(from) <
				(best["pos"] as Vector3).distance_squared_to(from)):
			best = {"pos": p, "who": who, "foot": foot}
	if best.is_empty():
		best = {"pos": from, "who": mod.my_id(), "foot": true}
	return best


func server_damage(who: int, amt: float) -> void:
	if _phase != "DUSK" and _phase != "BREAK" and _phase != "WAVE" and _phase != "DAWN":
		return
	var hp: float = float(_hp.get(who, HP_MAX)) - amt
	_no_hit_t[who] = 0.0
	if hp <= 0.0:
		hp = HP_MAX
		_deaths += 1
		_result = "%s（%d/%d）" % [tr("阵亡，已在告示板旁复活"), _deaths, FAIL_DEATHS]
		_result_t = 5.0
		if _deaths >= FAIL_DEATHS:
			server_fail()
			return
		# 【坑·v1.5】这句以前在 if 外面：被咬一扣血就把人整台瞬回告示板，
		# 用户反馈「人物一碰撞就瞬移」——只有真正阵亡才该传送。
		mod.send_defense_respawn(who)
	_hp[who] = hp


func local_respawn(who: int) -> void:
	if game == null or who != mod.my_id():
		return
	var car: Node3D = game.call("get_driving") as Node3D
	if car != null:
		game.call("exit_vehicle")
	var pl: Node3D = _find_player()
	if pl == null:
		return
	pl.global_position = BOARD_POS + Vector3(0, 0.05, 3)
	pl.set("velocity", Vector3.ZERO)


func server_fail() -> void:
	_zombies.clear()
	_spend(PAY_FAIL_CUT, "defense_fail")
	_result = tr("讨伐失败：僵尸淹没了街道")
	_result_t = 6.0
	_set_phase("COOLDOWN")
	_t = COOLDOWN_T
	mod.emit_mission_state("defense", "fail")


func _regen(delta: float) -> void:
	for who in _hp.keys():
		var w: int = int(who)
		var t: float = float(_no_hit_t.get(w, 99.0)) + delta
		_no_hit_t[w] = t
		if t >= REGEN_DELAY:
			_hp[w] = minf(float(_hp[w]) + REGEN * delta, HP_MAX)


# ---------------------------------------------------------------- 波次与结算

func server_accept() -> void:
	if _phase != "BOARD" or not mod.is_auth():
		return
	for p in _payees():
		_hp[int(p)] = HP_MAX
		_no_hit_t[int(p)] = 99.0
	_wave = 0
	_deaths = 0
	_set_phase("DUSK")
	_t = DUSK_T
	mod.emit_mission_state("defense", "accepted")


func server_deliver() -> void:
	if _phase != "DELIVER" or not mod.is_auth():
		return
	_earn(PAY_DELIVER, "defense")
	_result = "%s +%d %s" % [tr("交付讨伐"), PAY_DELIVER, tr("金币")]
	_result_t = 6.0
	_set_phase("COOLDOWN")
	_t = COOLDOWN_T
	mod.emit_mission_state("defense", "delivered")


func server_spawn_wave() -> void:
	_plug_holes()
	var n: int = int(WAVES[_wave])
	var pool: Array = KIND_POOL[mini(_wave, KIND_POOL.size() - 1)]
	var pl: Node3D = _find_player()
	var origin: Vector3 = pl.global_position if pl != null else BOARD_POS
	for i in range(n):
		var spot: Vector3 = _ring_point(origin)
		var kind: int = int(pool[_rng.randi_range(0, pool.size() - 1)])
		_zombies[_next_eid] = {
			"pos": spot, "yaw": _rng.randf_range(0.0, TAU), "hp": ZHP,
			"kind": kind, "atk": 0.5, "walk": false, "atka": 0.0,
		}
		_next_eid += 1
	_set_phase("WAVE")
	mod.emit_mission_state("defense", "wave_%d" % (_wave + 1))


func _plug_holes() -> void:
	for p in _payees():
		if not _hp.has(int(p)):
			_hp[int(p)] = HP_MAX
			_no_hit_t[int(p)] = 99.0


func _ring_point(origin: Vector3) -> Vector3:
	for i in range(12):
		var a: float = _rng.randf_range(0.0, TAU)
		var r: float = _rng.randf_range(55.0, 85.0)
		var p: Vector3 = origin + Vector3(cos(a) * r, 0.0, sin(a) * r)
		p.x = clampf(p.x, -150.0, 150.0)
		p.z = clampf(p.z, -150.0, 150.0)
		p.y = _ground_y(p.x, p.z) + 0.05
		if not _blocked(Vector3(p.x, p.y + 0.9, p.z)):
			return p
	return origin + Vector3(60.0, _ground_y(origin.x + 60.0, origin.z) + 0.05, 0.0)


func _payees() -> Array:
	if mod.net_on():
		var ids: Array = [1]
		for p in game.get_tree().get_multiplayer().get_peers():
			ids.append(int(p))
		return ids
	return [mod.my_id()]


func _earn(amount: int, reason: String) -> void:
	var bus: Node = mod.bus()
	if bus == null:
		return
	for p in _payees():
		bus.coin_earn.emit(int(p), amount, reason)


func _spend(amount: int, reason: String) -> void:
	var bus: Node = mod.bus()
	if bus == null:
		return
	for p in _payees():
		bus.coin_spend.emit(int(p), amount, reason)


# ---------------------------------------------------------------- 攻击（本地输入 → 意图/host 判定）

func try_shoot() -> void:
	if not _combat_open():
		return
	_last_gun = Time.get_ticks_msec() / 1000.0
	_attach_gun()
	var pl: Node3D = _find_player()
	if pl != null and pl.has_method("play_shoot"):
		pl.call("play_shoot")   # v1.5 烘焙自动画：举枪射击一次性片段
	var cam: Camera3D = pl.get("camera") as Camera3D
	# 准星射线 + 随机散布（Starter-Kit-FPS：spread 在发射端抖方向，不在判定端）
	var dir: Vector3 = (-cam.global_transform.basis.z
		+ Vector3(randfn(0.0, 1.0), randfn(0.0, 1.0), randfn(0.0, 1.0)) * GUN_SPREAD).normalized()
	if mod.is_auth():
		server_gun(mod.my_id(), cam.global_position, dir)
	else:
		mod.rpc_id(1, "_rpc_defense_intent", 0, cam.global_position, dir)
	_play_gun_fx(dir)


## 开枪三件套（Starter-Kit-FPS：muzzle.play + container/相机 knockback）
## 本项目是第三人称：火光挂在枪口前方的视线方向上，镜头轻微上跳由玩家自己压枪。
func _muzzle_flash(dir: Vector3) -> void:
	if _gun == null or not is_instance_valid(_gun):
		return
	var tex: Texture2D = load(BURST_PATH) as Texture2D
	if tex == null:
		return
	var spr := Sprite3D.new()
	spr.name = "MuzzleFx"
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	# burst.png 是 512×256 两帧图集（demo burst_animation.tres：0/256 起各 256×256）
	atlas.region = Rect2(float(_rng.randi_range(0, 1)) * 256.0, 0.0, 256.0, 256.0)
	spr.texture = atlas
	spr.shaded = false
	spr.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	spr.pixel_size = 0.0035
	spr.scale = Vector3.ONE * _rng.randf_range(0.7, 1.2)
	spr.rotation = Vector3(0.0, 0.0, _rng.randf_range(-0.8, 0.8))
	game.add_child(spr)
	spr.global_position = _gun.global_position + dir * 0.32
	var tw: Tween = game.create_tween()
	tw.tween_property(spr, "modulate:a", 0.0, 0.1)
	tw.tween_callback(spr.queue_free)


func _play_gun_fx(dir: Vector3) -> void:
	_kick = 1.0
	_sfx("res://assets/sounds/combat/blaster.ogg")
	_muzzle_flash(dir)
	var pl: Node3D = _find_player()
	if pl != null:
		var p: float = float(pl.get("_pitch"))
		pl.set("_pitch", clampf(p + _rng.randf_range(0.008, 0.016), -1.2, 0.6))


func try_melee() -> void:
	if not _combat_open():
		return
	_last_melee = Time.get_ticks_msec() / 1000.0
	var pl: Node3D = _find_player()
	var fwd: Vector3 = -(pl.get("yaw_pivot") as Node3D).global_transform.basis.z
	fwd.y = 0.0
	if mod.is_auth():
		server_melee(mod.my_id(), pl.global_position, fwd.normalized())
	else:
		mod.rpc_id(1, "_rpc_defense_intent", 1, pl.global_position, fwd.normalized())
	_play_melee_fx()


func _combat_open() -> bool:
	if game == null or mod == null:
		return false
	if _phase != "WAVE" and _phase != "DUSK" and _phase != "BREAK" and _phase != "DAWN":
		return false
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return false
	if game.call("get_driving") != null:
		return false
	var pl: Node3D = _find_player()
	if pl == null or not bool(pl.get("active")):
		return false
	return true


## host 收到的一切攻击走这里：kind 0=枪(from=相机位 dir=视线) 1=近战(from=人物位 dir=朝向)
func server_intent(who: int, kind: int, from: Vector3, dir: Vector3) -> void:
	if kind == 0:
		server_gun(who, from, dir)
	elif kind == 1:
		server_melee(who, from, dir)
	elif kind == 2:
		server_accept()
	elif kind == 3:
		server_deliver()


func server_gun(_who: int, from: Vector3, dir: Vector3) -> void:
	var best_eid: int = -1
	var best_t: float = GUN_RANGE
	for k in _zombies.keys():
		var z: Dictionary = _zombies[k]
		var v: Vector3 = (z["pos"] as Vector3) + Vector3(0, 0.9, 0) - from
		var t: float = v.dot(dir)
		if t <= 0.2 or t >= best_t:
			continue
		var d2: float = v.length_squared() - t * t
		if d2 <= GUN_HIT_R * GUN_HIT_R:
			best_t = t
			best_eid = int(k)
	if best_eid >= 0:
		_spark(from + (dir as Vector3) * best_t)
		_hit(best_eid, GUN_DMG)
		if _zombies.has(best_eid):
			# 击退（demo knockback 思路）：活着才推，推之前照旧查墙
			var z2: Dictionary = _zombies[best_eid]
			var nxt: Vector3 = (z2["pos"] as Vector3) + (dir as Vector3) * GUN_KNOCK
			var gy: float = _ground_y(nxt.x, nxt.z)
			if not _blocked(Vector3(nxt.x, gy + 0.9, nxt.z)):
				nxt.y = gy
				z2["pos"] = nxt


func server_melee(_who: int, from: Vector3, fwd: Vector3) -> void:
	var hits: Array = []
	for k in _zombies.keys():
		var z: Dictionary = _zombies[k]
		var v: Vector3 = (z["pos"] as Vector3) - from
		v.y = 0.0
		if v.length() <= MELEE_R and v.length() > 0.01 and v.normalized().dot(fwd) > 0.35:
			hits.append(int(k))
	for e in hits:
		_hit(int(e), MELEE_DMG)


func _hit(eid: int, dmg: float) -> void:
	if not _zombies.has(eid):
		return
	var z: Dictionary = _zombies[eid]
	z["hp"] = float(z["hp"]) - dmg
	if float(z["hp"]) <= 0.0:
		_zombies.erase(eid)
		_sfx("res://assets/sounds/combat/enemy_destroy.ogg")


# ---------------------------------------------------------------- 告示板

func _build_board() -> void:
	_board = Node3D.new()
	_board.name = "DefenseBoard"
	_board.position = BOARD_POS
	game.add_child(_board)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#6b4a2b")
	var post := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(2.2, 1.5, 0.16)
	post.mesh = pm
	post.material_override = mat
	post.position = Vector3(0, 1.3, 0)
	_board.add_child(post)
	var lm := BoxMesh.new()
	lm.size = Vector3(0.16, 0.9, 0.16)
	for sx: float in [-0.8, 0.8]:
		var leg := MeshInstance3D.new()
		leg.mesh = lm
		leg.material_override = mat
		leg.position = Vector3(sx, 0.45, 0)
		_board.add_child(leg)
	var tag := Label3D.new()
	tag.text = tr("守夜讨伐 告示板")
	tag.position = Vector3(0, 2.35, 0)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 40
	tag.outline_size = 8
	tag.modulate = Color("#ff8a5c")
	_board.add_child(tag)
	_spot = DefenseSpot.new()
	_spot.name = "DefenseSpot"
	_spot.owner_m = self
	_spot.interact_radius = 4.0
	_spot.interact_priority = 10
	_board.add_child(_spot)
	_spot.mark_ready()


func can_board(_player_pos: Vector3) -> bool:
	if _phase != "BOARD" and _phase != "DELIVER":
		return false
	if game == null or game.call("get_driving") != null:
		return false
	var pl: Node3D = _find_player()
	return pl != null and pl.global_position.distance_to(BOARD_POS) <= _spot.interact_radius


func board_prompt() -> String:
	if _phase == "DELIVER":
		return tr("按 E 交付讨伐 +1000 金币")
	return tr("按 E 接下守夜讨伐")


func interact_local() -> void:
	if mod == null:
		return
	if _phase == "BOARD":
		if mod.is_auth():
			server_accept()
		else:
			mod.rpc_id(1, "_rpc_defense_intent", 2, Vector3.ZERO, Vector3.ZERO)
	elif _phase == "DELIVER":
		if mod.is_auth():
			server_deliver()
		else:
			mod.rpc_id(1, "_rpc_defense_intent", 3, Vector3.ZERO, Vector3.ZERO)


# ---------------------------------------------------------------- 昼夜

func _cache_daynight() -> void:
	_sun = game.get_node_or_null("Sun") as DirectionalLight3D
	_we = game.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if _we == null:
		return
	_env_shared = _we.environment
	if _env_shared == null:
		return
	_env = _env_shared.duplicate() as Environment
	if _env != null and _env.sky != null:
		# 【浅 duplicate 只复制 Environment 本体】sky 和 sky_material 仍是与共享 .tres
		# 同一个对象，夜色一改就把资源涂脏 —— 和上面那条纪律同源，逐层各自 duplicate。
		_env.sky = (_env.sky as Sky).duplicate() as Sky
		var m: Resource = (_env.sky as Sky).sky_material
		if m != null:
			(_env.sky as Sky).sky_material = m.duplicate() as ProceduralSkyMaterial
	_we.environment = _env
	var se: float = 1.0
	if _sun != null:
		se = _sun.light_energy
	_base = {
		"sun_e": se,
		"amb_c": _env.ambient_light_color,
		"amb_e": _env.ambient_light_energy,
		"bg_c": _env.background_color,
		"expo": _env.tonemap_exposure,
	}
	var psm: ProceduralSkyMaterial = _sky_mat()
	if psm != null:
		_base["sky_top"] = psm.sky_top_color
		_base["sky_hor"] = psm.sky_horizon_color
		_base["gnd_hor"] = psm.ground_horizon_color
		_base["gnd_bot"] = psm.ground_bottom_color


## 本任务私有那份天空材质（#32 起 urban 背景是真程序天空，不再是纯色）
func _sky_mat() -> ProceduralSkyMaterial:
	if _env == null or _env.sky == null:
		return null
	return (_env.sky as Sky).sky_material as ProceduralSkyMaterial


func _night_logic(delta: float) -> void:
	var want: float = 1.0 if (_phase == "DUSK" or _phase == "BREAK" or _phase == "WAVE") else 0.0
	if absf(_night - want) < 0.001:
		return
	_night = clampf(_night + signf(want - _night) * delta / DUSK_T, 0.0, 1.0)
	_apply_night()


func _apply_night() -> void:
	if _base.is_empty():
		return
	var t: float = _night
	if _sun != null:
		_sun.light_energy = lerpf(float(_base["sun_e"]), 0.10, t)
		_sun.light_color = Color(1, 1, 1).lerp(Color(0.55, 0.62, 0.92), t)
	if _env != null:
		_env.ambient_light_color = (_base["amb_c"] as Color).lerp(Color(0.10, 0.13, 0.24), t)
		_env.ambient_light_energy = lerpf(float(_base["amb_e"]), 0.5, t)
		_env.background_color = (_base["bg_c"] as Color).lerp(Color(0.02, 0.03, 0.07), t)
		_env.tonemap_exposure = lerpf(float(_base["expo"]), 0.6, t)
		# 【#32】urban 背景从纯色换成真程序天空后，只改 background_color 就变成
		# 「地暗了、天还是白天」。夜色必须落到天空材质本身。
		var psm: ProceduralSkyMaterial = _sky_mat()
		if psm != null and _base.has("sky_top"):
			psm.sky_top_color = (_base["sky_top"] as Color).lerp(Color(0.015, 0.025, 0.06), t)
			psm.sky_horizon_color = (_base["sky_hor"] as Color).lerp(Color(0.04, 0.055, 0.11), t)
			psm.ground_horizon_color = (_base["gnd_hor"] as Color).lerp(Color(0.03, 0.04, 0.08), t)
			psm.ground_bottom_color = (_base["gnd_bot"] as Color).lerp(Color(0.01, 0.015, 0.04), t)
		var fog_on: bool = t > 0.05
		if _env.fog_enabled != fog_on:
			_env.fog_enabled = fog_on
		if fog_on:
			_env.fog_light_color = (_base["amb_c"] as Color).lerp(Color(0.05, 0.07, 0.14), t)
			_env.fog_density = lerpf(0.0, 0.012, t)


# ---------------------------------------------------------------- 持枪与音效（纯本地表现）

func _attach_gun() -> void:
	if _gun != null and is_instance_valid(_gun):
		return
	if _find_player() == null:
		return
	var mp: Node3D = _find_player().get("model_pivot") as Node3D
	if mp == null:
		return
	var sc: PackedScene = load(GUN_PATH) as PackedScene
	if sc == null:
		return
	_gun = sc.instantiate() as Node3D
	_gun.name = "Blaster"
	# 挂 model_pivot 下（实测 BoneAttachment3D 里 glb 不渲染，见 #25 记录），
	# 但每帧用 RightHand 骨全局姿势手写同步（_sync_gun），这样射击后坐时枪跟着手。
	_skel = _find_skel(_find_player())
	if _skel != null:
		_hand_bone = _skel.find_bone("RightHand")
	mp.add_child(_gun)
	_sync_gun()


## 枪在手中的姿态：手骨 Y 轴 = 指向（实测 bake_check：hand Y ≈ 前向），
## 枪管（资产 +Z）要映到手 Y；手 X 朝下 → 枪 Y（上）= -手 X。
const GUN_IN_HAND := Basis(Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0))
const GUN_OFF := Vector3(0.05, 0.04, 0.0)   # 握把相对腕：手 X 方向 5cm、手 Y 方向 4cm
const GUN_SCALE := 0.45
const GUN_PULL := 0.03                       # 后坐时沿枪管回拉


func _sync_gun() -> void:
	if _gun == null or not is_instance_valid(_gun) or _skel == null or _hand_bone < 0:
		return
	if not _skel.is_inside_tree():
		return
	var wt: Transform3D = _skel.global_transform * _skel.get_bone_global_pose(_hand_bone)
	var hb: Basis = wt.basis.orthonormalized()
	var gb: Basis = hb * GUN_IN_HAND
	var pos: Vector3 = wt.origin + hb * GUN_OFF - gb.z * GUN_PULL * _kick
	_gun.global_transform = Transform3D(gb * Basis.from_scale(Vector3.ONE * GUN_SCALE), pos)


func _find_skel(n: Node) -> Skeleton3D:
	if n == null:
		return null
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var r: Skeleton3D = _find_skel(c)
		if r != null:
			return r
	return null


func _detach_gun() -> void:
	if _gun != null and is_instance_valid(_gun):
		if _gun.get_parent() != null:
			_gun.get_parent().remove_child(_gun)
		_gun.free()
	_gun = null
	_skel = null
	_hand_bone = -1


func _play_melee_fx() -> void:
	_lunge = 1.0
	_sfx("res://assets/sounds/combat/enemy_attack.ogg")


func _sfx(path: String) -> void:
	var p: AudioStreamPlayer = _snd.get(path) as AudioStreamPlayer
	if p == null:
		var st: Resource = load(path) as Resource
		if st == null:
			return
		p = AudioStreamPlayer.new()
		p.stream = st
		mod.add_child(p)
		_snd[path] = p
	p.play()


# ---------------------------------------------------------------- 复制品（两端共用）

func _sync_zs() -> Array:
	var out: Array = []
	for k in _zombies.keys():
		var z: Dictionary = _zombies[k]
		var p: Vector3 = z["pos"] as Vector3
		# a[7] 状态码：2=攻击动画窗口 1=步行 0=待机（v1.5：以前只传 walk 布尔，
		# 用户反馈「丧尸攻击没有动画，只是滑行」）
		var st: int = 2 if float(z["atka"]) > 0.0 else (1 if bool(z["walk"]) else 0)
		out.append([int(k), p.x, p.y, p.z, float(z["yaw"]), float(z["hp"]), int(z["kind"]), st])
	return out


func apply_state(phase_code: int, wave: int, deaths: int, hp: Dictionary, zs: Array) -> void:
	_phase = PHASES[clampi(phase_code, 0, PHASES.size() - 1)]
	_wave = wave
	_deaths = deaths
	var my_old: float = float(_hp.get(mod.my_id(), HP_MAX))
	for k in hp.keys():
		_hp[int(k)] = float(hp[k])
	if float(_hp.get(mod.my_id(), HP_MAX)) < my_old - 0.01:
		_hit_flash()   # 自己掉血 → 屏幕红闪（demo 里没有，第三人称更需要）
	if _phase == "DUSK" or _phase == "BREAK" or _phase == "WAVE" or _phase == "DAWN":
		_attach_gun()
	var seen: Dictionary = {}
	for e in zs:
		var a: Array = e as Array
		var eid: int = int(a[0])
		seen[eid] = true
		if not _views.has(eid):
			_spawn_view(eid, int(a[6]), Vector3(float(a[1]), float(a[2]), float(a[3])))
		var v: Dictionary = _views[eid]
		v["tgt"] = Vector3(float(a[1]), float(a[2]), float(a[3]))
		v["yaw"] = float(a[4])
		var st: int = int(a[7])
		v["walk_on"] = st == 1
		v["atk_on"] = st == 2
		var hp_new: float = float(a[5])
		if hp_new < float(v["hp"]) - 0.01:
			_damage_floater(v["tgt"] as Vector3, float(v["hp"]) - hp_new)
		v["hp"] = hp_new
		_set_bar_text(v, hp_new)
	var gone: Array = []
	for k in _views.keys():
		if not seen.has(int(k)):
			gone.append(int(k))
	for eid in gone:
		_despawn_view(eid)


func _spawn_view(eid: int, kind: int, at: Vector3) -> void:
	var sc: PackedScene = load(KIND_PATHS[kind]) as PackedScene
	if sc == null:
		return
	var n: Node3D = Node3D.new()
	n.name = "Zombie%d" % eid
	var model: Node3D = sc.instantiate() as Node3D
	n.add_child(model)
	game.add_child(n)
	n.global_position = at
	_fit_model(model)
	var ap: AnimationPlayer = _find_anim(model)
	var clips: Array = []
	if ap != null:
		clips = ap.get_animation_list()
	var guard: Node = null
	if model.get_child_count() > 0 and model.get_child(0) is Node3D:
		guard = model.get_child(0)
	var bar := Label3D.new()
	bar.name = "HpBar"
	bar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	bar.font_size = 26
	bar.outline_size = 6
	bar.position = Vector3(0, Z_HEIGHT + 0.35, 0)
	n.add_child(bar)
	_views[eid] = {"node": n, "model": model, "anim": ap, "guard": guard, "bar": bar,
		"walk": _guess_clip(clips, ["walk"]), "idle": _guess_clip(clips, ["idle"]),
		"atk": _guess_clip(clips, ["attack-melee", "bite", "attack"]),
		"tgt": at, "yaw": 0.0, "walk_on": false, "atk_on": false, "hp": ZHP}


## graveyard 动画可能带根位移：内层模型每帧归零 x/z（世界位置只由外层节点写）
func _fit_model(model: Node3D) -> void:
	var list: Array = []
	_collect_mesh(model, list)
	if list.is_empty():
		return
	var box: AABB = (list[0] as MeshInstance3D).global_transform \
		* (list[0] as MeshInstance3D).mesh.get_aabb()
	for i in range(1, list.size()):
		var mi: MeshInstance3D = list[i]
		box = box.merge(mi.global_transform * mi.mesh.get_aabb())
	if box.size.y <= 0.001:
		return
	model.scale *= Vector3.ONE * (Z_HEIGHT / box.size.y)


func _collect_mesh(n: Node, list: Array) -> void:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		list.append(n)
	for c in n.get_children():
		_collect_mesh(c, list)


func _despawn_view(eid: int) -> void:
	if not _views.has(eid):
		return
	var v: Dictionary = _views[eid]
	var n: Node3D = v["node"] as Node3D
	_views.erase(eid)
	if n != null and is_instance_valid(n):
		n.get_parent().remove_child(n)
		n.free()


func _tick_views(delta: float) -> void:
	for k in _views.keys():
		var v: Dictionary = _views[k]
		var n: Node3D = v["node"] as Node3D
		if n == null or not is_instance_valid(n):
			continue
		n.global_position = n.global_position.lerp(v["tgt"] as Vector3,
			clampf(delta * 12.0, 0.0, 1.0))
		n.rotation.y = float(v["yaw"])
		var guard: Node = v["guard"] as Node
		if guard != null and guard is Node3D:
			var gp: Vector3 = (guard as Node3D).position
			if gp.x != 0.0 or gp.z != 0.0:
				gp.x = 0.0
				gp.z = 0.0
				(guard as Node3D).position = gp
		var ap: AnimationPlayer = v["anim"] as AnimationPlayer
		if ap != null:
			var want: String = String(v["walk"]) if bool(v["walk_on"]) else String(v["idle"])
			var atk: String = String(v.get("atk", ""))
			if bool(v.get("atk_on", false)) and atk != "":
				want = atk
			if want != "" and ap.current_animation != want:
				ap.play(want)


func _guess_clip(list: Array, keys: Array) -> String:
	for key in keys:
		for a in list:
			if String(a).to_lower().contains(String(key)):
				return String(a)
	return ""


func _clear_views() -> void:
	for k in _views.keys():
		var n: Node3D = (_views[k] as Dictionary)["node"] as Node3D
		if n != null and is_instance_valid(n):
			n.get_parent().remove_child(n)
			n.free()
	_views.clear()


# ---------------------------------------------------------------- 战斗反馈 UI（Starter-Kit-FPS 思路）

## 准星（战斗阶段才显示）+ 受击红闪。挂在 mod（常驻 Node）下，随 leave 释放。
func _build_combat_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.name = "DefenseCombatUi"
	_ui.layer = 5
	mod.add_child(_ui)
	_flash = ColorRect.new()
	_flash.name = "HitFlash"
	_flash.color = Color(0.85, 0.08, 0.08, 0.0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_flash)
	# 【坑·v1.5】PRESET_CENTER 只把锚点收到中心，offsets 不清零就是 0×0 控件，
	# Label 文字根本不绘制（用户反馈「准星没有显示」）。TextureRect 给显式 offsets 才稳。
	var ctex: Texture2D = load(CROSSHAIR_PATH) as Texture2D
	_cross = TextureRect.new()
	_cross.name = "Crosshair"
	_cross.texture = ctex
	_cross.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_cross.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_cross.set_anchors_preset(Control.PRESET_CENTER)
	_cross.offset_left = -24.0
	_cross.offset_top = -24.0
	_cross.offset_right = 24.0
	_cross.offset_bottom = 24.0
	_cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cross.visible = false
	_ui.add_child(_cross)


func _hit_flash() -> void:
	if _flash == null or not is_instance_valid(_flash):
		return
	_flash.color = Color(0.85, 0.08, 0.08, 0.35)
	var tw: Tween = game.create_tween()
	tw.tween_property(_flash, "color:a", 0.0, 0.45)


## 命中火花：host 在判中点放一颗小球，放大后消失（demo 的 impact 简化版）
func _spark(at: Vector3) -> void:
	var m := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.09
	sm.height = 0.18
	m.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.92, 0.55)
	m.material_override = mat
	game.add_child(m)
	m.global_position = at
	var tw2: Tween = game.create_tween()
	tw2.tween_property(m, "scale", Vector3.ONE * 2.6, 0.16)
	tw2.tween_callback(m.queue_free)


## 伤害飘字：复制品掉血就弹（数据来自 10Hz 状态包，两端都会显示）
func _damage_floater(at: Vector3, dmg: float) -> void:
	var lb := Label3D.new()
	lb.text = "-%d" % int(roundf(dmg))
	lb.position = at + Vector3(0, Z_HEIGHT + 0.75, 0)
	lb.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lb.font_size = 40
	lb.outline_size = 8
	lb.modulate = Color("#ffd45e")
	game.add_child(lb)
	var tw: Tween = game.create_tween()
	tw.set_parallel(true)
	tw.tween_property(lb, "position:y", lb.position.y + 0.9, 0.7)
	tw.tween_property(lb, "modulate:a", 0.0, 0.7)
	tw.chain().tween_callback(lb.queue_free)


func _set_bar_text(v: Dictionary, hp: float) -> void:
	var bar: Label3D = v.get("bar", null) as Label3D
	if bar == null or not is_instance_valid(bar):
		return
	var ratio: float = clampf(hp / ZHP, 0.0, 1.0)
	var seg: int = int(ceilf(ratio * 5.0))
	var s: String = ""
	for i in range(5):
		s += "█" if i < seg else "░"
	bar.text = s
	bar.modulate = Color(0.45, 0.9, 0.45).lerp(Color(0.95, 0.3, 0.25), 1.0 - ratio)


# ---------------------------------------------------------------- HUD / 状态查询

func _phase_code() -> int:
	return PHASES.find(_phase)


func is_net_active() -> bool:
	return _phase == "DUSK" or _phase == "BREAK" or _phase == "WAVE" or _phase == "DAWN"


func dbg_state() -> Dictionary:
	return {"phase": _phase, "wave": _wave, "deaths": _deaths,
		"zombies": _zombies.size(), "views": _views.size(), "hp": _hp.duplicate(),
		"night": _night}


func hud_line() -> String:
	if game == null:
		return ""
	match _phase:
		"BOARD":
			if _result_t > 0.0:
				return _result
			return tr("守夜讨伐：找告示板接任务（鼠标左键开枪 / F 近战）")
		"DUSK":
			return tr("讨伐开始：天黑了，找好掩体…")
		"BREAK":
			return "%s %d/%d ｜ %s" % [tr("下一波"), _wave + 1, WAVES.size(), _hp_hud()]
		"WAVE":
			var left: int = _zombies.size() if mod.is_auth() else _views.size()
			return "%s %d/%d ｜ %s %d ｜ %s %d/%d ｜ %s" % [tr("讨伐"), _wave + 1, WAVES.size(),
				tr("妖怪剩余"), left, tr("阵亡"), _deaths, FAIL_DEATHS, _hp_hud()]
		"DAWN":
			return tr("最后一波已清空，天亮中…")
		"DELIVER":
			return "%s ｜ %s" % [tr("回告示板按 E 交付 +1000"), _hp_hud()]
		"COOLDOWN":
			if _result_t > 0.0:
				return _result
			return ""
		_:
			return ""


func _hp_hud() -> String:
	var hp: float = float(_hp.get(mod.my_id(), HP_MAX))
	return "%s %d" % [tr("生命"), int(hp)]
