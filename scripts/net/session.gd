extends Node
## net/session.gd —— 会话层（autoload 名：Lobby）
##
## 抄 GTA Online 的四房型（总纲 §3.4）：Solo / Invite / Crew / Public。
## 铁律：server 是唯一权威。客户端只上报「意图」，不报「结果」。
##
## 通道约定（Godot 4 高层网络）：
##   位姿类  -> 走 MultiplayerSynchronizer 或 unreliable_ordered 快照（20Hz）
##   事件类  -> reliable RPC（命中 / 爆炸 / 占点 / 任务阶段）
##   输入类  -> reliable RPC 批量上报（20~30Hz，一帧一包，别每个键一个包）
##
## 4.7 坑：autoload 名字不能叫 Net（和引擎内置全局类 Net = NetworkedMultiplayerAPI 撞名），
##        也别叫 Multiplayer。所以本项目叫 **Lobby**。

enum RoomMode { SOLO, INVITE, CREW, PUBLIC }

const DEFAULT_PORT := 7777
const DEFAULT_MAX_PLAYERS := 8
const GAMEPLAY_TICK := 0.05    # 20Hz 服务端模拟步

var room_mode: int = RoomMode.SOLO
var max_players: int = DEFAULT_MAX_PLAYERS
var session_id: String = ""
var players: Dictionary = {}   # peer_id -> {name, faction, ready}

func _ready() -> void:
	name = "Lobby"
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 断线/掉线要清理玩家表
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	print("[Lobby] 就绪（本机 %d，房型 Solo）" % multiplayer.get_unique_id())


## 开房。mode 见 RoomMode。
func host(mode: int = RoomMode.PUBLIC, port: int = DEFAULT_PORT, cap: int = DEFAULT_MAX_PLAYERS) -> Error:
	room_mode = mode
	max_players = cap
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, cap)
	if err != OK:
		push_error("[Lobby] 开房失败：%d" % err)
		return err
	multiplayer.multiplayer_peer = peer
	session_id = "host_%d" % port
	players[multiplayer.get_unique_id()] = {"name": "Host", "faction": "", "ready": false}
	print("[Lobby] 开房成功 port=%d cap=%d mode=%d" % [port, cap, mode])
	return OK


## 加房。addr 留空表示本机。
func join(addr: String = "127.0.0.1", port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(addr, port)
	if err != OK:
		push_error("[Lobby] 连房失败：%d" % err)
		return err
	multiplayer.multiplayer_peer = peer
	session_id = ""
	print("[Lobby] 正在连接 %s:%d" % [addr, port])
	return OK


## 退出（单机等于重置 peer）
func leave() -> void:
	if multiplayer.multiplayer_peer != null:
		if multiplayer.is_server():
			(multiplayer.multiplayer_peer as ENetMultiplayerPeer).close()
		else:
			(multiplayer.multiplayer_peer as ENetMultiplayerPeer).disconnect_from_host()
	multiplayer.multiplayer_peer = null
	players.clear()
	room_mode = RoomMode.SOLO
	print("[Lobby] 已退出")


func is_server() -> bool:
	return multiplayer.is_server()


func is_solo() -> bool:
	return room_mode == RoomMode.SOLO or not multiplayer.multiplayer_peer is ENetMultiplayerPeer


func player_count() -> int:
	return players.size()


func get_players() -> Array:
	var out: Array = []
	for id in players.keys():
		out.append(players[id])
	out.sort_custom(func(a, b) -> bool:
		return int(a["id"]) < int(b["id"]))
	return out


func set_local_faction(faction_name: String) -> void:
	players[multiplayer.get_unique_id()] = {
		"name": players[multiplayer.get_unique_id()].get("name", "P"),
		"faction": faction_name,
		"ready": true,
	}


# ---------------- 内部回调 ----------------

func _on_peer_connected(id: int) -> void:
	if not multiplayer.is_server():
		return  # 客机的玩家表由服务端权威广播，不自己拼（以前客机只看到"P1"占位）
	players[id] = {"name": "P%d" % id, "faction": "", "ready": false}
	print("[Lobby] 玩家加入 %d（当前 %d 人）" % [id, players.size()])
	# 房主通知新房客「这里是什么局」+ 把整张玩家表广播给所有人
	if has_method("_rpc_handshake"):
		rpc("_rpc_handshake", session_id, room_mode)
	rpc("_rpc_roster", players.duplicate(true))


func _on_peer_disconnected(id: int) -> void:
	players.erase(id)
	print("[Lobby] 玩家离开 %d（当前 %d 人）" % [id, players.size()])
	if multiplayer.is_server():
		rpc("_rpc_roster", players.duplicate(true))


func _on_connected_to_server() -> void:
	print("[Lobby] 已连上服务器（我的 id=%d）" % multiplayer.get_unique_id())
	players.erase(1)
	var my: int = multiplayer.get_unique_id()
	players[my] = {"name": "P%d" % my, "faction": "", "ready": false}


func _on_connection_failed() -> void:
	push_warning("[Lobby] 连不上服务器")


func _on_server_disconnected() -> void:
	push_warning("[Lobby] 和服务器断开了")
	players.clear()


## 房主用来广播局信息；客户端收到后填自己的 room_mode
@rpc("authority", "call_local", "reliable")
func _rpc_handshake(sid: String, mode: int) -> void:
	session_id = sid
	room_mode = mode
	print("[Lobby] 收到局信息：%s（mode=%d）" % [sid, mode])


## 服务端权威玩家表：增删人后整表广播，客机直接替换本地副本
@rpc("authority", "reliable")
func _rpc_roster(p: Dictionary) -> void:
	players = p
	print("[Lobby] 收到玩家表（%d 人）" % p.size())
