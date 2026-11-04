extends Control

const HALF := 12
const GRID_SIZE := HALF * 2          # always even
const MAX_CELL := 48          # cell size when the grid is small
const MAX_GRID_PX := 560      # grid never exceeds this many pixels per side
const SEP := 2
const MID_THICKNESS := 4
const MAX_HP := 100
const DAMAGE := 20
const FLASH_TIME := 0.35
const ENEMY_DELAY := 0.7
const ATTACK_GAP := 1
const MOVE_GAP := 0.6

const PLAYER_COLOR := Color(0.25, 0.55, 1.0)
const ENEMY_COLOR := Color(1.0, 0.65, 0.15)
const ENEMY_SIDE_COLOR := Color(0.16, 0.12, 0.12)
const PLAYER_SIDE_COLOR := Color(0.12, 0.12, 0.17)
const HIT_COLOR := Color(1.0, 0.1, 0.1)
const MISS_COLOR := Color(1.0, 1.0, 1.0)
const MID_COLOR := Color(0.9, 0.9, 0.9)

enum Mode { NONE, MOVE, ATTACK }

@onready var grid: GridContainer = $VBoxContainer/GridHolder/Grid
@onready var grid_holder: Control = $VBoxContainer/GridHolder
@onready var mid_line: ColorRect = $VBoxContainer/GridHolder/MidLine
@onready var player_bar: ProgressBar = $HUD/HealthBars/PlayerBox/PlayerBar
@onready var enemy_bar: ProgressBar = $HUD/HealthBars/EnemyBox/EnemyBar
@onready var move_button: Button = $VBoxContainer/Buttons/MoveButton
@onready var attack_button: Button = $VBoxContainer/Buttons/AttackButton
@onready var status_label: Label = $VBoxContainer/StatusLabel

var cells: Array[ColorRect] = []
var player_pos := Vector2i(HALF, GRID_SIZE - 2)
var enemy_pos := Vector2i(HALF - 1, 1)
var player_hp := MAX_HP
var enemy_hp := MAX_HP
var mode := Mode.NONE
var busy := false
var game_over := false
var enemy_action := Mode.NONE
var enemy_dest := Vector2i.ZERO   # move destination, or attack target
var cell_size := MAX_CELL

func _ready() -> void:
	randomize()
	_build_grid()
	_build_midline()

	for bar in [player_bar, enemy_bar]:
		bar.max_value = MAX_HP
		bar.show_percentage = false
	player_bar.modulate = PLAYER_COLOR
	enemy_bar.modulate = ENEMY_COLOR

	move_button.pressed.connect(_set_mode.bind(Mode.MOVE))
	attack_button.pressed.connect(_set_mode.bind(Mode.ATTACK))

	_update_bars()
	_refresh()
	_set_status("Your turn: choose Move or Attack")


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


func _update_bars() -> void:
	player_bar.value = player_hp
	enemy_bar.value = enemy_hp


func _set_status(text: String) -> void:
	status_label.text = text


func _set_busy(value: bool) -> void:
	busy = value
	move_button.disabled = value or game_over
	attack_button.disabled = value or game_over


func _set_mode(new_mode: Mode) -> void:
	if busy or game_over:
		return
	mode = new_mode
	match mode:
		Mode.MOVE:
			_set_status("Click an adjacent cell on your side to move")
		Mode.ATTACK:
			_set_status("Click a cell on the enemy's side to attack")

func _compute_cell_size() -> void:
	var available := MAX_GRID_PX - (GRID_SIZE - 1) * SEP
	cell_size = clampi(int(available / float(GRID_SIZE)), 4, MAX_CELL)


func _grid_pixels() -> int:
	return GRID_SIZE * cell_size + (GRID_SIZE - 1) * SEP

# ---------- player turn ----------

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
		Mode.ATTACK:
			if not _on_enemy_side(pos):
				return
	_resolve_turn(mode, pos)


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
		enemy_action = Mode.ATTACK
		enemy_dest = player_pos   # player's current cell, before moves


func _resolve_turn(p_action: Mode, p_target: Vector2i) -> void:
	mode = Mode.NONE
	_set_busy(true)
	_plan_enemy()
	var msgs: Array[String] = []

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
		msgs.append("You moved")
		_refresh()
		_set_status(" | ".join(msgs))

	if p_action == Mode.MOVE or enemy_action == Mode.MOVE:
		await get_tree().create_timer(ENEMY_DELAY).timeout
	# Phase 2: attacks, enemy first, staggered if both attack
	var player_hit := false
	var enemy_hit := false

	if enemy_action == Mode.ATTACK:
		player_hit = enemy_dest == player_pos
		_flash(enemy_dest, HIT_COLOR if player_hit else MISS_COLOR)
		msgs.append("Enemy hit you!" if player_hit else "Enemy missed")
		if player_hit:
			player_hp = maxi(player_hp - DAMAGE, 0)
			_update_bars()
		_set_status(" | ".join(msgs))
		if p_action == Mode.ATTACK:
			await get_tree().create_timer(ATTACK_GAP).timeout

	if p_action == Mode.ATTACK:
		enemy_hit = p_target == enemy_pos
		_flash(p_target, HIT_COLOR if enemy_hit else MISS_COLOR)
		msgs.append("You hit the enemy!" if enemy_hit else "You missed")
		if enemy_hit:
			enemy_hp = maxi(enemy_hp - DAMAGE, 0)
			_update_bars()
		_set_status(" | ".join(msgs))

	if p_action == Mode.ATTACK or enemy_action == Mode.ATTACK:
		await get_tree().create_timer(ENEMY_DELAY).timeout

	# Resolve end of turn
	if player_hp <= 0 and enemy_hp <= 0:
		_finish("Draw!")
	elif enemy_hp <= 0:
		_finish("You win!")
	elif player_hp <= 0:
		_finish("You lose...")
	else:
		_set_busy(false)
		_set_status("Your turn: choose Move or Attack")

func _finish(message: String) -> void:
	game_over = true
	_set_busy(false)
	_set_status(message)
