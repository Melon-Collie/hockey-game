class_name LockerMannequin
extends Node3D

# The locker's display figure: a full kit-dressed skater assembled from the
# rink's own shared part meshes, standing on the case floor with the picked
# stick in both hands. Every piece the locker edits is worn HERE — skates on
# the feet, gloves gripping the shaft, face gear in the helmet — so a pick is
# judged in the place it will actually be seen.
#
# Built from the individual part meshes rather than the skinned rig. That costs
# nothing in fidelity: `shared_torso()` and the skinned mesh's torso surface are
# the same cached `_shared("torso", ...)` geometry, so the silhouette is
# identical while the pose stays plain node transforms — no Skeleton3D, no bone
# poses, no gait. The lobby's bench dummies are assembled the same way.
#
# Frame: the rest positions below are Scenes/Skater.tscn's, in MeshRoot-local
# coordinates, so the figure is laid out in the rig's own numbers and faces −Z
# like the rig does. `_rig` is then seated so the blade contact lands on THIS
# node's origin — y = 0 is the ice, whatever the build's height.
#
# Body dials scale the rig about that ice plane, mirroring
# SkaterAppearanceCoordinator's rule: every Y offset rides the height
# multiplier, each part's lateral scale rides its own bulk multiplier, and the
# helmet scales uniformly by its own mild table rather than stretching with
# height.
#
# The stick hangs at rest — no flex pulse. The workbench's spinning stick could
# bow because nothing held it; here both fists are pinned to the shaft, and a
# bow that leaves the hands behind reads as broken rather than as flex. The
# FLEX row carries the fitted stiffness number instead.

# The camera framings the locker dollies between — one per group of rows, plus
# the wide shot nothing is focused.
enum Focus { FULL, STICK, SKATES, GLOVES, HELMET }

# ── Rig rest pose (Scenes/Skater.tscn, MeshRoot-local) ───────────────────────
# Leg offsets are relative to the LEG pivot so the chain reads as the scene's
# parenting does (Leg → Shin → Sock/Skate/Foot) without the intermediate nodes.
const _TORSO_Y: float = 0.195
const _HELMET_Y: float = 0.65
const _SHOULDER_X: float = 0.22
const _SHOULDER_Y: float = 0.40
const _LEG_X: float = 0.13
const _LEG_Y: float = -0.13
const _SOCK_DY: float = -0.50
const _COLLAR_DY: float = -0.72
const _BOOT_DY: float = -0.76
const _BOOT_DZ: float = -0.10
const _THIGH_DY: float = -0.13
# Boot frame, straight off FootL/R's scene basis: local −Y is the toe and local
# +Z is down, so this lands the toe on −Z (the way the rig faces) sole-down.
const _BOOT_ROT := Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0))
# The runner bottoms out this far below the boot origin — the pre-lift contact
# (boot-local z 0.080) plus the stance lift.
const _BLADE_ICE_M: float = 0.080 + SkaterMeshBuilder.SKATE_LIFT_M
# The ice plane in rig-local coordinates. Everything scales about it.
const _ICE_Y: float = _LEG_Y + _BOOT_DY - _BLADE_ICE_M

# Part radii for the unit-scale meshes, mirroring the live rig's exports.
const _ARM_RADIUS: float = 0.065
const _ELBOW_RADIUS: float = 0.082
const _HAND_RADIUS: float = 0.064
const _CUFF_RADIUS: float = 0.065
# How far up the forearm the cuff ring sits from the fist's center.
const _CUFF_OFFSET_M: float = 0.075
# Arm segments at the rig's own lengths (Skater.upper_arm_length /
# forearm_length), NOT derived from how far the grip happens to be: the two
# hands sit at very different distances from their shoulders, so a
# reach-proportional segment builds one long arm and one short one.
const _UPPER_ARM_M: float = 0.33
const _FOREARM_M: float = 0.33
# Grips are solved onto the shaft within this fraction of the arm's full span,
# so the elbow always has a bend left in it and the fists never float off the
# hand they belong to.
const _GRIP_REACH_FRAC: float = 0.88
# Elbow pole hint, the rig's own (Skater.arm_pole_local) — mirrored per side so
# each elbow swings out and back rather than folding into the ribs.
const _ARM_POLE := Vector3(0.55, -1.0, 0.1)

# ── Stick pose ───────────────────────────────────────────────────────────────
# The display LIE — steeper than the rink's 42°, which is a skating-crouch
# number. A standing player's stick is near-upright, and the hosel is built at
# this same angle so the blade still sits flat on the ice instead of up on an
# edge. Steep also keeps the silhouette portrait-shaped: at 68° the blade is
# only ~0.5 m ahead of the butt instead of ~0.8 m.
const _SHAFT_LEAN_DEG: float = 68.0
# Yaw of the whole stick about the heel — the shaft leans back across the body
# rather than straight out, which is what puts the blade in profile.
const _STICK_YAW_DEG: float = 30.0
# Blade heel on the ice: out to the shooting side and ahead of the toes.
# Deliberately not scaled by height — where a player plants the blade is a
# stance, not a limb length.
const _HEEL_OUT_M: float = 0.14
const _HEEL_FWD_M: float = -0.67
# The heel rides this far above the sole (the stick workbench's disc seat).
const _HEEL_LIFT_M: float = 0.042
# Where the grips WANT to sit — the top hand just under the knob, the bottom
# hand high on the shaft. Both are only hints: the arm pass slides each one
# along the shaft until its own shoulder can actually reach it. They sit high
# because a stick standing on the ice in front of a player genuinely is held
# near its top; the shoulders are only ~1.4 m above a blade planted 0.7 m out.
const _TOP_HAND_DROP_M: float = 0.13
const _BOTTOM_HAND_FRAC: float = 0.70
# A grip never rides onto the hosel, and never past the knob.
const _GRIP_MIN_S_M: float = 0.25
const _GRIP_END_MARGIN_M: float = 0.06
const _HOSEL_LEN_M: float = 0.085
const _SHAFT_CROSS := Vector2(0.04, 0.05)
const _KNOB_HEIGHT_M: float = 0.05

# ── Camera framings, indexed by Focus ────────────────────────────────────────
# Distance from the anchor, and the yaw the figure turns to present the piece
# (mirrored by shooting side, so the gear you are looking at faces the glass).
# Pitch is the camera's elevation: above for the head, below for the boots.
const _FOCUS_DIST: Array[float] = [2.45, 1.30, 0.62, 0.55, 0.52]
const _FOCUS_YAW_DEG: Array[float] = [22.0, 38.0, 26.0, 34.0, 18.0]
const _FOCUS_PITCH_DEG: Array[float] = [-3.0, 6.0, 24.0, 5.0, -8.0]

# Surface finishes, matching the rink's (SkaterUniformCoordinator).
const _CLOTH_ROUGH: float = 0.9
const _LEATHER_ROUGH: float = 0.42
const _HELMET_ROUGH: float = 0.28
const _STEEL_ROUGH: float = 0.25

var _rig: Node3D = null
var _torso: MeshInstance3D = null
var _helmet: MeshInstance3D = null
var _face: MeshInstance3D = null
var _shoulders: Array[MeshInstance3D] = []
var _thighs: Array[MeshInstance3D] = []
var _socks: Array[MeshInstance3D] = []
var _collars: Array[MeshInstance3D] = []
var _boots: Array[MeshInstance3D] = []
# Arms are indexed TOP hand first, then BOTTOM — the grip order on the shaft,
# not left/right, because that is what the pose is built from.
var _upper_arms: Array[MeshInstance3D] = []
var _forearms: Array[MeshInstance3D] = []
var _elbows: Array[MeshInstance3D] = []
var _hands: Array[MeshInstance3D] = []
var _cuffs: Array[MeshInstance3D] = []

var _stick_root: Node3D = null
var _shaft: MeshInstance3D = null
var _shaft_mat: ShaderMaterial = null
var _blade: MeshInstance3D = null
var _tape_mesh: MeshInstance3D = null
var _knob: MeshInstance3D = null

# Focus anchors, in THIS node's space — recomputed by every apply() because the
# pieces move with the build's height and the picked stick length.
var _anchors: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
	Vector3.ZERO, Vector3.ZERO]
# The posed shaft line, in rig space. Written by the stick pass and read by the
# arm pass right after it — the grips are solved onto this line.
var _shaft_heel: Vector3 = Vector3.ZERO
var _shaft_up: Vector3 = Vector3.UP
var _shaft_len: float = 1.0
# +1 when the blade sits on the rig's +X side (a right-handed shot), −1 for a
# lefty. The top hand is always on the other side — see Skater._position_hand_markers.
var _blade_side: float = 1.0


func _ready() -> void:
	_build()


# ── Construction ─────────────────────────────────────────────────────────────

func _build() -> void:
	_rig = Node3D.new()
	add_child(_rig)

	_torso = _part(SkaterMeshBuilder.shared_torso())
	# Helmet assembly carries the shell and the head/neck skin as two surfaces,
	# so the head rides the helmet's scale exactly as it rides its bone.
	_helmet = _part(SkaterMeshBuilder.shared_helmet_assembly())
	# The face piece rides the HELMET, so it is a child at identity rather than
	# a sibling sharing its transform — that is what riding the bone means.
	_face = MeshInstance3D.new()
	_helmet.add_child(_face)

	for i: int in 2:
		_shoulders.append(_part(SkaterMeshBuilder.shared_shoulder_cap()))
		_thighs.append(_part(SkaterMeshBuilder.shared_thigh()))
		_socks.append(_part(SkaterMeshBuilder.shared_sock()))
		# Collar assembly = the ankle cuff plus its accent stripe; boot assembly
		# = quarter, toe cap, holder, steel runner and laces. Between them they
		# carry every zone a skate model paints, in one node each.
		_collars.append(_part(SkaterMeshBuilder.shared_skate_assembly()))
		_boots.append(_part(SkaterMeshBuilder.shared_boot_assembly()))
		_upper_arms.append(_part(SkaterMeshBuilder.shared_arm_bone()))
		_forearms.append(_part(SkaterMeshBuilder.shared_arm_bone()))
		_elbows.append(_part(SkaterMeshBuilder.shared_joint_ball()))
		_hands.append(_part(SkaterMeshBuilder.shared_glove_fist()))
		_cuffs.append(_part(SkaterMeshBuilder.shared_cuff()))

	_build_stick()


func _part(mesh: Mesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	_rig.add_child(mi)
	return mi


# The stick, assembled in its own frame exactly as the workbench built it:
# heel at the origin with the shaft climbing along the lie axis, so placing the
# whole sub-tree is one transform on `_stick_root`.
func _build_stick() -> void:
	_stick_root = Node3D.new()
	_rig.add_child(_stick_root)

	_shaft = MeshInstance3D.new()
	var shaft_box := BoxMesh.new()
	shaft_box.size = Vector3(_SHAFT_CROSS.x, _SHAFT_CROSS.y, 1.0)
	_shaft.mesh = shaft_box
	_shaft_mat = StickStyle.make_shaft_material()
	_shaft.material_override = _shaft_mat
	_stick_root.add_child(_shaft)

	_blade = MeshInstance3D.new()
	_blade.material_override = StickStyle.make_blade_material()
	_stick_root.add_child(_blade)

	_tape_mesh = MeshInstance3D.new()
	_blade.add_child(_tape_mesh)

	_knob = MeshInstance3D.new()
	var knob_cyl := CylinderMesh.new()
	knob_cyl.top_radius = 0.035
	knob_cyl.bottom_radius = 0.03
	knob_cyl.height = _KNOB_HEIGHT_M
	knob_cyl.radial_segments = 12
	_knob.mesh = knob_cyl
	_stick_root.add_child(_knob)


# ── Host API ─────────────────────────────────────────────────────────────────

# Dress and pose the figure from one pending build. `team_colors` is the
# pending team's TeamColorRegistry.get_colors dict — the kit the mannequin
# wears AND the slots a gear model's TEAM / ACCENT / LIGHT zones resolve
# against, so the figure previews the design on the sweater you are buying it
# for.
func apply(attrs: PlayerAttributes, gear: GearStyleConfig, tape: StickTapeConfig,
		team_colors: Dictionary, skin_tone: int, is_left_handed: bool) -> void:
	_blade_side = -1.0 if is_left_handed else 1.0
	_pose(attrs, tape, is_left_handed)
	_paint_body(team_colors, skin_tone)
	_paint_gear(gear, team_colors)
	_paint_stick(gear, tape, team_colors)


# Where the camera looks for one framing, in this node's space.
func focus_anchor(focus: int) -> Vector3:
	return _anchors[clampi(focus, 0, _anchors.size() - 1)]


func focus_distance(focus: int) -> float:
	return _FOCUS_DIST[clampi(focus, 0, _FOCUS_DIST.size() - 1)]


# The yaw the figure turns to, mirrored so the piece under inspection swings
# toward the glass on either shooting side.
func focus_yaw(focus: int) -> float:
	return deg_to_rad(_FOCUS_YAW_DEG[clampi(focus, 0, _FOCUS_YAW_DEG.size() - 1)]) \
			* _blade_side


func focus_pitch(focus: int) -> float:
	return deg_to_rad(_FOCUS_PITCH_DEG[clampi(focus, 0, _FOCUS_PITCH_DEG.size() - 1)])


# ── Pose ─────────────────────────────────────────────────────────────────────

# Scale a rig-local height about the ice plane — the appearance rig's rule, so
# a tall build grows legs and torso together and the skates stay planted.
static func _lift(y: float, m_height: float) -> float:
	return _ICE_Y + (y - _ICE_Y) * m_height


func _pose(attrs: PlayerAttributes, tape: StickTapeConfig,
		is_left_handed: bool) -> void:
	var m_height: float = attrs.height_mult()
	var m_torso: float = attrs.torso_bulk_mult()
	var m_shoulder: float = attrs.shoulder_bulk_mult()
	var m_head: float = attrs.head_bulk_mult()
	var m_thigh: float = attrs.thigh_mult()
	var m_calf: float = attrs.calf_mult()
	var m_upper_arm: float = attrs.upper_arm_bulk_mult()
	var m_forearm: float = attrs.forearm_bulk_mult()

	_torso.transform = Transform3D(
			Basis.from_scale(Vector3(m_torso, m_height, m_torso)),
			Vector3(0.0, _lift(_TORSO_Y, m_height), 0.0))
	# The helmet takes its own mild multiplier on all three axes and never
	# stretches with height: adult heads are near-constant across statures, and
	# that constancy is what sells a tall build as big rather than zoomed.
	_helmet.transform = Transform3D(
			Basis.from_scale(Vector3.ONE * m_head),
			Vector3(0.0, _lift(_HELMET_Y, m_height), 0.0))

	var shoulder_y: float = _lift(_SHOULDER_Y, m_height)
	# Deltoid caps ride TORSO bulk laterally — the pad sits on the chest wall,
	# so it is the torso's width that pushes it out, while its own bulk
	# multiplier keeps the ball reading Physical.
	var shoulder_x: float = _SHOULDER_X * m_torso
	var boot_y: float = _lift(_LEG_Y + _BOOT_DY, m_height)
	for i: int in 2:
		var side: float = -1.0 if i == 0 else 1.0
		_shoulders[i].transform = Transform3D(
				Basis.from_scale(Vector3(m_shoulder, m_height, m_shoulder)),
				Vector3(side * shoulder_x, shoulder_y, 0.0))

		var leg_x: float = side * _LEG_X * m_torso
		_thighs[i].transform = Transform3D(
				Basis.from_scale(Vector3(m_thigh, m_height, m_thigh)),
				Vector3(leg_x, _lift(_LEG_Y + _THIGH_DY, m_height), 0.0))
		_socks[i].transform = Transform3D(
				Basis.from_scale(Vector3(m_calf, m_height, m_calf)),
				Vector3(leg_x, _lift(_LEG_Y + _SOCK_DY, m_height), 0.0))
		_collars[i].transform = Transform3D(
				Basis.from_scale(Vector3(m_calf, m_height, m_calf)),
				Vector3(leg_x, _lift(_LEG_Y + _COLLAR_DY, m_height), 0.0))
		# The boot itself never scales — a big frame gets a longer leg, not a
		# longer foot — but its seat rides the lengthened shin like the rig's.
		_boots[i].transform = Transform3D(_BOOT_ROT,
				Vector3(leg_x, boot_y, _BOOT_DZ))

	_pose_stick(attrs, tape)
	_pose_arms(is_left_handed, shoulder_x, shoulder_y, m_upper_arm, m_forearm, m_height)

	# Anchors so far are rig-local (the stick and arm passes wrote theirs the
	# same way); the two body framings join them here.
	_anchors[Focus.FULL] = Vector3(0.0, (_lift(_LEG_Y, m_height) + shoulder_y) * 0.5, 0.0)
	_anchors[Focus.SKATES] = Vector3(0.0, boot_y, _BOOT_DZ)
	_anchors[Focus.HELMET] = _helmet.position

	# Seat the whole rig so the runner's contact lands on this node's origin.
	# The boot is the one unscaled part, so its contact does not follow the
	# height scaling on its own — deriving the seat here is what keeps every
	# build standing ON the case floor rather than sunk into it or hovering.
	var contact_y: float = boot_y - _BLADE_ICE_M
	_rig.position.y = -contact_y
	# Publish the anchors in THIS node's space, so a caller framing a piece does
	# not have to know how the rig was seated.
	for i: int in _anchors.size():
		_anchors[i].y -= contact_y


# The stick, then the grips derived from it. Placing the assembly first is what
# lets the hands sit ON the shaft instead of near it.
func _pose_stick(attrs: PlayerAttributes, tape: StickTapeConfig) -> void:
	var curve: int = attrs.curve
	var p := StickBladeMeshBuilder.Params.new()
	p.length = GameRules.DEFAULT_BLADE_LENGTH_M
	p.curve_depth = Skater.BLADE_PATTERN_DEPTH[curve]
	p.curve_power = Skater.BLADE_PATTERN_POWER[curve]
	p.face_open_deg = Skater.BLADE_PATTERN_FACE_DEG[curve]
	p.toe_round_m = Skater.BLADE_PATTERN_TOE_ROUND[curve]
	# The blade's curve is baked per hand, and the mannequin's blade side is
	# already the same flag, so the two can never disagree.
	p.curve_sign = -_blade_side
	p.hosel_length = _HOSEL_LEN_M
	p.hosel_angle_deg = _SHAFT_LEAN_DEG
	_blade.mesh = StickBladeMeshBuilder.build(p)
	_blade.transform = Transform3D.IDENTITY

	var tape_p := StickBladeMeshBuilder.Params.new()
	tape_p.length = p.length
	tape_p.curve_depth = p.curve_depth
	tape_p.curve_power = p.curve_power
	tape_p.face_open_deg = p.face_open_deg
	tape_p.toe_round_m = p.toe_round_m
	tape_p.curve_sign = p.curve_sign
	_tape_mesh.mesh = StickBladeMeshBuilder.build_tape(tape_p, tape.span_range()) \
			if tape.has_blade_tape() else null

	var stick_len: float = GameRules.DEFAULT_STICK_LENGTH_M * attrs.stick_len_mult() \
			+ Skater.SHAFT_BUTT_EXTEND_M
	var lean: float = deg_to_rad(_SHAFT_LEAN_DEG)
	var axis := Vector3(0.0, sin(lean), cos(lean))
	_shaft.transform = Transform3D(
			Basis.looking_at(-axis, Vector3.UP)
					* Basis.from_scale(Vector3(1.0, 1.0, stick_len)),
			axis * (stick_len * 0.5))
	# Same composition as Skater._update_stick_knob: the cylinder's long axis
	# onto the shaft line, taper toward the blade, capping the butt slightly proud.
	_knob.transform = Transform3D(
			Basis.looking_at(axis, Vector3.UP) * Basis(Vector3.RIGHT, PI * 0.5),
			axis * (stick_len - _KNOB_HEIGHT_M * 0.5 + 0.01))
	_shaft_mat.set_shader_parameter(&"shaft_len_m", stick_len)

	# Seat the assembly: heel on the ice out to the shooting side, yawed so the
	# shaft leans back across the body rather than straight out in front.
	var heel := Vector3(_blade_side * _HEEL_OUT_M, _ICE_Y + _HEEL_LIFT_M, _HEEL_FWD_M)
	var yaw: float = deg_to_rad(-_blade_side * _STICK_YAW_DEG)
	_stick_root.transform = Transform3D(Basis(Vector3.UP, yaw), heel)

	# Cached for the arm pass, which solves the grips onto this line.
	_shaft_heel = heel
	_shaft_up = _stick_root.basis * axis
	_shaft_len = stick_len
	_anchors[Focus.STICK] = heel + _shaft_up * (stick_len * 0.5)


# Both arms, shoulder → elbow → fist. The top hand belongs to the shoulder AWAY
# from the blade (a lefty's right hand tops the stick), which is the same rule
# the rig's hand markers use.
#
# The grips are SOLVED onto the shaft rather than fixed on it: the shoulders sit
# ~1.4 m above a blade planted out in front, so the two hands are at very
# different distances from their own shoulders, and pinning both would put one
# hand outside its arm's reach. Sliding each grip to where its arm can hold it
# is what keeps both arms the rig's own length.
func _pose_arms(is_left_handed: bool, shoulder_x: float, shoulder_y: float,
		m_upper_arm: float, m_forearm: float, m_height: float) -> void:
	var top_side: float = 1.0 if is_left_handed else -1.0
	var upper: float = _UPPER_ARM_M * m_height
	var fore: float = _FOREARM_M * m_height
	var reach_limit: float = (upper + fore) * _GRIP_REACH_FRAC
	var wanted: Array[float] = [
		_shaft_len - _TOP_HAND_DROP_M, _shaft_len * _BOTTOM_HAND_FRAC]
	var grips: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
	for i: int in 2:
		var side: float = top_side if i == 0 else -top_side
		var shoulder := Vector3(side * shoulder_x, shoulder_y, 0.0)
		var hand: Vector3 = _shaft_heel + _shaft_up \
				* _grip_along_shaft(shoulder, wanted[i], reach_limit)
		grips[i] = hand
		var pole := Vector3(_ARM_POLE.x * side, _ARM_POLE.y, _ARM_POLE.z)
		var elbow: Vector3 = _solve_elbow(shoulder, hand, pole, upper, fore)
		_seat_bone(_upper_arms[i], shoulder, elbow, _ARM_RADIUS * m_upper_arm)
		_seat_bone(_forearms[i], elbow, hand, _ARM_RADIUS * m_forearm)
		_elbows[i].transform = Transform3D(
				Basis.from_scale(Vector3.ONE * _ELBOW_RADIUS * m_upper_arm), elbow)
		# The fist's local +Y runs back toward the elbow — the live rig's
		# convention, so the block's faces track the forearm. Both this and the
		# cuff scale their basis COLUMNS: Basis.scaled() would scale in the
		# parent frame, which shears a rotated basis into a stretched sheet.
		var grip: Basis = _basis_along((elbow - hand).normalized())
		_hands[i].transform = Transform3D(
				Basis(grip.x * _HAND_RADIUS, grip.y * _HAND_RADIUS,
					grip.z * _HAND_RADIUS), hand)
		var wrist: Vector3 = hand + (elbow - hand).normalized() * _CUFF_OFFSET_M
		# The cuff mesh carries its real height baked, so only the radius scales.
		_cuffs[i].transform = Transform3D(
				Basis(grip.x * _CUFF_RADIUS, grip.y, grip.z * _CUFF_RADIUS), wrist)

	_anchors[Focus.GLOVES] = (grips[0] + grips[1]) * 0.5


# How far along the shaft a hand can grip: the points within `reach` of the
# shoulder are an interval on the shaft line, so take the one nearest where the
# grip wanted to be. A shaft that never comes within reach falls back to the
# closest it gets, which is the best that arm can do.
func _grip_along_shaft(shoulder: Vector3, wanted: float, reach: float) -> float:
	var to_heel: Vector3 = _shaft_heel - shoulder
	var b: float = _shaft_up.dot(to_heel)
	var disc: float = b * b - to_heel.length_squared() + reach * reach
	var s: float = -b
	if disc > 0.0:
		var root: float = sqrt(disc)
		s = clampf(wanted, -b - root, -b + root)
	return clampf(s, _GRIP_MIN_S_M, _shaft_len - _GRIP_END_MARGIN_M)


# Elbow on the circle of poses that reach `hand` with the given segments,
# picked by a pole hint — the hint is what stops the solver bending into the
# ribs. Segments are the rig's fixed lengths, so both arms come out the same
# length whatever their grip ended up being.
func _solve_elbow(shoulder: Vector3, hand: Vector3, pole: Vector3,
		upper: float, fore: float) -> Vector3:
	var to_hand: Vector3 = hand - shoulder
	var reach: float = to_hand.length()
	if reach < 0.001:
		return shoulder + Vector3.DOWN * upper
	var dir: Vector3 = to_hand / reach
	# Cosine rule: how far along the shoulder→hand line the elbow projects.
	var along: float = clampf(
			(reach * reach + upper * upper - fore * fore) / (2.0 * reach), -upper, upper)
	var offset: float = sqrt(maxf(upper * upper - along * along, 0.0))
	var perp: Vector3 = pole - dir * pole.dot(dir)
	if perp.length_squared() < 1e-8:
		perp = Vector3.DOWN - dir * dir.dot(Vector3.DOWN)
	return shoulder + dir * along + perp.normalized() * offset


# Stretch a unit bone prism between two joints. +Y (the wide end) lands on the
# proximal joint to match the mesh's distal taper.
func _seat_bone(mi: MeshInstance3D, proximal: Vector3, distal: Vector3,
		radius: float) -> void:
	var along: Vector3 = proximal - distal
	var length: float = along.length()
	if length < 0.001:
		mi.visible = false
		return
	mi.visible = true
	var b: Basis = _basis_along(along / length)
	mi.transform = Transform3D(
			Basis(b.x * radius, b.y * length, b.z * radius),
			(proximal + distal) * 0.5)


# Right-handed orthonormal basis with +Y along `y_axis`.
static func _basis_along(y_axis: Vector3) -> Basis:
	var ref: Vector3 = Vector3.FORWARD if absf(y_axis.dot(Vector3.UP)) < 0.99 \
			else Vector3.RIGHT
	var x_axis: Vector3 = ref.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, x_axis.cross(y_axis))


# ── Paint ────────────────────────────────────────────────────────────────────

# The kit, not flat team colors: striped jersey with the yoke on the torso's
# top cap, the shoulder pads' own color, striped socks, solid pants. Stripe
# textures come from the coordinator the rink paints with, so the bands land
# where the in-game skater's do.
func _paint_body(colors: Dictionary, skin_tone: int) -> void:
	var uniform: Dictionary = colors.uniform
	var jersey: Dictionary = uniform.jersey
	var socks: Dictionary = uniform.socks

	_paint_texture(_torso, 0, SkaterUniformCoordinator.make_h_stripes_texture(
			jersey.base, jersey.stripes, jersey.yoke), _CLOTH_ROUGH)
	_paint(_helmet, SkaterMeshBuilder.HELMET_SURF_SHELL, uniform.helmet, _HELMET_ROUGH)
	_paint(_helmet, SkaterMeshBuilder.HELMET_SURF_SKIN,
			SkinToneRegistry.color_for(skin_tone), _CLOTH_ROUGH)

	var sock_tex: ImageTexture = null
	if not socks.stripes.is_empty():
		sock_tex = SkaterUniformCoordinator.make_h_stripes_texture(
				socks.base, socks.stripes)
	var sleeve: Color = uniform.arms.upper.base
	for i: int in 2:
		_paint(_shoulders[i], 0, uniform.shoulders.color, _CLOTH_ROUGH)
		_paint(_thighs[i], 0, uniform.pants.base, _CLOTH_ROUGH)
		if sock_tex != null:
			_paint_texture(_socks[i], 0, sock_tex, _CLOTH_ROUGH)
		else:
			_paint(_socks[i], 0, socks.base, _CLOTH_ROUGH)
		_paint(_upper_arms[i], 0, sleeve, _CLOTH_ROUGH)
		_paint(_forearms[i], 0, sleeve, _CLOTH_ROUGH)
		_paint(_elbows[i], 0, sleeve, _CLOTH_ROUGH)


# The four gear picks, painted onto the pieces that wear them. A model paints
# every zone of its piece at once, so what stands in the case is the design you
# are buying on the kit you are buying it for.
func _paint_gear(gear: GearStyleConfig, colors: Dictionary) -> void:
	var team: Color = colors.primary
	var accent: Color = colors.secondary
	var light: Color = colors.light
	var quarter: Color = GearModelRegistry.skate_color(
			gear.skate_model, GearModelRegistry.SKATE_QUARTER, team, accent, light)
	var toe: Color = GearModelRegistry.skate_color(
			gear.skate_model, GearModelRegistry.SKATE_TOE, team, accent, light)
	var holder: Color = GearModelRegistry.skate_color(
			gear.skate_model, GearModelRegistry.SKATE_HOLDER, team, accent, light)
	var collar: Color = GearModelRegistry.skate_color(
			gear.skate_model, GearModelRegistry.SKATE_COLLAR, team, accent, light)
	var stripe: Color = GearModelRegistry.skate_color(
			gear.skate_model, GearModelRegistry.SKATE_STRIPE, team, accent, light)
	var lace: Color = TapeColorRegistry.resolve(gear.lace_color, team)

	var glove_kit: Color = colors.gloves
	var glove_accent: Color = colors.glove_accent
	var body: Color = GearModelRegistry.glove_color(
			gear.glove_model, GearModelRegistry.GLOVE_BODY, glove_kit, glove_accent, light)
	var fingers: Color = GearModelRegistry.glove_color(
			gear.glove_model, GearModelRegistry.GLOVE_FINGERS, glove_kit, glove_accent, light)
	var cuff: Color = GearModelRegistry.glove_color(
			gear.glove_model, GearModelRegistry.GLOVE_CUFF, glove_kit, glove_accent, light)

	for i: int in 2:
		_paint(_boots[i], SkaterMeshBuilder.BOOT_SURF_SHELL, quarter, _LEATHER_ROUGH)
		_paint(_boots[i], SkaterMeshBuilder.BOOT_SURF_TOE, toe, _LEATHER_ROUGH)
		_paint(_boots[i], SkaterMeshBuilder.BOOT_SURF_HOLDER, holder, _LEATHER_ROUGH)
		# The steel runner is never a model zone — it is a few millimetres of
		# silhouette under the holder's rail, not a design surface.
		_paint(_boots[i], SkaterMeshBuilder.BOOT_SURF_RUNNER,
				SkaterMeshBuilder.BLADE_STEEL_COLOR, _STEEL_ROUGH)
		_paint(_boots[i], SkaterMeshBuilder.BOOT_SURF_LACES, lace, _CLOTH_ROUGH)
		_paint(_collars[i], SkaterMeshBuilder.SKATE_SURF_COLLAR, collar, _LEATHER_ROUGH)
		_paint(_collars[i], SkaterMeshBuilder.SKATE_SURF_STRIPE, stripe, _LEATHER_ROUGH)
		_paint(_hands[i], SkaterMeshBuilder.FIST_PART_BACK, body, _CLOTH_ROUGH)
		_paint(_hands[i], SkaterMeshBuilder.FIST_PART_FINGERS, fingers, _CLOTH_ROUGH)
		_paint(_cuffs[i], 0, cuff, _CLOTH_ROUGH)

	# Face gear is a fixed look with no kit zones — the rink's own mesh and
	# material, and a null mesh for bare.
	_face.mesh = SkaterMeshBuilder.shared_face_gear(gear.helmet_face)
	_face.material_override = SkaterMeshBuilder.make_face_gear_material(gear.helmet_face)


func _paint_stick(gear: GearStyleConfig, tape: StickTapeConfig,
		colors: Dictionary) -> void:
	var accent: Color = colors.primary
	# Fresh materials from the same factories the rink uses, so the mannequin's
	# stick IS the in-game stick. The shaft material comes back with default
	# uniforms, so the pose's shaft length has to be re-sent after it.
	_shaft_mat = StickStyle.make_shaft_material(gear.stick_model)
	_shaft.material_override = _shaft_mat
	_blade.material_override = StickStyle.make_blade_material(gear.stick_model)

	var knob_color: Color = TapeColorRegistry.resolve(tape.knob_color, accent)
	_shaft_mat.set_shader_parameter(&"grip_mode", tape.knob_style)
	_shaft_mat.set_shader_parameter(&"grip_color", knob_color)
	_shaft_mat.set_shader_parameter(&"shaft_len_m",
			_shaft.transform.basis.get_scale().z)
	_tape_mesh.material_override = _flat(
			TapeColorRegistry.resolve(tape.blade_color, accent), _CLOTH_ROUGH)
	_knob.material_override = _flat(knob_color, _CLOTH_ROUGH)


# Per-instance paint for one surface. Goes through surface_override so the
# shared default's finish (the steel, the laces, the body rim) is duplicated
# rather than discarded — the merged assemblies must never take a
# material_override, which would flatten every one of their surfaces into one.
func _paint(mi: MeshInstance3D, surface: int, color: Color, roughness: float) -> void:
	var mat: StandardMaterial3D = SkaterMeshBuilder.surface_override(mi, surface)
	mat.albedo_color = color
	mat.albedo_texture = null
	mat.roughness = roughness
	BodyRim.apply(mat)


func _paint_texture(mi: MeshInstance3D, surface: int, tex: Texture2D,
		roughness: float) -> void:
	var mat: StandardMaterial3D = SkaterMeshBuilder.surface_override(mi, surface)
	mat.albedo_color = Color.WHITE
	mat.albedo_texture = tex
	mat.roughness = roughness
	BodyRim.apply(mat)


# Plain material for the stick's non-body pieces (tape, knob) — no body rim:
# they are equipment in the hand, not skin or cloth on the silhouette.
static func _flat(color: Color, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat
