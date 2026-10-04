class_name InteractionGate
extends Node

# 全局唯一交互门控（用户定的约束机制）：
# 提示条的可见性与 E 键分发只有这一个入口。
#   _process：每帧从 "interactable" 组里挑「can_interact() 为真且最近」的一个当
#             current_target；prompt.visible == (current_target != null)（断言 1、4）
#   _unhandled_input：只有 current_target 非空、且再校验一次 can_interact 才分发
#             on_interact（断言 3：所有交互入口都走 can_interact）
# 用 _unhandled_input 而不是 _input：网络面板的 LineEdit 要先吃掉按键，
# 否则输 IP 时每敲一个 e 都会触发上/下车。

var player: Node3D = null
var prompt: Label = null
var current_target: Interactable = null


func _process(_delta: float) -> void:
	var ppos: Vector3 = Vector3.ZERO
	if player != null:
		ppos = player.global_position
	var best: Interactable = null
	var best_d: float = INF
	var best_p: int = -1000000
	var list: Array = get_tree().get_nodes_in_group("interactable")
	var i: int = 0
	while i < list.size():
		var it: Interactable = list[i] as Interactable
		if it != null and it.can_interact(ppos):
			var body: Node3D = it.get_parent() as Node3D
			var d: float = 0.0
			if body != null:
				# 有真实位置接口的（车）不用根节点锚点排序
				if body.has_method("get_vehicle_position"):
					d = body.call("get_vehicle_position").distance_to(ppos)
				else:
					d = body.global_position.distance_to(ppos)
			# 先比优先级（任务点压过上下车），同级再比距离
			var pr: int = it.interact_priority
			if pr > best_p or (pr == best_p and d < best_d):
				best_p = pr
				best_d = d
				best = it
		i += 1
	current_target = best
	if prompt != null:
		prompt.visible = current_target != null
		if current_target != null:
			prompt.text = current_target.get_prompt(ppos)
		else:
			prompt.text = ""


func _unhandled_input(event: InputEvent) -> void:
	if current_target == null:
		return
	if not event.is_action_pressed("interact"):
		return
	var ppos: Vector3 = Vector3.ZERO
	if player != null:
		ppos = player.global_position
	# 同帧内目标可能刚失效（车被开走/模型被换），分发前再过一遍门控
	if current_target.can_interact(ppos):
		current_target.on_interact(ppos)
