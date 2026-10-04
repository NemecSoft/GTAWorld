extends SceneTree

# Headless map generator + verifier.
#
#   godot --headless --path . --script res://tools/gen_map.gd --seed=7
#       -> pure generation report (ascii + stats), no scene load.
#
#   godot --headless --path . --script res://tools/gen_map.gd --probe --seed=7
#       -> also boots scenes/main.tscn, settles the physics and reports
#          where the car actually ends up (that is how "car sank" is caught).
#
# Output: res://Temp/gen_map_report.txt

const MapGen := preload("res://scripts/world/mapgen.gd")

var _seed := -1
var _probe := false
var _out: PackedStringArray = []
var _phase := 0
var _ticks := 0
var _scene: Node = null
var _sphere: RigidBody3D = null
var _min_y := 1e9
var _max_y := -1e9
var _samples: PackedStringArray = []
var _hits: PackedStringArray = []


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--seed="):
			_seed = a.substr(7).to_int()
		elif a == "--probe":
			_probe = true
	if _seed < 0:
		_seed = randi()


func _process(_delta: float) -> bool:
	_ticks += 1
	if _ticks < 4 or _ticks > 28:
		print("tick " + str(_ticks) + " phase " + str(_phase))

	# NOTE: MainLoop._process returning true ENDS the main loop, so every tick
	# must return false until we are really done.
	if _phase == 0:
		_gen_report()
		if not _probe:
			_finish()
			return true
		_phase = 1
		_ticks = 0
		return false

	if _phase == 1:
		if _ticks > 30:
			_boot_scene()
			if _scene == null:
				_finish()
				return true
			_phase = 2
			_ticks = 0
		return false

	if _phase == 2:
		if _sphere == null:
			_sphere = root.find_child("Sphere", true, false) as RigidBody3D
		if _sphere != null:
			var y := _sphere.global_position.y
			_min_y = min(_min_y, y)
			_max_y = max(_max_y, y)
			if _ticks % 60 == 0:
				_samples.append("t=" + "%.2f" % (_ticks / 60.0) + "s  y=" + "%.3f" % y)
		if _ticks > 300:
			_ground_report()
			_finish()
			return true
	return true


func _gen_report() -> void:
	var res: Dictionary = MapGen.generate(_seed)
	_out.append("=== mapgen seed " + str(_seed) + " ===")
	_out.append(str(res["ascii"]))
	_out.append("")
	_out.append("stats = " + JSON.stringify(res["stats"]))


func _boot_scene() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		_out.append("!! scenes/main.tscn failed to load")
		return
	print("BOOT scene ...")
	_scene = packed.instantiate()
	root.add_child(_scene)
	print("BOOT scene ok = " + str(_scene != null))


# Probe the ground height under the whole map: how tall is the road surface,
# and is there anything at all to stand on?
func _ground_report() -> void:
	print("GROUND report ...")
	_out.append("")
	_out.append("--- ground probe ---")
	if _sphere == null:
		_out.append("!! no Sphere found in main.tscn")
		return
	_out.append("car y min=" + "%.3f" % _min_y + "  max=" + "%.3f" % _max_y)
	for s in _samples:
		_out.append(s)

	var rc := RayCast3D.new()
	rc.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, 0))
	rc.target_position = Vector3(0, -60.0, 0)
	root.add_child(rc)

	var gm := root.find_child("GridMap", true, false) as GridMap
	var cells: Array = []
	if gm != null:
		cells = gm.get_used_cells()

	var seen := {}
	var probes: Array = []
	for c in cells:
		var ci: Vector3i = c
		var key := str(ci.x) + "," + str(ci.z)
		if seen.has(key):
			continue
		seen[key] = true
		probes.append(ci)

	var gmin := 1e9
	var gmax := -1e9
	for ci in probes:
		rc.global_position = Vector3(float(ci.x) * 9.99, 60.0, float(ci.z) * 9.99)
		rc.force_raycast_update()
		if rc.is_colliding():
			var p: Vector3 = rc.get_collision_point()
			gmin = min(gmin, p.y)
			gmax = max(gmax, p.y)
			if _hits.size() < 12:
				_hits.append("cell(" + str(ci.x) + "," + str(ci.z) + ") item=" +
						str(gm.get_cell_item(ci)) + "  ground y=" + "%.3f" % p.y)
	rc.queue_free()

	_out.append("probed " + str(probes.size()) + " unique columns")
	if gmax > -1e8:
		_out.append("ground y range = " + "%.3f" % gmin + " .. " + "%.3f" % gmax)
		for h in _hits:
			_out.append(h)
	else:
		_out.append("!! NOTHING UNDER ANY TRACK CELL - the car will fall forever")


func _finish() -> void:
	var f := FileAccess.open("res://Temp/gen_map_report.txt", FileAccess.WRITE)
	if f == null:
		print("cannot write report")
		quit(1)
		return
	f.store_string("\n".join(_out) + "\n")
	f.close()
	print("gen_map report written")
	quit()
