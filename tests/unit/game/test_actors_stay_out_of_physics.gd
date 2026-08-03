extends GutTest

# Guards the analytic-physics invariant: no actor may leave anything in the
# physics simulation.
#
# This is a test rather than a comment because the cost is a CLIFF, not a slope.
# One active body or one monitoring Area3D switches on Jolt's per-step pipeline
# for a fixed ~0.4 ms of the 8.3 ms tick (measured headless, 120 Hz, 4 cores)
# whether or not it ever touches anything: a single Area3D on its own measured
# 623 us/tick against a 230 us floor, and twenty kinematic bodies cost barely
# more than one. So re-adding one Area3D for a new mechanic gives back the whole
# win of having removed the other thirty, and it does so invisibly — the game
# plays identically, the host just loses 5% of its tick budget.
#
# Anything that reappears is also, by construction, unused: no ray, shape, or
# overlap query exists anywhere in the project, so a body the engine tracks is a
# body nothing can ever ask about.
#
# Static geometry is exempt and expected — the rink, net, and goalie parts cost
# ~2 us/tick each and their shapes and transforms ARE the geometry the analytic
# solvers read (GoalieContactDetector walks the goalie's CollisionShape3Ds).

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const PUCK_SCENE: PackedScene = preload("res://Scenes/Puck.tscn")
const GOALIE_SCENE: PackedScene = preload("res://Scenes/Goalie.tscn")


func _spawn(scene: PackedScene) -> Node:
	var actor: Node = scene.instantiate()
	add_child_autofree(actor)
	return actor


# The actor and every descendant, so a body buried in a rig is caught too.
func _subtree(root: Node) -> Array[Node]:
	var found: Array[Node] = [root]
	var i: int = 0
	while i < found.size():
		for child: Node in found[i].get_children():
			found.append(child)
		i += 1
	return found


func _collision_objects(root: Node) -> Array[CollisionObject3D]:
	var objects: Array[CollisionObject3D] = []
	for node: Node in _subtree(root):
		if node is CollisionObject3D:
			objects.append(node as CollisionObject3D)
	return objects


func _paths(objects: Array[CollisionObject3D], root: Node) -> String:
	var names: PackedStringArray = PackedStringArray()
	for obj: CollisionObject3D in objects:
		names.append("%s (%s)" % [root.get_path_to(obj), obj.get_class()])
	return ", ".join(names)


func test_skater_puts_nothing_in_the_simulation() -> void:
	var skater: Node = _spawn(SKATER_SCENE)
	var objects: Array[CollisionObject3D] = _collision_objects(skater)
	assert_eq(objects.size(), 0,
			"Skater must carry no collision objects at all — every skater contact " \
			+ "(vs. skater, boards, net, goalie, puck) is analytic. Found: " \
			+ _paths(objects, skater))


func test_puck_puts_nothing_in_the_simulation() -> void:
	var puck: Node = _spawn(PUCK_SCENE)
	var objects: Array[CollisionObject3D] = _collision_objects(puck)
	assert_eq(objects.size(), 0,
			"Puck must carry no collision objects at all — it is custom-integrated " \
			+ "and every carom is analytic. Found: " + _paths(objects, puck))


# The goalie is the one actor that legitimately keeps collision objects: its
# parts are the save geometry. They must stay STATIC — a static body never joins
# the solver, which is why 14 of them moving every tick measured ~26 us against a
# plain-Node3D rig, versus the ~400 us a single non-static body costs.
func test_goalie_parts_are_static_only() -> void:
	var goalie: Node = _spawn(GOALIE_SCENE)
	var offenders: Array[CollisionObject3D] = []
	for obj: CollisionObject3D in _collision_objects(goalie):
		if not (obj is StaticBody3D):
			offenders.append(obj)
	assert_eq(offenders.size(), 0,
			"Goalie parts must be StaticBody3D — an Area3D or a non-static body " \
			+ "here switches the whole solver back on. Found: " \
			+ _paths(offenders, goalie))


# A mask is what pairs one body with another. Every remaining body is static, so
# these masks are already inert — zeroing them is the belt-and-braces half: it
# means a body added on any layer tomorrow still cannot pair against the geometry
# that outlived the migration.
func test_no_actor_masks_anything() -> void:
	for scene: PackedScene in [SKATER_SCENE, PUCK_SCENE, GOALIE_SCENE]:
		var actor: Node = _spawn(scene)
		for obj: CollisionObject3D in _collision_objects(actor):
			assert_eq(obj.collision_mask, 0,
					"%s masks layer(s) %d — nothing in this project queries or " \
					% [actor.get_path_to(obj), obj.collision_mask] \
					+ "collides, so every mask must be 0")


# Guards the guard: the checks above pass by finding NOTHING, which is also what
# a broken subtree walk returns. Plant a body at depth and confirm it is seen, so
# a traversal bug cannot quietly green the whole file.
func test_the_walk_actually_finds_a_planted_body() -> void:
	var skater: Node = _spawn(SKATER_SCENE)
	assert_eq(_collision_objects(skater).size(), 0, "clean before planting")
	var planted := Area3D.new()
	var deepest: Node = skater
	for node: Node in _subtree(skater):
		if node.get_path().get_name_count() > deepest.get_path().get_name_count():
			deepest = node
	deepest.add_child(planted)
	var found: Array[CollisionObject3D] = _collision_objects(skater)
	assert_eq(found.size(), 1, "a body planted at the deepest point must be found")
	assert_eq(found[0], planted)


# The skater's contact disc replaced a CylinderShape3D that no longer exists.
# Nothing else can supply the number, so the analytic paths and the export must
# not drift apart: collision_radius() IS the export, and the clamps call it.
func test_skater_contact_disc_is_the_exported_radius() -> void:
	var skater: Skater = _spawn(SKATER_SCENE) as Skater
	assert_eq(skater.collision_radius(), skater.body_collision_radius,
			"collision_radius() must report the export the clamps inset by")
	skater.body_collision_radius = 0.5
	assert_eq(skater.collision_radius(), 0.5,
			"a per-build radius (SkaterController.apply_attributes) must reach the " \
			+ "analytic paths, not a cached copy")
