extends Node3D
## world/world_streamer.gd —— 开放世界区块流式加载（总纲 §3.5，M1）
##
## 参数（dt = 调试面板里可调）：
##   CHUNK_SIZE  每区块边长（米）
##   VISIBLE_R   可视半径（格）；实际加载 (2R+1)^2 格
##   UNLOAD_MARGIN 卸载余量（格），避免边界反复加载卸载
##   每帧最多实例化 CHUNK_BUDGET 个，剩下的排队（这是不卡顿的关键）
##
## 用法：把本脚本挂到世界根（开放世界场景），把区块场景挂到 `Chunks` 组下。
## 没有区块源时（M0 阶段）它只是空转，不影响现有单局跑法。
##
## 4.7 坑：本 build 不支持 `..` 区间语法，所有循环写 range(a, b + 1)。

@export_group("World Streamer")
@export_range(64, 512, 64) var chunk_size: float = 128.0
@export_range(1, 8, 1) var visible_radius: int = 4
@export_range(0, 4, 1) var unload_margin: int = 1
@export_range(1, 8, 1) var chunk_budget_per_frame: int = 2
@export var chunk_scene: PackedScene = null   # 区块模板（future）

const MAX_LIFE_SECONDS := 120.0

var _loaded: Dictionary = {}    # Vector2i key -> Node
var _queue: Array = []          # 待加载的 Vector2i
var _focus: Vector3 = Vector3.ZERO
var _last_center := Vector2i(999999, 999999)
var _pending_unload: Dictionary = {}  # key -> float（剩余存活秒数）

func _ready() -> void:
	set_process(true)
	print("[WorldStreamer] 就绪 chunk=%.0f R=%d" % [chunk_size, visible_radius])


func _process(delta: float) -> void:
	_refresh_queue()
	_process_unload(delta)
	_process_queue()


## 只在玩家跨格时重建队列，别每帧重算
func _refresh_queue() -> void:
	var center := Vector2i(floor(_focus.x / chunk_size), floor(_focus.z / chunk_size))
	if center == _last_center:
		return
	_last_center = center
	_queue.clear()
	var r: int = visible_radius
	for x in range(-r, r + 1):
		for z in range(-r, r + 1):
			var key := Vector2i(center.x + x, center.z + z)
			if not _loaded.has(key) and not _queue.has(key):
				_queue.append(key)


## 每帧只处理 budget 个，优先近的（简化：队列头就是最近的）
func _process_queue() -> void:
	var n: int = 0
	while not _queue.is_empty() and n < chunk_budget_per_frame:
		var key: Vector2i = _queue.pop_front()
		if _loaded.has(key):
			continue
		var chunk := _instantiate_chunk(key)
		if chunk == null:
			continue
		_loaded[key] = chunk
		n += 1


func _instantiate_chunk(key: Vector2i) -> Node:
	if chunk_scene == null:
		return null
	var c := chunk_scene.instantiate()
	var w: Vector3 = Vector3(float(key.x) * chunk_size, 0.0, float(key.y) * chunk_size)
	c.global_position = w
	add_child(c)
	return c


func _process_unload(delta: float) -> void:
	if _pending_unload.is_empty():
		return
	var expired: Array = []
	for k in _pending_unload.keys():
		var left: float = float(_pending_unload[k]) - delta
		_pending_unload[k] = left
		if left <= 0.0:
			expired.append(k)
	# 边遍历边删会踩 Dictionary 迭代的坑，先攒起来一次性删
	for k in expired:
		var node: Node = _loaded.get(k, null)
		if node != null and is_instance_valid(node):
			node.queue_free()
		_loaded.erase(k)
		_pending_unload.erase(k)


## M1 起用：告诉流式器「玩家在哪」，位置来自玩家/载具
func focus_on(world_pos: Vector3) -> void:
	_focus = world_pos


func get_loaded_count() -> int:
	return _loaded.size()


func get_chunk_key(world_pos: Vector3) -> Vector2i:
	return Vector2i(floor(world_pos.x / chunk_size), floor(world_pos.z / chunk_size))
