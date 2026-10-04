class_name Interactable
extends Node

# 交互组件基类（InteractionGate 机制的「可交互物」侧）。
# 契约——三条硬约束全满足才允许出现提示、才允许响应输入：
#   C1 距离：player 在 interact_radius 之内
#   C2 就绪：is_ready —— 只允许在「模型/资源实例化完成」的那个回调里调 mark_ready()，
#            加载失败或还没挂上模型的对象永远不亮提示
#   C3 可用：is_interactable + 子类业务条件（如驾驶中必须先刹停）
# 任何脚本都不许绕过子类 can_interact() 自己拼 if 判定（断言表第 3 条）。

@export var interact_radius: float = 6.0
## 同一帧多个可交互物都合法时，先比优先级再比距离（任务点=10 > 上下车=0）。
## 没有它：开着货车刹停在装货区，「按 E 装货」永远被「按 E 下车」抢走。
@export var interact_priority: int = 0

var is_ready: bool = false
var is_interactable: bool = true


func _enter_tree() -> void:
	add_to_group("interactable")


func mark_ready() -> void:
	is_ready = true


func can_interact(_player_pos: Vector3) -> bool:
	return is_ready and is_interactable


func get_prompt(_player_pos: Vector3) -> String:
	return ""


func on_interact(_player_pos: Vector3) -> void:
	pass
