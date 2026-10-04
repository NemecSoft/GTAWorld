extends Node
## core/modules.gd —— 模块注册表（autoload 名：Modules）
##
## 模块化契约（总纲 §3.1 / §3.3）：
##   * 每个可选模块是目录 modules/<name>/，里面必须有 mod.cfg 和入口脚本。
##   * mod.cfg（ConfigFile）字段：
##       script  = "module.gd"   入口脚本（相对模块目录）
##       deps    = ["core"]      依赖的模块名，可为空数组
##       enabled = true          默认是否启用
##       version = 1             MTARGET 版本号，跨存档兼容性判断
##   * 启动顺序：拓扑排序（依赖先起）→ 实例化 → add_child → 调入口的 mod_setup(ctx)。
##   * 单模块崩溃要能隔离：出错的模块只会 disable 自己，不拖垮整个游戏。
##
## 4.7 语法备忘：本 build 不支持 `..` 区间语法，循环一律 range(a, b + 1)；
##               也不支持 `fn` 定义局部函数（局部逻辑写进 _process 或用内联方法）。

const MODULES_ROOT := "res://modules"

var _modules: Dictionary = {}   # name -> {dir, script, deps, enabled, version, node}
var _order: Array = []          # 拓扑排序结果（依赖在前）
var _ctx: Node = null           # 共享上下文，交给每个模块入口

func _ready() -> void:
	name = "Modules"
	process_mode = Node.PROCESS_MODE_ALWAYS
	scan()
	if _ctx == null:
		_ctx = get_tree().root
	_enable_all()
	print("[Modules] 可用 %d 个，启用 %d 个：%s" % [
		_modules.size(), _order.size(), str(_order)])


## 扫描 modules/ 子目录并读 mod.cfg（只解析，不实例化）
func scan() -> void:
	if DirAccess.open(MODULES_ROOT) == null:   # 4.7 没有 DirAccess.dir_exists 静态函数
		return
	var dir := DirAccess.open(MODULES_ROOT)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with(".") and dir.current_is_dir():
			_load_manifest(entry)
		entry = dir.get_next()
	dir.list_dir_end()


func _load_manifest(mod_name: String) -> void:
	var cfg_path: String = "%s/%s/mod.cfg" % [MODULES_ROOT, mod_name]
	if not FileAccess.file_exists(cfg_path):
		return
	var cf := ConfigFile.new()
	if cf.load(cfg_path) != OK:
		push_warning("[Modules] mod.cfg 读不了，跳过：%s" % cfg_path)
		return
	_modules[mod_name] = {
		"dir": mod_name,
		"script": String(cf.get_value("module", "script", "module.gd")),
		"deps": Array(cf.get_value("module", "deps", [])),
		"enabled": bool(cf.get_value("module", "enabled", true)),
		"version": int(cf.get_value("module", "version", 1)),
		"node": null,
	}


## 依赖优先的拓扑排序（显式栈，模块数个位数，深度不会爆）
func _topo_sort() -> void:
	_order = []
	var state: Dictionary = {}   # name -> 0 未访问 / 1 正在处理 / 2 已完成
	for name in _modules.keys():
		if int(state.get(name, 0)) != 0:
			continue
		var stack: Array = [name]
		while not stack.is_empty():
			var cur: String = String(stack.pop_back())
			var phase: int = int(state.get(cur, 0))
			if phase == 1 or phase == 2:
				continue
			state[cur] = 1
			var deps: Array = Array((_modules[cur] as Dictionary).get("deps", []))
			var pending: Array = []
			for d in deps:
				var dn: String = String(d)
				if not _modules.has(dn):
					push_warning("[Modules] %s 的依赖 %s 不存在，已忽略" % [cur, dn])
					continue
				var ds: int = int(state.get(dn, 0))
				if ds != 2:
					pending.append(dn)
			if not pending.is_empty():
				state[cur] = 0          # 先压回去，等依赖完成后再来
				stack.append(cur)
				for dn in pending:
					stack.append(dn)
				continue
			state[cur] = 2
			_order.append(cur)


func _enable_all() -> void:
	_topo_sort()
	for name in _order:
		if is_enabled(name):
			enable(name)


## 实例化并启用一个模块。返回是否成功。
func enable(name: String) -> bool:
	if not _modules.has(name):
		push_warning("[Modules] 没有这个模块：%s" % name)
		return false
	var md: Dictionary = _modules[name]
	if md["node"] != null:
		return true                       # 已经起来了
	if not bool(md.get("enabled", false)):
		return false
	# 依赖先起
	for d in Array(md.get("deps", [])):
		var dn: String = String(d)
		if _modules.has(dn) and _modules[dn]["node"] == null:
			enable(dn)
	var script_path: String = "%s/%s/%s" % [MODULES_ROOT, name, String(md.get("script", "module.gd"))]
	if not ResourceLoader.exists(script_path):
		push_warning("[Modules] 缺入口脚本，模块下线：%s" % script_path)
		md["enabled"] = false
		return false
	var mod_class = load(script_path)
	if mod_class == null:
		push_warning("[Modules] 脚本加载失败，模块下线：%s" % script_path)
		md["enabled"] = false
		return false
	var node: Node = mod_class.new()
	node.name = "Mod_" + name
	node.set_meta("mod_name", name)
	node.set_meta("mod_version", int(md.get("version", 1)))
	add_child(node)
	md["node"] = node
	if node.has_method("mod_setup"):
		node.call("mod_setup", _ctx)
	elif node.has_method("_enter_module"):
		node.call("_enter_module", _ctx)
	print("[Modules] 启用 %s v%s" % [name, str(md.get("version", 1))])
	return true


func disable(name: String) -> void:
	if not _modules.has(name):
		return
	var node: Node = _modules[name]["node"]
	if node == null:
		return
	if node.has_method("_exit_module"):
		node.call("_exit_module")
	node.queue_free()
	_modules[name]["node"] = null


func is_enabled(name: String) -> bool:
	if not _modules.has(name):
		return false
	return bool((_modules[name] as Dictionary).get("enabled", false))


func get_module_node(name: String) -> Node:
	if not _modules.has(name):
		return null
	return (_modules[name] as Dictionary).get("node", null) as Node


## 调试用：返回 [{name, enabled, version, deps, running}, ...]
func list_modules() -> Array:
	var out: Array = []
	for name in _modules.keys():
		var md: Dictionary = _modules[name]
		out.append({
			"name": name,
			"enabled": bool(md.get("enabled", false)),
			"version": int(md.get("version", 1)),
			"deps": Array(md.get("deps", [])),
			"running": md.get("node", null) != null,
		})
	out.sort_custom(func(a, b) -> bool:
		return String(a["name"]) < String(b["name"]))
	return out
