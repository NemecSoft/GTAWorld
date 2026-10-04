extends RefCounted
## modules/missions/mission_base.gd —— 任务基类（#21 方案 A）
##
## #20 的三个任务脚本把「enter/leave/tick/hud_line」撞成了同款形状，
## 这里正式立为契约：所有任务 = RefCounted 子类，节点生命周期全交给 mod
## （场景一切换就 leave），金币结算只发 EventBus 事件。
## 4.7 坑：无 `..` 区间语法；tr("…%d") 要配 % 而非 .arg()。

var mod: Node = null
var game: Node3D = null
var state: String = "OFF"


func enter(_g: Node3D) -> void:
	pass


func leave() -> void:
	state = "OFF"


func tick(_delta: float) -> void:
	pass


func hud_line() -> String:
	return ""


# ---------------------------------------------------------------- 公共查找/量测

## 车的真实位置：模型世界坐标（根节点是出生锚点，不会跟着开，#19 铁律）
func _car_pos(car: Node) -> Vector3:
	if car == null:
		return Vector3.ZERO
	if car.has_method("get_vehicle_position"):
		return car.call("get_vehicle_position")
	return (car as Node3D).global_position


func _stopped(car: Node, max_speed: float = 1.6) -> bool:
	if car == null:
		return false
	return float(car.call("get_speed_mps")) <= max_speed


func _ground_y(x: float, z: float) -> float:
	if game == null:
		return 0.0
	var terrain: Node = game.get_node_or_null("Terrain")
	if terrain != null and terrain.has_method("ground_height"):
		return maxf(float(terrain.call("ground_height", x, z)), 0.0)
	return 0.0


func _find_player() -> Node3D:
	if game == null:
		return null
	return game.call("get_game_player") as Node3D


func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r: AnimationPlayer = _find_anim(c)
		if r != null:
			return r
	return null


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var r: Skeleton3D = _find_skeleton(c)
		if r != null:
			return r
	return null


## Kenney 骨骼命名没有保证——按「右侧 + 手臂类关键词」渐进匹配，找不到返回 -1
func _find_right_arm(sk: Skeleton3D) -> int:
	if sk == null:
		return -1
	var best: int = -1
	for b in range(sk.get_bone_count()):
		var bn: String = String(sk.get_bone_name(b)).to_lower()
		if not (bn.contains("arm") or bn.contains("shoulder") or bn.contains("elbow")):
			continue
		if bn.contains("left") or bn.contains(".l") or bn.contains("_l") or bn.ends_with("l"):
			continue
		if bn.ends_with("r") or bn.contains("right") or bn.contains(".r") or bn.contains("_r"):
			return b
		if best < 0:
			best = b
	return best
