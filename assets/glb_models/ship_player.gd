extends Node3D

@export_group("Movement")
@export var max_speed: float = 12.0
@export var acceleration: float = 4.0
@export var drag: float = 2.0
@export var turn_speed: float = 1.4
@export var min_turn_factor: float = 0.25

@export_group("Lean")
@export var max_lean_degrees: float = 12.0  # negative value leans outward instead
@export var lean_response: float = 5.0      # higher = snappier lean

@export_group("Camera")
@export var cam_distance: float = 9.0
@export var cam_height: float = 5.0
@export var look_height: float = 1.5
@export var cam_follow_speed: float = 5.0
@export var cam_fov: float = 70.0

@export_group("Acceleration Zoom")
@export var zoom_in_distance: float = 2.0   # how much closer the camera gets
@export var zoom_in_fov: float = 6.0        # how many degrees FOV narrows
@export var zoom_end_ratio: float = 0.6     # zoom fades out as speed nears this fraction of max
@export var zoom_response: float = 3.0      # how fast the zoom eases in/out

@export_group("Ship Model")
@export var model_faces_positive_z: bool = false

var speed: float = 0.0
var yaw: float = 0.0
var roll: float = 0.0
var zoom_kick: float = 0.0
var steer_input: float = 0.0
var camera: Camera3D


func _ready() -> void:
	_ensure_input_actions()
	yaw = rotation.y
	camera = _find_or_create_camera()
	camera.top_level = true
	camera.fov = cam_fov
	camera.global_position = _desired_cam_position()
	_aim_camera(1.0)


func _physics_process(delta: float) -> void:
	var throttle := Input.is_action_pressed("move_forward")
	var speed_ratio := clampf(speed / max_speed, 0.0, 1.0)

	# --- Throttle (forward only) ---
	if throttle:
		speed = move_toward(speed, max_speed, acceleration * delta)
	else:
		speed = move_toward(speed, 0.0, drag * delta)

	# --- Steering ---
	steer_input = Input.get_axis("turn_right", "turn_left")
	var turn_factor := lerpf(min_turn_factor, 1.0, speed_ratio)
	if speed > 0.05:
		yaw += steer_input * turn_speed * turn_factor * delta

	# --- Lean (roll into the turn, stronger at higher speed) ---
	var target_roll := 0.0
	if speed > 0.05:
		target_roll = deg_to_rad(max_lean_degrees) * steer_input * speed_ratio
	roll = lerpf(roll, target_roll, 1.0 - exp(-lean_response * delta))

	# Apply yaw + roll. Roll is about the ship's local Z (its forward axis),
	# so it never changes the direction the ship travels.
	rotation = Vector3(0.0, yaw, roll)

	# --- Move ---
	global_position += _forward() * speed * delta

	# --- Zoom kick target: on while accelerating from a standstill ---
	var accelerating := throttle and speed_ratio < zoom_end_ratio
	var target_kick := 1.0 if accelerating else 0.0
	zoom_kick = lerpf(zoom_kick, target_kick, 1.0 - exp(-zoom_response * delta))


func _process(delta: float) -> void:
	camera.fov = cam_fov - zoom_in_fov * zoom_kick

	var t := 1.0 - exp(-cam_follow_speed * delta)
	camera.global_position = camera.global_position.lerp(_desired_cam_position(), t)
	_aim_camera(t)


# ---------- Helpers ----------

func _forward() -> Vector3:
	var f := -global_transform.basis.z
	return -f if model_faces_positive_z else f


func _desired_cam_position() -> Vector3:
	var dist := cam_distance - zoom_in_distance * zoom_kick
	return global_position - _forward() * dist + Vector3.UP * cam_height


func _aim_camera(t: float) -> void:
	var target := global_position + Vector3.UP * look_height
	var desired := camera.global_transform.looking_at(target, Vector3.UP)
	camera.global_transform = camera.global_transform.interpolate_with(desired, t)


func _find_or_create_camera() -> Camera3D:
	for child in find_children("*", "Camera3D", true, false):
		return child as Camera3D
	var cam := Camera3D.new()
	cam.name = "ChaseCamera"
	add_child(cam)
	cam.current = true
	return cam


func _ensure_input_actions() -> void:
	_add_key_action("move_forward", KEY_W)
	_add_key_action("turn_left", KEY_A)
	_add_key_action("turn_right", KEY_D)


func _add_key_action(action: String, key: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	InputMap.action_add_event(action, ev)
