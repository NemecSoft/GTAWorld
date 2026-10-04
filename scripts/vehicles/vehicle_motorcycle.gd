extends ArcadeVehicle

## 【同 vehicle.gd：不要再用 @onready】
## picker 是**运行时**换脚本的，换脚本不会重跑 _ready，@onready 会全是 null。
## base 那边已经统一改成「var + bind_nodes() / _bind_extra()」，这里照样办。
var motorcycle: Node3D = null
var fork: Node3D = null

var wheel_front: Node3D = null
var wheel_back: Node3D = null


func _ready() -> void:

	super._ready()


# Overwrite functions from base vehicle script

## base 的 bind_nodes() 收尾会回调 _bind_extra()，摩托这套引用就在这里抓。
## 别写进 _ready()：picker 换完脚本只会重跑 bind_nodes，不会重跑 _ready。
func _bind_extra() -> void:

	motorcycle = get_node_or_null("Container/Model/motorcycle")
	fork = get_node_or_null("Container/Model/motorcycle/body/fork")

	wheel_front = get_node_or_null("Container/Model/motorcycle/wheel-front")
	wheel_back = get_node_or_null("Container/Model/motorcycle/wheel-back")

	# 摩托车身那一段单独当「俯仰 / 侧倾」的载体（原版就是这么绑的）
	vehicle_body = get_node_or_null("Container/Model/motorcycle/body")


func effect_body(delta):

	var target_lean = -input.x / 5 * linear_speed
	calculated_lean = lerp_angle(calculated_lean, target_lean, delta * 5)

	# Apply leaning when doing corners

	if motorcycle != null:
		motorcycle.rotation.z = lerp_angle(motorcycle.rotation.z, input.x * linear_speed, delta * 3)
		vehicle_body.rotation.x = lerp_angle(vehicle_body.rotation.x, -(linear_speed - acceleration) / 6, delta * 10)


func effect_wheels(delta):

	# Rotate wheels based on acceleration

	for wheel in [wheel_front, wheel_back]:
		if wheel != null:
			wheel.rotation.x += acceleration

	# Handle steering

	if wheel_front != null:
		fork.rotation.y = lerp_angle(fork.rotation.y, -input.x / 1.5, delta * 5)
		wheel_front.rotation.y = lerp_angle(wheel_front.rotation.y, -input.x / 1.5, delta * 10)
