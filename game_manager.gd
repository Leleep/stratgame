extends Node
## GameManager: central store for inventory, weapon stats, hunger and player health.
## Every upgradable stat lives in the UPGRADES table, so adding a new
## property means adding one entry there (and optionally a getter).

# ---------------------------------------------------------------- Signals
signal property_upgraded(property_name: String, new_level: int)
signal inventory_changed
signal health_changed(current: int, maximum: int)
signal hunger_changed(current: int, maximum: int)

# ---------------------------------------------------------------- Items
enum ItemType { AMMO, FOOD, COIN }

## Weight of ONE unit of each item. Every ItemType needs an entry here.
const ITEM_WEIGHTS := {
	ItemType.AMMO: 0.5,
	ItemType.FOOD: 2.0,
	ItemType.COIN: 0.1,
}
const WEIGHT_EPSILON := 0.0001  # guards float rounding, e.g. 0.1 * 5

# ---------------------------------------------------------------- Upgrade table
# One entry per upgradable property.
#   "level":  current level (1-based)
#   "values": value at each level; index 0 = level 1. Array length = max level.
# To add a property, just add an entry here.
var upgrades: Dictionary = {
	"carry_capacity":  {"level": 1, "values": [50, 70, 95, 125, 160]},  # max total weight
	"player_health":   {"level": 1, "values": [100, 130, 170, 220, 280]},

	# Single-pixel precise attack
	"single_attack":   {"level": 1, "values": [10, 14, 19, 25, 32]},
	# AOE attack: centre block hits harder than the 4 edge blocks
	"aoe_center":      {"level": 1, "values": [15, 21, 28, 36, 45]},
	"aoe_edge":        {"level": 1, "values": [6, 9, 12, 16, 20]},
}

# Properties that should level together. Upgrading the key also bumps the
# listed properties, so the AOE centre/edge damage stay in sync.
var linked_properties: Dictionary = {
	"aoe_center": ["aoe_edge"],
}

# Relative cells hit by the AOE (centre + 4 neighbours). Offsets are (x, y).
const AOE_OFFSETS: Array[Vector2i] = [
	Vector2i(0, 0),   # centre
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1),
]

# ---------------------------------------------------------------- Hunger & ammo costs
const MAX_HUNGER := 100
const MOVE_HUNGER_COST := 5
const FOOD_HUNGER_RESTORE := 30
const SINGLE_AMMO_COST := 1
const AOE_AMMO_COST := 3

# ---------------------------------------------------------------- Runtime state
var current_health: int
var hunger: int = MAX_HUNGER
# How many of each item the player carries: {ItemType: int}
var items: Dictionary = {}


func _ready() -> void:
	for type in ITEM_WEIGHTS:
		items[type] = 0
	current_health = get_value("player_health")

# ---------------------------------------------------------------- Zones & encounters
const DEFAULT_ENEMY_LEVEL := 1

## Enemy level for each map zone. Edit a number here to change a zone's difficulty.
var zone_levels: Dictionary = {
	"zone1": 1,
	"zone2": 2,
	"zone3": 3,
}

var enemy_level: int = DEFAULT_ENEMY_LEVEL   # level of the encounter being fought


## Call this right before loading the combat scene.
func start_encounter(zone: String) -> void:
	enemy_level = int(zone_levels.get(zone, DEFAULT_ENEMY_LEVEL))

# ================================================================ Generic upgrade API

## Current level of a property (1-based). Returns 0 if the property doesn't exist.
func get_level(property_name: String) -> int:
	if not upgrades.has(property_name):
		push_warning("Unknown property: %s" % property_name)
		return 0
	return upgrades[property_name]["level"]


## Max level = number of entries in the property's values array.
func get_max_level(property_name: String) -> int:
	return upgrades[property_name]["values"].size()


func is_maxed(property_name: String) -> bool:
	return get_level(property_name) >= get_max_level(property_name)


## Value of a property at its current level (e.g. capacity, damage, max HP).
func get_value(property_name: String) -> int:
	var data: Dictionary = upgrades[property_name]
	return data["values"][data["level"] - 1]


## Upgrades a property by one level. Returns true if it was upgraded,
## false if the property is unknown or already maxed.
func upgrade_property(property_name: String) -> bool:
	if not upgrades.has(property_name):
		push_warning("Unknown property: %s" % property_name)
		return false
	if is_maxed(property_name):
		return false

	var old_value := get_value(property_name)
	upgrades[property_name]["level"] += 1
	_apply_upgrade_side_effects(property_name, old_value)
	property_upgraded.emit(property_name, get_level(property_name))

	# Level any linked properties together (e.g. AOE centre + edge).
	for linked: String in linked_properties.get(property_name, []):
		upgrade_property(linked)
	return true


## Property-specific reactions to an upgrade. Add a `match` branch here
## only if a new property needs more than just a changed value.
func _apply_upgrade_side_effects(property_name: String, old_value: int) -> void:
	match property_name:
		"carry_capacity":
			inventory_changed.emit()  # lets the weight bar pick up the new maximum
		"player_health":
			# Heal by the amount max HP increased, so the upgrade feels rewarding.
			current_health += get_value(property_name) - old_value
			health_changed.emit(current_health, get_value(property_name))


# ================================================================ Weapons

func get_single_attack_damage() -> int:
	return get_value("single_attack")


## Damage for one AOE cell. Pass true for the centre block, false for edges.
func get_aoe_damage(is_center: bool) -> int:
	return get_value("aoe_center") if is_center else get_value("aoe_edge")


func get_attack_ammo_cost(is_aoe: bool) -> int:
	return AOE_AMMO_COST if is_aoe else SINGLE_AMMO_COST


# ================================================================ Health

func get_max_health() -> int:
	return get_value("player_health")


func damage_player(amount: int) -> void:
	current_health = max(current_health - amount, 0)
	health_changed.emit(current_health, get_max_health())


func heal_player(amount: int) -> void:
	current_health = min(current_health + amount, get_max_health())
	health_changed.emit(current_health, get_max_health())


# ================================================================ Hunger

func change_hunger(amount: int) -> void:
	hunger = clampi(hunger + amount, 0, MAX_HUNGER)
	hunger_changed.emit(hunger, MAX_HUNGER)


## Eats one food to restore hunger. Returns false (and uses nothing) if
## hunger is already full or there is no food.
func eat() -> bool:
	if hunger >= MAX_HUNGER or not remove_item(ItemType.FOOD, 1):
		return false
	change_hunger(FOOD_HUNGER_RESTORE)
	return true


# ================================================================ Inventory (weight based)

## Weight of a single unit of an item.
func get_item_weight(type: ItemType) -> float:
	return float(ITEM_WEIGHTS.get(type, 0.0))


## Total amount of an item being carried.
func get_item_count(type: ItemType) -> int:
	return int(items.get(type, 0))


## Combined weight of everything carried (count x unit weight, summed).
func get_total_weight() -> float:
	var total := 0.0
	for type: ItemType in items:
		total += get_item_count(type) * get_item_weight(type)
	return total


## Maximum weight the player can carry at the current carry_capacity level.
func get_max_weight() -> float:
	return float(get_value("carry_capacity"))


func get_free_weight() -> float:
	return maxf(get_max_weight() - get_total_weight(), 0.0)


## True if `amount` of the item would fit entirely.
func can_carry(type: ItemType, amount: int) -> bool:
	return get_item_weight(type) * amount <= get_free_weight() + WEIGHT_EPSILON


## Adds as many units as fit under the weight limit. Returns the leftover
## amount that didn't fit (0 = everything stored).
func add_item(type: ItemType, amount: int) -> int:
	if amount <= 0:
		return 0
	var fits := amount
	var unit_weight := get_item_weight(type)
	if unit_weight > 0.0:
		fits = mini(amount, floori(get_free_weight() / unit_weight + WEIGHT_EPSILON))
	if fits > 0:
		items[type] = get_item_count(type) + fits
		inventory_changed.emit()
	return amount - fits


## All-or-nothing: returns false (and removes nothing) if the player
## doesn't have enough.
func remove_item(type: ItemType, amount: int) -> bool:
	if amount < 0 or get_item_count(type) < amount:
		return false
	items[type] = get_item_count(type) - amount
	inventory_changed.emit()
	return true
