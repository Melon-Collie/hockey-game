extends GutTest

# The ceiling rig's fixture housings hang at 22 m, and the play-following
# cameras climb past that (GameCamera tops out at 32 m, higher on the intro
# crane and the camera-distance pref) — so from a wide zoom the housings sit
# between the camera and the play, dark side toward the lens. They must render
# only on the layer GameCamera and PovCamera mask out.


# A stand-in for RinkArena.tscn's rig: the three groups ArenaHouseLights
# matches by name, with only the overhead one expected to carry housings.
func _make_arena() -> Node3D:
	var root := Node3D.new()
	add_child_autofree(root)
	for i: int in 8:
		var spot := SpotLight3D.new()
		spot.name = "SpotLight3D" if i == 0 else "SpotLight3D%d" % (i + 1)
		spot.position = Vector3(-6.0 if i < 4 else 6.0, 22.0, -22.0 + 15.0 * (i % 4))
		root.add_child(spot)
	var dasher := SpotLight3D.new()
	dasher.name = "DasherSpotLight"
	root.add_child(dasher)
	var bowl := OmniLight3D.new()
	bowl.name = "BowlLight_NE"
	root.add_child(bowl)
	return root


func _make_lights(root: Node3D) -> ArenaHouseLights:
	var lights := ArenaHouseLights.new()
	root.add_child(lights)
	lights.setup(root)
	return lights


func test_housings_render_only_on_the_masked_layer() -> void:
	var lights: ArenaHouseLights = _make_lights(_make_arena())
	var visual_count: int = 0
	var stack: Array[Node] = [lights]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is VisualInstance3D:
			visual_count += 1
			assert_eq((node as VisualInstance3D).layers, ArenaHouseLights.FIXTURE_LAYER,
					"%s must render only on the overhead set-dressing layer" % node.name)
	# Body + lens for each of the eight overhead fixtures; the dasher and bowl
	# lights are behind the stands and get no housing at all.
	assert_eq(visual_count, 16, "unexpected housing part count")


func test_fixture_layer_is_the_one_the_play_cameras_mask_out() -> void:
	var cam: GameCamera = GameCamera.new()
	add_child_autofree(cam)
	assert_eq(cam.cull_mask & ArenaHouseLights.FIXTURE_LAYER, 0,
			"gameplay camera must never render the ceiling fixtures")
	var pov: PovCamera = PovCamera.new()
	add_child_autofree(pov)
	assert_eq(pov.cull_mask & ArenaHouseLights.FIXTURE_LAYER, 0,
			"POV camera reproduces the same top-down framing and must mask them too")
