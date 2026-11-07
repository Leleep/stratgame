@tool
extends Control


# Add these at the top of your script with your other exports/constants:
@export_category("Audio Effects")
@export var click_stream: AudioStream
@export var hover_stream: AudioStream

@onready var sfx_player: AudioStreamPlayer2D = $buttonSFX

# Add these helper functions anywhere in your script:
func play_click_sfx() -> void:
	if click_stream:
		sfx_player.stream = click_stream
		sfx_player.play()

func play_hover_sfx() -> void:
	if hover_stream:
		sfx_player.stream = hover_stream
		sfx_player.play()


const GRID_SIZE := 8
const HALF := GRID_SIZE / 2
const MIN_CELL := 24
const SEP := 2
const MID_THICKNESS := 4

@export_category("Visual Assets")
@export var floor_texture: Texture2D
@export var player_texture: Texture2D
@export var enemy_texture: Texture2D

@export_category("Combat Effects")
@export var hit_flash_duration: float = 0.35
@export var hit_flash_color: Color = Color(1.0, 0.3, 0.3, 1.0)

const MAX_CELL := 48
const MAX_GRID_PX := 560

@onready var grid: GridContainer = $MarginContainer/VBox/GridHolder/Grid
@onready var grid_holder: Control = $MarginContainer/VBox/GridHolder
@onready var mid_line: ColorRect = $MarginContainer/VBox/GridHolder/MidLine
@onready var player_bar: ProgressBar = $HUD/HealthBars/PlayerBox/HBoxContainer/MarginContainer/PlayerBar
@onready var hunger_bar: ProgressBar = $HUD/HealthBars/PlayerBox/HBoxContainer2/MarginContainer2/HungerBar
@onready var enemy_bar: ProgressBar = $HUD/HealthBars/HBoxContainer/PanelContainer/EnemyBar
@onready var move_button: Button = $MarginContainer/VBox/Buttons/MoveButton
@onready var attack_button: Button = $MarginContainer/VBox/Buttons/AttackButton
@onready var eat_button: Button = $MarginContainer/VBox/Buttons/EatButton
@onready var attack_options: HBoxContainer = $MarginContainer/VBox/AttackOptions
@onready var single_button: Button = $MarginContainer/VBox/AttackOptions/SingleButton
@onready var aoe_button: Button = $MarginContainer/VBox/AttackOptions/AoeButton
@onready var status_label: Label = $StatusLabel

@onready var ammo_label: Label = $ResourcePanel/ResourceList/MarginContainer/HBoxContainer/AmmoLabel
@onready var food_label: Label = $ResourcePanel/ResourceList/MarginContainer2/HBoxContainer2/FoodLabel
@onready var coin_label: Label = $ResourcePanel/ResourceList/MarginContainer3/HBoxContainer3/CoinLabel
@onready var weight_label: Label = $ResourcePanel/ResourceList/MarginContainer4/HBoxContainer4/WeightLabel
@onready var weight_bar: ProgressBar = $ResourcePanel/ResourceList/WeightBar

var cells: Array[TextureRect] = []
var cell_size := MAX_CELL

# Direction tracking: Player defaults to Up (0°), Enemy inverted to Down (180°)
var last_player_pos := Vector2i(-1, -1)
var player_rotation_deg := 0.0

var last_enemy_pos := Vector2i(-1, -1)
var enemy_rotation_deg := 180.0

func _ready() -> void:
	_build_grid()
	_build_midline()
	attack_options.hide()

	if not Engine.is_editor_hint():
		_setup_test_data()

		# Listen to CombatManager signals
		CombatManager.combat_started.connect(_on_combat_started)
		CombatManager.combat_ended.connect(_on_combat_ended)
		CombatManager.state_changed.connect(_update_ui)
		CombatManager.log_message.connect(func(msg): status_label.text = msg)
		CombatManager.grid_refreshed.connect(refresh_grid)
		CombatManager.cell_flashed.connect(_flash_cell)

		# Listen to GameManager signals
		GameManager.health_changed.connect(_on_health_changed)
		GameManager.hunger_changed.connect(_on_hunger_changed)
		GameManager.inventory_changed.connect(_update_resources)

		# UI Actions send commands to CombatManager
		move_button.pressed.connect(func():
			attack_options.hide()
			CombatManager.set_player_mode(CombatManager.Mode.MOVE)
		)
		attack_button.pressed.connect(func():
			if CombatManager.is_busy: return
			attack_options.show()
			status_label.text = "Choose an attack"
		)
		eat_button.pressed.connect(func():
			CombatManager.on_cell_clicked(Vector2i.ZERO)
		)
		single_button.pressed.connect(func(): CombatManager.set_player_mode(CombatManager.Mode.SINGLE))
		aoe_button.pressed.connect(func(): CombatManager.set_player_mode(CombatManager.Mode.AOE))

		# Initial sync
		_update_resources()
		_on_health_changed(GameManager.current_health, GameManager.get_max_health())
		_on_hunger_changed(GameManager.hunger, GameManager.MAX_HUNGER)
		
		CombatManager.start_combat()

	refresh_grid()

func _build_grid() -> void:
	if not grid:
		return

	# Clear existing cells (vital for @tool mode re-loads)
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	cells.clear()

	_compute_cell_size()

	grid.columns = GRID_SIZE
	grid.add_theme_constant_override("h_separation", SEP)
	grid.add_theme_constant_override("v_separation", SEP)

	var total := GRID_SIZE * cell_size + (GRID_SIZE - 1) * SEP
	if grid_holder:
		grid_holder.custom_minimum_size = Vector2(total, total)

	for y in GRID_SIZE:
		for x in GRID_SIZE:
			var cell := TextureRect.new()
			cell.custom_minimum_size = Vector2(cell_size, cell_size)
			cell.pivot_offset = Vector2(cell_size, cell_size) / 2.0 # Center point for rotation
			cell.expand_mode = TextureRect.EXPAND_FIT_WIDTH
			cell.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			cell.mouse_filter = Control.MOUSE_FILTER_STOP
			
			var p := Vector2i(x, y)
			cell.gui_input.connect(func(event):
				if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
					if not Engine.is_editor_hint():
						CombatManager.on_cell_clicked(p)
			)
			grid.add_child(cell)
			cells.append(cell)

func _build_midline() -> void:
	if not mid_line:
		return
	mid_line.color = Color(0.9, 0.9, 0.9)
	mid_line.size = Vector2(GRID_SIZE * cell_size + (GRID_SIZE - 1) * SEP, MID_THICKNESS)
	mid_line.position = Vector2(0, HALF * (cell_size + SEP) - SEP / 2.0 - MID_THICKNESS / 2.0)

func refresh_grid() -> void:
	if cells.is_empty():
		return
		
	var default_player_pos := Vector2i(GRID_SIZE / 2, GRID_SIZE - 2)
	var default_enemy_pos := Vector2i(GRID_SIZE / 2, HALF - 2)

	var p_pos := CombatManager.player_pos if not Engine.is_editor_hint() else default_player_pos
	var e_pos := CombatManager.enemy_pos if not Engine.is_editor_hint() else default_enemy_pos

	# Safety clamp to prevent out-of-bounds crashes
	p_pos.x = clamp(p_pos.x, 0, GRID_SIZE - 1)
	p_pos.y = clamp(p_pos.y, 0, GRID_SIZE - 1)
	e_pos.x = clamp(e_pos.x, 0, GRID_SIZE - 1)
	e_pos.y = clamp(e_pos.y, 0, GRID_SIZE - 1)

	# Initialize tracking positions on first run
	if last_player_pos == Vector2i(-1, -1):
		last_player_pos = p_pos
	if last_enemy_pos == Vector2i(-1, -1):
		last_enemy_pos = e_pos

	# Calculate player rotation with inverted delta mapping
	if p_pos != last_player_pos:
		var diff := p_pos - last_player_pos
		if diff.x > 0: player_rotation_deg = 270.0    # Right (Inverted)
		elif diff.x < 0: player_rotation_deg = 90.0   # Left (Inverted)
		elif diff.y > 0: player_rotation_deg = 0.0    # Down (Inverted)
		elif diff.y < 0: player_rotation_deg = 180.0  # Up (Inverted)
		last_player_pos = p_pos

	# Calculate enemy rotation with inverted delta mapping
	if e_pos != last_enemy_pos:
		var diff := e_pos - last_enemy_pos
		if diff.x > 0: enemy_rotation_deg = 270.0
		elif diff.x < 0: enemy_rotation_deg = 90.0
		elif diff.y > 0: enemy_rotation_deg = 0.0
		elif diff.y < 0: enemy_rotation_deg = 180.0
		last_enemy_pos = e_pos

	for y in GRID_SIZE:
		for x in GRID_SIZE:
			var p := Vector2i(x, y)
			var index = y * GRID_SIZE + x
			var cell := cells[index]
			
			if p == p_pos:
				cell.texture = player_texture
				cell.rotation_degrees = player_rotation_deg
			elif p == e_pos:
				cell.texture = enemy_texture
				cell.rotation_degrees = enemy_rotation_deg
			else:
				cell.texture = floor_texture
				cell.rotation_degrees = 0.0

func _flash_cell(p: Vector2i, _flash_color: Color) -> void:
	p.x = clamp(p.x, 0, GRID_SIZE - 1)
	p.y = clamp(p.y, 0, GRID_SIZE - 1)
	
	var cell := cells[p.y * GRID_SIZE + p.x]
	cell.modulate = hit_flash_color
	var tween := create_tween()
	tween.tween_property(cell, "modulate", Color.WHITE, hit_flash_duration)

func _update_ui() -> void:
	var locked := CombatManager.is_busy
	var ammo := GameManager.get_item_count(GameManager.ItemType.AMMO)
	var single_cost := GameManager.get_attack_ammo_cost(false)
	var aoe_cost := GameManager.get_attack_ammo_cost(true)

	single_button.text = "Single (%d ammo)" % single_cost
	aoe_button.text = "AOE (%d ammo)" % aoe_cost

	move_button.disabled = locked
	attack_button.disabled = locked or ammo < single_cost
	single_button.disabled = locked or ammo < single_cost
	aoe_button.disabled = locked or ammo < aoe_cost
	eat_button.disabled = locked or (GameManager.hunger >= GameManager.MAX_HUNGER or GameManager.get_item_count(GameManager.ItemType.FOOD) < 1)

	enemy_bar.max_value = CombatManager.enemy_max_hp
	enemy_bar.value = CombatManager.enemy_hp
	if locked:
		attack_options.hide()

func _on_combat_started() -> void:
	show()
	_update_ui()
	refresh_grid()

func _on_combat_ended(_won: bool) -> void:
	_update_ui()

func _on_health_changed(current: int, maximum: int) -> void:
	player_bar.max_value = maximum
	player_bar.value = current

func _on_hunger_changed(current: int, maximum: int) -> void:
	hunger_bar.max_value = maximum
	hunger_bar.value = current
	_update_ui()

func _update_resources() -> void:
	ammo_label.text = "Ammo: %d" % GameManager.get_item_count(GameManager.ItemType.AMMO)
	food_label.text = "Food: %d" % GameManager.get_item_count(GameManager.ItemType.FOOD)
	coin_label.text = "Coins: %d" % GameManager.get_item_count(GameManager.ItemType.COIN)
	var total := GameManager.get_total_weight()
	var maximum := GameManager.get_max_weight()
	weight_bar.max_value = maximum
	weight_bar.value = total
	weight_label.text = "Weight: %.1f / %.1f" % [total, maximum]
	_update_ui()

func _compute_cell_size() -> void:
	var viewport_size := get_viewport_rect().size
	if viewport_size == Vector2.ZERO:
		viewport_size = Vector2(800, 600)
	var available_space := minf(viewport_size.x * 0.55, viewport_size.y * 0.65)
	var total_sep_space := (GRID_SIZE - 1) * SEP
	cell_size = maxi(int((available_space - total_sep_space) / float(GRID_SIZE)), 16)
	
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_resize_grid()

func _resize_grid() -> void:
	if cells.is_empty() or not is_inside_tree():
		return
		
	_compute_cell_size()
	
	var total := GRID_SIZE * cell_size + (GRID_SIZE - 1) * SEP
	if grid_holder:
		grid_holder.custom_minimum_size = Vector2(total, total)
	
	for cell in cells:
		cell.custom_minimum_size = Vector2(cell_size, cell_size)
		cell.pivot_offset = Vector2(cell_size, cell_size) / 2.0
		
	_build_midline()

func _setup_test_data() -> void:
	GameManager.add_item(GameManager.ItemType.AMMO, 20)
	GameManager.add_item(GameManager.ItemType.FOOD, 5)
	GameManager.add_item(GameManager.ItemType.COIN, 10)
	GameManager.heal_player(GameManager.get_max_health())
	GameManager.change_hunger(GameManager.MAX_HUNGER)
	print("Test data loaded into GameManager successfully!")
