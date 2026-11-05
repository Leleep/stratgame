extends Node3D

const GAME_SCENE := "res://sea_world.tscn"  # change to your game scene

@export var tween_time := 0.7
@export var sway_amount := 0.15

@onready var camera: Camera3D = $Camera3D
@onready var markers: Node3D = $CameraMarkers
@onready var buttons: VBoxContainer = $UI/VBoxContainer
@onready var fade: ColorRect = $UI/Fade

var tween: Tween
var return_timer: Timer
var time := 0.0

func _ready() -> void:
	# Make the world scene harmless in the menu
	var ship := $SeaWorld.get_node_or_null("ShipPlayer")
	if ship:
		ship.process_mode = Node.PROCESS_MODE_DISABLED
		for c in ship.find_children("*", "Camera3D", true, false):
			c.current = false
	camera.current = true

	# Start at the wide shot
	camera.global_transform = markers.get_node("Default").global_transform

	# Delay before returning to the wide shot
	return_timer = Timer.new()
	return_timer.one_shot = true
	return_timer.wait_time = 0.2
	return_timer.timeout.connect(_focus_marker.bind("Default"))
	add_child(return_timer)

	# Hook up the buttons generically
	for child in buttons.get_children():
		if child is Button:
			var marker_name: String = child.name.trim_suffix("Button")
			child.mouse_entered.connect(_on_hover.bind(marker_name))
			child.focus_entered.connect(_on_hover.bind(marker_name))
			child.mouse_exited.connect(return_timer.start)
			child.focus_exited.connect(return_timer.start)

	$UI/VBoxContainer/PlayButton.pressed.connect(_on_play)
	$UI/VBoxContainer/QuitButton.pressed.connect(get_tree().quit)

func _process(delta: float) -> void:
	# Idle sway uses offsets, so it doesn't fight the tween
	time += delta
	camera.h_offset = sin(time * 0.5) * sway_amount
	camera.v_offset = cos(time * 0.4) * sway_amount * 0.5

func _on_hover(marker_name: String) -> void:
	return_timer.stop()
	_focus_marker(marker_name)

func _focus_marker(marker_name: String) -> void:
	var marker := markers.get_node_or_null(marker_name) as Marker3D
	if marker == null:
		return
	if tween:
		tween.kill()
	tween = create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(camera, "global_transform", marker.global_transform, tween_time)

func _on_play() -> void:
	for b in buttons.get_children():
		if b is Button:
			b.disabled = true
	var t := create_tween()
	t.tween_property(fade, "color:a", 1.0, 0.6)
	t.tween_callback(func(): get_tree().change_scene_to_file(GAME_SCENE))
