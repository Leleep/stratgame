extends Control

# ---------- grid / layout ----------
const HALF := 6
const GRID_SIZE := HALF * 2          # always even
const MAX_CELL := 48                 # cell size when the grid is small
const MAX_GRID_PX := 560             # grid never exceeds this many pixels per side
const SEP := 2
const MID_THICKNESS := 4

# ---------- enemy stats (player stats come from GameManager) ----------
const ENEMY_MAX_HP := 100
const ENEMY_SINGLE_DAMAGE := 12
const ENEMY_AOE_CENTER_DAMAGE := 18
const ENEMY_AOE_EDGE_DAMAGE := 7

# ---------- timing ----------
const FLASH_TIME := 0.35
const ENEMY_DELAY := 0.7
const ATTACK_GAP := 0.5
const MOVE_GAP := 0.4

# ---------- colors ----------
const PLAYER_COLOR := Color(0.25, 0.55, 1.0)
const ENEMY_COLOR := Color(1.0, 0.65, 0.15)
const ENEMY_SIDE_COLOR := Color(0.16, 0.12, 0.12)
const PLAYER_SIDE_COLOR := Color(0.12, 0.12, 0.17)
const HIT_COLOR := Color(1.0, 0.1, 0.1)
const MISS_COLOR := Color(1.0, 1.0, 1.0)
const MID_COLOR := Color(0.9, 0.9, 0.9)
const HUNGER_COLOR := Color(0.6, 0.85, 0.3)
const WEIGHT_COLOR := Color(0.7, 0.7, 0.75)
const WEIGHT_FULL_COLOR := Color(1.0, 0.35, 0.3)

enum Mode { NONE, MOVE, SINGLE, AOE, EAT }

@onready var grid: GridContainer = $VBox/GridHolder/Grid
@onready var grid_holder: Control = $VBox/GridHolder
@onready var mid_line: ColorRect = $VBox/GridHolder/MidLine
@onready var player_bar: ProgressBar = $HUD/HealthBars/PlayerBox/PlayerBar
@onready var hunger_bar: ProgressBar = $HUD/HealthBars/PlayerBox/HungerBar
@onready var enemy_bar: ProgressBar = $HUD/HealthBars/EnemyBox/EnemyBar
@onready var move_button: Button = $VBox/Buttons/MoveButton
@onready var attack_button: Button = $VBox/Buttons/AttackButton
@onready var eat_button: Button = $VBox/Buttons/EatButton
@onready var attack_options: HBoxContainer = $VBox/AttackOptions
@onready var single_button: Button = $VBox/AttackOptions/SingleButton
@onready var aoe_button: Button = $VBox/AttackOptions/AoeButton
@onready var status_label: Label = $VBox/StatusLabel
@onready var ammo_label: Label = $ResourcePanel/ResourceList/AmmoLabel
@onready var food_label: Label = $ResourcePanel/ResourceList/FoodLabel
@onready var coin_label: Label = $ResourcePanel/ResourceList/CoinLabel
@onready var weight_label: Label = $ResourcePanel/ResourceList/WeightLabel
@onready var weight_bar: ProgressBar = $ResourcePanel/ResourceList/WeightBar

var cells: Array[ColorRect] = []
var player_pos := Vector2i(HALF, GRID_SIZE - 2)
var enemy_pos := Vector2i(HALF - 1, 1)
var enemy_hp := ENEMY_MAX_HP
var mode := Mode.NONE
var busy := false
var game_over := false
var cell_size := MAX_CELL
var enemy_action := Mode.NONE
var enemy_dest := Vector2i.ZERO   # move destination, or attack centre


func _ready() -> void:
	var panel: Control = $ResourcePanel
	panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)  # must come first, it resets offsets
	panel.offset_left = -196
	panel.offset_right = -16
	panel.offset_top = -90
	panel.offset_bottom = 90
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	_build_grid()
	_build_midline()
	attack_options.hide()

	for bar in [player_bar, hunger_bar, enemy_bar, weight_bar]:
		bar.show_percentage = false
	enemy_bar.max_value = ENEMY_MAX_HP
	player_bar.modulate = PLAYER_COLOR
	hunger_bar.modulate = HUNGER_COLOR
	enemy_bar.modulate = ENEMY_COLOR

	# TEMP: starter items for testing. Remove once you have a real way to earn them.
	GameManager.add_item(GameManager.ItemType.AMMO, 20)
	GameManager.add_item(GameManager.ItemType.FOOD, 5)
	GameManager.add_item(GameManager.ItemType.COIN, 10)

	move_button.pressed.connect(_on_move_pressed)
	attack_button.pressed.connect(_on_attack_pressed)
	eat_button.pressed.connect(_on_eat_pressed)
	single_button.pressed.connect(_set_mode.bind(Mode.SINGLE))
	aoe_button.pressed.connect(_set_mode.bind(Mode.AOE))

	# The UI listens to GameManager, so any change to HP, hunger or items
	# (from anywhere in the game) updates the screen automatically.
	GameManager.health_changed.connect(_on_health_changed)
	GameManager.hunger_changed.connect(_on_hunger_changed)
	GameManager.inventory_changed.connect(_update_resources)

	_on_health_changed(GameManager.current_health, GameManager.get_max_health())
	_on_hunger_changed(GameManager.hunger, GameManager.MAX_HUNGER)
	_update_resources()
	_update_enemy_bar()
	_refresh()
	_set_status("Your turn: choose Move, Attack or Eat")


# ---------- setup ----------

func _build_grid() -> void:
	_compute_cell_size()
	grid.columns = GRID_SIZE
	grid.add_theme_constant_override("h_separation", SEP)
	grid.add_theme_constant_override("v_separation", SEP)

	var total := _grid_pixels()
	grid_holder.custom_minimum_size = Vector2(total, total)

	for y in GRID_SIZE:
		for x in GRID_SIZE:
			var cell := ColorRect.new()
			cell.custom_minimum_size = Vector2(cell_size, cell_size)
			cell.mouse_filter = Control.MOUSE_FILTER_STOP
			cell.gui_input.connect(_on_cell_input.bind(Vector2i(x, y)))
			grid.add_child(cell)
			cells.append(cell)


func _build_midline() -> void:
	mid_line.color = MID_COLOR
	mid_line.size = Vector2(_grid_pixels(), MID_THICKNESS)
	mid_line.position = Vector2(0, HALF * (cell_size + SEP) - SEP / 2.0 - MID_THICKNESS / 2.0)


# ---------- helpers ----------

func _compute_cell_size() -> void:
	var available := MAX_GRID_PX - (GRID_SIZE - 1) * SEP
	cell_size = clampi(int(available / float(GRID_SIZE)), 4, MAX_CELL)


func _grid_pixels() -> int:
	return GRID_SIZE * cell_size + (GRID_SIZE - 1) * SEP


func _idx(p: Vector2i) -> int:
	return p.y * GRID_SIZE + p.x


func _in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.x < GRID_SIZE and p.y >= 0 and p.y < GRID_SIZE


func _on_player_side(p: Vector2i) -> bool:
	return p.y >= HALF


func _on_enemy_side(p: Vector2i) -> bool:
	return p.y < HALF


func _is_adjacent(a: Vector2i, b: Vector2i) -> bool:
	return absi(a.x - b.x) + absi(a.y - b.y) == 1


func _is_attack(m: Mode) -> bool:
	return m == Mode.SINGLE or m == Mode.AOE


func _can_eat() -> bool:
	return GameManager.hunger < GameManager.MAX_HUNGER \
			and GameManager.get_item_count(GameManager.ItemType.FOOD) >= 1


func _color_at(p: Vector2i) -> Color:
	if p == player_pos:
		return PLAYER_COLOR
	if p == enemy_pos:
		return ENEMY_COLOR
	return PLAYER_SIDE_COLOR if _on_player_side(p) else ENEMY_SIDE_COLOR


func _refresh() -> void:
	for y in GRID_SIZE:
		for x in GRID_SIZE:
			var p := Vector2i(x, y)
			cells[_idx(p)].color = _color_at(p)


func _flash(p: Vector2i, flash_color: Color) -> void:
	var cell := cells[_idx(p)]
	cell.color = flash_color
	var tween := create_tween()
	tween.tween_property(cell, "color", _color_at(p), FLASH_TIME)
	tween.tween_callback(_refresh)


func _set_status(text: String) -> void:
	status_label.text = text


# ---------- UI sync ----------

func _on_health_changed(current: int, maximum: int) -> void:
	player_bar.max_value = maximum
	player_bar.value = current


func _on_hunger_changed(current: int, maximum: int) -> void:
	hunger_bar.max_value = maximum
	hunger_bar.value = current
	_update_buttons()


func _update_enemy_bar() -> void:
	enemy_bar.value = enemy_hp


func _update_resources() -> void:
	ammo_label.text = "Ammo: %d" % GameManager.get_item_count(GameManager.ItemType.AMMO)
	food_label.text = "Food: %d" % GameManager.get_item_count(GameManager.ItemType.FOOD)
	coin_label.text = "Coins: %d" % GameManager.get_item_count(GameManager.ItemType.COIN)

	var total := GameManager.get_total_weight()
	var maximum := GameManager.get_max_weight()
	weight_bar.max_value = maximum
	weight_bar.value = total
	weight_bar.modulate = WEIGHT_FULL_COLOR if total >= maximum - 0.0001 else WEIGHT_COLOR
	weight_label.text = "Weight: %.1f / %.1f" % [total, maximum]
	_update_buttons()


# Every button's enabled state is recomputed from the current state in one place.
func _update_buttons() -> void:
	var locked := busy or game_over
	var ammo := GameManager.get_item_count(GameManager.ItemType.AMMO)
	var single_cost := GameManager.get_attack_ammo_cost(false)
	var aoe_cost := GameManager.get_attack_ammo_cost(true)

	single_button.text = "Single (%d ammo)" % single_cost
	aoe_button.text = "AOE (%d ammo)" % aoe_cost

	move_button.disabled = locked
	attack_button.disabled = locked or ammo < single_cost
	single_button.disabled = locked or ammo < single_cost
	aoe_button.disabled = locked or ammo < aoe_cost
	eat_button.disabled = locked or not _can_eat()


func _set_busy(value: bool) -> void:
	busy = value
	if value:
		attack_options.hide()
	_update_buttons()


# ---------- player input ----------

func _on_move_pressed() -> void:
	attack_options.hide()
	_set_mode(Mode.MOVE)


func _on_attack_pressed() -> void:
	if busy or game_over:
		return
	mode = Mode.NONE                 # nothing armed until an attack type is picked
	attack_options.show()
	_set_status("Choose an attack")


func _on_eat_pressed() -> void:
	if busy or game_over or not _can_eat():
		return
	_resolve_turn(Mode.EAT, Vector2i.ZERO)


func _set_mode(new_mode: Mode) -> void:
	if busy or game_over:
		return
	mode = new_mode
	match mode:
		Mode.MOVE:
			_set_status("Click an adjacent cell on your side to move")
		Mode.SINGLE:
			_set_status("Single attack: click a cell on the enemy's side")
		Mode.AOE:
			_set_status("AOE attack: click the centre cell on the enemy's side")


func _on_cell_input(event: InputEvent, pos: Vector2i) -> void:
	if busy or game_over or mode == Mode.NONE:
		return
	if not (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT):
		return

	match mode:
		Mode.MOVE:
			if not _on_player_side(pos) or not _is_adjacent(player_pos, pos):
				return
		Mode.SINGLE, Mode.AOE:
			if not _on_enemy_side(pos):
				return
	_resolve_turn(mode, pos)


# ---------- enemy planning ----------

# The enemy decides using the positions BEFORE any movement happens.
func _plan_enemy() -> void:
	if randi() % 2 == 0:
		enemy_action = Mode.MOVE
		var options: Array[Vector2i] = []
		for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var p: Vector2i = enemy_pos + d
			if _in_bounds(p) and _on_enemy_side(p):
				options.append(p)
		enemy_dest = options.pick_random()
	else:
		enemy_action = Mode.SINGLE if randi() % 2 == 0 else Mode.AOE
		enemy_dest = player_pos       # player's current cell, before moves


# ---------- attacks ----------

# Cells covered by an attack. AOE cells that would land on the other
# side of the midline are dropped, so attacks never cross it.
func _cells_hit(is_aoe: bool, center: Vector2i, hits_player_side: bool) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not is_aoe:
		result.append(center)
		return result
	for off in GameManager.AOE_OFFSETS:
		var c: Vector2i = center + off
		if _in_bounds(c) and _on_player_side(c) == hits_player_side:
			result.append(c)
	return result


# Flashes every covered cell (red on the victim, white elsewhere) and
# returns the damage dealt to whoever is standing on a covered cell.
func _strike(by_player: bool, is_aoe: bool, center: Vector2i) -> int:
	var victim_pos := enemy_pos if by_player else player_pos
	var single_dmg := GameManager.get_single_attack_damage() if by_player else ENEMY_SINGLE_DAMAGE
	var center_dmg := GameManager.get_aoe_damage(true) if by_player else ENEMY_AOE_CENTER_DAMAGE
	var edge_dmg := GameManager.get_aoe_damage(false) if by_player else ENEMY_AOE_EDGE_DAMAGE

	var damage := 0
	for c in _cells_hit(is_aoe, center, not by_player):
		var cell_damage := single_dmg
		if is_aoe:
			cell_damage = center_dmg if c == center else edge_dmg
		var hit := c == victim_pos
		_flash(c, HIT_COLOR if hit else MISS_COLOR)
		if hit:
			damage = cell_damage
	return damage


# ---------- turn resolution ----------

func _resolve_turn(p_action: Mode, p_target: Vector2i) -> void:
	mode = Mode.NONE
	_set_busy(true)
	_plan_enemy()
	var msgs: Array[String] = []

	# Phase 0: eating
	if p_action == Mode.EAT:
		if GameManager.eat():
			msgs.append("You ate")
			_set_status(" | ".join(msgs))
			await get_tree().create_timer(ENEMY_DELAY).timeout

	# Phase 1: movement, enemy first, staggered if both move
	if enemy_action == Mode.MOVE:
		enemy_pos = enemy_dest
		msgs.append("Enemy moved")
		_refresh()
		_set_status(" | ".join(msgs))
		if p_action == Mode.MOVE:
			await get_tree().create_timer(MOVE_GAP).timeout

	if p_action == Mode.MOVE:
		player_pos = p_target
		GameManager.change_hunger(-GameManager.MOVE_HUNGER_COST)
		msgs.append("You moved")
		_refresh()
		_set_status(" | ".join(msgs))

	if p_action == Mode.MOVE or enemy_action == Mode.MOVE:
		await get_tree().create_timer(ENEMY_DELAY).timeout

	# Phase 2: attacks, enemy first, staggered if both attack
	var player_attacks := _is_attack(p_action)
	var enemy_attacks := _is_attack(enemy_action)

	if enemy_attacks:
		var enemy_dmg := _strike(false, enemy_action == Mode.AOE, enemy_dest)
		if enemy_dmg > 0:
			GameManager.damage_player(enemy_dmg)
			msgs.append("Enemy hit you for %d!" % enemy_dmg)
		else:
			msgs.append("Enemy missed")
		_set_status(" | ".join(msgs))
		if player_attacks and GameManager.current_health > 0:
			await get_tree().create_timer(ATTACK_GAP).timeout

	# A dead player doesn't get to strike back (and doesn't spend ammo).
	if player_attacks and GameManager.current_health > 0:
		var is_aoe := p_action == Mode.AOE
		GameManager.remove_item(GameManager.ItemType.AMMO, GameManager.get_attack_ammo_cost(is_aoe))
		var player_dmg := _strike(true, is_aoe, p_target)
		if player_dmg > 0:
			enemy_hp = maxi(enemy_hp - player_dmg, 0)
			_update_enemy_bar()
			msgs.append("You hit the enemy for %d!" % player_dmg)
		else:
			msgs.append("You missed")
		_set_status(" | ".join(msgs))

	if player_attacks or enemy_attacks:
		await get_tree().create_timer(ENEMY_DELAY).timeout

	# End of turn
	if GameManager.current_health <= 0:
		_finish("You lose...")
	elif enemy_hp <= 0:
		_finish("You win!")
	else:
		_set_busy(false)
		_set_status("Your turn: choose Move, Attack or Eat")


func _finish(message: String) -> void:
	game_over = true
	_set_busy(false)                 # game_over keeps every button disabled
	_set_status(message)
