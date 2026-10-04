extends Node
##
## VGlobal —— 射线车系统全局服务（精简版，只保留「开车 / 相机 / 地形测高」需要的部分）
##
## 之所以要自己写一个精简版，而不是把参考项目那套 global.gd 整个搬进来：
##   那份 autoload 连带 AI 车池、RoadPath 寻路、Autoshop 车库、UI、幽灵回放、存档，
##   跟我们项目已有的 EventBus / Modules / Lobby、HUD、地图生成器全都撞在一起。
##   这里只提供 RayVehicle / CameraHandler / PlayerController 真正读的那几个字段：
##     player_car、player_data、camera、四条调校曲线、get_height_at_coords()。
##   新增 AI 车时再往 npc_pool / spawn_ai() 里补，不必一次搬整套。
##
## autoload 名固定为 VGlobal，脚本里统一写 global.xxx。

var player_car: RayVehicle
var camera: CameraHandler

## 玩家累计数据（PlayerController 每帧往上加）
var player_data: PlayerData

## 复位点：respawn 后把车放回来
var spawn_position := Vector3.ZERO

## 调校曲线（从 res://Curves/ 读取，改曲线不用改代码）
var accel_curve := load("res://Curves/acceleration.tres")
var aero_curve := load("res://Curves/aero.tres")
var brake_curve := load("res://Curves/brake.tres")
var steer_curve := load("res://Curves/steer.tres")
var spring_grip_curve := load("res://Curves/spring_grip.tres")
var turbo_curve := load("res://Curves/turbo.tres")
var terrain_curve := load("res://Curves/terrain.tres")

## AI 车池（先留空，需要 AI 时由 AI 模块自己填）
var npc_pool: Array[RayVehicle] = []
var npc_vehicledata: VehicleData = null

func _ready() -> void:
	player_data = PlayerData.new()
	camera = get_tree().get_first_node_in_group("camera") as CameraHandler
	if camera == null:
		push_warning("[VGlobal] 场景里没有 groups=[\"camera\"] 的 CameraHandler 节点")

func set_player_car(car: RayVehicle) -> void:
	player_car = car
	if player_car != null:
		spawn_position = car.global_position

## 拨地而起向下打一条射线，返回该点地面高度；打不到返回 -1。
## Vehicle.attempt_respawn() 用它找一块平地，Wheel 不直接用。
func get_height_at_coords(pos: Vector2, layers: Array = [1]) -> float:
	var map := get_tree().get_first_node_in_group("map")
	if map == null:
		return -1.0
	var space: PhysicsDirectSpaceState3D = map.get_world_3d().direct_space_state

	var query := PhysicsRayQueryParameters3D.create(Vector3(pos.x, 1000.0, pos.y), Vector3(pos.x, -200.0, pos.y))
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var mask := 0
	for layer in layers:
		mask |= (1 << (int(layer) - 1))
	query.collision_mask = mask

	var result: Dictionary = space.intersect_ray(query)
	if not result.is_empty():
		return result.position.y
	return -1.0

## 在玩家附近撒一台 AI 车（目前只占坑：由 AI 模块接管后实现）
func attempt_ai_spawn() -> void:
	return
