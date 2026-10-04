@tool
extends SceneTree

## Headless installer for gdtuner addon.
## Usage: godot --headless --script addons/gdtuner/installer.gd
## Ensures plugin is enabled and autoload is registered in project.godot.


func _init() -> void:
	var cfg_path := "res://project.godot"
	var config := ConfigFile.new()
	var err := config.load(cfg_path)
	if err != OK:
		print("[gdtuner] ERROR: Could not load project.godot (error %d)" % err)
		print("[gdtuner] Make sure you run this from the project root directory.")
		quit(1)
		return

	var changed := false

	# Enable plugin
	var plugins: PackedStringArray = config.get_value("editor_plugins", "enabled", PackedStringArray())
	var plugin_entry := "res://addons/gdtuner/plugin.cfg"
	if not plugins.has(plugin_entry):
		plugins.append(plugin_entry)
		config.set_value("editor_plugins", "enabled", plugins)
		changed = true
		print("[gdtuner] Plugin enabled.")
	else:
		print("[gdtuner] Plugin already enabled.")

	# Register autoload
	var autoload_key := "DebugTuner"
	var autoload_path := "*res://addons/gdtuner/debug_tuner.gd"
	var current_autoload: String = config.get_value("autoload", autoload_key, "")
	if current_autoload != autoload_path:
		config.set_value("autoload", autoload_key, autoload_path)
		changed = true
		print("[gdtuner] Autoload 'DebugTuner' registered.")
	else:
		print("[gdtuner] Autoload 'DebugTuner' already registered.")

	if changed:
		err = config.save(cfg_path)
		if err != OK:
			print("[gdtuner] ERROR: Could not save project.godot (error %d)" % err)
			quit(1)
			return
		print("[gdtuner] Installation complete!")
	else:
		print("[gdtuner] Already installed, no changes needed.")

	quit(0)
