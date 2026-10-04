extends Node

## 车库：开局玩家开哪台车。
##
## 为什么做成一个 autoload：
## 选车页（scenes/select.tscn）和真正跑车的场景（scenes/main.tscn）是两棵互不相干
## 的场景树，选择结果必须有个跨场景的落点。走 autoload 比写 user:// 配置文件省事，
## 也比塞进 EventBus 合适 —— EventBus 是广播（谁都能发、谁都能听），
## 这里是**状态**，需要的是"读回来"。
##
## 【目录里到底存了什么】
## 每台车只记 (控制器脚本, 模型 glb, 归一化长度) 三样，不做整棵载具场景：
## 因为 scenes/main.tscn 里那个占位 Vehicle 节点已经自带物理球、地面射线、
## 轮胎烟、三路音效、相机跟随目标 —— 换车只要换「它身上挂的脚本」+「Container/Model
## 里那台模型」，不用把整棵节点树拆了重建（重建会打断相机跟随的目标引用，见
## scripts/world/vehicle_picker.gd）。

const CATALOG := [
	{
		"id": "car",
		"name": "皮卡 · 黄",
		"sub": "全能：稳、快、撞得起",
		"script": "res://scripts/vehicles/vehicle_arcade.gd",
		"model": "res://models/vehicle-truck-yellow.glb",
		"len": 0.0,
		"preview": "res://ui/preview_car.png",
		"tags": ["默认", "四轮", "均衡"],
	},
	{
		"id": "green",
		"name": "皮卡 · 绿",
		"sub": "同款换个配色，手感一点没变",
		"script": "res://scripts/vehicles/vehicle_arcade.gd",
		"model": "res://models/vehicle-truck-green.glb",
		"len": 0.0,
		"preview": "res://ui/preview_green.png",
		"tags": ["配色", "四轮", "均衡"],
	},
	{
		"id": "moto",
		"name": "摩托",
		"sub": "轻、贼、甩尾狠，走线全靠晕",
		"script": "res://scripts/vehicles/vehicle_motorcycle.gd",
		"model": "res://models/vehicle-motorcycle.glb",
		"len": 0.0,
		"preview": "res://ui/preview_moto.png",
		"tags": ["两轮", "飘移", "高速"],
	},
	{
		"id": "bee",
		"name": "蜜蜂载具",
		"sub": "20MB 的骨骼动画蜜蜂，地上跑也行、心里飞也行",
		"script": "res://scripts/vehicles/vehicle_arcade.gd",
		"model": "res://models/bee.glb",
		# 蜜蜂原比例是 1.44 宽 / 1.51 高 / 1.83 长 —— 高个子，等比缩到和皮卡一样长（1.828）
		# 的话它比皮卡高两倍多，镜头（机位约 1.9m 高、look_at 0.55）会被它整块糊住。
		# 收到 0.72 ⇒ 约 0.55 高 / 0.59 宽 / 0.72 长，比皮卡（1.83 长）小一半还多，
		# 视觉上"腿短短一只蜂在跑"，肚子离地也跟着降下来（用户反馈"太高 + 太大"）。
		"len": 0.72,
		"preview": "res://ui/preview_bee.png",
		"tags": ["glTF", "骨骼动画", "整活"],
	},
]

## 当前选中的 id（默认 = 目录第一项 = 占位那台黄皮卡）
var selected_id: String = "car"


func _ready() -> void:
	# 万一有人把 selected_id 写成了目录里没有的字符串，兜回默认那台，
	# 别让进图之后玩家开着空气
	if _find(selected_id).is_empty():
		selected_id = "car"


func _find(p_id: String) -> Dictionary:
	for d in CATALOG:
		if String(d["id"]) == p_id:
			return d
	return {}


## 当前选中的车款（字典；目录查不到就是空字典）
func current() -> Dictionary:
	return _find(selected_id)


func select_vehicle(p_id: String) -> bool:
	if _find(p_id).is_empty():
		push_warning("[garage] 没有这台车：" + p_id)
		return false
	selected_id = p_id
	return true
