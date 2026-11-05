extends Node
## GameManager: central store for inventory, weapon stats and player health.
## Every upgradable stat lives in the UPGRADES table, so adding a new
## property means adding one entry there (and optionally a getter).

# ---------------------------------------------------------------- Signals
signal property_upgraded(property_name: String, new_level: int)
signal inventory_changed
signal health_changed(current: int, maximum: int)

# ---------------------------------------------------------------- Items
enum ItemType { AMMO, FOOD, COIN }

const EMPTY_SLOT := -1
const STACK_SIZE := 20  # same for every item for now; swap for a per-item dict later

# ---------------------------------------------------------------- Upgrade table
# One entry per upgradable property.
#   "level":  current level (1-based)
#   "values": value at each level; index 0 = level 1. Array length = max level.
# To add a property, just add an entry here.
var upgrades: Dictionary = {
	"inventory_slots": {"level": 1, "values": [4, 6, 8, 10, 12]},
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

# ---------------------------------------------------------------- Runtime state
var current_health: int
# Each slot: {"type": ItemType or EMPTY_SLOT, "count": int}
var inventory: Array[Dictionary] = []


func _ready() -> void:
	_resize_inventory(get_value("inventory_slots"))
	current_health = get_value("player_health")


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


## Value of a property at its current level (e.g. slot count, damage, max HP).
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
		"inventory_slots":
			_resize_inventory(get_value(property_name))
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


# ================================================================ Health

func get_max_health() -> int:
	return get_value("player_health")


func damage_player(amount: int) -> void:
	current_health = max(current_health - amount, 0)
	health_changed.emit(current_health, get_max_health())


func heal_player(amount: int) -> void:
	current_health = min(current_health + amount, get_max_health())
	health_changed.emit(current_health, get_max_health())


# ================================================================ Inventory

## Grows the inventory to `new_size` slots (never shrinks, upgrades only go up).
func _resize_inventory(new_size: int) -> void:
	while inventory.size() < new_size:
		inventory.append({"type": EMPTY_SLOT, "count": 0})
	inventory_changed.emit()


## Adds items: tops up existing stacks of the same type first, then uses empty
## slots. Returns the leftover amount that didn't fit (0 = everything stored).
func add_item(type: ItemType, amount: int) -> int:
	# Pass 1: fill partially filled stacks of this type.
	for slot in inventory:
		if amount <= 0:
			break
		if slot["type"] == type and slot["count"] < STACK_SIZE:
			var moved: int = min(amount, STACK_SIZE - slot["count"])
			slot["count"] += moved
			amount -= moved
	# Pass 2: open new stacks in empty slots.
	for slot in inventory:
		if amount <= 0:
			break
		if slot["type"] == EMPTY_SLOT:
			var moved: int = min(amount, STACK_SIZE)
			slot["type"] = type
			slot["count"] = moved
			amount -= moved
	inventory_changed.emit()
	return amount


## Removes items across stacks. All-or-nothing: returns false (and removes
## nothing) if the player doesn't have enough.
func remove_item(type: ItemType, amount: int) -> bool:
	if get_item_count(type) < amount:
		return false
	for slot in inventory:
		if amount <= 0:
			break
		if slot["type"] == type:
			var taken: int = min(amount, slot["count"])
			slot["count"] -= taken
			amount -= taken
			if slot["count"] == 0:
				slot["type"] = EMPTY_SLOT  # free the slot
	inventory_changed.emit()
	return true


## Total amount of an item across all stacks.
func get_item_count(type: ItemType) -> int:
	var total := 0
	for slot in inventory:
		if slot["type"] == type:
			total += slot["count"]
	return total
