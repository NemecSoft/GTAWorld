class_name VehicleInteractable
extends Interactable

# 车辆侧交互实现。mode：0=停在路边等人上车，1=有人正在开（本机的我）。
# 判定与提示文案全收在这里；urban_game 只提供三条回调：
#   can_exit_vehicle() / enter_vehicle(car) / exit_vehicle()
# 以及 is_vehicle_remote(car)（别人正在开的车不能抢）。

const MODE_BOARD := 0
const MODE_DRIVE := 1

var host: Node = null
var mode: int = MODE_BOARD

var board_prompt: String = "按 E 上车"
var drive_prompt: String = "按 E 下车"


func can_interact(player_pos: Vector3) -> bool:
	if not is_ready or not is_interactable or host == null:
		return false
	var car := get_parent() as Node3D
	if car == null:
		return false
	if mode == MODE_DRIVE:
		return host.call("can_exit_vehicle")
	if host.get("_driving") != null:
		return false
	if host.call("is_vehicle_remote", car):
		return false
	# 车的真实位置 = 模型世界坐标；根节点只是出生锚点，开出去后不会跟着动
	var cpos: Vector3 = car.global_position
	if car.has_method("get_vehicle_position"):
		cpos = car.call("get_vehicle_position")
	return cpos.distance_to(player_pos) <= interact_radius


func get_prompt(_player_pos: Vector3) -> String:
	if mode == MODE_DRIVE:
		return drive_prompt
	return board_prompt


func on_interact(_player_pos: Vector3) -> void:
	var car := get_parent() as Node3D
	if car == null or host == null:
		return
	if mode == MODE_DRIVE:
		host.call("exit_vehicle")
	else:
		host.call("enter_vehicle", car)
