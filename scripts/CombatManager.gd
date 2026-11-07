extends Node

signal combat_started
signal combat_ended(won: bool)
signal state_changed
signal log_message(msg: String)
signal cell_flashed(pos: Vector2i, color: Color)
signal grid_refreshed

const GRID_SIZE := 8
const HALF := GRID_SIZE/2

# Enemy base scaling stats (independent of player upgrades)
const ENEMY_BASE_HP := 100
const ENEMY_HP_PER_LEVEL := 20
const ENEMY_DAMAGE_PER_LEVEL := 0.15
const ENEMY_SINGLE_DAMAGE := 12
const ENEMY_AOE_CENTER_DAMAGE := 18
const ENEMY_AOE_EDGE_DAMAGE := 7

enum Mode { NONE, MOVE, SINGLE, AOE, EAT }

var in_combat := false
var is_busy := false
var mode := Mode.NONE

var player_pos := Vector2i(HALF, GRID_SIZE - 2)
var enemy_pos := Vector2i(HALF - 1, 1)
var enemy_level := 1
var enemy_max_hp := ENEMY_BASE_HP
var enemy_hp := ENEMY_BASE_HP

var enemy_action := Mode.NONE
var enemy_dest := Vector2i.ZERO

func start_combat() -> void:
	in_combat = true
	is_busy = false
	mode = Mode.NONE
	
	# Pull encounter scaling directly from GameManager zone settings
	enemy_level = GameManager.enemy_level
	enemy_max_hp = ENEMY_BASE_HP + ENEMY_HP_PER_LEVEL * (enemy_level - 1)
	enemy_hp = enemy_max_hp
	
	player_pos = Vector2i(HALF, GRID_SIZE - 2)
	enemy_pos = Vector2i(HALF - 1, 1)
	
	emit_signal("combat_started")
	emit_signal("log_message", "Combat started! Choose your action.")
	emit_signal("grid_refreshed")

func end_combat(won: bool) -> void:
	in_combat = false
	is_busy = false
	emit_signal("combat_ended", won)

func set_player_mode(new_mode: Mode) -> void:
	if not in_combat or is_busy:
		return
	mode = new_mode
	emit_signal("state_changed")
	
	match mode:
		Mode.MOVE:
			emit_signal("log_message", "Click an adjacent cell on your side to move.")
		Mode.SINGLE:
			emit_signal("log_message", "Single attack: click a cell on the enemy's side.")
		Mode.AOE:
			emit_signal("log_message", "AOE attack: click the center cell on the enemy's side.")

func is_adjacent(a: Vector2i, b: Vector2i) -> bool:
	return absi(a.x - b.x) + absi(a.y - b.y) == 1

func try_eat() -> void:
	if not in_combat or is_busy:
		return
	# Delegate eating logic entirely to GameManager
	if GameManager.eat():
		_resolve_turn(Mode.EAT, Vector2i.ZERO)

func on_cell_clicked(pos: Vector2i) -> void:
	if not in_combat or is_busy or mode == Mode.NONE:
		return

	if mode == Mode.MOVE:
		if pos.y < HALF or not is_adjacent(player_pos, pos):
			return
	elif mode == Mode.SINGLE or mode == Mode.AOE:
		if pos.y >= HALF:
			return

	_resolve_turn(mode, pos)

func _plan_enemy() -> void:
	if randi() % 2 == 0:
		enemy_action = Mode.MOVE
		var options: Array[Vector2i] = []
		for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var p = enemy_pos + d
			if p.x >= 0 and p.x < GRID_SIZE and p.y >= 0 and p.y < HALF:
				options.append(p)
		if options.size() > 0:
			enemy_dest = options.pick_random()
		else:
			enemy_dest = enemy_pos
	else:
		enemy_action = Mode.SINGLE if randi() % 2 == 0 else Mode.AOE
		enemy_dest = player_pos

func _level_enemy_damage(base: int) -> int:
	return roundi(base * (1.0 + ENEMY_DAMAGE_PER_LEVEL * (enemy_level - 1)))

func _resolve_turn(p_action: Mode, p_target: Vector2i) -> void:
	mode = Mode.NONE
	is_busy = true
	emit_signal("state_changed")
	_plan_enemy()
	
	var msgs: Array[String] = []

	# Phase 0: Eating handled via GameManager.eat() already triggered
	if p_action == Mode.EAT:
		msgs.append("You ate")
		emit_signal("log_message", " | ".join(msgs))
		await get_tree().create_timer(0.7).timeout

	# Phase 1: Movement
	if enemy_action == Mode.MOVE:
		enemy_pos = enemy_dest
		msgs.append("Enemy moved")
		emit_signal("grid_refreshed")
		emit_signal("log_message", " | ".join(msgs))
		if p_action == Mode.MOVE:
			await get_tree().create_timer(0.4).timeout

	if p_action == Mode.MOVE:
		player_pos = p_target
		# Get movement hunger cost dynamically from GameManager
		GameManager.change_hunger(-GameManager.MOVE_HUNGER_COST)
		msgs.append("You moved")
		emit_signal("grid_refreshed")
		emit_signal("log_message", " | ".join(msgs))

	if p_action == Mode.MOVE or enemy_action == Mode.MOVE:
		await get_tree().create_timer(0.7).timeout

	# Phase 2: Attacks
	var player_attacks := (p_action == Mode.SINGLE or p_action == Mode.AOE)
	var enemy_attacks := (enemy_action == Mode.SINGLE or enemy_action == Mode.AOE)

	if enemy_attacks:
		var dmg := _strike_enemy(enemy_action == Mode.AOE, enemy_dest)
		if dmg > 0:
			# Damage player via GameManager API
			GameManager.damage_player(dmg)
			msgs.append("Enemy hit you for %d!" % dmg)
		else:
			msgs.append("Enemy missed")
		emit_signal("log_message", " | ".join(msgs))
		if player_attacks and GameManager.current_health > 0:
			await get_tree().create_timer(0.5).timeout

	if player_attacks and GameManager.current_health > 0:
		var is_aoe := (p_action == Mode.AOE)
		# Deduct ammo using GameManager item rules
		GameManager.remove_item(GameManager.ItemType.AMMO, GameManager.get_attack_ammo_cost(is_aoe))
		var dmg := _strike_player(is_aoe, p_target)
		if dmg > 0:
			enemy_hp = maxi(enemy_hp - dmg, 0)
			msgs.append("You hit enemy for %d!" % dmg)
		else:
			msgs.append("You missed")
		emit_signal("log_message", " | ".join(msgs))

	if player_attacks or enemy_attacks:
		await get_tree().create_timer(0.7).timeout

	# Win / Loss Checks (Reading player health directly from GameManager)
	if GameManager.current_health <= 0:
		emit_signal("log_message", "You lose...")
		end_combat(false)
	elif enemy_hp <= 0:
		emit_signal("log_message", "You win!")
		end_combat(true)
	else:
		is_busy = false
		emit_signal("state_changed")
		emit_signal("log_message", "Your turn: choose Move, Attack or Eat")

func _strike_enemy(is_aoe: bool, center: Vector2i) -> int:
	var hit_dmg := 0
	var targets := [center]
	if is_aoe:
		targets.clear()
		for off in GameManager.AOE_OFFSETS: # Pulls pattern offsets from GameManager
			var c = center + off
			if c.x >= 0 and c.x < GRID_SIZE and c.y >= HALF and c.y < GRID_SIZE:
				targets.append(c)
	for c in targets:
		var is_hit: bool = (c == player_pos)
		emit_signal("cell_flashed", c, Color(1, 0.1, 0.1) if is_hit else Color(1, 1, 1))
		if is_hit:
			hit_dmg = _level_enemy_damage(ENEMY_AOE_CENTER_DAMAGE) if is_aoe and c == center else (_level_enemy_damage(ENEMY_AOE_EDGE_DAMAGE) if is_aoe else _level_enemy_damage(ENEMY_SINGLE_DAMAGE))
	return hit_dmg

func _strike_player(is_aoe: bool, center: Vector2i) -> int:
	var hit_dmg := 0
	var targets := [center]
	if is_aoe:
		targets.clear()
		for off in GameManager.AOE_OFFSETS: # Pulls pattern offsets from GameManager
			var c = center + off
			if c.x >= 0 and c.x < GRID_SIZE and c.y >= 0 and c.y < HALF:
				targets.append(c)
	for c in targets:
		var is_hit: bool = (c == enemy_pos)
		emit_signal("cell_flashed", c, Color(1, 0.1, 0.1) if is_hit else Color(1, 1, 1))
		if is_hit:
			# Pulls upgraded weapon damages directly from GameManager functions!
			hit_dmg = GameManager.get_aoe_damage(true) if is_aoe and c == center else (GameManager.get_aoe_damage(false) if is_aoe else GameManager.get_single_attack_damage())
	return hit_dmg
