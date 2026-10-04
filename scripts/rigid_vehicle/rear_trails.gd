extends GPUParticles3D

var trail_material = load("res://materials/misc/trail.tres")
var car : RayVehicle
var speed_threshold := 50

func update_vars() -> void:
	if car.linear_velocity.dot(car.global_basis.x) < speed_threshold:
		emitting = false
		return
	else: emitting = true
	
	var pm = process_material
	pm.set("initial_velocity_min", (car.linear_velocity.length() - speed_threshold) / 25)
	pm.set("initial_velocity_max", (car.linear_velocity.length() - speed_threshold) / 25)
