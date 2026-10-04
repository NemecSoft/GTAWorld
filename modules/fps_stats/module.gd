extends Node
## modules/fps_stats/module.gd —— 可选模块示范（默认开启）
##
## 作用：右下角一块调试信息（FPS / 帧时间 / 场景节点数 / 出图物理帧 / 在线人数 / 启用模块）。
## 它演示了模块化契约怎么落地：
##   * 入口只有 mod_setup(ctx) 一个函数，拿共享上下文；
##   * 不抓别模块的节点，只读 Lobby/Modules 的公开 getter；
##   * 随时可以在 mod.cfg 里把 enabled 改成 false 就下线，主游戏毫发无伤。

var _label: Label = null
var _acc: float = 0.0
var _frames: int = 0

func mod_setup(ctx: Node) -> void:
	var cv := CanvasLayer.new()
	cv.layer = 8
	cv.name = "ModFpsStatsLayer"

	_label = Label.new()
	_label.name = "ModFpsStats"
	# 【#31】原来挂右下角，正好被驾驶速度面板压住（"126" 和 "在线 0 人" 叠成糊的）。
	# 这是开发者统计条，让位给玩家 HUD，挪到左下角（左上给了金币/能力，右上小地图，
	# 正下是交互提示，只剩左下是空的）。
	_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_label.offset_left = 8.0
	_label.offset_top = -60.0
	_label.offset_right = 340.0
	_label.offset_bottom = -8.0
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 12)
	cv.add_child(_label)
	add_child(cv)
	print("[fps_stats] 模块已挂上")


func _process(delta: float) -> void:
	_frames += 1
	_acc += delta
	if _acc < 0.25:
		return
	var fps: float = float(_frames) / _acc
	_frames = 0
	_acc = 0.0

	var node_count: int = get_tree().get_node_count()
	var lobby := get_node_or_null("/root/Lobby")
	var mods := get_node_or_null("/root/Modules")
	if lobby != null and mods != null:
		var arr: Array = mods.list_modules()
		var on: int = 0
		for m in arr:
			if bool(m["running"]):
				on += 1
		_label.text = "FPS %.0f | 节点 %d | 在线 %d 人 | 模块 %d/%d" % [
			fps, node_count, lobby.player_count(), on, arr.size()]
	elif lobby != null:
		_label.text = "FPS %.0f | 节点 %d | 在线 %d 人" % [
			fps, node_count, lobby.player_count()]
	else:
		_label.text = "FPS %.0f | 节点 %d" % [fps, node_count]
